;;; refbox-latex.el --- LaTeX citation integration for refbox -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Ayan Das

;; Author: Ayan Das <bvits@riseup.net>
;; Maintainer: Ayan Das <bvits@riseup.net>
;; Version: 0.5.0
;; Package-Requires: ((emacs "29.1") (jsonrpc "1.0.27"))
;; Keywords: bib, tex, convenience

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

;; LaTeX citation commands for refbox.  This file has no hard dependency on
;; AUCTeX or RefTeX; local discovery reads their buffer-local variables only
;; when those variables are already present.

;;; Code:

(require 'cl-lib)
(require 'seq)
(require 'subr-x)
(require 'refbox)

(declare-function reftex-all-used-citation-keys "reftex-cite" ())

(defgroup refbox-latex nil
  "LaTeX citation integration for refbox."
  :group 'refbox
  :prefix "refbox-latex-")

(defcustom refbox-latex-cite-commands
  '((("cite" "Cite" "citet" "Citet" "citep" "Citep" "parencite"
      "Parencite" "footcite" "footcitetext" "textcite" "Textcite"
      "smartcite" "Smartcite" "cite*" "parencite*" "autocite"
      "Autocite" "autocite*" "Autocite*" "citeauthor" "Citeauthor"
      "citeauthor*" "Citeauthor*" "citetitle" "citetitle*" "citeyear"
      "citeyear*" "citedate" "citedate*" "citeurl" "fullcite"
      "footfullcite" "notecite" "Notecite" "pnotecite" "Pnotecite"
      "fnotecite")
     . (["Prenote"] ["Postnote"] t))
    (("nocite" "supercite") . nil))
  "LaTeX citation commands recognized by refbox.

Each alist key is a list of command names.  The value describes the
command argument prompts; vector entries are prompted as optional
arguments and `t' marks the citation-key argument."
  :type '(alist :key-type (repeat string)
                :value-type sexp)
  :group 'refbox-latex)

(defcustom refbox-latex-default-cite-command "cite"
  "Default LaTeX citation command inserted by refbox."
  :type 'string
  :group 'refbox-latex)

(defcustom refbox-latex-prompt-for-cite-style t
  "When non-nil, prompt for the LaTeX citation command before insertion."
  :type 'boolean
  :group 'refbox-latex)

(defcustom refbox-latex-prompt-for-extra-arguments t
  "When non-nil, prompt for optional citation command arguments."
  :type 'boolean
  :group 'refbox-latex)

(defvar refbox-latex-cite-command-history nil
  "Minibuffer history for LaTeX citation commands.")

(defun refbox-latex--command-names ()
  "Return configured LaTeX citation command names."
  (seq-mapcat #'car refbox-latex-cite-commands))

(defun refbox-latex--command-entry (command)
  "Return configured citation command entry for COMMAND."
  (seq-find (lambda (entry)
              (member command (car entry)))
            refbox-latex-cite-commands))

(defun refbox-latex--command-regexp ()
  "Return a regexp matching configured LaTeX citation commands."
  (concat "\\\\\\(" (regexp-opt (refbox-latex--command-names)) "\\)"))

(defun refbox-latex--scan-braced-group (position)
  "Return bounds of braced group at POSITION, or nil.

Escaped braces are literal content and do not affect group balance."
  (save-excursion
    (goto-char position)
    (when (eq (char-after) ?{)
      (let ((depth 0)
            (start position)
            end
            escaped)
        (while (and (not end) (not (eobp)))
          (let ((char (char-after)))
            (cond
             (escaped
              (setq escaped nil))
             ((eq char ?\\)
              (setq escaped t))
             ((eq char ?{)
              (setq depth (1+ depth)))
             ((eq char ?})
              (setq depth (1- depth))
              (when (= depth 0)
                (setq end (1+ (point)))))))
          (forward-char 1))
        (when end (cons start end))))))

(defun refbox-latex--scan-optional-group (position)
  "Return bounds of optional group at POSITION, or nil.

Escaped brackets are literal content.  Braces protect bracket content
inside optional arguments, matching ordinary LaTeX argument structure."
  (save-excursion
    (goto-char position)
    (when (eq (char-after) ?\[)
      (let ((bracket-depth 0)
            (brace-depth 0)
            (start position)
            end
            escaped)
        (while (and (not end) (not (eobp)))
          (let ((char (char-after)))
            (cond
             (escaped
              (setq escaped nil))
             ((eq char ?\\)
              (setq escaped t))
             ((eq char ?{)
              (setq brace-depth (1+ brace-depth)))
             ((and (eq char ?}) (> brace-depth 0))
              (setq brace-depth (1- brace-depth)))
             ((and (= brace-depth 0) (eq char ?\[))
              (setq bracket-depth (1+ bracket-depth)))
             ((and (= brace-depth 0) (eq char ?\]))
              (setq bracket-depth (1- bracket-depth))
              (when (= bracket-depth 0)
                (setq end (1+ (point)))))))
          (forward-char 1))
        (when end (cons start end))))))

(defun refbox-latex--parse-optional-argument ()
  "Parse one optional argument at point and return its string."
  (skip-chars-forward " \t\n")
  (when (eq (char-after) ?\[)
    (if-let ((group (refbox-latex--scan-optional-group (point))))
        (prog1
            (buffer-substring-no-properties (1+ (car group))
                                            (1- (cdr group)))
          (goto-char (cdr group)))
      (user-error "Unclosed LaTeX citation optional argument"))))

(defun refbox-latex--parse-braced-argument ()
  "Parse one braced argument at point and return its bounds."
  (skip-chars-forward " \t\n")
  (when (eq (char-after) ?{)
    (if-let ((group (refbox-latex--scan-braced-group (point))))
        (prog1 group
          (goto-char (cdr group)))
      (user-error "Unclosed LaTeX citation argument"))))

(defun refbox-latex--keys-in-braced-group (group)
  "Return citation keys from braced GROUP bounds."
  (let ((text (buffer-substring-no-properties (1+ (car group))
                                              (1- (cdr group)))))
    (mapcar #'string-trim
            (split-string text "," t "[ \t\n]+"))))

(defun refbox-latex--parse-citation-arguments (specs)
  "Parse citation arguments at point according to SPECS.

Return a plist with `:optional-args', `:key-group', and `:end', or nil
when the configured key argument is absent."
  (let (optional-args key-group end optional)
    (catch 'invalid
      (dolist (spec specs)
        (cond
         ((vectorp spec)
          (when-let ((argument (refbox-latex--parse-optional-argument)))
            (push argument optional-args)
            (setq end (point))))
         ((stringp spec)
          (if-let ((group (refbox-latex--parse-braced-argument)))
              (setq end (cdr group))
            (throw 'invalid nil)))
         ((eq spec t)
          (if-let ((group (refbox-latex--parse-braced-argument)))
              (setq key-group group
                    end (cdr group))
            (throw 'invalid nil)))))
      (unless key-group
        (unless specs
          (while (setq optional (refbox-latex--parse-optional-argument))
            (push optional optional-args)
            (setq end (point))))
        (if-let ((group (refbox-latex--parse-braced-argument)))
            (setq key-group group
                  end (cdr group))
          (throw 'invalid nil)))
      (list :optional-args (nreverse optional-args)
            :key-group key-group
            :end end))))

(defun refbox-latex--parse-citation-at-match ()
  "Parse a citation command at current regexp match."
  (let ((begin (match-beginning 0))
        (command (match-string-no-properties 1)))
    (save-excursion
      (goto-char (match-end 0))
      (when-let ((parsed (refbox-latex--parse-citation-arguments
                          (cdr (refbox-latex--command-entry command)))))
        (let ((group (plist-get parsed :key-group)))
          (let* ((key-begin (1+ (car group)))
                 (key-end (1- (cdr group)))
                 (keys (refbox-latex--keys-in-braced-group group)))
            (list :begin begin
                  :end (plist-get parsed :end)
                  :command command
                  :optional-args (plist-get parsed :optional-args)
                  :key-begin key-begin
                  :key-end key-end
                  :keys keys)))))))

(defun refbox-latex--citation-at-point ()
  "Return LaTeX citation metadata at point, or nil."
  (save-excursion
    (let ((point (point))
          (start (save-excursion (backward-paragraph) (point)))
          (finish (save-excursion (forward-paragraph) (point)))
          (regexp (refbox-latex--command-regexp))
          citation)
      (goto-char start)
      (while (and (not citation)
                  (re-search-forward regexp finish t))
        (let ((parsed (refbox-latex--parse-citation-at-match)))
          (when (and parsed
                     (<= (plist-get parsed :begin) point)
                     (< point (plist-get parsed :end)))
            (setq citation parsed))))
      citation)))

;;;###autoload
(defun refbox-latex-citation-at-point ()
  "Return LaTeX citation keys at point with their bounds."
  (when-let ((citation (refbox-latex--citation-at-point)))
    (cons (plist-get citation :keys)
          (cons (plist-get citation :begin)
                (plist-get citation :end)))))

(defun refbox-latex--key-spans (citation)
  "Return key spans for CITATION as (KEY BEGIN END) lists."
  (save-excursion
    (let ((end (plist-get citation :key-end))
          spans)
      (goto-char (plist-get citation :key-begin))
      (while (< (point) end)
        (skip-chars-forward " \t\n," end)
        (let ((begin (point)))
          (skip-chars-forward "^,\n\t " end)
          (when (> (point) begin)
            (push (list (buffer-substring-no-properties begin (point))
                        begin
                        (point))
                  spans))))
      (nreverse spans))))

(defun refbox-latex--key-and-bounds-at-point ()
  "Return the LaTeX citation key and bounds at point, or nil."
  (when-let ((citation (refbox-latex--citation-at-point)))
    (let ((point (point)))
      (cl-loop
       for (key begin end) in (refbox-latex--key-spans citation)
       when (and (<= begin point) (<= point end))
       return (cons key (cons begin end))))))

;;;###autoload
(defun refbox-latex-key-at-point ()
  "Return the LaTeX citation key at point with its bounds."
  (refbox-latex--key-and-bounds-at-point))

;;;###autoload
(defun refbox-latex-list-keys (&optional buffer)
  "Return unique LaTeX citation keys in BUFFER."
  (with-current-buffer (or buffer (current-buffer))
    (if (fboundp 'reftex-all-used-citation-keys)
        (copy-sequence (reftex-all-used-citation-keys))
      (let ((regexp (refbox-latex--command-regexp))
            keys)
        (save-excursion
          (goto-char (point-min))
          (while (re-search-forward regexp nil t)
            (when-let ((citation (refbox-latex--parse-citation-at-match)))
              (setq keys (append keys (plist-get citation :keys))))))
        (delete-dups keys)))))

(defun refbox-latex--completion-bounds ()
  "Return LaTeX citation key bounds for completion at point."
  (when-let ((citation (refbox-latex--citation-at-point)))
    (let ((bounds (refbox-capf-key-bounds
                   (plist-get citation :key-begin)
                   (plist-get citation :key-end))))
      (when (and bounds
                 (<= (plist-get citation :key-begin) (car bounds))
                 (<= (cdr bounds) (plist-get citation :key-end)))
        bounds))))

;;;###autoload
(defun refbox-latex-completion-at-point ()
  "Return CAPF data for LaTeX citation keys at point."
  (when-let ((bounds (refbox-latex--completion-bounds)))
    (refbox-capf-at-bounds bounds (refbox-latex-local-bib-files) t)))

;;;###autoload
(defun refbox-latex-setup-capf ()
  "Enable refbox completion at point in the current LaTeX buffer."
  (interactive)
  (add-hook 'completion-at-point-functions
            #'refbox-latex-completion-at-point
            nil
            t))

(defun refbox-latex--read-command (&optional invert-prompt command)
  "Read or return the configured LaTeX citation command.

COMMAND, when non-nil, is returned directly.  INVERT-PROMPT reverses
`refbox-latex-prompt-for-cite-style'."
  (or command
      (if (if invert-prompt
              (not refbox-latex-prompt-for-cite-style)
            refbox-latex-prompt-for-cite-style)
          (completing-read
           "Cite command: "
           (refbox-latex--command-names)
           nil
           nil
           nil
           'refbox-latex-cite-command-history
           refbox-latex-default-cite-command)
        refbox-latex-default-cite-command)))

(defun refbox-latex--argument-prompt (spec fallback)
  "Return prompt text for argument SPEC, falling back to FALLBACK."
  (cond
   ((vectorp spec) (or (aref spec 0) fallback))
   ((stringp spec) spec)
   (t fallback)))

(defun refbox-latex--read-arguments (command)
  "Read or return configured LaTeX arguments for COMMAND."
  (let ((specs (cdr (refbox-latex--command-entry command))))
    (if refbox-latex-prompt-for-extra-arguments
        (cl-loop for spec in specs
                 when (vectorp spec)
                 collect
                 (let ((value (read-string
                               (format "%s: "
                                       (refbox-latex--argument-prompt
                                        spec "Optional argument")))))
                   (list :optional
                         (unless (string-empty-p value) value)))
                 when (stringp spec)
                 collect
                 (list :mandatory
                       (read-string
                        (format "%s: "
                                (refbox-latex--argument-prompt
                                 spec "Mandatory argument")))))
      (cl-loop for spec in specs
               when (vectorp spec)
               collect (list :optional nil)))))

(defun refbox-latex-format-citation (command keys &optional optional-args)
  "Return a LaTeX citation COMMAND for KEYS and OPTIONAL-ARGS."
  (concat "\\"
          command
          (mapconcat (lambda (arg) (format "[%s]" arg))
                     optional-args
                     "")
          "{"
          (string-join keys ",")
          "}"))

(defun refbox-latex--key-argument (keys)
  "Return KEYS formatted as a LaTeX mandatory citation argument."
  (concat "{" (string-join keys ",") "}"))

(defun refbox-latex--spec-argument-items (specs arguments)
  "Return SPECS paired with their consumed ARGUMENTS."
  (let ((arguments (copy-sequence arguments)))
    (mapcar
     (lambda (spec)
       (list spec
             (when (or (vectorp spec) (stringp spec))
               (pop arguments))))
     specs)))

(defun refbox-latex--later-optional-value-p (items)
  "Return non-nil when later consecutive optional ITEMS have a value."
  (cl-loop for (spec argument) in (cdr items)
           while (vectorp spec)
           thereis (pcase argument
                     (`(:optional ,value) value))))

(defun refbox-latex--format-citation-from-spec
    (command keys &optional optional-args)
  "Return citation COMMAND for KEYS following its configured argument spec.

Vector specs consume optional argument records and emit bracketed
optional arguments.
String specs consume mandatory argument records and emit braced arguments.
A `t' spec marks where the citation-key argument belongs.  When no `t'
is configured, append the key argument after configured optional args."
  (let ((items (refbox-latex--spec-argument-items
                (cdr (refbox-latex--command-entry command))
                optional-args))
        key-inserted)
    (concat
     "\\"
     command
     (mapconcat
      (lambda (items)
        (pcase-let ((`(,spec ,argument) (car items)))
          (cond
           ((vectorp spec)
            (pcase argument
              (`(:optional ,value)
               (if value
                   (format "[%s]" value)
                 (if (refbox-latex--later-optional-value-p items)
                     "[]"
                   "")))
              (_
               (if (refbox-latex--later-optional-value-p items)
                   "[]"
                 ""))))
           ((stringp spec)
            (pcase argument
              (`(:mandatory ,value)
               (format "{%s}" (or value "")))
              (_ "")))
           ((eq spec t)
            (setq key-inserted t)
            (refbox-latex--key-argument keys))
           (t ""))))
      (cl-loop for tail on items collect tail)
      "")
     (unless key-inserted
       (refbox-latex--key-argument keys)))))

(defun refbox-latex--selected-keys ()
  "Read selected reference keys for a LaTeX citation."
  (mapcar #'refbox--reference-key
          (refbox-read-references
           "References: "
           nil
           nil
           nil
           (refbox-latex-local-bib-files)
           t
           t)))

(defun refbox-latex--insert-keys-into-citation (citation keys)
  "Insert KEYS into existing LaTeX CITATION."
  (let ((text (string-join keys ","))
        (end (plist-get citation :end)))
    (when keys
      (pcase (progn
               (skip-chars-forward "^,{}" end)
               (following-char))
        ((guard (= (point) end))
         (insert "{}")
         (backward-char))
        ((or ?{ ?,)
         (forward-char)
         (unless (looking-at-p "[[:space:]]*[},]")
           (insert ",")
           (backward-char)))
        (?}
         (skip-chars-backward "[:space:]")
         (unless (member (preceding-char) '(?{ ?,))
           (insert ","))))
      (insert text))))

(defun refbox-latex--move-after-citation ()
  "Move point after the LaTeX citation command containing point."
  (when-let ((citation (refbox-latex--citation-at-point)))
    (goto-char (plist-get citation :end))))

;;;###autoload
(defun refbox-latex-insert-citation (keys &optional invert-prompt command)
  "Insert a LaTeX citation at point.

When point is already in a citation command, add selected keys to
that citation instead of replacing it.  INVERT-PROMPT reverses
`refbox-latex-prompt-for-cite-style'.  COMMAND, when non-nil, selects
the citation command directly."
  (when keys
    (let ((citation (refbox-latex--citation-at-point)))
      (if citation
          (refbox-latex--insert-keys-into-citation citation keys)
        (let* ((command (refbox-latex--read-command invert-prompt command))
               (optional-args (refbox-latex--read-arguments command)))
          (insert (refbox-latex--format-citation-from-spec
                   command keys optional-args))))
      (refbox-latex--move-after-citation))))

;;;###autoload
(defun refbox-latex-insert-edit (&optional _arg)
  "Insert or edit a LaTeX citation at point."
  (interactive "P")
  (refbox-latex-insert-citation (refbox-latex--selected-keys)))

(defun refbox-latex--bib-file (path)
  "Return PATH with a .bib extension when it has no extension."
  (if (file-name-extension path)
      path
    (concat path ".bib")))

(defun refbox-latex--parse-bibliography-commands ()
  "Return bibliography files declared in the current LaTeX buffer."
  (let (files)
    (save-excursion
      (goto-char (point-min))
      (while (re-search-forward
              "\\\\\\(?:bibliography\\|addbibresource\\)"
              nil t)
        (let ((command-end (point)))
          (skip-chars-forward " \t\n")
          (while (eq (char-after) ?\[)
            (if-let ((group (refbox-latex--scan-optional-group (point))))
                (progn
                  (goto-char (cdr group))
                  (skip-chars-forward " \t\n"))
              (setq command-end nil)
              (unless (eobp)
                (forward-char 1))))
          (when command-end
            (when-let ((group (refbox-latex--scan-braced-group (point))))
              (let ((raw (buffer-substring-no-properties
                          (1+ (car group))
                          (1- (cdr group)))))
                (dolist (part (split-string raw "," t "[ \t\n]+"))
                  (push (expand-file-name
                         (refbox-latex--bib-file (string-trim part)))
                        files)))
              (goto-char (cdr group)))))))
    (nreverse files)))

(defun refbox-latex--optional-bibliography-files ()
  "Return bibliography files from optional LaTeX helper variables."
  (let (files)
    (when (fboundp 'reftex-get-bibfile-list)
      (dolist (file (ignore-errors (reftex-get-bibfile-list)))
        (setq files
              (append files
                      (list (expand-file-name
                             (refbox-latex--bib-file file)))))))
    (when (boundp 'reftex-default-bibliography)
      (dolist (file (symbol-value 'reftex-default-bibliography))
        (setq files (append files (list (expand-file-name file))))))
    (when (boundp 'LaTeX-bibliography-list)
      (dolist (file (symbol-value 'LaTeX-bibliography-list))
        (setq files
              (append files
                      (list (expand-file-name
                             (refbox-latex--bib-file file)))))))
    (when (and (boundp 'TeX-master)
               (stringp (symbol-value 'TeX-master)))
      (let ((master (expand-file-name (symbol-value 'TeX-master))))
        (when (file-readable-p master)
          (with-temp-buffer
            (insert-file-contents master)
            (let ((default-directory (file-name-directory master)))
              (setq files
                    (append files
                            (refbox-latex--parse-bibliography-commands))))))))
    files))

;;;###autoload
(defun refbox-latex-local-bib-files (&optional buffer)
  "Return bibliography files declared for LaTeX BUFFER."
  (with-current-buffer (or buffer (current-buffer))
    (delete-dups
     (append (refbox-latex--parse-bibliography-commands)
             (refbox-latex--optional-bibliography-files)))))

(provide 'refbox-latex)

;;; refbox-latex.el ends here
