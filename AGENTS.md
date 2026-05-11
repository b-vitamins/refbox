# AGENTS

## Purpose
- Build `refbox` as a local-first bibliography engine with an Emacs front-end.
- Keep the architecture honest: BibTeX and BibLaTeX files are the source of truth, the index is derived, and interactive paths must stay sublinear in corpus size.
- Target large personal and research corpora from the start. A design that only works by materializing every reference in Emacs is out of bounds.

## Guardrails
- Keep hot paths out of Emacs Lisp. Parsing, normalization, indexing, ranking, and query execution belong in Rust.
- Do not send the full bibliography to Emacs. Completion and lookup surfaces must request bounded result sets from the daemon.
- Do not let hidden global state decide correctness. The daemon must expose freshness explicitly and writes must have read-your-writes semantics.
- Use dedicated incremental index updates for changed bibliography files. Do not route file-level sync through full-root rebuild logic.
- Treat duplicate keys, duplicate works, parse diagnostics, source locations, files, links, notes, and citation editing as first-class product surfaces.
- Do not silently discard malformed entries. Indexing may preserve partial records, but diagnostics must stay queryable and visible.
- Do not add command, variable, or package-name compatibility layers for other bibliography packages. `refbox` owns its own public API.
- Do not introduce circular crate or feature dependencies. Domain types stay in `refbox-core`; transport types stay in `refbox-rpc`.
- Avoid load-time side effects in Elisp. User-facing commands may start the daemon, but simply loading the package must not mutate user state.
- Keep expensive discovery off redisplay and completion hot paths. Background sync, explicit refresh, and indexed queries are the only scalable paths.
- Do not add competitive copy, migration pressure, or dismissive comparisons to documentation or code comments. Let the product surface explain itself.
- Keep documentation tight. Use `README.md`, `CHANGELOG.md`, and code comments; do not create ad hoc planning markdown files.

## Release Policy
- Work under `Unreleased` in `CHANGELOG.md`.
- Treat `v0.1.0` as a complete native bibliography workflow, not a protocol or search prototype.
- Do not tag or claim `v0.1.0` until the project genuinely supports sync and freshness reporting, search and selection, citation insertion and editing for Org/LaTeX/Markdown, resource actions, note actions, source lookup, diagnostics, CAPF, Embark actions, reference formatting, and indexed refresh workflows.
- Keep the `v0.1.0` contract aligned across `README.md`, `CHANGELOG.md`, milestone issues, and implemented behavior.
- Use Conventional Commits for every commit message.
- Keep history readable: commit at coherent milestones after tests pass.

## Repository Conventions
- Prefer a single repository containing the Rust workspace and the Emacs package.
- Keep Emacs package entry files at the repository root for straightforward ELPA packaging.
- Keep package headers strict: lexical binding, `Package-Requires`, `Version`, commentary, and no false metadata.
- Maintain GPL-3.0-or-later licensing across Rust and Elisp code.
- Favor stable protocol boundaries over in-process integration tricks. JSON-RPC over stdio is the default boundary.
- Keep the daemon and Emacs package separable. The Emacs side should work with a `refbox` executable on `PATH` or an explicit `refbox-server-program`.

## Verification
- Run `cargo fmt`, `cargo test --workspace`, and `cargo clippy --all-targets --all-features` before milestone commits when the codebase supports them.
- Run Emacs batch checks before milestone commits once Elisp commands exist.
- Add regression tests with every bug fix touching parsing, indexing, query semantics, source-location tracking, or protocol behavior.
- Maintain benchmark gates before the first release. Scale claims must come from generated and real-corpus measurements, not anecdotes.
