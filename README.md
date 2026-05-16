# refbox

`refbox` is a local-first bibliography engine with an Emacs front-end.

Bibliography files stay as plain `.bib` source files. The daemon builds a
derived SQLite index from those files and answers bounded JSON-RPC queries over
stdio. Emacs starts the daemon on demand, keeps session state, and presents
commands for search, citation editing, resources, notes, source lookup, and
completion.

## Install

Build from source with the system SQLite library:

```bash
make release
```

The daemon binary is written to `target/release/refbox`. Put that binary on
`PATH`, or point Emacs at it with `refbox-server-program`.

For a portable daemon binary with SQLite compiled in, use:

```bash
make release-bundled-sqlite
```

Bundled SQLite builds require a C compiler toolchain. Tagged release workflows
publish `refbox-<platform>.tar.gz` archives containing the daemon binary,
`LICENSE`, and a `.sha256` checksum. The Emacs package files are the root
`refbox*.el` files in this repository.

Add the repository to Emacs' `load-path`:

```elisp
(add-to-list 'load-path "/path/to/refbox")
(require 'refbox)
```

## Configure

Minimal daemon configuration:

```elisp
(setq refbox-server-program "refbox")
(setq refbox-bibliography-roots '("~/bibliography"))
;; Optional explicit files outside the discovery roots.
;; (setq refbox-bibliography '("~/work/project/references.bib"))
(setq refbox-database-file
      (expand-file-name "refbox.sqlite" user-emacs-directory))

(refbox-autosync-mode 1)
```

The daemon indexes every directory in `refbox-bibliography-roots` plus every
file in `refbox-bibliography`.  The SQLite database is derived state. If it is
deleted while the daemon is not running, `M-x refbox-sync` can rebuild it from
the configured bibliography corpus.
`refbox-autosync-mode` performs that sync when it is enabled, then keeps files
edited through Emacs current with targeted file updates.

Useful resource, note, and formatting options:

```elisp
(setq refbox-library-paths '("~/papers"))
(setq refbox-library-paths-recursive t)
(setq refbox-notes-paths '("~/notes/references"))

;; Optional CSL formatting through citeproc.
(setq refbox-citeproc-csl-styles-dir '("~/csl/styles"))
(setq refbox-citeproc-csl-locales-dir '("~/csl/locales"))
(setq refbox-citeproc-csl-style "apa")
(setq refbox-citeproc-csl-locale "en-US")
```

## First Sync

Run:

```text
M-x refbox-sync
```

This starts the daemon if needed, discovers bibliography files under configured
roots, includes explicit bibliography files, parses changed files, and updates
the derived index. Check index state with:

```text
M-x refbox-status
```

When `refbox-autosync-mode` is enabled, saving a tracked bibliography file
updates that file in the index. Without autosync, use:

```text
M-x refbox-sync-current-file
```

or sync an explicit file with `M-x refbox-sync-file`. Renames and deletes made
through Emacs are also tracked by autosync mode.

## Daily Use

Reference selection is backed by bounded daemon search:

```text
M-x refbox-read-reference
M-x refbox-read-references
```

Open associated material:

```text
M-x refbox-open
M-x refbox-open-files
M-x refbox-open-links
M-x refbox-open-notes
M-x refbox-create-note
```

Open or insert source data:

```text
M-x refbox-open-source
M-x refbox-insert-raw-entry
M-x refbox-export-bibliography
```

Inspect indexed bibliography problems:

```text
M-x refbox-list-diagnostics
M-x refbox-list-duplicates
```

Formatted references use the `preview` entry in `refbox-templates` by default.
For CSL output, set `refbox-format-reference-function` to
`refbox-citeproc-format-reference` and configure citeproc:

```text
M-x refbox-citeproc-select-csl-style
M-x refbox-insert-reference
M-x refbox-copy-reference
```

Add a file, URL, or current buffer to the configured library directory:

```text
M-x refbox-add-file-to-library
```

## Org

Load the Org integration and enable completion in Org buffers:

```elisp
(with-eval-after-load 'org
  (require 'refbox-org)
  (refbox-org-register-processor)
  (add-hook 'org-mode-hook #'refbox-org-setup-capf))
```

Use:

```text
M-x refbox-org-insert-citation
M-x refbox-org-set-reference-prefix
M-x refbox-org-set-reference-suffix
M-x refbox-org-shift-reference-left
M-x refbox-org-shift-reference-right
M-x refbox-org-delete-citation
M-x refbox-org-kill-citation
M-x refbox-org-follow-at-point
```

Org completion is active inside Org citation references and is scoped by Org's
declared bibliography files when they are present.

## LaTeX

Load the LaTeX integration and enable completion in TeX buffers:

```elisp
(require 'refbox-latex)
(add-hook 'latex-mode-hook #'refbox-latex-setup-capf)
(add-hook 'LaTeX-mode-hook #'refbox-latex-setup-capf)
(add-hook 'tex-mode-hook #'refbox-latex-setup-capf)
```

Use:

```text
M-x refbox-latex-insert-citation
```

Relevant options:

```elisp
(setq refbox-latex-default-cite-command "cite")
(setq refbox-latex-prompt-for-cite-style nil)
(setq refbox-latex-prompt-for-extra-arguments nil)
```

LaTeX completion is active inside recognized citation commands. Bibliography
scoping uses `\bibliography{...}`, `\addbibresource{...}`,
`reftex-default-bibliography`, `LaTeX-bibliography-list`, and readable
`TeX-master` files.

## Markdown

Load the Markdown integration and enable completion:

```elisp
(require 'refbox-markdown)
(add-hook 'markdown-mode-hook #'refbox-markdown-setup-capf)
(add-hook 'gfm-mode-hook #'refbox-markdown-setup-capf)
```

Use:

```text
M-x refbox-markdown-insert-citation
M-x refbox-markdown-insert-key
```

Relevant options:

```elisp
(setq refbox-markdown-prompt-for-extra-arguments nil)
(setq refbox-markdown-default-prefix nil)
(setq refbox-markdown-default-suffix nil)
```

Markdown insertion uses Pandoc-style `[@key]` citations.

## CAPF And Embark

For a generic completion hook, use:

```elisp
(add-hook 'completion-at-point-functions #'refbox-capf)
```

Mode-specific setup commands are usually better because they install a
buffer-local completion function:

```text
M-x refbox-capf-setup
M-x refbox-org-setup-capf
M-x refbox-latex-setup-capf
M-x refbox-markdown-setup-capf
```

Embark integration is optional:

```elisp
(with-eval-after-load 'embark
  (require 'refbox-embark)
  (refbox-embark-setup))
```

It adds targets for refbox completion candidates and citation keys at point.
Actions include opening resources, files, links, notes, source entries, raw
entries, copying formatted references, and adding library files.

## Diagnostics

Malformed bibliography files do not discard the entire corpus. Sync preserves
recoverable entries and stores parse diagnostics in the derived index.

`M-x refbox-status` reports the current diagnostic count, and
`M-x refbox-list-diagnostics` opens a bounded diagnostic list with source
jumps. `M-x refbox-list-duplicates` lists duplicate-key groups. After fixing a
source file, run `M-x refbox-sync-current-file` from that buffer or
`M-x refbox-sync` for the full root.

## Performance

Interactive paths request bounded result sets from the daemon. Completion and
reference selection do not send the full bibliography to Emacs.

Benchmark reports are written as JSON under `target/refbox-bench/`:

```bash
make bench-ci       # 2k generated entries, CI p95 gates
make bench-release  # 100k generated entries
make bench-local    # 1M generated entries
```

For a real corpus, provide the root, query, and a key with resources:

```bash
REFBOX_BENCH_REAL_ROOT=/path/to/bibliography \
REFBOX_BENCH_REAL_QUERY=searchterm \
REFBOX_BENCH_REAL_KEY=key-with-files \
make bench-real
```

Set `REFBOX_BENCH_REAL_SOURCE_PATH` as well when the key is duplicated across
source files.

Benchmark reports distinguish daemon query latency from Emacs candidate
rendering latency.

## Troubleshooting

`refbox server executable not found`: build the daemon with `make release`, put
`target/release/refbox` on `PATH`, or set `refbox-server-program` to an
absolute executable path.

`refbox bibliography root does not exist`: check `refbox-bibliography-roots`.
The current daemon uses the first configured root.

Stale search results: enable `refbox-autosync-mode`, or run
`M-x refbox-sync-current-file` after editing one bibliography file. Use
`M-x refbox-sync` after changing many files outside Emacs. If needed, shut down
Emacs, remove `refbox-database-file`, and run `M-x refbox-sync` to rebuild the
derived index.

Malformed bibliography files: run `M-x refbox-list-diagnostics`, open the
reported source location, fix the `.bib` source file, and sync again.

Missing file resources: check `file` fields, `refbox-library-paths`,
`refbox-library-paths-recursive`, and
`refbox-library-file-extensions`. `M-x refbox-add-file-to-library`
writes new files into the first configured library path.

Missing links: `refbox-open-links` uses indexed URL and identifier fields such
as `url`, `doi`, `pmid`, and `pmcid`, configured by `refbox-link-fields`.

Missing notes: configure `refbox-notes-paths` and
`refbox-file-note-extensions`. Use `M-x refbox-create-note` to create the
default note file for a reference.

## Development

Use `CHANGELOG.md` for durable change notes and `AGENTS.md` for project
invariants.

`make test` is the local all-checks entry point. It runs Rust formatting checks,
clippy, Rust tests, Emacs batch tests, byte compilation, and the conservative
CI benchmark gate:

```bash
make test
```

Source builds:

```bash
make build
make build-bundled-sqlite
make release
make release-bundled-sqlite
```
