# refbox

`refbox` is a local-first bibliography engine with an Emacs front-end.

It is designed for large BibTeX and BibLaTeX corpora. Bibliography files remain
the source of truth, while a derived index supports interactive search,
citation selection, source lookup, and resource workflows. The Rust side owns
parsing, normalization, indexing, ranking, and query execution. The Emacs Lisp
side owns commands, session state, editing integration, and presentation.

## Status

This repository is under active development. Work remains under `Unreleased`
until the project reaches the first daily-use workflow target.

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
