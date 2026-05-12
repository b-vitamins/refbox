# Changelog

All notable changes to this project will be documented in this file.

The format follows Keep a Changelog, and this project will follow SemVer once it starts making releases.

## [Unreleased]

### Added
- Initialized the repository charter, architecture guardrails, release policy, and verification conventions.
- Added a Rust workspace scaffold, JSON-RPC protocol types, stdio daemon, Emacs client, and load tests.
- Codified the native-API product stance: no compatibility shims or comparative positioning.
- Documented the `0.1.0` product contract, workflow families, non-goals, and milestone map.
- Added serializable core records for bibliography files, entries, fields, names, dates, source spans, resource fields, diagnostics, global key lookup, and duplicate-key reporting.
- Added a recoverable BibTeX/BibLaTeX parser with fixtures for valid, mixed, and malformed bibliography files.
- Added the first SQLite store schema, migration, parsed-file insertion, duplicate-key queries, diagnostics/source queries, and bounded FTS search.
- Added bibliography discovery policy, file freshness metadata, full-root sync, single-file sync, stale-file pruning, and file removal.
- Added typed JSON-RPC contracts and daemon handlers for status, sync, indexed files, search, lookup, raw entries, source locations, diagnostics, and duplicate groups.
