# Changelog

All notable changes to this project will be documented in this file.

The format follows Keep a Changelog, and this project follows SemVer.

## [Unreleased]

## [0.5.1] - 2026-05-17

### Fixed
- Made the buffer-backed library-save regression test independent of
  environment-specific final-newline handling for fake PDF buffers, matching
  Citar's `save-buffer` behavior instead of hard-coding text-mode output.

## [0.5.0] - 2026-05-17

### Changed
- Added enforced generated-corpus benchmark thresholds for the 100k-entry release profile and 1M-entry local profile.
- Made citeproc CSL style and locale configuration use Citar-shaped single directory values instead of list-valued directory knobs.
- Removed unused simple indicator knobs; `refbox-indicators` is now the single authoritative indicator configuration path.
- Removed the separate note and cited predicate knobs; note and cited indicators now use the same `refbox-indicators` path as other indicators.
- Removed duplicate file and crossref field-name knobs; `refbox-file-variable` and `refbox-crossref-variable` now own those contracts.
- Removed the extra Markdown single-key insertion command; Markdown insertion now follows Citar's `insert-keys` and `insert-citation` surface.
- Made `refbox-file-sources` use Citar-shaped source plists instead of named alist entries.
- Made the daemon corpus configuration match the Emacs configuration: multiple bibliography roots, explicit bibliography files, discovery extensions, include/exclude globs, and hidden-file policy are now sent through one authoritative sync path.
- Let explicit bibliography files participate in full sync and targeted autosync even when they live outside discovery roots.
- Route reference-list formatting through the Emacs citeproc integration instead of a daemon-side placeholder formatter.
- Let `make test-elisp TESTS=...` run a single ERT selector or a space-separated selector list for scoped parity work.
- Renamed `refbox-search-tag-aliases` to `refbox-search-tag-shortcuts` as the single public configuration point for terse search tags.

### Fixed
- Bounded ranked FTS searches by preselecting a small match window before ranking and preferring exact-token matches before prefix fallback, avoiding multi-second broad searches on million-entry corpora.
- Resolved bibliography `file` fields against both source-relative directories and configured library paths instead of stopping after the first non-empty root set.
- Treated single string values for bibliography, library, notes, extension, and discovery-glob options as one configured item instead of iterating them character by character.
- Autoloaded mode-local citation inspection helpers and Org citation processors so callers see the same public surface as Citar without preloading feature files.
- Autoloaded the indicator struct, citeproc reference formatter, and default Org note formatter to match Citar's package surface for user configuration.
- Preserved duplicate-key entries, including same-file duplicates, by using daemon row ids for completion identity, entry lookup, resources, raw entry text, and source locations.
- Indexed Org and LaTeX local bibliography files through explicit incremental sync before scoped searches, with freshness caching so local CAPF and insertion work for files outside configured roots.
- Treated Org and LaTeX local bibliography files as scoped additions to the configured corpus, matching Citar selection behavior without leaking ad-hoc local files into unrelated searches.
- Batched Org activation hydration by exact citation keys instead of issuing per-key entry lookups during citation activation.
- Used bounded daemon key filters for `is:cited` and enumerable `has:notes` searches instead of pulling broad result pages into Emacs for post-filtering.
- Removed implicit whole-bibliography materialization from entry/resource/note helper paths; global note listing now requires note-source enumeration instead of scanning every reference.
- Recognized BibLaTeX `\addbibresource[...]{...}` declarations when scoping LaTeX completion and insertion to local bibliography files.
- Used RefTeX's bibliography file list when available so LaTeX project bibliography discovery matches Citar-backed setups.
- Normalized indexed field values with Citar-style string expansion, title brace cleanup, and raw-entry preservation so display, search, and resource lookup no longer expose ordinary BibTeX delimiters.
- Added bounded Emacs diagnostic and duplicate-key list commands backed by daemon RPCs, with source jumps from the list views.
- Routed exact multi-key hydration through one daemon request while preserving Citar-style first-hit duplicate-key lookup.
- Allocated star-width template remainders deterministically so multi-star completion displays consume the requested display width.
- Bounded Markdown citation detection to containing bracket syntax state instead of scanning backward through unrelated bracketed text.
- Used exact Markdown citation-key spans for at-point and Embark targets, including brace-delimited Pandoc keys.
- Parsed LaTeX citation optional arguments with escaped brackets and brace-protected bracket content instead of stopping at the first `]`.
- Matched Citar's default completion indicator order: links, files, notes, then cited-in-buffer.
- Applied cross-reference resource inheritance to daemon resource filters and resource-kind summaries, so `has:files` and `has:links` match Citar-style parent resources without broad Emacs post-filtering.
- Made `refbox-link-fields` the single authority for link indicators, `has:links` daemon filters, and opened link URLs, matching Citar's default DOI/PMID/PMCID/URL behavior.
- Made interactive reference insertion and copying select references before calling custom formatters, matching the Citar command contract.
- Parsed LaTeX bibliography declarations with balanced optional and braced groups, so spaced `\bibliography` and complex `\addbibresource` forms still scope local searches.
- Carried note-source completion categories through resource choices and Embark targets, with file-backed notes exposed as file resources by default.
- Normalized protective braces out of indexed `author` and `editor` values to match Citar's parsebib-backed field values.
- Hydrated preview, note, and configured additional fields on bounded completion candidates so selected-reference actions see the same metadata Citar parsed for them.
- Honored mandatory string arguments in configured LaTeX citation command specs instead of dropping non-key required arguments.
- Preserved empty LaTeX optional-argument slots when later optional citation arguments are supplied.
- Parsed existing LaTeX citations with the configured command specs so mandatory non-key arguments no longer masquerade as citation keys.
- Matched Citar's Org, LaTeX, and Markdown citation prompt labels.
- Initialized new Org note files with Citar's title/body/print-bibliography layout and side-effecting formatter contract.
- Exposed Org property-drawer `@key` references as Embark key targets.
- Stopped mutating completion category defaults while loading the package.
- Made local bibliography export use the single `refbox-export-local-bib-file` path and derive `local-bib.<ext>` from the first configured bibliography, matching Citar.
- Used citekeys verbatim for generated note filenames and treated additional-file separators as regexps when enumerating file-backed note keys.
- Matched Citar's formatted-reference copy behavior by copying only non-empty output and echoing the copied text.
- Matched Citar's BibTeX insertion/export spacing by writing a blank line after the final exported entry.
- Matched Citar's generic citation insertion contract by selecting references before dispatching to mode adapters.
- Matched Citar's empty `refbox-open` error shape by including the selected reference keys in the no-resource message.
- Matched Citar's generic citation-edit fallback by reporting unsupported editing instead of silently inserting a new citation.
- Collapsed Zotero opening to the `refbox-open-entry-in-zotero` entry opener and preserved URL targets in the external opener.
- Matched Citar's template reference formatter by concatenating preview output without an extra separator.
- Matched Citar's DWIM/default-action contract by erroring when no citation is at point and passing default-action references through unchanged.
- Removed extra interactive selection echo messages from reference readers and selectors.
- Matched Citar's citeproc formatter contract by returning citeproc's formatted bibliography string directly.
- Matched Citar's template formatter by preserving text properties attached to field placeholders.
- Matched Citar's template width parsing for empty, zero, zero-padded, and nonnumeric width markers.
- Matched Citar's CAPF return contract by exposing annotation and completion-exit hooks directly.
- Matched Citar's Org citation style previews and keymap activation side effects.
- Matched Citar's Org citation style variant expansion order and shape.
- Matched Citar's Org activation typo suggestions with a bounded daemon edit-distance query.
- Matched Citar's Org citation reference shifting rewrite behavior for prefix and suffix text.
- Removed extra Org style minibuffer history state so style selection follows Citar's prompt contract.
- Matched Citar's Org citation-at-point boundary checks when reusing parsed citation elements.
- Matched Citar's LaTeX insert-edit adapter by ignoring the prefix argument at the mode-specific edit layer.
- Matched Citar's LaTeX key-listing path by preferring RefTeX's citation scanner when available.
- Matched Citar's Markdown insert-edit adapter by ignoring the prefix argument at the mode-specific edit layer.
- Matched Citar's Embark target contracts for citation key strings, multi-category candidates, minibuffer guards, and citation keymaps.
- Marked the single-reference Embark copy action as multi-target capable, matching Citar's Embark action surface.
- Matched Citar's citeproc style metadata and selection contract by returning titles and storing selected style filenames.
- Trimmed the default reference and citation action keymaps to Citar's visible bindings.
- Pushed exact-key hydration limits into store queries instead of materializing every duplicate-key entry before truncating.
- Matched Citar's reference action argument contract by passing programmatic nil references through instead of prompting.
- Matched Citar's unsupported citation-insertion contract by reserving the hard error for interactive insertion.
- Matched Citar's resource action argument contract by moving reference selection into interactive specs instead of programmatic nil calls.
- Matched Citar's BibTeX insertion contract by treating programmatic nil references as empty output instead of prompting.
- Matched Citar's local bibliography export behavior by writing an empty file when the current buffer has no citations.
- Matched Citar's note action argument contract by moving note/reference selection into interactive specs instead of programmatic nil calls.
- Matched Citar's mode citation-adapter contract by keeping reference selection in `insert-edit` and generic insertion paths.
- Matched Citar's citeproc formatter contract by treating programmatic nil references as empty output.
- Matched Citar's exact-key selection behavior by allowing completion UIs to accept keys outside the current result page.
- Fixed `refbox-insert-raw-entry` so the documented interactive command selects references and programmatic nil inserts nothing.
- Bounded cross-reference resource inheritance by preferring same-source parent entries instead of inheriting from every duplicate parent key in the corpus.
- Matched Citar's add-file command contract by validating library paths, sources, and writer configuration before prompting for a file source.
- Matched Citar's library-file save behavior for empty extensions, raw citekey filenames, and add-file prompt labels.
- Matched Citar's LaTeX citation editing by inserting selected keys as supplied instead of dropping duplicates.
- Matched Citar's Org citation insertion by treating a non-nil style argument as a request to select a style.
- Fixed triplet file-field parsing so commas inside file names do not prevent Citar-style resource discovery.
- Matched Citar's link formatting by always applying `refbox-link-fields` templates and honoring string field keys.
- Matched Citar's file-backed note creation by using `find-file` for new note buffers instead of the configurable note opener.
- Matched Citar's file-backed note creation contract by requiring a note formatter for newly created notes.
- Matched Citar's note-source contract by requiring `:hasitems` instead of materializing note items for note predicates.
- Matched Citar's resource selection prompt text across file, link, note, attach, and generic open commands.
- Kept LaTeX citation command configuration on Citar's alist-shaped command-spec path instead of accepting a second ad hoc shape.
- Matched Citar's multi-reference selection prompt by showing selected and indexed-total counts without materializing candidates in Emacs.
- Matched Citar's resource opener return contract by returning the configured file/link opener result instead of the target path.
- Matched Citar's public entry accessor behavior by returning nil for unknown keys and using first-hit duplicate-key lookup.
- Matched Citar's Embark citation-edit behavior by ignoring injected targets for the citation edit action.
- Matched Citar's multi-reference toggle behavior by restoring selection history when a chosen reference is deselected.
- Matched Citar's resource selection display by offering raw file/link/note strings, Citar-style group transforms, target deduplication, and reference-shaped create-note rows.
- Matched Citar's command-state resource prompting by using `this-command` for single-resource prompts and forced create-note offers.
- Matched Citar's literal file and note extension handling, including case-sensitive resource filters and empty additional-file separators.
- Matched Citar's Markdown citation affix insertion by preserving user-supplied spacing instead of trimming prefix and suffix text.
- Matched Citar's Org style completion by preserving empty style selections and applying style/variant faces to completion candidates.
- Matched Citar's buffer-backed add-file behavior when the destination is the current buffer's visited file.
- Matched Citar's add-file directory choices by preserving configured and recursive library directory strings in the prompt.
- Matched Citar's resource completion metadata by exposing file, URL, note-source, and mixed-resource categories.
- Matched Citar's prompt-local Embark default actions for resource selection prompts.
- Matched Citar's file resource aggregation by combining file-field resources with same-key library-path resources.
- Matched Citar's file-field resolution against every explicit bibliography file directory while keeping root discovery out of Emacs.
- Matched Citar's bibliography cache identity by truename-normalizing active local bibliography files and erroring on missing local bibliography declarations.
- Matched Citar's duplicate-key lookup semantics by returning the first indexed duplicate while keeping duplicate groups queryable.
- Matched Citar's public mode adapter return contract for citation keys and whole citations at point.
- Matched Citar's Org reference-shifting point preservation and boundary error messages.
- Matched Citar's Org citation deletion and kill-region behavior for current citation datums.
- Matched Citar's Org prefix/suffix update rewrite and citation keymap bindings.
- Matched Citar's Org follow processor by routing citation clicks through `org-open-at-point`.
- Restored the default completion indicator fast path while preserving Citar's link/file/note/cited order.
- Routed Org citation insertion through Org's native insert dispatcher instead of a local dispatcher copy.
- Removed extra Org style override/default variables so style completion follows Org's supported style registry.
- Removed extra Markdown citation default/separator variables so insertion follows Citar's fixed Pandoc shape.
- Removed extra LaTeX optional-argument and key-separator variables so citation insertion follows Citar's fixed command shape.

## [0.4.8] - 2026-05-17

### Fixed
- Added Citar-style short indicator search shortcuts such as `:p`, `:f`, `:n`, `:l`, and `:c`.
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
