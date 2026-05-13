# Changelog

All notable changes to this project will be documented in this file.

The format follows Keep a Changelog, and this project will follow SemVer once it starts making releases.

## [Unreleased]

### Added
- Added `refbox-autosync-mode` to sync on enable, update tracked bibliography files after save, and keep the index current after Emacs rename/delete operations.

### Changed
- Replaced the internal BibTeX parser with the `bibtex-parser` crate.

### Fixed
- Reduced index storage growth for large collaboration papers by storing compact per-person name text instead of duplicating full author lists for every parsed name.
- Reduced full-sync work by refreshing duplicate-key groups once per bulk sync instead of after every changed file.
- Removed unused span-shadow storage and an unused broad field-value index from the SQLite schema to keep large bibliography indexes smaller.
- Made indexed search build safe FTS prefix queries from user input and added FTS prefix indexes so title, author, identifier, and key fragments work naturally for type-ahead completion.
- Fixed scoped Emacs RPC requests so Org and LaTeX citation completion send JSON arrays for source-path filters.
- Made targeted single-file sync obey the same discovery policy as full sync.

## [0.1.0] - 2026-05-12

### Added
- Added a local-first bibliography workflow where `.bib` files remain the source of truth and a rebuildable SQLite index powers interactive use.
- Added a Rust daemon with JSON-RPC over stdio for status, full sync, single-file sync, indexed search, key lookup, raw entries, source locations, resources, diagnostics, duplicate keys, and formatted references.
- Added recoverable BibTeX/BibLaTeX parsing with source spans, normalized fields, names, dates, resources, duplicate-key reporting, and queryable diagnostics for malformed files.
- Added Emacs commands for daemon lifecycle, status, sync, bounded reference selection, display templates, source opening, raw-entry insertion, local bibliography export, and formatted reference copy/insert workflows.
- Added Org, LaTeX, and Markdown citation insertion and editing workflows, including local bibliography discovery where the mode exposes it.
- Added indexed resource workflows for files, links, notes, library-file creation, cross-reference resource inheritance, and configurable open/create functions.
- Added completion-at-point support for Org, LaTeX, and Markdown citation contexts, backed by bounded daemon queries rather than full-corpus Elisp tables.
- Added optional Embark targets and action maps for reference candidates and citation keys at point.
- Added source and binary build targets, CI verification, release archive packaging, checksums, and documentation for installation and daily use.
- Added deterministic scale benchmark profiles with JSON reports, CI regression thresholds, 100k-entry release coverage, 1M-entry local coverage, real-corpus validation, daemon query timings, and Emacs candidate-rendering timings.
