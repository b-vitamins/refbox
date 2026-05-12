use std::io::{self, BufRead, BufReader, Write};
use std::path::{Component, PathBuf};

use anyhow::{Context, Result};
use clap::{Parser, Subcommand};
use refbox_core::PingInfo;
use refbox_index::{DiscoveryPolicy, SyncEngine, SyncStatus};
use refbox_rpc::{
    DiagnosticItem, DiagnosticsResponse, DuplicateGroupItem, DuplicateGroupsResponse, EmptyParams,
    EntriesByKeysRequest, EntriesResponse, EntryByKeyRequest, EntryFieldItem, EntryItem,
    EntryRefItem, EntrySearchItem, IndexedFilesResponse, JsonRpcError, JsonRpcErrorObject,
    JsonRpcRequest, JsonRpcResponse, LimitRequest, METHOD_DIAGNOSTICS, METHOD_DUPLICATE_GROUPS,
    METHOD_ENTRIES_BY_KEYS, METHOD_ENTRY_BY_KEY, METHOD_INDEXED_FILES, METHOD_PING,
    METHOD_RAW_ENTRY, METHOD_SEARCH_ENTRIES, METHOD_SOURCE_LOCATION, METHOD_STATUS,
    METHOD_SYNC_FILE, METHOD_SYNC_FULL, RawEntryRequest, RawEntryResponse, SearchEntriesRequest,
    SearchEntriesResponse, SourceLocationRequest, SourceLocationResponse, StatusResponse,
    SyncFileRequest, SyncResponse, clamp_limit,
};
use refbox_store::{RefboxStore, StoredEntry};
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
        /// Root directory containing bibliography files.
        #[arg(long)]
        root: PathBuf,
        /// SQLite database path for the derived index.
        #[arg(long)]
        db: PathBuf,
    },
}

fn main() -> Result<()> {
    let cli = Cli::parse();
    match cli.command {
        Command::Serve { root, db } => serve(root, db),
    }
}

fn serve(root: PathBuf, db: PathBuf) -> Result<()> {
    let mut daemon = Daemon::new(root, db)?;
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

struct Daemon {
    root: PathBuf,
    db: PathBuf,
    store: RefboxStore,
    sync: SyncEngine,
}

impl Daemon {
    fn new(root: PathBuf, db: PathBuf) -> Result<Self> {
        let root = root
            .canonicalize()
            .with_context(|| format!("invalid root: {}", root.display()))?;
        let store = RefboxStore::open(&db)
            .with_context(|| format!("failed to open store: {}", db.display()))?;
        let sync = SyncEngine::new(DiscoveryPolicy::new(vec![root.clone()]));
        Ok(Self {
            root,
            db,
            store,
            sync,
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

    fn dispatch(
        &mut self,
        method: &str,
        params: serde_json::Value,
    ) -> std::result::Result<serde_json::Value, JsonRpcError> {
        match method {
            METHOD_PING => self.to_value(PingInfo {
                version: env!("CARGO_PKG_VERSION").to_owned(),
                root: self.root.display().to_string(),
                db: self.db.display().to_string(),
            }),
            METHOD_STATUS => {
                let _: EmptyParams = parse_params(params)?;
                self.to_value(StatusResponse {
                    root: self.root.display().to_string(),
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
                let path = self.resolve_request_path(&request.path)?;
                let status = self
                    .sync
                    .sync_file(&mut self.store, path)
                    .map_err(sync_error)?;
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
                let search_results = self
                    .store
                    .search(&request.query, limit)
                    .map_err(store_error)?;
                let entries = search_results
                    .into_iter()
                    .map(|entry| {
                        let fields = self
                            .store
                            .fields_for_entry(entry.entry_id)
                            .map_err(store_error)?
                            .into_iter()
                            .map(field_item)
                            .collect();
                        Ok(EntrySearchItem {
                            key: entry.key,
                            source_path: entry.file_path,
                            entry_type: entry.entry_type,
                            score: entry.score,
                            fields,
                        })
                    })
                    .collect::<std::result::Result<Vec<_>, JsonRpcError>>()?;
                self.to_value(SearchEntriesResponse { entries })
            }
            METHOD_ENTRY_BY_KEY => {
                let request: EntryByKeyRequest = parse_params(params)?;
                let entry = self.resolve_entry(&request.key, request.source_path.as_deref())?;
                self.to_value(entry_item(entry))
            }
            METHOD_ENTRIES_BY_KEYS => {
                let request: EntriesByKeysRequest = parse_params(params)?;
                let limit = clamp_limit(request.limit_per_key);
                let mut entries = Vec::new();
                for key in request.keys {
                    entries.extend(
                        self.store
                            .entries_by_key(&key)
                            .map_err(store_error)?
                            .into_iter()
                            .take(limit)
                            .map(entry_item),
                    );
                }
                self.to_value(EntriesResponse { entries })
            }
            METHOD_RAW_ENTRY => {
                let request: RawEntryRequest = parse_params(params)?;
                let entry = self.resolve_entry(&request.key, request.source_path.as_deref())?;
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
                let entry = self.resolve_entry(&request.key, request.source_path.as_deref())?;
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
                    .diagnostics()
                    .map_err(store_error)?
                    .into_iter()
                    .take(limit)
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
                let _: EmptyParams = parse_params(params)?;
                let groups = self
                    .store
                    .duplicate_groups()
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

    fn resolve_request_path(&self, path: &str) -> std::result::Result<PathBuf, JsonRpcError> {
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
            self.root.join(path)
        };

        if !path.starts_with(&self.root) {
            return Err(invalid_path(path.display().to_string()));
        }

        Ok(path)
    }

    fn resolve_entry(
        &self,
        key: &str,
        source_path: Option<&str>,
    ) -> std::result::Result<StoredEntry, JsonRpcError> {
        let mut entries = self.store.entries_by_key(key).map_err(store_error)?;
        if let Some(source_path) = source_path {
            entries.retain(|entry| entry.file_path == source_path);
        }

        match entries.len() {
            0 => Err(unknown_key(key.to_string())),
            1 => Ok(entries.remove(0)),
            _ => Err(ambiguous_key(key.to_string())),
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

fn entry_item(entry: StoredEntry) -> EntryItem {
    EntryItem {
        id: entry.id,
        key: entry.key,
        source_path: entry.file_path,
        entry_type: entry.entry_type,
        source: entry.source,
    }
}

fn field_item(field: refbox_store::StoredField) -> EntryFieldItem {
    EntryFieldItem {
        raw_name: field.raw_name,
        lookup_name: field.lookup_name,
        value: field.value,
        source: field.source,
    }
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
        format!("path is outside the configured root: {path}"),
    ))
}

fn unknown_key(key: String) -> JsonRpcError {
    JsonRpcError::new(JsonRpcErrorObject::domain(
        -32002,
        "unknown_key",
        format!("unknown entry key: {key}"),
    ))
}

fn ambiguous_key(key: String) -> JsonRpcError {
    JsonRpcError::new(JsonRpcErrorObject::domain(
        -32003,
        "ambiguous_key",
        format!("entry key matches multiple source files: {key}"),
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
        project.write("refs/a.bib", "@article{a2020, title = {Alpha Search}}\n");
        let mut daemon = Daemon::new(project.root.clone(), project.path("index.sqlite"))
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
    fn daemon_returns_stable_lookup_errors() {
        let project = TestProject::new("daemon-errors");
        let first = project.write("refs/a.bib", "@article{dup2020, title = {First}}\n");
        project.write("refs/b.bib", "@book{dup2020, title = {Second}}\n");
        let mut daemon = Daemon::new(project.root.clone(), project.path("index.sqlite"))
            .expect("daemon should start");
        result(daemon.handle_request(request(METHOD_SYNC_FULL, json!({}))));

        let ambiguous =
            daemon.handle_request(request(METHOD_ENTRY_BY_KEY, json!({ "key": "dup2020" })));
        assert_eq!(
            ambiguous.error.expect("expected error").data.expect("data")["kind"],
            "ambiguous_key"
        );

        let disambiguated = result(daemon.handle_request(request(
            METHOD_ENTRY_BY_KEY,
            json!({ "key": "dup2020", "source_path": first.to_string_lossy() }),
        )));
        assert_eq!(disambiguated["key"], "dup2020");

        let unknown = daemon.handle_request(request(METHOD_RAW_ENTRY, json!({ "key": "none" })));
        assert_eq!(
            unknown.error.expect("expected error").data.expect("data")["kind"],
            "unknown_key"
        );
    }

    #[test]
    fn daemon_rejects_invalid_file_paths() {
        let project = TestProject::new("daemon-invalid-path");
        let mut daemon = Daemon::new(project.root.clone(), project.path("index.sqlite"))
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
