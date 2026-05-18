use std::collections::{BTreeSet, HashMap, HashSet};
use std::io::{self, BufRead, BufReader, Write};
use std::path::{Component, Path, PathBuf};

use anyhow::{Context, Result, bail};
use clap::{ArgAction, Parser, Subcommand};
use refbox_core::PingInfo;
use refbox_index::{DiscoveryPolicy, SyncEngine, SyncStatus};
use refbox_rpc::{
    CloseKeysRequest, CloseKeysResponse, DiagnosticItem, DiagnosticsResponse, DuplicateGroupItem,
    DuplicateGroupsResponse, EmptyParams, EntriesByKeysRequest, EntriesResponse, EntryByKeyRequest,
    EntryCompletionDisplayItem, EntryFieldItem, EntryItem, EntryRefItem, EntrySearchItem,
    IndexedFilesResponse, JsonRpcError, JsonRpcErrorObject, JsonRpcRequest, JsonRpcResponse,
    LibraryFilesByKeysRequest, LibraryFilesResponse, LimitRequest, ListEntriesRequest,
    METHOD_CLOSE_KEYS, METHOD_DIAGNOSTICS, METHOD_DUPLICATE_GROUPS, METHOD_ENTRIES_BY_KEYS,
    METHOD_ENTRY_BY_KEY, METHOD_INDEXED_FILES, METHOD_LIBRARY_FILES_BY_KEYS, METHOD_LIST_ENTRIES,
    METHOD_PING, METHOD_RAW_ENTRY, METHOD_RESOLVE_FILES, METHOD_RESOURCES_BY_KEY,
    METHOD_RESOURCES_BY_KEYS, METHOD_SEARCH_ENTRIES, METHOD_SOURCE_LOCATION, METHOD_STATUS,
    METHOD_SYNC_FILE, METHOD_SYNC_FULL, RawEntryRequest, RawEntryResponse, ResolveFilesRequest,
    ResourceItem, ResourcesByKeyRequest, ResourcesByKeysRequest, ResourcesResponse,
    SearchEntriesRequest, SearchEntriesResponse, SourceLocationRequest, SourceLocationResponse,
    StatusResponse, SyncFileRequest, SyncResponse, clamp_limit,
};
use refbox_store::{
    HydrateOptions, KeyScopeOptions, RefboxStore, SearchOptions, SearchResult, StoredEntry,
    StoredField, StoredSearchEntry,
};
use serde::de::DeserializeOwned;

#[derive(Debug, Parser)]
#[command(author, version, about = "Local-first bibliography engine")]
struct Cli {
    #[command(subcommand)]
    command: Command,
}

#[derive(Debug, Subcommand)]
enum Command {
    /// Run the JSON-RPC daemon over stdio.
    Serve {
        /// SQLite database path for the derived index.
        #[arg(long)]
        db: PathBuf,
        /// Root directory containing bibliography files.
        #[arg(long, action = ArgAction::Append)]
        root: Vec<PathBuf>,
        /// Explicit bibliography file to include in the indexed corpus.
        #[arg(long = "file", action = ArgAction::Append)]
        files: Vec<PathBuf>,
        /// File extension considered during root discovery.
        #[arg(long = "extension", action = ArgAction::Append)]
        extensions: Vec<String>,
        /// Glob pattern included during root discovery.
        #[arg(long = "include-glob", action = ArgAction::Append)]
        include_globs: Vec<String>,
        /// Glob pattern excluded during root discovery.
        #[arg(long = "exclude-glob", action = ArgAction::Append)]
        exclude_globs: Vec<String>,
        /// Include hidden files and directories during root discovery.
        #[arg(long, default_value_t = false)]
        include_hidden: bool,
    },
}

fn main() -> Result<()> {
    let cli = Cli::parse();
    match cli.command {
        Command::Serve {
            db,
            root,
            files,
            extensions,
            include_globs,
            exclude_globs,
            include_hidden,
        } => serve(
            db,
            root,
            files,
            extensions,
            include_globs,
            exclude_globs,
            include_hidden,
        ),
    }
}

fn serve(
    db: PathBuf,
    roots: Vec<PathBuf>,
    files: Vec<PathBuf>,
    extensions: Vec<String>,
    include_globs: Vec<String>,
    exclude_globs: Vec<String>,
    include_hidden: bool,
) -> Result<()> {
    let policy = daemon_policy(
        roots,
        files,
        extensions,
        include_globs,
        exclude_globs,
        include_hidden,
    )?;
    let mut daemon = Daemon::new(policy, db)?;
    let stdin = io::stdin();
    let stdout = io::stdout();
    let mut reader = BufReader::new(stdin.lock());
    let mut writer = stdout.lock();

    loop {
        match read_request(&mut reader) {
            Ok(Some(request)) => {
                let response = daemon.handle_request(request);
                write_response(&mut writer, &response)?;
            }
            Ok(None) => break,
            Err(error) => {
                let response = JsonRpcResponse::error(
                    serde_json::Value::Null,
                    JsonRpcErrorObject::parse_error(error.to_string()),
                );
                write_response(&mut writer, &response)?;
            }
        }
    }

    Ok(())
}

fn daemon_policy(
    roots: Vec<PathBuf>,
    files: Vec<PathBuf>,
    extensions: Vec<String>,
    include_globs: Vec<String>,
    exclude_globs: Vec<String>,
    include_hidden: bool,
) -> Result<DiscoveryPolicy> {
    if roots.is_empty() && files.is_empty() {
        bail!("at least one --root or --file must be configured");
    }

    let roots = roots
        .into_iter()
        .map(normalize_root_path)
        .collect::<Result<Vec<_>>>()?;
    let files = files
        .into_iter()
        .map(normalize_explicit_file_path)
        .collect::<Result<Vec<_>>>()?;
    let mut policy = DiscoveryPolicy::new(roots, files);

    if !extensions.is_empty() {
        policy.extensions = extensions
            .into_iter()
            .filter_map(|extension| {
                let extension = extension
                    .trim()
                    .trim_start_matches('.')
                    .to_ascii_lowercase();
                (!extension.is_empty()).then_some(extension)
            })
            .collect();
        if policy.extensions.is_empty() {
            bail!("at least one non-empty --extension must be configured for root discovery");
        }
    }

    policy.include_globs = include_globs;
    policy.exclude_globs = exclude_globs;
    policy.include_hidden = include_hidden;
    Ok(policy)
}

fn normalize_root_path(path: PathBuf) -> Result<PathBuf> {
    let path = absolute_path(path)?;
    let metadata = std::fs::metadata(&path)
        .with_context(|| format!("bibliography root does not exist: {}", path.display()))?;
    if !metadata.is_dir() {
        bail!("bibliography root is not a directory: {}", path.display());
    }
    Ok(path)
}

fn normalize_explicit_file_path(path: PathBuf) -> Result<PathBuf> {
    let path = absolute_path(path)?;
    if std::fs::metadata(&path).is_ok_and(|metadata| metadata.is_dir()) {
        bail!("bibliography file is a directory: {}", path.display());
    }
    Ok(path)
}

fn absolute_path(path: PathBuf) -> Result<PathBuf> {
    if path.is_absolute() {
        Ok(path)
    } else {
        Ok(std::env::current_dir()
            .context("failed to read current directory")?
            .join(path))
    }
}

struct Daemon {
    policy: DiscoveryPolicy,
    db: PathBuf,
    store: RefboxStore,
    sync: SyncEngine,
    file_lookup_cache: HashMap<FileLookupCacheKey, FileLookupIndex>,
}

#[derive(Debug, Clone, PartialEq, Eq, Hash)]
struct FileLookupCacheKey {
    roots: Vec<PathBuf>,
    recursive: bool,
    extensions: Option<Vec<String>>,
}

#[derive(Debug, Clone, Default)]
struct FileLookupIndex {
    entries: Vec<(PathBuf, String)>,
}

impl FileLookupIndex {
    fn push(&mut self, path: PathBuf) {
        let Some(stem) = path
            .file_stem()
            .and_then(|stem| stem.to_str())
            .map(str::to_owned)
        else {
            return;
        };
        self.entries.push((path, stem));
    }
}

impl Daemon {
    fn new(policy: DiscoveryPolicy, db: PathBuf) -> Result<Self> {
        let store = RefboxStore::open(&db)
            .with_context(|| format!("failed to open store: {}", db.display()))?;
        let sync = SyncEngine::new(policy.clone());
        Ok(Self {
            policy,
            db,
            store,
            sync,
            file_lookup_cache: HashMap::new(),
        })
    }

    fn handle_request(&mut self, request: JsonRpcRequest) -> JsonRpcResponse {
        let id = request.id.unwrap_or(serde_json::Value::Null);
        let response = self.dispatch(request.method.as_str(), request.params);

        match response {
            Ok(result) => JsonRpcResponse::success(id, result),
            Err(error) => JsonRpcResponse::error(id, error.into_inner()),
        }
    }

    fn entry_search_item(entry: StoredSearchEntry) -> EntrySearchItem {
        Self::entry_search_item_with_display(entry, false, true)
    }

    fn entry_search_item_with_display(
        entry: StoredSearchEntry,
        include_completion_display: bool,
        include_fields: bool,
    ) -> EntrySearchItem {
        let completion_display =
            include_completion_display.then(|| completion_display_item(&entry));
        EntrySearchItem {
            id: entry.entry_id,
            key: entry.key,
            source_path: entry.file_path,
            entry_type: entry.entry_type,
            score: entry.score,
            fields: if include_fields {
                entry.fields.into_iter().map(field_item).collect()
            } else {
                Vec::new()
            },
            resource_kinds: entry.resource_kinds,
            resources: entry.resources.into_iter().map(resource_item).collect(),
            completion_display,
        }
    }

    fn file_lookup_index(&mut self, key: FileLookupCacheKey) -> &FileLookupIndex {
        self.file_lookup_cache
            .entry(key.clone())
            .or_insert_with(|| build_file_lookup_index(&key))
    }

    fn resolve_files(&mut self, request: ResolveFilesRequest) -> Vec<String> {
        let files = normalize_nonempty_strings(request.files);
        if files.is_empty() {
            return Vec::new();
        }

        let roots = normalize_existing_dirs(request.roots);
        let extensions = normalize_extensions_vec(request.extensions);
        let extension_set = extension_set(extensions.as_ref());
        let recursive = request.recursive.unwrap_or(false);
        let cache_only = request.cache_only.unwrap_or(false);
        let mut found = Vec::new();
        let mut seen = HashSet::new();
        let mut relative_files = Vec::new();

        for file in files {
            let path = PathBuf::from(file);
            if path.is_absolute() {
                push_regular_file(&mut found, &mut seen, &path, extension_set.as_ref());
            } else {
                relative_files.push(path);
            }
        }

        if relative_files.is_empty() || roots.is_empty() {
            return found;
        }

        for root in &roots {
            for relative in &relative_files {
                push_regular_file(
                    &mut found,
                    &mut seen,
                    &root.join(relative),
                    extension_set.as_ref(),
                );
            }
        }

        if recursive {
            let relative_scan_files = relative_files
                .iter()
                .filter(|relative| !path_has_parent_dir(relative))
                .collect::<Vec<_>>();
            if !relative_scan_files.is_empty() {
                let cache_key = FileLookupCacheKey {
                    roots,
                    recursive: true,
                    extensions,
                };
                if cache_only && !self.file_lookup_cache.contains_key(&cache_key) {
                    return found;
                }
                let index = self.file_lookup_index(cache_key);
                for (path, _) in &index.entries {
                    if relative_scan_files
                        .iter()
                        .any(|relative| path.ends_with(relative))
                    {
                        push_unique_path(&mut found, &mut seen, path);
                    }
                }
            }
        }

        found
    }

    fn library_files_by_keys(&mut self, request: LibraryFilesByKeysRequest) -> Vec<String> {
        let keys = normalize_nonempty_strings(request.keys)
            .into_iter()
            .collect::<HashSet<_>>();
        let roots = normalize_existing_dirs(request.roots);
        if keys.is_empty() || roots.is_empty() {
            return Vec::new();
        }

        let recursive = request.recursive.unwrap_or(false);
        let additional_separator = request.additional_separator;
        let cache_key = FileLookupCacheKey {
            roots,
            recursive,
            extensions: normalize_extensions_vec(request.extensions),
        };
        if request.cache_only.unwrap_or(false) && !self.file_lookup_cache.contains_key(&cache_key) {
            return Vec::new();
        }
        let index = self.file_lookup_index(cache_key);
        let mut found = Vec::new();
        let mut seen = HashSet::new();

        for (path, stem) in &index.entries {
            if keyed_file_stem_matches(stem, &keys, additional_separator.as_deref()) {
                push_unique_path(&mut found, &mut seen, path);
            }
        }

        found
    }

    fn dispatch(
        &mut self,
        method: &str,
        params: serde_json::Value,
    ) -> std::result::Result<serde_json::Value, JsonRpcError> {
        match method {
            METHOD_PING => self.to_value(PingInfo {
                version: env!("CARGO_PKG_VERSION").to_owned(),
                roots: path_strings_lossy(&self.policy.roots),
                files: path_strings_lossy(&self.policy.files),
                db: self.db.display().to_string(),
            }),
            METHOD_STATUS => {
                let _: EmptyParams = parse_params(params)?;
                self.to_value(StatusResponse {
                    roots: path_strings_lossy(&self.policy.roots),
                    files: path_strings_lossy(&self.policy.files),
                    db: self.db.display().to_string(),
                    schema_version: self.store.schema_version().map_err(store_error)?,
                    counts: self.store.index_counts().map_err(store_error)?,
                })
            }
            METHOD_SYNC_FULL => {
                let _: EmptyParams = parse_params(params)?;
                let status = self.sync.sync_full(&mut self.store).map_err(sync_error)?;
                self.to_value(sync_response(status))
            }
            METHOD_SYNC_FILE => {
                let request: SyncFileRequest = parse_params(params)?;
                let explicit = request.explicit.unwrap_or(false);
                let path = self.resolve_request_path(&request.path, explicit)?;
                let managed = self.policy.is_managed_file(&path).map_err(sync_error)?;
                let status = if explicit && !managed {
                    self.sync
                        .sync_explicit_file(&mut self.store, path)
                        .map_err(sync_error)?
                } else {
                    self.sync
                        .sync_file(&mut self.store, path)
                        .map_err(sync_error)?
                };
                self.to_value(sync_response(status))
            }
            METHOD_INDEXED_FILES => {
                let _: EmptyParams = parse_params(params)?;
                self.to_value(IndexedFilesResponse {
                    files: self.store.indexed_file_metadata().map_err(store_error)?,
                })
            }
            METHOD_SEARCH_ENTRIES => {
                let request: SearchEntriesRequest = parse_params(params)?;
                let limit = clamp_limit(request.limit);
                let source_paths = request.source_paths.unwrap_or_default();
                let include_configured_sources = request
                    .include_configured_sources
                    .unwrap_or(source_paths.is_empty());
                let keys = request.keys.unwrap_or_default();
                let resource_kinds = request.resource_kinds.unwrap_or_default();
                let crossref_fields =
                    request_crossref_fields(request.include_crossrefs, request.crossref_fields);
                let search_fields = request.search_fields.unwrap_or_default();
                let field_names = request.field_names;
                let include_resources = request.include_resources.unwrap_or(true);
                let include_fields = request.include_fields.unwrap_or(true);
                let include_field_sources = request.include_field_sources.unwrap_or(true);
                let include_completion_display =
                    request.include_completion_display.unwrap_or(false);
                let field_value_char_limit = request.field_value_char_limit;
                let search_results = self
                    .store
                    .search(
                        &request.query,
                        limit,
                        SearchOptions {
                            source_paths: &source_paths,
                            include_configured_sources,
                            keys: &keys,
                            resource_kinds: &resource_kinds,
                            crossref_fields: &crossref_fields,
                            search_fields: &search_fields,
                            allow_empty_query: request.allow_empty_query.unwrap_or(false),
                            ranked: request.ranked.unwrap_or(true),
                        },
                    )
                    .map_err(store_error)?;
                let entries = self
                    .store
                    .hydrate_search_results(
                        search_results,
                        HydrateOptions {
                            crossref_fields: &crossref_fields,
                            field_names: field_names.as_deref(),
                            include_resources,
                            include_fields,
                            include_completion_display,
                            include_field_sources,
                            field_value_char_limit,
                        },
                    )
                    .map_err(store_error)?
                    .into_iter()
                    .map(|entry| {
                        Self::entry_search_item_with_display(
                            entry,
                            include_completion_display,
                            include_fields,
                        )
                    })
                    .collect();
                self.to_value(SearchEntriesResponse { entries })
            }
            METHOD_LIST_ENTRIES => {
                let request: ListEntriesRequest = parse_params(params)?;
                let limit = clamp_limit(request.limit);
                let offset = request.offset.unwrap_or(0);
                let search_results = self
                    .store
                    .list_entries(limit, offset)
                    .map_err(store_error)?
                    .into_iter()
                    .map(|entry| SearchResult {
                        entry_id: entry.id,
                        file_path: entry.file_path,
                        key: entry.key,
                        entry_type: entry.entry_type,
                        score: 0.0,
                    })
                    .collect();
                let crossref_fields = default_crossref_fields();
                let entries = self
                    .store
                    .hydrate_search_results(
                        search_results,
                        HydrateOptions {
                            crossref_fields: &crossref_fields,
                            ..HydrateOptions::default()
                        },
                    )
                    .map_err(store_error)?
                    .into_iter()
                    .map(Self::entry_search_item)
                    .collect();
                self.to_value(SearchEntriesResponse { entries })
            }
            METHOD_CLOSE_KEYS => {
                let request: CloseKeysRequest = parse_params(params)?;
                let limit = clamp_limit(request.limit);
                let source_paths = request.source_paths.unwrap_or_default();
                let include_configured_sources = request
                    .include_configured_sources
                    .unwrap_or(source_paths.is_empty());
                let keys = self
                    .store
                    .close_keys(
                        &request.key,
                        request.max_distance.unwrap_or(2),
                        limit,
                        KeyScopeOptions {
                            source_paths: &source_paths,
                            include_configured_sources,
                        },
                    )
                    .map_err(store_error)?;
                self.to_value(CloseKeysResponse { keys })
            }
            METHOD_ENTRY_BY_KEY => {
                let request: EntryByKeyRequest = parse_params(params)?;
                let entry =
                    self.resolve_entry(request.id, &request.key, request.source_path.as_deref())?;
                self.to_value(entry_item(entry))
            }
            METHOD_ENTRIES_BY_KEYS => {
                let request: EntriesByKeysRequest = parse_params(params)?;
                let limit = clamp_limit(request.limit_per_key);
                let crossref_fields =
                    request_crossref_fields(request.include_crossrefs, request.crossref_fields);
                let mut search_results = Vec::new();
                for key in request.keys {
                    search_results.extend(
                        self.store
                            .entries_by_key(&key, None, Some(limit))
                            .map_err(store_error)?
                            .into_iter()
                            .map(|entry| SearchResult {
                                entry_id: entry.id,
                                file_path: entry.file_path,
                                key: entry.key,
                                entry_type: entry.entry_type,
                                score: 0.0,
                            }),
                    );
                }
                let entries = self
                    .store
                    .hydrate_search_results(
                        search_results,
                        HydrateOptions {
                            crossref_fields: &crossref_fields,
                            ..HydrateOptions::default()
                        },
                    )
                    .map_err(store_error)?
                    .into_iter()
                    .map(Self::entry_search_item)
                    .collect();
                self.to_value(EntriesResponse { entries })
            }
            METHOD_RESOURCES_BY_KEY => {
                let request: ResourcesByKeyRequest = parse_params(params)?;
                let entry =
                    self.resolve_entry(request.id, &request.key, request.source_path.as_deref())?;
                let crossref_fields =
                    request_crossref_fields(request.include_crossrefs, request.crossref_fields);
                let resources = self
                    .store
                    .resources_for_entry(entry.id, &crossref_fields)
                    .map_err(store_error)?
                    .into_iter()
                    .map(resource_item)
                    .collect();
                self.to_value(ResourcesResponse { resources })
            }
            METHOD_RESOURCES_BY_KEYS => {
                let request: ResourcesByKeysRequest = parse_params(params)?;
                let limit = clamp_limit(request.limit_per_key);
                let crossref_fields =
                    request_crossref_fields(request.include_crossrefs, request.crossref_fields);
                let resources = self
                    .store
                    .resources_for_keys(&request.keys, limit, &crossref_fields)
                    .map_err(store_error)?
                    .into_iter()
                    .map(resource_item)
                    .collect();
                self.to_value(ResourcesResponse { resources })
            }
            METHOD_RESOLVE_FILES => {
                let request: ResolveFilesRequest = parse_params(params)?;
                let files = self.resolve_files(request);
                self.to_value(LibraryFilesResponse { files })
            }
            METHOD_LIBRARY_FILES_BY_KEYS => {
                let request: LibraryFilesByKeysRequest = parse_params(params)?;
                let files = self.library_files_by_keys(request);
                self.to_value(LibraryFilesResponse { files })
            }
            METHOD_RAW_ENTRY => {
                let request: RawEntryRequest = parse_params(params)?;
                let entry =
                    self.resolve_entry(request.id, &request.key, request.source_path.as_deref())?;
                let raw = self
                    .store
                    .raw_entry(entry.id)
                    .map_err(store_error)?
                    .ok_or_else(|| unknown_key(entry.key.clone()))?;
                self.to_value(RawEntryResponse {
                    key: entry.key,
                    source_path: entry.file_path,
                    raw,
                })
            }
            METHOD_SOURCE_LOCATION => {
                let request: SourceLocationRequest = parse_params(params)?;
                let entry =
                    self.resolve_entry(request.id, &request.key, request.source_path.as_deref())?;
                if !std::path::Path::new(&entry.file_path).is_file() {
                    return Err(stale_source_file(entry.file_path));
                }
                self.to_value(SourceLocationResponse {
                    key: entry.key,
                    source_path: entry.file_path,
                    source: entry.source,
                })
            }
            METHOD_DIAGNOSTICS => {
                let request: LimitRequest = parse_params(params)?;
                let limit = clamp_limit(request.limit);
                let diagnostics = self
                    .store
                    .diagnostics(limit)
                    .map_err(store_error)?
                    .into_iter()
                    .map(|diagnostic| DiagnosticItem {
                        file_path: diagnostic.file_path,
                        entry_id: diagnostic.entry_id,
                        severity: diagnostic.severity,
                        code: diagnostic.code,
                        message: diagnostic.message,
                        target_kind: diagnostic.target_kind,
                        source: diagnostic.source,
                    })
                    .collect();
                self.to_value(DiagnosticsResponse { diagnostics })
            }
            METHOD_DUPLICATE_GROUPS => {
                let request: LimitRequest = parse_params(params)?;
                let limit = clamp_limit(request.limit);
                let groups = self
                    .store
                    .duplicate_groups(limit)
                    .map_err(store_error)?
                    .into_iter()
                    .map(|group| DuplicateGroupItem {
                        key: group.key,
                        entries: group
                            .entries
                            .into_iter()
                            .map(|entry| EntryRefItem {
                                id: entry.id,
                                key: entry.key,
                                source_path: entry.file_path,
                            })
                            .collect(),
                    })
                    .collect();
                self.to_value(DuplicateGroupsResponse { groups })
            }
            _ => Err(JsonRpcError::new(JsonRpcErrorObject::method_not_found(
                format!("unsupported method: {method}"),
            ))),
        }
    }

    fn resolve_request_path(
        &self,
        path: &str,
        explicit: bool,
    ) -> std::result::Result<PathBuf, JsonRpcError> {
        let path = PathBuf::from(path);
        if path
            .components()
            .any(|component| matches!(component, Component::ParentDir))
        {
            return Err(invalid_path(path.display().to_string()));
        }
        let path = if path.is_absolute() {
            path
        } else {
            let Some(root) = self.policy.roots.first() else {
                return Err(invalid_path(path.display().to_string()));
            };
            root.join(path)
        };

        if !explicit && !self.policy.contains_path(&path) {
            return Err(invalid_path(path.display().to_string()));
        }

        Ok(path)
    }

    fn resolve_entry(
        &self,
        id: Option<i64>,
        key: &str,
        source_path: Option<&str>,
    ) -> std::result::Result<StoredEntry, JsonRpcError> {
        if let Some(id) = id {
            let entry = self
                .store
                .entry_by_id(id)
                .map_err(store_error)?
                .ok_or_else(|| unknown_key(key.to_string()))?;
            if entry.key != key || source_path.is_some_and(|path| entry.file_path != path) {
                return Err(unknown_key(key.to_string()));
            }
            return Ok(entry);
        }

        let mut entries = self
            .store
            .entries_by_key(key, source_path, Some(1))
            .map_err(store_error)?;

        match entries.len() {
            0 => Err(unknown_key(key.to_string())),
            1 => Ok(entries.remove(0)),
            _ => unreachable!("exact key lookup is limited to one entry"),
        }
    }

    fn to_value<T: serde::Serialize>(
        &self,
        value: T,
    ) -> std::result::Result<serde_json::Value, JsonRpcError> {
        serde_json::to_value(value).map_err(|error| {
            JsonRpcError::new(JsonRpcErrorObject::internal_error(error.to_string()))
        })
    }
}

fn read_request(reader: &mut impl BufRead) -> Result<Option<JsonRpcRequest>> {
    let mut content_length = None;

    loop {
        let mut line = String::new();
        let bytes = reader
            .read_line(&mut line)
            .context("failed to read framing header")?;
        if bytes == 0 {
            return Ok(None);
        }

        if line == "\r\n" {
            break;
        }

        let trimmed = line.trim_end_matches(['\r', '\n']);
        let (name, value) = trimmed
            .split_once(':')
            .with_context(|| format!("invalid header line: {trimmed}"))?;
        if name.eq_ignore_ascii_case("content-length") {
            let parsed = value
                .trim()
                .parse::<usize>()
                .with_context(|| format!("invalid content length: {}", value.trim()))?;
            content_length = Some(parsed);
        }
    }

    let length = content_length.context("missing Content-Length header")?;
    let mut body = vec![0_u8; length];
    reader
        .read_exact(&mut body)
        .context("failed to read framed body")?;

    let request = serde_json::from_slice(&body).context("invalid JSON-RPC request body")?;
    Ok(Some(request))
}

fn write_response(writer: &mut impl Write, response: &JsonRpcResponse) -> Result<()> {
    let body = serde_json::to_vec(response).context("failed to serialize JSON-RPC response")?;
    write!(writer, "Content-Length: {}\r\n\r\n", body.len())
        .context("failed to write framing header")?;
    writer
        .write_all(&body)
        .context("failed to write JSON-RPC response body")?;
    writer
        .flush()
        .context("failed to flush JSON-RPC response")?;
    Ok(())
}

fn parse_params<T: DeserializeOwned>(
    params: serde_json::Value,
) -> std::result::Result<T, JsonRpcError> {
    let params = if params.is_null() {
        serde_json::json!({})
    } else {
        params
    };
    serde_json::from_value(params)
        .map_err(|error| JsonRpcError::new(JsonRpcErrorObject::invalid_params(error.to_string())))
}

fn build_file_lookup_index(key: &FileLookupCacheKey) -> FileLookupIndex {
    let extension_set = extension_set(key.extensions.as_ref());
    let mut index = FileLookupIndex::default();
    for root in &key.roots {
        scan_regular_files(root, key.recursive, |path| {
            if extension_allowed(&path, extension_set.as_ref()) {
                index.push(path);
            }
        });
    }
    index
}

fn normalize_nonempty_strings(values: Vec<String>) -> Vec<String> {
    values
        .into_iter()
        .map(|value| value.trim().to_string())
        .filter(|value| !value.is_empty())
        .collect()
}

fn normalize_existing_dirs(roots: Vec<String>) -> Vec<PathBuf> {
    let mut seen = BTreeSet::new();
    let mut dirs = Vec::new();
    for root in normalize_nonempty_strings(roots) {
        let path = PathBuf::from(root);
        if path.is_dir() {
            let key = path.display().to_string();
            if seen.insert(key) {
                dirs.push(path);
            }
        }
    }
    dirs
}

fn normalize_extensions_vec(extensions: Option<Vec<String>>) -> Option<Vec<String>> {
    extensions.and_then(|extensions| {
        let extensions = extensions
            .into_iter()
            .filter(|extension| !extension.is_empty())
            .collect::<BTreeSet<_>>();
        (!extensions.is_empty()).then(|| extensions.into_iter().collect())
    })
}

fn extension_set(extensions: Option<&Vec<String>>) -> Option<HashSet<String>> {
    extensions.map(|extensions| extensions.iter().cloned().collect())
}

fn push_regular_file(
    found: &mut Vec<String>,
    seen: &mut HashSet<String>,
    path: &Path,
    extensions: Option<&HashSet<String>>,
) {
    if path.metadata().is_ok_and(|metadata| metadata.is_file())
        && extension_allowed(path, extensions)
    {
        push_unique_path(found, seen, path);
    }
}

fn push_unique_path(found: &mut Vec<String>, seen: &mut HashSet<String>, path: &Path) {
    let path = path.display().to_string();
    if seen.insert(path.clone()) {
        found.push(path);
    }
}

fn extension_allowed(path: &Path, extensions: Option<&HashSet<String>>) -> bool {
    match extensions {
        Some(extensions) => path
            .extension()
            .and_then(|extension| extension.to_str())
            .map(|extension| extensions.contains(extension))
            .unwrap_or(false),
        None => true,
    }
}

fn keyed_file_stem_matches(
    stem: &str,
    keys: &HashSet<String>,
    additional_separator: Option<&str>,
) -> bool {
    if keys.contains(stem) {
        return true;
    }
    additional_separator.is_some_and(|separator| {
        keys.iter().any(|key| {
            stem.strip_prefix(key)
                .is_some_and(|suffix| separator.is_empty() || suffix.starts_with(separator))
        })
    })
}

fn path_has_parent_dir(path: &Path) -> bool {
    path.components()
        .any(|component| matches!(component, Component::ParentDir))
}

fn scan_regular_files(root: &Path, recursive: bool, mut visit: impl FnMut(PathBuf)) {
    let mut stack = vec![root.to_path_buf()];
    while let Some(dir) = stack.pop() {
        let Ok(read_dir) = std::fs::read_dir(&dir) else {
            continue;
        };
        let mut entries = read_dir.filter_map(|entry| entry.ok()).collect::<Vec<_>>();
        entries.sort_by_key(|entry| entry.path());
        let mut subdirs = Vec::new();
        for entry in entries {
            let path = entry.path();
            let Ok(file_type) = entry.file_type() else {
                continue;
            };
            if recursive && file_type.is_dir() && !file_type.is_symlink() {
                subdirs.push(path);
            } else if file_type.is_file()
                || (file_type.is_symlink()
                    && path.metadata().is_ok_and(|metadata| metadata.is_file()))
            {
                visit(path);
            }
        }
        for subdir in subdirs.into_iter().rev() {
            stack.push(subdir);
        }
    }
}

fn sync_response(status: SyncStatus) -> SyncResponse {
    SyncResponse {
        discovered_file_count: status.discovered_file_count,
        changed_file_count: status.changed_file_count,
        skipped_file_count: status.skipped_file_count,
        removed_file_count: status.removed_file_count,
        indexed_file_count: status.indexed_file_count,
        indexed_entry_count: status.indexed_entry_count,
        diagnostic_count: status.diagnostic_count,
        latest_modified_ns: status.latest_modified_ns,
    }
}

fn path_strings_lossy(paths: &[PathBuf]) -> Vec<String> {
    paths
        .iter()
        .map(|path| path.to_string_lossy().into_owned())
        .collect()
}

fn entry_item(entry: StoredEntry) -> EntryItem {
    EntryItem {
        id: entry.id,
        key: entry.key,
        source_path: entry.file_path,
        entry_type: entry.entry_type,
        source: entry.source,
    }
}

fn completion_display_item(entry: &StoredSearchEntry) -> EntryCompletionDisplayItem {
    let (author, date, title, tags) = if let Some(display) = &entry.completion_display {
        (
            clean_bibliography_value(&display.author)
                .map(|value| shorten_names_to_width(&value, 30))
                .unwrap_or_default(),
            clean_bibliography_value(&display.date).unwrap_or_default(),
            clean_bibliography_value(&display.title).unwrap_or_default(),
            clean_bibliography_value(&display.tags).unwrap_or_default(),
        )
    } else {
        (
            first_clean_field(&entry.fields, &["author", "editor"])
                .map(|value| shorten_names_to_width(&value, 30))
                .unwrap_or_default(),
            first_clean_field(&entry.fields, &["date", "year", "issued"]).unwrap_or_default(),
            first_clean_field(&entry.fields, &["title"]).unwrap_or_default(),
            first_clean_field(&entry.fields, &["tags", "keywords"]).unwrap_or_default(),
        )
    };

    EntryCompletionDisplayItem {
        main: format!(
            "{}     {}     {}",
            fit_columns(&author, 30),
            fit_columns(&date, 4),
            fit_columns(&title, 48)
        ),
        suffix: format!(
            "          {}    {}    {}",
            fit_columns(&entry.key, 15),
            fit_columns(&entry.entry_type, 12),
            tags
        )
        .trim_end()
        .to_owned(),
    }
}

fn first_clean_field(fields: &[StoredField], names: &[&str]) -> Option<String> {
    fields
        .iter()
        .find(|field| names.contains(&field.lookup_name.as_str()))
        .and_then(|field| clean_bibliography_value(&field.value))
}

fn clean_bibliography_value(value: &str) -> Option<String> {
    let mut text = value.trim();
    loop {
        let bytes = text.as_bytes();
        if bytes.len() >= 2
            && ((bytes[0] == b'{' && bytes[bytes.len() - 1] == b'}')
                || (bytes[0] == b'"' && bytes[bytes.len() - 1] == b'"'))
        {
            text = text[1..text.len() - 1].trim();
        } else {
            break;
        }
    }
    let text = text.split_whitespace().collect::<Vec<_>>().join(" ");
    if text.is_empty() { None } else { Some(text) }
}

fn shorten_names_to_width(names: &str, width: usize) -> String {
    let mut result = String::new();
    let mut parts = names.split(" and ").peekable();
    while let Some(raw_name) = parts.next() {
        if !result.is_empty() && result.chars().count() >= width {
            break;
        }
        let mut short_name = raw_name
            .split_once(", ")
            .map_or(raw_name, |(family, _)| family)
            .trim()
            .replace(['{', '}'], "");
        if short_name.split_whitespace().count() > 1 {
            short_name = short_name.split_whitespace().collect::<Vec<_>>().join(" ");
        }
        result.push_str(&short_name);
        if parts.peek().is_some() {
            result.push_str(", ");
        }
    }
    truncate_columns(&result, width)
}

fn fit_columns(value: &str, width: usize) -> String {
    let truncated = truncate_columns(value, width);
    let column_count = truncated.chars().count();
    if column_count < width {
        format!("{truncated}{}", " ".repeat(width - column_count))
    } else {
        truncated
    }
}

fn truncate_columns(value: &str, width: usize) -> String {
    value.chars().take(width).collect()
}

fn field_item(field: refbox_store::StoredField) -> EntryFieldItem {
    EntryFieldItem {
        raw_name: field.raw_name,
        lookup_name: field.lookup_name,
        value: field.value,
        source: field.source,
    }
}

fn resource_item(resource: refbox_store::StoredResource) -> ResourceItem {
    ResourceItem {
        key: resource.key,
        source_path: resource.source_path,
        owner_key: resource.owner_key,
        owner_source_path: resource.owner_source_path,
        kind: resource.kind,
        raw_name: resource.raw_name,
        lookup_name: resource.lookup_name,
        value: resource.value,
        inherited_from_key: resource.inherited_from_key,
        inherited_from_source_path: resource.inherited_from_source_path,
        source: resource.source,
    }
}

fn request_crossref_fields(
    include_crossrefs: Option<bool>,
    crossref_fields: Option<Vec<String>>,
) -> Vec<String> {
    if !include_crossrefs.unwrap_or(true) {
        return Vec::new();
    }

    crossref_fields
        .unwrap_or_else(default_crossref_fields)
        .into_iter()
        .map(|field| field.trim().to_ascii_lowercase())
        .filter(|field| !field.is_empty())
        .collect()
}

fn default_crossref_fields() -> Vec<String> {
    vec!["crossref".to_string()]
}

fn store_error(error: refbox_store::StoreError) -> JsonRpcError {
    JsonRpcError::new(JsonRpcErrorObject::internal_error(error.to_string()))
}

fn sync_error(error: refbox_index::SyncError<refbox_store::StoreError>) -> JsonRpcError {
    JsonRpcError::new(JsonRpcErrorObject::internal_error(error.to_string()))
}

fn invalid_path(path: String) -> JsonRpcError {
    JsonRpcError::new(JsonRpcErrorObject::domain(
        -32001,
        "invalid_path",
        format!("path is outside the configured bibliography corpus: {path}"),
    ))
}

fn unknown_key(key: String) -> JsonRpcError {
    JsonRpcError::new(JsonRpcErrorObject::domain(
        -32002,
        "unknown_key",
        format!("unknown entry key: {key}"),
    ))
}

fn stale_source_file(path: String) -> JsonRpcError {
    JsonRpcError::new(JsonRpcErrorObject::domain(
        -32004,
        "stale_source_file",
        format!("indexed source file is not readable: {path}"),
    ))
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::{Value, json};
    use std::fs;
    use std::time::{SystemTime, UNIX_EPOCH};

    #[test]
    fn daemon_sync_search_raw_and_source_workflows() {
        let project = TestProject::new("daemon-workflow");
        project.write(
            "refs/a.bib",
            "@article{a2020, title = {Alpha Search}, doi = {10.1000/alpha}}\n",
        );
        let mut daemon = Daemon::new(project.policy(), project.path("index.sqlite"))
            .expect("daemon should start");

        let sync = result(daemon.handle_request(request(METHOD_SYNC_FULL, json!({}))));
        assert_eq!(sync["indexed_entry_count"], 1);

        let search = result(daemon.handle_request(request(
            METHOD_SEARCH_ENTRIES,
            json!({ "query": "alpha", "limit": 500 }),
        )));
        assert_eq!(
            search["entries"].as_array().expect("entries array").len(),
            1
        );
        assert_eq!(search["entries"][0]["key"], "a2020");
        assert_eq!(search["entries"][0]["entry_type"], "article");
        assert_eq!(search["entries"][0]["fields"][0]["lookup_name"], "title");
        assert!(search["entries"][0]["fields"][0]["source"].is_object());
        assert_eq!(search["entries"][0]["resources"][0]["kind"], "doi");

        let lightweight_search = result(daemon.handle_request(request(
            METHOD_SEARCH_ENTRIES,
            json!({
                "query": "alpha",
                "limit": 500,
                "include_resources": false,
                "include_field_sources": false,
            }),
        )));
        assert_eq!(lightweight_search["entries"][0]["key"], "a2020");
        assert!(lightweight_search["entries"][0].get("resources").is_none());
        assert!(
            lightweight_search["entries"][0]["fields"][0]
                .get("source")
                .is_none()
        );
        assert!(
            lightweight_search["entries"][0]
                .get("completion_display")
                .is_none()
        );

        let completion_search = result(daemon.handle_request(request(
            METHOD_SEARCH_ENTRIES,
            json!({
                "query": "alpha",
                "limit": 500,
                "include_resources": false,
                "include_fields": false,
                "include_field_sources": false,
                "include_completion_display": true,
            }),
        )));
        assert!(completion_search["entries"][0].get("fields").is_none());
        assert!(completion_search["entries"][0].get("resources").is_none());
        assert!(
            completion_search["entries"][0]["completion_display"]["main"]
                .as_str()
                .expect("completion main display")
                .contains("Alpha Search")
        );
        assert!(
            completion_search["entries"][0]["completion_display"]["suffix"]
                .as_str()
                .expect("completion suffix display")
                .contains("a2020")
        );

        let listed = result(daemon.handle_request(request(
            METHOD_LIST_ENTRIES,
            json!({ "limit": 1, "offset": 0 }),
        )));
        assert_eq!(listed["entries"][0]["key"], "a2020");
        assert_eq!(listed["entries"][0]["fields"][0]["lookup_name"], "title");

        let resources = result(
            daemon.handle_request(request(METHOD_RESOURCES_BY_KEY, json!({ "key": "a2020" }))),
        );
        assert_eq!(resources["resources"][0]["value"], "10.1000/alpha");

        let resources_for_keys = result(daemon.handle_request(request(
            METHOD_RESOURCES_BY_KEYS,
            json!({ "keys": ["a2020"], "limit_per_key": 1 }),
        )));
        assert_eq!(resources_for_keys["resources"][0]["kind"], "doi");

        let raw =
            result(daemon.handle_request(request(METHOD_RAW_ENTRY, json!({ "key": "a2020" }))));
        assert!(
            raw["raw"]
                .as_str()
                .expect("raw string")
                .contains("@article")
        );

        let source = result(
            daemon.handle_request(request(METHOD_SOURCE_LOCATION, json!({ "key": "a2020" }))),
        );
        assert_eq!(source["source"]["start"]["line"], 1);

        let status = result(daemon.handle_request(request(METHOD_STATUS, json!({}))));
        assert_eq!(status["counts"]["entry_count"], 1);
    }

    #[test]
    fn daemon_close_keys_uses_edit_distance() {
        let project = TestProject::new("daemon-close-keys");
        project.write(
            "refs/main.bib",
            "@article{alpha2020, title = {Alpha}}\n\
             @article{alphi2020, title = {Typo}}\n\
             @article{omega2020, title = {Far}}\n",
        );
        let mut daemon = Daemon::new(project.policy(), project.path("index.sqlite"))
            .expect("daemon should start");

        result(daemon.handle_request(request(METHOD_SYNC_FULL, json!({}))));
        let close = result(daemon.handle_request(request(
            METHOD_CLOSE_KEYS,
            json!({
                "key": "alpha2020",
                "max_distance": 1,
                "limit": 10,
            }),
        )));
        assert_eq!(close["keys"], json!(["alphi2020"]));
    }

    #[test]
    fn daemon_exact_key_lookup_uses_first_indexed_duplicate() {
        let project = TestProject::new("daemon-errors");
        let first = project.write("refs/a.bib", "@article{dup2020, title = {First}}\n");
        project.write("refs/b.bib", "@book{dup2020, title = {Second}}\n");
        let mut daemon = Daemon::new(project.policy(), project.path("index.sqlite"))
            .expect("daemon should start");
        result(daemon.handle_request(request(METHOD_SYNC_FULL, json!({}))));

        let first_duplicate = result(
            daemon.handle_request(request(METHOD_ENTRY_BY_KEY, json!({ "key": "dup2020" }))),
        );
        assert_eq!(
            first_duplicate["source_path"],
            first.to_string_lossy().as_ref()
        );

        let disambiguated = result(daemon.handle_request(request(
            METHOD_ENTRY_BY_KEY,
            json!({ "key": "dup2020", "source_path": first.to_string_lossy() }),
        )));
        assert_eq!(disambiguated["key"], "dup2020");

        fs::remove_file(&first).expect("source fixture should delete");
        let stale = daemon.handle_request(request(
            METHOD_SOURCE_LOCATION,
            json!({ "key": "dup2020", "source_path": first.to_string_lossy() }),
        ));
        assert_eq!(
            stale.error.expect("expected error").data.expect("data")["kind"],
            "stale_source_file"
        );

        let unknown = daemon.handle_request(request(METHOD_RAW_ENTRY, json!({ "key": "none" })));
        assert_eq!(
            unknown.error.expect("expected error").data.expect("data")["kind"],
            "unknown_key"
        );
    }

    #[test]
    fn daemon_treats_local_bibliographies_as_scoped_additions() {
        let project = TestProject::new("daemon-local-bibliography");
        project.write(
            "refs/global.bib",
            "@article{global2020, title = {Shared Scope Signal}}\n",
        );
        let local = project.write(
            "doc/local.bib",
            "@article{local2020, title = {Shared Scope Signal}}\n",
        );
        let local = local.to_string_lossy().to_string();
        let policy = DiscoveryPolicy::new(vec![project.path("refs")], Vec::new());
        let mut daemon =
            Daemon::new(policy, project.path("index.sqlite")).expect("daemon should start");

        result(daemon.handle_request(request(METHOD_SYNC_FULL, json!({}))));
        result(daemon.handle_request(request(
            METHOD_SYNC_FILE,
            json!({ "path": local.clone(), "explicit": true }),
        )));

        let default_search = result(daemon.handle_request(request(
            METHOD_SEARCH_ENTRIES,
            json!({ "query": "shared", "limit": 10 }),
        )));
        assert_eq!(
            default_search["entries"].as_array().expect("entries").len(),
            1
        );
        assert_eq!(default_search["entries"][0]["key"], "global2020");

        let local_only = result(daemon.handle_request(request(
            METHOD_SEARCH_ENTRIES,
            json!({
                "query": "shared",
                "limit": 10,
                "source_paths": [local.clone()],
            }),
        )));
        assert_eq!(local_only["entries"].as_array().expect("entries").len(), 1);
        assert_eq!(local_only["entries"][0]["key"], "local2020");

        let configured_plus_local = result(daemon.handle_request(request(
            METHOD_SEARCH_ENTRIES,
            json!({
                "query": "shared",
                "limit": 10,
                "source_paths": [local.clone()],
                "include_configured_sources": true,
            }),
        )));
        assert_eq!(
            configured_plus_local["entries"]
                .as_array()
                .expect("entries")
                .iter()
                .map(|entry| entry["key"].as_str().expect("key"))
                .collect::<Vec<_>>(),
            vec!["global2020", "local2020"]
        );
    }

    #[test]
    fn daemon_resolves_resource_files_in_rust() {
        let project = TestProject::new("daemon-resource-files");
        let library = project.path("library");
        let declared = project.write("library/declared.pdf", "");
        let uppercase_declared = project.write("library/declared.PDF", "");
        let nested_declared = project.write("library/nested/declared.pdf", "");
        project.write("library/declared.txt", "");
        let keyed = project.write("library/smith2020.pdf", "");
        let keyed_uppercase = project.write("library/smith2020.PDF", "");
        let keyed_prefix = project.write("library/smith2020extra.pdf", "");
        let keyed_extra = project.write("library/nested/smith2020-extra.pdf", "");
        project.write("library/nested/smith2020-extra.html", "");
        let mut daemon = Daemon::new(project.policy(), project.path("index.sqlite"))
            .expect("daemon should start");

        let resolved = result(daemon.handle_request(request(
            METHOD_RESOLVE_FILES,
            json!({
                "files": ["declared.pdf"],
                "roots": [library],
                "recursive": true,
                "extensions": ["pdf"],
            }),
        )));
        assert_eq!(
            resolved["files"],
            json!([
                declared.to_string_lossy(),
                nested_declared.to_string_lossy()
            ])
        );

        let uppercase = result(daemon.handle_request(request(
            METHOD_RESOLVE_FILES,
            json!({
                "files": ["declared.PDF"],
                "roots": [library],
                "recursive": true,
                "extensions": ["PDF"],
            }),
        )));
        assert_eq!(
            uppercase["files"],
            json!([uppercase_declared.to_string_lossy()])
        );

        let absolute = result(daemon.handle_request(request(
            METHOD_RESOLVE_FILES,
            json!({
                "files": [declared.to_string_lossy()],
                "roots": [],
                "extensions": ["pdf"],
            }),
        )));
        assert_eq!(absolute["files"], json!([declared.to_string_lossy()]));

        daemon.file_lookup_cache.clear();
        let cache_only_resolved = result(daemon.handle_request(request(
            METHOD_RESOLVE_FILES,
            json!({
                "files": ["declared.pdf"],
                "roots": [project.path("library")],
                "recursive": true,
                "extensions": ["pdf"],
                "cache_only": true,
            }),
        )));
        assert_eq!(
            cache_only_resolved["files"],
            json!([declared.to_string_lossy()])
        );
        assert_eq!(daemon.file_lookup_cache.len(), 0);

        let cache_only_keyed_files = result(daemon.handle_request(request(
            METHOD_LIBRARY_FILES_BY_KEYS,
            json!({
                "keys": ["smith2020"],
                "roots": [project.path("library")],
                "recursive": true,
                "extensions": ["pdf"],
                "cache_only": true,
            }),
        )));
        assert_eq!(cache_only_keyed_files["files"], json!([]));
        assert_eq!(daemon.file_lookup_cache.len(), 0);

        let keyed_files = result(daemon.handle_request(request(
            METHOD_LIBRARY_FILES_BY_KEYS,
            json!({
                "keys": ["smith2020"],
                "roots": [project.path("library")],
                "recursive": true,
                "extensions": ["pdf"],
                "additional_separator": "-",
            }),
        )));
        assert_eq!(
            keyed_files["files"],
            json!([keyed.to_string_lossy(), keyed_extra.to_string_lossy()])
        );
        assert_eq!(daemon.file_lookup_cache.len(), 1);

        let keyed_uppercase_files = result(daemon.handle_request(request(
            METHOD_LIBRARY_FILES_BY_KEYS,
            json!({
                "keys": ["smith2020"],
                "roots": [project.path("library")],
                "recursive": true,
                "extensions": ["PDF"],
            }),
        )));
        assert_eq!(
            keyed_uppercase_files["files"],
            json!([keyed_uppercase.to_string_lossy()])
        );

        let keyed_prefix_files = result(daemon.handle_request(request(
            METHOD_LIBRARY_FILES_BY_KEYS,
            json!({
                "keys": ["smith2020"],
                "roots": [project.path("library")],
                "recursive": true,
                "extensions": ["pdf"],
                "additional_separator": "",
            }),
        )));
        assert_eq!(
            keyed_prefix_files["files"],
            json!([
                keyed.to_string_lossy(),
                keyed_prefix.to_string_lossy(),
                keyed_extra.to_string_lossy()
            ])
        );
        assert_eq!(daemon.file_lookup_cache.len(), 2);
    }

    #[test]
    fn daemon_rejects_invalid_file_paths() {
        let project = TestProject::new("daemon-invalid-path");
        let mut daemon = Daemon::new(project.policy(), project.path("index.sqlite"))
            .expect("daemon should start");
        let response = daemon.handle_request(request(
            METHOD_SYNC_FILE,
            json!({ "path": "../outside.bib" }),
        ));

        assert_eq!(
            response.error.expect("expected error").data.expect("data")["kind"],
            "invalid_path"
        );
    }

    fn request(method: &str, params: Value) -> JsonRpcRequest {
        JsonRpcRequest {
            jsonrpc: "2.0".to_string(),
            id: Some(Value::from(1)),
            method: method.to_string(),
            params,
        }
    }

    fn result(response: JsonRpcResponse) -> Value {
        if let Some(error) = response.error {
            panic!("unexpected error: {error}");
        }
        response.result.expect("response should contain result")
    }

    struct TestProject {
        root: PathBuf,
    }

    impl TestProject {
        fn new(name: &str) -> Self {
            let unique = SystemTime::now()
                .duration_since(UNIX_EPOCH)
                .expect("time should be after epoch")
                .as_nanos();
            let root =
                std::env::temp_dir().join(format!("refbox-{name}-{}-{unique}", std::process::id()));
            fs::create_dir_all(&root).expect("test root should create");
            Self { root }
        }

        fn path(&self, path: &str) -> PathBuf {
            self.root.join(path)
        }

        fn policy(&self) -> DiscoveryPolicy {
            DiscoveryPolicy::new(vec![self.root.clone()], Vec::new())
        }

        fn write(&self, path: &str, contents: &str) -> PathBuf {
            let path = self.path(path);
            if let Some(parent) = path.parent() {
                fs::create_dir_all(parent).expect("test parent should create");
            }
            fs::write(&path, contents).expect("test file should write");
            path
        }
    }

    impl Drop for TestProject {
        fn drop(&mut self) {
            let _ = fs::remove_dir_all(&self.root);
        }
    }
}
