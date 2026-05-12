;;; refbox.el --- Local-first bibliography tools -*- lexical-binding: t; -*-

;; Copyright (C) 2026 refbox contributors

;; Author: refbox contributors <maintainers@example.invalid>
;; Maintainer: refbox contributors <maintainers@example.invalid>
;; Version: 0.1.0
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
(require 'subr-x)
(require 'xml)
(require 'refbox-rpc)

(declare-function refbox-org-list-keys "refbox-org" (&optional buffer))
(declare-function refbox-org-completion-at-point "refbox-org" ())
(declare-function refbox-latex-list-keys "refbox-latex" (&optional buffer))
(declare-function refbox-latex-completion-at-point "refbox-latex" ())
(declare-function refbox-markdown-list-keys "refbox-markdown" (&optional buffer))
(declare-function refbox-markdown-completion-at-point "refbox-markdown" ())

(defcustom refbox-reference-main-template
  "%{key:24} %{author|editor:28!refbox-template-clean} %{date|year:6!refbox-template-year} %{title:*!refbox-template-clean}"
  "Template used for the main reference completion candidate text."
  :type 'string
  :group 'refbox)

(defcustom refbox-reference-suffix-template
  "%{indicators:4} %{entry_type:10} %{source_path!file-name-nondirectory}"
  "Template used for reference completion annotations and suffixes."
  :type 'string
  :group 'refbox)

(defcustom refbox-reference-preview-template
  "%{title|key!refbox-template-clean}\n%{author|editor!refbox-template-clean}\n%{date|year!refbox-template-year}\n%{source_path}"
  "Template used for preview-oriented reference rendering."
  :type 'string
  :group 'refbox)

(defcustom refbox-reference-note-template
  "%{title|key!refbox-template-clean}"
  "Template used when deriving note-oriented reference text."
  :type 'string
  :group 'refbox)

(defcustom refbox-reference-display-width 100
  "Display width used when formatting star-width reference templates."
  :type 'natnum
  :group 'refbox)

(defcustom refbox-capf-limit 50
  "Maximum number of reference candidates requested for CAPF completion."
  :type 'natnum
  :group 'refbox)

(defcustom refbox-reference-resource-indicator "F"
  "Indicator used when a reference has local resource fields."
  :type 'string
  :group 'refbox)

(defcustom refbox-reference-link-indicator "@"
  "Indicator used when a reference has external link fields."
  :type 'string
  :group 'refbox)

(defcustom refbox-reference-note-indicator "N"
  "Indicator used when `refbox-reference-note-predicate' matches."
  :type 'string
  :group 'refbox)

(defcustom refbox-reference-cited-indicator "*"
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

(defcustom refbox-reference-note-predicate nil
  "Function called with a candidate to decide whether it has a note."
  :type '(choice (const :tag "Disabled" nil) function)
  :group 'refbox)

(defcustom refbox-reference-cited-predicate
  #'refbox-reference-cited-in-current-buffer-p
  "Function called with a candidate to decide whether it is cited."
  :type '(choice (const :tag "Disabled" nil) function)
  :group 'refbox)

(defcustom refbox-resource-library-paths nil
  "Directories searched for files associated with references."
  :type '(repeat directory)
  :group 'refbox)

(defcustom refbox-resource-library-paths-recursive nil
  "When non-nil, include subdirectories of `refbox-resource-library-paths'."
  :type 'boolean
  :group 'refbox)

(defcustom refbox-resource-library-file-extensions nil
  "File extensions accepted for associated files.

When nil, associated file lookup does not filter by extension."
  :type '(choice (const :tag "Any extension" nil)
                 (repeat string))
  :group 'refbox)

(defcustom refbox-resource-file-field-names '("file")
  "Indexed field names treated as file-resource fields."
  :type '(repeat string)
  :group 'refbox)

(defcustom refbox-resource-file-parser-functions
  '(refbox-resource-parse-file-field-default
    refbox-resource-parse-file-field-triplet)
  "Functions used to parse file-resource field values."
  :type '(repeat function)
  :group 'refbox)

(defcustom refbox-resource-additional-file-separator nil
  "Regexp separating a reference key from additional file-name text."
  :type '(choice (const :tag "Ignore additional files" nil)
                 regexp)
  :group 'refbox)

(defcustom refbox-resource-open-file-function #'find-file
  "Function used to open file resources."
  :type 'function
  :group 'refbox)

(defcustom refbox-resource-open-link-function #'browse-url
  "Function used to open link resources."
  :type 'function
  :group 'refbox)

(defcustom refbox-resource-link-templates
  '((url . "%s")
    (doi . "https://doi.org/%s")
    (pmid . "https://pubmed.ncbi.nlm.nih.gov/%s/")
    (pmcid . "https://www.ncbi.nlm.nih.gov/pmc/articles/%s/"))
  "Alist mapping resource kinds to URL format strings."
  :type '(alist :key-type symbol :value-type string)
  :group 'refbox)

(defcustom refbox-note-paths nil
  "Directories searched for per-reference note files."
  :type '(repeat directory)
  :group 'refbox)

(defcustom refbox-note-file-extensions '("org" "md")
  "File extensions used for per-reference notes."
  :type '(repeat string)
  :group 'refbox)

(defcustom refbox-note-open-function #'find-file
  "Function used to open note resources."
  :type 'function
  :group 'refbox)

(defcustom refbox-note-content-function #'refbox-note-default-content
  "Function called with KEY and CANDIDATE to initialize a new note."
  :type '(choice (const :tag "Empty note" nil) function)
  :group 'refbox)

(defcustom refbox-source-open-function #'find-file
  "Function used to open bibliography source files."
  :type 'function
  :group 'refbox)

(defcustom refbox-export-no-export-fields '("file")
  "Field names removed when exporting a local bibliography."
  :type '(repeat string)
  :group 'refbox)

(defcustom refbox-csl-style-directories nil
  "Directories containing CSL style files."
  :type '(repeat directory)
  :group 'refbox)

(defcustom refbox-csl-locale-directories nil
  "Directories containing CSL locale files."
  :type '(repeat directory)
  :group 'refbox)

(defcustom refbox-csl-style nil
  "Selected CSL style file or style id."
  :type '(choice (const :tag "Unset" nil) string)
  :group 'refbox)

(defcustom refbox-csl-locale nil
  "Selected CSL locale file or locale id."
  :type '(choice (const :tag "Unset" nil) string)
  :group 'refbox)

(defcustom refbox-format-reference-function nil
  "Optional function used instead of daemon reference formatting."
  :type '(choice (const :tag "Use daemon formatter" nil) function)
  :group 'refbox)

(defcustom refbox-library-file-name-function
  #'refbox-library-default-file-name
  "Function called with KEY and EXTENSION to name added library files."
  :type 'function
  :group 'refbox)

(defvar refbox-reference-history nil
  "Minibuffer history for refbox reference selection.")

(defconst refbox-template--placeholder-regexp "%{\\([^}\n]+\\)}")

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
  (refbox--listify (refbox--candidate-value candidate :fields)))

(defun refbox--candidate-resources (candidate)
  "Return CANDIDATE resources as a list."
  (refbox--listify (refbox--candidate-value candidate :resources)))

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

(defun refbox-reference-field (candidate field)
  "Return FIELD from CANDIDATE.

FIELD may name a protocol property such as key or source_path, a
computed property such as indicators, or an indexed bibliography field."
  (let ((field (refbox--field-name-normalize field)))
    (cond
     ((member field '("key" "citekey"))
      (refbox--candidate-value candidate :key))
     ((member field '("source_path" "source-path" "source" "path"))
      (refbox--candidate-value candidate :source_path :source-path))
     ((member field '("entry_type" "entry-type" "type"))
      (refbox--candidate-value candidate :entry_type :entry-type))
     ((string= field "score")
      (let ((score (refbox--candidate-value candidate :score)))
        (when score (format "%s" score))))
     ((string= field "indicators")
      (refbox-reference-indicators candidate))
     (t
      (cl-loop
       for indexed-field in (refbox--candidate-fields candidate)
       for lookup-name = (refbox--field-lookup-name indexed-field)
       for raw-name = (refbox--field-raw-name indexed-field)
       when (or (and lookup-name
                     (string= field (refbox--field-name-normalize lookup-name)))
                (and raw-name
                     (string= field (refbox--field-name-normalize raw-name))))
       return (refbox--field-value indexed-field))))))

(defun refbox-reference-has-field-p (candidate field)
  "Return non-nil when CANDIDATE has a non-empty FIELD."
  (not (refbox--blank-string-p (refbox-reference-field candidate field))))

(defun refbox-reference-has-any-field-p (candidate fields)
  "Return non-nil when CANDIDATE has any field in FIELDS."
  (cl-some (lambda (field)
             (refbox-reference-has-field-p candidate field))
           fields))

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

(defun refbox-reference-has-files-p (candidate)
  "Return non-nil when CANDIDATE has an indexed file resource."
  (or (refbox-reference-has-resource-kind-p candidate "file")
      (refbox-reference-has-any-field-p
       candidate refbox-reference-resource-field-names)))

(defun refbox-reference-has-links-p (candidate)
  "Return non-nil when CANDIDATE has an indexed link resource."
  (or (refbox-reference-has-any-resource-kind-p
       candidate '("url" "doi" "pmid" "pmcid"))
      (refbox-reference-has-any-field-p
       candidate refbox-reference-link-field-names)))

(defun refbox-reference-cited-in-current-buffer-p (candidate)
  "Return non-nil when CANDIDATE's key appears in the current buffer."
  (let ((key (refbox-reference-field candidate "key")))
    (and (not (refbox--blank-string-p key))
         (let ((buffer (if (minibufferp)
                           (window-buffer (minibuffer-selected-window))
                         (current-buffer))))
           (and (buffer-live-p buffer)
                (with-current-buffer buffer
                  (save-excursion
                    (save-restriction
                      (widen)
                      (goto-char (point-min))
                      (search-forward key nil t)))))))))

(defun refbox--predicate-matches-p (predicate candidate)
  "Return non-nil when PREDICATE matches CANDIDATE."
  (and predicate
       (funcall predicate candidate)))

(defun refbox-reference-indicators (candidate)
  "Return configured indicator text for CANDIDATE."
  (string-join
   (delq nil
         (list
          (when (refbox-reference-has-files-p candidate)
            refbox-reference-resource-indicator)
          (when (refbox-reference-has-links-p candidate)
            refbox-reference-link-indicator)
          (when (refbox--predicate-matches-p
                 refbox-reference-note-predicate candidate)
            refbox-reference-note-indicator)
          (when (refbox--predicate-matches-p
                 refbox-reference-cited-predicate candidate)
            refbox-reference-cited-indicator)))
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

(defun refbox-template-year (value)
  "Return the first four-digit year found in VALUE."
  (let ((text (format "%s" (or value ""))))
    (if (string-match "[0-9][0-9][0-9][0-9]" text)
        (match-string 0 text)
      text)))

(defun refbox-template--parse-field (body)
  "Parse placeholder BODY into a field token."
  (let* ((parts (split-string (string-trim body) "!"))
         (field-part (car parts))
         (transform-part (cadr parts))
         width)
    (when (> (length parts) 2)
      (user-error "refbox template field has multiple transforms: %s" body))
    (when (or (null field-part) (string-empty-p (string-trim field-part)))
      (user-error "refbox template field is empty"))
    (when (and transform-part (string-empty-p (string-trim transform-part)))
      (user-error "refbox template transform is empty: %s" body))
    (when (string-match "\\`\\(.+\\):\\([0-9]+\\|\\*\\)\\'" field-part)
      (setq width (match-string 2 field-part)
            field-part (match-string 1 field-part)))
    (let ((fields (mapcar #'refbox--field-name-normalize
                          (split-string field-part "|" t "[[:space:]\n]+"))))
      (when (null fields)
        (user-error "refbox template field is empty"))
      (list :fields fields
            :width (cond
                    ((null width) nil)
                    ((string= width "*") '*)
                    (t (string-to-number width)))
            :transform (when transform-part
                         (intern (string-trim transform-part)))))))

(defun refbox-template-parse (template)
  "Parse TEMPLATE into literal strings and field tokens."
  (unless (stringp template)
    (user-error "refbox template must be a string"))
  (let ((position 0)
        tokens)
    (while (string-match refbox-template--placeholder-regexp template position)
      (let ((match-start (match-beginning 0))
            (match-end (match-end 0))
            (field-body (match-string 1 template)))
        (when (> match-start position)
          (push (substring template position match-start) tokens))
        (push (refbox-template--parse-field field-body) tokens)
        (setq position match-end)))
    (when (< position (length template))
      (push (substring template position) tokens))
    (nreverse tokens)))

(defun refbox-template--field-text (token candidate)
  "Return TOKEN text for CANDIDATE before width fitting."
  (let ((value (cl-loop
                for field in (plist-get token :fields)
                for field-value = (refbox-reference-field candidate field)
                when (not (refbox--blank-string-p field-value))
                return field-value))
        (transform (plist-get token :transform)))
    (setq value (format "%s" (or value "")))
    (when transform
      (unless (fboundp transform)
        (user-error "refbox template transform is not defined: %s" transform))
      (setq value (format "%s" (or (funcall transform value) ""))))
    value))

(defun refbox-template--fit (value width)
  "Fit VALUE into WIDTH display columns."
  (if (null width)
      value
    (let ((truncated (truncate-string-to-width value width)))
      (if (< (string-width truncated) width)
          (string-pad truncated width)
        truncated))))

(defun refbox-template-format (template candidate &optional width)
  "Format CANDIDATE with TEMPLATE and optional display WIDTH."
  (let* ((tokens (if (stringp template)
                     (refbox-template-parse template)
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

(defun refbox-reference-format-main (candidate &optional width)
  "Return the main display string for CANDIDATE."
  (string-trim-right
   (refbox-template-format
    refbox-reference-main-template
    candidate
    (or width refbox-reference-display-width))))

(defun refbox-reference-format-suffix (candidate &optional width)
  "Return the suffix display string for CANDIDATE."
  (string-trim-right
   (refbox-template-format refbox-reference-suffix-template candidate width)))

(defun refbox-reference-format-preview (candidate &optional width)
  "Return the preview display string for CANDIDATE."
  (refbox-template-format refbox-reference-preview-template candidate width))

(defun refbox-reference-format-note (candidate &optional width)
  "Return note-oriented display text for CANDIDATE."
  (refbox-template-format refbox-reference-note-template candidate width))

(defun refbox-search-references (query &optional limit source-paths)
  "Search indexed references for QUERY using bounded LIMIT.

When SOURCE-PATHS is non-nil, restrict results to those
bibliography source files."
  (let* ((source-paths
          (cl-remove-if
           #'refbox--blank-string-p
           (mapcar #'expand-file-name source-paths)))
         (response (refbox-rpc-request
                    refbox-rpc-method-search-entries
                    (append
                     (list :query (or query "")
                           :limit (refbox-rpc--search-limit limit))
                     (when source-paths
                       (list :source_paths source-paths)))))
         (entries (plist-get response :entries)))
    (refbox--listify entries)))

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
    (when (and (> (car bounds) (or begin (point-min)))
               (eq (char-before (car bounds)) ?@))
      bounds)))

(defun refbox-capf--state (&optional limit source-paths)
  "Return CAPF completion state using LIMIT and SOURCE-PATHS."
  (list :limit (refbox-rpc--search-limit limit)
        :source-paths source-paths
        :input nil
        :candidates nil))

(defun refbox-capf--candidate (candidate seen)
  "Return a key completion candidate from CANDIDATE using SEEN."
  (let ((key (refbox-reference-field candidate "key")))
    (unless (or (refbox--blank-string-p key)
                (gethash key seen))
      (puthash key t seen)
      (propertize key 'refbox-candidate candidate))))

(defun refbox-capf--state-candidates (state input)
  "Return bounded key candidates for INPUT using STATE."
  (setq input (substring-no-properties input))
  (unless (equal input (plist-get state :input))
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
                      (plist-get state :source-paths)))))))
  (plist-get state :candidates))

(defun refbox-capf--completion-table (state)
  "Return a CAPF completion table backed by bounded daemon search STATE."
  (lambda (string predicate action)
    (cond
     ((eq action 'metadata)
      '(metadata
        (category . refbox-reference)
        (annotation-function . refbox--completion-annotation)
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

(defun refbox-capf-at-bounds (bounds &optional source-paths)
  "Return CAPF data for BOUNDS using optional SOURCE-PATHS."
  (when bounds
    (list (car bounds)
          (cdr bounds)
          (refbox-capf--completion-table
           (refbox-capf--state refbox-capf-limit source-paths))
          :exclusive 'no)))

;;;###autoload
(defun refbox-completion-at-point ()
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
(defun refbox-setup-capf ()
  "Enable refbox completion at point in the current buffer."
  (interactive)
  (add-hook 'completion-at-point-functions
            #'refbox-completion-at-point
            nil
            t))

(defun refbox-reference-resources (candidate)
  "Return indexed resources for CANDIDATE via the daemon."
  (let ((key (refbox-reference-field candidate "key"))
        (source-path (refbox-reference-field candidate "source_path")))
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
             refbox-resource-file-parser-functions)))))

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

(defun refbox-resource--directory-list (dirs recursive)
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

(defun refbox-resource--library-dirs ()
  "Return configured library directories."
  (refbox-resource--directory-list
   refbox-resource-library-paths
   refbox-resource-library-paths-recursive))

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

(defun refbox-resource--files-for-keys (keys dirs extensions additional-sep)
  "Return files in DIRS associated with KEYS."
  (let ((keys (cl-remove-if #'string-empty-p
                            (mapcar (lambda (key)
                                      (format "%s" (or key "")))
                                    keys)))
        found)
    (when (and keys dirs)
      (if (and extensions (not additional-sep))
          (dolist (dir dirs)
            (dolist (key keys)
              (dolist (extension (refbox-resource--normalize-extensions extensions))
                (let ((file (expand-file-name (format "%s.%s" key extension) dir)))
                  (when (file-exists-p file)
                    (push file found))))))
        (dolist (dir dirs)
          (when (file-directory-p dir)
            (dolist (file (directory-files dir t directory-files-no-dot-files-regexp))
              (when (and (file-regular-p file)
                         (refbox-resource--extension-allowed-p file extensions))
                (let ((base (file-name-base file)))
                  (when (cl-some
                         (lambda (key)
                           (or (string= base key)
                               (and additional-sep
                                    (string-match-p
                                     (concat "\\`" (regexp-quote key)
                                             "\\(?:" additional-sep ".*\\)?\\'")
                                     base))))
                         keys)
                    (push file found)))))))))
    (nreverse (delete-dups found))))

(defun refbox-reference-files (candidate &optional resources)
  "Return existing file resources for CANDIDATE."
  (let* ((resources (or resources (refbox-reference-resources candidate)))
         (key (refbox-reference-field candidate "key"))
         (extensions refbox-resource-library-file-extensions)
         (field-files
          (cl-loop
           for resource in resources
           for kind = (refbox--resource-kind resource)
           for lookup = (refbox--resource-lookup-name resource)
           when (or (equal kind "file")
                    (and lookup
                         (member lookup refbox-resource-file-field-names)))
           append (refbox-resource--parse-file-field
                   (refbox--resource-value resource))))
         (source-dirs (refbox-resource--source-dirs candidate resources))
         (library-dirs (refbox-resource--library-dirs)))
    (delete-dups
     (append
      (refbox-resource--find-files-in-dirs
       field-files
       (append source-dirs library-dirs)
       extensions)
      (when key
        (refbox-resource--files-for-keys
         (list key)
         library-dirs
         extensions
         refbox-resource-additional-file-separator))))))

(defun refbox-resource-link-url (resource)
  "Return the URL represented by RESOURCE."
  (let* ((kind-name (refbox--resource-kind resource))
         (kind (and (not (refbox--blank-string-p kind-name))
                    (intern kind-name)))
         (template (alist-get kind refbox-resource-link-templates))
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
  (refbox-resource--directory-list refbox-note-paths nil))

(defun refbox-note-files (key)
  "Return existing note files for KEY."
  (refbox-resource--files-for-keys
   (list key)
   (refbox-note--directories)
   refbox-note-file-extensions
   refbox-resource-additional-file-separator))

(defun refbox-note--filename-key (key)
  "Return KEY transformed for a single file name."
  (replace-regexp-in-string "[/\\]" "_" key))

(defun refbox-note-filename (key)
  "Return the existing or default note filename for KEY."
  (when (refbox--blank-string-p key)
    (user-error "Reference candidate has no key"))
  (unless refbox-note-paths
    (user-error "`refbox-note-paths' must contain at least one directory"))
  (unless refbox-note-file-extensions
    (user-error "`refbox-note-file-extensions' must contain at least one extension"))
  (or (car (refbox-note-files key))
      (expand-file-name
       (format "%s.%s"
               (refbox-note--filename-key key)
               (string-remove-prefix "." (car refbox-note-file-extensions)))
       (car refbox-note-paths))))

(defun refbox-note-default-content (key candidate)
  "Return default note content for KEY and CANDIDATE."
  (let ((title (string-trim (refbox-reference-format-note candidate))))
    (if (string-empty-p title)
        (format "#+title: %s\n\n" key)
      (format "#+title: %s\n\n" title))))

(defun refbox--read-target (prompt targets)
  "Read one target from TARGETS using PROMPT."
  (cond
   ((null targets)
    (user-error "No resources found"))
   ((null (cdr targets))
    (car targets))
   (t
    (let ((table (make-hash-table :test 'equal)))
      (dolist (target targets)
        (puthash target target table))
      (gethash (completing-read prompt targets nil t) table)))))

(defun refbox--open-target (function target)
  "Open TARGET with FUNCTION and return TARGET."
  (funcall function target)
  target)

;;;###autoload
(defun refbox-open-files (&optional candidate)
  "Open a file resource for CANDIDATE."
  (interactive)
  (let* ((candidate (or candidate (refbox-read-reference)))
         (file (refbox--read-target
                "File: "
                (refbox-reference-files candidate))))
    (refbox--open-target refbox-resource-open-file-function file)))

;;;###autoload
(defun refbox-open-links (&optional candidate)
  "Open a link resource for CANDIDATE."
  (interactive)
  (let* ((candidate (or candidate (refbox-read-reference)))
         (link (refbox--read-target
                "Link: "
                (refbox-reference-links candidate))))
    (refbox--open-target refbox-resource-open-link-function link)))

;;;###autoload
(defun refbox-open-notes (&optional candidate)
  "Open an existing note for CANDIDATE."
  (interactive)
  (let* ((candidate (or candidate (refbox-read-reference)))
         (key (refbox-reference-field candidate "key")))
    (when (refbox--blank-string-p key)
      (user-error "Reference candidate has no key"))
    (let ((note (refbox--read-target "Note: " (refbox-note-files key))))
      (refbox--open-target refbox-note-open-function note))))

;;;###autoload
(defun refbox-create-note (&optional candidate)
  "Create or open the note for CANDIDATE."
  (interactive)
  (let* ((candidate (or candidate (refbox-read-reference)))
         (key (refbox-reference-field candidate "key"))
         (file (refbox-note-filename key))
         (exists (file-exists-p file)))
    (make-directory (file-name-directory file) t)
    (funcall refbox-note-open-function file)
    (unless exists
      (when-let* ((content-function refbox-note-content-function)
                  (content (funcall content-function key candidate)))
        (when (and (stringp content)
                   (not (string-empty-p content))
                   buffer-file-name
                   (equal (file-truename buffer-file-name)
                          (file-truename file)))
          (insert content))))
    file))

(defun refbox--resource-choice-label (type target)
  "Return display label for resource TYPE and TARGET."
  (format "%-5s %s" type target))

;;;###autoload
(defun refbox-open (&optional candidate)
  "Open a file, link, or note associated with CANDIDATE."
  (interactive)
  (let* ((candidate (or candidate (refbox-read-reference)))
         (key (refbox-reference-field candidate "key"))
         (resources (refbox-reference-resources candidate))
         (choices (append
                   (mapcar (lambda (file)
                             (list :type 'file :target file
                                   :label (refbox--resource-choice-label "file" file)))
                           (refbox-reference-files candidate resources))
                   (mapcar (lambda (link)
                             (list :type 'link :target link
                                   :label (refbox--resource-choice-label "link" link)))
                           (refbox-reference-links candidate resources))
                   (mapcar (lambda (note)
                             (list :type 'note :target note
                                   :label (refbox--resource-choice-label "note" note)))
                           (and key (refbox-note-files key))))))
    (unless choices
      (user-error "No resources found"))
    (let* ((table (make-hash-table :test 'equal))
           (labels (mapcar (lambda (choice)
                             (puthash (plist-get choice :label) choice table)
                             (plist-get choice :label))
                           choices))
           (choice (gethash
                    (if (cdr labels)
                        (completing-read "Resource: " labels nil t)
                      (car labels))
                    table))
           (target (plist-get choice :target)))
      (pcase (plist-get choice :type)
        ('file (refbox--open-target refbox-resource-open-file-function target))
        ('link (refbox--open-target refbox-resource-open-link-function target))
        ('note (refbox--open-target refbox-note-open-function target))))))

(defun refbox--reference-key (reference)
  "Return the key represented by REFERENCE."
  (cond
   ((stringp reference) reference)
   ((and (listp reference) (plist-member reference :key))
    (plist-get reference :key))
   (t (user-error "Reference has no key"))))

(defun refbox--reference-source-path (reference)
  "Return REFERENCE's source path, when available."
  (when (and (listp reference) (plist-member reference :source_path))
    (plist-get reference :source_path)))

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
        (move-to-column column)))
    location))

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

(defun refbox-current-buffer-citation-keys (&optional buffer)
  "Return unique citation keys in BUFFER."
  (with-current-buffer (or buffer (current-buffer))
    (cond
     ((derived-mode-p 'org-mode)
      (require 'refbox-org)
      (refbox-org-list-keys))
     ((or (derived-mode-p 'latex-mode)
          (derived-mode-p 'LaTeX-mode)
          (derived-mode-p 'tex-mode))
      (require 'refbox-latex)
      (refbox-latex-list-keys))
     ((derived-mode-p 'markdown-mode)
      (require 'refbox-markdown)
      (refbox-markdown-list-keys))
     (t
      (refbox--generic-citation-keys)))))

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
                   refbox-export-no-export-fields))
                keys)
        "\n\n"))
      (insert "\n"))
    file))

(defun refbox-csl--directories (dirs)
  "Return existing CSL DIRS."
  (refbox-resource--directory-list dirs nil))

(defun refbox-csl--readable-file-p (file)
  "Return non-nil when FILE is a readable regular file."
  (and (file-regular-p file)
       (file-readable-p file)))

(defun refbox-csl-style-files ()
  "Return configured CSL style files."
  (apply
   #'append
   (mapcar (lambda (dir)
             (cl-remove-if-not
              #'refbox-csl--readable-file-p
              (directory-files dir t "\\.csl\\'")))
           (refbox-csl--directories refbox-csl-style-directories))))

(defun refbox-csl-locale-files ()
  "Return configured CSL locale files."
  (apply
   #'append
   (mapcar (lambda (dir)
             (cl-remove-if-not
              #'refbox-csl--readable-file-p
              (directory-files dir t "\\.xml\\'")))
           (refbox-csl--directories refbox-csl-locale-directories))))

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

(defun refbox-csl-style-metadata (file)
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
      (equal (plist-get (ignore-errors (refbox-csl-style-metadata file)) :id)
             value)))

(defun refbox-csl--locale-match-p (file value)
  "Return non-nil when CSL locale FILE matches VALUE."
  (or (refbox-csl--name-match-p file value ".xml")
      (refbox-csl--name-match-p file (concat "locales-" value) ".xml")))

(defun refbox-csl--resolve-file (value files kind match-function)
  "Resolve VALUE against FILES for KIND using MATCH-FUNCTION."
  (cond
   ((refbox--blank-string-p value)
    (user-error "`refbox-csl-%s' is not configured" kind))
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

(defun refbox-csl-style-file ()
  "Return the selected CSL style file or signal an actionable error."
  (refbox-csl--resolve-file
   refbox-csl-style
   (refbox-csl-style-files)
   "style"
   #'refbox-csl--style-match-p))

(defun refbox-csl-locale-file ()
  "Return the selected CSL locale file or signal an actionable error."
  (refbox-csl--resolve-file
   refbox-csl-locale
   (refbox-csl-locale-files)
   "locale"
   #'refbox-csl--locale-match-p))

;;;###autoload
(defun refbox-select-csl-style ()
  "Select a CSL style from `refbox-csl-style-directories'."
  (interactive)
  (let ((metadata (mapcar #'refbox-csl-style-metadata
                          (refbox-csl-style-files))))
    (unless metadata
      (user-error "`refbox-csl-style-directories' contains no readable CSL styles"))
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
        (setq refbox-csl-style (plist-get item :file))
        (message "refbox CSL style: %s" (plist-get item :title))
        refbox-csl-style))))

(defun refbox-format-references (references)
  "Return formatted reference strings for REFERENCES."
  (let ((references (refbox--reference-list references)))
    (unless references
      (user-error "No references selected"))
    (if refbox-format-reference-function
        (funcall refbox-format-reference-function references)
      (let* ((style-path (refbox-csl-style-file))
             (locale-path (refbox-csl-locale-file))
             (response
              (refbox-rpc-request
               refbox-rpc-method-format-references
               (list :keys (mapcar #'refbox--reference-key references)
                     :style_path style-path
                     :locale_path locale-path))))
        (mapcar (lambda (item)
                  (plist-get item :text))
                (refbox--listify (plist-get response :references)))))))

;;;###autoload
(defun refbox-insert-reference (&optional references)
  "Insert formatted references for REFERENCES."
  (interactive)
  (insert (string-join (refbox-format-references references) "\n\n")))

;;;###autoload
(defun refbox-copy-reference (&optional references)
  "Copy formatted references for REFERENCES to the kill ring."
  (interactive)
  (let ((text (string-join (refbox-format-references references) "\n\n")))
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
  "Return the primary library directory, creating it if needed."
  (unless refbox-resource-library-paths
    (user-error "`refbox-resource-library-paths' must contain at least one directory"))
  (let ((directory (file-name-as-directory
                    (expand-file-name (car refbox-resource-library-paths)))))
    (make-directory directory t)
    directory))

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
  (when (and (file-exists-p destination) (not overwrite))
    (user-error "Library file already exists: %s" destination)))

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

;;;###autoload
(defun refbox-add-file-to-library (&optional reference)
  "Add a buffer, file, or URL resource to REFERENCE's library files."
  (interactive)
  (let* ((reference (or reference (refbox-read-reference)))
         (source (completing-read
                  "Add from: "
                  '("buffer" "file" "url")
                  nil t)))
    (pcase source
      ("buffer"
       (let* ((default (and buffer-file-name
                            (file-name-extension buffer-file-name)))
              (extension (read-string "Extension: " default)))
         (refbox-add-buffer-to-library reference extension)))
      ("file"
       (refbox-add-file-to-library-from-file
        reference
        (read-file-name "File: ")))
      ("url"
       (let ((url (read-string "URL: "))
             (extension (read-string "Extension: ")))
         (refbox-add-file-to-library-from-url reference url extension))))))

(defun refbox--completion-state (&optional limit)
  "Return fresh completion state using LIMIT."
  (list :limit (refbox-rpc--search-limit limit)
        :input nil
        :candidates nil
        :map (make-hash-table :test 'equal)))

(defun refbox--completion-candidate-display (candidate seen)
  "Return a propertized display string for CANDIDATE using SEEN map."
  (let* ((base (refbox-reference-format-main candidate))
         (display base)
         (source-path (refbox-reference-field candidate "source_path"))
         (counter 2))
    (when (gethash display seen)
      (setq display (format "%s  [%s]" base source-path)))
    (while (gethash display seen)
      (setq display (format "%s <%d>" base counter)
            counter (1+ counter)))
    (puthash display candidate seen)
    (propertize display 'refbox-candidate candidate)))

(defun refbox--completion-state-candidates (state input)
  "Return bounded completion candidates for INPUT using STATE."
  (setq input (substring-no-properties input))
  (unless (equal input (plist-get state :input))
    (let ((seen (plist-get state :map)))
      (clrhash seen)
      (setf (plist-get state :input) input)
      (setf (plist-get state :candidates)
            (mapcar (lambda (candidate)
                      (refbox--completion-candidate-display candidate seen))
                    (refbox-search-references
                     input
                     (plist-get state :limit))))))
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
  (let ((candidate (get-text-property 0 'refbox-candidate completion)))
    (when candidate
      (concat " " (refbox-reference-format-suffix candidate)))))

(defun refbox--completion-affixation (completions)
  "Return affixation triples for COMPLETIONS."
  (mapcar
   (lambda (completion)
     (let ((candidate (get-text-property 0 'refbox-candidate completion)))
       (list completion
             ""
             (if candidate
                 (concat " " (refbox-reference-format-suffix candidate))
               ""))))
   completions))

(defun refbox--read-reference (prompt preset limit allow-empty)
  "Read one reference with PROMPT, PRESET, LIMIT, and ALLOW-EMPTY."
  (let* ((state (refbox--completion-state limit))
         (selection (completing-read
                     prompt
                     (refbox--completion-table state)
                     nil
                     (not allow-empty)
                     preset
                     'refbox-reference-history))
         (selection-key (substring-no-properties selection)))
    (cond
     ((and allow-empty (string-empty-p selection-key)) nil)
     ((gethash selection-key (plist-get state :map)))
     ((get-text-property 0 'refbox-candidate selection))
     (t (user-error "Unknown refbox reference selection: %s" selection)))))

;;;###autoload
(defun refbox-read-reference (&optional prompt preset limit)
  "Read and return a single indexed reference candidate.

PRESET is inserted as the initial minibuffer search text.  LIMIT
bounds each daemon search request."
  (interactive)
  (let ((candidate (refbox--read-reference
                    (or prompt "Reference: ")
                    preset
                    limit
                    nil)))
    (when (called-interactively-p 'interactive)
      (message "refbox: %s" (refbox-reference-field candidate "key")))
    candidate))

;;;###autoload
(defun refbox-read-references (&optional prompt preset limit)
  "Read and return multiple indexed reference candidates.

Each selection performs a bounded daemon search for the current
minibuffer input.  An empty selection finishes the read."
  (interactive)
  (let ((prompt (or prompt "Reference (empty when done): "))
        (next-preset preset)
        selected
        candidate)
    (while (setq candidate
                 (refbox--read-reference prompt next-preset limit t))
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
  (let* ((response (refbox-rpc-request refbox-rpc-method-sync-full))
         (changed (plist-get response :changed_file_count))
         (removed (plist-get response :removed_file_count))
         (entries (plist-get response :indexed_entry_count)))
    (message "refbox sync: %s changed, %s removed, %s indexed entries"
             changed removed entries)
    response))

;;;###autoload
(defun refbox-sync-file (file)
  "Synchronize bibliography FILE."
  (interactive "fSync bibliography file: ")
  (let* ((path (expand-file-name file))
         (response (refbox-rpc-request refbox-rpc-method-sync-file
                                       (list :path path)))
         (changed (plist-get response :changed_file_count))
         (removed (plist-get response :removed_file_count))
         (entries (plist-get response :indexed_entry_count)))
    (message "refbox file sync: %s changed, %s removed, %s indexed entries"
             changed removed entries)
    response))

;;;###autoload
(defun refbox-sync-current-file ()
  "Synchronize the file visited by the current buffer."
  (interactive)
  (unless buffer-file-name
    (user-error "Current buffer is not visiting a file"))
  (refbox-sync-file buffer-file-name))

(provide 'refbox)

;;; refbox.el ends here
