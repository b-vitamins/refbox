;;; refbox-org.el --- Org citation integration for refbox -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Ayan Das

;; Author: Ayan Das <bvits@riseup.net>
;; Maintainer: Ayan Das <bvits@riseup.net>
;; Version: 0.4.8
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
(declare-function org-open-at-point "org" (&optional arg reference-buffer))
(declare-function org-cite-basic-activate "oc-basic" (citation))
(declare-function org-cite-basic--set-keymap "oc-basic" (begin end follow))
(declare-function org-id-get-create "org-id" (&optional force))
(declare-function org-roam-buffer-p "org-roam" ())
(declare-function org-roam-ref-add "org-roam" (ref))
(declare-function embark-act "embark" (&optional target type action))
(defvar org-cite-basic-mouse-over-key-face)
(defvar org-cite-basic-max-key-distance)

(defgroup refbox-org nil
  "Org citation integration for refbox."
  :group 'refbox
  :prefix "refbox-org-")

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

(defcustom refbox-org-activation-functions
  '(refbox-org-cite-basic-activate
    refbox-org-activate-keymap)
  "Functions used to activate an Org citation.

Each function receives the citation datum."
  :type '(repeat function)
  :group 'refbox-org)

(defconst refbox-org--key-regexp "[[:alnum:]_:.#$%&+?<>~/=-]+"
  "Regexp matching a refbox citation key in Org buffers.")

(defvar refbox-org-style-preview-alist
  '(("/" . "(de Villiers et al, 2019)")
    ("/b" . "de Villiers et al, 2019")
    ("/c" . "(De Villiers et al, 2019)")
    ("/bc" . "de Villiers et al, 2019")
    ;; Text style.
    ("text" . "de Villiers et al (2019)")
    ("text/c" . "De Villiers et al (2019)")
    ("text/f" . "de Villiers, Smith, Doa, and Jones (2019)")
    ("text/cf" . "De Villiers, Smith, Doa, and Jones (2019)")
    ;; Author style.
    ("author" . "de Villiers et al")
    ("author/c" . "De Villiers et al")
    ("author/f" . "de Villiers, Smith, Doa, and Jones")
    ("author/cf" . "De Villiers, Smith, Doa, and Jones")
    ;; Locators style.
    ("locators" . "(p23)")
    ("locators" . "p23")
    ;; Noauthor style.
    ("noauthor" . "(2019)")
    ("noauthor/b" . "2019"))
  "Example previews for common Org citation styles.")

(defvar refbox-org-citation-map
  (let ((map (make-sparse-keymap)))
    (define-key map (kbd "<mouse-1>") (cons "default action" #'org-open-at-point))
    (with-eval-after-load 'embark
      (define-key map (kbd "<mouse-3>") (cons "embark act" #'embark-act)))
    (define-key map (kbd "C-c C-x DEL") (cons "delete citation" #'refbox-org-delete-citation))
    (define-key map (kbd "C-c C-x k") (cons "kill citation" #'refbox-org-kill-citation))
    (define-key map (kbd "S-<left>") (cons "shift left" #'refbox-org-shift-reference-left))
    (define-key map (kbd "S-<right>") (cons "shift right" #'refbox-org-shift-reference-right))
    (define-key map (kbd "M-p") (cons "update prefix/suffix" #'refbox-org-update-prefix-suffix))
    map)
  "Keymap installed by `refbox-org-activate'.")

(defun refbox-org--candidate-key (candidate)
  "Return the citation key from CANDIDATE."
  (refbox--reference-key candidate))

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
                 source-paths
                 t
                 t))
      (refbox-org--candidate-key
       (refbox-read-reference
        "Reference: "
        nil
        nil
        nil
        source-paths
        t
        t)))))

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
            (let ((style (concat style-name
                                 (unless (string= "/" style-name) "/")
                                 (cadr variant))))
              (push style
                    styles))))))
    styles))

(defun refbox-org--style-candidate (style)
  "Return STYLE as a propertized completion candidate."
  (propertize
   style
   'face
   (if (and (string-match-p "/" style)
            (< 1 (length style)))
       'refbox
     'refbox-highlight)))

(defun refbox-org-style-candidates ()
  "Return Org citation style completion candidates."
  (mapcar
   #'refbox-org--style-candidate
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
        ("author" "Author-Only")
        ("locators" "Locators-Only")
        ("text" "Textual/Narrative")
        ("nocite" "No Cite")
        ("year" "Year-Only")
        ("noauthor" "Suppress Author")
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
                 "Styles: "
                 (lambda (string predicate action)
                   (if (eq action 'metadata)
                      '(metadata
                        (annotation-function . refbox-org--style-annotation)
                        (group-function . refbox-org--style-group))
                     (complete-with-action
                      action candidates string predicate)))))
         (style (string-trim style)))
    (cond
     ((string= style "/") "")
     (t style))))

(defun refbox-org--style-fragment (style)
  "Return Org citation style fragment for STYLE."
  (let ((style (when style
                 (refbox-org-select-style))))
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
    (if-let ((citation (refbox-org--citation-at-point context)))
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
(defun refbox-org-insert-citation (keys &optional style)
  "Insert or edit an Org citation at point.

KEYS supplies citation keys directly.  STYLE is forwarded to Org's
citation formatter."
  (refbox-org--insert-supplied-citation keys style))

;;;###autoload
(defun refbox-org-insert-edit (&optional arg)
  "Insert or edit an Org citation at point."
  (interactive "P")
  (refbox-org-register-processor)
  (let ((org-cite-insert-processor 'refbox))
    (org-cite-insert arg)))

(defun refbox-org-reference-at-point (&optional datum)
  "Return the Org citation reference at point or in DATUM."
  (let ((context (or datum (org-element-context))))
    (pcase (org-element-type context)
      ('citation-reference context)
      ('citation
       (let ((references (org-cite-get-references context)))
         (cl-find-if
          (lambda (reference)
            (and (>= (point) (org-element-begin reference))
                 (<= (point) (org-element-end reference))))
          references)))
      (_ nil))))

(defun refbox-org--citation-at-point (&optional datum)
  "Return the Org citation at point or in DATUM."
  (let ((element (or datum (org-element-context))))
    (while (and element
                (not (eq 'citation (org-element-type element))))
      (setq element (org-element-property :parent element)))
    (when-let ((bounds (and element (org-cite-boundaries element))))
      (when (and (>= (point) (car bounds))
                 (<= (point) (cdr bounds)))
        element))))

;;;###autoload
(defun refbox-org-citation-at-point (&optional datum)
  "Return Org citation keys at point with their bounds."
  (when-let ((citation (refbox-org--citation-at-point datum)))
    (cons (org-cite-get-references citation t)
          (org-cite-boundaries citation))))

(defun refbox-org--reference-key-and-bounds-at-point (&optional datum)
  "Return an Org citation-reference key and bounds at point."
  (when-let ((reference (refbox-org-reference-at-point datum)))
    (cons (org-element-property :key reference)
          (cons (org-element-begin reference)
                (org-element-end reference)))))

;;;###autoload
(defun refbox-org-key-at-point (&optional datum)
  "Return the Org citation key at point with its bounds."
  (or (refbox-org--reference-key-and-bounds-at-point datum)
      (refbox-org--property-key-and-bounds-at-point datum)))

(defun refbox-org--property-key-and-bounds-at-point (&optional datum)
  "Return an Org node-property citation key and bounds at point."
  (let ((context (or datum (org-element-context))))
    (when (and (eq (org-element-type context) 'node-property)
               (org-in-regexp
                (concat "[[:space:]]@\\("
                        refbox-org--key-regexp
                        "\\)")))
      (cons (match-string-no-properties 1)
            (cons (match-beginning 0)
                  (match-end 0))))))

(defun refbox-org-property-key-at-point (&optional datum)
  "Return an @KEY citation key from an Org node property at point."
  (car (refbox-org--property-key-and-bounds-at-point datum)))

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

(defun refbox-org--citation-or-error ()
  "Return the citation at point or signal a user error."
  (or (refbox-org--citation-at-point)
      (user-error "Point is not on an Org citation")))

(defun refbox-org--update-reference-prefix-suffix (reference)
  "Prompt for and update REFERENCE's prefix and suffix."
  (unless (eq 'citation-reference (org-element-type reference))
    (error "Not on a reference"))
  (let* ((key (org-element-property :key reference))
         (label (propertize key 'face 'mode-line-emphasis))
         (pre (org-element-interpret-data
               (org-element-property :prefix reference)))
         (post (org-element-interpret-data
                (org-element-property :suffix reference)))
         (prefix (read-string (format "Prefix for %s: " label)
                              (string-trim pre)))
         (suffix (string-trim-left
                  (read-string (format "Suffix for %s: " label)
                               (string-trim post))))
         (suffix (concat (unless (string-empty-p suffix) " ") suffix)))
    (cl--set-buffer-substring
     (org-element-begin reference)
     (org-element-end reference)
     (org-element-interpret-data
      `(citation-reference
        (:key ,key :prefix ,prefix :suffix ,suffix))))))

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
                     (_ (error "Not on a citation or reference"))))
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
  (org-cite-delete-citation (org-element-context)))

;;;###autoload
(defun refbox-org-kill-citation ()
  "Kill the Org citation or citation reference at point."
  (interactive)
  (let ((context (org-element-context)))
    (kill-region (org-element-begin context)
                 (org-element-end context))))

(defun refbox-org-cite-swap (i j list)
  "Swap indexes I and J in LIST and return LIST."
  (let ((item-i (nth i list)))
    (setf (nth i list) (nth j list))
    (setf (nth j list) item-i))
  list)

(defun refbox-org--get-ref-index (references reference)
  "Return index of REFERENCE within REFERENCES."
  (seq-position
   references
   reference
   (lambda (left right)
     (equal (org-element-property :begin left)
            (org-element-property :begin right)))))

(defun refbox-org--shift-reference (datum direction)
  "Shift citation reference DATUM in DIRECTION."
  (let* ((citation (if (eq 'citation (org-element-type datum))
                       datum
                     (org-element-property :parent datum)))
         (reference (when (eq 'citation-reference (org-element-type datum))
                      datum))
         (point-offset
          (- (point) (org-element-property :begin reference)))
         (references (org-cite-get-references citation))
         (index (refbox-org--get-ref-index references reference)))
    (when (= 1 (length references))
      (error "You only have one reference; you cannot shift this"))
    (when (or (and (equal index 0)
                   (equal direction 'left))
              (and (equal (1+ index) (length references))
                   (equal direction 'right)))
      (error "You cannot shift the reference in this direction"))
    (when (null index)
      (error "Nothing to shift here"))
    (let* ((begin (org-element-property :contents-begin citation))
           (end (org-element-property :contents-end citation))
           (new-index (if (eq 'left direction) (1- index) (1+ index))))
      (cl--set-buffer-substring
       begin
       end
       (org-element-interpret-data
        (refbox-org-cite-swap index new-index references)))
      (goto-char
       (+ (org-element-property
           :begin
           (nth new-index (org-cite-get-references citation)))
          point-offset)))))

;;;###autoload
(defun refbox-org-shift-reference-left ()
  "Shift the Org citation reference at point left."
  (interactive)
  (refbox-org--shift-reference (org-element-context) 'left))

;;;###autoload
(defun refbox-org-shift-reference-right ()
  "Shift the Org citation reference at point right."
  (interactive)
  (refbox-org--shift-reference (org-element-context) 'right))

;;;###autoload
(defun refbox-org-follow (datum arg)
  "Follow Org citation DATUM with ARG."
  (interactive (list (org-element-context) current-prefix-arg))
  (ignore datum arg)
  (call-interactively refbox-at-point-function))

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
  (when-let ((citation (refbox-org--citation-at-point)))
    (refbox-capf-key-bounds-after-at
     (org-element-contents-begin citation)
     (org-element-contents-end citation))))

;;;###autoload
(defun refbox-org-completion-at-point ()
  "Return CAPF data for Org citation references at point."
  (when-let ((bounds (refbox-org--completion-bounds)))
    (refbox-capf-at-bounds bounds (refbox-org-local-bib-files) t)))

;;;###autoload
(defun refbox-org-setup-capf ()
  "Enable refbox completion at point in the current Org buffer."
  (interactive)
  (add-hook 'completion-at-point-functions
            #'refbox-org-completion-at-point
            nil
            t))

(defun refbox-org--activation-field-names ()
  "Return bibliography fields needed for Org activation previews."
  (delete-dups
   (cl-remove-if
    #'refbox--blank-string-p
    (append
     (refbox-template-field-names (refbox--template 'preview))
     (refbox--crossref-field-names)))))

(defun refbox-org--activation-candidates (keys)
  "Return a hash table mapping citation KEYS to indexed candidates."
  (let ((table (make-hash-table :test 'equal))
        (groups (make-hash-table :test 'equal))
        (source-paths (refbox-org-local-bib-files))
        (keys (delete-dups (cl-remove-if #'refbox--blank-string-p keys))))
    (when keys
      (condition-case nil
          (dolist (candidate
                   (refbox-search-references
                    ""
                    (min refbox-search-maximum-limit
                         (max 1 (* 8 (length keys))))
                    source-paths
                    t
                    (refbox-org--activation-field-names)
                    t
                    nil
                    nil
                    keys
                    t))
            (let ((key (refbox--reference-key candidate)))
              (puthash key
                       (cons candidate (gethash key groups))
                       groups)))
        (error nil)))
    (dolist (key keys)
      (when-let ((candidate
                  (refbox--context-candidate-for-key
                   key
                   (nreverse (gethash key groups))
                   source-paths)))
        (puthash key candidate table)))
    table))

(defun refbox-org--activation-close-keys (key)
  "Return bounded Refbox-backed edit-distance suggestions for unknown KEY."
  (condition-case nil
      (let* ((source-paths
              (refbox--normalize-bibliography-source-paths
               (refbox-org-local-bib-files)))
             (max-distance
              (if (boundp 'org-cite-basic-max-key-distance)
                  org-cite-basic-max-key-distance
                2)))
        (when source-paths
          (refbox--ensure-source-paths-indexed source-paths))
        (refbox--listify
         (plist-get
          (refbox-rpc-request
           refbox-rpc-method-close-keys
           (append
            (list :key key
                  :max_distance max-distance
                  :limit refbox-completion-limit)
            (when source-paths
              (list :source_paths (vconcat source-paths)))
            (list :include_configured_sources t)))
          :keys)))
    (error nil)))

(defun refbox-org--set-basic-keymap (begin end replacement)
  "Install Org basic citation keymap from BEGIN to END."
  (when (fboundp 'org-cite-basic--set-keymap)
    (org-cite-basic--set-keymap begin end replacement)))

(defun refbox-org-cite-basic-activate (citation)
  "Activate Org CITATION using Refbox-indexed citation metadata."
  (pcase-let* ((`(,begin . ,end) (org-cite-boundaries citation))
               (references (org-cite-get-references citation))
               (candidates
                (refbox-org--activation-candidates
                 (mapcar (lambda (reference)
                           (org-element-property :key reference))
                         references))))
    (put-text-property begin end 'font-lock-multiline t)
    (add-face-text-property begin end 'org-cite)
    (dolist (reference references)
      (pcase-let* ((`(,key-begin . ,key-end)
                    (org-cite-key-boundaries reference))
                   (key (org-element-property :key reference))
                   (candidate (gethash key candidates)))
        (when (boundp 'org-cite-basic-mouse-over-key-face)
          (put-text-property
           key-begin
           key-end
           'mouse-face
           org-cite-basic-mouse-over-key-face))
        (if candidate
            (let ((entry (string-trim
                          (refbox-format-reference (list candidate)))))
              (add-face-text-property key-begin key-end 'org-cite-key)
              (unless (string-empty-p entry)
                (put-text-property
                 key-begin
                 key-end
                 'help-echo
                 (org-element-interpret-data entry)))
              (refbox-org--set-basic-keymap key-begin key-end nil))
          (add-face-text-property key-begin key-end 'error)
          (let ((close-keys (refbox-org--activation-close-keys key)))
            (when close-keys
              (put-text-property
               key-begin
               key-end
               'help-echo
               (concat "Suggestions (mouse-1 to substitute): "
                       (mapconcat #'identity close-keys " "))))
            (refbox-org--set-basic-keymap
             key-begin
             key-end
             (or close-keys 'all))))))))

(defun refbox-org-activate-keymap (citation)
  "Activate Org CITATION with refbox keymap text properties."
  (pcase-let ((`(,begin . ,end) (org-cite-boundaries citation)))
    (put-text-property begin end 'keymap refbox-org-citation-map)))

;;;###autoload
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
