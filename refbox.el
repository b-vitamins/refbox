;;; refbox.el --- Local-first bibliography tools -*- lexical-binding: t; -*-

;; Copyright (C) 2026 refbox contributors

;; Author: refbox contributors <maintainers@example.invalid>
;; Maintainer: refbox contributors <maintainers@example.invalid>
;; Version: 0.0.0
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

(require 'cl-lib)
(require 'subr-x)
(require 'refbox-rpc)

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
          (when (refbox-reference-has-any-field-p
                 candidate refbox-reference-resource-field-names)
            refbox-reference-resource-indicator)
          (when (refbox-reference-has-any-field-p
                 candidate refbox-reference-link-field-names)
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

(defun refbox-search-references (query &optional limit)
  "Search indexed references for QUERY using bounded LIMIT."
  (let* ((response (refbox-rpc-request
                    refbox-rpc-method-search-entries
                    (list :query (or query "")
                          :limit (refbox-rpc--search-limit limit))))
         (entries (plist-get response :entries)))
    (refbox--listify entries)))

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
