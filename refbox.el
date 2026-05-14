;;; refbox.el --- Local-first bibliography tools -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Ayan Das

;; Author: Ayan Das <bvits@riseup.net>
;; Maintainer: Ayan Das <bvits@riseup.net>
;; Version: 0.2.1
;; Package-Requires: ((emacs "29.1") (jsonrpc "1.0.27"))
;; Keywords: bib, tex, files, convenience

;; This file is not part of GNU Emacs.

;; refbox is free software: you can redistribute it and/or modify
;; it under the terms of the GNU General Public License as published by
;; the Free Software Foundation, either version 3 of the License, or
;; (at your option) any later version.
;;
;; refbox is distributed in the hope that it will be useful,
;; but WITHOUT ANY WARRANTY; without even the implied warranty of
;; MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
;; GNU General Public License for more details.
;;
;; You should have received a copy of the GNU General Public License
;; along with refbox.  If not, see <https://www.gnu.org/licenses/>.

;;; Commentary:

;; refbox provides a local-first bibliography workflow backed by a dedicated
;; index and query engine.  This file contains the package entry points and
;; user-facing commands.

;;; Code:

(require 'browse-url)
(require 'cl-lib)
(require 'seq)
(require 'subr-x)
(require 'xml)
(require 'refbox-rpc)

(defface refbox
  '((t :inherit default))
  "Base face for refbox completion candidates."
  :group 'refbox)

(defface refbox-highlight
  '((t :inherit highlight))
  "Face for highlighted refbox text."
  :group 'refbox)

(defface refbox-title
  '((t :inherit font-lock-function-name-face))
  "Face for reference titles."
  :group 'refbox)

(defface refbox-year
  '((t :inherit shadow))
  "Face for reference years."
  :group 'refbox)

(defface refbox-author
  '((t :inherit font-lock-variable-name-face))
  "Face for reference authors and editors."
  :group 'refbox)

(defface refbox-journal
  '((t :inherit font-lock-string-face))
  "Face for journals, publishers, and containers."
  :group 'refbox)

(defface refbox-tags
  '((t :inherit font-lock-keyword-face))
  "Face for reference tags and keywords."
  :group 'refbox)

(defface refbox-note-highlight
  '((t :inherit font-lock-doc-face))
  "Face for note-oriented reference text."
  :group 'refbox)

(defface refbox-org-highlight
  '((t :inherit link))
  "Face for activated Org citations."
  :group 'refbox)

(defface refbox-org-style-preview
  '((t :inherit completions-annotations))
  "Face for Org citation style previews."
  :group 'refbox)

(defface refbox-selection
  '((t :inherit highlight))
  "Face for selected refbox references."
  :group 'refbox)

(declare-function org-cite-get-references "oc" (citation))
(declare-function org-element-parent "org-element" (element))
(declare-function org-element-property "org-element" (property element))
(declare-function org-element-type "org-element" (element))
(declare-function mml-attach-file "mml" (file &optional type description disposition))
(declare-function refbox-org-local-bib-files "refbox-org" (&optional buffer))
(declare-function refbox-org-citation-at-point "refbox-org" (&optional datum))
(declare-function refbox-org-insert-citation "refbox-org" (&optional arg))
(declare-function refbox-org-key-at-point "refbox-org" (&optional datum))
(declare-function refbox-org-list-keys "refbox-org" (&optional buffer))
(declare-function refbox-org-completion-at-point "refbox-org" ())
(declare-function refbox-latex-local-bib-files "refbox-latex" (&optional buffer))
(declare-function refbox-latex-citation-at-point "refbox-latex" ())
(declare-function refbox-latex-insert-citation "refbox-latex" (&optional arg))
(declare-function refbox-latex-key-at-point "refbox-latex" ())
(declare-function refbox-latex-list-keys "refbox-latex" (&optional buffer))
(declare-function refbox-latex-completion-at-point "refbox-latex" ())
(declare-function refbox-markdown-citation-at-point "refbox-markdown" ())
(declare-function refbox-markdown-insert-citation "refbox-markdown" (&optional arg))
(declare-function refbox-markdown-insert-keys "refbox-markdown" (keys))
(declare-function refbox-markdown-key-at-point "refbox-markdown" ())
(declare-function refbox-markdown-list-keys "refbox-markdown" (&optional buffer))
(declare-function refbox-markdown-completion-at-point "refbox-markdown" ())

(defcustom refbox-default-action #'refbox-open
  "Function called by `refbox-run-default-action'.

The function receives a list of references.  A reference may be a
completion candidate plist or a citation key string."
  :type 'function
  :group 'refbox)

(defcustom refbox-at-point-function #'refbox-dwim
  "Function run by `refbox-at-point'."
  :type 'function
  :group 'refbox)

(defcustom refbox-at-point-fallback 'prompt
  "Fallback used by `refbox-dwim' when no citation key is at point.

When the value is `prompt' or t, `refbox-dwim' prompts for
references and runs `refbox-default-action'.  When nil, it signals
a user error instead."
  :type '(choice (const :tag "Prompt" prompt)
                 (const :tag "Prompt (t)" t)
                 (const :tag "Error" nil))
  :group 'refbox)

(defcustom refbox-autosync-sync-on-enable t
  "Whether `refbox-autosync-mode' performs a full sync when enabled.

This catches bibliography edits made outside Emacs before the current
session.  Save, rename, and delete events still use targeted file sync."
  :type 'boolean
  :group 'refbox)

(defcustom refbox-open-resources '(:files :links :notes :create-notes)
  "Resource types offered by `refbox-open'."
  :type '(set (const :tag "Files" :files)
              (const :tag "Links" :links)
              (const :tag "Notes" :notes)
              (const :tag "Create notes" :create-notes))
  :group 'refbox)

(defcustom refbox-open-prompt
  '(refbox-open refbox-attach-files refbox-open-note)
  "Commands that should prompt even when there is only one resource.

When nil, commands open a single resource without prompting.  When
t, all resource-opening commands prompt.  Otherwise the value is a
list of command symbols."
  :type '(choice (const :tag "Always prompt" t)
                 (const :tag "Prompt only for multiple resources" nil)
                 (repeat function))
  :group 'refbox)

(defcustom refbox-open-always-create-notes nil
  "Whether note-opening commands should always offer note creation.

When nil, note creation is offered only when a reference has no
existing note.  When t, it is always offered.  Otherwise the value
is a list of command symbols for which creation is always offered."
  :type '(choice (const :tag "Always offer creation" t)
                 (const :tag "Only when no note exists" nil)
                 (repeat function))
  :group 'refbox)

(defcustom refbox-major-mode-functions
  '(((org-mode) .
     ((local-bib-files . refbox-org-local-bib-files)
      (insert-citation . refbox-org-insert-citation)
      (insert-edit . refbox-org-insert-edit)
      (key-at-point . refbox-org-key-at-point)
      (citation-at-point . refbox-org-citation-at-point)
      (list-keys . refbox-org-list-keys)))
    ((latex-mode LaTeX-mode tex-mode) .
     ((local-bib-files . refbox-latex-local-bib-files)
      (insert-citation . refbox-latex-insert-citation)
      (insert-edit . refbox-latex-insert-edit)
      (key-at-point . refbox-latex-key-at-point)
      (citation-at-point . refbox-latex-citation-at-point)
      (list-keys . refbox-latex-list-keys)))
    ((markdown-mode gfm-mode) .
     ((insert-keys . refbox-markdown-insert-keys)
      (insert-citation . refbox-markdown-insert-citation)
      (insert-edit . refbox-markdown-insert-edit)
      (key-at-point . refbox-markdown-key-at-point)
      (citation-at-point . refbox-markdown-citation-at-point)
      (list-keys . refbox-markdown-list-keys)))
    (t .
       ((insert-keys . refbox--insert-keys-comma-space-separated))))
  "Major-mode adapters used by generic refbox commands.

Each entry maps a mode list, or t as a fallback, to an alist of
adapter functions.  Supported adapter keys are `local-bib-files',
`insert-keys', `insert-citation', `insert-edit', `key-at-point',
`citation-at-point', and `list-keys'."
  :type 'alist
  :group 'refbox)

(defcustom refbox-templates
  '((main . "${author editor:30%sn}     ${date year issued:4}     ${title:48}")
    (suffix . "          ${=key= id:15}    ${=type=:12}    ${tags keywords keywords:*}")
    (preview . "${author editor:%etal} (${year issued date}) ${title}, ${journal journaltitle publisher container-title collection-title}.\n")
    (note . "Notes on ${author editor:%etal}, ${title}"))
  "Reference display templates.

This alist may contain `main', `suffix', `preview', and `note'
entries.  Template strings may use `${field:width%transform}' or
`%{field:width!function}' placeholders."
  :type '(alist :key-type symbol :value-type string)
  :group 'refbox)

(defcustom refbox-additional-fields nil
  "Additional bibliography fields expected by local configuration.

Refbox indexes all parsed fields, so these names do not limit ingestion;
they document fields referenced by display, resource, or downstream
configuration."
  :type '(repeat string)
  :group 'refbox)

(defcustom refbox-display-transform-functions
  '((sn . (refbox--shorten-names))
    (etal . (refbox--shorten-names 3 "&")))
  "Alist mapping template transform keys to function calls.

Each entry is (KEY . FORM), where FORM is a list whose car is called
with the field value and whose cdr supplies additional arguments."
  :type '(alist :key-type symbol :value-type sexp)
  :group 'refbox)

(defcustom refbox-reference-display-width 100
  "Display width used when formatting star-width reference templates."
  :type 'natnum
  :group 'refbox)

(defcustom refbox-ellipsis nil
  "String used to mark truncated template fields.

When nil, truncated fields end at the configured display width
without adding a marker."
  :type '(choice (const :tag "No marker" nil) string)
  :group 'refbox)

(defcustom refbox-capf-limit 50
  "Maximum number of reference candidates requested for CAPF completion."
  :type 'natnum
  :group 'refbox)

(defcustom refbox-reference-resource-indicator "F"
  "Indicator used when a reference has local resource fields."
  :type 'string
  :group 'refbox)

(defcustom refbox-reference-link-indicator "L"
  "Indicator used when a reference has external link fields."
  :type 'string
  :group 'refbox)

(defcustom refbox-reference-note-indicator "N"
  "Indicator used when `refbox-reference-note-predicate' matches."
  :type 'string
  :group 'refbox)

(defcustom refbox-reference-cited-indicator "C"
  "Indicator used when `refbox-reference-cited-predicate' matches."
  :type 'string
  :group 'refbox)

(defcustom refbox-reference-resource-field-names '("file")
  "Field names treated as local resource fields for candidate indicators."
  :type '(repeat string)
  :group 'refbox)

(defcustom refbox-reference-link-field-names
  '("url" "doi" "pmid" "pmcid" "eprint")
  "Field names treated as external link fields for candidate indicators."
  :type '(repeat string)
  :group 'refbox)

(defcustom refbox-reference-note-predicate #'refbox-reference-has-notes-p
  "Function called with a candidate to decide whether it has a note."
  :type '(choice (const :tag "Disabled" nil) function)
  :group 'refbox)

(defcustom refbox-reference-cited-predicate
  #'refbox-reference-cited-in-current-buffer-p
  "Function called with a candidate to decide whether it is cited."
  :type '(choice (const :tag "Disabled" nil) function)
  :group 'refbox)

(defcustom refbox-symbols
  '((file . ("F" . " "))
    (note . ("N" . " "))
    (link . ("L" . " ")))
  "Alist of simple present/absent symbols for file, note, and link indicators."
  :type '(alist :key-type symbol
                :value-type (cons (string :tag "Present")
                                  (string :tag "Absent"))
                :options (file note link))
  :group 'refbox)

(defcustom refbox-symbol-separator " "
  "Padding inserted between simple indicator symbols."
  :type 'string
  :group 'refbox)

(cl-defstruct
    (refbox-indicator (:constructor refbox-indicator-create)
                      (:copier nil))
  "A reference indicator specification."
  (tag nil)
  (symbol nil)
  (padding " ")
  (emptysymbol "")
  (function nil)
  (compiledfunction nil))

(defvar refbox-indicator-files
  (refbox-indicator-create
   :symbol refbox-reference-resource-indicator
   :function #'refbox-has-files
   :tag "has:files")
  "Default indicator for references with files.")

(defvar refbox-indicator-links
  (refbox-indicator-create
   :symbol refbox-reference-link-indicator
   :function #'refbox-has-links
   :tag "has:links")
  "Default indicator for references with links.")

(defvar refbox-indicator-notes
  (refbox-indicator-create
   :symbol refbox-reference-note-indicator
   :function #'refbox-has-notes
   :tag "has:notes")
  "Default indicator for references with notes.")

(defvar refbox-indicator-cited
  (refbox-indicator-create
   :symbol refbox-reference-cited-indicator
   :function #'refbox-is-cited
   :tag "is:cited")
  "Default indicator for references cited in the current buffer.")

(defcustom refbox-indicators
  (list refbox-indicator-files
        refbox-indicator-links
        refbox-indicator-notes
        refbox-indicator-cited)
  "Reference indicators rendered in completion candidates.

Each item is a `refbox-indicator' whose function returns a predicate
accepting a reference key or candidate."
  :type 'sexp
  :group 'refbox)

(defcustom refbox-crossref-field-names '("crossref")
  "Field names whose values name parent references.

Parent keys are used when resolving local file and note resources
that are discovered from configured directories rather than
returned directly by the daemon."
  :type '(repeat string)
  :group 'refbox)

(defcustom refbox-crossref-variable "crossref"
  "Primary field name whose value names a parent reference.

When non-nil, this field is included with `refbox-crossref-field-names'
while resolving related local files and notes."
  :type '(choice (const :tag "Disabled" nil) string)
  :group 'refbox)

(defcustom refbox-library-paths nil
  "Directories searched for files associated with references."
  :type '(repeat directory)
  :group 'refbox)

(defcustom refbox-library-paths-recursive nil
  "When non-nil, include subdirectories of `refbox-library-paths'."
  :type 'boolean
  :group 'refbox)

(defcustom refbox-library-file-extensions nil
  "File extensions accepted for associated files.

When nil, associated file lookup does not filter by extension."
  :type '(choice (const :tag "Any extension" nil)
                 (repeat string))
  :group 'refbox)

(defcustom refbox-file-variable "file"
  "Bibliography field name used for local file declarations."
  :type 'string
  :group 'refbox)

(defcustom refbox-resource-file-field-names '("file")
  "Indexed field names treated as file-resource fields."
  :type '(repeat string)
  :group 'refbox)

(defcustom refbox-file-parser-functions
  '(refbox-resource-parse-file-field-default
    refbox-resource-parse-file-field-triplet)
  "Functions used to parse file-resource field values."
  :type '(repeat function)
  :group 'refbox)

(defcustom refbox-file-sources
  '((indexed-fields
     :items refbox-resource-file-source-indexed-items
     :hasitems refbox-resource-file-source-indexed-has-items)
    (library-paths
     :items refbox-resource-file-source-library-items
     :hasitems refbox-resource-file-source-library-has-items))
  "Sources used to discover files associated with references.

Each source is an alist entry of the form (NAME . PLIST).  NAME
is a symbol identifying the source.  PLIST recognizes `:items'
and optional `:hasitems'.  Both functions receive CANDIDATE and
RESOURCES, where RESOURCES are the indexed resources already
loaded for CANDIDATE.  `:items' returns existing file names;
`:hasitems' should return non-nil when the source can report a
file association more cheaply than materializing all items."
  :type 'alist
  :group 'refbox)

(defcustom refbox-file-additional-files-separator nil
  "Regexp separating a reference key from additional file-name text."
  :type '(choice (const :tag "Ignore additional files" nil)
                 regexp)
  :group 'refbox)

(defcustom refbox-add-file-sources
  '((?b "buffer" "Current buffer" refbox-add-file-source-buffer)
    (?f "file" "Existing file" refbox-add-file-source-file)
    (?u "url" "Download from URL" refbox-add-file-source-url))
  "Sources offered by `refbox-add-file-to-library'.

Each source is a list containing a shortcut character, short name,
description, and function.  The function receives REFERENCE and returns
a source plist with `:write-file' and optional `:extension'.
`:write-file' is a function of DESTINATION and OVERWRITE with the same
overwrite convention as `copy-file'."
  :type '(repeat :tag "Sources for `refbox-add-file-to-library'"
                 (group (character :tag "Shortcut")
                        (string :tag "Name")
                        (string :tag "Description")
                        (function :tag "Source function")))
  :group 'refbox)

(defcustom refbox-add-file-function #'refbox-save-file-to-library
  "Function used by `refbox-add-file-to-library' to store a source.

The function receives REFERENCE and a source plist returned by one of
`refbox-add-file-sources'.  It should write the source and return the
destination file name."
  :type 'function
  :group 'refbox)

(defcustom refbox-file-open-functions
  '(("html" . refbox-file-open-external)
    (t . find-file))
  "Alist mapping file extensions to resource opening functions.

Keys are extension strings without a leading dot.  The entry with key
t is used as the default when no extension entry matches."
  :type '(repeat (cons
                  (choice (string :tag "Extension")
                          (symbol :tag "Default" t))
                  (function :tag "Function")))
  :group 'refbox)

(defcustom refbox-link-open-function #'browse-url
  "Function used to open link resources."
  :type 'function
  :group 'refbox)

(defcustom refbox-link-fields
  '((doi . "https://doi.org/%s")
    (pmid . "https://www.ncbi.nlm.nih.gov/pubmed/%s")
    (pmcid . "https://www.ncbi.nlm.nih.gov/pmc/articles/%s")
    (url . "%s"))
  "Alist mapping resource kinds to URL format strings."
  :type '(alist :key-type symbol :value-type string)
  :group 'refbox)

(defcustom refbox-notes-paths nil
  "Directories searched for per-reference note files."
  :type '(repeat directory)
  :group 'refbox)

(defcustom refbox-file-note-extensions '("org" "md")
  "File extensions used for per-reference notes."
  :type '(repeat string)
  :group 'refbox)

(defcustom refbox-open-note-function #'find-file
  "Function used to open note resources."
  :type 'function
  :group 'refbox)

(defcustom refbox-note-format-function #'refbox-org-format-note-default
  "Function called with KEY and CANDIDATE to initialize a new note."
  :type '(choice (const :tag "Empty note" nil) function)
  :group 'refbox)

(defcustom refbox-notes-source 'file
  "Selected note source used by note opening and creation commands."
  :type 'symbol
  :group 'refbox)

(defcustom refbox-notes-sources
  '((file
     :name "Notes"
     :items refbox-note-source-file-items
     :all-items refbox-note-source-file-all-items
     :hasitems refbox-note-source-file-has-items
     :open refbox-note-source-file-open
     :create refbox-note-source-file-create
     :create-label refbox-note-source-file-create-label
     :transform file-name-nondirectory))
  "Alist of note sources available to refbox.

Each entry is (SOURCE . PLIST).  Recognized plist keys are
`:items', `:all-items', `:hasitems', `:open', `:create',
`:create-label', and `:transform'.  `:items' and `:hasitems'
functions receive KEY and REFERENCE.  `:all-items' receives no
arguments and returns note items directly openable by `:open'.
`:open' receives a note item.  `:create' and `:create-label'
receive KEY and REFERENCE.  `:items' and `:open' are required
when registering a note source with `refbox-register-notes-source'."
  :type 'alist
  :group 'refbox)

(defcustom refbox-source-open-function #'find-file
  "Function used to open bibliography source files."
  :type 'function
  :group 'refbox)

(defcustom refbox-open-entry-function #'refbox-open-entry-in-file
  "Function used by `refbox-open-entry' to open a bibliography entry."
  :type 'function
  :group 'refbox)

(defcustom refbox-zotero-open-function #'browse-url
  "Function used to open Zotero select URLs."
  :type 'function
  :group 'refbox)

(defcustom refbox-bibtex-no-export-fields nil
  "Field names removed when exporting a local bibliography."
  :type '(repeat string)
  :group 'refbox)

(defcustom refbox-citeproc-csl-styles-dir nil
  "Directories containing CSL style files."
  :type '(repeat directory)
  :group 'refbox)

(defcustom refbox-citeproc-csl-locales-dir nil
  "Directories containing CSL locale files."
  :type '(repeat directory)
  :group 'refbox)

(defcustom refbox-citeproc-csl-style nil
  "Selected CSL style file or style id."
  :type '(choice (const :tag "Unset" nil) string)
  :group 'refbox)

(defcustom refbox-citeproc-csl-locale nil
  "Selected CSL locale file or locale id."
  :type '(choice (const :tag "Unset" nil) string)
  :group 'refbox)

(defcustom refbox-format-reference-function #'refbox-format-reference
  "Function used by reference insertion and copy commands.

The function receives a list of reference keys or candidates and returns
the formatted reference text."
  :type 'function
  :group 'refbox)

(defcustom refbox-library-file-name-function
  #'refbox-library-default-file-name
  "Function called with KEY and EXTENSION to name added library files."
  :type 'function
  :group 'refbox)

(defcustom refbox-presets nil
  "Predefined search strings offered by reference selection commands."
  :type '(repeat string)
  :group 'refbox)

(defcustom refbox-select-multiple t
  "Whether selection helpers should read multiple references by default.

When nil, `refbox-select-references' and `refbox-select-refs' use
single-reference selection even when their MULTIPLE keyword argument
is non-nil."
  :type 'boolean
  :group 'refbox)

(defvar refbox-history nil
  "Minibuffer history for refbox reference selection.")

(defvar refbox-autosync-mode)

(defvar refbox--autosync-suppress-after-save nil
  "Non-nil while an explicit sync path owns the current save.")

(defvar refbox-map
  (let ((map (make-sparse-keymap)))
    (define-key map (kbd "a") #'refbox-add-file-to-library)
    (define-key map (kbd "A") #'refbox-attach-files)
    (define-key map (kbd "b") #'refbox-insert-bibtex)
    (define-key map (kbd "c") #'refbox-insert-citation)
    (define-key map (kbd "e") #'refbox-open-entry)
    (define-key map (kbd "f") #'refbox-open-files)
    (define-key map (kbd "k") #'refbox-insert-keys)
    (define-key map (kbd "l") #'refbox-open-links)
    (define-key map (kbd "n") #'refbox-open-notes)
    (define-key map (kbd "N") #'refbox-open-note)
    (define-key map (kbd "o") #'refbox-open)
    (define-key map (kbd "r") #'refbox-copy-reference)
    (define-key map (kbd "R") #'refbox-insert-reference)
    (define-key map (kbd "z") #'refbox-open-in-zotero)
    (define-key map (kbd "RET") #'refbox-run-default-action)
    map)
  "Keymap for refbox reference actions.")

(defvar refbox-citation-map
  (let ((map (make-sparse-keymap)))
    (define-key map (kbd "i") #'refbox-insert-edit)
    (define-key map (kbd "o") #'refbox-open)
    (define-key map (kbd "e") #'refbox-open-entry)
    (define-key map (kbd "l") #'refbox-open-links)
    (define-key map (kbd "n") #'refbox-open-notes)
    (define-key map (kbd "f") #'refbox-open-files)
    (define-key map (kbd "b") #'refbox-insert-bibtex)
    (define-key map (kbd "r") #'refbox-copy-reference)
    (define-key map (kbd "RET") #'refbox-run-default-action)
    map)
  "Keymap for refbox citation actions.")

(defconst refbox-template--placeholder-regexp
  "\\(?:%{\\([^}\n]+\\)}\\|\\${\\([^}\n]+\\)}\\)"
  "Regexp matching supported refbox template placeholders.")

(defvar refbox-template--parse-cache (make-hash-table :test 'equal)
  "Cache of parsed reference templates keyed by template configuration.")

(defvar refbox--reference-field-cache nil
  "Dynamic cache of candidate field lookup tables.")

(defconst refbox--cache-miss (make-symbol "refbox-cache-miss")
  "Sentinel used for internal cache misses.")

(defvar refbox--dynamic-cache nil
  "Dynamic cache shared by one completion or rendering operation.")

(defmacro refbox--with-dynamic-cache (cache &rest body)
  "Run BODY with CACHE available to hot-path helpers."
  (declare (indent 1) (debug t))
  `(let ((refbox--dynamic-cache
          (or ,cache refbox--dynamic-cache (make-hash-table :test 'eq))))
     ,@body))

(defun refbox--dynamic-cache-get (namespace key producer)
  "Return cached value for NAMESPACE and KEY, or call PRODUCER."
  (if (null refbox--dynamic-cache)
      (funcall producer)
    (let* ((cache (or (gethash namespace refbox--dynamic-cache)
                      (puthash namespace
                               (make-hash-table :test 'equal)
                               refbox--dynamic-cache)))
           (value (gethash key cache refbox--cache-miss)))
      (if (eq value refbox--cache-miss)
          (puthash key (funcall producer) cache)
        value))))

(defun refbox--dynamic-cache-value (namespace key)
  "Return cached value for NAMESPACE and KEY, or `refbox--cache-miss'."
  (if-let ((cache (and refbox--dynamic-cache
                       (gethash namespace refbox--dynamic-cache))))
      (gethash key cache refbox--cache-miss)
    refbox--cache-miss))

(defun refbox--plist-get-any (plist &rest keys)
  "Return the first value in PLIST matching one of KEYS."
  (catch 'value
    (dolist (key keys)
      (when (plist-member plist key)
        (throw 'value (plist-get plist key))))
    nil))

(defun refbox--listify (value)
  "Return VALUE as a list when it is a JSON array or list."
  (cond
   ((null value) nil)
   ((vectorp value) (append value nil))
   ((listp value) value)
   (t nil)))

(defun refbox--candidate-value (candidate &rest keys)
  "Return the first value in CANDIDATE matching one of KEYS."
  (apply #'refbox--plist-get-any candidate keys))

(defun refbox--field-value (field)
  "Return bibliography FIELD's display value."
  (refbox--plist-get-any field :value))

(defun refbox--field-lookup-name (field)
  "Return bibliography FIELD's lookup name."
  (refbox--plist-get-any field :lookup_name :lookup-name))

(defun refbox--field-raw-name (field)
  "Return bibliography FIELD's raw name."
  (refbox--plist-get-any field :raw_name :raw-name))

(defun refbox--candidate-fields (candidate)
  "Return CANDIDATE bibliography fields as a list."
  (when (listp candidate)
    (refbox--listify (refbox--candidate-value candidate :fields))))

(defun refbox--candidate-resources (candidate)
  "Return CANDIDATE resources as a list."
  (when (listp candidate)
    (refbox--listify (refbox--candidate-value candidate :resources))))

(defun refbox--candidate-field-table (candidate)
  "Return cached field lookup table for CANDIDATE."
  (when (and refbox--reference-field-cache (listp candidate))
    (or (gethash candidate refbox--reference-field-cache)
        (let ((table (make-hash-table :test 'equal)))
          (dolist (field (refbox--candidate-fields candidate))
            (let ((value (refbox--field-value field))
                  (lookup-name (refbox--field-lookup-name field))
                  (raw-name (refbox--field-raw-name field)))
              (dolist (name (delq nil (list lookup-name raw-name)))
                (let ((normalized (refbox--field-name-normalize name)))
                  (unless (gethash normalized table)
                    (puthash normalized value table))))))
          (puthash candidate table refbox--reference-field-cache)))))

(defun refbox--resource-value (resource)
  "Return RESOURCE's raw value."
  (refbox--plist-get-any resource :value))

(defun refbox--resource-kind (resource)
  "Return RESOURCE's kind as a string."
  (let ((kind (refbox--plist-get-any resource :kind)))
    (cond
     ((symbolp kind) (symbol-name kind))
     ((stringp kind) kind)
     (t nil))))

(defun refbox--resource-lookup-name (resource)
  "Return RESOURCE's lookup field name."
  (refbox--plist-get-any resource :lookup_name :lookup-name))

(defun refbox--resource-owner-source-path (resource)
  "Return the bibliography file that owns RESOURCE."
  (refbox--plist-get-any resource
                         :owner_source_path :owner-source-path
                         :source_path :source-path))

(defun refbox--blank-string-p (value)
  "Return non-nil when VALUE is nil or an empty string."
  (or (null value)
      (and (stringp value) (string-empty-p (string-trim value)))))

(defun refbox--field-name-normalize (field)
  "Normalize FIELD for lookup against indexed bibliography fields."
  (downcase (string-trim field)))

(defun refbox--crossref-field-names ()
  "Return field names used for parent reference keys."
  (delete-dups
   (cl-remove-if
    #'refbox--blank-string-p
    (append refbox-crossref-field-names
            (list refbox-crossref-variable)))))

(defun refbox--file-field-names ()
  "Return field names used for local file declarations."
  (delete-dups
   (cl-remove-if
    #'refbox--blank-string-p
    (append refbox-resource-file-field-names
            refbox-reference-resource-field-names
            (list refbox-file-variable)))))

(defun refbox-reference-field (candidate field)
  "Return FIELD from CANDIDATE.

FIELD may name a protocol property such as key or source_path, a
computed property such as indicators, or an indexed bibliography field."
  (let ((field (refbox--field-name-normalize field)))
    (cond
     ((and (stringp candidate)
           (member field '("key" "citekey")))
      candidate)
     ((stringp candidate)
      nil)
     ((member field '("key" "citekey" "id" "=key="))
      (refbox--candidate-value candidate :key))
     ((member field '("source_path" "source-path" "source" "path"))
      (refbox--candidate-value candidate :source_path :source-path))
     ((member field '("entry_type" "entry-type" "type" "=type="))
      (refbox--candidate-value candidate :entry_type :entry-type))
     ((string= field "score")
      (let ((score (refbox--candidate-value candidate :score)))
        (when score (format "%s" score))))
     ((string= field "indicators")
      (refbox-reference-indicators candidate))
     (t
      (or
       (when-let ((table (refbox--candidate-field-table candidate)))
         (gethash field table))
       (cl-loop
        for indexed-field in (refbox--candidate-fields candidate)
        for lookup-name = (refbox--field-lookup-name indexed-field)
        for raw-name = (refbox--field-raw-name indexed-field)
        when (or (and lookup-name
                      (string= field (refbox--field-name-normalize lookup-name)))
                 (and raw-name
                      (string= field (refbox--field-name-normalize raw-name))))
        return (refbox--field-value indexed-field)))))))

(defun refbox-reference-has-field-p (candidate field)
  "Return non-nil when CANDIDATE has a non-empty FIELD."
  (not (refbox--blank-string-p (refbox-reference-field candidate field))))

(defun refbox-reference-has-any-field-p (candidate fields)
  "Return non-nil when CANDIDATE has any field in FIELDS."
  (cl-some (lambda (field)
             (refbox-reference-has-field-p candidate field))
           fields))

(defun refbox-reference-entry-alist (candidate)
  "Return CANDIDATE as a field alist suitable for data access helpers."
  (let ((alist (list (cons "key" (refbox-reference-field candidate "key"))
                     (cons "citekey" (refbox-reference-field candidate "key"))
                     (cons "=key=" (refbox-reference-field candidate "key"))
                     (cons "id" (refbox-reference-field candidate "key"))
                     (cons "entry_type" (refbox-reference-field candidate "entry_type"))
                     (cons "entry-type" (refbox-reference-field candidate "entry_type"))
                     (cons "type" (refbox-reference-field candidate "entry_type"))
                     (cons "=type=" (refbox-reference-field candidate "entry_type"))
                     (cons "source_path" (refbox-reference-field candidate "source_path"))
                     (cons "source-path" (refbox-reference-field candidate "source_path")))))
    (dolist (field (refbox--candidate-fields candidate))
      (let ((raw (refbox--field-raw-name field))
            (lookup (refbox--field-lookup-name field))
            (value (refbox--field-value field)))
        (when raw
          (push (cons raw value) alist))
        (when (and lookup (not (equal lookup raw)))
          (push (cons lookup value) alist))))
    (nreverse
     (cl-remove-if (lambda (item)
                     (refbox--blank-string-p (cdr item)))
                   alist))))

(defun refbox--entry-alist (citekey-or-entry)
  "Return CITEKEY-OR-ENTRY as an entry alist."
  (cond
   ((stringp citekey-or-entry)
    (refbox-get-entry citekey-or-entry))
   ((and (listp citekey-or-entry) (plist-member citekey-or-entry :key))
    (refbox-reference-entry-alist citekey-or-entry))
   ((and (listp citekey-or-entry)
	         (or (null citekey-or-entry) (consp (car citekey-or-entry))))
    citekey-or-entry)
   (t nil)))

(defun refbox--entry-candidate (key entry)
  "Return an indexed-candidate-shaped plist for KEY and ENTRY alist."
  (let ((entry (refbox--entry-alist entry)))
    (list :key key
          :entry_type (or (cdr (assoc-string "=type=" entry t))
                          (cdr (assoc-string "entry_type" entry t))
                          (cdr (assoc-string "entry-type" entry t))
                          (cdr (assoc-string "type" entry t)))
          :fields
          (cl-loop for (name . value) in entry
                   unless (member
                           (downcase (format "%s" name))
                           '("key" "citekey" "id" "=key="
                             "type" "=type=" "entry_type" "entry-type"
                             "source_path" "source-path"))
                   collect (list :raw_name (format "%s" name)
                                 :lookup_name
                                 (refbox--field-name-normalize (format "%s" name))
                                 :value value))
          :resources nil)))

(defun refbox-reference-has-resource-kind-p (candidate kind)
  "Return non-nil when CANDIDATE has an indexed resource of KIND."
  (let ((kind (if (symbolp kind) (symbol-name kind) kind)))
    (cl-some (lambda (resource)
               (equal (refbox--resource-kind resource) kind))
             (refbox--candidate-resources candidate))))

(defun refbox-reference-has-any-resource-kind-p (candidate kinds)
  "Return non-nil when CANDIDATE has an indexed resource from KINDS."
  (cl-some (lambda (kind)
             (refbox-reference-has-resource-kind-p candidate kind))
           kinds))

(defun refbox--reference-key-list (value)
  "Return bibliography keys parsed from VALUE."
  (let ((value (refbox-resource--clean-value value)))
    (cl-remove-if
     #'refbox--blank-string-p
     (mapcar #'string-trim
             (split-string value "[,;[:space:]\n]+" t)))))

(defun refbox-reference-crossref-keys (candidate &optional resources)
  "Return parent reference keys declared by CANDIDATE.

RESOURCES, when non-nil, supplies indexed resources already
loaded for CANDIDATE."
  (let ((names (mapcar #'refbox--field-name-normalize
                       (refbox--crossref-field-names)))
        keys)
    (dolist (field (refbox--candidate-fields candidate))
      (let ((lookup (refbox--field-lookup-name field))
            (raw (refbox--field-raw-name field)))
        (when (or (and lookup (member lookup names))
                  (and raw
                       (member (refbox--field-name-normalize raw) names)))
          (setq keys
                (append keys
                        (refbox--reference-key-list
                         (refbox--field-value field)))))))
    (dolist (resource (or resources (refbox--candidate-resources candidate)))
      (let ((lookup (refbox--resource-lookup-name resource))
            (kind (refbox--resource-kind resource)))
        (when (or (equal kind "crossref")
                  (and lookup (member lookup names)))
          (setq keys
                (append keys
                        (refbox--reference-key-list
                         (refbox--resource-value resource)))))))
    (delete-dups keys)))

(defun refbox-reference-related-keys (candidate &optional resources)
  "Return CANDIDATE's key followed by configured parent keys."
  (delete-dups
   (cl-remove-if
    #'refbox--blank-string-p
    (cons (refbox--reference-key candidate)
          (refbox-reference-crossref-keys candidate resources)))))

(defun refbox--reference-candidate (reference)
  "Return REFERENCE as an indexed candidate plist."
  (if (and (listp reference) (plist-member reference :key))
      reference
    (refbox-entry-by-key reference)))

(defun refbox-reference-has-files-p (candidate)
  "Return non-nil when CANDIDATE has an associated file resource."
  (refbox-resource-file-source-has-items-p
   candidate
   (refbox--candidate-resources candidate)))

(defun refbox-reference-has-links-p (candidate)
  "Return non-nil when CANDIDATE has an indexed link resource."
  (or (refbox-reference-has-any-resource-kind-p
       candidate '("url" "doi" "pmid" "pmcid"))
      (refbox-reference-has-any-field-p
       candidate refbox-reference-link-field-names)))

(defun refbox-reference-has-notes-p (candidate)
  "Return non-nil when CANDIDATE has an associated note."
  (refbox-note-source-has-items-p candidate))

(defun refbox-has-files ()
  "Return a predicate matching references with associated files.

The returned function accepts either an indexed candidate plist or a
reference key string."
  (lambda (reference)
    (refbox-reference-has-files-p (refbox--reference-candidate reference))))

(defun refbox-has-links ()
  "Return a predicate matching references with associated links.

The returned function accepts either an indexed candidate plist or a
reference key string."
  (lambda (reference)
    (refbox-reference-has-links-p (refbox--reference-candidate reference))))

(defun refbox-has-notes ()
  "Return a predicate matching references with associated notes.

The returned function accepts either an indexed candidate plist or a
reference key string."
  (lambda (reference)
    (refbox-reference-has-notes-p (refbox--reference-candidate reference))))

(defun refbox-is-cited ()
  "Return a predicate matching references cited in the current buffer.

The returned function accepts either an indexed candidate plist or a
reference key string."
  (lambda (reference)
    (refbox-reference-cited-in-current-buffer-p reference)))

(defun refbox--citation-buffer ()
  "Return the buffer whose citation context should be inspected."
  (if (minibufferp)
      (window-buffer (minibuffer-selected-window))
    (current-buffer)))

(defun refbox--current-citation-key-table ()
  "Return a cached table of citation keys in the current context buffer."
  (let ((buffer (refbox--citation-buffer)))
    (refbox--dynamic-cache-get
     'citation-keys
     (list buffer
           (and (buffer-live-p buffer)
                (buffer-chars-modified-tick buffer)))
     (lambda ()
       (let ((table (make-hash-table :test 'equal)))
         (when (buffer-live-p buffer)
           (with-current-buffer buffer
             (dolist (key (ignore-errors
                            (refbox-current-buffer-citation-keys buffer)))
               (unless (refbox--blank-string-p key)
                 (puthash key t table)))))
         table)))))

(defun refbox-reference-cited-in-current-buffer-p (candidate)
  "Return non-nil when CANDIDATE's key appears in the current buffer."
  (let ((key (refbox-reference-field candidate "key")))
    (and (not (refbox--blank-string-p key))
         (if refbox--dynamic-cache
             (gethash key (refbox--current-citation-key-table))
           (let ((buffer (refbox--citation-buffer)))
             (and (buffer-live-p buffer)
                  (with-current-buffer buffer
                    (save-excursion
                      (save-restriction
                        (widen)
                        (goto-char (point-min))
                        (search-forward key nil t))))))))))

(defun refbox--predicate-matches-p (predicate candidate)
  "Return non-nil when PREDICATE matches CANDIDATE."
  (and predicate
       (funcall predicate candidate)))

(defun refbox--indicator-predicate (indicator)
  "Return INDICATOR's cached predicate."
  (or (refbox-indicator-compiledfunction indicator)
      (when-let ((function (refbox-indicator-function indicator)))
        (let ((predicate (funcall function)))
          (setf (refbox-indicator-compiledfunction indicator) predicate)
          predicate))))

(defun refbox--indicator-text (indicator candidate)
  "Return INDICATOR text for CANDIDATE."
  (let* ((predicate (refbox--indicator-predicate indicator))
         (matched (and predicate (funcall predicate candidate)))
         (symbol (if matched
                     (refbox-indicator-symbol indicator)
                   (refbox-indicator-emptysymbol indicator)))
         (padding (refbox-indicator-padding indicator)))
    (unless (refbox--blank-string-p symbol)
      (concat symbol (or padding "")))))

(defun refbox-reference-indicators (candidate)
  "Return configured indicator text for CANDIDATE."
  (string-join
   (delq nil
         (mapcar (lambda (indicator)
                   (refbox--indicator-text indicator candidate))
                 refbox-indicators))
   ""))

(defun refbox-template-clean (value)
  "Return VALUE with common BibTeX wrapping and whitespace cleaned."
  (let ((text (string-trim (format "%s" (or value "")))))
    (while (and (> (length text) 1)
                (or (and (string-prefix-p "{" text)
                         (string-suffix-p "}" text))
                    (and (string-prefix-p "\"" text)
                         (string-suffix-p "\"" text))))
      (setq text (string-trim (substring text 1 -1))))
    (replace-regexp-in-string "[[:space:]\n\r\t]+" " " text)))

(defun refbox-template-author (value)
  "Return VALUE cleaned and propertized as an author/editor."
  (propertize (refbox-template-clean value) 'face 'refbox-author))

(defun refbox-template-title (value)
  "Return VALUE cleaned and propertized as a title."
  (propertize (refbox-template-clean value) 'face 'refbox-title))

(defun refbox-template-journal (value)
  "Return VALUE cleaned and propertized as a journal/container."
  (propertize (refbox-template-clean value) 'face 'refbox-journal))

(defun refbox-template-tags (value)
  "Return VALUE cleaned and propertized as tags or keywords."
  (propertize (refbox-template-clean value) 'face 'refbox-tags))

(defun refbox-template-year (value)
  "Return the first four-digit year found in VALUE."
  (let ((text (format "%s" (or value ""))))
    (if (string-match "[0-9][0-9][0-9][0-9]" text)
        (match-string 0 text)
      text)))

(defun refbox-template-year-face (value)
  "Return VALUE reduced to a year and propertized as a year."
  (propertize (refbox-template-year value) 'face 'refbox-year))

(defun refbox--shorten-name-position (names name)
  "Return NAME position in NAMES."
  (1+ (or (seq-position names name) -1)))

(defun refbox--shorten-name (name)
  "Return family name from NAME when it is written as \"family, given\"."
  (car (split-string name ", ")))

(defun refbox--shorten-names (names &optional truncate and-string)
  "Return shortened family names from BibTeX-style NAMES.

When TRUNCATE is an integer, include at most that many names and append
\"et al.\" when names were omitted.  AND-STRING replaces the final comma
between displayed names."
  (let* ((names (split-string (refbox-template-clean names) " and "))
         (name-count (length names))
         (truncated-names (seq-take names (or truncate name-count)))
         (truncated-count (length truncated-names)))
    (mapconcat
     (lambda (name)
       (let* ((short-name (refbox--shorten-name name))
              (position (refbox--shorten-name-position truncated-names name))
              (suffix
               (cond
                ((equal position truncated-count)
                 (if (< truncated-count name-count) " et al." ""))
                ((and and-string (equal position (1- truncated-count)))
                 (concat " " and-string " "))
                (t ", "))))
         (concat short-name suffix)))
     truncated-names
     "")))

(defun refbox-template--field-width (width)
  "Return normalized template WIDTH."
  (cond
   ((or (null width) (string-empty-p width) (string= width "0")) nil)
   ((string= width "*") '*)
   (t (string-to-number width))))

(defun refbox-template--split-fields (fields separator)
  "Return normalized FIELDS split using SEPARATOR."
  (let ((fields
         (if separator
             (split-string fields separator t "[[:space:]\n]+")
           (split-string-and-unquote fields))))
    (mapcar #'refbox--field-name-normalize fields)))

(defun refbox-template--display-transform (transform)
  "Return display transform call for TRANSFORM key."
  (unless (refbox--blank-string-p transform)
    (cdr (assoc (intern (string-trim transform))
                refbox-display-transform-functions))))

(defun refbox-template--parse-field (body &optional display-transform)
  "Parse placeholder BODY into a field token.

When DISPLAY-TRANSFORM is non-nil, parse `%TRANSFORM' through
`refbox-display-transform-functions'.  Otherwise parse `!FUNCTION' as a
direct function transform."
  (let* ((separator (if display-transform "%" "!"))
         (parts (split-string (string-trim body) separator))
         (field-part (car parts))
         (transform-part (cadr parts))
         width)
    (when (> (length parts) 2)
      (user-error "refbox template field has multiple transforms: %s" body))
    (when (or (null field-part) (string-empty-p (string-trim field-part)))
      (user-error "refbox template field is empty"))
    (when (and transform-part (string-empty-p (string-trim transform-part)))
      (user-error "refbox template transform is empty: %s" body))
    (when (string-match "\\`\\(.*?\\):[[:blank:]]*\\([0-9]+\\|\\*\\)[[:blank:]]*\\'"
                        field-part)
      (setq width (match-string 2 field-part)
            field-part (match-string 1 field-part)))
    (when (and display-transform
               (string-suffix-p ":" (string-trim-right field-part)))
      (setq field-part
            (string-remove-suffix ":" (string-trim-right field-part))))
    (let ((fields (refbox-template--split-fields
                   field-part
                   (unless display-transform "|"))))
      (when (null fields)
        (user-error "refbox template field is empty"))
      (list :fields fields
            :width (refbox-template--field-width width)
            :transform (cond
                        (display-transform
                         (refbox-template--display-transform transform-part))
                        (transform-part
                         (intern (string-trim transform-part)))
                        (t nil))))))

(defun refbox-template-parse (template)
  "Parse TEMPLATE into literal strings and field tokens."
  (unless (stringp template)
    (user-error "refbox template must be a string"))
  (let ((position 0)
        tokens)
    (while (string-match refbox-template--placeholder-regexp template position)
      (let ((match-start (match-beginning 0))
            (match-end (match-end 0))
            (field-body (or (match-string 1 template)
                            (match-string 2 template)))
            (display-transform (match-beginning 2)))
        (when (> match-start position)
          (push (substring template position match-start) tokens))
        (push (refbox-template--parse-field field-body display-transform)
              tokens)
        (setq position match-end)))
    (when (< position (length template))
      (push (substring template position) tokens))
    (nreverse tokens)))

(defun refbox-template--parsed (template)
  "Return cached parsed TEMPLATE."
  (let ((cache-key (list template refbox-display-transform-functions)))
    (or (gethash cache-key refbox-template--parse-cache)
        (puthash cache-key
                 (refbox-template-parse template)
                 refbox-template--parse-cache))))

(defun refbox-template--field-text (token candidate)
  "Return TOKEN text for CANDIDATE before width fitting."
  (let ((value (cl-loop
                for field in (plist-get token :fields)
                for field-value = (refbox-reference-field candidate field)
                when (not (refbox--blank-string-p field-value))
                return field-value))
        (transform (plist-get token :transform)))
    (setq value (refbox-template-clean value))
    (when transform
      (setq
       value
       (format
        "%s"
        (or
         (pcase transform
           ((pred symbolp)
            (unless (fboundp transform)
              (user-error "refbox template transform is not defined: %s"
                          transform))
            (funcall transform value))
           (`(,function . ,args)
            (unless (or (functionp function)
                        (and (symbolp function) (fboundp function)))
              (user-error "refbox template transform is not defined: %s"
                          function))
            (apply function value args))
           (_
            (user-error "refbox template transform is invalid: %S"
                        transform)))
         ""))))
    value))

(defun refbox-template--fit (value width)
  "Fit VALUE into WIDTH display columns."
  (if (null width)
      value
    (let ((truncated
           (truncate-string-to-width
            value
            width
            nil
            nil
            refbox-ellipsis)))
      (if (< (string-width truncated) width)
          (string-pad truncated width)
        truncated))))

(defun refbox-template-format (template candidate &optional width)
  "Format CANDIDATE with TEMPLATE and optional display WIDTH."
  (let* ((tokens (if (stringp template)
                     (refbox-template--parsed template)
                   template))
         rendered
         (used-width 0)
         (star-count 0))
    (dolist (token tokens)
      (let ((value (if (stringp token)
                       token
                     (refbox-template--field-text token candidate))))
        (push (cons token value) rendered)
        (cond
         ((stringp token)
          (setq used-width (+ used-width (string-width value))))
         ((eq (plist-get token :width) '*)
          (setq star-count (1+ star-count)))
         ((integerp (plist-get token :width))
          (setq used-width (+ used-width (plist-get token :width))))
         (t
          (setq used-width (+ used-width (string-width value)))))))
    (setq rendered (nreverse rendered))
    (let ((star-width (when (and width (> star-count 0))
                        (/ (max 0 (- width used-width)) star-count))))
      (mapconcat
       (lambda (rendered-token)
         (let* ((token (car rendered-token))
                (value (cdr rendered-token))
                (field-width (unless (stringp token)
                               (plist-get token :width))))
           (refbox-template--fit
            value
            (cond
             ((eq field-width '*) star-width)
             ((integerp field-width) field-width)
             (t nil)))))
	       rendered
	       ""))))

(defun refbox--template (name)
  "Return configured template NAME."
  (or (alist-get name refbox-templates)
      ""))

(defun refbox-reference-format-main (candidate &optional width)
  "Return the main display string for CANDIDATE."
  (string-trim-right
   (refbox-template-format
    (refbox--template 'main)
    candidate
    (or width refbox-reference-display-width))))

(defun refbox-reference-format-suffix (candidate &optional width)
  "Return the suffix display string for CANDIDATE."
  (string-trim-right
   (refbox-template-format
    (refbox--template 'suffix)
    candidate
    width)))

(defun refbox-reference-format-preview (candidate &optional width)
  "Return the preview display string for CANDIDATE."
  (refbox-template-format
   (refbox--template 'preview)
   candidate
   width))

(defun refbox-reference-format-note (candidate &optional width)
  "Return note-oriented display text for CANDIDATE."
  (refbox-template-format
   (refbox--template 'note)
   candidate
   width))

(defconst refbox-search--tag-resource-kinds
  '(("has:file" . ("file"))
    ("has:files" . ("file"))
    ("has:link" . ("url" "doi" "arxiv" "pmid" "pmcid"))
    ("has:links" . ("url" "doi" "arxiv" "pmid" "pmcid")))
  "Search tags that can be pushed into the daemon resource filter.")

(defconst refbox-search--post-filter-tags
  '("has:note" "has:notes" "is:cited")
  "Search tags evaluated from Emacs-side candidate predicates.")

(defun refbox-search--parse-query (query)
  "Return parsed QUERY as a plist with clean text and tags."
  (let (tokens resource-kinds post-filter-tags)
    (dolist (token (split-string (or query "") "[[:space:]\n\r\t]+" t))
      (let ((normalized (downcase token)))
        (cond
         ((alist-get normalized refbox-search--tag-resource-kinds nil nil #'equal)
          (setq resource-kinds
                (append (alist-get normalized
                                   refbox-search--tag-resource-kinds
                                   nil nil #'equal)
                        resource-kinds)))
         ((member normalized refbox-search--post-filter-tags)
          (push normalized post-filter-tags))
         (t
          (push token tokens)))))
    (list :query (string-join (nreverse tokens) " ")
          :resource-kinds (delete-dups (nreverse resource-kinds))
          :post-filter-tags (nreverse post-filter-tags))))

(defun refbox-search--candidate-matches-post-tag-p (candidate tag)
  "Return non-nil when CANDIDATE matches search TAG."
  (pcase tag
    ((or "has:note" "has:notes")
     (refbox--predicate-matches-p refbox-reference-note-predicate candidate))
    ("is:cited"
     (refbox--predicate-matches-p refbox-reference-cited-predicate candidate))
    (_ t)))

(defun refbox-search--post-filter (entries tags limit)
  "Return ENTRIES matching TAGS, capped at LIMIT."
  (let ((matches
         (cl-remove-if-not
          (lambda (candidate)
            (cl-every
             (lambda (tag)
               (refbox-search--candidate-matches-post-tag-p candidate tag))
             tags))
          entries)))
    (if (> (length matches) limit)
        (cl-subseq matches 0 limit)
      matches)))

(defun refbox-search-references (query &optional limit source-paths)
  "Search indexed references for QUERY using bounded LIMIT.

When SOURCE-PATHS is non-nil, restrict results to those
bibliography source files."
  (let* ((parsed (refbox-search--parse-query query))
         (clean-query (plist-get parsed :query))
         (resource-kinds (plist-get parsed :resource-kinds))
         (post-filter-tags (plist-get parsed :post-filter-tags))
         (requested-limit (refbox-rpc--search-limit limit))
         (rpc-limit (if post-filter-tags
                        (refbox-rpc--search-limit refbox-search-maximum-limit)
                      requested-limit))
         (source-paths
          (cl-remove-if
           #'refbox--blank-string-p
           (mapcar #'expand-file-name source-paths)))
         (response (refbox-rpc-request
                    refbox-rpc-method-search-entries
                    (append
                     (list :query clean-query
                           :limit rpc-limit)
                     (when source-paths
                       (list :source_paths (vconcat source-paths)))
                     (when resource-kinds
                       (list :resource_kinds (vconcat resource-kinds)))
                     (when (and (refbox--blank-string-p clean-query)
                                (or resource-kinds post-filter-tags))
                       (list :allow_empty_query t)))))
         (entries (plist-get response :entries)))
    (setq entries (refbox--listify entries))
    (if post-filter-tags
        (refbox--with-dynamic-cache nil
          (refbox-search--post-filter entries post-filter-tags requested-limit))
      entries)))

(defun refbox-list-references (&optional limit offset)
  "Return indexed reference candidates from OFFSET up to LIMIT.

This is a paged enumeration API for explicit whole-corpus callers;
interactive search paths should use `refbox-search-references'."
  (let* ((params (append (when limit (list :limit limit))
                         (when offset (list :offset offset))))
         (response (refbox-rpc-request refbox-rpc-method-list-entries params)))
    (refbox--listify (plist-get response :entries))))

(defun refbox-entry-by-key (reference)
  "Return the indexed reference candidate for REFERENCE.

REFERENCE may be a key string or a candidate plist carrying both key
and source path."
  (let* ((resolved (refbox-rpc-request
                    refbox-rpc-method-entry-by-key
                    (refbox--reference-rpc-params reference)))
         (key (plist-get resolved :key))
         (source-path (plist-get resolved :source_path))
         (candidates (refbox-search-references
                      key
                      refbox-search-maximum-limit
                      (and source-path (list source-path)))))
    (or (cl-find-if (lambda (candidate)
                      (and (equal (refbox-reference-field candidate "key") key)
                           (or (not source-path)
                               (equal (refbox-reference-field candidate "source_path")
                                      source-path))))
                    candidates)
        (append resolved (list :score 0.0 :fields nil :resources nil)))))

(defun refbox-get-entry (reference)
  "Return REFERENCE as a bibliography entry alist."
  (refbox-reference-entry-alist (refbox-entry-by-key reference)))

(defun refbox-get-entries (&optional limit)
  "Return a hash table of indexed bibliography entries.

When LIMIT is non-nil, return at most that many entries.  Without
LIMIT, enumerate the full index in daemon-sized pages."
  (let ((entries (make-hash-table :test 'equal))
        (remaining limit)
        (offset 0)
        (page-size refbox-search-maximum-limit)
        page)
    (while (and (or (null remaining) (> remaining 0))
                (setq page (refbox-list-references
                            (if remaining (min page-size remaining) page-size)
                            offset)))
      (dolist (candidate page)
        (puthash (refbox-reference-field candidate "key")
                 (refbox-reference-entry-alist candidate)
                 entries))
      (setq offset (+ offset (length page)))
      (when remaining
        (setq remaining (- remaining (length page)))))
    entries))

(defun refbox--all-reference-candidates (&optional limit)
  "Return indexed reference candidates, optionally bounded by LIMIT."
  (let ((remaining limit)
        (offset 0)
        (page-size refbox-search-maximum-limit)
        candidates
        page)
    (while (and (or (null remaining) (> remaining 0))
                (setq page (refbox-list-references
                            (if remaining (min page-size remaining) page-size)
                            offset)))
      (setq candidates (nconc candidates page)
            offset (+ offset (length page)))
      (when remaining
        (setq remaining (- remaining (length page)))))
    candidates))

(defun refbox--resource-reference-candidates
    (reference-or-references supplied-p)
  "Return candidates for resource APIs.

When REFERENCE-OR-REFERENCES is omitted, enumerate the full index.
When it is explicitly nil, return nil."
  (cond
   ((and supplied-p (null reference-or-references))
    nil)
   ((not supplied-p)
    (refbox--all-reference-candidates))
   ((and (listp reference-or-references)
         (plist-member reference-or-references :key))
    (list reference-or-references))
   ((listp reference-or-references)
    (mapcar #'refbox--reference-candidate
            (delete-dups (copy-sequence reference-or-references))))
   (t
    (list (refbox--reference-candidate reference-or-references)))))

(defun refbox-get-value (field reference-or-entry)
  "Return FIELD value from REFERENCE-OR-ENTRY."
  (cdr (assoc-string (format "%s" field)
                     (refbox--entry-alist reference-or-entry)
                     'case-fold)))

(defun refbox-get-field-with-value (fields reference-or-entry)
  "Return the first field/value pair from FIELDS in REFERENCE-OR-ENTRY."
  (let ((entry (refbox--entry-alist reference-or-entry)))
    (seq-some (lambda (field)
                (when-let ((value (cdr (assoc-string (format "%s" field)
                                                     entry
                                                     'case-fold))))
                  (cons field value)))
              fields)))

(defun refbox-get-display-value (fields reference-or-entry &optional transform)
  "Return the first display value for FIELDS in REFERENCE-OR-ENTRY.

When TRANSFORM is non-nil, it is a list whose car is a function and
whose cdr is passed as additional arguments."
  (let* ((field-value (refbox-get-field-with-value fields reference-or-entry))
         (function (car transform))
         (arguments (cdr transform))
         (value (if transform
                    (apply function (cdr field-value) arguments)
                  (cdr field-value))))
    (or value "")))

(defconst refbox-capf--key-chars "[:alnum:]_:.#$%&+?<>~/=-"
  "Characters treated as part of citation keys during CAPF detection.")

(defun refbox-capf-key-bounds (&optional begin end)
  "Return citation key bounds around point between BEGIN and END."
  (let ((begin (or begin (point-min)))
        (end (or end (point-max))))
    (when (and (<= begin (point))
               (<= (point) end))
      (save-excursion
        (skip-chars-backward refbox-capf--key-chars begin)
        (let ((start (point)))
          (skip-chars-forward refbox-capf--key-chars end)
          (cons start (point)))))))

(defun refbox-capf-key-bounds-after-at (&optional begin end)
  "Return citation key bounds after an @ marker between BEGIN and END."
  (when-let ((bounds (refbox-capf-key-bounds begin end)))
    (when (or (and (> (car bounds) (or begin (point-min)))
                   (eq (char-before (car bounds)) ?@))
              (and (> (car bounds) (1+ (or begin (point-min))))
                   (eq (char-before (car bounds)) ?{)
                   (eq (char-before (1- (car bounds))) ?@)))
      bounds)))

(defun refbox-capf--state (&optional limit source-paths)
  "Return CAPF completion state using LIMIT and SOURCE-PATHS."
  (list :limit (refbox-rpc--search-limit limit)
        :source-paths source-paths
        :input nil
        :candidates nil
        :cache (make-hash-table :test 'eq)))

(defun refbox-capf--candidate (candidate seen)
  "Return a key completion candidate from CANDIDATE using SEEN."
  (let ((key (refbox-reference-field candidate "key")))
    (unless (or (refbox--blank-string-p key)
                (gethash key seen))
      (puthash key t seen)
      (propertize key
                  'refbox-candidate candidate
                  'refbox-annotation
                  (refbox-reference-format-suffix candidate)))))

(defun refbox-capf--state-candidates (state input)
  "Return bounded key candidates for INPUT using STATE."
  (setq input (substring-no-properties input))
  (unless (equal input (plist-get state :input))
    (refbox--with-dynamic-cache (plist-get state :cache)
      (let ((seen (make-hash-table :test 'equal)))
        (setf (plist-get state :input) input)
        (setf (plist-get state :candidates)
              (delq
               nil
               (mapcar (lambda (candidate)
                         (refbox-capf--candidate candidate seen))
                       (refbox-search-references
                        input
                        (plist-get state :limit)
                        (plist-get state :source-paths))))))))
  (plist-get state :candidates))

(defun refbox-capf--completion-table (state)
  "Return a CAPF completion table backed by bounded daemon search STATE."
  (lambda (string predicate action)
    (cond
     ((eq action 'metadata)
      '(metadata
        (category . refbox-reference)
        (annotation-function . refbox-capf-annotate)
        (affixation-function . refbox--completion-affixation)))
     (t
      (let ((candidates (refbox--completion-filter
                         (refbox-capf--state-candidates state string)
                         predicate)))
        (cond
         ((eq action t) candidates)
         ((eq action 'lambda)
          (cl-some (lambda (candidate)
                     (string= string (substring-no-properties candidate)))
                   candidates))
         ((cl-some (lambda (candidate)
                     (string= string (substring-no-properties candidate)))
                   candidates)
          t)
         ((null candidates) nil)
         ((null (cdr candidates)) (car candidates))
         (t string)))))))

(defun refbox-capf-annotate (citekey)
  "Return a completion annotation for CITEKEY."
  (or (when-let ((annotation (get-text-property 0 'refbox-annotation citekey)))
        (concat " " annotation))
      (refbox--with-dynamic-cache nil
        (let ((candidate
               (or (get-text-property 0 'refbox-candidate citekey)
                   (ignore-errors
                     (refbox-entry-by-key (substring-no-properties citekey))))))
          (if candidate
              (concat " " (refbox-reference-format-suffix candidate))
            "")))))

(defun refbox-capf-at-bounds (bounds &optional source-paths)
  "Return CAPF data for BOUNDS using optional SOURCE-PATHS."
  (when bounds
    (list (car bounds)
          (cdr bounds)
          (refbox-capf--completion-table
           (refbox-capf--state refbox-capf-limit source-paths))
          :exclusive 'no)))

;;;###autoload
(defun refbox-capf ()
  "Return reference completion data at supported citation contexts."
  (cond
   ((and (derived-mode-p 'org-mode)
         (fboundp 'refbox-org-completion-at-point))
    (refbox-org-completion-at-point))
   ((and (derived-mode-p 'latex-mode 'LaTeX-mode 'tex-mode)
         (fboundp 'refbox-latex-completion-at-point))
    (refbox-latex-completion-at-point))
   ((and (derived-mode-p 'markdown-mode 'gfm-mode)
         (fboundp 'refbox-markdown-completion-at-point))
    (refbox-markdown-completion-at-point))))

;;;###autoload
(defun refbox-capf-setup ()
  "Enable refbox completion at point in the current buffer."
  (interactive)
  (add-hook 'completion-at-point-functions
            #'refbox-capf
            nil
            t))

(defun refbox-reference-resources (candidate)
  "Return indexed resources for CANDIDATE via the daemon."
  (let ((key (refbox--reference-key candidate))
        (source-path (refbox--reference-source-path candidate)))
    (unless key
      (user-error "Reference candidate has no key"))
    (refbox--listify
     (plist-get
      (refbox-rpc-request
       refbox-rpc-method-resources-by-key
       (append (list :key key)
               (unless (refbox--blank-string-p source-path)
                 (list :source_path source-path))))
      :resources))))

(defun refbox-resource--clean-value (value)
  "Return VALUE stripped of simple bibliography wrappers."
  (let ((text (string-trim (format "%s" (or value "")))))
    (while (and (> (length text) 1)
                (or (and (string-prefix-p "{" text)
                         (string-suffix-p "}" text))
                    (and (string-prefix-p "\"" text)
                         (string-suffix-p "\"" text))))
      (setq text (string-trim (substring text 1 -1))))
    text))

(defun refbox-resource--split-escaped-string (string sepchar)
  "Split STRING on SEPCHAR while honoring backslash escapes."
  (let ((index 0)
        pieces
        chars)
    (while (< index (length string))
      (let ((char (aref string index)))
        (cond
         ((= char ?\\)
          (if (< (1+ index) (length string))
              (let ((next (aref string (1+ index))))
                (if (or (= next sepchar) (= next ?\\))
                    (progn
                      (push next chars)
                      (setq index (1+ index)))
                  (push char chars)))
            (push char chars)))
         ((= char sepchar)
          (push (apply #'string (nreverse chars)) pieces)
          (setq chars nil))
         (t
          (push char chars))))
      (setq index (1+ index)))
    (nreverse (cons (apply #'string (nreverse chars)) pieces))))

(defun refbox-resource-parse-file-field-default (file-field)
  "Parse FILE-FIELD as a semicolon-separated path list."
  (let ((text (refbox-resource--clean-value file-field)))
    (cl-remove-if
     #'string-empty-p
     (mapcar #'string-trim
             (refbox-resource--split-escaped-string text ?\;)))))

(defun refbox-resource-parse-file-field-triplet (file-field)
  "Parse FILE-FIELD entries shaped as title:path:type triplets."
  (let ((text (refbox-resource--clean-value file-field))
        files)
    (dolist (item (refbox-resource--split-escaped-string text ?,))
      (let ((parts (refbox-resource--split-escaped-string item ?:)))
        (when (>= (length parts) 3)
          (push (string-join (butlast (cdr parts)) ":") files))))
    (nreverse files)))

(defun refbox-resource--parse-file-field (value)
  "Return candidate file paths parsed from VALUE."
  (delete-dups
   (cl-remove-if
    #'string-empty-p
    (apply
     #'append
     (mapcar (lambda (parser)
               (unless (fboundp parser)
                 (user-error "refbox file parser is not defined: %s" parser))
               (mapcar #'refbox-resource--clean-value
                       (or (funcall parser value) nil)))
             refbox-file-parser-functions)))))

(defun refbox-resource--normalize-extensions (extensions)
  "Return normalized EXTENSIONS."
  (mapcar (lambda (extension)
            (downcase (string-remove-prefix "." extension)))
          extensions))

(defun refbox-resource--extension-allowed-p (file extensions)
  "Return non-nil when FILE has an accepted extension."
  (or (null extensions)
      (let ((extension (file-name-extension file)))
        (and extension
             (member (downcase extension)
                     (refbox-resource--normalize-extensions extensions))))))

(defun refbox-resource--directory-list-uncached (dirs recursive)
  "Return existing DIRS, optionally including recursive subdirectories."
  (delete-dups
   (apply
    #'append
    (mapcar
     (lambda (dir)
       (let ((dir (file-name-as-directory (expand-file-name dir))))
         (when (file-directory-p dir)
           (cons dir
                 (when recursive
                   (cl-loop
                    for child in (directory-files-recursively dir "" t)
                    when (file-directory-p child)
                      collect (file-name-as-directory child)))))))
     dirs))))

(defun refbox-resource--directory-list (dirs recursive)
  "Return existing DIRS, optionally including recursive subdirectories."
  (refbox--dynamic-cache-get
   'resource-directories
   (list (mapcar #'expand-file-name dirs) recursive)
   (lambda ()
     (refbox-resource--directory-list-uncached dirs recursive))))

(defun refbox-resource--library-dirs ()
  "Return configured library directories."
  (refbox-resource--directory-list
   refbox-library-paths
   refbox-library-paths-recursive))

(defun refbox-resource--source-dirs (candidate resources)
  "Return bibliography source directories for CANDIDATE and RESOURCES."
  (delete-dups
   (cl-remove
    nil
    (append
     (when-let* ((path (refbox-reference-field candidate "source_path"))
                 (dir (file-name-directory path)))
       (list (file-name-as-directory (expand-file-name dir))))
     (cl-loop
      for resource in resources
      for path = (refbox--resource-owner-source-path resource)
      for dir = (and path (file-name-directory path))
      when dir
      collect (file-name-as-directory (expand-file-name dir)))))))

(defun refbox-resource--find-files-in-dirs (files dirs extensions)
  "Resolve FILES against DIRS while filtering EXTENSIONS."
  (let (found)
    (dolist (file files)
      (let ((file (refbox-resource--clean-value file)))
        (cond
         ((file-name-absolute-p file)
          (when (and (file-exists-p file)
                     (refbox-resource--extension-allowed-p file extensions))
            (push (expand-file-name file) found)))
         (t
          (cl-loop
           for dir in dirs
           for candidate = (expand-file-name file dir)
           when (and (file-exists-p candidate)
                     (refbox-resource--extension-allowed-p candidate extensions))
           do (push candidate found)
           and return t)))))
    (nreverse (delete-dups found))))

(defun refbox-resource--normalized-roots (roots)
  "Return existing ROOTS as absolute directory names."
  (delete-dups
   (delq nil
         (mapcar (lambda (root)
                   (let ((root (file-name-as-directory
                                (expand-file-name root))))
                     (and (file-directory-p root) root)))
                 roots))))

(defun refbox-resource--file-index-key (roots recursive extensions)
  "Return the cache key for a ROOTS file index."
  (list (refbox-resource--normalized-roots roots)
        recursive
        (and extensions
             (refbox-resource--normalize-extensions extensions))))

(defun refbox-resource--file-index (roots recursive extensions)
  "Return cached regular files under ROOTS matching EXTENSIONS."
  (let* ((key (refbox-resource--file-index-key roots recursive extensions))
         (roots (nth 0 key))
         (extensions (nth 2 key)))
    (refbox--dynamic-cache-get
     'resource-file-index
     key
     (lambda ()
       (let (entries stack)
         (dolist (root roots)
           (if recursive
               (push root stack)
             (dolist (file (directory-files
                            root t directory-files-no-dot-files-regexp))
               (when (and (file-regular-p file)
                          (or (null extensions)
                              (when-let ((extension (file-name-extension file)))
                                (member (downcase extension) extensions))))
                 (push (cons (file-name-base file) file) entries)))))
         (while stack
           (let ((dir (pop stack)))
             (dolist (file (directory-files
                            dir t directory-files-no-dot-files-regexp))
               (cond
                ((and (file-directory-p file)
                      (not (file-symlink-p file)))
                 (push file stack))
                ((and (file-regular-p file)
                      (or (null extensions)
                          (when-let ((extension (file-name-extension file)))
                            (member (downcase extension) extensions))))
                 (push (cons (file-name-base file) file) entries))))))
         (nreverse entries))))))

(defun refbox-resource--file-base-matches-key-p (base key additional-sep)
  "Return non-nil when file BASE matches reference KEY."
  (or (string= base key)
      (and additional-sep
           (string-match-p
            (concat "\\`" (regexp-quote key)
                    "\\(?:" additional-sep ".*\\)?\\'")
            base))))

(defun refbox-resource--normalized-key-list (keys)
  "Return non-empty string keys from KEYS."
  (cl-remove-if #'string-empty-p
                (mapcar (lambda (key)
                          (format "%s" (or key "")))
                        keys)))

(defun refbox-resource--files-for-keys-in-index
    (keys index additional-sep)
  "Return files matching KEYS from file INDEX."
  (let (found)
    (dolist (entry index)
      (let ((base (car entry))
            (file (cdr entry)))
        (when (cl-some
               (lambda (key)
                 (refbox-resource--file-base-matches-key-p
                  base key additional-sep))
               keys)
          (push file found))))
    (nreverse (delete-dups found))))

(defun refbox-resource--files-for-keys-direct (keys roots extensions)
  "Return exact KEY.EXTENSION matches in ROOTS."
  (let (found)
    (dolist (dir roots)
      (dolist (key keys)
        (dolist (extension extensions)
          (let ((file (expand-file-name
                       (format "%s.%s" key extension)
                       dir)))
            (when (file-exists-p file)
              (push file found))))))
    (nreverse (delete-dups found))))

(defun refbox-resource--files-for-keys-normalized
    (keys roots recursive extensions additional-sep materialize)
  "Return files for normalized search inputs.

When MATERIALIZE is nil, only use exact path probes or an index that
already exists in the dynamic cache."
  (cond
   ((or (null keys) (null roots))
    nil)
   ((and (not recursive) extensions (not additional-sep))
    (refbox-resource--files-for-keys-direct keys roots extensions))
   (materialize
    (refbox-resource--files-for-keys-in-index
     keys
     (refbox-resource--file-index roots recursive extensions)
     additional-sep))
   (t
    (let* ((key (refbox-resource--file-index-key roots recursive extensions))
           (index (refbox--dynamic-cache-value 'resource-file-index key)))
      (unless (eq index refbox--cache-miss)
        (refbox-resource--files-for-keys-in-index
         keys index additional-sep))))))

(defun refbox-resource--normalize-file-search (keys roots extensions)
  "Return normalized KEYS, ROOTS, and EXTENSIONS for file search."
  (list (refbox-resource--normalized-key-list keys)
        (refbox-resource--normalized-roots roots)
        (and extensions
             (refbox-resource--normalize-extensions extensions))))

(defun refbox-resource--files-for-keys-in-roots
    (keys roots recursive extensions additional-sep)
  "Return files in ROOTS associated with KEYS."
  (pcase-let ((`(,keys ,roots ,extensions)
               (refbox-resource--normalize-file-search keys roots extensions)))
    (refbox--dynamic-cache-get
     'resource-files-for-keys
     (list keys roots recursive extensions additional-sep)
     (lambda ()
       (refbox-resource--files-for-keys-normalized
        keys roots recursive extensions additional-sep t)))))

(defun refbox-resource--files-for-keys-cheap
    (keys roots recursive extensions additional-sep)
  "Return cheap file matches for KEYS in ROOTS.

This never performs recursive directory discovery or full directory
materialization from an indicator path."
  (pcase-let ((`(,keys ,roots ,extensions)
               (refbox-resource--normalize-file-search keys roots extensions)))
    (refbox-resource--files-for-keys-normalized
     keys roots recursive extensions additional-sep nil)))

(defun refbox-resource-file-source--plist (source)
  "Return the plist for file SOURCE."
  (unless (and (consp source) (symbolp (car source)) (listp (cdr source)))
    (user-error "Invalid refbox file source: %S" source))
  (cdr source))

(defun refbox-resource-file-source--function (source property &optional required)
  "Return SOURCE function PROPERTY.

When REQUIRED is non-nil, signal if the property is absent or not
callable."
  (let ((function (plist-get (refbox-resource-file-source--plist source)
                             property)))
    (cond
     ((functionp function) function)
     (required
      (user-error "refbox file source %s has no callable %s"
                  (car source)
                  property))
     (t nil))))

(defun refbox-resource-file-source-indexed-items (candidate resources)
  "Return files declared by indexed resources for CANDIDATE."
  (let* ((extensions refbox-library-file-extensions)
         (field-files
          (cl-loop
           for resource in resources
           for kind = (refbox--resource-kind resource)
           for lookup = (refbox--resource-lookup-name resource)
           when (or (equal kind "file")
                    (and lookup
                         (member lookup (refbox--file-field-names))))
           append (refbox-resource--parse-file-field
                   (refbox--resource-value resource))))
         (source-dirs (refbox-resource--source-dirs candidate resources))
         (library-dirs (refbox-resource--library-dirs)))
    (refbox-resource--find-files-in-dirs
     field-files
     (append source-dirs library-dirs)
     extensions)))

(defun refbox-resource-file-source-indexed-has-items (candidate resources)
  "Return non-nil when CANDIDATE has indexed file declarations."
  (or (refbox-reference-has-resource-kind-p candidate "file")
      (refbox-reference-has-any-field-p
       candidate
       (refbox--file-field-names))
      (cl-some
       (lambda (resource)
         (let ((kind (refbox--resource-kind resource))
               (lookup (refbox--resource-lookup-name resource)))
           (or (equal kind "file")
               (and lookup
                    (member lookup (refbox--file-field-names))))))
       resources)))

(defun refbox-resource-file-source-library-items (candidate resources)
  "Return library-path files associated with CANDIDATE."
  (refbox-resource--files-for-keys-in-roots
   (refbox-reference-related-keys candidate resources)
   refbox-library-paths
   refbox-library-paths-recursive
   refbox-library-file-extensions
   refbox-file-additional-files-separator))

(defun refbox-resource-file-source-library-has-items (candidate resources)
  "Return non-nil when CANDIDATE has files in configured library paths."
  (not
   (null
    (refbox-resource--files-for-keys-cheap
     (refbox-reference-related-keys candidate resources)
     refbox-library-paths
     refbox-library-paths-recursive
     refbox-library-file-extensions
     refbox-file-additional-files-separator))))

(defun refbox-resource-file-source-items (candidate resources)
  "Return file items from `refbox-file-sources'."
  (delete-dups
   (cl-loop
    for source in refbox-file-sources
    append
    (refbox--listify
     (funcall
      (refbox-resource-file-source--function source :items t)
      candidate
      resources)))))

(defun refbox-resource-file-source-has-items-p (candidate resources)
  "Return non-nil when any file source has items for CANDIDATE."
  (cl-some
   (lambda (source)
     (if-let ((hasitems
               (refbox-resource-file-source--function source :hasitems)))
         (funcall hasitems candidate resources)
       (not
        (null
         (refbox--listify
          (funcall
           (refbox-resource-file-source--function source :items t)
           candidate
           resources))))))
   refbox-file-sources))

(cl-defun refbox-reference-files
    (candidate &optional (resources nil resources-supplied-p))
  "Return existing file resources for CANDIDATE."
  (refbox-resource-file-source-items
   candidate
   (if resources-supplied-p
       resources
     (refbox-reference-resources candidate))))

(defun refbox-resource-link-url (resource)
  "Return the URL represented by RESOURCE."
  (let* ((kind-name (refbox--resource-kind resource))
         (kind (and (not (refbox--blank-string-p kind-name))
                    (intern kind-name)))
         (template (alist-get kind refbox-link-fields))
         (value (refbox-resource--clean-value (refbox--resource-value resource))))
    (when (and template (not (string-empty-p value)))
      (if (or (eq kind 'url)
              (string-match-p "\\`https?://" value))
          value
        (format template value)))))

(defun refbox-reference-links (candidate &optional resources)
  "Return link URLs for CANDIDATE."
  (delete-dups
   (cl-loop
    for resource in (or resources (refbox-reference-resources candidate))
    for url = (refbox-resource-link-url resource)
    when url
    collect url)))

(defun refbox-note--directories ()
  "Return configured note directories."
  (refbox-resource--directory-list refbox-notes-paths nil))

(defun refbox-note-files (key)
  "Return existing note files for KEY."
  (refbox-note-files-for-keys (list key)))

(defun refbox-note-files-for-keys (keys)
  "Return existing note files for KEYS."
  (refbox-resource--files-for-keys-in-roots
   keys
   refbox-notes-paths
   nil
   refbox-file-note-extensions
   refbox-file-additional-files-separator))

(defun refbox-note-source-file-all-items ()
  "Return all file-backed note items from configured note directories."
  (apply
   #'append
   (mapcar
    (lambda (dir)
      (cl-loop
       for file in (directory-files dir t directory-files-no-dot-files-regexp)
       when (and (file-regular-p file)
                 (refbox-resource--extension-allowed-p
                  file
                  refbox-file-note-extensions))
       collect file))
    (refbox-note--directories))))

(defun refbox-note--filename-key (key)
  "Return KEY transformed for a single file name."
  (replace-regexp-in-string "[/\\]" "_" key))

(defun refbox-note-filename (key)
  "Return the existing or default note filename for KEY."
  (when (refbox--blank-string-p key)
    (user-error "Reference candidate has no key"))
  (unless refbox-notes-paths
    (user-error "`refbox-notes-paths' must contain at least one directory"))
  (unless refbox-file-note-extensions
    (user-error "`refbox-file-note-extensions' must contain at least one extension"))
  (or (car (refbox-note-files key))
      (expand-file-name
       (format "%s.%s"
               (refbox-note--filename-key key)
               (string-remove-prefix "." (car refbox-file-note-extensions)))
       (car refbox-notes-paths))))

(defun refbox-org-format-note-default (key candidate)
  "Return default note content for KEY and CANDIDATE."
  (let ((title (string-trim (refbox-reference-format-note candidate))))
    (if (string-empty-p title)
        (format "#+title: %s\n\n" key)
      (format "#+title: %s\n\n" title))))

(defun refbox-note-source--plist ()
  "Return the configured plist for `refbox-notes-source'."
  (or (alist-get refbox-notes-source refbox-notes-sources)
      (user-error "Unknown refbox note source: %s" refbox-notes-source)))

(defconst refbox-note-source--required-properties
  '(:items :open)
  "Required plist properties for registered note sources.")

(defconst refbox-note-source--function-properties
  '(:items :all-items :hasitems :open :create :create-label :transform)
  "Note source plist properties whose values must be callable.")

(defconst refbox-note-source--known-properties
  (append refbox-note-source--function-properties '(:name))
  "Recognized note source plist properties.")

(defun refbox-note-source-validate (name config)
  "Signal when note source NAME has an invalid CONFIG plist."
  (unless (symbolp name)
    (user-error "refbox note source name must be a symbol"))
  (unless (and (proper-list-p config) (zerop (mod (length config) 2)))
    (user-error "refbox note source config must be a plist"))
  (dolist (property refbox-note-source--required-properties)
    (unless (plist-member config property)
      (user-error "refbox note source %s is missing %s" name property)))
  (cl-loop for (property value) on config by #'cddr
           do
           (unless (keywordp property)
             (user-error "refbox note source %s has non-keyword property %S"
                         name property))
           (cond
            ((memq property refbox-note-source--function-properties)
             (unless (functionp value)
               (user-error "refbox note source %s property %s is not callable"
                           name property)))
            ((eq property :name)
             (unless (stringp value)
               (user-error "refbox note source %s property :name is not a string"
                           name)))
            ((not (memq property refbox-note-source--known-properties))
             (display-warning
              'refbox
              (format "refbox note source %s has unknown property %s"
                      name property)
              :warning))))
  name)

(defun refbox-register-notes-source (name config)
  "Register note source NAME with CONFIG."
  (refbox-note-source-validate name config)
  (setf (alist-get name refbox-notes-sources) config)
  name)

(defun refbox-remove-notes-source (name)
  "Remove note source NAME from `refbox-notes-sources'."
  (setq refbox-notes-sources
        (assq-delete-all name refbox-notes-sources))
  name)

(defun refbox-note-source--function (property)
  "Return function PROPERTY from the active note source."
  (let ((function (plist-get (refbox-note-source--plist) property)))
    (unless (functionp function)
      (user-error "refbox note source %s has no callable %s"
                  refbox-notes-source property))
    function))

(defun refbox-note-source--display (item)
  "Return display text for note source ITEM."
  (if-let ((transform (plist-get (refbox-note-source--plist) :transform)))
      (funcall transform item)
    (format "%s" item)))

(defun refbox-note-source-file-items (key reference)
  "Return file-backed note items for KEY."
  (refbox-note-files-for-keys
   (if (and (listp reference) (plist-member reference :key))
       (refbox-reference-related-keys reference)
     (list key))))

(defun refbox-note-source-file-has-items (key reference)
  "Return non-nil when KEY has file-backed notes."
  (not (null (refbox-note-source-file-items key reference))))

(defun refbox-note-source-file-open (item)
  "Open file-backed note ITEM."
  (refbox--open-target refbox-open-note-function item))

(defun refbox-note-source-file-create-label (key _reference)
  "Return the file-backed create target label for KEY."
  (refbox-note-filename key))

(defun refbox-note-source-file-create (key reference)
  "Create or open a file-backed note for KEY and REFERENCE."
  (let* ((file (refbox-note-filename key))
         (exists (file-exists-p file)))
    (make-directory (file-name-directory file) t)
    (funcall refbox-open-note-function file)
    (unless exists
      (when-let* ((content-function refbox-note-format-function)
                  (content (funcall content-function key reference)))
        (when (and (stringp content)
                   (not (string-empty-p content))
                   buffer-file-name
                   (equal (file-truename buffer-file-name)
                          (file-truename file)))
          (insert content))))
    file))

(defun refbox-note-source-items (reference)
  "Return active note source items for REFERENCE."
  (let ((key (refbox--reference-key reference)))
    (unless (refbox--blank-string-p key)
      (refbox--listify
       (funcall (refbox-note-source--function :items) key reference)))))

(defun refbox--resource-table (candidates items-function)
  "Return a hash table of resource ITEMS-FUNCTION values for CANDIDATES."
  (let ((table (make-hash-table :test 'equal)))
    (dolist (candidate candidates)
      (let* ((key (refbox--reference-key candidate))
             (items (and key (refbox--listify
                              (funcall items-function candidate)))))
        (when items
          (puthash key items table))))
    table))

(cl-defun refbox-get-files
    (&optional (reference-or-references nil supplied-p))
  "Return files associated with REFERENCE-OR-REFERENCES.

REFERENCE-OR-REFERENCES may be a single reference key, an indexed
candidate, or a list of reference keys.  Return a hash table mapping
keys to non-empty file lists.  When REFERENCE-OR-REFERENCES is omitted,
enumerate all indexed references; when it is explicitly nil, return nil."
  (when (or reference-or-references (not supplied-p))
    (refbox--resource-table
     (refbox--resource-reference-candidates
      reference-or-references supplied-p)
     (lambda (candidate)
       (refbox-reference-files candidate (refbox--candidate-resources candidate))))))

(cl-defun refbox-get-links
    (&optional (reference-or-references nil supplied-p))
  "Return links associated with REFERENCE-OR-REFERENCES.

REFERENCE-OR-REFERENCES may be a single reference key, an indexed
candidate, or a list of reference keys.  Return a hash table mapping
keys to non-empty link lists.  When REFERENCE-OR-REFERENCES is omitted,
enumerate all indexed references; when it is explicitly nil, return nil."
  (when (or reference-or-references (not supplied-p))
    (refbox--resource-table
     (refbox--resource-reference-candidates
      reference-or-references supplied-p)
     (lambda (candidate)
       (refbox-reference-links candidate (refbox--candidate-resources candidate))))))

(cl-defun refbox-get-notes
    (&optional (reference-or-references nil supplied-p))
  "Return notes associated with REFERENCE-OR-REFERENCES.

REFERENCE-OR-REFERENCES may be a single reference key, an indexed
candidate, or a list of reference keys.  Return a hash table mapping
keys to non-empty note lists.  When REFERENCE-OR-REFERENCES is omitted,
enumerate all indexed references; when it is explicitly nil, return nil."
  (when (or reference-or-references (not supplied-p))
    (refbox--resource-table
     (refbox--resource-reference-candidates
      reference-or-references supplied-p)
     #'refbox-note-source-items)))

(defun refbox-note-source-all-items ()
  "Return all items from the active note source."
  (refbox--listify
   (funcall (refbox-note-source--function :all-items))))

(defun refbox-note-source-has-items-p (reference)
  "Return non-nil when REFERENCE has active note source items."
  (let ((key (refbox--reference-key reference)))
    (and (not (refbox--blank-string-p key))
         (if-let ((hasitems (plist-get (refbox-note-source--plist) :hasitems)))
             (funcall hasitems key reference)
           (not (null (refbox-note-source-items reference)))))))

(defun refbox-note-source-open (item)
  "Open active note source ITEM."
  (funcall (refbox-note-source--function :open) item))

(defun refbox-note-source-create-label (reference)
  "Return display label for creating a note for REFERENCE."
  (let* ((key (refbox--reference-key reference))
         (function (plist-get (refbox-note-source--plist) :create-label)))
    (if (functionp function)
        (funcall function key reference)
      key)))

(defun refbox-note-source-create (reference)
  "Create or open a note for REFERENCE using the active source."
  (let ((key (refbox--reference-key reference)))
    (funcall (refbox-note-source--function :create) key reference)))

(defun refbox--command-should-prompt-p (command)
  "Return non-nil when COMMAND should prompt for a single resource."
  (or (eq refbox-open-prompt t)
      (and (listp refbox-open-prompt)
           (memq command refbox-open-prompt))))

(defun refbox--command-should-always-create-notes-p (command)
  "Return non-nil when COMMAND should always offer note creation."
  (or (eq refbox-open-always-create-notes t)
      (and (listp refbox-open-always-create-notes)
           (memq command refbox-open-always-create-notes))))

(defun refbox--read-resource-choice (prompt choices &optional command)
  "Read one resource choice from CHOICES using PROMPT.

When COMMAND is provided, `refbox-open-prompt' controls whether a
single choice is accepted without prompting."
  (cond
   ((null choices)
    (user-error "No resources found"))
   ((and (null (cdr choices))
         (not (and command (refbox--command-should-prompt-p command))))
    (car choices))
   (t
    (let ((table (make-hash-table :test 'equal))
          labels)
      (dolist (choice choices)
        (let ((label (plist-get choice :label))
              (counter 2))
          (while (gethash label table)
            (setq label (format "%s <%d>" (plist-get choice :label) counter)
                  counter (1+ counter)))
          (puthash label choice table)
          (push label labels)))
      (gethash (completing-read prompt (nreverse labels) nil t) table)))))

(defun refbox--open-target (function target)
  "Open TARGET with FUNCTION and return TARGET."
  (funcall function target)
  target)

(defun refbox-file-open (file)
  "Open FILE using the configured resource opener."
  (let* ((file (expand-file-name file))
         (extension (file-name-extension file))
         (function (cdr (or (and extension
                                  (assoc-string extension
                                                refbox-file-open-functions
                                                'case-fold))
                            (assq t refbox-file-open-functions)))))
    (unless function
      (user-error "Could not find extension in `refbox-file-open-functions': %s"
                  extension))
    (refbox--open-target
     function
     file)))

(defun refbox-file-open-external (file)
  "Open FILE using the platform's external file opener."
  (let ((file (expand-file-name file)))
    (if (and (eq system-type 'windows-nt)
             (fboundp 'w32-shell-execute))
        (w32-shell-execute "open" file)
      (call-process
       (pcase system-type
         ('darwin "open")
         ('cygwin "cygstart")
         (_ "xdg-open"))
       nil
       0
       nil
       file)))
  file)

(defun refbox--reference-choice-key (reference)
  "Return a display key for REFERENCE."
  (refbox--reference-key reference))

(defun refbox--resource-choice-label (type reference target)
  "Return display label for resource TYPE, REFERENCE, and TARGET."
  (let ((key (and reference (refbox--reference-choice-key reference))))
    (if key
        (format "%-7s %-24s %s" type key target)
      (format "%-7s %s" type target))))

(defun refbox--file-choices (references)
  "Return file resource choices for REFERENCES."
  (cl-loop
   for reference in references
   append
   (mapcar (lambda (file)
             (list :type 'file
                   :reference reference
                   :target file
                   :label (refbox--resource-choice-label
                           "file" reference file)))
           (refbox-reference-files reference))))

(defun refbox--link-choices (references)
  "Return link resource choices for REFERENCES."
  (cl-loop
   for reference in references
   append
   (mapcar (lambda (link)
             (list :type 'link
                   :reference reference
                   :target link
                   :label (refbox--resource-choice-label
                           "link" reference link)))
           (refbox-reference-links reference))))

(defun refbox--note-choices (references &optional include-create command)
  "Return note resource choices for REFERENCES.

When INCLUDE-CREATE is non-nil, include note creation choices.
COMMAND controls `refbox-open-always-create-notes'."
  (cl-loop
   for reference in references
   for key = (refbox--reference-key reference)
   for notes = (and key (refbox-note-source-items reference))
   for create-label = (and include-create
                           key
                           (ignore-errors
                             (refbox-note-source-create-label reference)))
   append
   (append
    (mapcar (lambda (note)
              (list :type 'note
                    :reference reference
                    :target note
                    :label (refbox--resource-choice-label
                            "note" reference
                            (refbox-note-source--display note))))
            notes)
    (when (and create-label
               (or (null notes)
                   (refbox--command-should-always-create-notes-p command)))
      (list (list :type 'create-note
                  :reference reference
                  :target key
                  :label (refbox--resource-choice-label
                          "create" reference
                          create-label)))))))

(defun refbox--all-note-choices ()
  "Return note choices from the active note source."
  (mapcar
   (lambda (note)
     (list :type 'note
           :target note
           :label (refbox--resource-choice-label
                   "note"
                   nil
                   (refbox-note-source--display note))))
   (delete-dups (refbox-note-source-all-items))))

(defun refbox--open-resource-choice (choice)
  "Open resource CHOICE and return its target."
  (let ((target (plist-get choice :target)))
    (pcase (plist-get choice :type)
      ('file (refbox-file-open target))
      ('link (refbox--open-target refbox-link-open-function target))
      ('note (refbox-note-source-open target))
      ('create-note (refbox-create-note (plist-get choice :reference)))
      (_ (user-error "Unknown refbox resource type: %S"
                     (plist-get choice :type))))))

;;;###autoload
(defun refbox-open-files (&optional references)
  "Open a file resource for REFERENCES."
  (interactive)
  (refbox--open-resource-choice
   (refbox--read-resource-choice
    "File: "
    (refbox--file-choices (refbox--reference-list references))
    'refbox-open-files)))

;;;###autoload
(defun refbox-attach-files (&optional references)
  "Attach a file resource for REFERENCES to an outgoing MIME message."
  (interactive)
  (let* ((choice (refbox--read-resource-choice
                  "Attach file: "
                  (refbox--file-choices (refbox--reference-list references))
                  'refbox-attach-files))
         (file (plist-get choice :target)))
    (unless (fboundp 'mml-attach-file)
      (require 'mml nil t))
    (unless (fboundp 'mml-attach-file)
      (user-error "MML attachment support is not available"))
    (mml-attach-file file)
    file))

;;;###autoload
(defun refbox-open-links (&optional references)
  "Open a link resource for REFERENCES."
  (interactive)
  (refbox--open-resource-choice
   (refbox--read-resource-choice
    "Link: "
    (refbox--link-choices (refbox--reference-list references))
    'refbox-open-links)))

;;;###autoload
(defun refbox-open-notes (&optional references)
  "Open or create a note for REFERENCES."
  (interactive)
  (refbox--open-resource-choice
   (refbox--read-resource-choice
    "Note: "
    (refbox--note-choices
     (refbox--reference-list references)
     t
     'refbox-open-notes)
    'refbox-open-notes)))

;;;###autoload
(defun refbox-open-note (&optional note)
  "Open NOTE, or select a note from all notes in the active source."
  (interactive)
  (refbox-note-source-open
   (or note
       (plist-get
        (refbox--read-resource-choice
         "Note: "
         (refbox--all-note-choices)
         'refbox-open-note)
        :target))))

;;;###autoload
(defun refbox-create-note (&optional key entry)
  "Create or open the note for KEY.

KEY may be a reference key string or an indexed candidate.  ENTRY, when
non-nil, is a bibliography entry alist used as candidate metadata."
  (interactive)
  (refbox-note-source-create
   (cond
    ((and (listp key) (plist-member key :key)) key)
    ((stringp key)
     (or (and entry (refbox--entry-candidate key entry))
         (refbox-entry-by-key key)))
    (t
     (refbox-read-reference)))))

;;;###autoload
(defun refbox-open (&optional references)
  "Open a file, link, or note associated with REFERENCES."
  (interactive)
  (let* ((references (refbox--reference-list references))
         (choices
          (append
           (when (memq :files refbox-open-resources)
             (refbox--file-choices references))
           (when (memq :links refbox-open-resources)
             (refbox--link-choices references))
           (when (or (memq :notes refbox-open-resources)
                     (memq :create-notes refbox-open-resources))
             (refbox--note-choices
              references
              (memq :create-notes refbox-open-resources)
              'refbox-open)))))
    (refbox--open-resource-choice
     (refbox--read-resource-choice "Resource: " choices 'refbox-open))))

(defun refbox--reference-key (reference)
  "Return the key represented by REFERENCE."
  (cond
   ((stringp reference) reference)
   ((and (listp reference) (plist-member reference :key))
    (plist-get reference :key))
   (t (user-error "Reference has no key"))))

(defun refbox--reference-source-path (reference)
  "Return REFERENCE's source path, when available."
  (when (listp reference)
    (or (and (plist-member reference :source_path)
             (plist-get reference :source_path))
        (and (plist-member reference :source-path)
             (plist-get reference :source-path)))))

(defun refbox--reference-rpc-params (reference)
  "Return key-shaped RPC params for REFERENCE."
  (let ((key (refbox--reference-key reference))
        (source-path (refbox--reference-source-path reference)))
    (append (list :key key)
            (unless (refbox--blank-string-p source-path)
              (list :source_path source-path)))))

(defun refbox-source-location (reference)
  "Return indexed source location for REFERENCE."
  (refbox-rpc-request
   refbox-rpc-method-source-location
   (refbox--reference-rpc-params reference)))

;;;###autoload
(defun refbox-open-source (&optional reference)
  "Open REFERENCE's bibliography source at its indexed location."
  (interactive)
  (let* ((reference (or reference (refbox-read-reference)))
         (location (refbox-source-location reference))
         (path (plist-get location :source_path))
         (source (plist-get location :source))
         (start (plist-get source :start))
         (line (plist-get start :line))
         (column (plist-get start :column)))
    (unless (and path source)
      (user-error "Reference has no indexed source location"))
    (funcall refbox-source-open-function path)
    (when (buffer-live-p (current-buffer))
      (goto-char (point-min))
      (when line
        (forward-line (1- line)))
      (when column
        (move-to-column (max 0 (1- column)))))
    location))

;;;###autoload
(defun refbox-open-entry (&optional reference)
  "Open REFERENCE's bibliography entry using `refbox-open-entry-function'."
  (interactive)
  (funcall refbox-open-entry-function (or reference (refbox-read-reference))))

(defun refbox-open-entry-in-file (&optional reference)
  "Open REFERENCE's bibliography entry at its indexed source location."
  (refbox-open-source reference))

(defun refbox-zotero-url (reference)
  "Return a Zotero select URL for REFERENCE."
  (format "zotero://select/items/@%s" (refbox--reference-key reference)))

;;;###autoload
(defun refbox-open-in-zotero (&optional reference)
  "Open REFERENCE in Zotero using its citation key."
  (interactive)
  (let ((reference (or reference (refbox-read-reference))))
    (funcall refbox-zotero-open-function (refbox-zotero-url reference))))

(defun refbox-open-entry-in-zotero (&optional reference)
  "Open REFERENCE in Zotero using its citation key."
  (refbox-open-in-zotero reference))

(defun refbox-raw-entry (reference)
  "Return raw bibliography entry text for REFERENCE."
  (let ((response (refbox-rpc-request
                   refbox-rpc-method-raw-entry
                   (refbox--reference-rpc-params reference))))
    (or (plist-get response :raw)
        (user-error "Reference has no raw entry text"))))

(defun refbox--reference-list (references)
  "Return REFERENCES as a list of references."
  (cond
   ((null references)
    (refbox-read-references "References: "))
   ((and (listp references) (plist-member references :key))
    (list references))
   ((listp references) references)
   (t (list references))))

;;;###autoload
(defun refbox-insert-raw-entry (&optional references)
  "Insert raw bibliography entries for REFERENCES."
  (interactive)
  (let ((references (refbox--reference-list references)))
    (unless references
      (user-error "No references selected"))
    (insert
     (string-join
      (mapcar #'refbox-raw-entry references)
      "\n\n"))))

(defun refbox--raw-entry-field-end ()
  "Return the end position of the raw field at point."
  (let ((depth 0)
        (in-string nil)
        (escaped nil)
        done)
    (while (and (not done) (not (eobp)))
      (let ((char (char-after)))
        (cond
         (escaped
          (setq escaped nil))
         ((and in-string (eq char ?\\))
          (setq escaped t))
         ((and in-string (eq char ?\"))
          (setq in-string nil))
         (in-string)
         ((eq char ?\")
          (setq in-string t))
         ((eq char ?{)
          (setq depth (1+ depth)))
         ((eq char ?})
          (if (= depth 0)
              (setq done t)
            (setq depth (1- depth))))
         ((and (eq char ?,) (= depth 0))
          (forward-char 1)
          (setq done t))))
      (unless done
        (forward-char 1)))
    (point)))

(defun refbox-raw-entry-remove-fields (raw fields)
  "Return RAW with bibliography FIELDS removed."
  (let ((fields (mapcar #'refbox--field-name-normalize fields)))
    (with-temp-buffer
      (insert raw)
      (goto-char (point-min))
      (while (re-search-forward
              "^[ \t]*\\([[:alnum:]_:-]+\\)[ \t\n]*="
              nil t)
        (let ((field (refbox--field-name-normalize
                      (match-string-no-properties 1)))
              (begin (line-beginning-position)))
          (if (member field fields)
              (let ((end (refbox--raw-entry-field-end)))
                (delete-region begin end)
                (goto-char begin))
              (goto-char (refbox--raw-entry-field-end)))))
      (string-trim-right (buffer-string)))))

;;;###autoload
(defun refbox-insert-bibtex (&optional references)
  "Insert BibTeX entries for REFERENCES.

Fields listed in `refbox-bibtex-no-export-fields' are removed before
insertion."
  (interactive)
  (let ((references (refbox--reference-list references)))
    (unless references
      (user-error "No references selected"))
    (insert
     (string-join
      (mapcar (lambda (reference)
                (refbox-raw-entry-remove-fields
                 (refbox-raw-entry reference)
                 refbox-bibtex-no-export-fields))
              references)
      "\n\n"))))

(defun refbox--generic-citation-keys ()
  "Return unique @KEY-style citation keys in the current buffer."
  (let (keys)
    (save-excursion
      (goto-char (point-min))
      (while (re-search-forward
              "\\(?:^\\|[^[:word:]_]\\)@\\([[:alnum:]_:.#$%&/+?<>~^-]+\\)"
              nil t)
        (push (match-string-no-properties 1) keys)))
    (delete-dups (nreverse keys))))

(defun refbox--maybe-load-adapter-function (function)
  "Load the integration that should define FUNCTION, when obvious."
  (unless (fboundp function)
    (let ((name (symbol-name function)))
      (cond
       ((string-prefix-p "refbox-org-" name)
        (require 'refbox-org nil t))
       ((string-prefix-p "refbox-latex-" name)
        (require 'refbox-latex nil t))
       ((string-prefix-p "refbox-markdown-" name)
        (require 'refbox-markdown nil t))))))

(defun refbox--callable-adapter-function (function)
  "Return FUNCTION when it is callable, loading its integration if needed."
  (when function
    (refbox--maybe-load-adapter-function function)
    (unless (fboundp function)
      (user-error "refbox adapter function is not available: %s" function))
    function))

(defun refbox--get-major-mode-function (key &optional default)
  "Return adapter function for KEY in `refbox-major-mode-functions'."
  (let* ((entry
          (cl-find-if
           (pcase-lambda (`(,modes . ,_functions))
             (or (eq modes t)
                 (apply #'derived-mode-p
                        (if (listp modes) modes (list modes)))))
           refbox-major-mode-functions))
         (function (alist-get key (cdr entry) default)))
    (refbox--callable-adapter-function function)))

(defun refbox--major-mode-function (key default &rest args)
  "Call the adapter for KEY with ARGS, falling back to DEFAULT."
  (apply (refbox--get-major-mode-function key default) args))

(defun refbox--insert-keys-comma-space-separated (keys)
  "Insert KEYS separated by comma and space."
  (insert (string-join keys ", ")))

(defun refbox--references-keys (references)
  "Return reference keys from REFERENCES."
  (delq nil (mapcar #'refbox--reference-key references)))

(defun refbox--org-citation-keys (citation)
  "Return Org citation keys from CITATION."
  (when (and (fboundp 'org-cite-get-references)
             (fboundp 'org-element-property))
    (mapcar (lambda (reference)
              (org-element-property :key reference))
            (org-cite-get-references citation))))

(defun refbox--citation-keys-from-value (value)
  "Return citation keys represented by mode-specific VALUE."
  (cond
   ((null value) nil)
   ((and (listp value)
         (plist-member value :keys))
    (refbox--listify (plist-get value :keys)))
   ((and (consp value)
         (listp (car value))
         (cl-every #'stringp (car value)))
    (car value))
   ((and (fboundp 'org-element-type)
         (memq (org-element-type value) '(citation citation-reference)))
    (let ((citation (if (eq (org-element-type value) 'citation)
                        value
                      (and (fboundp 'org-element-parent)
                           (org-element-parent value)))))
      (and citation (refbox--org-citation-keys citation))))
   (t nil)))

;;;###autoload
(defun refbox-key-at-point ()
  "Return the citation key at point in the current buffer, or nil."
  (refbox--major-mode-function 'key-at-point #'ignore))

;;;###autoload
(defun refbox-citation-at-point ()
  "Return citation keys at point in the current buffer, or nil."
  (refbox--citation-keys-from-value
   (refbox--major-mode-function 'citation-at-point #'ignore)))

(defun refbox-current-buffer-citation-keys (&optional buffer)
  "Return unique citation keys in BUFFER."
  (with-current-buffer (or buffer (current-buffer))
    (refbox--major-mode-function
     'list-keys
     #'refbox--generic-citation-keys)))

;;;###autoload
(defun refbox-local-bibliography-files (&optional buffer)
  "Return bibliography files declared locally for BUFFER."
  (with-current-buffer (or buffer (current-buffer))
    (refbox--major-mode-function 'local-bib-files #'ignore)))

;;;###autoload
(defun refbox-insert-keys (&optional references)
  "Insert selected reference keys in a mode-appropriate form."
  (interactive)
  (let ((keys (refbox--references-keys (refbox--reference-list references))))
    (unless keys
      (user-error "No references selected"))
    (refbox--major-mode-function
     'insert-keys
     #'refbox--insert-keys-comma-space-separated
     keys)))

;;;###autoload
(defun refbox-insert-citation (&optional references arg)
  "Insert or edit a citation using the current major-mode adapter.

REFERENCES, when non-nil, supplies reference keys or candidates.  ARG is
passed to the adapter command."
  (interactive (list nil current-prefix-arg))
  (unless (refbox--get-major-mode-function 'insert-citation)
    (user-error "Citation insertion is not supported for %s" major-mode))
  (refbox--major-mode-function
   'insert-citation
   #'ignore
   (and references
        (refbox--references-keys (refbox--reference-list references)))
   arg))

;;;###autoload
(defun refbox-insert-edit (&optional arg)
  "Edit the citation at point using the current major-mode adapter."
  (interactive "P")
  (if (refbox--get-major-mode-function 'insert-edit)
      (refbox--major-mode-function 'insert-edit #'ignore arg)
    (refbox-insert-citation nil arg)))

;;;###autoload
(defun refbox-run-default-action (&optional references)
  "Run `refbox-default-action' on REFERENCES."
  (interactive)
  (let ((references (refbox--reference-list references)))
    (unless references
      (user-error "No references selected"))
    (funcall refbox-default-action references)))

;;;###autoload
(defun refbox-dwim ()
  "Run the default action on citation keys at point."
  (interactive)
  (let ((references (or (when-let ((key (refbox-key-at-point)))
                          (list key))
                        (refbox-citation-at-point))))
    (cond
     (references
      (refbox-run-default-action references))
     ((memq refbox-at-point-fallback '(prompt t))
      (refbox-run-default-action nil))
     (t
      (user-error "No citation keys found")))))

;;;###autoload
(defun refbox-at-point ()
  "Run `refbox-at-point-function'."
  (interactive)
  (funcall refbox-at-point-function))

;;;###autoload
(defun refbox-export-bibliography (file &optional keys)
  "Export raw bibliography entries for KEYS to FILE."
  (interactive
   (list (read-file-name "Export bibliography to: " nil nil nil "references.bib")))
  (let ((keys (or keys (refbox-current-buffer-citation-keys))))
    (unless keys
      (user-error "Current buffer contains no citation keys"))
    (with-temp-file file
      (insert
       (string-join
        (mapcar (lambda (key)
                  (refbox-raw-entry-remove-fields
                   (refbox-raw-entry key)
                   refbox-bibtex-no-export-fields))
                keys)
        "\n\n"))
      (insert "\n"))
    file))

(defun refbox--local-bibliography-extension ()
  "Return the preferred extension for a generated local bibliography."
  (let ((extension
         (or (when-let ((file (car (refbox-local-bibliography-files))))
               (file-name-extension file))
             (when-let ((file (car refbox-bibliography)))
               (file-name-extension file))
             (car refbox-bibliography-extensions)
             "bib")))
    (if (refbox--blank-string-p extension)
        "bib"
      (string-remove-prefix "." extension))))

;;;###autoload
(defun refbox-export-local-bibliography (&optional file)
  "Export the current buffer's citations to a local bibliography FILE."
  (interactive)
  (let ((file (or file
                  (expand-file-name
                   (format "local-bib.%s"
                           (refbox--local-bibliography-extension))
                   (or (and buffer-file-name
                            (file-name-directory buffer-file-name))
                       default-directory)))))
    (refbox-export-bibliography file)))

;;;###autoload
(defun refbox-export-local-bib-file (&optional file)
  "Export the current buffer's citations to a local bibliography file."
  (interactive)
  (refbox-export-local-bibliography file))

(defun refbox-csl--directories (dirs)
  "Return existing CSL DIRS."
  (refbox-resource--directory-list dirs nil))

(defun refbox-csl--readable-file-p (file)
  "Return non-nil when FILE is a readable regular file."
  (and (file-regular-p file)
       (file-readable-p file)))

(defun refbox-csl--style-files ()
  "Return configured CSL style files."
  (apply
   #'append
   (mapcar (lambda (dir)
             (cl-remove-if-not
              #'refbox-csl--readable-file-p
              (directory-files dir t "\\.csl\\'")))
           (refbox-csl--directories refbox-citeproc-csl-styles-dir))))

(defun refbox-csl--locale-files ()
  "Return configured CSL locale files."
  (apply
   #'append
   (mapcar (lambda (dir)
             (cl-remove-if-not
              #'refbox-csl--readable-file-p
              (directory-files dir t "\\.xml\\'")))
           (refbox-csl--directories refbox-citeproc-csl-locales-dir))))

(defun refbox-csl--node-children (node)
  "Return XML NODE children."
  (cddr node))

(defun refbox-csl--child-node (node name)
  "Return the first direct XML child named NAME under NODE."
  (cl-find-if (lambda (child)
                (and (listp child)
                     (eq (car child) name)))
              (refbox-csl--node-children node)))

(defun refbox-csl--node-text (node)
  "Return text content from XML NODE."
  (string-trim
   (mapconcat (lambda (child)
                (if (stringp child) child ""))
              (refbox-csl--node-children node)
              "")))

(defun refbox-citeproc-csl-metadata (file)
  "Return metadata plist for CSL style FILE."
  (let* ((root (car (xml-parse-file file)))
         (info-node (and root (refbox-csl--child-node root 'info)))
         (title-node (and info-node (refbox-csl--child-node info-node 'title)))
         (id-node (and info-node (refbox-csl--child-node info-node 'id)))
         (title (and title-node (refbox-csl--node-text title-node)))
         (id (and id-node (refbox-csl--node-text id-node))))
    (list :file file
          :id (unless (refbox--blank-string-p id) id)
          :title (if (refbox--blank-string-p title)
                     (file-name-base file)
                   title))))

(defun refbox-csl--name-match-p (file value extension)
  "Return non-nil when FILE name matches VALUE with EXTENSION."
  (let ((name (if (string-suffix-p extension value)
                  value
                (concat value extension))))
    (or (string= (file-name-nondirectory file) name)
        (string= (file-name-base file) value))))

(defun refbox-csl--style-match-p (file value)
  "Return non-nil when CSL style FILE matches VALUE."
  (or (refbox-csl--name-match-p file value ".csl")
      (equal (plist-get (ignore-errors (refbox-citeproc-csl-metadata file)) :id)
             value)))

(defun refbox-csl--locale-match-p (file value)
  "Return non-nil when CSL locale FILE matches VALUE."
  (or (refbox-csl--name-match-p file value ".xml")
      (refbox-csl--name-match-p file (concat "locales-" value) ".xml")))

(defun refbox-csl--resolve-file (value files kind match-function)
  "Resolve VALUE against FILES for KIND using MATCH-FUNCTION."
  (cond
   ((refbox--blank-string-p value)
    (user-error "`refbox-citeproc-csl-%s' is not configured" kind))
   (t
    (let ((match (cl-find-if
                  (lambda (file)
                    (funcall match-function file value))
                  files)))
      (cond
       (match match)
       ((or (file-name-absolute-p value) (file-name-directory value))
        (let ((file (expand-file-name value)))
          (unless (refbox-csl--readable-file-p file)
            (user-error "refbox CSL %s file is not readable: %s" kind file))
          file))
       (t
        (user-error "refbox CSL %s not found in configured directories: %s"
                    kind value)))))))

(defun refbox-csl--style-file ()
  "Return the selected CSL style file or signal an actionable error."
  (refbox-csl--resolve-file
   refbox-citeproc-csl-style
   (refbox-csl--style-files)
   "style"
   #'refbox-csl--style-match-p))

(defun refbox-csl--locale-file ()
  "Return the selected CSL locale file or signal an actionable error."
  (refbox-csl--resolve-file
   refbox-citeproc-csl-locale
   (refbox-csl--locale-files)
   "locale"
   #'refbox-csl--locale-match-p))

;;;###autoload
(defun refbox-citeproc-select-csl-style ()
  "Select a CSL style from `refbox-citeproc-csl-styles-dir'."
  (interactive)
  (let ((metadata (mapcar #'refbox-citeproc-csl-metadata
                          (refbox-csl--style-files))))
    (unless metadata
      (user-error "`refbox-citeproc-csl-styles-dir' contains no readable CSL styles"))
    (let ((table (make-hash-table :test 'equal)))
      (dolist (item metadata)
        (let* ((title (plist-get item :title))
               (id (plist-get item :id))
               (label (if id
                          (format "%s <%s>" title id)
                        title)))
          (puthash label item table)))
      (let* ((choice (completing-read "CSL style: " table nil t))
             (item (gethash choice table)))
        (setq refbox-citeproc-csl-style (plist-get item :file))
        (message "refbox CSL style: %s" (plist-get item :title))
        refbox-citeproc-csl-style))))

(defun refbox-citeproc--format-references (references &optional style)
  "Return CSL-formatted reference strings for REFERENCES.

STYLE, when non-nil, overrides `refbox-citeproc-csl-style'."
  (let ((references (refbox--reference-list references)))
    (unless references
      (user-error "No references selected"))
    (when (or current-prefix-arg
              (and (null style)
                   (refbox--blank-string-p refbox-citeproc-csl-style)))
      (refbox-citeproc-select-csl-style))
    (let ((refbox-citeproc-csl-style
           (or style refbox-citeproc-csl-style)))
      (let* ((style-path (refbox-csl--style-file))
             (locale-path (refbox-csl--locale-file))
             (response
              (refbox-rpc-request
               refbox-rpc-method-format-references
               (list :keys (vconcat (mapcar #'refbox--reference-key references))
                     :style_path style-path
                     :locale_path locale-path))))
        (mapcar (lambda (item)
                  (plist-get item :text))
                (refbox--listify (plist-get response :references)))))))

(defun refbox-citeproc-format-reference (references &optional style)
  "Return CSL-formatted reference text for REFERENCES.

STYLE, when non-nil, overrides `refbox-citeproc-csl-style'."
  (string-join (refbox-citeproc--format-references references style) "\n\n"))

(defun refbox-format-references (references)
  "Return template-formatted reference strings for REFERENCES."
  (mapcar #'refbox-reference-format-preview
          (refbox--reference-list references)))

(defun refbox-format-reference (references)
  "Return formatted reference text for REFERENCES."
  (string-join (refbox-format-references references) "\n\n"))

(defun refbox--format-reference-text (references)
  "Return formatted reference text for REFERENCES using configured formatter."
  (funcall (or refbox-format-reference-function #'refbox-format-reference)
           references))

;;;###autoload
(defun refbox-insert-reference (&optional references)
  "Insert formatted references for REFERENCES."
  (interactive)
  (insert (refbox--format-reference-text references)))

;;;###autoload
(defun refbox-copy-reference (&optional references)
  "Copy formatted references for REFERENCES to the kill ring."
  (interactive)
  (let ((text (refbox--format-reference-text references)))
    (kill-new text)
    (when (called-interactively-p 'interactive)
      (message "refbox: copied formatted reference%s"
               (if (string-match-p "\n\n" text) "s" "")))
    text))

(defun refbox-library--safe-key (key)
  "Return KEY made safe for a single file name."
  (replace-regexp-in-string "[/\\]" "_" key))

(defun refbox-library-default-file-name (key extension)
  "Return default library file name for KEY and EXTENSION."
  (format "%s.%s"
          (refbox-library--safe-key key)
          (string-remove-prefix "." extension)))

(defun refbox-library--primary-directory ()
  "Return a library destination directory, creating it if needed."
  (unless refbox-library-paths
    (user-error "`refbox-library-paths' must contain at least one directory"))
  (dolist (directory refbox-library-paths)
    (make-directory (file-name-as-directory (expand-file-name directory)) t))
  (let* ((directories (refbox-resource--library-dirs))
         (directory (if (cdr directories)
                        (completing-read "Library directory: "
                                         directories
                                         nil
                                         t)
                      (car directories))))
    (make-directory directory t)
    (file-name-as-directory (expand-file-name directory))))

(defun refbox-library-destination-file (reference extension)
  "Return destination library file for REFERENCE and EXTENSION."
  (when (refbox--blank-string-p extension)
    (user-error "Cannot add a library file without an extension"))
  (expand-file-name
   (funcall refbox-library-file-name-function
            (refbox--reference-key reference)
            extension)
   (refbox-library--primary-directory)))

(defun refbox-library--check-destination (destination overwrite)
  "Signal when DESTINATION exists and OVERWRITE is nil."
  (when (file-exists-p destination)
    (cond
     ((integerp overwrite)
      (unless (yes-or-no-p
               (format "Library file exists: %s; overwrite? " destination))
        (user-error "Library file already exists: %s" destination)))
     ((not overwrite)
      (user-error "Library file already exists: %s" destination)))))

(defun refbox-add-buffer-to-library (reference extension &optional overwrite)
  "Save current buffer contents as REFERENCE's library file with EXTENSION."
  (let ((destination (refbox-library-destination-file reference extension)))
    (refbox-library--check-destination destination overwrite)
    (write-region (point-min) (point-max) destination nil 'silent)
    destination))

(defun refbox-add-file-to-library-from-file (reference file &optional overwrite)
  "Copy FILE into the library for REFERENCE."
  (let* ((extension (file-name-extension file))
         (destination (refbox-library-destination-file reference extension)))
    (copy-file file destination overwrite)
    destination))

(defun refbox-add-file-to-library-from-url
    (reference url extension &optional overwrite)
  "Copy URL into the library for REFERENCE using EXTENSION."
  (let ((destination (refbox-library-destination-file reference extension)))
    (url-copy-file url destination overwrite)
    destination))

(defun refbox-save-file-to-library (reference source &optional overwrite)
  "Save SOURCE as a library resource for REFERENCE.

SOURCE is a plist returned by one of `refbox-add-file-sources'.
OVERWRITE follows the same convention as `copy-file'; an integer
asks before replacing an existing file."
  (let* ((overwrite (or overwrite 1))
         (extension (or (plist-get source :extension)
                        (read-string "Extension: ")))
         (write-file (plist-get source :write-file))
         (destination (refbox-library-destination-file reference extension)))
    (unless (functionp write-file)
      (user-error "refbox add-file source has no callable :write-file"))
    (funcall write-file destination overwrite)
    destination))

(defun refbox-add-file-source-buffer (_reference)
  "Return an add-file source plist for a selected buffer."
  (let ((buffer (get-buffer (read-buffer "Buffer: " (current-buffer) t))))
    (list
     :extension (when (buffer-file-name buffer)
                  (file-name-extension (buffer-file-name buffer)))
     :write-file
     (lambda (destination overwrite)
       (with-current-buffer buffer
         (refbox-library--check-destination destination overwrite)
         (write-region (point-min) (point-max) destination nil 'silent))))))

(defun refbox-add-file-source-file (_reference)
  "Return an add-file source plist for an existing file."
  (let ((file (read-file-name "File: " nil nil t)))
    (list
     :extension (file-name-extension file)
     :write-file
     (lambda (destination overwrite)
       (copy-file file destination overwrite)))))

(defun refbox-add-file-source-url (_reference)
  "Return an add-file source plist for a URL."
  (let ((url (read-string "URL: ")))
    (list
     :write-file
     (lambda (destination overwrite)
       (url-copy-file url destination overwrite)))))

(defun refbox-add-file-source--function (source)
  "Return the function configured for add-file SOURCE."
  (unless (and (listp source)
               (= (length source) 4)
               (characterp (nth 0 source))
               (stringp (nth 1 source))
               (stringp (nth 2 source)))
    (user-error "Invalid refbox add-file source: %S" source))
  (let ((function (nth 3 source)))
    (unless (functionp function)
      (user-error "refbox add-file source %s has no callable function"
                  (nth 1 source)))
    function))

(defun refbox-add-file-source--read ()
  "Prompt for and return a source from `refbox-add-file-sources'."
  (unless refbox-add-file-sources
    (user-error "Make sure `refbox-add-file-sources' is non-nil"))
  (dolist (source refbox-add-file-sources)
    (refbox-add-file-source--function source))
  (read-multiple-choice "Add file from" refbox-add-file-sources))

;;;###autoload
(defun refbox-add-file-to-library (&optional reference)
  "Add a configured source resource to REFERENCE's library files."
  (interactive)
  (unless (functionp refbox-add-file-function)
    (user-error "refbox-add-file-function is not callable"))
  (let* ((reference (or reference (refbox-read-reference)))
         (source (refbox-add-file-source--read))
         (source-plist (funcall (refbox-add-file-source--function source)
                                reference)))
    (funcall refbox-add-file-function reference source-plist)))

(defun refbox--completion-state (&optional limit source-paths)
  "Return fresh completion state using LIMIT and SOURCE-PATHS."
  (list :limit (refbox-rpc--search-limit limit)
        :source-paths source-paths
        :input nil
        :candidates nil
        :map (make-hash-table :test 'equal)
        :cache (make-hash-table :test 'eq)))

(defun refbox--completion-candidate-display (candidate seen)
  "Return a propertized display string for CANDIDATE using SEEN map."
  (let ((refbox--reference-field-cache
         (or refbox--reference-field-cache
             (make-hash-table :test 'eq))))
    (let* ((base (refbox-reference-format-main candidate))
           (suffix (refbox-reference-format-suffix candidate))
           (display base)
           (source-path (refbox-reference-field candidate "source_path"))
           (counter 2))
      (when (gethash display seen)
        (setq display (format "%s  [%s]" base source-path)))
      (while (gethash display seen)
        (setq display (format "%s <%d>" base counter)
              counter (1+ counter)))
      (puthash display candidate seen)
      (propertize display
                  'refbox-candidate candidate
                  'refbox-annotation suffix))))

(defun refbox--completion-annotation-text (completion)
  "Return cached annotation text for COMPLETION."
  (or (get-text-property 0 'refbox-annotation completion)
      (when-let ((candidate (get-text-property 0 'refbox-candidate completion)))
        (let ((refbox--reference-field-cache (make-hash-table :test 'eq)))
          (refbox-reference-format-suffix candidate)))))

(defun refbox--completion-state-candidates (state input)
  "Return bounded completion candidates for INPUT using STATE."
  (setq input (substring-no-properties input))
  (unless (equal input (plist-get state :input))
    (refbox--with-dynamic-cache (plist-get state :cache)
      (let ((seen (plist-get state :map)))
        (clrhash seen)
        (setf (plist-get state :input) input)
        (setf (plist-get state :candidates)
              (mapcar (lambda (candidate)
                        (refbox--completion-candidate-display candidate seen))
                      (refbox-search-references
                       input
                       (plist-get state :limit)
                       (plist-get state :source-paths)))))))
  (plist-get state :candidates))

(defun refbox--completion-filter (candidates predicate)
  "Return CANDIDATES accepted by PREDICATE."
  (if predicate
      (cl-remove-if-not predicate candidates)
    candidates))

(defun refbox--completion-table (state)
  "Return a dynamic completion table backed by bounded daemon search STATE."
  (lambda (string predicate action)
    (cond
     ((eq action 'metadata)
      '(metadata
        (category . refbox-reference)
        (annotation-function . refbox--completion-annotation)
        (affixation-function . refbox--completion-affixation)))
     (t
      (let ((candidates (refbox--completion-filter
                         (refbox--completion-state-candidates state string)
                         predicate)))
        (cond
         ((eq action t) candidates)
         ((eq action 'lambda)
          (cl-some (lambda (candidate)
                     (string= string (substring-no-properties candidate)))
                   candidates))
         ((cl-some (lambda (candidate)
                     (string= string (substring-no-properties candidate)))
                   candidates)
          t)
         ((null candidates) nil)
         ((null (cdr candidates)) (car candidates))
         (t string)))))))

(defun refbox--completion-annotation (completion)
  "Return annotation text for COMPLETION."
  (when-let ((annotation (refbox--completion-annotation-text completion)))
    (concat " " annotation)))

(defun refbox--completion-affixation (completions)
  "Return affixation triples for COMPLETIONS."
  (refbox--with-dynamic-cache nil
    (let ((refbox--reference-field-cache (make-hash-table :test 'eq)))
      (mapcar
       (lambda (completion)
         (list completion
               ""
               (if-let ((annotation (refbox--completion-annotation-text completion)))
                   (concat " " annotation)
                 "")))
       completions))))

(defun refbox--completion-predicate (predicate)
  "Return a completion predicate wrapping candidate PREDICATE."
  (when predicate
    (lambda (completion)
      (when-let ((candidate (get-text-property 0 'refbox-candidate completion)))
        (funcall predicate candidate)))))

(defun refbox--read-reference
    (prompt preset limit allow-empty &optional predicate source-paths)
  "Read one reference.

PROMPT, PRESET, LIMIT, ALLOW-EMPTY, PREDICATE, and SOURCE-PATHS
control completion and validation."
  (refbox--sync-current-bibliography-buffer-if-needed)
  (let* ((state (refbox--completion-state limit source-paths))
         (selection (completing-read
                     prompt
                     (refbox--completion-table state)
                     (refbox--completion-predicate predicate)
                     (not allow-empty)
                     preset
                     'refbox-history
                     refbox-presets))
         (selection-key (substring-no-properties selection)))
    (cond
     ((and allow-empty (string-empty-p selection-key)) nil)
     ((gethash selection-key (plist-get state :map)))
     ((get-text-property 0 'refbox-candidate selection))
     (t (user-error "Unknown refbox reference selection: %s" selection)))))

;;;###autoload
(defun refbox-insert-preset ()
  "Prompt for and insert a predefined reference search."
  (interactive)
  (unless (minibufferp)
    (user-error "Command can only be used in minibuffer"))
  (let ((enable-recursive-minibuffers t))
    (insert (completing-read "Preset: " refbox-presets nil t))))

(defun refbox--normalized-bibliography-extensions ()
  "Return normalized bibliography extensions accepted by refbox."
  (cl-loop for extension in refbox-bibliography-extensions
           when (and (stringp extension)
                     (not (string-empty-p extension)))
           collect (downcase (string-remove-prefix "." extension))))

(defun refbox--bibliography-extension-p (file)
  "Return non-nil when FILE has a configured bibliography extension."
  (when-let ((extension (file-name-extension file)))
    (member (downcase extension)
            (refbox--normalized-bibliography-extensions))))

(defun refbox--bibliography-root ()
  "Return the daemon bibliography root used for file-level sync."
  (when-let ((root (car refbox-bibliography-roots)))
    (let ((root (expand-file-name root)))
      (when (file-directory-p root)
        (file-name-as-directory (file-truename root))))))

(defun refbox--file-in-bibliography-root-p (file)
  "Return non-nil when FILE is inside the active bibliography root."
  (when-let ((root (refbox--bibliography-root)))
    (file-in-directory-p (expand-file-name file) root)))

(defun refbox--syncable-file-p (file)
  "Return non-nil when FILE is eligible for targeted autosync."
  (and file
       (not (auto-save-file-name-p file))
       (not (backup-file-name-p file))
       (refbox--bibliography-extension-p file)
       (refbox--file-in-bibliography-root-p file)))

(defun refbox--syncable-buffer-p (&optional buffer)
  "Return non-nil when BUFFER visits a syncable bibliography file."
  (with-current-buffer (or buffer (current-buffer))
    (refbox--syncable-file-p buffer-file-name)))

(defun refbox--sync-full (&optional quiet)
  "Synchronize all configured bibliography roots.

When QUIET is non-nil, do not report successful sync counts."
  (let* ((response (refbox-rpc-request refbox-rpc-method-sync-full))
         (changed (plist-get response :changed_file_count))
         (removed (plist-get response :removed_file_count))
         (entries (plist-get response :indexed_entry_count)))
    (unless quiet
      (message "refbox sync: %s changed, %s removed, %s indexed entries"
               changed removed entries))
    response))

(defun refbox--sync-file (file &optional quiet)
  "Synchronize bibliography FILE.

When QUIET is non-nil, do not report successful sync counts."
  (let* ((path (expand-file-name file))
         (response (refbox-rpc-request refbox-rpc-method-sync-file
                                       (list :path path)))
         (changed (plist-get response :changed_file_count))
         (removed (plist-get response :removed_file_count))
         (entries (plist-get response :indexed_entry_count)))
    (unless quiet
      (message "refbox file sync: %s changed, %s removed, %s indexed entries"
               changed removed entries))
    response))

(defun refbox--autosync-warn (operation file error)
  "Warn that autosync OPERATION for FILE failed with ERROR."
  (display-warning
   'refbox
   (format "refbox autosync %s failed for %s: %s"
           operation file (error-message-string error))
   :warning))

(defun refbox--autosync-sync-full ()
  "Run a quiet full sync for `refbox-autosync-mode'."
  (condition-case error
      (refbox--sync-full 'quiet)
    (error (refbox--autosync-warn "full sync" "<configured roots>" error))))

(defun refbox--autosync-sync-file (file operation)
  "Run a quiet targeted sync for FILE after OPERATION."
  (when (refbox--syncable-file-p file)
    (condition-case error
        (refbox--sync-file file 'quiet)
      (error (refbox--autosync-warn operation file error)))))

(defun refbox--autosync-after-save-h ()
  "Synchronize the current bibliography file after saving it."
  (unless refbox--autosync-suppress-after-save
    (refbox--autosync-sync-file buffer-file-name "save")))

(defun refbox--autosync-setup-buffer (&optional buffer)
  "Install or remove autosync save hooks for BUFFER."
  (with-current-buffer (or buffer (current-buffer))
    (if (and refbox-autosync-mode
             (refbox--syncable-buffer-p))
        (add-hook 'after-save-hook #'refbox--autosync-after-save-h nil t)
      (remove-hook 'after-save-hook #'refbox--autosync-after-save-h t))))

(defun refbox--autosync-setup-file-h ()
  "Set up autosync for the current file-visiting buffer."
  (refbox--autosync-setup-buffer))

(defun refbox--autosync-delete-file-a (file &rest _args)
  "Synchronize the index after deleting FILE."
  (refbox--autosync-sync-file file "delete"))

(defun refbox--autosync-rename-file-a (old-file new-file-or-dir &rest _args)
  "Synchronize the index after renaming OLD-FILE to NEW-FILE-OR-DIR."
  (let ((new-file (if (directory-name-p new-file-or-dir)
                      (expand-file-name (file-name-nondirectory old-file)
                                        new-file-or-dir)
                    new-file-or-dir)))
    (refbox--autosync-sync-file old-file "rename")
    (refbox--autosync-sync-file new-file "rename")))

(defun refbox--sync-current-bibliography-buffer-if-needed ()
  "Save and sync the current buffer when it visits a modified bibliography."
  (when (and (refbox--syncable-buffer-p)
             (buffer-modified-p))
    (let ((refbox--autosync-suppress-after-save t))
      (save-buffer))
    (refbox--sync-file buffer-file-name 'quiet)))

;;;###autoload
(define-minor-mode refbox-autosync-mode
  "Keep the refbox index current for Emacs bibliography file events.

Enabling this global mode performs a full sync when
`refbox-autosync-sync-on-enable' is non-nil, installs buffer-local
save hooks for tracked bibliography files, and updates the index after
tracked files are renamed or deleted through Emacs."
  :global t
  :group 'refbox
  (if refbox-autosync-mode
      (progn
        (add-hook 'find-file-hook #'refbox--autosync-setup-file-h)
        (advice-add #'rename-file :after #'refbox--autosync-rename-file-a)
        (advice-add #'delete-file :after #'refbox--autosync-delete-file-a)
        (advice-add #'vc-delete-file :after #'refbox--autosync-delete-file-a)
        (dolist (buffer (buffer-list))
          (refbox--autosync-setup-buffer buffer))
        (when refbox-autosync-sync-on-enable
          (refbox--autosync-sync-full)))
    (remove-hook 'find-file-hook #'refbox--autosync-setup-file-h)
    (advice-remove #'rename-file #'refbox--autosync-rename-file-a)
    (advice-remove #'delete-file #'refbox--autosync-delete-file-a)
    (advice-remove #'vc-delete-file #'refbox--autosync-delete-file-a)
    (dolist (buffer (buffer-list))
      (refbox--autosync-setup-buffer buffer))))

;;;###autoload
(cl-defun refbox-select-references (&key (multiple t) filter preset limit source-paths)
  "Select references from the indexed bibliography.

When MULTIPLE is non-nil, return a list of candidates.  Otherwise
return a single candidate.  FILTER, when non-nil, is called with
each candidate and should return non-nil for selectable references."
  (interactive)
  (let ((selected
         (if (and multiple refbox-select-multiple)
             (refbox-read-references "References: " preset limit filter source-paths)
           (refbox-read-reference "Reference: " preset limit filter source-paths))))
    (when (called-interactively-p 'interactive)
      (let ((count (cond
                    ((null selected) 0)
                    ((and (listp selected) (plist-member selected :key)) 1)
                    ((listp selected) (length selected))
                    (t 1))))
        (message "refbox: selected %d reference%s"
                 count
                 (if (= count 1) "" "s"))))
    selected))

;;;###autoload
(cl-defun refbox-select-reference (&key filter preset limit source-paths)
  "Select and return one reference from the indexed bibliography."
  (interactive)
  (refbox-select-references
   :multiple nil
   :filter filter
   :preset preset
   :limit limit
   :source-paths source-paths))

;;;###autoload
(cl-defun refbox-select-refs (&key (multiple t) filter preset limit source-paths)
  "Select reference keys from the indexed bibliography.

FILTER, when non-nil, is called with each candidate key."
  (mapcar #'refbox--reference-key
          (refbox--reference-list
           (refbox-select-references
            :multiple multiple
            :filter (when filter
                      (lambda (candidate)
                        (funcall filter (refbox--reference-key candidate))))
            :preset preset
            :limit limit
            :source-paths source-paths))))

;;;###autoload
(cl-defun refbox-select-ref (&key filter preset limit source-paths)
  "Select and return one reference key from the indexed bibliography."
  (car (refbox-select-refs
        :multiple nil
        :filter filter
        :preset preset
        :limit limit
        :source-paths source-paths)))

;;;###autoload
(defun refbox-read-reference (&optional prompt preset limit predicate source-paths)
  "Read and return a single indexed reference candidate.

PRESET is inserted as the initial minibuffer search text.  LIMIT
bounds each daemon search request.  PREDICATE, when non-nil, is
called with each candidate and should return non-nil for
selectable references.  SOURCE-PATHS restricts searches to those
bibliography source files."
  (interactive)
  (let ((candidate (refbox--read-reference
                    (or prompt "Reference: ")
                    preset
                    limit
                    nil
                    predicate
                    source-paths)))
    (when (called-interactively-p 'interactive)
      (message "refbox: %s" (refbox-reference-field candidate "key")))
    candidate))

;;;###autoload
(defun refbox-read-references (&optional prompt preset limit predicate source-paths)
  "Read and return multiple indexed reference candidates.

Each selection performs a bounded daemon search for the current
minibuffer input.  An empty selection finishes the read.  PREDICATE,
when non-nil, is called with each candidate and should return
non-nil for selectable references.  SOURCE-PATHS restricts
searches to those bibliography source files."
  (interactive)
  (let ((prompt (or prompt "Reference (empty when done): "))
        (next-preset preset)
        selected
        candidate)
    (while (setq candidate
                 (refbox--read-reference
                  prompt next-preset limit t predicate source-paths))
      (push candidate selected)
      (setq next-preset nil))
    (setq selected (nreverse selected))
    (when (called-interactively-p 'interactive)
      (message "refbox: selected %d reference%s"
               (length selected)
               (if (= (length selected) 1) "" "s")))
    selected))

;;;###autoload
(defun refbox-ping ()
  "Check that the local refbox daemon responds."
  (interactive)
  (let* ((response (refbox-rpc-request refbox-rpc-method-ping))
         (version (plist-get response :version))
         (root (plist-get response :root)))
    (message "refbox %s at %s" version root)
    response))

;;;###autoload
(defun refbox-status ()
  "Show the current refbox daemon and index status."
  (interactive)
  (let* ((response (refbox-rpc-request refbox-rpc-method-status))
         (counts (plist-get response :counts))
         (files (plist-get counts :file_count))
         (entries (plist-get counts :entry_count))
         (diagnostics (plist-get counts :diagnostic_count)))
    (message "refbox: %s files, %s entries, %s diagnostics"
             files entries diagnostics)
    response))

;;;###autoload
(defun refbox-sync ()
  "Synchronize all configured bibliography roots."
  (interactive)
  (refbox--sync-full))

;;;###autoload
(defun refbox-sync-file (file)
  "Synchronize bibliography FILE."
  (interactive "fSync bibliography file: ")
  (refbox--sync-file file))

;;;###autoload
(defun refbox-sync-current-file ()
  "Synchronize the file visited by the current buffer."
  (interactive)
  (unless buffer-file-name
    (user-error "Current buffer is not visiting a file"))
  (when (buffer-modified-p)
    (let ((refbox--autosync-suppress-after-save t))
      (save-buffer)))
  (refbox-sync-file buffer-file-name))

(provide 'refbox)

;;; refbox.el ends here
