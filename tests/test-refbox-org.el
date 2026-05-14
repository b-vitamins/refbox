;;; test-refbox-org.el --- Tests for refbox Org integration -*- lexical-binding: t; -*-

;;; Commentary:

;; Buffer-level checks for Org citation workflows.

;;; Code:

(require 'ert)
(require 'cl-lib)
(require 'refbox-org)

(defmacro refbox-org-test-with-buffer (contents &rest body)
  "Create an Org buffer from CONTENTS and evaluate BODY.

A single `|' in CONTENTS marks point and is removed before BODY runs."
  (declare (indent 1))
  `(with-temp-buffer
     (let* ((text ,contents)
            (point-index (string-match-p "|" text)))
       (org-mode)
       (insert (replace-regexp-in-string "|" "" text nil t))
       (when point-index
         (goto-char (1+ point-index)))
       ,@body)))

(defun refbox-org-test-candidate (key)
  "Return a minimal refbox candidate for KEY."
  (list :key key))

(defun refbox-org-test-search-candidate (key source-path)
  "Return a search candidate for KEY from SOURCE-PATH."
  (list :key key
        :source_path source-path
        :entry_type "article"
        :score 0.0
        :fields nil
        :resources nil))

(ert-deftest refbox-org-test-inserts-new-citation ()
  "Org insertion should create a citation from selected references."
  (refbox-org-test-with-buffer "Alpha |omega"
    (cl-letf (((symbol-function 'refbox-read-references)
               (lambda (&rest _args)
                 (list (refbox-org-test-candidate "alpha")
                       (refbox-org-test-candidate "beta")))))
      (refbox-org-insert-citation)
      (should (equal (buffer-string)
                     "Alpha [cite:@alpha; @beta]omega")))))

(ert-deftest refbox-org-test-inserts_supplied_citation_keys ()
  "Org insertion should accept direct key lists and explicit styles."
  (refbox-org-test-with-buffer "Alpha |omega"
    (refbox-org-insert-citation '("alpha" "beta") "text")
    (should (equal (buffer-string)
                   "Alpha [cite/text:@alpha; @beta]omega"))))

(ert-deftest refbox-org-test-insertion_scopes_selection_to_local_bibliography ()
  "Org insertion should pass local bibliography files to reference selection."
  (let* ((root (make-temp-file "refbox-org-scope-" t))
         (bib (expand-file-name "refs/main.bib" root))
         calls)
    (unwind-protect
        (let ((default-directory root)
              (org-cite-global-bibliography nil))
          (make-directory (file-name-directory bib) t)
          (write-region "" nil bib)
          (refbox-org-test-with-buffer "#+bibliography: refs/main.bib\n\n|"
            (cl-letf (((symbol-function 'refbox-read-references)
                       (lambda (&rest args)
                         (push args calls)
                         (list (refbox-org-test-candidate "alpha")))))
              (refbox-org-insert-citation)
              (should (equal (nth 4 (car calls)) (list bib))))))
      (delete-directory root t))))

(ert-deftest refbox-org-test-replaces-existing-reference ()
  "Org insertion on a reference key should replace that one reference."
  (refbox-org-test-with-buffer "[cite:@al|pha; @beta]"
    (cl-letf (((symbol-function 'refbox-read-reference)
               (lambda (&rest _args)
                 (refbox-org-test-candidate "gamma"))))
      (refbox-org-insert-citation)
      (should (equal (buffer-string)
                     "[cite:@gamma; @beta]")))))

(ert-deftest refbox-org-test-adds-reference-around-existing-citation ()
  "Org insertion around an existing reference should add without full rewrites."
  (refbox-org-test-with-buffer "[cite:|@alpha; @beta]"
    (cl-letf (((symbol-function 'refbox-read-reference)
               (lambda (&rest _args)
                 (refbox-org-test-candidate "gamma"))))
      (refbox-org-insert-citation)
      (should (equal (buffer-string)
                     "[cite:@gamma;@alpha; @beta]")))))

(ert-deftest refbox-org-test-edits-existing-citation-style ()
  "Org insertion on the style area should update the citation style."
  (refbox-org-test-with-buffer "[cite/au|thor:@alpha]"
    (cl-letf (((symbol-function 'refbox-org--select-style)
               (lambda (_citation) "text")))
      (refbox-org-insert-citation)
      (should (equal (buffer-string)
                     "[cite/text:@alpha]")))))

(ert-deftest refbox-org-test-style_selection_uses_org_supported_styles ()
  "Style completion should use Org's supported style registry by default."
  (let ((refbox-org-citation-styles nil))
    (cl-letf (((symbol-function 'org-cite-supported-styles)
               (lambda (&optional _targets)
                 '((("nil") ("/b"))
                   (("text") ("/f")))))
              ((symbol-function 'completing-read)
               (lambda (_prompt collection &rest _args)
                 (car (all-completions "text" collection)))))
      (should (equal (refbox-org-select-style) "text"))))
  (let ((refbox-org-citation-styles '("author")))
    (cl-letf (((symbol-function 'completing-read)
               (lambda (_prompt collection &rest _args)
                 (car (all-completions "" collection)))))
      (should (equal (refbox-org-select-style) "author")))))

(ert-deftest refbox-org-test-delete-and-kill-citation-elements ()
  "Deletion and kill commands should use Org citation boundaries."
  (refbox-org-test-with-buffer "A [cite:@al|pha; @beta] Z"
    (refbox-org-delete-citation)
    (should (equal (buffer-string) "A [cite:@beta] Z")))
  (refbox-org-test-with-buffer "A [cite:@al|pha] Z"
    (refbox-org-kill-citation)
    (should (equal (current-kill 0 t) "[cite:@alpha]"))
    (should (equal (buffer-string) "A Z"))))

(ert-deftest refbox-org-test-shifts-references ()
  "Reference shifting should be deterministic within one citation."
  (refbox-org-test-with-buffer "[cite:@alpha; @be|ta; @gamma]"
    (refbox-org-shift-reference-left)
    (should (equal (buffer-string)
                   "[cite:@beta; @alpha; @gamma]")))
  (refbox-org-test-with-buffer "[cite:@alpha; @be|ta; @gamma]"
    (refbox-org-shift-reference-right)
    (should (equal (buffer-string)
                   "[cite:@alpha; @gamma; @beta]"))))

(ert-deftest refbox-org-test-cite-swap_swaps_list_positions ()
  "Citation swap helper should swap two list positions in place."
  (let ((items '("alpha" "beta" "gamma")))
    (should (equal (refbox-org-cite-swap 0 2 items)
                   '("gamma" "beta" "alpha")))
    (should (equal items '("gamma" "beta" "alpha")))))

(ert-deftest refbox-org-test-roam_preamble_adds_at_ref_when_available ()
  "Org-roam preamble helper should add an @KEY ref in Org-roam buffers."
  (refbox-org-test-with-buffer "|* Alpha\n"
    (let (refs id-created)
      (cl-letf (((symbol-function 'org-roam-buffer-p)
                 (lambda () t))
                ((symbol-function 'org-roam-ref-add)
                 (lambda (ref)
                   (push ref refs)))
                ((symbol-function 'org-id-get-create)
                 (lambda (&optional _force)
                   (setq id-created t)
                   "id-1")))
        (refbox-org-roam-make-preamble "alpha")
        (should id-created)
        (should (equal refs '("@alpha")))))))

(ert-deftest refbox-org-test-prefix-and-suffix-updates ()
  "Prefix and suffix commands should edit citation-reference affixes."
  (refbox-org-test-with-buffer "[cite:|@alpha]"
    (refbox-org-set-reference-prefix "see")
    (goto-char (point-min))
    (search-forward "@alpha")
    (refbox-org-set-reference-suffix "p. 12")
    (should (equal (buffer-string)
                   "[cite:see @alpha p. 12]"))))

(ert-deftest refbox-org-test-prefix-and-suffix-update_can_edit_all_refs ()
  "Prefix and suffix update should handle every reference in a citation."
  (refbox-org-test-with-buffer "[cite:|@alpha; @beta]"
    (let ((answers '("see" "p. 1" "also" "p. 2")))
      (cl-letf (((symbol-function 'read-string)
                 (lambda (_prompt &optional _initial _history _default _inherit)
                   (pop answers))))
        (refbox-org-update-prefix-suffix t)))
    (should (equal (buffer-string)
                   "[cite:see @alpha p. 1; also @beta p. 2]"))))

(ert-deftest refbox-org-test-key-and-citation-at-point ()
  "Helpers should find citation and key locations."
  (refbox-org-test-with-buffer "[cite:@al|pha]"
    (should (equal (refbox-org-key-at-point) "alpha"))
    (should (eq (org-element-type (refbox-org-citation-at-point)) 'citation))
    (should (eq (org-element-type (refbox-org-reference-at-point))
                'citation-reference))))

(ert-deftest refbox-org-test-key-at-point_reads_node_property_refs ()
  "Org key helper should find @KEY references in property drawers."
  (refbox-org-test-with-buffer ":PROPERTIES:\n:ROAM_REFS: @smi|th2020\n:END:\n"
    (should (equal (refbox-org-key-at-point) "smith2020"))))

(ert-deftest refbox-org-test-follow-at-citation-and-reference-locations ()
  "Follow should dispatch the key through the configured action."
  (dolist (fixture '("[ci|te:@alpha]" "[cite:@al|pha]"))
    (refbox-org-test-with-buffer fixture
      (let (calls)
        (let ((refbox-org-follow-action
               (lambda (key datum arg)
                 (push (list key (org-element-type datum) arg) calls))))
          (refbox-org-follow-at-point :arg)
          (should (equal (caar calls) "alpha")))))))

(ert-deftest refbox-org-test-default_follow_runs_default_action ()
  "The default Org follow action should run the normal reference action."
  (refbox-org-test-with-buffer "[cite:|@alpha]"
    (let (seen)
      (let ((refbox-default-action
             (lambda (references)
               (setq seen references))))
        (refbox-org-follow-at-point nil))
      (should (equal seen '("alpha"))))))

(ert-deftest refbox-org-test-default_follow_uses_at_point_function ()
  "The default Org follow action should honor the at-point function."
  (refbox-org-test-with-buffer "[cite:|@alpha]"
    (let (called)
      (let ((refbox-at-point-function
             (lambda ()
               (interactive)
               (setq called (refbox-org-key-at-point)))))
        (refbox-org-follow-at-point nil))
      (should (equal called "alpha")))))

(ert-deftest refbox-org-test-activation-installs-keymap ()
  "Activation should install the refbox citation keymap on citation text."
  (refbox-org-test-with-buffer "[cite:|@alpha]"
    (let ((citation (refbox-org-citation-at-point)))
      (refbox-org-activate citation)
      (should (eq (get-text-property (point) 'keymap)
                  refbox-org-citation-map)))))

(ert-deftest refbox-org-test-local-bibliography-discovery ()
  "Local Org bibliography declarations should resolve from fixture buffers."
  (let ((root (make-temp-file "refbox-org-bib-" t)))
    (unwind-protect
        (let ((default-directory root)
              (global-bib (expand-file-name "global.bib" root)))
          (make-directory (expand-file-name "refs" root))
          (write-region "" nil (expand-file-name "refs/main.bib" root))
          (write-region "" nil global-bib)
          (refbox-org-test-with-buffer "#+bibliography: refs/main.bib\n\n|Body"
            (let ((org-cite-global-bibliography (list global-bib)))
              (should (equal (refbox-org-local-bib-files)
                             (list (expand-file-name "refs/main.bib" root)))))))
      (delete-directory root t))))

(ert-deftest refbox-org-test-lists-current-buffer-keys ()
  "Org key listing should deduplicate citation references."
  (refbox-org-test-with-buffer "[cite:@alpha; @beta]\n[cite:@alpha]\n|"
    (should (equal (refbox-org-list-keys) '("alpha" "beta")))))

(ert-deftest refbox-org-test-capf-completes-scoped-citation-keys ()
  "Org CAPF should complete citation keys through bounded scoped search."
  (let* ((root (make-temp-file "refbox-org-capf-" t))
         (bib (expand-file-name "refs/main.bib" root))
         calls)
    (unwind-protect
        (let ((default-directory root)
              (refbox-capf-limit 7))
          (make-directory (file-name-directory bib) t)
          (write-region "" nil bib)
          (refbox-org-test-with-buffer "#+bibliography: refs/main.bib\n\n[cite:@al|]"
            (cl-letf (((symbol-function 'refbox-rpc-request)
                       (lambda (method params)
                         (should (equal method refbox-rpc-method-search-entries))
                         (push params calls)
                         (list :entries
                               (list (refbox-org-test-search-candidate
                                      "alpha"
                                      bib))))))
              (let* ((capf (refbox-org-completion-at-point))
                     (start (nth 0 capf))
                     (end (nth 1 capf))
                     (table (nth 2 capf))
                     (candidate (car (all-completions
                                      (buffer-substring-no-properties start end)
                                      table)))
                     (metadata (funcall table "" nil 'metadata))
                     (annotation-function
                      (cdr (assq 'annotation-function (cdr metadata)))))
                (should (equal (buffer-substring-no-properties start end) "al"))
                (should (equal (substring-no-properties candidate) "alpha"))
                (should (string-match-p "article"
                                        (funcall annotation-function candidate)))
                (should (equal (car calls)
                               (list :query "al"
                                     :limit 7
                                     :source_paths (vector bib))))))))
      (delete-directory root t))))

(ert-deftest refbox-org-test-capf-setup-is-buffer-local ()
  "Org CAPF setup should install a buffer-local completion function."
  (refbox-org-test-with-buffer "|"
    (setq-local completion-at-point-functions nil)
    (refbox-org-setup-capf)
    (should (memq #'refbox-org-completion-at-point
                  completion-at-point-functions))
    (should (local-variable-p 'completion-at-point-functions))))

(provide 'test-refbox-org)

;;; test-refbox-org.el ends here
