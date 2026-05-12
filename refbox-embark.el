;;; refbox-embark.el --- Embark integration for refbox -*- lexical-binding: t; -*-

;; Copyright (C) 2026 refbox contributors

;; Author: refbox contributors <maintainers@example.invalid>
;; Maintainer: refbox contributors <maintainers@example.invalid>
;; Version: 0.1.0
;; Package-Requires: ((emacs "29.1") (jsonrpc "1.0.27"))
;; Keywords: bib, convenience

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

;; Optional Embark target finders and action keymaps.  This file deliberately
;; does not require Embark at load time; call `refbox-embark-setup' to register
;; the integration in an Emacs session where Embark is available.

;;; Code:

(require 'cl-lib)
(require 'subr-x)
(require 'refbox)

(declare-function refbox-org-key-at-point "refbox-org" (&optional datum))
(declare-function refbox-org-reference-at-point "refbox-org" (&optional datum))
(declare-function org-element-begin "org-element" (element))
(declare-function org-element-end "org-element" (element))
(declare-function refbox-latex-key-at-point "refbox-latex" ())
(declare-function refbox-latex--completion-bounds "refbox-latex" ())
(declare-function refbox-markdown-key-at-point "refbox-markdown" ())
(declare-function refbox-markdown--completion-bounds "refbox-markdown" ())

(defvar embark-target-finders)
(defvar embark-keymap-alist)
(defvar embark-multitarget-actions)

(defgroup refbox-embark nil
  "Embark integration for refbox."
  :group 'refbox
  :prefix "refbox-embark-")

(defcustom refbox-embark-multitarget-limit 100
  "Maximum number of Embark targets accepted by multi-target actions."
  :type 'natnum
  :group 'refbox-embark)

(defvar refbox-embark-reference-map
  (let ((map (make-sparse-keymap)))
    (define-key map (kbd "o") #'refbox-embark-open)
    (define-key map (kbd "f") #'refbox-embark-open-files)
    (define-key map (kbd "n") #'refbox-embark-open-notes)
    (define-key map (kbd "l") #'refbox-embark-open-links)
    (define-key map (kbd "s") #'refbox-embark-open-source)
    (define-key map (kbd "r") #'refbox-embark-insert-raw-entry)
    (define-key map (kbd "c") #'refbox-embark-copy-reference)
    (define-key map (kbd "C") #'refbox-embark-copy-references)
    (define-key map (kbd "a") #'refbox-embark-add-file)
    map)
  "Embark actions for refbox reference targets.")

(defvar refbox-embark-citation-map
  (let ((map (make-sparse-keymap)))
    (define-key map (kbd "o") #'refbox-embark-open)
    (define-key map (kbd "f") #'refbox-embark-open-files)
    (define-key map (kbd "n") #'refbox-embark-open-notes)
    (define-key map (kbd "l") #'refbox-embark-open-links)
    (define-key map (kbd "s") #'refbox-embark-open-source)
    (define-key map (kbd "r") #'refbox-embark-insert-raw-entry)
    (define-key map (kbd "c") #'refbox-embark-copy-reference)
    (define-key map (kbd "C") #'refbox-embark-copy-references)
    (define-key map (kbd "a") #'refbox-embark-add-file)
    map)
  "Embark actions for refbox citation targets.")

(defun refbox-embark--target-string (reference)
  "Return an Embark target string for REFERENCE."
  (let* ((key (refbox--reference-key reference))
         (source-path (refbox--reference-source-path reference))
         (target (copy-sequence key)))
    (put-text-property
     0
     (length target)
     'refbox-reference
     (append (list :key key)
             (unless (refbox--blank-string-p source-path)
               (list :source_path source-path)))
     target)
    target))

(defun refbox-embark-reference (target)
  "Return the stable reference plist represented by TARGET."
  (or (and (stringp target)
           (get-text-property 0 'refbox-reference target))
      (list :key (substring-no-properties target))))

(defun refbox-embark--property-position (property)
  "Return a buffer position carrying PROPERTY at point."
  (cond
   ((get-text-property (point) property)
    (point))
   ((and (> (point) (point-min))
         (get-text-property (1- (point)) property))
    (1- (point)))))

(defun refbox-embark--property-bounds (position property)
  "Return bounds for PROPERTY around POSITION."
  (cons
   (or (previous-single-property-change position property nil (point-min))
       (point-min))
   (or (next-single-property-change position property nil (point-max))
       (point-max))))

(defun refbox-embark-target-reference-candidate ()
  "Return an Embark target for a refbox completion candidate at point."
  (when-let* ((position (refbox-embark--property-position 'refbox-candidate))
              (candidate (get-text-property position 'refbox-candidate))
              (target (refbox-embark--target-string candidate)))
    (pcase-let ((`(,start . ,end)
                 (refbox-embark--property-bounds position 'refbox-candidate)))
      (cons 'refbox-reference (cons target (cons start end))))))

(defun refbox-embark--citation-key-and-bounds ()
  "Return citation key and bounds at point when a supported mode provides them."
  (cond
   ((and (derived-mode-p 'org-mode)
         (require 'refbox-org nil t))
    (when-let* ((key (refbox-org-key-at-point))
                (reference (refbox-org-reference-at-point)))
      (list key (org-element-begin reference) (org-element-end reference))))
   ((and (derived-mode-p 'latex-mode 'LaTeX-mode 'tex-mode)
         (require 'refbox-latex nil t))
    (when-let* ((key (refbox-latex-key-at-point))
                (bounds (refbox-latex--completion-bounds)))
      (list key (car bounds) (cdr bounds))))
   ((and (derived-mode-p 'markdown-mode 'gfm-mode)
         (require 'refbox-markdown nil t))
    (when-let* ((key (refbox-markdown-key-at-point))
                (bounds (refbox-markdown--completion-bounds)))
      (list key (car bounds) (cdr bounds))))))

(defun refbox-embark-target-citation-at-point ()
  "Return an Embark target for the citation key at point."
  (pcase (refbox-embark--citation-key-and-bounds)
    (`(,key ,start ,end)
     (cons 'refbox-citation
           (cons (refbox-embark--target-string key)
                 (cons start end))))))

(defun refbox-embark-open (target)
  "Open resources for TARGET."
  (interactive "sReference: ")
  (refbox-open (refbox-embark-reference target)))

(defun refbox-embark-open-files (target)
  "Open a file resource for TARGET."
  (interactive "sReference: ")
  (refbox-open-files (refbox-embark-reference target)))

(defun refbox-embark-open-notes (target)
  "Open an existing note for TARGET."
  (interactive "sReference: ")
  (refbox-open-notes (refbox-embark-reference target)))

(defun refbox-embark-open-links (target)
  "Open a link resource for TARGET."
  (interactive "sReference: ")
  (refbox-open-links (refbox-embark-reference target)))

(defun refbox-embark-open-source (target)
  "Open the bibliography source entry for TARGET."
  (interactive "sReference: ")
  (refbox-open-source (refbox-embark-reference target)))

(defun refbox-embark-insert-raw-entry (target)
  "Insert the raw bibliography entry for TARGET."
  (interactive "sReference: ")
  (refbox-insert-raw-entry (list (refbox-embark-reference target))))

(defun refbox-embark-copy-reference (target)
  "Copy a formatted reference for TARGET."
  (interactive "sReference: ")
  (refbox-copy-reference (list (refbox-embark-reference target))))

(defun refbox-embark-copy-references (targets)
  "Copy formatted references for explicit TARGETS."
  (interactive (list (list (read-string "Reference: "))))
  (when (> (length targets) refbox-embark-multitarget-limit)
    (user-error
     "Refusing to act on %d targets; `refbox-embark-multitarget-limit' is %d"
     (length targets)
     refbox-embark-multitarget-limit))
  (refbox-copy-reference (mapcar #'refbox-embark-reference targets)))

(defun refbox-embark-add-file (target)
  "Add a file to TARGET's library resources."
  (interactive "sReference: ")
  (refbox-add-file-to-library (refbox-embark-reference target)))

;;;###autoload
(defun refbox-embark-setup ()
  "Register refbox targets and action maps with Embark."
  (interactive)
  (unless (require 'embark nil t)
    (user-error "Embark is not available"))
  (add-to-list 'embark-target-finders
               #'refbox-embark-target-reference-candidate)
  (add-to-list 'embark-target-finders
               #'refbox-embark-target-citation-at-point)
  (add-to-list 'embark-keymap-alist
               '(refbox-reference . refbox-embark-reference-map))
  (add-to-list 'embark-keymap-alist
               '(refbox-citation . refbox-embark-citation-map))
  (when (boundp 'embark-multitarget-actions)
    (add-to-list 'embark-multitarget-actions
                 #'refbox-embark-copy-references)))

(provide 'refbox-embark)

;;; refbox-embark.el ends here
