use serde::{Deserialize, Serialize};
use std::collections::BTreeMap;
use unicode_normalization::UnicodeNormalization;

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct PingInfo {
    pub version: String,
    pub roots: Vec<String>,
    pub files: Vec<String>,
    pub db: String,
}

#[derive(Debug, Clone, PartialEq, Eq, PartialOrd, Ord, Serialize, Deserialize)]
pub struct EntryId {
    pub source_path: String,
    pub key: String,
}

impl EntryId {
    #[must_use]
    pub fn new(source_path: impl Into<String>, key: impl Into<String>) -> Self {
        Self {
            source_path: source_path.into(),
            key: key.into(),
        }
    }
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct BibliographyFile {
    pub path: String,
    #[serde(default)]
    pub entries: Vec<BibliographyEntry>,
    #[serde(default)]
    pub diagnostics: Vec<Diagnostic>,
}

impl BibliographyFile {
    #[must_use]
    pub fn new(path: impl Into<String>) -> Self {
        Self {
            path: path.into(),
            entries: Vec::new(),
            diagnostics: Vec::new(),
        }
    }
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct IndexedFileMetadata {
    pub path: String,
    pub origin: IndexedFileOrigin,
    pub source_order: i64,
    pub size_bytes: u64,
    pub modified_ns: Option<i64>,
    pub content_hash: String,
    pub parse_status: FileParseStatus,
    pub entry_count: usize,
    pub diagnostic_count: usize,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum IndexedFileOrigin {
    Configured,
    Local,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum FileParseStatus {
    Ok,
    Partial,
    Failed,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
pub struct IndexStoreCounts {
    pub file_count: usize,
    pub entry_count: usize,
    pub diagnostic_count: usize,
}

pub trait DerivedBibliographyStore {
    type Error;

    fn begin_bulk_update(&mut self) -> Result<(), Self::Error> {
        Ok(())
    }

    fn finish_bulk_update(&mut self) -> Result<(), Self::Error> {
        Ok(())
    }

    fn cancel_bulk_update(&mut self) -> Result<(), Self::Error> {
        Ok(())
    }

    fn indexed_file_metadata(&self) -> Result<Vec<IndexedFileMetadata>, Self::Error>;

    fn upsert_file(
        &mut self,
        file: &BibliographyFile,
        metadata: &IndexedFileMetadata,
    ) -> Result<(), Self::Error>;

    fn remove_file(&mut self, path: &str) -> Result<(), Self::Error>;

    fn index_counts(&self) -> Result<IndexStoreCounts, Self::Error>;
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct BibliographyEntry {
    pub id: EntryId,
    pub entry_type: String,
    pub raw: RawEntry,
    #[serde(default)]
    pub fields: Vec<BibliographyField>,
    #[serde(default)]
    pub names: Vec<NameList>,
    #[serde(default)]
    pub dates: Vec<EntryDate>,
    #[serde(default)]
    pub resources: Vec<ResourceField>,
    #[serde(default)]
    pub diagnostics: Vec<Diagnostic>,
}

impl BibliographyEntry {
    #[must_use]
    pub fn source_span(&self) -> &SourceSpan {
        &self.raw.source
    }
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct BibliographyField {
    pub raw_name: String,
    pub lookup_name: String,
    pub value: String,
    pub source: Option<SourceSpan>,
}

impl BibliographyField {
    #[must_use]
    pub fn new(
        raw_name: impl Into<String>,
        value: impl Into<String>,
        source: Option<SourceSpan>,
    ) -> Self {
        let raw_name = raw_name.into();

        Self {
            lookup_name: normalize_lookup_name(&raw_name),
            raw_name,
            value: value.into(),
            source,
        }
    }
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct NameList {
    pub raw_role: String,
    pub lookup_role: String,
    pub raw: String,
    #[serde(default)]
    pub names: Vec<PersonName>,
    pub source: Option<SourceSpan>,
}

impl NameList {
    #[must_use]
    pub fn new(
        raw_role: impl Into<String>,
        raw: impl Into<String>,
        names: Vec<PersonName>,
        source: Option<SourceSpan>,
    ) -> Self {
        let raw_role = raw_role.into();

        Self {
            lookup_role: normalize_lookup_name(&raw_role),
            raw_role,
            raw: raw.into(),
            names,
            source,
        }
    }
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct PersonName {
    #[serde(default)]
    pub given: Vec<String>,
    #[serde(default)]
    pub family: Vec<String>,
    #[serde(default)]
    pub prefix: Vec<String>,
    #[serde(default)]
    pub suffix: Vec<String>,
    pub literal: Option<String>,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct EntryDate {
    pub raw_field: String,
    pub lookup_field: String,
    pub raw: String,
    pub parts: DateParts,
    pub source: Option<SourceSpan>,
}

impl EntryDate {
    #[must_use]
    pub fn new(
        raw_field: impl Into<String>,
        raw: impl Into<String>,
        parts: DateParts,
        source: Option<SourceSpan>,
    ) -> Self {
        let raw_field = raw_field.into();

        Self {
            lookup_field: normalize_lookup_name(&raw_field),
            raw_field,
            raw: raw.into(),
            parts,
            source,
        }
    }
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct DateParts {
    pub year: Option<i32>,
    pub month: Option<u8>,
    pub day: Option<u8>,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct RawEntry {
    pub text: String,
    pub source: SourceSpan,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct SourceSpan {
    pub path: String,
    pub start: SourcePosition,
    pub end: SourcePosition,
}

impl SourceSpan {
    #[must_use]
    pub fn new(path: impl Into<String>, start: SourcePosition, end: SourcePosition) -> Self {
        Self {
            path: path.into(),
            start,
            end,
        }
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
pub struct SourcePosition {
    pub byte: u64,
    pub line: u32,
    pub column: u32,
}

impl SourcePosition {
    /// Creates a source position with a byte offset, 1-based line, and 1-based column.
    #[must_use]
    pub fn new(byte: u64, line: u32, column: u32) -> Self {
        Self { byte, line, column }
    }
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct ResourceField {
    pub kind: ResourceKind,
    pub raw_name: String,
    pub lookup_name: String,
    pub value: String,
    pub source: Option<SourceSpan>,
}

impl ResourceField {
    #[must_use]
    pub fn from_field(field: &BibliographyField) -> Option<Self> {
        Some(Self {
            kind: resource_kind_for_lookup_name(&field.lookup_name)?,
            raw_name: field.raw_name.clone(),
            lookup_name: field.lookup_name.clone(),
            value: field.value.clone(),
            source: field.source.clone(),
        })
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum ResourceKind {
    File,
    Url,
    Doi,
    Pmid,
    Pmcid,
    Isbn,
    Issn,
    Eprint,
    Arxiv,
    Crossref,
}

impl From<bibtex_parser::ResourceKind> for ResourceKind {
    fn from(kind: bibtex_parser::ResourceKind) -> Self {
        match kind {
            bibtex_parser::ResourceKind::File => Self::File,
            bibtex_parser::ResourceKind::Url => Self::Url,
            bibtex_parser::ResourceKind::Doi => Self::Doi,
            bibtex_parser::ResourceKind::Pmid => Self::Pmid,
            bibtex_parser::ResourceKind::Pmcid => Self::Pmcid,
            bibtex_parser::ResourceKind::Isbn => Self::Isbn,
            bibtex_parser::ResourceKind::Issn => Self::Issn,
            bibtex_parser::ResourceKind::Eprint => Self::Eprint,
            bibtex_parser::ResourceKind::Arxiv => Self::Arxiv,
            bibtex_parser::ResourceKind::Crossref => Self::Crossref,
        }
    }
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct Diagnostic {
    pub severity: DiagnosticSeverity,
    pub code: String,
    pub message: String,
    pub target: DiagnosticTarget,
    pub source: Option<SourceSpan>,
}

impl Diagnostic {
    #[must_use]
    pub fn file(
        severity: DiagnosticSeverity,
        code: impl Into<String>,
        message: impl Into<String>,
        path: impl Into<String>,
        source: Option<SourceSpan>,
    ) -> Self {
        Self {
            severity,
            code: code.into(),
            message: message.into(),
            target: DiagnosticTarget::File { path: path.into() },
            source,
        }
    }

    #[must_use]
    pub fn entry(
        severity: DiagnosticSeverity,
        code: impl Into<String>,
        message: impl Into<String>,
        id: EntryId,
        source: Option<SourceSpan>,
    ) -> Self {
        Self {
            severity,
            code: code.into(),
            message: message.into(),
            target: DiagnosticTarget::Entry { id },
            source,
        }
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum DiagnosticSeverity {
    Error,
    Warning,
    Info,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(tag = "kind", rename_all = "snake_case")]
pub enum DiagnosticTarget {
    File { path: String },
    Entry { id: EntryId },
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct KeyLookupRecord {
    pub key: String,
    pub entries: Vec<EntryId>,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct DuplicateKeyGroup {
    pub key: String,
    pub entries: Vec<EntryId>,
}

#[must_use]
pub fn normalize_lookup_name(name: &str) -> String {
    name.trim().to_ascii_lowercase()
}

#[must_use]
pub fn compose_unicode_accents(text: &str) -> String {
    text.nfc().collect()
}

#[must_use]
pub fn resource_kind_for_lookup_name(lookup_name: &str) -> Option<ResourceKind> {
    bibtex_parser::classify_resource_field(lookup_name).map(ResourceKind::from)
}

#[must_use]
pub fn key_lookup_records<'entry>(
    entries: impl IntoIterator<Item = &'entry BibliographyEntry>,
) -> Vec<KeyLookupRecord> {
    key_groups(entries)
        .into_iter()
        .map(|(key, entries)| KeyLookupRecord { key, entries })
        .collect()
}

#[must_use]
pub fn duplicate_key_groups<'entry>(
    entries: impl IntoIterator<Item = &'entry BibliographyEntry>,
) -> Vec<DuplicateKeyGroup> {
    key_groups(entries)
        .into_iter()
        .filter_map(|(key, entries)| {
            if entries.len() > 1 {
                Some(DuplicateKeyGroup { key, entries })
            } else {
                None
            }
        })
        .collect()
}

fn key_groups<'entry>(
    entries: impl IntoIterator<Item = &'entry BibliographyEntry>,
) -> Vec<(String, Vec<EntryId>)> {
    let mut by_key: BTreeMap<String, Vec<EntryId>> = BTreeMap::new();

    for entry in entries {
        by_key
            .entry(entry.id.key.clone())
            .or_default()
            .push(entry.id.clone());
    }

    by_key.into_iter().collect()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn entry_records_round_trip_through_json() {
        let source = span("refs/main.bib", 0, 1, 0, 96, 7, 1);
        let title =
            BibliographyField::new("Title", "Fast bibliography indexing", Some(source.clone()));
        let doi = BibliographyField::new("DOI", "10.1000/example", Some(source.clone()));
        let id = EntryId::new("refs/main.bib", "smith2020");

        let entry = BibliographyEntry {
            id: id.clone(),
            entry_type: "article".to_string(),
            raw: RawEntry {
                text: "@Article{smith2020,\n  Title = {Fast bibliography indexing}\n}".to_string(),
                source: source.clone(),
            },
            fields: vec![title, doi.clone()],
            names: vec![NameList::new(
                "author",
                "Smith, Jane",
                vec![PersonName {
                    given: vec!["Jane".to_string()],
                    family: vec!["Smith".to_string()],
                    prefix: Vec::new(),
                    suffix: Vec::new(),
                    literal: None,
                }],
                Some(source.clone()),
            )],
            dates: vec![EntryDate::new(
                "year",
                "2020",
                DateParts {
                    year: Some(2020),
                    month: None,
                    day: None,
                },
                Some(source.clone()),
            )],
            resources: vec![ResourceField::from_field(&doi).expect("DOI is resource-bearing")],
            diagnostics: vec![Diagnostic::entry(
                DiagnosticSeverity::Warning,
                "duplicate-field",
                "entry has a duplicate field",
                id,
                Some(source),
            )],
        };

        let encoded = serde_json::to_value(&entry).expect("entry should serialize");
        assert_eq!(encoded["fields"][0]["raw_name"], "Title");
        assert_eq!(encoded["fields"][0]["lookup_name"], "title");
        assert_eq!(encoded["resources"][0]["kind"], "doi");

        let decoded: BibliographyEntry =
            serde_json::from_value(encoded).expect("entry should deserialize");
        assert_eq!(decoded, entry);
    }

    #[test]
    fn duplicate_key_groups_preserve_each_entry_identity() {
        let entries = vec![
            entry("refs/a.bib", "knuth1984"),
            entry("refs/b.bib", "knuth1984"),
            entry("refs/a.bib", "lamport1994"),
        ];

        let lookup = key_lookup_records(&entries);
        assert_eq!(
            lookup,
            vec![
                KeyLookupRecord {
                    key: "knuth1984".to_string(),
                    entries: vec![
                        EntryId::new("refs/a.bib", "knuth1984"),
                        EntryId::new("refs/b.bib", "knuth1984"),
                    ],
                },
                KeyLookupRecord {
                    key: "lamport1994".to_string(),
                    entries: vec![EntryId::new("refs/a.bib", "lamport1994")],
                },
            ]
        );

        assert_eq!(
            duplicate_key_groups(&entries),
            vec![DuplicateKeyGroup {
                key: "knuth1984".to_string(),
                entries: vec![
                    EntryId::new("refs/a.bib", "knuth1984"),
                    EntryId::new("refs/b.bib", "knuth1984"),
                ],
            }]
        );
    }

    #[test]
    fn composes_common_latin_combining_accents() {
        assert_eq!(
            compose_unicode_accents(
                "Porra\u{0300}; Bogun\u{0303}a\u{0301}; Adamova\u{0301}; Tomas\u{030c}"
            ),
            "Porr\u{00e0}; Bogu\u{00f1}\u{00e1}; Adamov\u{00e1}; Toma\u{0161}"
        );
        assert_eq!(
            compose_unicode_accents("Schro\u{0308}dinger"),
            "Schr\u{00f6}dinger"
        );
    }

    #[test]
    fn diagnostics_can_target_files_or_entries() {
        let file_diagnostic = Diagnostic::file(
            DiagnosticSeverity::Error,
            "unclosed-entry",
            "entry is missing its closing brace",
            "refs/broken.bib",
            Some(span("refs/broken.bib", 14, 2, 0, 28, 2, 14)),
        );
        let entry_diagnostic = Diagnostic::entry(
            DiagnosticSeverity::Info,
            "partial-record",
            "entry was indexed with partial fields",
            EntryId::new("refs/broken.bib", "partial2020"),
            None,
        );

        assert_eq!(
            serde_json::to_value(&file_diagnostic).expect("diagnostic should serialize")["target"]
                ["kind"],
            "file"
        );
        assert_eq!(
            serde_json::to_value(&entry_diagnostic).expect("diagnostic should serialize")["target"]
                ["kind"],
            "entry"
        );
    }

    #[test]
    fn resource_fields_are_identified_by_normalized_name() {
        let known_resources = [
            ("file", ResourceKind::File),
            ("URL", ResourceKind::Url),
            ("doi", ResourceKind::Doi),
            ("pmid", ResourceKind::Pmid),
            ("pmcid", ResourceKind::Pmcid),
            ("isbn", ResourceKind::Isbn),
            ("issn", ResourceKind::Issn),
            ("eprint", ResourceKind::Eprint),
            ("arxiv", ResourceKind::Arxiv),
            ("crossref", ResourceKind::Crossref),
        ];

        for (raw_name, kind) in known_resources {
            let field = BibliographyField::new(raw_name, "value", None);
            let resource = ResourceField::from_field(&field).expect("field should be a resource");
            assert_eq!(resource.kind, kind);
            assert_eq!(resource.lookup_name, normalize_lookup_name(raw_name));
        }

        let title = BibliographyField::new("title", "Not a resource", None);
        assert!(ResourceField::from_field(&title).is_none());
    }

    fn entry(path: &str, key: &str) -> BibliographyEntry {
        let source = span(path, 0, 1, 0, 12, 1, 12);

        BibliographyEntry {
            id: EntryId::new(path, key),
            entry_type: "book".to_string(),
            raw: RawEntry {
                text: format!("@book{{{key}}}"),
                source,
            },
            fields: Vec::new(),
            names: Vec::new(),
            dates: Vec::new(),
            resources: Vec::new(),
            diagnostics: Vec::new(),
        }
    }

    fn span(
        path: &str,
        start_byte: u64,
        start_line: u32,
        start_column: u32,
        end_byte: u64,
        end_line: u32,
        end_column: u32,
    ) -> SourceSpan {
        SourceSpan::new(
            path,
            SourcePosition::new(start_byte, start_line, start_column),
            SourcePosition::new(end_byte, end_line, end_column),
        )
    }
}
