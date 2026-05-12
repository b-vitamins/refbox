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
(setq refbox-database-file
      (expand-file-name "refbox.sqlite" user-emacs-directory))
```

The current daemon indexes the first directory in `refbox-bibliography-roots`.
The SQLite database is derived state. If it is deleted while the daemon is not
running, `M-x refbox-sync` can rebuild it from the bibliography root.

Useful resource, note, and formatting options:

```elisp
(setq refbox-resource-library-paths '("~/papers"))
(setq refbox-resource-library-paths-recursive t)
(setq refbox-note-paths '("~/notes/references"))

(setq refbox-csl-style-directories '("~/csl/styles"))
(setq refbox-csl-locale-directories '("~/csl/locales"))
(setq refbox-csl-style "apa")
(setq refbox-csl-locale "en-US")
```

## First Sync

Run:

```text
M-x refbox-sync
```

This starts the daemon if needed, discovers bibliography files under the root,
parses changed files, and updates the derived index. Check index state with:

```text
M-x refbox-status
```

After editing a bibliography file, use:

```text
M-x refbox-sync-current-file
```

or sync an explicit file with `M-x refbox-sync-file`.

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

Formatted references require `refbox-csl-style`, `refbox-csl-locale`, and their
directories, unless `refbox-format-reference-function` supplies custom
formatting:

```text
M-x refbox-select-csl-style
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
M-x refbox-org-delete-at-point
M-x refbox-org-kill-at-point
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
(setq refbox-latex-default-command "cite")
(setq refbox-latex-prompt-for-command nil)
(setq refbox-latex-prompt-for-optional-arguments nil)
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
(setq refbox-markdown-prompt-for-affixes nil)
(setq refbox-markdown-default-prefix nil)
(setq refbox-markdown-default-suffix nil)
```

Markdown insertion uses Pandoc-style `[@key]` citations.

## CAPF And Embark

For a generic completion hook, use:

```elisp
(add-hook 'completion-at-point-functions #'refbox-completion-at-point)
```

Mode-specific setup commands are usually better because they install a
buffer-local completion function:

```text
M-x refbox-setup-capf
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

`M-x refbox-status` reports the current diagnostic count. After fixing a source
file, run `M-x refbox-sync-current-file` from that buffer or `M-x refbox-sync`
for the full root.

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

Stale search results: run `M-x refbox-sync-current-file` after editing one
bibliography file, or `M-x refbox-sync` after changing many files. If needed,
shut down Emacs, remove `refbox-database-file`, and run `M-x refbox-sync` to
rebuild the derived index.

Malformed bibliography files: run `M-x refbox-status` and check the diagnostic
count. Fix the `.bib` source file and sync again.

Missing file resources: check `file` fields, `refbox-resource-library-paths`,
`refbox-resource-library-paths-recursive`, and
`refbox-resource-library-file-extensions`. `M-x refbox-add-file-to-library`
writes new files into the first configured library path.

Missing links: `refbox-open-links` uses indexed URL and identifier fields such
as `url`, `doi`, `pmid`, and `pmcid`, plus `refbox-resource-link-templates`.

Missing notes: configure `refbox-note-paths` and
`refbox-note-file-extensions`. Use `M-x refbox-create-note` to create the
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
