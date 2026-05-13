;;; refbox-markdown.el --- Markdown citation integration for refbox -*- lexical-binding: t; -*-

;; Copyright (C) 2026 refbox contributors

;; Author: refbox contributors <maintainers@example.invalid>
;; Maintainer: refbox contributors <maintainers@example.invalid>
;; Version: 0.1.0
;; Package-Requires: ((emacs "29.1") (jsonrpc "1.0.27"))
;; Keywords: bib, markdown, convenience

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

;; Markdown support uses Pandoc-style citations by default:
;;
;;   [@key]
;;   [@key; @other]
;;   [see @key pp. 10-12]
;;
;; `refbox-markdown-insert-key' inserts a bare `@key'.  The citation command
;; inserts or replaces one bracketed citation at point.

;;; Code:

(require 'cl-lib)
(require 'subr-x)
(require 'refbox)

(defgroup refbox-markdown nil
  "Markdown citation integration for refbox."
  :group 'refbox
  :prefix "refbox-markdown-")

(defcustom refbox-markdown-prompt-for-affixes nil
  "When non-nil, prompt for citation prefix and suffix text."
  :type 'boolean
  :group 'refbox-markdown)

(defcustom refbox-markdown-default-prefix nil
  "Default text inserted before the first Markdown citation key."
  :type '(choice (const :tag "No prefix" nil) string)
  :group 'refbox-markdown)

(defcustom refbox-markdown-default-suffix nil
  "Default text inserted after the last Markdown citation key."
  :type '(choice (const :tag "No suffix" nil) string)
  :group 'refbox-markdown)

(defcustom refbox-markdown-key-separator "; "
  "Separator used between Markdown citation keys."
  :type 'string
  :group 'refbox-markdown)

(defconst refbox-markdown--key-regexp "-?@[[:alnum:]_:.#$%&+?<>~/=-]+")

(defun refbox-markdown--selected-keys ()
  "Read selected reference keys for Markdown."
  (mapcar (lambda (candidate)
            (or (plist-get candidate :key)
                (user-error "refbox candidate has no key")))
          (refbox-read-references "References: ")))

(defun refbox-markdown--selected-key ()
  "Read one reference key for Markdown."
  (or (plist-get (refbox-read-reference "Reference: ") :key)
      (user-error "refbox candidate has no key")))

(defun refbox-markdown--read-affixes ()
  "Read or return configured Markdown citation affixes."
  (if refbox-markdown-prompt-for-affixes
      (let ((prefix (read-string "Citation prefix: "))
            (suffix (read-string "Citation suffix: ")))
        (cons (unless (string-empty-p prefix) prefix)
              (unless (string-empty-p suffix) suffix)))
    (cons refbox-markdown-default-prefix refbox-markdown-default-suffix)))

(defun refbox-markdown-format-citation (keys &optional prefix suffix)
  "Return a Pandoc-style Markdown citation for KEYS, PREFIX, and SUFFIX."
  (let ((body (string-join (mapcar (lambda (key) (concat "@" key)) keys)
                           refbox-markdown-key-separator)))
    (concat "["
            (if (and prefix (not (string-empty-p (string-trim prefix))))
                (concat (string-trim prefix) " ")
              "")
            body
            (if (and suffix (not (string-empty-p (string-trim suffix))))
                (concat " " (string-trim suffix))
              "")
            "]")))

(defun refbox-markdown--new-keys (keys existing)
  "Return KEYS that are not already present in EXISTING."
  (cl-remove-if (lambda (key) (member key existing)) keys))

(defun refbox-markdown--key-spans (citation)
  "Return key spans for CITATION as (KEY BEGIN END) lists."
  (save-excursion
    (let ((end (plist-get citation :body-end))
          spans)
      (goto-char (plist-get citation :body-begin))
      (while (re-search-forward refbox-markdown--key-regexp end t)
        (push (list (string-remove-prefix
                     "@"
                     (string-remove-prefix
                      "-"
                      (match-string-no-properties 0)))
                    (match-beginning 0)
                    (match-end 0))
              spans))
      (nreverse spans))))

(defun refbox-markdown--insert-keys-into-citation (citation keys)
  "Insert KEYS into existing Markdown CITATION."
  (let* ((existing (plist-get citation :keys))
         (keys (refbox-markdown--new-keys keys existing))
         (text (mapconcat (lambda (key) (concat "@" key))
                          keys
                          refbox-markdown-key-separator))
         (body-begin (plist-get citation :body-begin))
         (body-end (plist-get citation :body-end))
         (spans (refbox-markdown--key-spans citation)))
    (when keys
      (cond
       ((null existing)
        (goto-char body-begin)
        (insert text))
       ((<= (point) body-begin)
        (goto-char body-begin)
        (insert text refbox-markdown-key-separator))
       ((>= (point) body-end)
        (goto-char body-end)
        (insert refbox-markdown-key-separator text))
       (t
        (goto-char
         (or (cl-loop
              for (_key begin end) in spans
              when (and (<= begin (point)) (<= (point) end))
              return end)
             body-end))
        (insert refbox-markdown-key-separator text))))))

(defun refbox-markdown-citation-at-point ()
  "Return Markdown citation metadata at point, or nil."
  (let ((point (point))
        citation)
    (save-excursion
      (goto-char (line-beginning-position))
      (while (and (not citation)
                  (search-forward "[" (line-end-position) t))
        (let ((begin (1- (point))))
          (when (search-forward "]" (line-end-position) t)
            (let* ((end (point))
                   (body-begin (1+ begin))
                   (body-end (1- end))
                   (body (buffer-substring-no-properties body-begin body-end)))
              (when (and (<= begin point)
                         (<= point end)
                         (string-match-p refbox-markdown--key-regexp body))
                (setq citation
                      (list :begin begin
                            :end end
                            :body-begin body-begin
                            :body-end body-end
                            :keys (refbox-markdown--keys-in-string body)))))))))
    citation))

(defun refbox-markdown--keys-in-string (string)
  "Return citation keys found in STRING without leading @ markers."
  (let ((position 0)
        keys)
    (while (string-match refbox-markdown--key-regexp string position)
      (push (string-remove-prefix
             "@"
             (string-remove-prefix "-" (match-string 0 string)))
            keys)
      (setq position (match-end 0)))
    (nreverse keys)))

(defun refbox-markdown-key-at-point ()
  "Return the Markdown citation key at point, or nil."
  (let ((point (point)))
    (save-excursion
      (goto-char (line-beginning-position))
      (catch 'key
        (while (re-search-forward refbox-markdown--key-regexp
                                  (line-end-position)
                                  t)
          (when (and (<= (match-beginning 0) point)
                     (<= point (match-end 0)))
            (throw 'key
                   (string-remove-prefix
                    "@"
                    (string-remove-prefix
                     "-"
                     (match-string-no-properties 0))))))
        nil))))

(defun refbox-markdown--completion-bounds ()
  "Return Markdown citation key bounds for completion at point."
  (if-let ((citation (refbox-markdown-citation-at-point)))
      (refbox-capf-key-bounds-after-at
       (plist-get citation :body-begin)
       (plist-get citation :body-end))
    (refbox-capf-key-bounds-after-at
     (line-beginning-position)
     (line-end-position))))

;;;###autoload
(defun refbox-markdown-completion-at-point ()
  "Return CAPF data for Markdown citation keys at point."
  (refbox-capf-at-bounds (refbox-markdown--completion-bounds)))

;;;###autoload
(defun refbox-markdown-setup-capf ()
  "Enable refbox completion at point in the current Markdown buffer."
  (interactive)
  (add-hook 'completion-at-point-functions
            #'refbox-markdown-completion-at-point
            nil
            t))

;;;###autoload
(defun refbox-markdown-insert-key ()
  "Insert a bare Pandoc Markdown citation key at point."
  (interactive)
  (insert "@" (refbox-markdown--selected-key)))

;;;###autoload
(defun refbox-markdown-insert-keys (keys)
  "Insert KEYS as bare Pandoc Markdown citation keys."
  (insert (mapconcat (lambda (key) (concat "@" key)) keys "; ")))

;;;###autoload
(defun refbox-markdown-insert-citation (&optional _arg)
  "Insert a bracketed Pandoc Markdown citation at point.

When point is already in a citation, add selected keys to that
citation instead of replacing it."
  (interactive)
  (let* ((citation (refbox-markdown-citation-at-point))
         (keys (refbox-markdown--selected-keys)))
    (unless keys
      (user-error "No references selected"))
    (if citation
        (refbox-markdown--insert-keys-into-citation citation keys)
      (let* ((affixes (refbox-markdown--read-affixes)))
        (insert (refbox-markdown-format-citation
                 keys
                 (car affixes)
                 (cdr affixes)))))))

;;;###autoload
(defun refbox-markdown-list-keys (&optional buffer)
  "Return unique Markdown citation keys in BUFFER."
  (with-current-buffer (or buffer (current-buffer))
    (let (keys)
      (save-excursion
        (goto-char (point-min))
        (while (re-search-forward refbox-markdown--key-regexp nil t)
          (push (string-remove-prefix
                 "@"
                 (string-remove-prefix "-" (match-string-no-properties 0)))
                keys)))
      (delete-dups (nreverse keys)))))

(provide 'refbox-markdown)

;;; refbox-markdown.el ends here
