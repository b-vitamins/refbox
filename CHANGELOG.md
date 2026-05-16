# Changelog

All notable changes to this project will be documented in this file.

The format follows Keep a Changelog, and this project follows SemVer.

## [Unreleased]

## [0.4.8] - 2026-05-17

### Fixed
- Added Citar-style short indicator search aliases such as `:p`, `:f`, `:n`, `:l`, and `:c`.
- Exposed Refbox resource candidates to Embark so file and URL choices use native Embark actions while note/create-note choices keep Refbox actions.
- Aligned Refbox Embark reference actions with the main reference action map while preserving duplicate-key source identity and multi-target selection.
- Made CAPF completion return clean citation-key candidates with author/title annotations instead of minibuffer affixation, while hydrating only the fields needed for annotation.
- Kept duplicate completion rows visually clean by storing source-path identity in an invisible internal marker instead of appending full bibliography paths to the displayed candidate.

## [0.4.7] - 2026-05-16

### Changed
- Matched the standard file-opening dispatch model: HTML resources open externally, while other file resources use Emacs' normal `find-file` path unless users configure extension-specific openers.

### Fixed
- Hardened the optional PDF opener so it only enters `pdf-view-mode` after `pdf-tools` has initialized the state that `pdf-view-mode` expects.
- Prevented the optional mode-specific file opener from exposing raw PDF bytes through auto-mode or magic-mode before activating the requested viewer.

## [0.4.6] - 2026-05-16

### Changed
- Moved the standard completion row shaping into the daemon response so the common minibuffer UI no longer formats author, year, title, key, and type columns in Elisp.
- Used a bounded ranked FTS preselection window for unfiltered ranked searches, cutting broad real-corpus search latency while preserving deterministic final ordering inside the window.
- Optimized default completion indicators by using daemon resource-kind summaries and a direct fixed-slot renderer.
- Updated the real-corpus rendering benchmark to measure the warmed steady-state completion path with the same GC budget used by interactive completion.

## [0.4.5] - 2026-05-16

### Changed
- Kept common minibuffer prefixes on the fast unranked FTS path for longer, avoiding broad ranked queries while users are still typing.
- Added a direct formatter for the standard reference completion templates, cutting generic Elisp template overhead on the hot path.
- Reduced completion GC pressure while shaping candidate pages.

### Fixed
- Avoided structural hashing of full candidate plists while caching completion indicators.
- Skipped cold recursive library-note/file indicator work when no cheap lookup is available.
- Made disabled note and cited indicator predicates actually suppress their backing lookups.

## [0.4.4] - 2026-05-16

### Changed
- Raised the default non-completion search page size to 100.
- Raised the single-RPC search/list page safety ceiling to 10,000 so explicit larger requests are not silently capped at 100.
- Clarified that completion limits are UI page-size defaults, separate from backend index scale.

## [0.4.3] - 2026-05-16

### Fixed
- Preserve padded main completion fields before appending key/type suffix columns, keeping reference rows aligned for short and long titles.
- Pad fixed-width template fields by display columns rather than character count.

## [0.4.2] - 2026-05-15

### Fixed
- Open PDF resources through a dedicated PDF opener by default instead of the generic file opener.
- Load `pdf-view-mode`/`doc-view-mode` on demand before opening PDFs in Emacs.
- Fall back to the external file opener when no Emacs PDF viewer is available, instead of leaving raw PDF bytes in a Fundamental-mode buffer.
- Kill stale unmodified raw PDF buffers from earlier opener attempts before reopening the file.

## [0.4.1] - 2026-05-15

### Changed
- Moved recursive library-file and file-field resolution onto daemon RPCs so resource selection no longer walks large library trees in Elisp.
- Made resolved indexed `file` fields terminal in the default resource source chain, avoiding pointless library fallback scans when the bibliography already names an existing file.
- Tightened daemon-side file scanning by avoiding per-entry metadata probes on ordinary files and by filtering extensions before key matching.
- Reduced completion rendering overhead by skipping expensive regexp cleanup on already-normalized field values.
- Polished resource choices to show file basenames in the main candidate text while keeping full directories in annotations.

### Fixed
- Opened file resources through `refbox-file-open-in-emacs` by default so stale raw PDF buffers are refreshed and `pdf-view-mode` is applied when available.
- Corrected README option names for library file extensions and file-backed notes.

## [0.4.0] - 2026-05-15

### Changed
- Polished the reference completion surface with explicit Refbox faces for main and suffix columns while preserving field-specific faces.
- Made completion display width frame-aware and kept indicator affixation width-stable for richer Vertico-style UIs.
- Updated the multi-reference selector to reuse the active minibuffer exit binding so RET accepts the current candidate and exits reliably.

### Fixed
- Cleaned protective BibTeX braces from shortened author/editor names in completion candidates.
- Lazily loaded Org, LaTeX, and Markdown CAPF adapters from the generic `refbox-capf` entry point.
- Closed citation integration parity gaps across Org activation, Markdown postnotes, LaTeX point placement, Embark targets/actions, note source enumeration, freeform presets, exact-key fallback, and default ellipsis handling.
- Resolved Org CSL locale fallback lookup through Org's bundled CSL directory when the user has not configured a separate locale directory.

## [0.3.0] - 2026-05-15

### Changed
- Made dynamic reference completion use native index matching for type-ahead input while keeping Emacs completion styles from discarding valid non-prefix hits.
- Shaped minibuffer reference candidates with Citar-style main and suffix display columns plus affixation indicators.
- Reduced completion-path RPC payloads by bounding hydrated fields, omitting full resources, returning resource-kind summaries, and skipping per-field source spans.
- Updated the real-corpus benchmark to measure the same lightweight completion request shape used by the Emacs UI.

### Fixed
- Preserved selected reference identity across completion UI redisplay/probe calls so accepting a displayed candidate returns the indexed reference reliably.
- Added one-character FTS prefix indexing for first-keystroke typeahead over large bibliographies.
- Increased the default RPC request timeout so one-time schema migrations and cold index setup can finish without spurious Emacs-side timeouts.

## [0.2.1] - 2026-05-14

### Changed
- Updated the `bibtex-parser` dependency to `0.3.1`.

## [0.2.0] - 2026-05-14

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
