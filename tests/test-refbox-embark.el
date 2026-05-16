;;; test-refbox-embark.el --- Tests for refbox Embark integration -*- lexical-binding: t; -*-

;;; Commentary:

;; Optional Embark integration checks.

;;; Code:

(require 'ert)
(require 'cl-lib)
(require 'refbox-embark)
(require 'refbox-latex)
(require 'refbox-markdown)

(defvar embark-general-map)

(defun refbox-embark-test-candidate (key source-path)
  "Return a search candidate for KEY from SOURCE-PATH."
  (list :key key
        :source_path source-path
        :entry_type "article"
        :score 0.0
        :fields nil
        :resources nil))

(ert-deftest refbox-embark-test-reference-candidate-target-uses-stable_identity ()
  "Candidate targets should use key/source identity, not display text."
  (let* ((candidate (refbox-embark-test-candidate "alpha" "/tmp/refs.bib"))
         (display (propertize "Alpha Search Display"
                              'refbox-candidate
                              candidate)))
    (with-temp-buffer
      (insert display)
      (goto-char (point-min))
      (let* ((target (refbox-embark-target-reference-candidate))
             (encoded (nth 1 target))
             (reference (refbox-embark-reference encoded)))
        (should (eq (car target) 'refbox-reference))
        (should (equal (substring-no-properties encoded) "alpha"))
        (should (equal reference
                       (list :key "alpha"
                             :source_path "/tmp/refs.bib")))
        (should (= (nth 2 target) (point-min)))
        (should (= (cdddr target) (point-max)))))))

(ert-deftest refbox-embark-test-key-target-at-point ()
  "Key targets should expose the citation key at point."
  (with-temp-buffer
    (setq major-mode 'latex-mode)
    (insert "\\cite{alpha}")
    (search-backward "alpha")
    (forward-char 2)
    (let* ((target (refbox-embark-target-key-at-point))
           (encoded (nth 1 target))
           (reference (refbox-embark-reference encoded)))
      (should (eq (car target) 'refbox-key))
      (should (equal reference (list :key "alpha")))
      (should (equal (substring-no-properties encoded) "alpha")))))

(ert-deftest refbox-embark-test-markdown-key-target_uses_actual_key_bounds ()
  "Markdown key targets should use the full Pandoc key span."
  (with-temp-buffer
    (cl-letf (((symbol-function 'derived-mode-p)
               (lambda (&rest modes) (memq 'markdown-mode modes))))
      (setq major-mode 'markdown-mode)
      (insert "See [@{braced key}; @beta].")
      (search-backward "braced")
      (forward-char 3)
      (let* ((target (refbox-embark-target-key-at-point))
             (encoded (nth 1 target))
             (reference (refbox-embark-reference encoded)))
        (should (eq (car target) 'refbox-key))
        (should (equal reference (list :key "braced key")))
        (should (equal (substring-no-properties encoded) "braced key"))
        (should (equal (buffer-substring-no-properties
                        (nth 2 target)
                        (cdddr target))
                       "@{braced key}"))))))

(ert-deftest refbox-embark-test-citation-target-at-point ()
  "Whole-citation targets should expose every key in the citation."
  (with-temp-buffer
    (setq major-mode 'latex-mode)
    (insert "\\cite{alpha,beta}")
    (search-backward "beta")
    (let* ((target (refbox-embark-target-citation-at-point))
           (encoded (nth 1 target)))
      (should (eq (car target) 'refbox-citation))
      (should (equal (refbox-embark-references encoded)
                     (list (list :key "alpha")
                           (list :key "beta"))))
      (should (equal (substring-no-properties encoded) "alpha beta")))))

(ert-deftest refbox-embark-test-candidate_transformer_uses_stable_identity ()
  "Minibuffer candidate transforms should not pass display strings to actions."
  (let* ((candidate (refbox-embark-test-candidate "alpha" "/tmp/refs.bib"))
         (display (propertize "Alpha Search Display"
                              'refbox-candidate
                              candidate))
         (target (refbox-embark-candidate-transformer
                  'refbox-reference
                  display)))
    (should (eq (car target) 'refbox-reference))
    (should (equal (refbox-embark-reference (cdr target))
                   (list :key "alpha"
                         :source_path "/tmp/refs.bib")))))

(ert-deftest refbox-embark-test-resource_transformer_exposes_file_targets ()
  "Resource choices should expose real file targets to generic Embark actions."
  (let* ((choice '(:type file
                   :target "/tmp/paper.pdf"
                   :label "file alpha paper.pdf"))
         (candidate (propertize (plist-get choice :label)
                                'refbox-resource-choice choice))
         (target (refbox-embark-resource-transformer
                  'refbox-resource
                  candidate)))
    (should (eq (car target) 'file))
    (should (equal (cdr target) "/tmp/paper.pdf"))))

(ert-deftest refbox-embark-test-resource_transformer_keeps_create_note_actions ()
  "Create-note resource choices should stay on the Refbox resource map."
  (let* ((choice '(:type create-note
                   :target "alpha"
                   :label "create alpha"))
         (candidate (propertize (plist-get choice :label)
                                'refbox-resource-choice choice))
         (target (refbox-embark-resource-transformer
                  'refbox-resource
                  candidate)))
    (should (eq (car target) 'refbox-resource))
    (should (equal (refbox-embark-resource-choice (cdr target))
                   choice))))

(ert-deftest refbox-embark-test-resource_choice_target_at_point ()
  "Resource choice targets should be discoverable in completion buffers."
  (let* ((choice '(:type file
                   :target "/tmp/paper.pdf"
                   :label "file alpha paper.pdf"))
         (display (propertize (plist-get choice :label)
                              'refbox-resource-choice choice)))
    (with-temp-buffer
      (insert display)
      (goto-char (point-min))
      (let* ((target (refbox-embark-target-resource-choice))
             (encoded (nth 1 target)))
        (should (eq (car target) 'refbox-resource))
        (should (equal (refbox-embark-resource-choice encoded) choice))
        (should (= (nth 2 target) (point-min)))
        (should (= (cdddr target) (point-max)))))))

(ert-deftest refbox-embark-test-setup-registers-finders-and-keymaps ()
  "Setup should register target finders and keymaps only when requested."
  (skip-unless (require 'embark nil t))
  (let ((embark-target-finders nil)
        (embark-candidate-collectors nil)
        (embark-transformer-alist nil)
        (embark-general-map (let ((map (make-sparse-keymap)))
                              (define-key map (kbd "g") #'ignore)
                              map))
        (embark-keymap-alist nil)
        (embark-multitarget-actions nil))
    (refbox-embark-setup)
    (should (memq #'refbox-embark-target-reference-candidate
                  embark-target-finders))
    (should (memq #'refbox-embark-target-resource-choice
                  embark-target-finders))
    (should (memq #'refbox-embark-target-key-at-point
                  embark-target-finders))
    (should (memq #'refbox-embark-target-citation-at-point
                  embark-target-finders))
    (should (memq #'refbox-embark-selected-candidates
                  embark-candidate-collectors))
    (should (eq (cdr (assq 'refbox-reference embark-transformer-alist))
                'refbox-embark-candidate-transformer))
    (should (eq (cdr (assq 'refbox-resource embark-transformer-alist))
                'refbox-embark-resource-transformer))
    (should (eq (lookup-key (cdr (assq 'refbox-reference embark-keymap-alist))
                            (kbd "o"))
                #'refbox-embark-open))
    (should (eq (lookup-key (cdr (assq 'refbox-reference embark-keymap-alist))
                            (kbd "RET"))
                #'refbox-embark-run-default-action))
    (should (eq (lookup-key (cdr (assq 'refbox-reference embark-keymap-alist))
                            (kbd "c"))
                #'refbox-embark-insert-citation))
    (should (eq (lookup-key (cdr (assq 'refbox-reference embark-keymap-alist))
                            (kbd "k"))
                #'refbox-embark-insert-keys))
    (should (eq (lookup-key (cdr (assq 'refbox-reference embark-keymap-alist))
                            (kbd "r"))
                #'refbox-embark-copy-reference))
    (should (eq (lookup-key (cdr (assq 'refbox-reference embark-keymap-alist))
                            (kbd "R"))
                #'refbox-embark-insert-reference))
    (should (eq (lookup-key (cdr (assq 'refbox-resource embark-keymap-alist))
                            (kbd "RET"))
                #'refbox-embark-open-resource))
    (should (eq (lookup-key (cdr (assq 'refbox-reference embark-keymap-alist))
                            (kbd "g"))
                #'ignore))
    (should (eq (lookup-key (cdr (assq 'refbox-key embark-keymap-alist))
                            (kbd "i"))
                #'refbox-embark-insert-edit))
    (should (eq (lookup-key (cdr (assq 'refbox-key embark-keymap-alist))
                            (kbd "r"))
                #'refbox-embark-copy-reference))
    (should (eq (lookup-key (cdr (assq 'refbox-key embark-keymap-alist))
                            (kbd "RET"))
                #'refbox-embark-run-default-action))
    (should (eq (lookup-key (cdr (assq 'refbox-citation embark-keymap-alist))
                            (kbd "i"))
                #'refbox-embark-insert-edit))
    (should (eq (lookup-key refbox-embark-map (kbd "s"))
                #'refbox-embark-open-source))
    (should (eq (lookup-key refbox-embark-map (kbd "e"))
                #'refbox-embark-open-entry))
    (should (eq (lookup-key refbox-embark-map (kbd "b"))
                #'refbox-embark-insert-bibtex))
    (should (eq (lookup-key refbox-embark-map (kbd "B"))
                #'refbox-embark-insert-raw-entry))
    (should (eq (lookup-key refbox-embark-map (kbd "C"))
                #'refbox-embark-copy-references))
    (should (memq #'refbox-embark-insert-citation
                  embark-multitarget-actions))
    (should (memq #'refbox-embark-run-default-action
                  embark-multitarget-actions))
    (should (memq #'refbox-embark-copy-references
                  embark-multitarget-actions))))

(ert-deftest refbox-embark-test-mode_can_disable_registered_surface ()
  "The global mode should be reversible."
  (skip-unless (require 'embark nil t))
  (let ((embark-target-finders nil)
        (embark-candidate-collectors nil)
        (embark-transformer-alist nil)
        (embark-keymap-alist nil)
        (embark-multitarget-actions nil)
        refbox-embark-mode)
    (refbox-embark-mode 1)
    (should (memq #'refbox-embark-target-reference-candidate
                  embark-target-finders))
    (should (memq #'refbox-embark-selected-candidates
                  embark-candidate-collectors))
    (should (assq 'refbox-reference embark-transformer-alist))
    (should (assq 'refbox-reference embark-keymap-alist))
    (should (memq #'refbox-embark-copy-references
                  embark-multitarget-actions))
    (refbox-embark-mode -1)
    (should-not (memq #'refbox-embark-target-reference-candidate
                      embark-target-finders))
    (should-not (memq #'refbox-embark-target-resource-choice
                      embark-target-finders))
    (should-not (memq #'refbox-embark-selected-candidates
                      embark-candidate-collectors))
    (should-not (assq 'refbox-reference embark-transformer-alist))
    (should-not (assq 'refbox-reference embark-keymap-alist))
    (should-not (memq #'refbox-embark-copy-references
                      embark-multitarget-actions))))

(ert-deftest refbox-embark-test-selected_candidate_collector_uses_group_metadata ()
  "The selected-candidate collector should expose multi-select choices."
  (let* ((selected (copy-sequence "alpha"))
         (unselected (copy-sequence "beta"))
         (metadata
          `(metadata
            (category . refbox-reference)
            (group-function
             . ,(lambda (candidate _transform)
                  (when (equal candidate selected)
                    "Selected"))))))
    (cl-letf (((symbol-function 'embark--metadata)
               (lambda () metadata)))
      (let ((minibuffer-history-variable 'refbox-history)
            (minibuffer-completion-table (list selected unselected))
            (minibuffer-completion-predicate nil))
        (should (equal (refbox-embark-selected-candidates)
                       (cons 'refbox-reference (list selected))))))))

(ert-deftest refbox-embark-test-actions-use-stable-reference_identity ()
  "Actions should pass stable reference plists through to core commands."
  (let ((target (refbox-embark--target-string
                 (list :key "alpha" :source_path "/tmp/refs.bib")))
        calls)
    (cl-letf (((symbol-function 'refbox-open-source)
               (lambda (reference)
                 (push reference calls)
                 :opened)))
      (should (eq (refbox-embark-open-source target) :opened))
      (should (equal (car calls)
                     (list :key "alpha"
                           :source_path "/tmp/refs.bib"))))))

(ert-deftest refbox-embark-test-entry_actions-use-stable-reference_identity ()
  "Entry-oriented actions should pass stable reference plists."
  (let ((target (refbox-embark--target-string
                 (list :key "alpha" :source_path "/tmp/refs.bib")))
        calls)
    (cl-letf (((symbol-function 'refbox-open-entry)
               (lambda (reference)
                 (push (list :open reference) calls)
                 :opened))
              ((symbol-function 'refbox-insert-bibtex)
               (lambda (references)
                 (push (list :insert references) calls)
                 :inserted))
              ((symbol-function 'refbox-insert-citation)
               (lambda (references)
                 (push (list :cite references) calls)
                 :cited))
              ((symbol-function 'refbox-insert-keys)
               (lambda (references)
                 (push (list :keys references) calls)
                 :keyed))
              ((symbol-function 'refbox-insert-reference)
               (lambda (references)
                 (push (list :formatted references) calls)
                 :formatted))
              ((symbol-function 'refbox-run-default-action)
               (lambda (references)
                 (push (list :default references) calls)
                 :defaulted)))
      (should (eq (refbox-embark-open-entry target) :opened))
      (should (eq (refbox-embark-insert-bibtex target) :inserted))
      (should (eq (refbox-embark-insert-citation target) :cited))
      (should (eq (refbox-embark-insert-keys target) :keyed))
      (should (eq (refbox-embark-insert-reference target) :formatted))
      (should (eq (refbox-embark-run-default-action target) :defaulted))
      (should (equal (nreverse calls)
                     (list
                      (list :open (list :key "alpha"
                                        :source_path "/tmp/refs.bib"))
                      (list :insert
                            (list (list :key "alpha"
                                        :source_path "/tmp/refs.bib")))
                      (list :cite
                            (list (list :key "alpha"
                                        :source_path "/tmp/refs.bib")))
                      (list :keys
                            (list (list :key "alpha"
                                        :source_path "/tmp/refs.bib")))
                      (list :formatted
                            (list (list :key "alpha"
                                        :source_path "/tmp/refs.bib")))
                      (list :default
                            (list (list :key "alpha"
                                        :source_path "/tmp/refs.bib")))))))))

(ert-deftest refbox-embark-test-multitarget-actions_decode_target_lists ()
  "Embark multi-target actions should decode every stable target."
  (let ((alpha (refbox-embark--target-string
                (list :key "alpha" :source_path "/tmp/a.bib")))
        (beta (refbox-embark--target-string
               (list :key "beta" :source_path "/tmp/b.bib")))
        calls)
    (cl-letf (((symbol-function 'refbox-open)
               (lambda (references)
                 (push references calls)
                 :opened)))
      (should (eq (refbox-embark-open (list alpha beta)) :opened))
      (should (equal (car calls)
                     (list (list :key "alpha" :source_path "/tmp/a.bib")
                           (list :key "beta" :source_path "/tmp/b.bib")))))))

(ert-deftest refbox-embark-test-multitarget-copy-is-bounded_and_explicit ()
  "The explicit multi-target copy action should enforce its target cap."
  (let ((alpha (refbox-embark--target-string
                (list :key "alpha" :source_path "/tmp/a.bib")))
        (beta (refbox-embark--target-string
               (list :key "beta" :source_path "/tmp/b.bib")))
        calls)
    (cl-letf (((symbol-function 'refbox-copy-reference)
               (lambda (references)
                 (push references calls)
                 :copied)))
      (let ((refbox-embark-multitarget-limit 2))
        (should (eq (refbox-embark-copy-references (list alpha beta))
                    :copied))
        (should (equal (car calls)
                       (list (list :key "alpha" :source_path "/tmp/a.bib")
                             (list :key "beta" :source_path "/tmp/b.bib")))))
      (let ((refbox-embark-multitarget-limit 1))
        (should-error
         (refbox-embark-copy-references (list alpha beta))
         :type 'user-error)))))

(provide 'test-refbox-embark)

;;; test-refbox-embark.el ends here
