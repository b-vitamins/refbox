//! Bibliography discovery, parsing, and indexing.

use std::collections::{BTreeMap, BTreeSet};
use std::fmt;
use std::fs;
use std::io::ErrorKind;
use std::path::{Path, PathBuf};
use std::time::UNIX_EPOCH;

use bibtex_parser::{
    Diagnostic as BibDiagnostic, DiagnosticSeverity as BibDiagnosticSeverity,
    DiagnosticTarget as BibDiagnosticTarget, ParsedDocument, ParsedEntry, ParsedField,
    Parser as BibParser, SourceSpan as BibSourceSpan,
};
use globset::{Glob, GlobSet, GlobSetBuilder};
use refbox_core::{
    BibliographyEntry, BibliographyField, BibliographyFile, DateParts, DerivedBibliographyStore,
    Diagnostic, DiagnosticSeverity, EntryDate, EntryId, FileParseStatus, IndexStoreCounts,
    IndexedFileMetadata, IndexedFileOrigin, NameList, PersonName, RawEntry, ResourceField,
    SourcePosition, SourceSpan, normalize_lookup_name,
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

        files.sort();
        files.dedup();
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
            for path in discovered {
                let path = path_string(&path)?;
                let snapshot = read_file_snapshot(&path)?;
                status.latest_modified_ns =
                    max_optional(status.latest_modified_ns, snapshot.modified_ns);

                if existing
                    .get(&path)
                    .is_some_and(|metadata| same_freshness(metadata, &snapshot))
                {
                    status.skipped_file_count += 1;
                    continue;
                }

                let parsed = parse_bibliography_file(path.clone(), snapshot.text.as_str());
                let metadata = snapshot.into_metadata(&parsed);
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
        status.discovered_file_count = 1;
        status.latest_modified_ns = snapshot.modified_ns;
        let parsed = parse_bibliography_file(path.clone(), snapshot.text.as_str());
        let metadata = snapshot.into_metadata(&parsed);
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
        let metadata = snapshot.into_metadata_with_origin(&parsed, IndexedFileOrigin::Local);
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
    fn into_metadata(self, file: &BibliographyFile) -> IndexedFileMetadata {
        self.into_metadata_with_origin(file, IndexedFileOrigin::Configured)
    }

    fn into_metadata_with_origin(
        self,
        file: &BibliographyFile,
        origin: IndexedFileOrigin,
    ) -> IndexedFileMetadata {
        IndexedFileMetadata {
            path: self.path,
            origin,
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

fn same_freshness(metadata: &IndexedFileMetadata, snapshot: &FileSnapshot) -> bool {
    metadata.origin == IndexedFileOrigin::Configured
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
    let entries = document
        .entries()
        .iter()
        .map(|entry| bibliography_entry_from_parsed(&path, input, entry))
        .collect::<Vec<_>>();
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
    entry: &ParsedEntry<'_>,
) -> BibliographyEntry {
    let id = EntryId::new(path, entry.key().to_string());
    let fields = entry
        .fields
        .iter()
        .map(|field| bibliography_field_from_parsed(path, input, field))
        .collect::<Vec<_>>();
    let names = name_lists_from_parsed_fields(path, &entry.fields);
    let dates = dates_from_parsed_fields(path, &entry.fields);
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
    input: &str,
    field: &ParsedField<'_>,
) -> BibliographyField {
    BibliographyField::new(
        field.name.as_ref(),
        field_value_text(input, field),
        field.source.map(|span| source_span(path, span)),
    )
}

fn name_lists_from_parsed_fields(path: &str, fields: &[ParsedField<'_>]) -> Vec<NameList> {
    fields
        .iter()
        .filter(|field| {
            matches!(
                normalize_lookup_name(&field.name),
                ref name if name == "author" || name == "editor" || name == "translator"
            )
        })
        .map(|field| {
            let raw = field.value.plain_text();
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
            NameList::new(
                field.name.as_ref(),
                raw,
                names,
                field.source.map(|span| source_span(path, span)),
            )
        })
        .collect()
}

fn dates_from_parsed_fields(path: &str, fields: &[ParsedField<'_>]) -> Vec<EntryDate> {
    fields
        .iter()
        .filter(|field| {
            matches!(
                normalize_lookup_name(&field.name).as_str(),
                "date" | "year" | "urldate" | "eventdate" | "origdate" | "issued"
            )
        })
        .map(|field| {
            let raw = field.value.plain_text();
            EntryDate::new(
                field.name.as_ref(),
                raw.clone(),
                date_parts_from_parser(&raw),
                field.source.map(|span| source_span(path, span)),
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

fn field_value_text(input: &str, field: &ParsedField<'_>) -> String {
    field
        .value
        .raw_text()
        .map(ToOwned::to_owned)
        .or_else(|| {
            field
                .value
                .source
                .and_then(|span| source_slice(input, span))
        })
        .unwrap_or_else(|| field.value.plain_text())
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
