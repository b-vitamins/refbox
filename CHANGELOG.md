# Changelog

All notable changes to this project will be documented in this file.

The format follows Keep a Changelog, and this project will follow SemVer once it starts making releases.

## [Unreleased]

### Added
- Initialized the repository charter, architecture guardrails, release policy, and verification conventions.
- Added a Rust workspace scaffold, JSON-RPC protocol types, stdio daemon, Emacs client, and load tests.
- Codified native public API ownership and documentation guardrails.
- Documented the `0.1.0` product contract, workflow families, non-goals, and milestone map.
- Added serializable core records for bibliography files, entries, fields, names, dates, source spans, resource fields, diagnostics, global key lookup, and duplicate-key reporting.
- Added a recoverable BibTeX/BibLaTeX parser with fixtures for valid, mixed, and malformed bibliography files.
- Added the first SQLite store schema, migration, parsed-file insertion, duplicate-key queries, diagnostics/source queries, and bounded FTS search.
- Added bibliography discovery policy, file freshness metadata, full-root sync, single-file sync, stale-file pruning, and file removal.
- Added typed JSON-RPC contracts and daemon handlers for status, sync, indexed files, search, lookup, raw entries, source locations, diagnostics, and duplicate groups.
- Added Emacs daemon configuration, executable/database validation, explicit status and sync commands, and lifecycle tests.
- Added bounded Emacs reference selection, display templates, candidate annotations, and search-result field metadata.
- Added Org citation insertion, editing, follow dispatch, activation keymap behavior, and local bibliography discovery.
- Added LaTeX citation detection, insertion, replacement, optional argument handling, and local bibliography discovery.
- Added Pandoc-style Markdown citation insertion, detection, replacement, affix prompts, and current-buffer key listing.
- Added indexed resource lookup, cross-reference resource inheritance, file/link/note resource actions, and note filename generation.
