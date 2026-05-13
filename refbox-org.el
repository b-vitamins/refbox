;;; refbox-org.el --- Org citation integration for refbox -*- lexical-binding: t; -*-

;; Copyright (C) 2026 refbox contributors

;; Author: refbox contributors <maintainers@example.invalid>
;; Maintainer: refbox contributors <maintainers@example.invalid>
;; Version: 0.1.0
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
(require 'oc-basic nil t)
(require 'org)
(require 'org-element)
(require 'org-id nil t)
(require 'seq)
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
(declare-function org-element-interpret-data "org-element" (data))
(declare-function org-cite-basic-activate "oc-basic" (citation))
(declare-function org-id-get-create "org-id" (&optional force))
(declare-function org-roam-buffer-p "org-roam" ())
(declare-function org-roam-ref-add "org-roam" (ref))
(declare-function embark-act "embark" (&optional target type action))

(defgroup refbox-org nil
  "Org citation integration for refbox."
  :group 'refbox
  :prefix "refbox-org-")

(defcustom refbox-org-default-style nil
  "Default Org citation style inserted when a style is requested."
  :type '(choice (const :tag "No explicit style" nil) string)
  :group 'refbox-org)

(defcustom refbox-org-citation-styles nil
  "Citation styles offered by `refbox-org-select-style'.

When nil, styles are read from Org's supported citation styles."
  :type '(choice (const :tag "Use Org supported styles" nil)
                 (repeat string))
  :group 'refbox-org)

(defcustom refbox-org-styles-format 'long
  "Org citation style display format."
  :type '(choice (const long)
                 (const short))
  :group 'refbox-org)

(defcustom refbox-org-style-targets nil
  "Org citation export processors used to limit style completion.

When nil, all styles reported by Org are offered."
  :type '(repeat symbol)
  :group 'refbox-org)

(defcustom refbox-org-follow-action #'refbox-org-follow-default-action
  "Function called by `refbox-org-follow-at-point'.

The function receives three arguments: the citation key, the Org
datum at point, and the raw prefix argument."
  :type 'function
  :group 'refbox-org)

(defcustom refbox-org-activation-functions
  '(refbox-org-cite-basic-activate
    refbox-org-activate-keymap)
  "Functions used to activate an Org citation.

Each function receives the citation datum."
  :type '(repeat function)
  :group 'refbox-org)

(defvar refbox-org-style-history nil
  "Minibuffer history for Org citation styles.")

(defconst refbox-org--key-regexp "[[:alnum:]_:.#$%&+?<>~/=-]+"
  "Regexp matching a refbox citation key in Org buffers.")

(defvar refbox-org-style-preview-alist
  '(("/" . "(de Villiers et al, 2019)")
    ("/b" . "de Villiers et al, 2019")
    ("text" . "de Villiers et al (2019)")
    ("author" . "de Villiers et al")
    ("noauthor" . "(2019)")
    ("nocite" . "No bibliography citation"))
  "Example previews for common Org citation styles.")

(defvar refbox-org-citation-map
  (let ((map (make-sparse-keymap)))
    (define-key map (kbd "<mouse-1>") #'refbox-org-follow-at-point)
    (with-eval-after-load 'embark
      (define-key map (kbd "<mouse-3>") #'embark-act))
    (define-key map (kbd "C-c C-x DEL") #'refbox-org-delete-citation)
    (define-key map (kbd "C-c C-x k") #'refbox-org-kill-citation)
    (define-key map (kbd "d") #'refbox-org-delete-citation)
    (define-key map (kbd "k") #'refbox-org-kill-citation)
    (define-key map (kbd "S-<left>") #'refbox-org-shift-reference-left)
    (define-key map (kbd "S-<right>") #'refbox-org-shift-reference-right)
    (define-key map (kbd "M-p") #'refbox-org-update-prefix-suffix)
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
  (let ((source-paths (refbox-org-local-bib-files)))
    (if multiple
        (mapcar #'refbox-org--candidate-key
                (refbox-read-references
                 "References: "
                 nil
                 nil
                 nil
                 source-paths))
      (refbox-org--candidate-key
	       (refbox-read-reference
	        "Reference: "
	        nil
	        nil
	        nil
	        source-paths)))))

;;;###autoload
(defun refbox-org-select-key (&optional multiple)
  "Select one or more Org citation keys.

When MULTIPLE is non-nil, return a list of keys.  Otherwise return one key."
  (refbox-org--select-keys multiple))

(defun refbox-org--flat-styles (&optional targets)
  "Return flat Org citation styles for TARGETS."
  (let (styles)
    (dolist (style-variants (org-cite-supported-styles targets))
      (seq-let (style &rest variants) style-variants
        (let ((style-name (if (string= "nil" (car style)) "/" (car style))))
          (push style-name styles)
          (dolist (variant variants)
            (let ((variant-name (format "%s" (or (cadr variant) (car variant)))))
              (push (concat style-name
                            (unless (string= "/" style-name) "/")
                            (string-remove-prefix "/" variant-name))
                    styles))))))
    (delete-dups (nreverse styles))))

(defun refbox-org-style-candidates ()
  "Return Org citation style completion candidates."
  (or refbox-org-citation-styles
      (sort (refbox-org--flat-styles refbox-org-style-targets)
            #'string-lessp)))

(defun refbox-org--style-group (style transform)
  "Return group metadata for STYLE.

When TRANSFORM is non-nil, return the displayed candidate."
  (let* ((style (string-trim style))
         (base (if (string-prefix-p "/" style)
                   "default"
                 (car (split-string style "/")))))
    (if transform
        (concat "  " (truncate-string-to-width style 20 nil 32))
      (pcase base
        ("author" "Author")
        ("locators" "Locators")
        ("text" "Textual")
        ("nocite" "No Cite")
        ("year" "Year")
        ("noauthor" "No Author")
        (_ (upcase-initials base))))))

(defun refbox-org--style-annotation (style)
  "Return preview annotation for STYLE."
  (let ((preview (or (cdr (assoc style refbox-org-style-preview-alist)) "")))
    (propertize
     (truncate-string-to-width preview 50 nil 32)
     'face 'refbox-org-style-preview)))

;;;###autoload
(defun refbox-org-select-style (&optional _arg)
  "Complete an Org citation style."
  (interactive)
  (let* ((candidates (refbox-org-style-candidates))
         (style (completing-read
                 "Citation style: "
                 (lambda (string predicate action)
                   (if (eq action 'metadata)
                       '(metadata
                         (annotation-function . refbox-org--style-annotation)
                         (group-function . refbox-org--style-group))
                     (complete-with-action
                      action candidates string predicate)))
                 nil
                 nil
                 nil
                 'refbox-org-style-history
                 refbox-org-default-style))
         (style (string-trim style)))
    (cond
     ((string-empty-p style) nil)
     ((string= style "/") "")
     (t style))))

(defun refbox-org--style-fragment (style)
  "Return Org citation style fragment for STYLE."
  (let ((style (cond
                ((stringp style) style)
                (style (refbox-org-select-style))
                (t nil))))
    (cond
     ((null style) "")
     ((string-empty-p style) "")
     (t (concat "/" style)))))

(defun refbox-org--key-string (keys)
  "Return Org citation reference text for KEYS."
  (mapconcat (lambda (key) (concat "@" key)) keys "; "))

(defun refbox-org--insert-supplied-citation (keys &optional style)
  "Insert KEYS in Org citation syntax, optionally using STYLE."
  (let ((context (org-element-context)))
    (if-let ((citation (refbox-org-citation-at-point context)))
        (let* ((existing (org-cite-get-references citation t))
               (keys (seq-difference keys existing #'equal))
               (key-string (refbox-org--key-string keys))
               (begin (org-element-property :contents-begin citation)))
          (when (and keys begin)
            (if (<= (point) begin)
                (save-excursion
                  (goto-char begin)
                  (insert key-string ";"))
              (let ((reference (refbox-org-reference-at-point)))
                (save-excursion
                  (goto-char (or (and reference (org-element-end reference))
                                 (org-element-property :contents-end citation)))
                  (if (eq (char-before) ?\;)
                      (insert-before-markers key-string ";")
                    (insert-before-markers ";" key-string)))))))
      (if (org-cite--allowed-p context)
          (insert
           (format "[cite%s:%s]"
                   (refbox-org--style-fragment style)
                   (refbox-org--key-string keys)))
        (user-error "Cannot insert an Org citation here")))))

(defun refbox-org--select-style (_citation)
  "Read an Org citation style."
  (refbox-org-select-style))

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
   :follow #'refbox-org-follow
   :activate #'refbox-org-activate))

;;;###autoload
(defun refbox-org-insert-citation (&optional keys style)
  "Insert or edit an Org citation at point.

KEYS, when non-nil, supplies citation keys directly.  When KEYS is nil,
STYLE is forwarded to Org's insertion processor as the raw prefix
argument."
  (interactive (list nil current-prefix-arg))
  (if keys
      (refbox-org--insert-supplied-citation keys style)
    (let ((context (org-element-context))
          (insert (refbox-org--insert-processor)))
      (cond
       ((org-element-type-p context '(citation citation-reference))
        (funcall insert context style))
       ((org-cite--allowed-p context)
        (funcall insert nil style))
       (t
        (user-error "Cannot insert an Org citation here"))))))

;;;###autoload
(defun refbox-org-insert-edit (&optional arg)
  "Insert or edit an Org citation at point."
  (interactive "P")
  (refbox-org-insert-citation nil arg))

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
  (or (let ((reference (refbox-org-reference-at-point datum)))
        (when reference
          (org-element-property :key reference)))
      (refbox-org-property-key-at-point datum)))

(defun refbox-org-property-key-at-point (&optional datum)
  "Return an @KEY citation key from an Org node property at point."
  (let ((context (or datum (org-element-context))))
    (when (and (eq (org-element-type context) 'node-property)
               (org-in-regexp
                (concat "[[:space:]]@\\("
                        refbox-org--key-regexp
                        "\\)")))
      (match-string-no-properties 1))))

(defun refbox-org--id-get-create (&optional force)
  "Call `org-id-get-create' while maintaining point.

With FORCE, force creation of a new ID."
  (unless (fboundp 'org-id-get-create)
    (user-error "`org-id-get-create' is not available"))
  (let ((point (point-marker)))
    (set-marker-insertion-type point t)
    (unwind-protect
        (org-id-get-create force)
      (goto-char point)
      (set-marker point nil))))

;;;###autoload
(defun refbox-org-roam-make-preamble (key)
  "Add an Org-roam note preamble for citation KEY."
  (when (and (derived-mode-p 'org-mode)
             (fboundp 'org-roam-buffer-p)
             (org-roam-buffer-p))
    (ignore-errors (refbox-org--id-get-create))
    (when (fboundp 'org-roam-ref-add)
      (ignore-errors (org-roam-ref-add (concat "@" key))))))

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

(defun refbox-org--reference-suffix-end (reference)
  "Return the end of REFERENCE's suffix without the citation separator."
  (save-excursion
    (goto-char (org-element-end reference))
    (skip-chars-backward " \t")
    (when (and (> (point) (org-element-begin reference))
               (eq (char-before) ?\;))
      (backward-char)
      (skip-chars-backward " \t"))
    (point)))

(defun refbox-org--reference-prefix-begin (reference)
  "Return the beginning of REFERENCE's editable prefix text."
  (let ((begin (org-element-begin reference)))
    (if (and (> begin (point-min))
             (memq (char-before begin) '(?\;))
             (memq (char-after begin) '(?\s ?\t ?\n)))
        (1+ begin)
      begin)))

(defun refbox-org--set-reference-affix (reference side text)
  "Set REFERENCE affix SIDE to TEXT.

SIDE is either `prefix' or `suffix'."
  (pcase-let* ((`(,key-begin . ,key-end) (org-cite-key-boundaries reference))
               (prefix-begin (refbox-org--reference-prefix-begin reference))
               (suffix-end (refbox-org--reference-suffix-end reference)))
    (pcase side
      ('prefix
       (delete-region prefix-begin key-begin)
       (goto-char prefix-begin)
       (insert (refbox-org--normalize-prefix text)))
      ('suffix
       (delete-region key-end suffix-end)
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

(defun refbox-org--reference-affix-text (reference property)
  "Return REFERENCE affix PROPERTY as plain prompt text."
  (if-let ((value (org-element-property property reference)))
      (string-trim (org-element-interpret-data value))
    ""))

(defun refbox-org--update-reference-prefix-suffix (reference)
  "Prompt for and update REFERENCE's prefix and suffix."
  (unless (eq 'citation-reference (org-element-type reference))
    (user-error "Point is not on an Org citation reference"))
  (let* ((key (org-element-property :key reference))
         (label (propertize key 'face 'mode-line-emphasis))
         (prefix (read-string (format "Prefix for %s: " label)
                              (refbox-org--reference-affix-text
                               reference
                               :prefix)))
         (suffix (read-string (format "Suffix for %s: " label)
                              (refbox-org--reference-affix-text
                               reference
                               :suffix))))
    (refbox-org--set-reference-affix reference 'prefix prefix)
    (refbox-org--set-reference-affix
     (refbox-org--reference-or-error)
     'suffix
     suffix)))

;;;###autoload
(defun refbox-org-update-prefix-suffix (&optional arg)
  "Update prefix and suffix text for Org citation references.

With ARG, update every reference in the citation at point.  When
point is on a citation but not on a specific reference, update
every reference in that citation."
  (interactive "P")
  (let* ((datum (org-element-context))
         (type (org-element-type datum))
         (citation (pcase type
                     ('citation datum)
                     ('citation-reference (org-element-property :parent datum))
                     (_ (user-error "Point is not on an Org citation or citation reference"))))
         (references (org-cite-get-references citation)))
    (save-excursion
      (if (or arg (eq type 'citation))
          (let ((citation-begin (org-element-begin citation)))
            (dotimes (index (length references))
              (goto-char citation-begin)
              (let* ((current-citation (refbox-org--citation-or-error))
                     (current-references
                      (org-cite-get-references current-citation))
                     (reference (nth index current-references)))
                (when reference
                  (goto-char (org-element-begin reference))
                  (refbox-org--update-reference-prefix-suffix reference)))))
        (refbox-org--update-reference-prefix-suffix datum)))))

;;;###autoload
(defun refbox-org-delete-citation ()
  "Delete the Org citation or citation reference at point."
  (interactive)
  (let ((context (org-element-context)))
    (if (org-element-type-p context '(citation citation-reference))
        (progn
          (org-cite-delete-citation context)
          (refbox-org--cleanup-citation-spacing-at-point))
      (user-error "Point is not on an Org citation"))))

;;;###autoload
(defun refbox-org-kill-citation ()
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

(defun refbox-org-cite-swap (i j list)
  "Swap indexes I and J in LIST and return LIST."
  (let ((item-i (nth i list)))
    (setf (nth i list) (nth j list))
    (setf (nth j list) item-i))
  list)

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

(defun refbox-org-follow (datum arg)
  "Follow Org citation DATUM with ARG through `refbox-org-follow-action'."
  (interactive (list (org-element-context) current-prefix-arg))
  (let ((key (refbox-org-key-at-point datum)))
    (unless key
      (user-error "No Org citation key at point"))
    (funcall refbox-org-follow-action key datum arg)))

;;;###autoload
(defun refbox-org-follow-at-point (&optional arg)
  "Follow the Org citation key at point using `refbox-org-follow-action'."
  (interactive "P")
  (refbox-org-follow (org-element-context) arg))

(defun refbox-org-open-source (key _datum _arg)
  "Open bibliography source for citation KEY."
  (refbox-open-source key))

(defun refbox-org-follow-default-action (key _datum _arg)
  "Run `refbox-default-action' for citation KEY."
  (refbox-run-default-action (list key)))

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
    (refbox-capf-at-bounds bounds (refbox-org-local-bib-files))))

;;;###autoload
(defun refbox-org-setup-capf ()
  "Enable refbox completion at point in the current Org buffer."
  (interactive)
  (add-hook 'completion-at-point-functions
            #'refbox-org-completion-at-point
            nil
            t))

(defun refbox-org-cite-basic-activate (citation)
  "Activate Org CITATION with Org's basic citation styling."
  (when (fboundp 'org-cite-basic-activate)
    (org-cite-basic-activate citation)))

(defun refbox-org-activate-keymap (citation)
  "Activate Org CITATION with refbox keymap text properties."
  (pcase-let ((`(,begin . ,end) (org-cite-boundaries citation)))
    (add-text-properties
     begin end
     `(keymap ,refbox-org-citation-map
       face refbox-org-highlight
       help-echo "refbox Org citation"))))

(defun refbox-org-activate (citation)
  "Activate Org CITATION with configured refbox activation functions."
  (dolist (function refbox-org-activation-functions)
    (funcall function citation)))

;;;###autoload
(defun refbox-org-local-bib-files (&optional buffer)
  "Return bibliography files declared for Org BUFFER.

Relative paths are expanded against the buffer's `default-directory'."
  (with-current-buffer (or buffer (current-buffer))
    (seq-difference
     (mapcar #'expand-file-name (org-cite-list-bibliography-files))
     (mapcar #'expand-file-name org-cite-global-bibliography)
     #'equal)))

(provide 'refbox-org)

;;; refbox-org.el ends here
