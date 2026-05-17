//! Bibliography discovery, parsing, and indexing.

use std::collections::{BTreeMap, BTreeSet};
use std::fmt;
use std::fs;
use std::io::ErrorKind;
use std::path::{Path, PathBuf};
use std::time::UNIX_EPOCH;

use bibtex_parser::{
    Diagnostic as BibDiagnostic, DiagnosticSeverity as BibDiagnosticSeverity,
    DiagnosticTarget as BibDiagnosticTarget, ExpansionOptions, ParsedDocument, ParsedEntry,
    ParsedField, Parser as BibParser, SourceSpan as BibSourceSpan, UnresolvedVariablePolicy,
};
use globset::{Glob, GlobSet, GlobSetBuilder};
use refbox_core::{
    BibliographyEntry, BibliographyField, BibliographyFile, DateParts, DerivedBibliographyStore,
    Diagnostic, DiagnosticSeverity, EntryDate, EntryId, FileParseStatus, IndexStoreCounts,
    IndexedFileMetadata, IndexedFileOrigin, NameList, PersonName, RawEntry, ResourceField,
    SourcePosition, SourceSpan, compose_unicode_accents, normalize_lookup_name,
};
use sha2::{Digest, Sha256};

pub fn parse_bibliography_file(path: impl Into<String>, input: &str) -> BibliographyFile {
    let path = path.into();
    match BibParser::new()
        .tolerant()
        .capture_source()
        .preserve_raw()
        .parse_source(path.clone(), input)
    {
        Ok(document) => bibliography_file_from_document(path, input, &document),
        Err(error) => BibliographyFile {
            path: path.clone(),
            entries: Vec::new(),
            diagnostics: vec![Diagnostic::file(
                DiagnosticSeverity::Error,
                "parse-error",
                error.to_string(),
                path,
                None,
            )],
        },
    }
}

#[derive(Debug, Clone)]
pub struct DiscoveryPolicy {
    pub roots: Vec<PathBuf>,
    pub files: Vec<PathBuf>,
    pub extensions: BTreeSet<String>,
    pub include_globs: Vec<String>,
    pub exclude_globs: Vec<String>,
    pub include_hidden: bool,
    pub ignored_directories: BTreeSet<String>,
}

impl DiscoveryPolicy {
    #[must_use]
    pub fn new(roots: Vec<PathBuf>, files: Vec<PathBuf>) -> Self {
        Self {
            roots,
            files,
            ..Self::default()
        }
    }

    pub fn discover_files(&self) -> std::result::Result<Vec<PathBuf>, SyncError<()>> {
        self.discover_files_inner()
    }

    pub fn is_managed_file<E>(&self, path: &Path) -> std::result::Result<bool, SyncError<E>> {
        let include_globs = build_glob_set::<E>(&self.include_globs)?;
        let exclude_globs = build_glob_set::<E>(&self.exclude_globs)?;

        if self.files.iter().any(|file| file == path) {
            return Ok(true);
        }

        Ok(self.roots.iter().any(|root| {
            path.starts_with(root)
                && self.is_eligible_file(root, path, &include_globs, &exclude_globs)
        }))
    }

    #[must_use]
    pub fn contains_path(&self, path: &Path) -> bool {
        self.files.iter().any(|file| file == path)
            || self.roots.iter().any(|root| path.starts_with(root))
    }

    fn discover_files_inner<E>(&self) -> std::result::Result<Vec<PathBuf>, SyncError<E>> {
        let include_globs = build_glob_set::<E>(&self.include_globs)?;
        let exclude_globs = build_glob_set::<E>(&self.exclude_globs)?;
        let mut files = Vec::new();

        for root in &self.roots {
            self.walk_path(root, root, &include_globs, &exclude_globs, &mut files)?;
        }

        for file in &self.files {
            match fs::metadata(file) {
                Ok(metadata) if metadata.is_file() => files.push(file.to_path_buf()),
                Ok(_) => {}
                Err(error) if error.kind() == ErrorKind::NotFound => {}
                Err(error) => return Err(SyncError::Io(error)),
            }
        }

        let mut seen = BTreeSet::new();
        files.retain(|path| seen.insert(path.clone()));
        Ok(files)
    }

    fn walk_path<E>(
        &self,
        root: &Path,
        path: &Path,
        include_globs: &Option<GlobSet>,
        exclude_globs: &Option<GlobSet>,
        files: &mut Vec<PathBuf>,
    ) -> std::result::Result<(), SyncError<E>> {
        let metadata = fs::metadata(path).map_err(SyncError::Io)?;
        if metadata.is_file() {
            if self.is_eligible_file(root, path, include_globs, exclude_globs) {
                files.push(path.to_path_buf());
            }
            return Ok(());
        }
        if !metadata.is_dir() {
            return Ok(());
        }

        if path != root && self.should_skip_directory(path) {
            return Ok(());
        }

        let mut children = fs::read_dir(path)
            .map_err(SyncError::Io)?
            .collect::<std::result::Result<Vec<_>, _>>()
            .map_err(SyncError::Io)?;
        children.sort_by_key(|entry| entry.path());

        for child in children {
            self.walk_path(root, &child.path(), include_globs, exclude_globs, files)?;
        }

        Ok(())
    }

    fn should_skip_directory(&self, path: &Path) -> bool {
        let Some(name) = path.file_name().and_then(|name| name.to_str()) else {
            return false;
        };

        (!self.include_hidden && name.starts_with('.')) || self.ignored_directories.contains(name)
    }

    fn is_eligible_file(
        &self,
        root: &Path,
        path: &Path,
        include_globs: &Option<GlobSet>,
        exclude_globs: &Option<GlobSet>,
    ) -> bool {
        let relative = path.strip_prefix(root).unwrap_or(path);
        if !self.include_hidden && path_components_include_hidden(relative) {
            return false;
        }

        let extension = path
            .extension()
            .and_then(|extension| extension.to_str())
            .map(|extension| extension.to_ascii_lowercase());
        if !extension.is_some_and(|extension| self.extensions.contains(&extension)) {
            return false;
        }

        if exclude_globs
            .as_ref()
            .is_some_and(|globs| globs.is_match(relative) || globs.is_match(path))
        {
            return false;
        }

        include_globs
            .as_ref()
            .is_none_or(|globs| globs.is_match(relative) || globs.is_match(path))
    }
}

impl Default for DiscoveryPolicy {
    fn default() -> Self {
        Self {
            roots: Vec::new(),
            files: Vec::new(),
            extensions: ["bib", "bibtex"].into_iter().map(str::to_string).collect(),
            include_globs: Vec::new(),
            exclude_globs: Vec::new(),
            include_hidden: false,
            ignored_directories: ["target", ".git", ".hg", ".svn", "node_modules"]
                .into_iter()
                .map(str::to_string)
                .collect(),
        }
    }
}

#[derive(Debug, Clone)]
pub struct SyncEngine {
    policy: DiscoveryPolicy,
}

impl SyncEngine {
    #[must_use]
    pub fn new(policy: DiscoveryPolicy) -> Self {
        Self { policy }
    }

    pub fn sync_full<S>(
        &self,
        store: &mut S,
    ) -> std::result::Result<SyncStatus, SyncError<S::Error>>
    where
        S: DerivedBibliographyStore,
    {
        let discovered = self.policy.discover_files_inner::<S::Error>()?;
        let discovered_paths = discovered
            .iter()
            .map(|path| path_string(path.as_path()))
            .collect::<std::result::Result<BTreeSet<_>, _>>()?;
        let existing = store
            .indexed_file_metadata()
            .map_err(SyncError::Store)?
            .into_iter()
            .map(|metadata| (metadata.path.clone(), metadata))
            .collect::<BTreeMap<_, _>>();
        let mut status = SyncStatus {
            discovered_file_count: discovered.len(),
            ..SyncStatus::default()
        };

        store.begin_bulk_update().map_err(SyncError::Store)?;
        let sync_result = (|| {
            for (order, path) in discovered.into_iter().enumerate() {
                let path = path_string(&path)?;
                let snapshot = read_file_snapshot(&path)?;
                let source_order = source_order(order);
                status.latest_modified_ns =
                    max_optional(status.latest_modified_ns, snapshot.modified_ns);

                if existing
                    .get(&path)
                    .is_some_and(|metadata| same_freshness(metadata, &snapshot, source_order))
                {
                    status.skipped_file_count += 1;
                    continue;
                }

                let parsed = parse_bibliography_file(path.clone(), snapshot.text.as_str());
                let metadata = snapshot.into_metadata(&parsed, source_order);
                store
                    .upsert_file(&parsed, &metadata)
                    .map_err(SyncError::Store)?;
                status.changed_file_count += 1;
            }

            for path in existing.keys() {
                if !discovered_paths.contains(path) {
                    store.remove_file(path).map_err(SyncError::Store)?;
                    status.removed_file_count += 1;
                }
            }

            Ok(status)
        })();

        let mut status = match sync_result {
            Ok(status) => {
                store.finish_bulk_update().map_err(SyncError::Store)?;
                status
            }
            Err(error) => {
                let _ = store.cancel_bulk_update();
                return Err(error);
            }
        };

        apply_counts(store.index_counts().map_err(SyncError::Store)?, &mut status);
        Ok(status)
    }

    pub fn sync_file<S>(
        &self,
        store: &mut S,
        path: impl AsRef<Path>,
    ) -> std::result::Result<SyncStatus, SyncError<S::Error>>
    where
        S: DerivedBibliographyStore,
    {
        let path = path.as_ref();
        let mut status = SyncStatus::default();

        if !path.exists() || !self.policy.is_managed_file(path)? {
            store
                .remove_file(&path_string(path)?)
                .map_err(SyncError::Store)?;
            status.removed_file_count = 1;
            apply_counts(store.index_counts().map_err(SyncError::Store)?, &mut status);
            return Ok(status);
        }

        let path = path_string(path)?;
        let snapshot = read_file_snapshot(&path)?;
        let source_order = existing_source_order(store, &path).unwrap_or_default();
        status.discovered_file_count = 1;
        status.latest_modified_ns = snapshot.modified_ns;
        let parsed = parse_bibliography_file(path.clone(), snapshot.text.as_str());
        let metadata = snapshot.into_metadata(&parsed, source_order);
        store
            .upsert_file(&parsed, &metadata)
            .map_err(SyncError::Store)?;
        status.changed_file_count = 1;
        apply_counts(store.index_counts().map_err(SyncError::Store)?, &mut status);
        Ok(status)
    }

    pub fn sync_explicit_file<S>(
        &self,
        store: &mut S,
        path: impl AsRef<Path>,
    ) -> std::result::Result<SyncStatus, SyncError<S::Error>>
    where
        S: DerivedBibliographyStore,
    {
        let path = path.as_ref();
        if !path.exists() {
            return self.remove_file(store, path);
        }

        let path = path_string(path)?;
        let snapshot = read_file_snapshot(&path)?;
        let mut status = SyncStatus {
            discovered_file_count: 1,
            latest_modified_ns: snapshot.modified_ns,
            ..SyncStatus::default()
        };
        let parsed = parse_bibliography_file(path.clone(), snapshot.text.as_str());
        let metadata = snapshot.into_metadata_with_origin(&parsed, IndexedFileOrigin::Local, 0);
        store
            .upsert_file(&parsed, &metadata)
            .map_err(SyncError::Store)?;
        status.changed_file_count = 1;
        apply_counts(store.index_counts().map_err(SyncError::Store)?, &mut status);
        Ok(status)
    }

    pub fn remove_file<S>(
        &self,
        store: &mut S,
        path: impl AsRef<Path>,
    ) -> std::result::Result<SyncStatus, SyncError<S::Error>>
    where
        S: DerivedBibliographyStore,
    {
        store
            .remove_file(&path_string(path.as_ref())?)
            .map_err(SyncError::Store)?;
        let mut status = SyncStatus {
            removed_file_count: 1,
            ..SyncStatus::default()
        };
        apply_counts(store.index_counts().map_err(SyncError::Store)?, &mut status);
        Ok(status)
    }
}

#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct SyncStatus {
    pub discovered_file_count: usize,
    pub changed_file_count: usize,
    pub skipped_file_count: usize,
    pub removed_file_count: usize,
    pub indexed_file_count: usize,
    pub indexed_entry_count: usize,
    pub diagnostic_count: usize,
    pub latest_modified_ns: Option<i64>,
}

#[derive(Debug)]
pub enum SyncError<StoreError> {
    Io(std::io::Error),
    Glob(globset::Error),
    Store(StoreError),
    NonUtf8Path(PathBuf),
}

impl<StoreError: fmt::Display> fmt::Display for SyncError<StoreError> {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Self::Io(error) => write!(formatter, "{error}"),
            Self::Glob(error) => write!(formatter, "{error}"),
            Self::Store(error) => write!(formatter, "{error}"),
            Self::NonUtf8Path(path) => {
                write!(formatter, "path is not valid UTF-8: {}", path.display())
            }
        }
    }
}

impl<StoreError> std::error::Error for SyncError<StoreError> where
    StoreError: std::error::Error + 'static
{
}

struct FileSnapshot {
    path: String,
    size_bytes: u64,
    modified_ns: Option<i64>,
    content_hash: String,
    text: String,
}

impl FileSnapshot {
    fn into_metadata(self, file: &BibliographyFile, source_order: i64) -> IndexedFileMetadata {
        self.into_metadata_with_origin(file, IndexedFileOrigin::Configured, source_order)
    }

    fn into_metadata_with_origin(
        self,
        file: &BibliographyFile,
        origin: IndexedFileOrigin,
        source_order: i64,
    ) -> IndexedFileMetadata {
        IndexedFileMetadata {
            path: self.path,
            origin,
            source_order,
            size_bytes: self.size_bytes,
            modified_ns: self.modified_ns,
            content_hash: self.content_hash,
            parse_status: parse_status_for_file(file),
            entry_count: file.entries.len(),
            diagnostic_count: diagnostic_count(file),
        }
    }
}

fn build_glob_set<E>(patterns: &[String]) -> std::result::Result<Option<GlobSet>, SyncError<E>> {
    if patterns.is_empty() {
        return Ok(None);
    }

    let mut builder = GlobSetBuilder::new();
    for pattern in patterns {
        builder.add(Glob::new(pattern).map_err(SyncError::Glob)?);
    }
    Ok(Some(builder.build().map_err(SyncError::Glob)?))
}

fn path_components_include_hidden(path: &Path) -> bool {
    path.components().any(|component| {
        component
            .as_os_str()
            .to_str()
            .is_some_and(|component| component.starts_with('.') && component != ".")
    })
}

fn path_string<E>(path: &Path) -> std::result::Result<String, SyncError<E>> {
    path.to_str()
        .map(ToOwned::to_owned)
        .ok_or_else(|| SyncError::NonUtf8Path(path.to_path_buf()))
}

fn read_file_snapshot<E>(path: &str) -> std::result::Result<FileSnapshot, SyncError<E>> {
    let bytes = fs::read(path).map_err(SyncError::Io)?;
    let metadata = fs::metadata(path).map_err(SyncError::Io)?;
    let modified_ns = metadata
        .modified()
        .ok()
        .and_then(|modified| modified.duration_since(UNIX_EPOCH).ok())
        .and_then(|duration| i64::try_from(duration.as_nanos()).ok());

    let content_hash = sha256_hex(&bytes);
    let text = match String::from_utf8(bytes) {
        Ok(text) => text,
        Err(error) => String::from_utf8_lossy(error.as_bytes()).into_owned(),
    };

    Ok(FileSnapshot {
        path: path.to_string(),
        size_bytes: metadata.len(),
        modified_ns,
        content_hash,
        text,
    })
}

fn sha256_hex(bytes: &[u8]) -> String {
    let digest = Sha256::digest(bytes);
    let mut encoded = String::with_capacity(digest.len() * 2);
    for byte in digest {
        encoded.push(char::from(HEX_DIGITS[usize::from(byte >> 4)]));
        encoded.push(char::from(HEX_DIGITS[usize::from(byte & 0x0f)]));
    }
    encoded
}

const HEX_DIGITS: &[u8; 16] = b"0123456789abcdef";

fn source_order(order: usize) -> i64 {
    i64::try_from(order).unwrap_or(i64::MAX)
}

fn existing_source_order<S>(store: &S, path: &str) -> Option<i64>
where
    S: DerivedBibliographyStore,
{
    store
        .indexed_file_metadata()
        .ok()?
        .into_iter()
        .find(|metadata| metadata.path == path)
        .map(|metadata| metadata.source_order)
}

fn same_freshness(
    metadata: &IndexedFileMetadata,
    snapshot: &FileSnapshot,
    source_order: i64,
) -> bool {
    metadata.origin == IndexedFileOrigin::Configured
        && metadata.source_order == source_order
        && metadata.size_bytes == snapshot.size_bytes
        && metadata.modified_ns == snapshot.modified_ns
        && metadata.content_hash == snapshot.content_hash
}

fn parse_status_for_file(file: &BibliographyFile) -> FileParseStatus {
    if file.entries.is_empty() && !file.diagnostics.is_empty() {
        FileParseStatus::Failed
    } else if diagnostic_count(file) > 0 {
        FileParseStatus::Partial
    } else {
        FileParseStatus::Ok
    }
}

fn diagnostic_count(file: &BibliographyFile) -> usize {
    file.diagnostics.len()
        + file
            .entries
            .iter()
            .map(|entry| entry.diagnostics.len())
            .sum::<usize>()
}

fn apply_counts(counts: IndexStoreCounts, status: &mut SyncStatus) {
    status.indexed_file_count = counts.file_count;
    status.indexed_entry_count = counts.entry_count;
    status.diagnostic_count = counts.diagnostic_count;
}

fn max_optional(left: Option<i64>, right: Option<i64>) -> Option<i64> {
    match (left, right) {
        (Some(left), Some(right)) => Some(left.max(right)),
        (Some(left), None) => Some(left),
        (None, Some(right)) => Some(right),
        (None, None) => None,
    }
}

fn bibliography_file_from_document(
    path: String,
    input: &str,
    document: &ParsedDocument<'_>,
) -> BibliographyFile {
    let mut entries = document
        .entries()
        .iter()
        .map(|entry| bibliography_entry_from_parsed(&path, input, document, entry))
        .collect::<Vec<_>>();
    inherit_crossref_fields(&mut entries, detect_bibtex_dialect(input));
    let diagnostics = document
        .diagnostics()
        .iter()
        .filter(|diagnostic| diagnostic_targets_file(&diagnostic.target))
        .map(|diagnostic| file_diagnostic_from_parsed(&path, diagnostic))
        .collect::<Vec<_>>();

    BibliographyFile {
        path,
        entries,
        diagnostics,
    }
}

fn bibliography_entry_from_parsed(
    path: &str,
    input: &str,
    document: &ParsedDocument<'_>,
    entry: &ParsedEntry<'_>,
) -> BibliographyEntry {
    let id = EntryId::new(path, entry.key().to_string());
    let fields = entry
        .fields
        .iter()
        .map(|field| bibliography_field_from_parsed(path, document, field))
        .collect::<Vec<_>>();
    let names = name_lists_from_fields(&fields);
    let dates = dates_from_fields(&fields);
    let resources = fields
        .iter()
        .filter_map(ResourceField::from_field)
        .collect::<Vec<_>>();
    let diagnostics = entry
        .diagnostics
        .iter()
        .map(|diagnostic| entry_diagnostic_from_parsed(path, &id, diagnostic))
        .collect::<Vec<_>>();

    BibliographyEntry {
        id,
        entry_type: normalize_lookup_name(&entry.ty.to_string()),
        raw: RawEntry {
            text: entry_raw_text(input, entry),
            source: entry
                .source
                .map_or_else(|| file_start_span(path), |span| source_span(path, span)),
        },
        fields,
        names,
        dates,
        resources,
        diagnostics,
    }
}

fn bibliography_field_from_parsed(
    path: &str,
    document: &ParsedDocument<'_>,
    field: &ParsedField<'_>,
) -> BibliographyField {
    BibliographyField::new(
        field.name.as_ref(),
        field_value_text(document, field),
        field.source.map(|span| source_span(path, span)),
    )
}

fn name_lists_from_fields(fields: &[BibliographyField]) -> Vec<NameList> {
    fields
        .iter()
        .filter(|field| {
            matches!(
                field.lookup_name.as_str(),
                "author" | "editor" | "translator"
            )
        })
        .map(|field| {
            let raw = field.value.clone();
            let names = bibtex_parser::parse_names(&raw)
                .into_iter()
                .map(|name| PersonName {
                    given: name.given,
                    family: name.family,
                    prefix: name.prefix,
                    suffix: name.suffix,
                    literal: name.literal,
                })
                .collect();
            NameList::new(field.raw_name.as_str(), raw, names, field.source.clone())
        })
        .collect()
}

fn dates_from_fields(fields: &[BibliographyField]) -> Vec<EntryDate> {
    fields
        .iter()
        .filter(|field| {
            matches!(
                field.lookup_name.as_str(),
                "date" | "year" | "urldate" | "eventdate" | "origdate" | "issued"
            )
        })
        .map(|field| {
            let raw = field.value.clone();
            EntryDate::new(
                field.raw_name.as_str(),
                raw.clone(),
                date_parts_from_parser(&raw),
                field.source.clone(),
            )
        })
        .collect()
}

fn date_parts_from_parser(value: &str) -> DateParts {
    bibtex_parser::parse_date_parts(value).map_or(
        DateParts {
            year: None,
            month: None,
            day: None,
        },
        |parts| DateParts {
            year: Some(parts.year),
            month: parts.month,
            day: parts.day,
        },
    )
}

fn entry_raw_text(input: &str, entry: &ParsedEntry<'_>) -> String {
    entry
        .raw
        .as_deref()
        .map(ToOwned::to_owned)
        .or_else(|| entry.source.and_then(|span| source_slice(input, span)))
        .unwrap_or_default()
}

fn field_value_text(document: &ParsedDocument<'_>, field: &ParsedField<'_>) -> String {
    let lookup_name = normalize_lookup_name(&field.name);
    if lookup_name == "month" {
        if let Some(raw) = bare_raw_value_text(field) {
            return raw;
        }
    }

    if field_postprocessing_excluded(&lookup_name) {
        return field.value.plain_text();
    }

    let text = document
        .expand_value(
            field.value.parsed(),
            ExpansionOptions {
                expand_strings: true,
                expand_months: false,
                unresolved_variables: UnresolvedVariablePolicy::Preserve,
            },
        )
        .unwrap_or_else(|_| field.value.plain_text());

    let text = if field_tex_cleanup_enabled(&lookup_name) {
        clean_tex_markup(&text)
    } else {
        text
    };

    collapse_display_whitespace(&text)
}

fn bare_raw_value_text(field: &ParsedField<'_>) -> Option<String> {
    let raw = field.value.raw_text()?.trim();
    raw.chars()
        .all(|character| character.is_ascii_alphanumeric() || matches!(character, '_' | '-'))
        .then(|| raw.to_string())
}

fn field_postprocessing_excluded(lookup_name: &str) -> bool {
    matches!(lookup_name, "file" | "url" | "doi")
}

fn field_tex_cleanup_enabled(lookup_name: &str) -> bool {
    matches!(lookup_name, "author" | "editor" | "title")
}

fn collapse_display_whitespace(text: &str) -> String {
    text.split_whitespace().collect::<Vec<_>>().join(" ")
}

fn clean_tex_markup(text: &str) -> String {
    compose_unicode_accents(&replace_tex_literals(&replace_tex_commands(text)))
}

fn replace_tex_commands(text: &str) -> String {
    let chars = text.chars().collect::<Vec<_>>();
    let mut cleaned = String::with_capacity(text.len());
    let mut index = 0;

    while index < chars.len() {
        if chars[index] != '\\' {
            cleaned.push(chars[index]);
            index += 1;
            continue;
        }

        let command_start = index;
        index += 1;
        if index >= chars.len() {
            cleaned.push('\\');
            break;
        }

        let name_start = index;
        if chars[index].is_alphabetic() {
            while index < chars.len() && chars[index].is_alphabetic() {
                index += 1;
            }
        } else {
            index += 1;
        }
        let command = chars[name_start..index].iter().collect::<String>();
        let after_name = index;
        while index < chars.len() && matches!(chars[index], ' ' | '\t') {
            index += 1;
        }

        let argument_start = index;
        while index < chars.len() && chars[index] == '[' {
            if let Some(close) = chars[index + 1..]
                .iter()
                .position(|character| *character == ']')
            {
                index += close + 2;
            } else {
                index = argument_start;
                break;
            }
        }

        let mut braced_argument: Option<String> = None;
        let mut letter_argument: Option<String> = None;
        if index < chars.len() && chars[index] == '{' {
            if let Some(close) = chars[index + 1..]
                .iter()
                .position(|character| *character == '}')
            {
                braced_argument = Some(
                    chars[index + 1..index + 1 + close]
                        .iter()
                        .collect::<String>(),
                );
                index += close + 2;
            } else {
                index = after_name;
            }
        } else {
            index = argument_start;
            if index < chars.len() && chars[index].is_alphabetic() {
                letter_argument = Some(chars[index].to_string());
                index += 1;
            } else {
                index = after_name;
            }
        }

        let argument = braced_argument
            .as_deref()
            .or(letter_argument.as_deref())
            .map(clean_tex_markup)
            .unwrap_or_default();
        if let Some(accent) = tex_accent_replacement(&command) {
            cleaned.push_str(&accented_tex_argument(&argument, accent));
        } else if let Some(replacement) = tex_command_replacement(&command, &argument) {
            cleaned.push_str(&replacement);
        } else if let Some(argument) = braced_argument {
            cleaned.push_str(&argument);
        } else {
            cleaned.extend(chars[command_start..index].iter());
        }
    }

    cleaned
}

fn accented_tex_argument(argument: &str, accent: char) -> String {
    let Some((first_index, first)) = argument.char_indices().next() else {
        return accent.to_string();
    };
    debug_assert_eq!(first_index, 0);

    let base = match first {
        '\u{0131}' => 'i',
        '\u{0237}' => 'j',
        _ => first,
    };
    let rest_start = first.len_utf8();
    let mut accented = String::new();
    accented.push(base);
    accented.push(accent);
    let mut accented = compose_unicode_accents(&accented);
    accented.push_str(&argument[rest_start..]);
    accented
}

fn tex_accent_replacement(command: &str) -> Option<char> {
    match command {
        "\"" => Some('\u{0308}'),
        "'" => Some('\u{0301}'),
        "." => Some('\u{0307}'),
        "=" => Some('\u{0304}'),
        "^" => Some('\u{0302}'),
        "`" => Some('\u{0300}'),
        "b" => Some('\u{0331}'),
        "c" => Some('\u{0327}'),
        "d" => Some('\u{0323}'),
        "H" => Some('\u{030B}'),
        "k" => Some('\u{0328}'),
        "U" => Some('\u{030E}'),
        "u" => Some('\u{0306}'),
        "v" => Some('\u{030C}'),
        "~" => Some('\u{0303}'),
        "|" => Some('\u{0313}'),
        "f" => Some('\u{0311}'),
        "G" | "C" => Some('\u{030F}'),
        "h" => Some('\u{0309}'),
        "r" => Some('\u{030A}'),
        _ => None,
    }
}

fn tex_command_replacement(command: &str, argument: &str) -> Option<String> {
    let replacement = match command {
        "ddag" | "textdaggerdbl" => "\u{2021}",
        "dag" | "textdagger" => "\u{2020}",
        "textpertenthousand" => "\u{2031}",
        "textperthousand" => "\u{2030}",
        "textquestiondown" => "\u{00BF}",
        "P" => "\u{00B6}",
        "textdollar" => "$",
        "S" => "\u{00A7}",
        "ldots" | "dots" | "textellipsis" => "\u{2026}",
        "textemdash" => "\u{2014}",
        "textendash" => "\u{2013}",
        "textbar" => "|",
        "AA" => "\u{00C5}",
        "AE" => "\u{00C6}",
        "DH" | "DJ" => "\u{00D0}",
        "L" => "\u{0141}",
        "SS" => "\u{1E9E}",
        "NG" => "\u{014A}",
        "OE" => "\u{0152}",
        "O" => "\u{00D8}",
        "TH" => "\u{00DE}",
        "aa" => "\u{00E5}",
        "ae" => "\u{00E6}",
        "dh" | "dj" => "\u{00F0}",
        "l" => "\u{0142}",
        "ss" => "\u{00DF}",
        "ng" => "\u{014B}",
        "oe" => "\u{0153}",
        "o" => "\u{00F8}",
        "th" => "\u{00FE}",
        "ij" => "ij",
        "i" => "\u{0131}",
        "j" => "\u{0237}",
        "textit" | "emph" | "textbf" => return Some(argument.to_string()),
        "textsc" => return Some(argument.to_uppercase()),
        _ => return None,
    };
    Some(format!("{replacement}{argument}"))
}

fn replace_tex_literals(text: &str) -> String {
    let chars = text.chars().collect::<Vec<_>>();
    let mut replaced = String::with_capacity(text.len());
    let mut index = 0;
    while index < chars.len() {
        let tail = &chars[index..];
        if starts_with_chars(tail, &['\\', '%']) {
            replaced.push('%');
            index += 2;
        } else if starts_with_chars(tail, &['\\', '&']) {
            replaced.push('&');
            index += 2;
        } else if starts_with_chars(tail, &['\\', '#']) {
            replaced.push('#');
            index += 2;
        } else if starts_with_chars(tail, &['\\', '$']) {
            replaced.push('$');
            index += 2;
        } else if starts_with_chars(tail, &['`', '`']) {
            replaced.push('\u{201C}');
            index += 2;
        } else if starts_with_chars(tail, &['\'', '\'']) {
            replaced.push('\u{201D}');
            index += 2;
        } else if chars[index] == '`' {
            replaced.push('\u{2018}');
            index += 1;
        } else if chars[index] == '\'' {
            replaced.push('\u{2019}');
            index += 1;
        } else if starts_with_chars(tail, &['-', '-', '-']) {
            replaced.push('\u{2014}');
            index += 3;
        } else if starts_with_chars(tail, &['-', '-']) {
            replaced.push('\u{2013}');
            index += 2;
        } else if matches!(chars[index], '{' | '}') {
            index += 1;
        } else {
            replaced.push(chars[index]);
            index += 1;
        }
    }
    replaced
}

fn starts_with_chars(text: &[char], prefix: &[char]) -> bool {
    text.len() >= prefix.len() && text[..prefix.len()] == *prefix
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum BibtexDialect {
    Bibtex,
    Biblatex,
}

fn detect_bibtex_dialect(input: &str) -> BibtexDialect {
    let tail_start = input.len().saturating_sub(3000);
    let tail = &input[tail_start..];
    if tail
        .to_ascii_lowercase()
        .contains("bibtex-dialect: biblatex")
    {
        BibtexDialect::Biblatex
    } else {
        BibtexDialect::Bibtex
    }
}

fn inherit_crossref_fields(entries: &mut [BibliographyEntry], dialect: BibtexDialect) {
    let key_to_index = entries
        .iter()
        .enumerate()
        .map(|(index, entry)| (entry.id.key.clone(), index))
        .collect::<BTreeMap<_, _>>();

    for index in 0..entries.len() {
        let mut visited = BTreeSet::new();
        inherit_entry_crossref_fields(index, &key_to_index, entries, dialect, &mut visited);
    }
}

fn inherit_entry_crossref_fields(
    index: usize,
    key_to_index: &BTreeMap<String, usize>,
    entries: &mut [BibliographyEntry],
    dialect: BibtexDialect,
    visited: &mut BTreeSet<usize>,
) {
    if !visited.insert(index) {
        return;
    }

    let Some(parent_key) = crossref_parent_key(&entries[index].fields) else {
        visited.remove(&index);
        return;
    };
    let Some(parent_index) = key_to_index.get(&parent_key).copied() else {
        visited.remove(&index);
        return;
    };

    inherit_entry_crossref_fields(parent_index, key_to_index, entries, dialect, visited);

    let source_type = entries[parent_index].entry_type.clone();
    let target_type = entries[index].entry_type.clone();
    let parent_fields = entries[parent_index].fields.clone();
    let mut existing_fields = entries[index]
        .fields
        .iter()
        .map(|field| field.lookup_name.clone())
        .collect::<BTreeSet<_>>();
    let mut inherited_fields = Vec::new();

    for field in parent_fields {
        let Some(target_name) =
            inherited_crossref_field_name(dialect, &source_type, &target_type, &field.lookup_name)
        else {
            continue;
        };
        if existing_fields.insert(target_name.clone()) {
            inherited_fields.push(inherited_field_with_name(field, &target_name));
        }
    }

    if !inherited_fields.is_empty() {
        entries[index].fields.extend(inherited_fields);
        entries[index].names = name_lists_from_fields(&entries[index].fields);
        entries[index].dates = dates_from_fields(&entries[index].fields);
    }

    visited.remove(&index);
}

fn inherited_crossref_field_name(
    dialect: BibtexDialect,
    source_type: &str,
    target_type: &str,
    source_field: &str,
) -> Option<String> {
    match dialect {
        BibtexDialect::Bibtex => Some(source_field.to_string()),
        BibtexDialect::Biblatex => {
            biblatex_inherited_field_name(source_type, target_type, source_field)
        }
    }
}

fn biblatex_inherited_field_name(
    source_type: &str,
    target_type: &str,
    source_field: &str,
) -> Option<String> {
    for rule in BIBLATEX_INHERITANCE_RULES {
        if type_list_contains(rule.source_types, source_type)
            && type_list_contains(rule.target_types, target_type)
        {
            for (source, target) in rule.fields {
                if source.eq_ignore_ascii_case(source_field) {
                    return target.map(str::to_string);
                }
            }
        }
    }

    if BIBLATEX_ALL_TYPE_EXCLUDED_FIELDS
        .iter()
        .any(|field| field.eq_ignore_ascii_case(source_field))
    {
        None
    } else {
        Some(source_field.to_string())
    }
}

fn type_list_contains(types: &[&str], entry_type: &str) -> bool {
    types
        .iter()
        .any(|candidate| candidate.eq_ignore_ascii_case(entry_type) || *candidate == "all")
}

fn inherited_field_with_name(mut field: BibliographyField, target_name: &str) -> BibliographyField {
    field.raw_name = target_name.to_string();
    field.lookup_name = normalize_lookup_name(target_name);
    field
}

struct BiblatexInheritanceRule {
    source_types: &'static [&'static str],
    target_types: &'static [&'static str],
    fields: &'static [(&'static str, Option<&'static str>)],
}

const BIBLATEX_ALL_TYPE_EXCLUDED_FIELDS: &[&str] = &[
    "ids",
    "crossref",
    "xref",
    "entryset",
    "entrysubtype",
    "execute",
    "label",
    "options",
    "presort",
    "related",
    "relatedoptions",
    "relatedstring",
    "relatedtype",
    "shorthand",
    "shorthandintro",
    "sortkey",
];

const MAIN_TITLE_INHERITANCE: &[(&str, Option<&str>)] = &[
    ("title", Some("maintitle")),
    ("subtitle", Some("mainsubtitle")),
    ("titleaddon", Some("maintitleaddon")),
    ("shorttitle", None),
    ("sorttitle", None),
    ("indextitle", None),
    ("indexsorttitle", None),
];

const BOOK_TITLE_INHERITANCE: &[(&str, Option<&str>)] = &[
    ("title", Some("booktitle")),
    ("subtitle", Some("booksubtitle")),
    ("titleaddon", Some("booktitleaddon")),
    ("shorttitle", None),
    ("sorttitle", None),
    ("indextitle", None),
    ("indexsorttitle", None),
];

const JOURNAL_TITLE_INHERITANCE: &[(&str, Option<&str>)] = &[
    ("title", Some("journaltitle")),
    ("subtitle", Some("journalsubtitle")),
    ("shorttitle", None),
    ("sorttitle", None),
    ("indextitle", None),
    ("indexsorttitle", None),
];

const AUTHOR_INHERITANCE: &[(&str, Option<&str>)] =
    &[("author", Some("author")), ("author", Some("bookauthor"))];

const BIBLATEX_INHERITANCE_RULES: &[BiblatexInheritanceRule] = &[
    BiblatexInheritanceRule {
        source_types: &["mvbook", "book"],
        target_types: &["inbook", "bookinbook", "suppbook"],
        fields: AUTHOR_INHERITANCE,
    },
    BiblatexInheritanceRule {
        source_types: &["mvbook"],
        target_types: &["book", "inbook", "bookinbook", "suppbook"],
        fields: MAIN_TITLE_INHERITANCE,
    },
    BiblatexInheritanceRule {
        source_types: &["mvcollection", "mvreference"],
        target_types: &[
            "collection",
            "reference",
            "incollection",
            "inreference",
            "suppcollection",
        ],
        fields: MAIN_TITLE_INHERITANCE,
    },
    BiblatexInheritanceRule {
        source_types: &["mvproceedings"],
        target_types: &["proceedings", "inproceedings"],
        fields: MAIN_TITLE_INHERITANCE,
    },
    BiblatexInheritanceRule {
        source_types: &["book"],
        target_types: &["inbook", "bookinbook", "suppbook"],
        fields: BOOK_TITLE_INHERITANCE,
    },
    BiblatexInheritanceRule {
        source_types: &["collection", "reference"],
        target_types: &["incollection", "inreference", "suppcollection"],
        fields: BOOK_TITLE_INHERITANCE,
    },
    BiblatexInheritanceRule {
        source_types: &["proceedings"],
        target_types: &["inproceedings"],
        fields: BOOK_TITLE_INHERITANCE,
    },
    BiblatexInheritanceRule {
        source_types: &["periodical"],
        target_types: &["article", "suppperiodical"],
        fields: JOURNAL_TITLE_INHERITANCE,
    },
];

fn crossref_parent_key(fields: &[BibliographyField]) -> Option<String> {
    fields
        .iter()
        .find(|field| field.lookup_name == "crossref")
        .and_then(|field| clean_crossref_key(&field.value))
}

fn clean_crossref_key(value: &str) -> Option<String> {
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
    (!text.is_empty()).then(|| text.to_string())
}

fn source_slice(input: &str, span: BibSourceSpan) -> Option<String> {
    input
        .get(span.byte_start..span.byte_end)
        .map(ToOwned::to_owned)
}

fn diagnostic_targets_file(target: &BibDiagnosticTarget) -> bool {
    matches!(
        target,
        BibDiagnosticTarget::File
            | BibDiagnosticTarget::Block(_)
            | BibDiagnosticTarget::FailedBlock(_)
    )
}

fn file_diagnostic_from_parsed(path: &str, diagnostic: &BibDiagnostic) -> Diagnostic {
    Diagnostic::file(
        diagnostic_severity(diagnostic.severity),
        diagnostic.code.as_str(),
        diagnostic.message.clone(),
        path,
        diagnostic.source.map(|span| source_span(path, span)),
    )
}

fn entry_diagnostic_from_parsed(
    path: &str,
    id: &EntryId,
    diagnostic: &BibDiagnostic,
) -> Diagnostic {
    Diagnostic::entry(
        diagnostic_severity(diagnostic.severity),
        diagnostic.code.as_str(),
        diagnostic.message.clone(),
        id.clone(),
        diagnostic.source.map(|span| source_span(path, span)),
    )
}

fn diagnostic_severity(severity: BibDiagnosticSeverity) -> DiagnosticSeverity {
    match severity {
        BibDiagnosticSeverity::Error => DiagnosticSeverity::Error,
        BibDiagnosticSeverity::Warning => DiagnosticSeverity::Warning,
        BibDiagnosticSeverity::Info => DiagnosticSeverity::Info,
    }
}

fn source_span(path: &str, span: BibSourceSpan) -> SourceSpan {
    SourceSpan::new(
        path,
        SourcePosition::new(
            u64_from_usize(span.byte_start),
            u32_from_usize(span.line),
            u32_from_usize(span.column),
        ),
        SourcePosition::new(
            u64_from_usize(span.byte_end),
            u32_from_usize(span.end_line),
            u32_from_usize(span.end_column),
        ),
    )
}

fn file_start_span(path: &str) -> SourceSpan {
    SourceSpan::new(
        path,
        SourcePosition::new(0, 1, 1),
        SourcePosition::new(0, 1, 1),
    )
}

fn u32_from_usize(value: usize) -> u32 {
    u32::try_from(value).unwrap_or(u32::MAX)
}

fn u64_from_usize(value: usize) -> u64 {
    u64::try_from(value).unwrap_or(u64::MAX)
}
