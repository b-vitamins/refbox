;;; refbox-org.el --- Org citation integration for refbox -*- lexical-binding: t; -*-

;; Copyright (C) 2026 refbox contributors

;; Author: refbox contributors <maintainers@example.invalid>
;; Maintainer: refbox contributors <maintainers@example.invalid>
;; Version: 0.0.0
;; Package-Requires: ((emacs "29.1") (org "9.8") (jsonrpc "1.0.27"))
;; Keywords: bib, tex, org, convenience

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

;; Org-specific citation commands for refbox.  The base `refbox' feature does
;; not load this file; Org integration is available by requiring `refbox-org' or
;; invoking its autoloaded commands.

;;; Code:

(require 'cl-lib)
(require 'oc)
(require 'org)
(require 'subr-x)
(require 'refbox)

(declare-function org-element-begin "org-element" (element))
(declare-function org-element-end "org-element" (element))
(declare-function org-element-contents-begin "org-element" (element))
(declare-function org-element-contents-end "org-element" (element))
(declare-function org-element-map "org-element"
                  (data types fun &optional info first-match no-recursion with-affiliated))
(declare-function org-element-parse-buffer "org-element" (&optional granularity visible-only))
(declare-function org-element-property "org-element" (property element))

(defgroup refbox-org nil
  "Org citation integration for refbox."
  :group 'refbox
  :prefix "refbox-org-")

(defcustom refbox-org-default-style nil
  "Default Org citation style inserted when a style is requested."
  :type '(choice (const :tag "No explicit style" nil) string)
  :group 'refbox-org)

(defcustom refbox-org-citation-styles
  '("author" "text" "nocite" "noauthor")
  "Citation styles offered by `refbox-org--select-style'."
  :type '(repeat string)
  :group 'refbox-org)

(defcustom refbox-org-follow-action #'refbox-org-open-source
  "Function called by `refbox-org-follow-at-point'.

The function receives three arguments: the citation key, the Org
datum at point, and the raw prefix argument."
  :type 'function
  :group 'refbox-org)

(defvar refbox-org-style-history nil
  "Minibuffer history for Org citation styles.")

(defvar refbox-org-citation-map
  (let ((map (make-sparse-keymap)))
    (define-key map (kbd "d") #'refbox-org-delete-at-point)
    (define-key map (kbd "k") #'refbox-org-kill-at-point)
    (define-key map (kbd "S-<left>") #'refbox-org-shift-reference-left)
    (define-key map (kbd "S-<right>") #'refbox-org-shift-reference-right)
    (define-key map (kbd "p") #'refbox-org-set-reference-prefix)
    (define-key map (kbd "s") #'refbox-org-set-reference-suffix)
    map)
  "Keymap installed by `refbox-org-activate'.")

(defun refbox-org--candidate-key (candidate)
  "Return the citation key from CANDIDATE."
  (or (plist-get candidate :key)
      (user-error "refbox candidate has no key")))

(defun refbox-org--select-keys (multiple)
  "Select one or more citation keys.

When MULTIPLE is non-nil, return a list of keys.  Otherwise return
a single key."
  (if multiple
      (mapcar #'refbox-org--candidate-key
              (refbox-read-references "References: "))
    (refbox-org--candidate-key
     (refbox-read-reference "Reference: "))))

(defun refbox-org--select-style (_citation)
  "Read an Org citation style."
  (let ((style (completing-read
                "Citation style: "
                refbox-org-citation-styles
                nil
                nil
                nil
                'refbox-org-style-history
                refbox-org-default-style)))
    (unless (string-empty-p style)
      style)))

(defun refbox-org--insert-processor ()
  "Return the refbox Org citation insert processor."
  (org-cite-make-insert-processor
   #'refbox-org--select-keys
   #'refbox-org--select-style))

;;;###autoload
(defun refbox-org-register-processor ()
  "Register the refbox Org citation processor for Org's native dispatcher."
  (interactive)
  (org-cite-register-processor
   'refbox
   :insert (refbox-org--insert-processor)
   :follow #'refbox-org--processor-follow
   :activate #'refbox-org-activate))

;;;###autoload
(defun refbox-org-insert-citation (&optional arg)
  "Insert or edit an Org citation at point.

ARG follows Org's citation insertion convention: when point is on a
citation or citation reference, a non-nil ARG deletes it; away from a
citation, a non-nil ARG requests an explicit citation style."
  (interactive "P")
  (let ((context (org-element-context))
        (insert (refbox-org--insert-processor)))
    (cond
     ((org-element-type-p context '(citation citation-reference))
      (funcall insert context arg))
     ((org-cite--allowed-p context)
      (funcall insert nil arg))
     (t
      (user-error "Cannot insert an Org citation here")))))

(defun refbox-org-reference-at-point (&optional datum)
  "Return the Org citation reference at point or in DATUM."
  (let ((context (or datum (org-element-context))))
    (pcase (org-element-type context)
      ('citation-reference context)
      ('citation
       (let ((references (org-cite-get-references context)))
         (or (cl-find-if
              (lambda (reference)
                (and (>= (point) (org-element-begin reference))
                     (<= (point) (org-element-end reference))))
              references)
             (car references))))
      (_ nil))))

(defun refbox-org-citation-at-point (&optional datum)
  "Return the Org citation at point or in DATUM."
  (let ((context (or datum (org-element-context))))
    (pcase (org-element-type context)
      ('citation context)
      ('citation-reference (org-element-parent context))
      (_ nil))))

(defun refbox-org-key-at-point (&optional datum)
  "Return the Org citation key at point or in DATUM."
  (let ((reference (refbox-org-reference-at-point datum)))
    (when reference
      (org-element-property :key reference))))

(defun refbox-org--reference-or-error ()
  "Return the citation reference at point or signal a user error."
  (or (refbox-org-reference-at-point)
      (user-error "Point is not on an Org citation reference")))

(defun refbox-org--citation-or-error ()
  "Return the citation at point or signal a user error."
  (or (refbox-org-citation-at-point)
      (user-error "Point is not on an Org citation")))

(defun refbox-org--cleanup-citation-spacing-at-point ()
  "Remove incidental leading space before the first reference at point."
  (save-excursion
    (let ((end (line-end-position)))
      (goto-char (line-beginning-position))
      (while (re-search-forward "\\(\\[cite[^]\n]*:\\)[ \t]+@" end t)
        (replace-match "\\1@" nil nil)))))

(defun refbox-org--normalize-prefix (prefix)
  "Normalize citation reference PREFIX for insertion."
  (let ((prefix (string-trim (or prefix ""))))
    (if (string-empty-p prefix) "" (concat prefix " "))))

(defun refbox-org--normalize-suffix (suffix)
  "Normalize citation reference SUFFIX for insertion."
  (let ((suffix (string-trim (or suffix ""))))
    (if (string-empty-p suffix) "" (concat " " suffix))))

(defun refbox-org--set-reference-affix (reference side text)
  "Set REFERENCE affix SIDE to TEXT.

SIDE is either `prefix' or `suffix'."
  (pcase-let* ((`(,key-begin . ,key-end) (org-cite-key-boundaries reference))
               (begin (org-element-begin reference))
               (end (org-element-end reference)))
    (pcase side
      ('prefix
       (delete-region begin key-begin)
       (goto-char begin)
       (insert (refbox-org--normalize-prefix text)))
      ('suffix
       (delete-region key-end end)
       (goto-char key-end)
       (insert (refbox-org--normalize-suffix text)))
      (_ (error "Unknown citation affix side: %S" side)))))

;;;###autoload
(defun refbox-org-set-reference-prefix (prefix)
  "Set the prefix for the Org citation reference at point."
  (interactive "sReference prefix: ")
  (refbox-org--set-reference-affix
   (refbox-org--reference-or-error)
   'prefix
   prefix))

;;;###autoload
(defun refbox-org-set-reference-suffix (suffix)
  "Set the suffix for the Org citation reference at point."
  (interactive "sReference suffix: ")
  (refbox-org--set-reference-affix
   (refbox-org--reference-or-error)
   'suffix
   suffix))

;;;###autoload
(defun refbox-org-delete-at-point ()
  "Delete the Org citation or citation reference at point."
  (interactive)
  (let ((context (org-element-context)))
    (if (org-element-type-p context '(citation citation-reference))
        (progn
          (org-cite-delete-citation context)
          (refbox-org--cleanup-citation-spacing-at-point))
      (user-error "Point is not on an Org citation"))))

;;;###autoload
(defun refbox-org-kill-at-point ()
  "Kill the Org citation or citation reference at point."
  (interactive)
  (let* ((context (org-element-context))
         (bounds
          (pcase (org-element-type context)
            ('citation (org-cite-boundaries context))
            ('citation-reference
             (let* ((citation (org-element-parent context))
                    (references (org-cite-get-references citation)))
               (if (= 1 (length references))
                   (org-cite-boundaries citation)
                 (cons (org-element-begin context)
                       (org-element-end context)))))
            (_ (user-error "Point is not on an Org citation")))))
    (kill-new (buffer-substring-no-properties (car bounds) (cdr bounds)))
    (org-cite-delete-citation context)
    (refbox-org--cleanup-citation-spacing-at-point)))

(defun refbox-org--reference-strings (references)
  "Return raw strings for REFERENCES."
  (mapcar
   (lambda (reference)
     (replace-regexp-in-string
      ";\\'"
      ""
      (string-trim
       (buffer-substring-no-properties
        (org-element-begin reference)
        (org-element-end reference)))))
   references))

(defun refbox-org--shift-reference (direction)
  "Shift citation reference at point in DIRECTION.

DIRECTION is -1 for left and 1 for right."
  (let* ((reference (refbox-org--reference-or-error))
         (citation (org-element-parent reference))
         (references (org-cite-get-references citation))
         (reference-begin (org-element-begin reference))
         (index (cl-position-if
                 (lambda (candidate)
                   (= reference-begin (org-element-begin candidate)))
                 references)))
    (unless index
      (user-error "Point is not on an Org citation reference"))
    (let ((target (+ index direction)))
      (unless (and (>= target 0) (< target (length references)))
        (user-error "Cannot shift citation reference further"))
      (let ((strings (refbox-org--reference-strings references))
            (begin (org-element-contents-begin citation))
            (end (org-element-contents-end citation)))
        (cl-rotatef (nth index strings) (nth target strings))
        (delete-region begin end)
        (goto-char begin)
        (insert (string-join strings "; "))))))

;;;###autoload
(defun refbox-org-shift-reference-left ()
  "Shift the Org citation reference at point left."
  (interactive)
  (refbox-org--shift-reference -1))

;;;###autoload
(defun refbox-org-shift-reference-right ()
  "Shift the Org citation reference at point right."
  (interactive)
  (refbox-org--shift-reference 1))

(defun refbox-org--processor-follow (datum arg)
  "Follow Org citation DATUM with ARG through `refbox-org-follow-action'."
  (let ((key (refbox-org-key-at-point datum)))
    (unless key
      (user-error "No Org citation key at point"))
    (funcall refbox-org-follow-action key datum arg)))

;;;###autoload
(defun refbox-org-follow-at-point (&optional arg)
  "Follow the Org citation key at point using `refbox-org-follow-action'."
  (interactive "P")
  (refbox-org--processor-follow (org-element-context) arg))

(defun refbox-org-open-source (key _datum _arg)
  "Open bibliography source for citation KEY."
  (refbox-open-source key))

(defun refbox-org-list-keys (&optional buffer)
  "Return unique Org citation keys in BUFFER."
  (with-current-buffer (or buffer (current-buffer))
    (delete-dups
     (org-element-map (org-element-parse-buffer)
         'citation-reference
       (lambda (reference)
         (org-element-property :key reference))))))

(defun refbox-org--completion-bounds ()
  "Return Org citation key bounds for completion at point."
  (when-let ((citation (refbox-org-citation-at-point)))
    (refbox-capf-key-bounds-after-at
     (org-element-contents-begin citation)
     (org-element-contents-end citation))))

;;;###autoload
(defun refbox-org-completion-at-point ()
  "Return CAPF data for Org citation references at point."
  (when-let ((bounds (refbox-org--completion-bounds)))
    (refbox-capf-at-bounds bounds (refbox-org-bibliography-files))))

;;;###autoload
(defun refbox-org-setup-capf ()
  "Enable refbox completion at point in the current Org buffer."
  (interactive)
  (add-hook 'completion-at-point-functions
            #'refbox-org-completion-at-point
            nil
            t))

(defun refbox-org-activate (citation)
  "Activate Org CITATION with refbox text properties."
  (pcase-let ((`(,begin . ,end) (org-cite-boundaries citation)))
    (add-text-properties
     begin end
     `(keymap ,refbox-org-citation-map
       help-echo "refbox Org citation"))))

;;;###autoload
(defun refbox-org-bibliography-files (&optional buffer)
  "Return bibliography files declared for Org BUFFER.

Relative paths are expanded against the buffer's `default-directory'."
  (with-current-buffer (or buffer (current-buffer))
    (mapcar #'expand-file-name (org-cite-list-bibliography-files))))

(provide 'refbox-org)

;;; refbox-org.el ends here
