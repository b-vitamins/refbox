# refbox

`refbox` is a local-first bibliography engine with an Emacs front-end.

It is designed for large BibTeX and BibLaTeX corpora. Bibliography files remain
the source of truth, while a derived index supports interactive search,
citation selection, source lookup, and resource workflows. The Rust side owns
parsing, normalization, indexing, ranking, and query execution. The Emacs Lisp
side owns commands, session state, editing integration, and presentation.

## Status

This repository is under active development. Work remains under `Unreleased`
until the project satisfies the `0.1.0` release contract below.

## 0.1.0 Contract

`0.1.0` is the first daily-use release of the native bibliography workflow. A
user should be able to keep bibliography files as the source of truth, run an
indexed daemon over those files, and use Emacs commands that request bounded
results from the daemon instead of materializing the full corpus in Elisp.

The release must cover these first-class workflow families:

- sync and freshness reporting for configured bibliography roots
- search, selection, lookup, and display of indexed references
- citation insertion and citation editing in Org, LaTeX, and Markdown buffers
- resource actions for files, links, and identifier-backed references
- note actions that are explicit, indexed where appropriate, and testable
- source lookup for opening the bibliography entry behind a reference
- parse and index diagnostics that remain queryable from Emacs
- completion-at-point integration backed by bounded daemon queries
- Embark integration for contextual reference actions
- reference formatting with explicit style selection

The public API is native to `refbox`: command names, user options, RPC methods,
and data contracts are defined by this project.

### Non-Goals For 0.1.0

- alternate command, variable, or package-name aliases
- full-corpus Elisp completion tables or full-corpus Elisp-side formatting
- a database as the source of truth for bibliography content
- citation workflow support outside Org, LaTeX, and Markdown

## 0.1.0 Milestone Map

- Product contract: #1
- Core records and parsing: #2, #3
- Store, sync, and RPC: #4, #5, #6
- Emacs lifecycle and indexed selection: #7, #8
- Citation workflows: #9, #10, #11
- Resources, actions, and formatting: #12, #13, #14
- Completion and contextual actions: #15, #16
- Contracts, benchmarks, packaging, and release docs: #17, #18, #19, #20

## Architecture

- Source files stay plain `.bib` files.
- The index is derived and rebuildable.
- The daemon exposes bounded JSON-RPC queries over stdio.
- Emacs never receives or formats the full bibliography for completion.
- Incremental sync keeps changed files fresh without rebuilding unrelated
  corpus state.

## Development

The project will ship as one repository containing:

- a Rust workspace for the daemon, indexer, query engine, and protocol types
- root-level Emacs Lisp files for the frontend package

Use `CHANGELOG.md` for durable change notes and `AGENTS.md` for project
invariants.

Current checks:

```bash
make test
```
