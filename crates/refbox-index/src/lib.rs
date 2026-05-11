//! Bibliography discovery, parsing, and indexing.

use std::collections::{BTreeMap, BTreeSet};
use std::fmt;
use std::fs;
use std::path::{Path, PathBuf};
use std::time::UNIX_EPOCH;

use globset::{Glob, GlobSet, GlobSetBuilder};
use refbox_core::{
    BibliographyEntry, BibliographyField, BibliographyFile, DateParts, DerivedBibliographyStore,
    Diagnostic, DiagnosticSeverity, EntryDate, EntryId, FileParseStatus, IndexStoreCounts,
    IndexedFileMetadata, NameList, PersonName, RawEntry, ResourceField, SourcePosition, SourceSpan,
    normalize_lookup_name,
};
use sha2::{Digest, Sha256};

pub fn parse_bibliography_file(path: impl Into<String>, input: &str) -> BibliographyFile {
    Parser::new(path.into(), input).parse()
}

#[derive(Debug, Clone)]
pub struct DiscoveryPolicy {
    pub roots: Vec<PathBuf>,
    pub extensions: BTreeSet<String>,
    pub include_globs: Vec<String>,
    pub exclude_globs: Vec<String>,
    pub include_hidden: bool,
    pub ignored_directories: BTreeSet<String>,
}

impl DiscoveryPolicy {
    #[must_use]
    pub fn new(roots: Vec<PathBuf>) -> Self {
        Self {
            roots,
            ..Self::default()
        }
    }

    pub fn discover_files(&self) -> std::result::Result<Vec<PathBuf>, SyncError<()>> {
        self.discover_files_inner()
    }

    fn discover_files_inner<E>(&self) -> std::result::Result<Vec<PathBuf>, SyncError<E>> {
        let include_globs = build_glob_set::<E>(&self.include_globs)?;
        let exclude_globs = build_glob_set::<E>(&self.exclude_globs)?;
        let mut files = Vec::new();

        for root in &self.roots {
            self.walk_path(root, root, &include_globs, &exclude_globs, &mut files)?;
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

        if !path.exists()
            || !self
                .policy
                .is_eligible_file(path.parent().unwrap_or(path), path, &None, &None)
        {
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
        IndexedFileMetadata {
            path: self.path,
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

    Ok(FileSnapshot {
        path: path.to_string(),
        size_bytes: metadata.len(),
        modified_ns,
        content_hash: sha256_hex(&bytes),
        text: String::from_utf8_lossy(&bytes).into_owned(),
    })
}

fn sha256_hex(bytes: &[u8]) -> String {
    let digest = Sha256::digest(bytes);
    digest.iter().map(|byte| format!("{byte:02x}")).collect()
}

fn same_freshness(metadata: &IndexedFileMetadata, snapshot: &FileSnapshot) -> bool {
    metadata.size_bytes == snapshot.size_bytes
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

struct Parser<'input> {
    path: String,
    input: &'input str,
    byte: usize,
    line: u32,
    column: u32,
}

impl<'input> Parser<'input> {
    fn new(path: String, input: &'input str) -> Self {
        Self {
            path,
            input,
            byte: 0,
            line: 1,
            column: 0,
        }
    }

    fn parse(mut self) -> BibliographyFile {
        let mut file = BibliographyFile::new(self.path.clone());

        while !self.is_eof() {
            if self.peek() == Some('@') {
                self.parse_command(&mut file);
            } else {
                self.bump();
            }
        }

        file
    }

    fn parse_command(&mut self, file: &mut BibliographyFile) {
        let command_start = self.position();
        let command_start_byte = self.byte;
        self.bump();
        self.skip_whitespace();

        let entry_type_start = self.byte;
        while self.peek().is_some_and(is_type_char) {
            self.bump();
        }
        let raw_entry_type = self.input[entry_type_start..self.byte].trim().to_string();

        if raw_entry_type.is_empty() {
            file.diagnostics.push(self.file_diagnostic(
                DiagnosticSeverity::Error,
                "missing-entry-type",
                "entry command is missing its type",
                command_start,
            ));
            self.recover_to_next_command(command_start_byte + 1);
            return;
        }

        self.skip_whitespace();
        let Some(open) = self.peek() else {
            file.diagnostics.push(self.file_diagnostic(
                DiagnosticSeverity::Error,
                "missing-entry-body",
                "entry command ended before its body",
                command_start,
            ));
            return;
        };
        let Some(close) = matching_close_delimiter(open) else {
            file.diagnostics.push(self.file_diagnostic(
                DiagnosticSeverity::Error,
                "missing-entry-body",
                "entry command is missing a braced or parenthesized body",
                command_start,
            ));
            self.recover_to_next_command(command_start_byte + 1);
            return;
        };
        self.bump();

        match normalize_lookup_name(&raw_entry_type).as_str() {
            "comment" | "preamble" | "string" => {
                if !self.skip_enclosed_command(open, close) {
                    file.diagnostics.push(self.file_diagnostic(
                        DiagnosticSeverity::Error,
                        "unclosed-command",
                        "command body was not closed",
                        command_start,
                    ));
                }
            }
            _ => {
                if let Some(entry) = self.parse_entry(
                    command_start,
                    command_start_byte,
                    raw_entry_type,
                    close,
                    &mut file.diagnostics,
                ) {
                    file.entries.push(entry);
                }
            }
        }
    }

    fn parse_entry(
        &mut self,
        command_start: SourcePosition,
        command_start_byte: usize,
        raw_entry_type: String,
        close: char,
        file_diagnostics: &mut Vec<Diagnostic>,
    ) -> Option<BibliographyEntry> {
        self.skip_whitespace();
        let key_start = self.position();
        let key_start_byte = self.byte;

        while let Some(ch) = self.peek() {
            if ch == ',' || ch == close {
                break;
            }
            self.bump();
        }

        let key = self.input[key_start_byte..self.byte].trim().to_string();
        if key.is_empty() {
            file_diagnostics.push(self.file_diagnostic(
                DiagnosticSeverity::Error,
                "missing-entry-key",
                "entry is missing its key",
                key_start,
            ));
            self.recover_to_entry_boundary(close);
            return None;
        }

        let id = EntryId::new(self.path.clone(), key);
        let mut diagnostics = Vec::new();
        let mut fields = Vec::new();

        match self.peek() {
            Some(',') => {
                self.bump();
                fields = self.parse_fields(close, &id, &mut diagnostics);
            }
            Some(ch) if ch == close => {
                diagnostics.push(self.entry_diagnostic(
                    DiagnosticSeverity::Warning,
                    "missing-key-field-separator",
                    "entry key is not followed by a comma",
                    &id,
                    self.position(),
                ));
                self.bump();
            }
            None => diagnostics.push(self.entry_diagnostic(
                DiagnosticSeverity::Error,
                "unclosed-entry",
                "entry ended before its closing delimiter",
                &id,
                command_start,
            )),
            _ => {
                diagnostics.push(self.entry_diagnostic(
                    DiagnosticSeverity::Error,
                    "missing-key-field-separator",
                    "entry key is not followed by a comma",
                    &id,
                    self.position(),
                ));
                self.recover_to_entry_boundary(close);
            }
        }

        let entry_end = self.position();
        let raw_text = self.input[command_start_byte..self.byte].to_string();
        let names = name_lists_from_fields(&fields);
        let dates = dates_from_fields(&fields);
        let resources = fields
            .iter()
            .filter_map(ResourceField::from_field)
            .collect::<Vec<_>>();

        Some(BibliographyEntry {
            id,
            entry_type: normalize_lookup_name(&raw_entry_type),
            raw: RawEntry {
                text: raw_text,
                source: self.span_between(command_start, entry_end),
            },
            fields,
            names,
            dates,
            resources,
            diagnostics,
        })
    }

    fn parse_fields(
        &mut self,
        close: char,
        id: &EntryId,
        diagnostics: &mut Vec<Diagnostic>,
    ) -> Vec<BibliographyField> {
        let mut fields = Vec::new();

        loop {
            self.skip_field_padding();

            if self.is_eof() {
                diagnostics.push(self.entry_diagnostic(
                    DiagnosticSeverity::Error,
                    "unclosed-entry",
                    "entry ended before its closing delimiter",
                    id,
                    self.position(),
                ));
                break;
            }

            if self.starts_new_command() {
                diagnostics.push(self.entry_diagnostic(
                    DiagnosticSeverity::Error,
                    "unclosed-entry",
                    "entry appears to end before its closing delimiter",
                    id,
                    self.position(),
                ));
                break;
            }

            if self.peek() == Some(close) {
                self.bump();
                break;
            }

            let field_start = self.position();
            let field_name_start = self.byte;
            if !self.peek().is_some_and(is_field_name_start_char) {
                diagnostics.push(self.entry_diagnostic(
                    DiagnosticSeverity::Error,
                    "expected-field-name",
                    "expected a field name",
                    id,
                    field_start,
                ));
                self.recover_to_field_boundary(close);
                continue;
            }

            while self.peek().is_some_and(is_field_name_char) {
                self.bump();
            }
            let raw_name = self.input[field_name_start..self.byte].to_string();

            self.skip_whitespace();
            if self.peek() != Some('=') {
                diagnostics.push(self.entry_diagnostic(
                    DiagnosticSeverity::Error,
                    "expected-field-equals",
                    "field name is not followed by '='",
                    id,
                    field_start,
                ));
                self.recover_to_field_boundary(close);
                continue;
            }
            self.bump();

            let value_start = self.position();
            let value_start_byte = self.byte;
            let value_finished = self.consume_field_value(close, id, diagnostics);
            let value_end = self.position();
            let value = self.input[value_start_byte..self.byte].trim().to_string();

            if value.is_empty() {
                diagnostics.push(self.entry_diagnostic(
                    DiagnosticSeverity::Warning,
                    "empty-field-value",
                    "field has an empty value",
                    id,
                    value_start,
                ));
            }

            fields.push(BibliographyField::new(
                raw_name,
                value,
                Some(self.span_between(field_start, value_end)),
            ));

            if !value_finished || self.starts_new_command() {
                if self.starts_new_command() {
                    diagnostics.push(self.entry_diagnostic(
                        DiagnosticSeverity::Error,
                        "unclosed-entry",
                        "entry appears to end before its closing delimiter",
                        id,
                        self.position(),
                    ));
                }
                break;
            }

            self.skip_whitespace();
            match self.peek() {
                Some(',') => {
                    self.bump();
                }
                Some(ch) if ch == close => {
                    self.bump();
                    break;
                }
                None => {
                    diagnostics.push(self.entry_diagnostic(
                        DiagnosticSeverity::Error,
                        "unclosed-entry",
                        "entry ended before its closing delimiter",
                        id,
                        self.position(),
                    ));
                    break;
                }
                _ => {
                    diagnostics.push(self.entry_diagnostic(
                        DiagnosticSeverity::Error,
                        "expected-field-boundary",
                        "field value is not followed by a comma or entry delimiter",
                        id,
                        self.position(),
                    ));
                    self.recover_to_field_boundary(close);
                }
            }
        }

        fields
    }

    fn consume_field_value(
        &mut self,
        close: char,
        id: &EntryId,
        diagnostics: &mut Vec<Diagnostic>,
    ) -> bool {
        loop {
            self.skip_whitespace();

            if self.is_eof() {
                diagnostics.push(self.entry_diagnostic(
                    DiagnosticSeverity::Error,
                    "unclosed-field-value",
                    "field value ended before a boundary",
                    id,
                    self.position(),
                ));
                return false;
            }

            if self.starts_new_command() {
                diagnostics.push(self.entry_diagnostic(
                    DiagnosticSeverity::Error,
                    "unclosed-field-value",
                    "field value appears to end before a boundary",
                    id,
                    self.position(),
                ));
                return false;
            }

            let ch = self.peek().expect("checked EOF above");
            if ch == ',' || ch == close {
                return true;
            }

            let atom_start = self.position();
            let atom_finished = match ch {
                '{' => self.consume_braced_atom(id, diagnostics, atom_start),
                '"' => self.consume_quoted_atom(id, diagnostics, atom_start),
                '#' => {
                    diagnostics.push(self.entry_diagnostic(
                        DiagnosticSeverity::Error,
                        "expected-value-atom",
                        "concatenation marker is missing a value atom",
                        id,
                        atom_start,
                    ));
                    self.bump();
                    false
                }
                _ => self.consume_bare_atom(close),
            };

            if !atom_finished {
                return false;
            }

            self.skip_whitespace();
            match self.peek() {
                Some('#') => {
                    self.bump();
                }
                Some(ch) if ch == ',' || ch == close => return true,
                None => return false,
                _ => {
                    diagnostics.push(self.entry_diagnostic(
                        DiagnosticSeverity::Error,
                        "expected-value-boundary",
                        "value atom is not followed by '#', a comma, or the entry delimiter",
                        id,
                        self.position(),
                    ));
                    self.recover_to_field_boundary(close);
                    return false;
                }
            }
        }
    }

    fn consume_braced_atom(
        &mut self,
        id: &EntryId,
        diagnostics: &mut Vec<Diagnostic>,
        atom_start: SourcePosition,
    ) -> bool {
        let mut depth = 0_u32;
        let mut escaped = false;

        while let Some(ch) = self.peek() {
            if depth > 0 && self.starts_new_command() {
                diagnostics.push(self.entry_diagnostic(
                    DiagnosticSeverity::Error,
                    "unclosed-braced-value",
                    "braced value appears to end before its closing brace",
                    id,
                    atom_start,
                ));
                return false;
            }

            self.bump();

            if escaped {
                escaped = false;
                continue;
            }
            if ch == '\\' {
                escaped = true;
                continue;
            }
            if ch == '{' {
                depth += 1;
            } else if ch == '}' {
                depth = depth.saturating_sub(1);
                if depth == 0 {
                    return true;
                }
            }
        }

        diagnostics.push(self.entry_diagnostic(
            DiagnosticSeverity::Error,
            "unclosed-braced-value",
            "braced value ended before its closing brace",
            id,
            atom_start,
        ));
        false
    }

    fn consume_quoted_atom(
        &mut self,
        id: &EntryId,
        diagnostics: &mut Vec<Diagnostic>,
        atom_start: SourcePosition,
    ) -> bool {
        self.bump();
        let mut brace_depth = 0_u32;
        let mut escaped = false;

        while let Some(ch) = self.peek() {
            if self.starts_new_command() {
                diagnostics.push(self.entry_diagnostic(
                    DiagnosticSeverity::Error,
                    "unclosed-quoted-value",
                    "quoted value appears to end before its closing quote",
                    id,
                    atom_start,
                ));
                return false;
            }

            self.bump();

            if escaped {
                escaped = false;
                continue;
            }
            if ch == '\\' {
                escaped = true;
                continue;
            }
            if ch == '{' {
                brace_depth += 1;
            } else if ch == '}' && brace_depth > 0 {
                brace_depth -= 1;
            } else if ch == '"' && brace_depth == 0 {
                return true;
            }
        }

        diagnostics.push(self.entry_diagnostic(
            DiagnosticSeverity::Error,
            "unclosed-quoted-value",
            "quoted value ended before its closing quote",
            id,
            atom_start,
        ));
        false
    }

    fn consume_bare_atom(&mut self, close: char) -> bool {
        let start = self.byte;

        while let Some(ch) = self.peek() {
            if ch.is_whitespace() || ch == ',' || ch == close || ch == '#' {
                break;
            }
            if self.starts_new_command() {
                break;
            }
            self.bump();
        }

        self.byte > start
    }

    fn skip_enclosed_command(&mut self, open: char, close: char) -> bool {
        let mut depth = 1_u32;
        let mut quoted = false;
        let mut escaped = false;

        while let Some(ch) = self.peek() {
            self.bump();

            if escaped {
                escaped = false;
                continue;
            }
            if ch == '\\' {
                escaped = true;
                continue;
            }
            if ch == '"' {
                quoted = !quoted;
                continue;
            }
            if quoted {
                continue;
            }
            if ch == open {
                depth += 1;
            } else if ch == close {
                depth = depth.saturating_sub(1);
                if depth == 0 {
                    return true;
                }
            }
        }

        false
    }

    fn skip_field_padding(&mut self) {
        loop {
            self.skip_whitespace();
            if self.peek() == Some(',') {
                self.bump();
            } else {
                break;
            }
        }
    }

    fn recover_to_field_boundary(&mut self, close: char) {
        let mut brace_depth = 0_u32;
        let mut quoted = false;
        let mut escaped = false;

        while let Some(ch) = self.peek() {
            if !quoted
                && brace_depth == 0
                && (ch == ',' || ch == close || self.starts_new_command())
            {
                return;
            }
            self.bump();

            if escaped {
                escaped = false;
                continue;
            }
            if ch == '\\' {
                escaped = true;
                continue;
            }
            if ch == '"' {
                quoted = !quoted;
                continue;
            }
            if quoted {
                continue;
            }
            if ch == '{' {
                brace_depth += 1;
            } else if ch == '}' && brace_depth > 0 {
                brace_depth -= 1;
            }
        }
    }

    fn recover_to_entry_boundary(&mut self, close: char) {
        let mut brace_depth = 0_u32;
        let mut quoted = false;
        let mut escaped = false;

        while let Some(ch) = self.peek() {
            if !quoted && brace_depth == 0 && ch == close {
                self.bump();
                return;
            }
            if !quoted && brace_depth == 0 && self.starts_new_command() {
                return;
            }
            self.bump();

            if escaped {
                escaped = false;
                continue;
            }
            if ch == '\\' {
                escaped = true;
                continue;
            }
            if ch == '"' {
                quoted = !quoted;
                continue;
            }
            if quoted {
                continue;
            }
            if ch == '{' {
                brace_depth += 1;
            } else if ch == '}' && brace_depth > 0 {
                brace_depth -= 1;
            }
        }
    }

    fn recover_to_next_command(&mut self, minimum_byte: usize) {
        while let Some(ch) = self.peek() {
            if ch == '@' && self.byte >= minimum_byte {
                return;
            }
            self.bump();
        }
    }

    fn skip_whitespace(&mut self) {
        while self.peek().is_some_and(char::is_whitespace) {
            self.bump();
        }
    }

    fn starts_new_command(&self) -> bool {
        self.peek() == Some('@') && self.column == 0
    }

    fn file_diagnostic(
        &self,
        severity: DiagnosticSeverity,
        code: impl Into<String>,
        message: impl Into<String>,
        start: SourcePosition,
    ) -> Diagnostic {
        Diagnostic::file(
            severity,
            code,
            message,
            self.path.clone(),
            Some(self.span_between(start, self.position())),
        )
    }

    fn entry_diagnostic(
        &self,
        severity: DiagnosticSeverity,
        code: impl Into<String>,
        message: impl Into<String>,
        id: &EntryId,
        start: SourcePosition,
    ) -> Diagnostic {
        Diagnostic::entry(
            severity,
            code,
            message,
            id.clone(),
            Some(self.span_between(start, self.position())),
        )
    }

    fn span_between(&self, start: SourcePosition, end: SourcePosition) -> SourceSpan {
        SourceSpan::new(self.path.clone(), start, end)
    }

    fn position(&self) -> SourcePosition {
        SourcePosition::new(self.byte as u64, self.line, self.column)
    }

    fn is_eof(&self) -> bool {
        self.byte >= self.input.len()
    }

    fn peek(&self) -> Option<char> {
        self.input[self.byte..].chars().next()
    }

    fn bump(&mut self) -> Option<char> {
        let ch = self.peek()?;
        self.byte += ch.len_utf8();
        if ch == '\n' {
            self.line += 1;
            self.column = 0;
        } else {
            self.column += 1;
        }
        Some(ch)
    }
}

fn matching_close_delimiter(open: char) -> Option<char> {
    match open {
        '{' => Some('}'),
        '(' => Some(')'),
        _ => None,
    }
}

fn is_type_char(ch: char) -> bool {
    ch.is_ascii_alphanumeric() || ch == '_' || ch == '-'
}

fn is_field_name_start_char(ch: char) -> bool {
    ch.is_ascii_alphabetic()
}

fn is_field_name_char(ch: char) -> bool {
    ch.is_ascii_alphanumeric() || ch == '_' || ch == '-'
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
            let raw = display_text_from_value(&field.value);
            NameList::new(
                field.raw_name.clone(),
                raw.clone(),
                person_names_from_value(&raw),
                field.source.clone(),
            )
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
            let raw = display_text_from_value(&field.value);
            EntryDate::new(
                field.raw_name.clone(),
                raw.clone(),
                date_parts_from_value(&raw),
                field.source.clone(),
            )
        })
        .collect()
}

fn person_names_from_value(value: &str) -> Vec<PersonName> {
    split_top_level_names(value)
        .into_iter()
        .filter_map(|name| person_name_from_text(name.trim()))
        .collect()
}

fn person_name_from_text(value: &str) -> Option<PersonName> {
    if value.is_empty() {
        return None;
    }

    if let Some((family, rest)) = value.split_once(',') {
        return Some(PersonName {
            given: split_name_words(rest),
            family: split_name_words(family),
            prefix: Vec::new(),
            suffix: Vec::new(),
            literal: None,
        });
    }

    let words = split_name_words(value);
    if words.len() <= 1 {
        return Some(PersonName {
            given: Vec::new(),
            family: words,
            prefix: Vec::new(),
            suffix: Vec::new(),
            literal: None,
        });
    }

    let family = words.last().cloned().into_iter().collect::<Vec<_>>();
    let given = words[..words.len() - 1].to_vec();

    Some(PersonName {
        given,
        family,
        prefix: Vec::new(),
        suffix: Vec::new(),
        literal: None,
    })
}

fn split_name_words(value: &str) -> Vec<String> {
    value
        .split_whitespace()
        .map(str::trim)
        .filter(|word| !word.is_empty())
        .map(strip_wrapping_braces)
        .map(ToOwned::to_owned)
        .collect()
}

fn split_top_level_names(value: &str) -> Vec<&str> {
    let mut names = Vec::new();
    let mut start = 0;
    let mut depth = 0_i32;
    let mut cursor = 0;

    while cursor < value.len() {
        let ch = value[cursor..].chars().next().expect("cursor is in bounds");

        if ch == '{' {
            depth += 1;
        } else if ch == '}' && depth > 0 {
            depth -= 1;
        } else if depth == 0 && value[cursor..].starts_with(" and ") {
            names.push(&value[start..cursor]);
            cursor += " and ".len();
            start = cursor;
            continue;
        }

        cursor += ch.len_utf8();
    }

    names.push(&value[start..]);
    names
}

fn date_parts_from_value(value: &str) -> DateParts {
    let mut parts = value
        .split(['-', '/'])
        .map(str::trim)
        .filter(|part| !part.is_empty());

    DateParts {
        year: parts.next().and_then(|part| part.parse::<i32>().ok()),
        month: parts.next().and_then(|part| part.parse::<u8>().ok()),
        day: parts.next().and_then(|part| part.parse::<u8>().ok()),
    }
}

fn display_text_from_value(value: &str) -> String {
    let trimmed = value.trim();
    let has_wrapping_braces =
        trimmed.starts_with('{') && trimmed.ends_with('}') && outer_braces_wrap(trimmed);
    let has_wrapping_quotes = trimmed.starts_with('"') && trimmed.ends_with('"');
    let unwrapped = if has_wrapping_braces || has_wrapping_quotes {
        &trimmed[1..trimmed.len() - 1]
    } else {
        trimmed
    };

    unwrapped.trim().to_string()
}

fn strip_wrapping_braces(value: &str) -> &str {
    let trimmed = value.trim();
    if trimmed.starts_with('{') && trimmed.ends_with('}') && outer_braces_wrap(trimmed) {
        &trimmed[1..trimmed.len() - 1]
    } else {
        trimmed
    }
}

fn outer_braces_wrap(value: &str) -> bool {
    let mut depth = 0_i32;
    let mut escaped = false;

    for (index, ch) in value.char_indices() {
        if escaped {
            escaped = false;
            continue;
        }
        if ch == '\\' {
            escaped = true;
            continue;
        }
        if ch == '{' {
            depth += 1;
        } else if ch == '}' {
            depth -= 1;
            if depth == 0 && index != value.len() - 1 {
                return false;
            }
        }
    }

    depth == 0
}
