;;; refbox-latex.el --- LaTeX citation integration for refbox -*- lexical-binding: t; -*-

;; Copyright (C) 2026 refbox contributors

;; Author: refbox contributors <maintainers@example.invalid>
;; Maintainer: refbox contributors <maintainers@example.invalid>
;; Version: 0.1.0
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
(require 'subr-x)
(require 'refbox)

(defgroup refbox-latex nil
  "LaTeX citation integration for refbox."
  :group 'refbox
  :prefix "refbox-latex-")

(defcustom refbox-latex-cite-commands
  '("cite" "Cite" "citet" "Citet" "citep" "Citep" "citealp" "citealt"
    "parencite" "Parencite" "footcite" "footcitetext" "textcite"
    "Textcite" "smartcite" "Smartcite" "autocite" "Autocite"
    "citeauthor" "Citeauthor" "citetitle" "citeyear" "citedate"
    "citeurl" "fullcite" "footfullcite" "notecite" "Notecite"
    "pnotecite" "Pnotecite" "fnotecite" "nocite" "supercite")
  "LaTeX citation commands recognized by refbox."
  :type '(repeat string)
  :group 'refbox-latex)

(defcustom refbox-latex-default-cite-command "cite"
  "Default LaTeX citation command inserted by refbox."
  :type 'string
  :group 'refbox-latex)

(defcustom refbox-latex-prompt-for-cite-style nil
  "When non-nil, prompt for the LaTeX citation command before insertion."
  :type 'boolean
  :group 'refbox-latex)

(defcustom refbox-latex-prompt-for-extra-arguments nil
  "When non-nil, prompt for optional citation command arguments."
  :type 'boolean
  :group 'refbox-latex)

(defcustom refbox-latex-default-optional-arguments nil
  "Optional arguments inserted when no prompt is requested."
  :type '(repeat string)
  :group 'refbox-latex)

(defcustom refbox-latex-key-separator ", "
  "Separator used between LaTeX citation keys."
  :type 'string
  :group 'refbox-latex)

(defvar refbox-latex-cite-command-history nil
  "Minibuffer history for LaTeX citation commands.")

(defun refbox-latex--command-regexp ()
  "Return a regexp matching configured LaTeX citation commands."
  (concat "\\\\\\(" (regexp-opt refbox-latex-cite-commands) "\\*?\\)"))

(defun refbox-latex--scan-braced-group (position)
  "Return bounds of braced group at POSITION, or nil."
  (save-excursion
    (goto-char position)
    (when (eq (char-after) ?{)
      (let ((depth 0)
            (start position)
            end)
        (while (and (not end) (not (eobp)))
          (let ((char (char-after)))
            (cond
             ((eq char ?{) (setq depth (1+ depth)))
             ((eq char ?})
              (setq depth (1- depth))
              (when (= depth 0)
                (setq end (1+ (point)))))))
          (forward-char 1))
        (when end (cons start end))))))

(defun refbox-latex--parse-optional-arguments ()
  "Parse optional arguments at point and return their strings."
  (let (arguments)
    (while (progn
             (skip-chars-forward " \t\n")
             (eq (char-after) ?\[))
      (let ((start (1+ (point))))
        (forward-char 1)
        (unless (search-forward "]" nil t)
          (user-error "Unclosed LaTeX citation optional argument"))
        (push (buffer-substring-no-properties start (1- (point)))
              arguments)))
    (nreverse arguments)))

(defun refbox-latex--parse-citation-at-match ()
  "Parse a citation command at current regexp match."
  (let ((begin (match-beginning 0))
        (command (match-string-no-properties 1)))
    (save-excursion
      (goto-char (match-end 0))
      (let* ((optional-args (refbox-latex--parse-optional-arguments))
             (group (progn
                      (skip-chars-forward " \t\n")
                      (refbox-latex--scan-braced-group (point)))))
        (when group
          (let* ((key-begin (1+ (car group)))
                 (key-end (1- (cdr group)))
                 (keys-text (buffer-substring-no-properties key-begin key-end))
                 (keys (mapcar #'string-trim
                               (split-string keys-text "," t "[ \t\n]+"))))
            (list :begin begin
                  :end (cdr group)
                  :command command
                  :optional-args optional-args
                  :key-begin key-begin
                  :key-end key-end
                  :keys keys)))))))

(defun refbox-latex-citation-at-point ()
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
                     (<= point (plist-get parsed :end)))
            (setq citation parsed))))
      citation)))

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

(defun refbox-latex-key-at-point ()
  "Return the LaTeX citation key at point, or nil."
  (when-let ((citation (refbox-latex-citation-at-point)))
    (let ((point (point)))
      (or (cl-loop
	   for (key begin end) in (refbox-latex--key-spans citation)
	   when (and (<= begin point) (<= point end))
	   return key)
          (car (plist-get citation :keys))))))

(defun refbox-latex-list-keys (&optional buffer)
  "Return unique LaTeX citation keys in BUFFER."
  (with-current-buffer (or buffer (current-buffer))
    (let ((regexp (refbox-latex--command-regexp))
          keys)
      (save-excursion
        (goto-char (point-min))
        (while (re-search-forward regexp nil t)
          (when-let ((citation (refbox-latex--parse-citation-at-match)))
            (setq keys (append keys (plist-get citation :keys))))))
      (delete-dups keys))))

(defun refbox-latex--completion-bounds ()
  "Return LaTeX citation key bounds for completion at point."
  (when-let ((citation (refbox-latex-citation-at-point)))
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
    (refbox-capf-at-bounds bounds (refbox-latex-local-bib-files))))

;;;###autoload
(defun refbox-latex-setup-capf ()
  "Enable refbox completion at point in the current LaTeX buffer."
  (interactive)
  (add-hook 'completion-at-point-functions
            #'refbox-latex-completion-at-point
            nil
            t))

(defun refbox-latex--read-command ()
  "Read or return the configured LaTeX citation command."
  (if refbox-latex-prompt-for-cite-style
      (completing-read
       "Citation command: "
       refbox-latex-cite-commands
       nil
       nil
       nil
       'refbox-latex-cite-command-history
       refbox-latex-default-cite-command)
    refbox-latex-default-cite-command))

(defun refbox-latex--read-optional-arguments ()
  "Read or return configured optional LaTeX citation arguments."
  (if refbox-latex-prompt-for-extra-arguments
      (let ((first (read-string "First optional argument: "))
            (second (read-string "Second optional argument: ")))
        (delq nil
              (list (unless (string-empty-p first) first)
                    (unless (string-empty-p second) second))))
    refbox-latex-default-optional-arguments))

(defun refbox-latex-format-citation (command keys &optional optional-args)
  "Return a LaTeX citation COMMAND for KEYS and OPTIONAL-ARGS."
  (concat "\\"
          command
          (mapconcat (lambda (arg) (format "[%s]" arg))
                     optional-args
                     "")
          "{"
          (string-join keys refbox-latex-key-separator)
          "}"))

(defun refbox-latex--selected-keys ()
  "Read selected reference keys for a LaTeX citation."
  (mapcar (lambda (candidate)
            (or (plist-get candidate :key)
                (user-error "refbox candidate has no key")))
          (refbox-read-references
           "References: "
           nil
           nil
           nil
           (refbox-latex-local-bib-files))))

(defun refbox-latex--new-keys (keys existing)
  "Return KEYS that are not already present in EXISTING."
  (cl-remove-if (lambda (key) (member key existing)) keys))

(defun refbox-latex--insert-keys-into-citation (citation keys)
  "Insert KEYS into existing LaTeX CITATION."
  (let* ((existing (plist-get citation :keys))
         (keys (refbox-latex--new-keys keys existing))
         (text (string-join keys refbox-latex-key-separator))
         (key-begin (plist-get citation :key-begin))
         (key-end (plist-get citation :key-end))
         (spans (refbox-latex--key-spans citation)))
    (when keys
      (cond
       ((null existing)
        (goto-char key-begin)
        (insert text))
       ((<= (point) key-begin)
        (goto-char key-begin)
        (insert text refbox-latex-key-separator))
       ((>= (point) key-end)
        (goto-char key-end)
        (insert refbox-latex-key-separator text))
       (t
        (goto-char
         (or (cl-loop
              for (_key begin end) in spans
              when (and (<= begin (point)) (<= (point) end))
              return end)
             key-end))
        (insert refbox-latex-key-separator text))))))

;;;###autoload
(defun refbox-latex-insert-citation (&optional _arg)
  "Insert a LaTeX citation at point.

When point is already in a citation command, add selected keys to
that citation instead of replacing it."
  (interactive)
  (let* ((citation (refbox-latex-citation-at-point))
         (keys (refbox-latex--selected-keys)))
    (unless keys
      (user-error "No references selected"))
    (if citation
        (refbox-latex--insert-keys-into-citation citation keys)
      (let* ((command (refbox-latex--read-command))
             (optional-args (refbox-latex--read-optional-arguments)))
        (insert (refbox-latex-format-citation
                 command keys optional-args))))))

;;;###autoload
(defun refbox-latex-insert-edit (&optional arg)
  "Insert or edit a LaTeX citation at point."
  (interactive "P")
  (refbox-latex-insert-citation arg))

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
              "\\\\\\(?:bibliography\\|addbibresource\\){\\([^}]+\\)}"
              nil t)
        (let ((raw (match-string-no-properties 1)))
          (dolist (part (split-string raw "," t "[ \t\n]+"))
            (push (expand-file-name
                   (refbox-latex--bib-file (string-trim part)))
                  files)))))
    (nreverse files)))

(defun refbox-latex--optional-bibliography-files ()
  "Return bibliography files from optional LaTeX helper variables."
  (let (files)
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
