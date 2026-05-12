//! SQLite storage and query surfaces.

use std::collections::HashSet;
use std::path::Path;

use refbox_core::{
    BibliographyEntry, BibliographyFile, DerivedBibliographyStore, Diagnostic, DiagnosticSeverity,
    DiagnosticTarget, FileParseStatus, IndexStoreCounts, IndexedFileMetadata, ResourceKind,
    SourcePosition, SourceSpan,
};
use rusqlite::{Connection, OptionalExtension, Row, Transaction, params};
use thiserror::Error;

pub const SCHEMA_VERSION: i64 = 2;

pub type Result<T> = std::result::Result<T, StoreError>;

#[derive(Debug, Error)]
pub enum StoreError {
    #[error(transparent)]
    Sqlite(#[from] rusqlite::Error),
    #[error("source byte offset {0} exceeds SQLite integer range")]
    SourceOffsetOutOfRange(u64),
    #[error("limit {0} exceeds SQLite integer range")]
    LimitOutOfRange(usize),
    #[error("row index {0} exceeds SQLite integer range")]
    IndexOutOfRange(usize),
    #[error("count {0} exceeds SQLite integer range")]
    CountOutOfRange(usize),
}

#[derive(Debug)]
pub struct RefboxStore {
    connection: Connection,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct StoredEntry {
    pub id: i64,
    pub file_path: String,
    pub key: String,
    pub entry_type: String,
    pub source: SourceSpan,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct StoredField {
    pub id: i64,
    pub entry_id: i64,
    pub raw_name: String,
    pub lookup_name: String,
    pub value: String,
    pub source: Option<SourceSpan>,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct StoredResource {
    pub id: i64,
    pub entry_id: i64,
    pub key: String,
    pub source_path: String,
    pub owner_key: String,
    pub owner_source_path: String,
    pub kind: String,
    pub raw_name: String,
    pub lookup_name: String,
    pub value: String,
    pub inherited_from_key: Option<String>,
    pub inherited_from_source_path: Option<String>,
    pub source: Option<SourceSpan>,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct StoredDiagnostic {
    pub id: i64,
    pub file_path: String,
    pub entry_id: Option<i64>,
    pub severity: String,
    pub code: String,
    pub message: String,
    pub target_kind: String,
    pub source: Option<SourceSpan>,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct StoredDuplicateGroup {
    pub key: String,
    pub entries: Vec<StoredEntryRef>,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct StoredEntryRef {
    pub id: i64,
    pub file_path: String,
    pub key: String,
}

#[derive(Debug, Clone, PartialEq)]
pub struct SearchResult {
    pub entry_id: i64,
    pub file_path: String,
    pub key: String,
    pub entry_type: String,
    pub score: f64,
}

#[derive(Debug, Clone, PartialEq, Eq)]
struct ResourceOwner {
    key: String,
    source_path: String,
}

#[derive(Debug, Clone, Copy)]
enum ResourceInheritance<'owner> {
    Direct,
    Inherited(&'owner ResourceOwner),
}

impl ResourceInheritance<'_> {
    fn key(self) -> Option<String> {
        match self {
            Self::Direct => None,
            Self::Inherited(owner) => Some(owner.key.clone()),
        }
    }

    fn source_path(self) -> Option<String> {
        match self {
            Self::Direct => None,
            Self::Inherited(owner) => Some(owner.source_path.clone()),
        }
    }
}

#[derive(Debug, Clone, PartialEq, Eq)]
struct StoredResourceRow {
    id: i64,
    entry_id: i64,
    kind: String,
    raw_name: String,
    lookup_name: String,
    value: String,
    source: Option<SourceSpan>,
}

impl RefboxStore {
    pub fn open(path: impl AsRef<Path>) -> Result<Self> {
        let connection = Connection::open(path)?;
        Self::from_connection(connection)
    }

    pub fn open_in_memory() -> Result<Self> {
        let connection = Connection::open_in_memory()?;
        Self::from_connection(connection)
    }

    fn from_connection(connection: Connection) -> Result<Self> {
        connection.execute_batch("PRAGMA foreign_keys = ON;")?;
        let mut store = Self { connection };
        store.migrate()?;
        Ok(store)
    }

    pub fn schema_version(&self) -> Result<i64> {
        Ok(self.connection.query_row(
            "SELECT COALESCE(MAX(version), 0) FROM schema_migrations",
            [],
            |row| row.get(0),
        )?)
    }

    pub fn insert_file(&mut self, file: &BibliographyFile) -> Result<()> {
        let metadata = metadata_from_file(file);
        self.insert_file_with_metadata(file, &metadata)
    }

    pub fn insert_file_with_metadata(
        &mut self,
        file: &BibliographyFile,
        metadata: &IndexedFileMetadata,
    ) -> Result<()> {
        let tx = self.connection.transaction()?;
        delete_existing_file(&tx, &file.path)?;

        tx.execute(
            "INSERT INTO files(
                path, size_bytes, modified_ns, content_hash, parse_status, entry_count, diagnostic_count
             ) VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7)",
            params![
                file.path,
                i64_from_u64(metadata.size_bytes)?,
                metadata.modified_ns,
                metadata.content_hash,
                parse_status_name(metadata.parse_status),
                i64_from_usize(metadata.entry_count)?,
                i64_from_usize(metadata.diagnostic_count)?,
            ],
        )?;
        let file_id = tx.last_insert_rowid();

        for diagnostic in &file.diagnostics {
            insert_diagnostic(&tx, file_id, None, &file.path, diagnostic)?;
        }

        for entry in &file.entries {
            insert_entry(&tx, file_id, &file.path, entry)?;
        }

        refresh_duplicate_groups(&tx)?;
        tx.commit()?;
        Ok(())
    }

    pub fn remove_file(&mut self, path: &str) -> Result<()> {
        let tx = self.connection.transaction()?;
        delete_existing_file(&tx, path)?;
        refresh_duplicate_groups(&tx)?;
        tx.commit()?;
        Ok(())
    }

    pub fn indexed_file_metadata(&self) -> Result<Vec<IndexedFileMetadata>> {
        let mut statement = self.connection.prepare(
            "SELECT path, size_bytes, modified_ns, content_hash, parse_status, entry_count, diagnostic_count
             FROM files
             ORDER BY path",
        )?;
        let files = statement
            .query_map([], indexed_file_metadata_from_row)?
            .collect::<std::result::Result<Vec<_>, _>>()?;
        Ok(files)
    }

    pub fn index_counts(&self) -> Result<IndexStoreCounts> {
        let file_count = self
            .connection
            .query_row("SELECT COUNT(*) FROM files", [], |row| row.get::<_, i64>(0))?;
        let entry_count = self
            .connection
            .query_row("SELECT COUNT(*) FROM entries", [], |row| {
                row.get::<_, i64>(0)
            })?;
        let diagnostic_count =
            self.connection
                .query_row("SELECT COUNT(*) FROM diagnostics", [], |row| {
                    row.get::<_, i64>(0)
                })?;

        Ok(IndexStoreCounts {
            file_count: usize_from_i64(file_count),
            entry_count: usize_from_i64(entry_count),
            diagnostic_count: usize_from_i64(diagnostic_count),
        })
    }

    pub fn entries_by_key(&self, key: &str) -> Result<Vec<StoredEntry>> {
        let mut statement = self.connection.prepare(
            "SELECT e.id, f.path, e.entry_key, e.entry_type,
                    e.source_path, e.source_start_byte, e.source_start_line, e.source_start_column,
                    e.source_end_byte, e.source_end_line, e.source_end_column
             FROM entries e
             JOIN files f ON f.id = e.file_id
             WHERE e.entry_key = ?1
             ORDER BY f.path, e.id",
        )?;
        let entries = statement
            .query_map(params![key], stored_entry_from_row)?
            .collect::<std::result::Result<Vec<_>, _>>()?;
        Ok(entries)
    }

    pub fn fields_for_entry(&self, entry_id: i64) -> Result<Vec<StoredField>> {
        let mut statement = self.connection.prepare(
            "SELECT id, entry_id, raw_name, lookup_name, value,
                    source_path, source_start_byte, source_start_line, source_start_column,
                    source_end_byte, source_end_line, source_end_column
             FROM fields
             WHERE entry_id = ?1
             ORDER BY id",
        )?;
        let fields = statement
            .query_map(params![entry_id], stored_field_from_row)?
            .collect::<std::result::Result<Vec<_>, _>>()?;
        Ok(fields)
    }

    pub fn resources_for_entry(
        &self,
        entry_id: i64,
        crossref_fields: &[String],
    ) -> Result<Vec<StoredResource>> {
        let Some(origin) = self.resource_owner_by_entry_id(entry_id)? else {
            return Ok(Vec::new());
        };

        let mut resources = self.direct_resources_for_entry(
            entry_id,
            &origin,
            &origin,
            ResourceInheritance::Direct,
        )?;
        let mut visited = HashSet::new();
        self.append_crossref_resources(
            entry_id,
            &origin,
            crossref_fields,
            &mut visited,
            &mut resources,
        )?;
        Ok(resources)
    }

    pub fn resources_for_key(
        &self,
        key: &str,
        crossref_fields: &[String],
    ) -> Result<Vec<StoredResource>> {
        let mut resources = Vec::new();
        for entry in self.entries_by_key(key)? {
            resources.extend(self.resources_for_entry(entry.id, crossref_fields)?);
        }
        Ok(resources)
    }

    pub fn resources_for_keys(
        &self,
        keys: &[String],
        limit_per_key: usize,
        crossref_fields: &[String],
    ) -> Result<Vec<StoredResource>> {
        let mut resources = Vec::new();
        for key in keys {
            for entry in self.entries_by_key(key)?.into_iter().take(limit_per_key) {
                resources.extend(self.resources_for_entry(entry.id, crossref_fields)?);
            }
        }
        Ok(resources)
    }

    pub fn raw_entry(&self, entry_id: i64) -> Result<Option<String>> {
        Ok(self
            .connection
            .query_row(
                "SELECT raw_text FROM entries WHERE id = ?1",
                params![entry_id],
                |row| row.get(0),
            )
            .optional()?)
    }

    pub fn diagnostics(&self) -> Result<Vec<StoredDiagnostic>> {
        let mut statement = self.connection.prepare(
            "SELECT d.id, f.path, d.entry_id, d.severity, d.code, d.message, d.target_kind,
                    d.source_path, d.source_start_byte, d.source_start_line, d.source_start_column,
                    d.source_end_byte, d.source_end_line, d.source_end_column
             FROM diagnostics d
             JOIN files f ON f.id = d.file_id
             ORDER BY d.id",
        )?;
        let diagnostics = statement
            .query_map([], stored_diagnostic_from_row)?
            .collect::<std::result::Result<Vec<_>, _>>()?;
        Ok(diagnostics)
    }

    pub fn duplicate_groups(&self) -> Result<Vec<StoredDuplicateGroup>> {
        let mut statement = self
            .connection
            .prepare("SELECT id, entry_key FROM duplicate_groups ORDER BY entry_key")?;
        let groups = statement
            .query_map([], |row| {
                Ok((row.get::<_, i64>(0)?, row.get::<_, String>(1)?))
            })?
            .collect::<std::result::Result<Vec<_>, _>>()?;

        groups
            .into_iter()
            .map(|(group_id, key)| {
                let entries = self.duplicate_group_entries(group_id)?;
                Ok(StoredDuplicateGroup { key, entries })
            })
            .collect()
    }

    pub fn search(&self, query: &str, limit: usize) -> Result<Vec<SearchResult>> {
        if query.trim().is_empty() || limit == 0 {
            return Ok(Vec::new());
        }

        let limit = i64::try_from(limit).map_err(|_| StoreError::LimitOutOfRange(limit))?;
        let mut statement = self.connection.prepare(
            "SELECT e.id, f.path, e.entry_key, e.entry_type, bm25(entry_fts) AS score
             FROM entry_fts
             JOIN entries e ON e.id = entry_fts.rowid
             JOIN files f ON f.id = e.file_id
             WHERE entry_fts MATCH ?1
             ORDER BY score, e.entry_key, f.path, e.id
             LIMIT ?2",
        )?;
        let results = statement
            .query_map(params![query, limit], |row| {
                Ok(SearchResult {
                    entry_id: row.get(0)?,
                    file_path: row.get(1)?,
                    key: row.get(2)?,
                    entry_type: row.get(3)?,
                    score: row.get(4)?,
                })
            })?
            .collect::<std::result::Result<Vec<_>, _>>()?;
        Ok(results)
    }

    fn resource_owner_by_entry_id(&self, entry_id: i64) -> Result<Option<ResourceOwner>> {
        Ok(self
            .connection
            .query_row(
                "SELECT e.entry_key, f.path
                 FROM entries e
                 JOIN files f ON f.id = e.file_id
                 WHERE e.id = ?1",
                params![entry_id],
                |row| {
                    Ok(ResourceOwner {
                        key: row.get(0)?,
                        source_path: row.get(1)?,
                    })
                },
            )
            .optional()?)
    }

    fn direct_resources_for_entry(
        &self,
        entry_id: i64,
        request_owner: &ResourceOwner,
        resource_owner: &ResourceOwner,
        inheritance: ResourceInheritance<'_>,
    ) -> Result<Vec<StoredResource>> {
        let mut statement = self.connection.prepare(
            "SELECT id, entry_id, kind, raw_name, lookup_name, value,
                    source_path, source_start_byte, source_start_line, source_start_column,
                    source_end_byte, source_end_line, source_end_column
             FROM resources
             WHERE entry_id = ?1
             ORDER BY id",
        )?;
        let rows = statement
            .query_map(params![entry_id], stored_resource_row)?
            .collect::<std::result::Result<Vec<_>, _>>()?;

        let resources = rows
            .into_iter()
            .map(|row| StoredResource {
                id: row.id,
                entry_id: row.entry_id,
                key: request_owner.key.clone(),
                source_path: request_owner.source_path.clone(),
                owner_key: resource_owner.key.clone(),
                owner_source_path: resource_owner.source_path.clone(),
                kind: row.kind,
                raw_name: row.raw_name,
                lookup_name: row.lookup_name,
                value: row.value,
                inherited_from_key: inheritance.key(),
                inherited_from_source_path: inheritance.source_path(),
                source: row.source,
            })
            .collect();
        Ok(resources)
    }

    fn append_crossref_resources(
        &self,
        entry_id: i64,
        request_owner: &ResourceOwner,
        crossref_fields: &[String],
        visited: &mut HashSet<i64>,
        resources: &mut Vec<StoredResource>,
    ) -> Result<()> {
        if crossref_fields.is_empty() || !visited.insert(entry_id) {
            return Ok(());
        }

        let parent_keys = self.crossref_parent_keys(entry_id, crossref_fields)?;
        for parent_key in parent_keys {
            for parent in self.entries_by_key(&parent_key)? {
                if visited.contains(&parent.id) {
                    continue;
                }
                let parent_owner = ResourceOwner {
                    key: parent.key,
                    source_path: parent.file_path,
                };
                resources.extend(self.direct_resources_for_entry(
                    parent.id,
                    request_owner,
                    &parent_owner,
                    ResourceInheritance::Inherited(&parent_owner),
                )?);
                self.append_crossref_resources(
                    parent.id,
                    request_owner,
                    crossref_fields,
                    visited,
                    resources,
                )?;
            }
        }

        Ok(())
    }

    fn crossref_parent_keys(
        &self,
        entry_id: i64,
        crossref_fields: &[String],
    ) -> Result<Vec<String>> {
        let crossref_fields = crossref_fields
            .iter()
            .map(|field| field.trim().to_ascii_lowercase())
            .filter(|field| !field.is_empty())
            .collect::<HashSet<_>>();
        if crossref_fields.is_empty() {
            return Ok(Vec::new());
        }

        let mut statement = self.connection.prepare(
            "SELECT lookup_name, value
             FROM fields
             WHERE entry_id = ?1
             ORDER BY id",
        )?;
        let fields = statement
            .query_map(params![entry_id], |row| {
                Ok((row.get::<_, String>(0)?, row.get::<_, String>(1)?))
            })?
            .collect::<std::result::Result<Vec<_>, _>>()?;
        let parents = fields
            .into_iter()
            .filter(|(lookup_name, _)| crossref_fields.contains(lookup_name))
            .filter_map(|(_, value)| clean_bibliography_scalar(&value))
            .collect();
        Ok(parents)
    }

    fn migrate(&mut self) -> Result<()> {
        let tx = self.connection.transaction()?;
        tx.execute_batch(
            "CREATE TABLE IF NOT EXISTS schema_migrations (
                version INTEGER PRIMARY KEY,
                applied_at TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP
            );",
        )?;

        for (version, migration) in MIGRATIONS {
            let already_applied = tx
                .query_row(
                    "SELECT version FROM schema_migrations WHERE version = ?1",
                    params![version],
                    |row| row.get::<_, i64>(0),
                )
                .optional()?
                .is_some();

            if !already_applied {
                tx.execute_batch(migration)?;
                tx.execute(
                    "INSERT INTO schema_migrations(version) VALUES (?1)",
                    params![version],
                )?;
            }
        }

        tx.execute_batch("PRAGMA user_version = 2;")?;
        tx.commit()?;
        Ok(())
    }

    fn duplicate_group_entries(&self, group_id: i64) -> Result<Vec<StoredEntryRef>> {
        let mut statement = self.connection.prepare(
            "SELECT e.id, f.path, e.entry_key
             FROM duplicate_group_entries dge
             JOIN entries e ON e.id = dge.entry_id
             JOIN files f ON f.id = e.file_id
             WHERE dge.group_id = ?1
             ORDER BY f.path, e.id",
        )?;
        let entries = statement
            .query_map(params![group_id], |row| {
                Ok(StoredEntryRef {
                    id: row.get(0)?,
                    file_path: row.get(1)?,
                    key: row.get(2)?,
                })
            })?
            .collect::<std::result::Result<Vec<_>, _>>()?;
        Ok(entries)
    }
}

impl DerivedBibliographyStore for RefboxStore {
    type Error = StoreError;

    fn indexed_file_metadata(&self) -> Result<Vec<IndexedFileMetadata>> {
        RefboxStore::indexed_file_metadata(self)
    }

    fn upsert_file(
        &mut self,
        file: &BibliographyFile,
        metadata: &IndexedFileMetadata,
    ) -> Result<()> {
        self.insert_file_with_metadata(file, metadata)
    }

    fn remove_file(&mut self, path: &str) -> Result<()> {
        RefboxStore::remove_file(self, path)
    }

    fn index_counts(&self) -> Result<IndexStoreCounts> {
        RefboxStore::index_counts(self)
    }
}

const MIGRATIONS: &[(i64, &str)] = &[(1, MIGRATION_001), (2, MIGRATION_002)];

const MIGRATION_001: &str = r#"
CREATE TABLE IF NOT EXISTS files (
    id INTEGER PRIMARY KEY,
    path TEXT NOT NULL UNIQUE
);

CREATE TABLE IF NOT EXISTS entries (
    id INTEGER PRIMARY KEY,
    file_id INTEGER NOT NULL REFERENCES files(id) ON DELETE CASCADE,
    entry_key TEXT NOT NULL,
    entry_type TEXT NOT NULL,
    raw_text TEXT NOT NULL,
    source_path TEXT NOT NULL,
    source_start_byte INTEGER NOT NULL,
    source_start_line INTEGER NOT NULL,
    source_start_column INTEGER NOT NULL,
    source_end_byte INTEGER NOT NULL,
    source_end_line INTEGER NOT NULL,
    source_end_column INTEGER NOT NULL,
    UNIQUE(file_id, entry_key)
);

CREATE TABLE IF NOT EXISTS fields (
    id INTEGER PRIMARY KEY,
    entry_id INTEGER NOT NULL REFERENCES entries(id) ON DELETE CASCADE,
    raw_name TEXT NOT NULL,
    lookup_name TEXT NOT NULL,
    value TEXT NOT NULL,
    source_path TEXT,
    source_start_byte INTEGER,
    source_start_line INTEGER,
    source_start_column INTEGER,
    source_end_byte INTEGER,
    source_end_line INTEGER,
    source_end_column INTEGER
);

CREATE TABLE IF NOT EXISTS names (
    id INTEGER PRIMARY KEY,
    entry_id INTEGER NOT NULL REFERENCES entries(id) ON DELETE CASCADE,
    raw_role TEXT NOT NULL,
    lookup_role TEXT NOT NULL,
    raw TEXT NOT NULL,
    name_index INTEGER NOT NULL,
    given TEXT NOT NULL,
    family TEXT NOT NULL,
    prefix TEXT NOT NULL,
    suffix TEXT NOT NULL,
    literal TEXT,
    source_path TEXT,
    source_start_byte INTEGER,
    source_start_line INTEGER,
    source_start_column INTEGER,
    source_end_byte INTEGER,
    source_end_line INTEGER,
    source_end_column INTEGER
);

CREATE TABLE IF NOT EXISTS resources (
    id INTEGER PRIMARY KEY,
    entry_id INTEGER NOT NULL REFERENCES entries(id) ON DELETE CASCADE,
    kind TEXT NOT NULL,
    raw_name TEXT NOT NULL,
    lookup_name TEXT NOT NULL,
    value TEXT NOT NULL,
    source_path TEXT,
    source_start_byte INTEGER,
    source_start_line INTEGER,
    source_start_column INTEGER,
    source_end_byte INTEGER,
    source_end_line INTEGER,
    source_end_column INTEGER
);

CREATE TABLE IF NOT EXISTS diagnostics (
    id INTEGER PRIMARY KEY,
    file_id INTEGER NOT NULL REFERENCES files(id) ON DELETE CASCADE,
    entry_id INTEGER REFERENCES entries(id) ON DELETE CASCADE,
    severity TEXT NOT NULL,
    code TEXT NOT NULL,
    message TEXT NOT NULL,
    target_kind TEXT NOT NULL,
    target_path TEXT,
    target_entry_file TEXT,
    target_entry_key TEXT,
    source_path TEXT,
    source_start_byte INTEGER,
    source_start_line INTEGER,
    source_start_column INTEGER,
    source_end_byte INTEGER,
    source_end_line INTEGER,
    source_end_column INTEGER
);

CREATE TABLE IF NOT EXISTS duplicate_groups (
    id INTEGER PRIMARY KEY,
    entry_key TEXT NOT NULL UNIQUE
);

CREATE TABLE IF NOT EXISTS duplicate_group_entries (
    group_id INTEGER NOT NULL REFERENCES duplicate_groups(id) ON DELETE CASCADE,
    entry_id INTEGER NOT NULL REFERENCES entries(id) ON DELETE CASCADE,
    PRIMARY KEY(group_id, entry_id)
);

CREATE TABLE IF NOT EXISTS source_spans (
    id INTEGER PRIMARY KEY,
    file_path TEXT NOT NULL,
    owner_kind TEXT NOT NULL,
    owner_id INTEGER NOT NULL,
    path TEXT NOT NULL,
    start_byte INTEGER NOT NULL,
    start_line INTEGER NOT NULL,
    start_column INTEGER NOT NULL,
    end_byte INTEGER NOT NULL,
    end_line INTEGER NOT NULL,
    end_column INTEGER NOT NULL
);

CREATE VIRTUAL TABLE IF NOT EXISTS entry_fts USING fts5(
    entry_key,
    title,
    names,
    date,
    venue,
    abstract,
    keywords,
    identifiers
);

CREATE INDEX IF NOT EXISTS files_path_idx ON files(path);
CREATE INDEX IF NOT EXISTS entries_key_idx ON entries(entry_key);
CREATE INDEX IF NOT EXISTS entries_file_key_idx ON entries(file_id, entry_key);
CREATE INDEX IF NOT EXISTS entries_source_idx ON entries(source_path, source_start_line, source_start_column);
CREATE INDEX IF NOT EXISTS fields_entry_lookup_idx ON fields(entry_id, lookup_name);
CREATE INDEX IF NOT EXISTS fields_lookup_value_idx ON fields(lookup_name, value);
CREATE INDEX IF NOT EXISTS names_entry_role_idx ON names(entry_id, lookup_role);
CREATE INDEX IF NOT EXISTS names_family_idx ON names(family);
CREATE INDEX IF NOT EXISTS resources_entry_idx ON resources(entry_id);
CREATE INDEX IF NOT EXISTS resources_kind_value_idx ON resources(kind, value);
CREATE INDEX IF NOT EXISTS diagnostics_file_idx ON diagnostics(file_id);
CREATE INDEX IF NOT EXISTS diagnostics_entry_idx ON diagnostics(entry_id);
CREATE INDEX IF NOT EXISTS diagnostics_code_idx ON diagnostics(code);
CREATE INDEX IF NOT EXISTS source_spans_owner_idx ON source_spans(owner_kind, owner_id);
CREATE INDEX IF NOT EXISTS source_spans_path_idx ON source_spans(file_path, start_line, start_column);
"#;

const MIGRATION_002: &str = r#"
ALTER TABLE files ADD COLUMN size_bytes INTEGER;
ALTER TABLE files ADD COLUMN modified_ns INTEGER;
ALTER TABLE files ADD COLUMN content_hash TEXT;
ALTER TABLE files ADD COLUMN parse_status TEXT NOT NULL DEFAULT 'ok';
ALTER TABLE files ADD COLUMN entry_count INTEGER NOT NULL DEFAULT 0;
ALTER TABLE files ADD COLUMN diagnostic_count INTEGER NOT NULL DEFAULT 0;
CREATE INDEX IF NOT EXISTS files_hash_idx ON files(content_hash);
CREATE INDEX IF NOT EXISTS files_parse_status_idx ON files(parse_status);
"#;

fn delete_existing_file(tx: &Transaction<'_>, path: &str) -> Result<()> {
    let entry_ids = {
        let mut statement = tx.prepare(
            "SELECT e.id
             FROM entries e
             JOIN files f ON f.id = e.file_id
             WHERE f.path = ?1",
        )?;
        statement
            .query_map(params![path], |row| row.get::<_, i64>(0))?
            .collect::<std::result::Result<Vec<_>, _>>()?
    };

    for entry_id in entry_ids {
        tx.execute("DELETE FROM entry_fts WHERE rowid = ?1", params![entry_id])?;
    }

    tx.execute(
        "DELETE FROM source_spans WHERE file_path = ?1",
        params![path],
    )?;
    tx.execute("DELETE FROM files WHERE path = ?1", params![path])?;
    Ok(())
}

fn insert_entry(
    tx: &Transaction<'_>,
    file_id: i64,
    file_path: &str,
    entry: &BibliographyEntry,
) -> Result<i64> {
    let source = db_span(&entry.raw.source)?;
    tx.execute(
        "INSERT INTO entries(
            file_id, entry_key, entry_type, raw_text,
            source_path, source_start_byte, source_start_line, source_start_column,
            source_end_byte, source_end_line, source_end_column
         ) VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10, ?11)",
        params![
            file_id,
            entry.id.key,
            entry.entry_type,
            entry.raw.text,
            source.path,
            source.start_byte,
            source.start_line,
            source.start_column,
            source.end_byte,
            source.end_line,
            source.end_column,
        ],
    )?;
    let entry_id = tx.last_insert_rowid();
    insert_source_span(tx, file_path, "entry", entry_id, &entry.raw.source)?;

    for field in &entry.fields {
        let source = nullable_span(field.source.as_ref())?;
        tx.execute(
            "INSERT INTO fields(
                entry_id, raw_name, lookup_name, value,
                source_path, source_start_byte, source_start_line, source_start_column,
                source_end_byte, source_end_line, source_end_column
             ) VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10, ?11)",
            params![
                entry_id,
                field.raw_name,
                field.lookup_name,
                field.value,
                source.path,
                source.start_byte,
                source.start_line,
                source.start_column,
                source.end_byte,
                source.end_line,
                source.end_column,
            ],
        )?;
        if let Some(span) = &field.source {
            insert_source_span(tx, file_path, "field", tx.last_insert_rowid(), span)?;
        }
    }

    for name_list in &entry.names {
        let source = nullable_span(name_list.source.as_ref())?;
        for (index, name) in name_list.names.iter().enumerate() {
            let name_index =
                i64::try_from(index).map_err(|_| StoreError::IndexOutOfRange(index))?;
            tx.execute(
                "INSERT INTO names(
                    entry_id, raw_role, lookup_role, raw, name_index,
                    given, family, prefix, suffix, literal,
                    source_path, source_start_byte, source_start_line, source_start_column,
                    source_end_byte, source_end_line, source_end_column
                 ) VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10, ?11, ?12, ?13, ?14, ?15, ?16, ?17)",
                params![
                    entry_id,
                    name_list.raw_role,
                    name_list.lookup_role,
                    name_list.raw,
                    name_index,
                    name.given.join(" "),
                    name.family.join(" "),
                    name.prefix.join(" "),
                    name.suffix.join(" "),
                    name.literal,
                    source.path,
                    source.start_byte,
                    source.start_line,
                    source.start_column,
                    source.end_byte,
                    source.end_line,
                    source.end_column,
                ],
            )?;
            if let Some(span) = &name_list.source {
                insert_source_span(tx, file_path, "name", tx.last_insert_rowid(), span)?;
            }
        }
    }

    for resource in &entry.resources {
        let source = nullable_span(resource.source.as_ref())?;
        tx.execute(
            "INSERT INTO resources(
                entry_id, kind, raw_name, lookup_name, value,
                source_path, source_start_byte, source_start_line, source_start_column,
                source_end_byte, source_end_line, source_end_column
             ) VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10, ?11, ?12)",
            params![
                entry_id,
                resource_kind_name(resource.kind),
                resource.raw_name,
                resource.lookup_name,
                resource.value,
                source.path,
                source.start_byte,
                source.start_line,
                source.start_column,
                source.end_byte,
                source.end_line,
                source.end_column,
            ],
        )?;
        if let Some(span) = &resource.source {
            insert_source_span(tx, file_path, "resource", tx.last_insert_rowid(), span)?;
        }
    }

    for diagnostic in &entry.diagnostics {
        insert_diagnostic(tx, file_id, Some(entry_id), file_path, diagnostic)?;
    }

    insert_fts_row(tx, entry_id, entry)?;
    Ok(entry_id)
}

fn insert_diagnostic(
    tx: &Transaction<'_>,
    file_id: i64,
    entry_id: Option<i64>,
    file_path: &str,
    diagnostic: &Diagnostic,
) -> Result<()> {
    let source = nullable_span(diagnostic.source.as_ref())?;
    let target = diagnostic_target_columns(&diagnostic.target);
    tx.execute(
        "INSERT INTO diagnostics(
            file_id, entry_id, severity, code, message, target_kind,
            target_path, target_entry_file, target_entry_key,
            source_path, source_start_byte, source_start_line, source_start_column,
            source_end_byte, source_end_line, source_end_column
         ) VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10, ?11, ?12, ?13, ?14, ?15, ?16)",
        params![
            file_id,
            entry_id,
            diagnostic_severity_name(diagnostic.severity),
            diagnostic.code,
            diagnostic.message,
            target.kind,
            target.path,
            target.entry_file,
            target.entry_key,
            source.path,
            source.start_byte,
            source.start_line,
            source.start_column,
            source.end_byte,
            source.end_line,
            source.end_column,
        ],
    )?;
    if let Some(span) = &diagnostic.source {
        insert_source_span(tx, file_path, "diagnostic", tx.last_insert_rowid(), span)?;
    }
    Ok(())
}

fn insert_fts_row(tx: &Transaction<'_>, entry_id: i64, entry: &BibliographyEntry) -> Result<()> {
    tx.execute(
        "INSERT INTO entry_fts(rowid, entry_key, title, names, date, venue, abstract, keywords, identifiers)
         VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9)",
        params![
            entry_id,
            entry.id.key,
            field_values(entry, &["title", "shorttitle"]),
            entry.names.iter().map(|name| name.raw.as_str()).collect::<Vec<_>>().join(" "),
            entry.dates.iter().map(|date| date.raw.as_str()).collect::<Vec<_>>().join(" "),
            field_values(
                entry,
                &[
                    "journaltitle",
                    "journal",
                    "booktitle",
                    "container-title",
                    "venue",
                    "publisher",
                ],
            ),
            field_values(entry, &["abstract", "annotation", "annote"]),
            field_values(entry, &["keywords", "tags", "mendeley-tags"]),
            field_values(
                entry,
                &[
                    "doi", "url", "pmid", "pmcid", "isbn", "issn", "eprint", "arxiv", "crossref",
                ],
            ),
        ],
    )?;
    Ok(())
}

fn refresh_duplicate_groups(tx: &Transaction<'_>) -> Result<()> {
    tx.execute("DELETE FROM duplicate_group_entries", [])?;
    tx.execute("DELETE FROM duplicate_groups", [])?;

    let duplicate_keys = {
        let mut statement = tx.prepare(
            "SELECT entry_key
             FROM entries
             GROUP BY entry_key
             HAVING COUNT(*) > 1
             ORDER BY entry_key",
        )?;
        statement
            .query_map([], |row| row.get::<_, String>(0))?
            .collect::<std::result::Result<Vec<_>, _>>()?
    };

    for key in duplicate_keys {
        tx.execute(
            "INSERT INTO duplicate_groups(entry_key) VALUES (?1)",
            params![key],
        )?;
        let group_id = tx.last_insert_rowid();
        let entry_ids = {
            let mut statement =
                tx.prepare("SELECT id FROM entries WHERE entry_key = ?1 ORDER BY file_id, id")?;
            statement
                .query_map(params![key], |row| row.get::<_, i64>(0))?
                .collect::<std::result::Result<Vec<_>, _>>()?
        };
        for entry_id in entry_ids {
            tx.execute(
                "INSERT INTO duplicate_group_entries(group_id, entry_id) VALUES (?1, ?2)",
                params![group_id, entry_id],
            )?;
        }
    }

    Ok(())
}

fn insert_source_span(
    tx: &Transaction<'_>,
    file_path: &str,
    owner_kind: &str,
    owner_id: i64,
    span: &SourceSpan,
) -> Result<()> {
    let span = db_span(span)?;
    tx.execute(
        "INSERT INTO source_spans(
            file_path, owner_kind, owner_id, path,
            start_byte, start_line, start_column,
            end_byte, end_line, end_column
         ) VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10)",
        params![
            file_path,
            owner_kind,
            owner_id,
            span.path,
            span.start_byte,
            span.start_line,
            span.start_column,
            span.end_byte,
            span.end_line,
            span.end_column,
        ],
    )?;
    Ok(())
}

fn stored_entry_from_row(row: &Row<'_>) -> rusqlite::Result<StoredEntry> {
    Ok(StoredEntry {
        id: row.get(0)?,
        file_path: row.get(1)?,
        key: row.get(2)?,
        entry_type: row.get(3)?,
        source: required_span_from_row(row, 4)?,
    })
}

fn stored_field_from_row(row: &Row<'_>) -> rusqlite::Result<StoredField> {
    Ok(StoredField {
        id: row.get(0)?,
        entry_id: row.get(1)?,
        raw_name: row.get(2)?,
        lookup_name: row.get(3)?,
        value: row.get(4)?,
        source: optional_span_from_row(row, 5)?,
    })
}

fn stored_resource_row(row: &Row<'_>) -> rusqlite::Result<StoredResourceRow> {
    Ok(StoredResourceRow {
        id: row.get(0)?,
        entry_id: row.get(1)?,
        kind: row.get(2)?,
        raw_name: row.get(3)?,
        lookup_name: row.get(4)?,
        value: row.get(5)?,
        source: optional_span_from_row(row, 6)?,
    })
}

fn stored_diagnostic_from_row(row: &Row<'_>) -> rusqlite::Result<StoredDiagnostic> {
    Ok(StoredDiagnostic {
        id: row.get(0)?,
        file_path: row.get(1)?,
        entry_id: row.get(2)?,
        severity: row.get(3)?,
        code: row.get(4)?,
        message: row.get(5)?,
        target_kind: row.get(6)?,
        source: optional_span_from_row(row, 7)?,
    })
}

fn indexed_file_metadata_from_row(row: &Row<'_>) -> rusqlite::Result<IndexedFileMetadata> {
    Ok(IndexedFileMetadata {
        path: row.get(0)?,
        size_bytes: row.get::<_, Option<i64>>(1)?.unwrap_or_default() as u64,
        modified_ns: row.get(2)?,
        content_hash: row.get::<_, Option<String>>(3)?.unwrap_or_default(),
        parse_status: parse_status_from_name(&row.get::<_, String>(4)?),
        entry_count: usize_from_i64(row.get(5)?),
        diagnostic_count: usize_from_i64(row.get(6)?),
    })
}

fn required_span_from_row(row: &Row<'_>, offset: usize) -> rusqlite::Result<SourceSpan> {
    Ok(SourceSpan::new(
        row.get::<_, String>(offset)?,
        SourcePosition::new(
            row.get::<_, i64>(offset + 1)? as u64,
            row.get::<_, i64>(offset + 2)? as u32,
            row.get::<_, i64>(offset + 3)? as u32,
        ),
        SourcePosition::new(
            row.get::<_, i64>(offset + 4)? as u64,
            row.get::<_, i64>(offset + 5)? as u32,
            row.get::<_, i64>(offset + 6)? as u32,
        ),
    ))
}

fn optional_span_from_row(row: &Row<'_>, offset: usize) -> rusqlite::Result<Option<SourceSpan>> {
    let path = row.get::<_, Option<String>>(offset)?;
    let Some(path) = path else {
        return Ok(None);
    };

    Ok(Some(SourceSpan::new(
        path,
        SourcePosition::new(
            row.get::<_, Option<i64>>(offset + 1)?.unwrap_or_default() as u64,
            row.get::<_, Option<i64>>(offset + 2)?.unwrap_or_default() as u32,
            row.get::<_, Option<i64>>(offset + 3)?.unwrap_or_default() as u32,
        ),
        SourcePosition::new(
            row.get::<_, Option<i64>>(offset + 4)?.unwrap_or_default() as u64,
            row.get::<_, Option<i64>>(offset + 5)?.unwrap_or_default() as u32,
            row.get::<_, Option<i64>>(offset + 6)?.unwrap_or_default() as u32,
        ),
    )))
}

#[derive(Debug, Clone)]
struct DbSpan {
    path: String,
    start_byte: i64,
    start_line: i64,
    start_column: i64,
    end_byte: i64,
    end_line: i64,
    end_column: i64,
}

#[derive(Debug, Clone)]
struct NullableSpan {
    path: Option<String>,
    start_byte: Option<i64>,
    start_line: Option<i64>,
    start_column: Option<i64>,
    end_byte: Option<i64>,
    end_line: Option<i64>,
    end_column: Option<i64>,
}

fn db_span(span: &SourceSpan) -> Result<DbSpan> {
    Ok(DbSpan {
        path: span.path.clone(),
        start_byte: i64_from_u64(span.start.byte)?,
        start_line: i64::from(span.start.line),
        start_column: i64::from(span.start.column),
        end_byte: i64_from_u64(span.end.byte)?,
        end_line: i64::from(span.end.line),
        end_column: i64::from(span.end.column),
    })
}

fn nullable_span(span: Option<&SourceSpan>) -> Result<NullableSpan> {
    match span {
        Some(span) => {
            let span = db_span(span)?;
            Ok(NullableSpan {
                path: Some(span.path),
                start_byte: Some(span.start_byte),
                start_line: Some(span.start_line),
                start_column: Some(span.start_column),
                end_byte: Some(span.end_byte),
                end_line: Some(span.end_line),
                end_column: Some(span.end_column),
            })
        }
        None => Ok(NullableSpan {
            path: None,
            start_byte: None,
            start_line: None,
            start_column: None,
            end_byte: None,
            end_line: None,
            end_column: None,
        }),
    }
}

fn i64_from_u64(value: u64) -> Result<i64> {
    i64::try_from(value).map_err(|_| StoreError::SourceOffsetOutOfRange(value))
}

fn i64_from_usize(value: usize) -> Result<i64> {
    i64::try_from(value).map_err(|_| StoreError::CountOutOfRange(value))
}

fn usize_from_i64(value: i64) -> usize {
    usize::try_from(value).unwrap_or_default()
}

#[derive(Debug, Clone)]
struct DiagnosticTargetColumns {
    kind: &'static str,
    path: Option<String>,
    entry_file: Option<String>,
    entry_key: Option<String>,
}

fn diagnostic_target_columns(target: &DiagnosticTarget) -> DiagnosticTargetColumns {
    match target {
        DiagnosticTarget::File { path } => DiagnosticTargetColumns {
            kind: "file",
            path: Some(path.clone()),
            entry_file: None,
            entry_key: None,
        },
        DiagnosticTarget::Entry { id } => DiagnosticTargetColumns {
            kind: "entry",
            path: None,
            entry_file: Some(id.source_path.clone()),
            entry_key: Some(id.key.clone()),
        },
    }
}

fn diagnostic_severity_name(severity: DiagnosticSeverity) -> &'static str {
    match severity {
        DiagnosticSeverity::Error => "error",
        DiagnosticSeverity::Warning => "warning",
        DiagnosticSeverity::Info => "info",
    }
}

fn parse_status_name(status: FileParseStatus) -> &'static str {
    match status {
        FileParseStatus::Ok => "ok",
        FileParseStatus::Partial => "partial",
        FileParseStatus::Failed => "failed",
    }
}

fn parse_status_from_name(status: &str) -> FileParseStatus {
    match status {
        "partial" => FileParseStatus::Partial,
        "failed" => FileParseStatus::Failed,
        _ => FileParseStatus::Ok,
    }
}

fn resource_kind_name(kind: ResourceKind) -> &'static str {
    match kind {
        ResourceKind::File => "file",
        ResourceKind::Url => "url",
        ResourceKind::Doi => "doi",
        ResourceKind::Pmid => "pmid",
        ResourceKind::Pmcid => "pmcid",
        ResourceKind::Crossref => "crossref",
    }
}

fn clean_bibliography_scalar(value: &str) -> Option<String> {
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

    if text.is_empty() {
        None
    } else {
        Some(text.to_string())
    }
}

fn field_values(entry: &BibliographyEntry, names: &[&str]) -> String {
    entry
        .fields
        .iter()
        .filter(|field| names.contains(&field.lookup_name.as_str()))
        .map(|field| field.value.as_str())
        .collect::<Vec<_>>()
        .join(" ")
}

fn metadata_from_file(file: &BibliographyFile) -> IndexedFileMetadata {
    IndexedFileMetadata {
        path: file.path.clone(),
        size_bytes: 0,
        modified_ns: None,
        content_hash: String::new(),
        parse_status: if file.entries.is_empty() && !file.diagnostics.is_empty() {
            FileParseStatus::Failed
        } else if diagnostic_count(file) > 0 {
            FileParseStatus::Partial
        } else {
            FileParseStatus::Ok
        },
        entry_count: file.entries.len(),
        diagnostic_count: diagnostic_count(file),
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
