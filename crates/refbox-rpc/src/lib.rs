use std::fmt;

use refbox_core::{IndexStoreCounts, IndexedFileMetadata, SourceSpan};
use serde::{Deserialize, Serialize};
use serde_json::Value;
use thiserror::Error;

pub const METHOD_PING: &str = "refbox/ping";
pub const METHOD_STATUS: &str = "refbox/status";
pub const METHOD_SYNC_FULL: &str = "refbox/syncFull";
pub const METHOD_SYNC_FILE: &str = "refbox/syncFile";
pub const METHOD_INDEXED_FILES: &str = "refbox/indexedFiles";
pub const METHOD_SEARCH_ENTRIES: &str = "refbox/searchEntries";
pub const METHOD_LIST_ENTRIES: &str = "refbox/listEntries";
pub const METHOD_CLOSE_KEYS: &str = "refbox/closeKeys";
pub const METHOD_ENTRY_BY_KEY: &str = "refbox/entryByKey";
pub const METHOD_ENTRIES_BY_KEYS: &str = "refbox/entriesByKeys";
pub const METHOD_RESOURCES_BY_KEY: &str = "refbox/resourcesByKey";
pub const METHOD_RESOURCES_BY_KEYS: &str = "refbox/resourcesByKeys";
pub const METHOD_RESOLVE_FILES: &str = "refbox/resolveFiles";
pub const METHOD_LIBRARY_FILES_BY_KEYS: &str = "refbox/libraryFilesByKeys";
pub const METHOD_RAW_ENTRY: &str = "refbox/rawEntry";
pub const METHOD_SOURCE_LOCATION: &str = "refbox/sourceLocation";
pub const METHOD_DIAGNOSTICS: &str = "refbox/diagnostics";
pub const METHOD_DUPLICATE_GROUPS: &str = "refbox/duplicateGroups";

pub const DEFAULT_LIMIT: usize = 100;
pub const MAX_LIMIT: usize = 10_000;

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct JsonRpcRequest {
    pub jsonrpc: String,
    pub id: Option<Value>,
    pub method: String,
    #[serde(default)]
    pub params: Value,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct JsonRpcResponse {
    pub jsonrpc: &'static str,
    pub id: Value,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub result: Option<Value>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub error: Option<JsonRpcErrorObject>,
}

impl JsonRpcResponse {
    #[must_use]
    pub fn success(id: Value, result: Value) -> Self {
        Self {
            jsonrpc: "2.0",
            id,
            result: Some(result),
            error: None,
        }
    }

    #[must_use]
    pub fn error(id: Value, error: JsonRpcErrorObject) -> Self {
        Self {
            jsonrpc: "2.0",
            id,
            result: None,
            error: Some(error),
        }
    }
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct JsonRpcErrorObject {
    pub code: i64,
    pub message: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub data: Option<Value>,
}

impl fmt::Display for JsonRpcErrorObject {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        write!(formatter, "JSON-RPC error {}: {}", self.code, self.message)
    }
}

impl JsonRpcErrorObject {
    #[must_use]
    pub fn parse_error(message: String) -> Self {
        Self {
            code: -32700,
            message,
            data: None,
        }
    }

    #[must_use]
    pub fn invalid_request(message: String) -> Self {
        Self {
            code: -32600,
            message,
            data: None,
        }
    }

    #[must_use]
    pub fn invalid_params(message: String) -> Self {
        Self {
            code: -32602,
            message,
            data: None,
        }
    }

    #[must_use]
    pub fn method_not_found(message: String) -> Self {
        Self {
            code: -32601,
            message,
            data: None,
        }
    }

    #[must_use]
    pub fn internal_error(message: String) -> Self {
        Self {
            code: -32603,
            message,
            data: None,
        }
    }

    #[must_use]
    pub fn domain(code: i64, kind: &'static str, message: String) -> Self {
        Self {
            code,
            message,
            data: Some(serde_json::json!({ "kind": kind })),
        }
    }
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize, Default)]
pub struct EmptyParams {}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct StatusResponse {
    pub roots: Vec<String>,
    pub files: Vec<String>,
    pub db: String,
    pub schema_version: i64,
    pub counts: IndexStoreCounts,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct SyncFileRequest {
    pub path: String,
    pub explicit: Option<bool>,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct SyncResponse {
    pub discovered_file_count: usize,
    pub changed_file_count: usize,
    pub skipped_file_count: usize,
    pub removed_file_count: usize,
    pub indexed_file_count: usize,
    pub indexed_entry_count: usize,
    pub diagnostic_count: usize,
    pub latest_modified_ns: Option<i64>,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct IndexedFilesResponse {
    pub files: Vec<IndexedFileMetadata>,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize, Default)]
pub struct LimitRequest {
    pub limit: Option<usize>,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct SearchEntriesRequest {
    pub query: String,
    pub limit: Option<usize>,
    pub source_paths: Option<Vec<String>>,
    pub include_configured_sources: Option<bool>,
    pub keys: Option<Vec<String>>,
    pub resource_kinds: Option<Vec<String>>,
    pub include_crossrefs: Option<bool>,
    pub crossref_fields: Option<Vec<String>>,
    pub search_fields: Option<Vec<String>>,
    pub field_names: Option<Vec<String>>,
    pub field_value_char_limit: Option<usize>,
    pub include_fields: Option<bool>,
    pub include_field_sources: Option<bool>,
    pub include_completion_display: Option<bool>,
    pub allow_empty_query: Option<bool>,
    pub ranked: Option<bool>,
    pub include_resources: Option<bool>,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct SearchEntriesResponse {
    pub entries: Vec<EntrySearchItem>,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize, Default)]
pub struct ListEntriesRequest {
    pub limit: Option<usize>,
    pub offset: Option<usize>,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct CloseKeysRequest {
    pub key: String,
    pub max_distance: Option<usize>,
    pub limit: Option<usize>,
    pub source_paths: Option<Vec<String>>,
    pub include_configured_sources: Option<bool>,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct CloseKeysResponse {
    pub keys: Vec<String>,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct EntrySearchItem {
    pub id: i64,
    pub key: String,
    pub source_path: String,
    pub entry_type: String,
    pub score: f64,
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub fields: Vec<EntryFieldItem>,
    pub resource_kinds: Vec<String>,
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub resources: Vec<ResourceItem>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub completion_display: Option<EntryCompletionDisplayItem>,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct EntryCompletionDisplayItem {
    pub main: String,
    pub suffix: String,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct EntryFieldItem {
    pub raw_name: String,
    pub lookup_name: String,
    pub value: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub source: Option<SourceSpan>,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct EntryByKeyRequest {
    pub id: Option<i64>,
    pub key: String,
    pub source_path: Option<String>,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct EntriesByKeysRequest {
    pub keys: Vec<String>,
    pub limit_per_key: Option<usize>,
    pub include_crossrefs: Option<bool>,
    pub crossref_fields: Option<Vec<String>>,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct EntriesResponse {
    pub entries: Vec<EntrySearchItem>,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct ResourcesByKeyRequest {
    pub id: Option<i64>,
    pub key: String,
    pub source_path: Option<String>,
    pub include_crossrefs: Option<bool>,
    pub crossref_fields: Option<Vec<String>>,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct ResourcesByKeysRequest {
    pub keys: Vec<String>,
    pub limit_per_key: Option<usize>,
    pub include_crossrefs: Option<bool>,
    pub crossref_fields: Option<Vec<String>>,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct ResourcesResponse {
    pub resources: Vec<ResourceItem>,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct ResolveFilesRequest {
    pub files: Vec<String>,
    pub roots: Vec<String>,
    pub recursive: Option<bool>,
    pub extensions: Option<Vec<String>>,
    pub cache_only: Option<bool>,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct LibraryFilesByKeysRequest {
    pub keys: Vec<String>,
    pub roots: Vec<String>,
    pub recursive: Option<bool>,
    pub extensions: Option<Vec<String>>,
    pub additional_separator: Option<String>,
    pub cache_only: Option<bool>,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct LibraryFilesResponse {
    pub files: Vec<String>,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct ResourceItem {
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

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct EntryItem {
    pub id: i64,
    pub key: String,
    pub source_path: String,
    pub entry_type: String,
    pub source: SourceSpan,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct RawEntryRequest {
    pub id: Option<i64>,
    pub key: String,
    pub source_path: Option<String>,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct RawEntryResponse {
    pub key: String,
    pub source_path: String,
    pub raw: String,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct SourceLocationRequest {
    pub id: Option<i64>,
    pub key: String,
    pub source_path: Option<String>,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct SourceLocationResponse {
    pub key: String,
    pub source_path: String,
    pub source: SourceSpan,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct DiagnosticsResponse {
    pub diagnostics: Vec<DiagnosticItem>,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct DiagnosticItem {
    pub file_path: String,
    pub entry_id: Option<i64>,
    pub severity: String,
    pub code: String,
    pub message: String,
    pub target_kind: String,
    pub source: Option<SourceSpan>,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct DuplicateGroupsResponse {
    pub groups: Vec<DuplicateGroupItem>,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct DuplicateGroupItem {
    pub key: String,
    pub entries: Vec<EntryRefItem>,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct EntryRefItem {
    pub id: i64,
    pub key: String,
    pub source_path: String,
}

#[must_use]
pub fn clamp_limit(limit: Option<usize>) -> usize {
    limit.unwrap_or(DEFAULT_LIMIT).min(MAX_LIMIT)
}

#[derive(Debug, Error)]
#[error("{inner}")]
pub struct JsonRpcError {
    inner: JsonRpcErrorObject,
}

impl JsonRpcError {
    #[must_use]
    pub fn new(inner: JsonRpcErrorObject) -> Self {
        Self { inner }
    }

    #[must_use]
    pub fn into_inner(self) -> JsonRpcErrorObject {
        self.inner
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn success_response_omits_error() {
        let response = JsonRpcResponse::success(Value::from(1), serde_json::json!({"ok": true}));
        let encoded = serde_json::to_value(response).expect("response should serialize");
        assert_eq!(encoded["jsonrpc"], "2.0");
        assert_eq!(encoded["id"], 1);
        assert!(encoded.get("result").is_some());
        assert!(encoded.get("error").is_none());
    }

    #[test]
    fn domain_error_shape_is_stable() {
        let error = JsonRpcErrorObject::domain(-32002, "unknown_key", "missing".to_string());
        let encoded = serde_json::to_value(error).expect("error should serialize");
        assert_eq!(encoded["code"], -32002);
        assert_eq!(encoded["data"]["kind"], "unknown_key");
    }

    #[test]
    fn limits_are_clamped() {
        assert_eq!(clamp_limit(None), DEFAULT_LIMIT);
        assert_eq!(clamp_limit(Some(5)), 5);
        assert_eq!(clamp_limit(Some(MAX_LIMIT + 1)), MAX_LIMIT);
    }
}
