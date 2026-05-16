;;; refbox-embark.el --- Embark integration for refbox -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Ayan Das

;; Author: Ayan Das <bvits@riseup.net>
;; Maintainer: Ayan Das <bvits@riseup.net>
;; Version: 0.4.2
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
(declare-function refbox-org-citation-at-point "refbox-org" (&optional datum))
(declare-function refbox-org-reference-at-point "refbox-org" (&optional datum))
(declare-function org-element-begin "org-element" (element))
(declare-function org-element-end "org-element" (element))
(declare-function org-cite-boundaries "oc" (citation))
(declare-function refbox-latex-key-at-point "refbox-latex" ())
(declare-function refbox-latex-citation-at-point "refbox-latex" ())
(declare-function refbox-latex--completion-bounds "refbox-latex" ())
(declare-function refbox-markdown-key-at-point "refbox-markdown" ())
(declare-function refbox-markdown-citation-at-point "refbox-markdown" ())
(declare-function refbox-markdown--completion-bounds "refbox-markdown" ())
(declare-function refbox--open-resource-choice "refbox" (choice))
(declare-function embark--metadata "embark" ())

(defvar embark-target-finders)
(defvar embark-candidate-collectors)
(defvar embark-transformer-alist)
(defvar embark-general-map)
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

(defvar refbox-embark-map
  (let ((map (make-sparse-keymap)))
    (define-key map (kbd "a") #'refbox-embark-add-file)
    (define-key map (kbd "A") #'refbox-embark-attach-file)
    (define-key map (kbd "b") #'refbox-embark-insert-bibtex)
    (define-key map (kbd "B") #'refbox-embark-insert-raw-entry)
    (define-key map (kbd "c") #'refbox-embark-insert-citation)
    (define-key map (kbd "e") #'refbox-embark-open-entry)
    (define-key map (kbd "f") #'refbox-embark-open-files)
    (define-key map (kbd "k") #'refbox-embark-insert-keys)
    (define-key map (kbd "l") #'refbox-embark-open-links)
    (define-key map (kbd "n") #'refbox-embark-open-notes)
    (define-key map (kbd "o") #'refbox-embark-open)
    (define-key map (kbd "r") #'refbox-embark-copy-reference)
    (define-key map (kbd "R") #'refbox-embark-insert-reference)
    (define-key map (kbd "s") #'refbox-embark-open-source)
    (define-key map (kbd "C") #'refbox-embark-copy-references)
    (define-key map (kbd "z") #'refbox-embark-open-in-zotero)
    (define-key map (kbd "RET") #'refbox-embark-run-default-action)
    map)
  "Embark actions for refbox reference targets.")

(defvar refbox-embark-citation-map
  (let ((map (make-sparse-keymap)))
    (define-key map (kbd "i") #'refbox-embark-insert-edit)
    (define-key map (kbd "a") #'refbox-embark-add-file)
    (define-key map (kbd "A") #'refbox-embark-attach-file)
    (define-key map (kbd "b") #'refbox-embark-insert-bibtex)
    (define-key map (kbd "B") #'refbox-embark-insert-raw-entry)
    (define-key map (kbd "e") #'refbox-embark-open-entry)
    (define-key map (kbd "f") #'refbox-embark-open-files)
    (define-key map (kbd "l") #'refbox-embark-open-links)
    (define-key map (kbd "n") #'refbox-embark-open-notes)
    (define-key map (kbd "o") #'refbox-embark-open)
    (define-key map (kbd "r") #'refbox-embark-copy-reference)
    (define-key map (kbd "s") #'refbox-embark-open-source)
    (define-key map (kbd "C") #'refbox-embark-copy-references)
    (define-key map (kbd "z") #'refbox-embark-open-in-zotero)
    (define-key map (kbd "RET") #'refbox-embark-run-default-action)
    map)
  "Embark actions for refbox citation targets.")

(defvar refbox-embark-resource-map
  (let ((map (make-sparse-keymap)))
    (define-key map (kbd "RET") #'refbox-embark-open-resource)
    (define-key map (kbd "o") #'refbox-embark-open-resource)
    map)
  "Embark actions for refbox resource targets.")

(defvar refbox-embark--target-finders
  '(refbox-embark-target-reference-candidate
    refbox-embark-target-resource-choice
    refbox-embark-target-key-at-point
    refbox-embark-target-citation-at-point)
  "Target finders installed by `refbox-embark-mode'.")

(defvar refbox-embark--candidate-collectors
  '(refbox-embark-selected-candidates)
  "Candidate collectors installed by `refbox-embark-mode'.")

(defvar refbox-embark--transformer-alist
  '((refbox-reference . refbox-embark-candidate-transformer)
    (refbox-resource . refbox-embark-resource-transformer))
  "Embark target transformers installed by `refbox-embark-mode'.")

(defvar refbox-embark--keymap-alist
  '((refbox-reference . refbox-embark-map)
    (refbox-resource . refbox-embark-resource-map)
    (refbox-key . refbox-embark-citation-map)
    (refbox-citation . refbox-embark-citation-map))
  "Embark keymap entries installed by `refbox-embark-mode'.")

(defvar refbox-embark--multitarget-actions
  '(refbox-embark-open
    refbox-embark-open-files
    refbox-embark-attach-file
    refbox-embark-open-links
    refbox-embark-insert-bibtex
    refbox-embark-insert-citation
    refbox-embark-insert-reference
    refbox-embark-insert-keys
    refbox-embark-run-default-action
    refbox-embark-open-notes
    refbox-embark-copy-references)
  "Embark multi-target actions installed by `refbox-embark-mode'.")

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

(defun refbox-embark--citation-target-string (keys)
  "Return an Embark target string for citation KEYS."
  (let ((target (copy-sequence (string-join keys " "))))
    (put-text-property
     0
     (length target)
     'refbox-references
     (mapcar (lambda (key) (list :key key)) keys)
     target)
    target))

(defun refbox-embark--resource-target-string (choice)
  "Return an Embark target string for resource CHOICE."
  (let ((target (copy-sequence (plist-get choice :label))))
    (put-text-property 0 (length target) 'refbox-resource-choice choice target)
    target))

(defun refbox-embark-reference (target)
  "Return the stable reference plist represented by TARGET."
  (cond
   ((and (stringp target)
         (get-text-property 0 'refbox-reference target)))
   ((and (stringp target)
         (car (get-text-property 0 'refbox-references target))))
   ((and (listp target)
         (plist-member target :key))
    target)
   ((stringp target)
    (list :key (substring-no-properties target)))
   (t
    (user-error "No refbox reference at target"))))

(defun refbox-embark-references (target)
  "Return stable reference plists represented by TARGET."
  (cond
   ((and (stringp target)
         (get-text-property 0 'refbox-references target)))
   ((and (listp target)
         (plist-member target :key))
    (list target))
   ((listp target)
    (mapcar #'refbox-embark-reference target))
   (t
    (list (refbox-embark-reference target)))))

(defun refbox-embark-candidate-transformer (_type target)
  "Transform minibuffer completion TARGET to a stable refbox reference."
  (or (when-let ((candidate (get-text-property 0 'refbox-candidate target)))
        (cons 'refbox-reference (refbox-embark--target-string candidate)))
      (cons 'refbox-reference target)))

(defun refbox-embark-resource-choice (target)
  "Return the resource choice represented by TARGET."
  (or (and (stringp target)
           (get-text-property 0 'refbox-resource-choice target))
      (user-error "No refbox resource choice at target")))

(defun refbox-embark-resource-transformer (_type target)
  "Transform minibuffer resource TARGET to the most specific Embark type."
  (let ((choice (and (stringp target)
                     (get-text-property 0 'refbox-resource-choice target))))
    (pcase (plist-get choice :type)
      ('file (cons 'file (plist-get choice :target)))
      ('link (cons 'url (plist-get choice :target)))
      (_ (cons 'refbox-resource
               (if choice
                   (refbox-embark--resource-target-string choice)
                 target))))))

(defun refbox-embark--with-general-map (map)
  "Return MAP composed with `embark-general-map' when available."
  (if (and (boundp 'embark-general-map)
           (keymapp embark-general-map))
      (make-composed-keymap map embark-general-map)
    map))

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

(defun refbox-embark-target-resource-choice ()
  "Return an Embark target for a refbox resource candidate at point."
  (when-let* ((position (refbox-embark--property-position
                        'refbox-resource-choice))
              (choice (get-text-property position 'refbox-resource-choice)))
    (pcase-let ((`(,start . ,end)
                 (refbox-embark--property-bounds
                  position 'refbox-resource-choice)))
      (cons 'refbox-resource
            (cons (refbox-embark--resource-target-string choice)
                  (cons start end))))))

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

(defun refbox-embark--citation-keys-and-bounds ()
  "Return citation keys and bounds at point for supported modes."
  (cond
   ((and (derived-mode-p 'org-mode)
         (require 'refbox-org nil t))
    (when-let* ((citation (refbox-org-citation-at-point))
                (keys (refbox--citation-keys-from-value citation)))
      (pcase-let ((`(,begin . ,end) (org-cite-boundaries citation)))
        (list keys begin end))))
   ((and (derived-mode-p 'latex-mode 'LaTeX-mode 'tex-mode)
         (require 'refbox-latex nil t))
    (when-let* ((citation (refbox-latex-citation-at-point))
                (keys (plist-get citation :keys)))
      (list keys
            (plist-get citation :begin)
            (plist-get citation :end))))
   ((and (derived-mode-p 'markdown-mode 'gfm-mode)
         (require 'refbox-markdown nil t))
    (when-let* ((citation (refbox-markdown-citation-at-point))
                (keys (plist-get citation :keys)))
      (list keys
            (plist-get citation :begin)
            (plist-get citation :end))))))

(defun refbox-embark-target-key-at-point ()
  "Return an Embark target for the citation key at point."
  (pcase (refbox-embark--citation-key-and-bounds)
    (`(,key ,start ,end)
     (cons 'refbox-key
           (cons (refbox-embark--target-string key)
                 (cons start end))))))

(defun refbox-embark-target-citation-at-point ()
  "Return an Embark target for the whole citation at point."
  (pcase (refbox-embark--citation-keys-and-bounds)
    (`(,keys ,start ,end)
     (cons 'refbox-citation
           (cons (refbox-embark--citation-target-string keys)
                 (cons start end))))))

(defun refbox-embark-selected-candidates ()
  "Return selected refbox candidates from the active multi-reference prompt."
  (when-let* (((eq minibuffer-history-variable 'refbox-history))
              ((fboundp 'embark--metadata))
              (metadata (embark--metadata))
              (group-function
               (completion-metadata-get metadata 'group-function))
              (candidates
               (all-completions
                ""
                minibuffer-completion-table
                (lambda (candidate)
                  (and (equal "Selected" (funcall group-function candidate nil))
                       (or (not minibuffer-completion-predicate)
                           (funcall minibuffer-completion-predicate
                                    candidate)))))))
    (cons (completion-metadata-get metadata 'category) candidates)))

(defun refbox-embark-open (target)
  "Open resources for TARGET."
  (interactive "sReference: ")
  (refbox-open (refbox-embark-references target)))

(defun refbox-embark-open-files (target)
  "Open a file resource for TARGET."
  (interactive "sReference: ")
  (refbox-open-files (refbox-embark-references target)))

(defun refbox-embark-open-notes (target)
  "Open an existing note for TARGET."
  (interactive "sReference: ")
  (refbox-open-notes (refbox-embark-references target)))

(defun refbox-embark-open-links (target)
  "Open a link resource for TARGET."
  (interactive "sReference: ")
  (refbox-open-links (refbox-embark-references target)))

(defun refbox-embark-open-source (target)
  "Open the bibliography source entry for TARGET."
  (interactive "sReference: ")
  (refbox-open-source (refbox-embark-reference target)))

(defun refbox-embark-open-entry (target)
  "Open the bibliography entry for TARGET."
  (interactive "sReference: ")
  (refbox-open-entry (refbox-embark-reference target)))

(defun refbox-embark-insert-bibtex (target)
  "Insert the BibTeX entry for TARGET."
  (interactive "sReference: ")
  (refbox-insert-bibtex (refbox-embark-references target)))

(defun refbox-embark-insert-raw-entry (target)
  "Insert the raw bibliography entry for TARGET."
  (interactive "sReference: ")
  (refbox-insert-raw-entry (refbox-embark-references target)))

(defun refbox-embark-insert-citation (target)
  "Insert a mode-appropriate citation for TARGET."
  (interactive "sReference: ")
  (refbox-insert-citation (refbox-embark-references target)))

(defun refbox-embark-insert-keys (target)
  "Insert citation keys for TARGET."
  (interactive "sReference: ")
  (refbox-insert-keys (refbox-embark-references target)))

(defun refbox-embark-insert-reference (target)
  "Insert formatted references for TARGET."
  (interactive "sReference: ")
  (refbox-insert-reference (refbox-embark-references target)))

(defun refbox-embark-copy-reference (target)
  "Copy a formatted reference for TARGET."
  (interactive "sReference: ")
  (refbox-copy-reference (refbox-embark-references target)))

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

(defun refbox-embark-insert-edit (_target)
  "Edit the citation at point."
  (interactive "sReference: ")
  (refbox-insert-edit))

(defun refbox-embark-attach-file (target)
  "Attach a file resource for TARGET."
  (interactive "sReference: ")
  (refbox-attach-files (refbox-embark-reference target)))

(defun refbox-embark-open-in-zotero (target)
  "Open TARGET in Zotero."
  (interactive "sReference: ")
  (refbox-open-in-zotero (refbox-embark-reference target)))

(defun refbox-embark-run-default-action (target)
  "Run the configured default action for TARGET."
  (interactive "sReference: ")
  (refbox-run-default-action (refbox-embark-references target)))

(defun refbox-embark-open-resource (target)
  "Open resource TARGET."
  (interactive "sResource: ")
  (refbox--open-resource-choice (refbox-embark-resource-choice target)))

(defun refbox-embark--enable ()
  "Install refbox target finders and keymaps in Embark."
  (unless (require 'embark nil t)
    (user-error "Embark is not available"))
  (dolist (finder (reverse refbox-embark--target-finders))
    (add-hook 'embark-target-finders finder))
  (when (boundp 'embark-candidate-collectors)
    (dolist (collector (reverse refbox-embark--candidate-collectors))
      (add-hook 'embark-candidate-collectors collector)))
  (when (boundp 'embark-transformer-alist)
    (pcase-dolist (`(,category . ,transformer)
                   refbox-embark--transformer-alist)
      (setf (alist-get category embark-transformer-alist) transformer)))
  (pcase-dolist (`(,category . ,map) refbox-embark--keymap-alist)
    (setf (alist-get category embark-keymap-alist)
          (refbox-embark--with-general-map (symbol-value map))))
  (when (boundp 'embark-multitarget-actions)
    (dolist (action refbox-embark--multitarget-actions)
      (add-to-list 'embark-multitarget-actions action))))

(defun refbox-embark--disable ()
  "Remove refbox target finders and keymaps from Embark."
  (dolist (finder refbox-embark--target-finders)
    (remove-hook 'embark-target-finders finder))
  (when (boundp 'embark-candidate-collectors)
    (dolist (collector refbox-embark--candidate-collectors)
      (remove-hook 'embark-candidate-collectors collector)))
  (when (boundp 'embark-transformer-alist)
    (cl-callf cl-set-difference
        embark-transformer-alist
        refbox-embark--transformer-alist
      :test #'equal))
  (pcase-dolist (`(,category . ,_map) refbox-embark--keymap-alist)
    (setq embark-keymap-alist
          (assq-delete-all category embark-keymap-alist)))
  (when (boundp 'embark-multitarget-actions)
    (dolist (action refbox-embark--multitarget-actions)
      (setq embark-multitarget-actions
            (remq action embark-multitarget-actions)))))

;;;###autoload
(defun refbox-embark-setup ()
  "Register refbox targets and action maps with Embark."
  (interactive)
  (refbox-embark--enable))

;;;###autoload
(define-minor-mode refbox-embark-mode
  "Toggle Embark integration for refbox."
  :group 'refbox-embark
  :global t
  :init-value nil
  :lighter " refbox-embark"
  (if refbox-embark-mode
      (refbox-embark--enable)
    (refbox-embark--disable)))

(provide 'refbox-embark)

;;; refbox-embark.el ends here
