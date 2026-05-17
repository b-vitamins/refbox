;;; test-refbox-latex.el --- Tests for refbox LaTeX integration -*- lexical-binding: t; -*-

;;; Commentary:

;; Buffer-level checks for LaTeX citation workflows.

;;; Code:

(require 'ert)
(require 'cl-lib)
(require 'refbox-latex)

(defvar reftex-default-bibliography)
(defvar LaTeX-bibliography-list)

(defmacro refbox-latex-test-with-buffer (contents &rest body)
  "Create a LaTeX buffer from CONTENTS and evaluate BODY.

A single `|' in CONTENTS marks point and is removed before BODY runs."
  (declare (indent 1))
  `(with-temp-buffer
     (let* ((text ,contents)
            (point-index (string-match-p "|" text)))
       (insert (replace-regexp-in-string "|" "" text nil t))
       (when point-index
         (goto-char (1+ point-index)))
       ,@body)))

(defun refbox-latex-test-candidate (key)
  "Return a minimal refbox candidate for KEY."
  (list :key key))

(defun refbox-latex-test-search-candidate (key source-path)
  "Return a search candidate for KEY from SOURCE-PATH."
  (list :key key
        :source_path source-path
        :entry_type "article"
        :score 0.0
        :fields nil
        :resources nil))

(ert-deftest refbox-latex-test-detects-plain-cite ()
  "Plain \\cite commands should expose citation and key metadata."
  (refbox-latex-test-with-buffer "Text \\cite{al|pha}."
    (let ((citation (refbox-latex--citation-at-point)))
      (should (equal (plist-get citation :command) "cite"))
      (should (equal (plist-get citation :keys) '("alpha")))
      (should (equal (car (refbox-latex-citation-at-point)) '("alpha")))
      (should (equal (car (refbox-latex-key-at-point)) "alpha")))))

(ert-deftest refbox-latex-test-key-at-point_requires_actual_key ()
  "Citation command positions should not masquerade as a key."
  (refbox-latex-test-with-buffer "\\ci|te{alpha,beta}"
    (should-not (refbox-latex-key-at-point))
    (should (equal (car (refbox-latex-citation-at-point))
                   '("alpha" "beta")))))

(ert-deftest refbox-latex-test-point_after_macro_is_not_inside_citation ()
  "A point after the closing brace should start a new citation like Citar."
  (refbox-latex-test-with-buffer "\\cite{alpha}|"
    (should-not (refbox-latex-citation-at-point))
    (should-not (refbox-latex-key-at-point))))

(ert-deftest refbox-latex-test-dwim_uses_whole_citation_on_command_text ()
  "DWIM on citation command text should act on every key in the citation."
  (refbox-latex-test-with-buffer "\\ci|te{alpha,beta}"
    (let (seen)
      (let ((major-mode 'latex-mode)
            (refbox-default-action
             (lambda (references)
               (setq seen references))))
        (refbox-dwim))
      (should (equal seen '("alpha" "beta"))))))

(ert-deftest refbox-latex-test-detects-natbib-optional-arguments ()
  "Natbib-style citations should preserve optional arguments and multiple keys."
  (refbox-latex-test-with-buffer "\\citet[see][p. 7]{alpha, be|ta}"
    (let ((citation (refbox-latex--citation-at-point)))
      (should (equal (plist-get citation :command) "citet"))
      (should (equal (plist-get citation :optional-args) '("see" "p. 7")))
      (should (equal (plist-get citation :keys) '("alpha" "beta")))
      (should (equal (car (refbox-latex-key-at-point)) "beta")))))

(ert-deftest refbox-latex-test-detects_complex_optional_arguments ()
  "Optional argument parsing should honor escapes and balanced braces."
  (refbox-latex-test-with-buffer
      "\\parencite[see {Appendix [A]} and \\] literal][p. 7]{al|pha}"
    (let ((citation (refbox-latex--citation-at-point)))
      (should (equal (plist-get citation :command) "parencite"))
      (should (equal (plist-get citation :optional-args)
                     '("see {Appendix [A]} and \\] literal" "p. 7")))
      (should (equal (plist-get citation :keys) '("alpha")))
      (should (equal (car (refbox-latex-key-at-point)) "alpha")))))

(ert-deftest refbox-latex-test-recognizes_extended_citation_commands ()
  "Default command recognition should cover common BibLaTeX and Natbib forms."
  (refbox-latex-test-with-buffer "\\footfullcite{al|pha}"
    (let ((citation (refbox-latex--citation-at-point)))
      (should (equal (plist-get citation :command) "footfullcite"))
      (should (equal (plist-get citation :keys) '("alpha")))))
  (refbox-latex-test-with-buffer "\\citeauthor*{be|ta}"
    (let ((citation (refbox-latex--citation-at-point)))
      (should (equal (plist-get citation :command) "citeauthor*"))
      (should (equal (plist-get citation :keys) '("beta"))))))

(ert-deftest refbox-latex-test-inserts-default-command ()
  "Insertion should honor the configured default command."
  (refbox-latex-test-with-buffer "Before | after"
    (let ((refbox-latex-default-cite-command "parencite")
          (refbox-latex-prompt-for-cite-style nil)
          (refbox-latex-prompt-for-extra-arguments nil))
	      (cl-letf (((symbol-function 'refbox-read-references)
	                 (lambda (&rest _args)
	                   (list (refbox-latex-test-candidate "alpha")
	                         (refbox-latex-test-candidate "beta")))))
	        (refbox-latex-insert-edit)
	        (should (equal (buffer-string)
	                       "Before \\parencite{alpha,beta} after"))
	        (should (looking-at " after"))))))

(ert-deftest refbox-latex-test-inserts_supplied_citation_keys ()
  "Citation insertion should accept direct key lists and command overrides."
  (refbox-latex-test-with-buffer "Before | after"
    (let ((refbox-latex-prompt-for-extra-arguments nil))
      (refbox-latex-insert-citation '("alpha" "beta") nil "textcite")
      (should (equal (buffer-string)
                     "Before \\textcite{alpha,beta} after")))))

(ert-deftest refbox-latex-test-insertion_includes_local_bibliography_with_configured_corpus ()
  "LaTeX insertion should add discovered bibliography files to selection."
  (let* ((root (make-temp-file "refbox-latex-scope-" t))
         (bib (expand-file-name "refs/main.bib" root))
         calls)
    (unwind-protect
        (let ((default-directory root)
              (refbox-latex-default-cite-command "cite")
              (refbox-latex-prompt-for-cite-style nil)
              (refbox-latex-prompt-for-extra-arguments nil))
          (make-directory (file-name-directory bib) t)
          (write-region "" nil bib)
          (refbox-latex-test-with-buffer "\\bibliography{refs/main}\n|"
	            (cl-letf (((symbol-function 'refbox-read-references)
	                       (lambda (&rest args)
	                         (push args calls)
	                         (list (refbox-latex-test-candidate "alpha")))))
	              (refbox-latex-insert-edit)
	              (should (equal (nth 4 (car calls)) (list bib)))
	              (should (eq (nth 5 (car calls)) t)))))
      (delete-directory root t))))

(ert-deftest refbox-latex-test-prompts-for-command-and-optional-arguments ()
  "Prompt settings should drive command and optional argument selection."
  (refbox-latex-test-with-buffer "|"
    (let ((refbox-latex-prompt-for-cite-style t)
          (refbox-latex-prompt-for-extra-arguments t))
	      (cl-letf (((symbol-function 'completing-read)
	                 (lambda (prompt &rest _args)
	                   (should (equal prompt "Cite command: "))
	                   "textcite"))
	                ((symbol-function 'read-string)
	                 (lambda (prompt &rest _args)
	                   (if (string-prefix-p "Prenote" prompt) "see" "p. 2")))
	                ((symbol-function 'refbox-read-references)
	                 (lambda (&rest _args)
	                   (list (refbox-latex-test-candidate "alpha")))))
	        (refbox-latex-insert-edit)
	        (should (equal (buffer-string)
	                       "\\textcite[see][p. 2]{alpha}"))))))

(ert-deftest refbox-latex-test-command_specs_control_optional_prompts ()
  "Citation command specs should decide which optional arguments are prompted."
  (refbox-latex-test-with-buffer "|"
    (let ((refbox-latex-prompt-for-cite-style nil)
          (refbox-latex-default-cite-command "nocite")
          (refbox-latex-prompt-for-extra-arguments t)
          prompted)
	      (cl-letf (((symbol-function 'read-string)
	                 (lambda (&rest _args)
	                   (setq prompted t)
	                   "unused"))
	                ((symbol-function 'refbox-read-references)
	                 (lambda (&rest _args)
	                   (list (refbox-latex-test-candidate "alpha")))))
	        (refbox-latex-insert-edit)
	        (should-not prompted)
	        (should (equal (buffer-string) "\\nocite{alpha}"))))))

(ert-deftest refbox-latex-test-command_config_uses_citar_alist_shape ()
  "LaTeX command configuration should use Citar's alist representation."
  (let ((refbox-latex-cite-commands
         '((("textcite" "parencite") . (["Prenote"] ["Postnote"] t))
           (("nocite") . nil))))
    (should (equal (refbox-latex--command-names)
                   '("textcite" "parencite" "nocite")))
    (should (equal (refbox-latex--command-entry "parencite")
                   '(("textcite" "parencite")
                     . (["Prenote"] ["Postnote"] t))))
    (should-not (refbox-latex--command-entry "cite"))))

(ert-deftest refbox-latex-test-command_specs_place_keys_at_placeholder ()
  "Citation command specs should place keys at the configured `t' slot."
  (refbox-latex-test-with-buffer "|"
    (let ((refbox-latex-cite-commands
           '((("postcite") . (["Prenote"] t ["Postnote"]))))
          (refbox-latex-default-cite-command "postcite")
          (refbox-latex-prompt-for-cite-style nil)
          (refbox-latex-prompt-for-extra-arguments t)
          (answers '("see" "p. 9")))
	      (cl-letf (((symbol-function 'read-string)
	                 (lambda (&rest _args)
	                   (pop answers)))
	                ((symbol-function 'refbox-read-references)
	                 (lambda (&rest _args)
	                   (list (refbox-latex-test-candidate "alpha")))))
	        (refbox-latex-insert-edit)
	        (should (equal (buffer-string)
	                       "\\postcite[see]{alpha}[p. 9]"))))))

(ert-deftest refbox-latex-test-command_specs_support_mandatory_prompts ()
  "String citation command specs should prompt for mandatory arguments."
  (refbox-latex-test-with-buffer "|"
    (let ((refbox-latex-cite-commands
           '((("chaptercite") . ("Chapter" t))))
          (refbox-latex-default-cite-command "chaptercite")
          (refbox-latex-prompt-for-cite-style nil)
          (refbox-latex-prompt-for-extra-arguments t))
	      (cl-letf (((symbol-function 'read-string)
	                 (lambda (prompt &rest _args)
	                   (should (string-prefix-p "Chapter" prompt))
	                   "ch. 2"))
	                ((symbol-function 'refbox-read-references)
	                 (lambda (&rest _args)
	                   (list (refbox-latex-test-candidate "alpha")))))
	        (refbox-latex-insert-edit)
	        (should (equal (buffer-string)
	                       "\\chaptercite{ch. 2}{alpha}"))))))

(ert-deftest refbox-latex-test-command_specs_parse_key_slot_after_mandatory_args ()
  "Citation parsing should use the configured key slot."
  (refbox-latex-test-with-buffer "\\chaptercite{ch. 2}{al|pha}"
    (let ((refbox-latex-cite-commands
           '((("chaptercite") . ("Chapter" t)))))
      (let ((citation (refbox-latex--citation-at-point)))
        (should (equal (plist-get citation :command) "chaptercite"))
        (should (equal (plist-get citation :keys) '("alpha")))
        (should (equal (car (refbox-latex-key-at-point)) "alpha"))))))

(ert-deftest refbox-latex-test-command_specs_do_not_treat_mandatory_args_as_keys ()
  "Point in a non-key mandatory argument should still find citation keys."
  (refbox-latex-test-with-buffer "\\chaptercite{ch. |2}{alpha}"
    (let ((refbox-latex-cite-commands
           '((("chaptercite") . ("Chapter" t)))))
      (let ((citation (refbox-latex--citation-at-point)))
        (should (equal (plist-get citation :keys) '("alpha")))
        (should-not (refbox-latex-key-at-point))))))

(ert-deftest refbox-latex-test-command_specs_preserve_optional_positions ()
  "Later optional arguments should not slide into earlier empty slots."
  (refbox-latex-test-with-buffer "|"
    (let ((refbox-latex-default-cite-command "textcite")
          (refbox-latex-prompt-for-cite-style nil)
          (refbox-latex-prompt-for-extra-arguments t)
          (answers '("" "p. 9")))
	      (cl-letf (((symbol-function 'read-string)
	                 (lambda (&rest _args)
	                   (pop answers)))
	                ((symbol-function 'refbox-read-references)
	                 (lambda (&rest _args)
	                   (list (refbox-latex-test-candidate "alpha")))))
	        (refbox-latex-insert-edit)
	        (should (equal (buffer-string)
	                       "\\textcite[][p. 9]{alpha}"))))))

(ert-deftest refbox-latex-test-adds-to-configured-key-slot ()
  "Insertion in a configured command should append to the key argument."
  (refbox-latex-test-with-buffer "\\chaptercite{ch. 2}{al|pha}"
    (let ((refbox-latex-cite-commands
           '((("chaptercite") . ("Chapter" t)))))
	      (cl-letf (((symbol-function 'refbox-read-references)
	                 (lambda (&rest _args)
	                   (list (refbox-latex-test-candidate "gamma")))))
	        (refbox-latex-insert-edit)
	        (should (equal (buffer-string)
	                       "\\chaptercite{ch. 2}{alpha,gamma}"))))))

(ert-deftest refbox-latex-test-adds-to-existing-citation ()
  "Insertion at an existing citation should add selected keys."
  (refbox-latex-test-with-buffer "A \\cite{al|pha, beta} Z"
    (let ((refbox-latex-default-cite-command "autocite"))
	      (cl-letf (((symbol-function 'refbox-read-references)
	                 (lambda (&rest _args)
	                   (list (refbox-latex-test-candidate "gamma")))))
	        (refbox-latex-insert-edit)
	        (should (equal (buffer-string)
	                       "A \\cite{alpha,gamma, beta} Z"))
	        (should (looking-at " Z"))))))

(ert-deftest refbox-latex-test-inserts_existing_keys_again_like_citar ()
  "LaTeX citation edits should not silently drop duplicate selected keys."
  (refbox-latex-test-with-buffer "A \\cite{al|pha, beta} Z"
    (refbox-latex-insert-citation '("alpha"))
    (should (equal (buffer-string) "A \\cite{alpha,alpha, beta} Z"))))

(ert-deftest refbox-latex-test-inserts_at_next_separator_like_citar ()
  "LaTeX insertion should scan to the next comma or brace."
  (refbox-latex-test-with-buffer "A \\cite{|alpha,beta} Z"
    (refbox-latex-insert-citation '("gamma"))
    (should (equal (buffer-string) "A \\cite{alpha,gamma,beta} Z")))
  (refbox-latex-test-with-buffer "A \\cite{alpha |, beta} Z"
    (refbox-latex-insert-citation '("gamma"))
    (should (equal (buffer-string) "A \\cite{alpha ,gamma, beta} Z")))
  (refbox-latex-test-with-buffer "A \\cite{alpha,beta}| Z"
    (let ((refbox-latex-prompt-for-extra-arguments nil))
      (refbox-latex-insert-citation '("gamma") nil "cite")
      (should (equal (buffer-string)
                     "A \\cite{alpha,beta}\\cite{gamma} Z")))))

(ert-deftest refbox-latex-test-nil_citation_insert_does_not_prompt ()
  "Programmatic nil LaTeX insertion should match Citar's no-op."
  (refbox-latex-test-with-buffer "Before | after"
    (cl-letf (((symbol-function 'refbox-read-references)
               (lambda (&rest _args)
                 (error "nil citation insertion should not read references"))))
      (refbox-latex-insert-citation nil)
      (should (equal (buffer-string) "Before  after")))))

(ert-deftest refbox-latex-test-formats-biblatex-and-optional-arguments ()
  "Formatter should support biblatex-style commands and optional arguments."
  (should (equal (refbox-latex-format-citation
                  "parencite"
                  '("alpha" "beta")
                  '("see" "chap. 2"))
                 "\\parencite[see][chap. 2]{alpha,beta}")))

(ert-deftest refbox-latex-test-local-bibliography-discovery ()
  "Bibliography discovery should parse common LaTeX declarations."
  (let ((root (make-temp-file "refbox-latex-bib-" t)))
    (unwind-protect
        (let ((default-directory root))
          (make-directory (expand-file-name "refs" root))
          (write-region "" nil (expand-file-name "refs/a.bib" root))
          (write-region "" nil (expand-file-name "refs/b.bib" root))
          (refbox-latex-test-with-buffer
              "\\bibliography{refs/a}\n\\addbibresource{refs/b.bib}\n|"
            (should (equal (refbox-latex-local-bib-files)
                           (list (expand-file-name "refs/a.bib" root)
                                 (expand-file-name "refs/b.bib" root))))))
      (delete-directory root t))))

(ert-deftest refbox-latex-test-local-bibliography_discovery_handles_biblatex_options ()
  "BibLaTeX resource declarations may include optional arguments."
  (let ((root (make-temp-file "refbox-latex-biblatex-" t)))
    (unwind-protect
        (let ((default-directory root))
          (refbox-latex-test-with-buffer
              "\\addbibresource[location=local]{refs/main.bib}\n|"
            (should (equal (refbox-latex-local-bib-files)
                           (list (expand-file-name "refs/main.bib" root))))))
      (delete-directory root t))))

(ert-deftest refbox-latex-test-local-bibliography_discovery_handles_spaced_commands ()
  "BibLaTeX resource declarations may contain whitespace and complex options."
  (let ((root (make-temp-file "refbox-latex-spaced-biblatex-" t)))
    (unwind-protect
        (let ((default-directory root))
          (refbox-latex-test-with-buffer
              "\\addbibresource [location={local [cache]}] { refs/main.bib }\n\\bibliography { refs/a, refs/b.bib }\n|"
            (should (equal (refbox-latex-local-bib-files)
                           (list (expand-file-name "refs/main.bib" root)
                                 (expand-file-name "refs/a.bib" root)
                                 (expand-file-name "refs/b.bib" root))))))
      (delete-directory root t))))

(ert-deftest refbox-latex-test-optional-package-signals-are-optional ()
  "Discovery should read optional helper variables only when already present."
  (refbox-latex-test-with-buffer "|"
    (let ((reftex-default-bibliography '("global.bib"))
          (LaTeX-bibliography-list '("local")))
      (should (equal (refbox-latex-local-bib-files)
                     (list (expand-file-name "global.bib")
                           (expand-file-name "local.bib")))))))

(ert-deftest refbox-latex-test-local-bibliography_discovery_uses_reftex_file_list ()
  "LaTeX bibliography discovery should consume RefTeX's project file list."
  (let ((root (make-temp-file "refbox-latex-reftex-" t)))
    (unwind-protect
        (let ((default-directory root))
          (cl-letf (((symbol-function 'reftex-get-bibfile-list)
                     (lambda () '("refs/project" "refs/other.bib"))))
            (refbox-latex-test-with-buffer "|"
              (should (equal (refbox-latex-local-bib-files)
                             (list (expand-file-name "refs/project.bib" root)
                                   (expand-file-name "refs/other.bib" root)))))))
      (delete-directory root t))))

(ert-deftest refbox-latex-test-lists-current-buffer-keys ()
  "Key listing should deduplicate LaTeX citation keys."
  (refbox-latex-test-with-buffer "\\cite{alpha,beta}\n\\parencite{alpha}\n|"
    (should (equal (refbox-latex-list-keys) '("alpha" "beta")))))

(ert-deftest refbox-latex-test-capf-completes-scoped-citation-keys ()
  "LaTeX CAPF should complete citation keys through bounded scoped search."
  (let* ((root (make-temp-file "refbox-latex-capf-" t))
         (bib (expand-file-name "refs/main.bib" root))
         calls
         syncs)
    (unwind-protect
        (let ((default-directory root)
              (refbox-capf-limit 9))
          (make-directory (file-name-directory bib) t)
          (write-region "" nil bib)
          (refbox-latex-test-with-buffer "\\bibliography{refs/main}\n\\cite{al|}"
            (cl-letf (((symbol-function 'refbox-rpc-request)
                       (lambda (method params)
                         (pcase method
                           ((pred (equal refbox-rpc-method-sync-file))
                            (push params syncs)
                            '(:changed_file_count 1 :removed_file_count 0
                              :indexed_entry_count 1))
                           ((pred (equal refbox-rpc-method-search-entries))
                            (push params calls)
                            (list :entries
                                  (list (refbox-latex-test-search-candidate
                                         "alpha"
                                         bib))))
                           (_ (error "unexpected method: %s" method))))))
              (let* ((capf (refbox-latex-completion-at-point))
                     (start (nth 0 capf))
                     (end (nth 1 capf))
                     (table (nth 2 capf))
                     (candidate (car (all-completions
                                      (buffer-substring-no-properties start end)
                                      table))))
                (should (equal (buffer-substring-no-properties start end) "al"))
                (should (equal (substring-no-properties candidate) "alpha"))
                (let ((params (car calls)))
                  (should (equal (plist-get params :query) "al"))
                  (should (equal (plist-get params :limit) 9))
                  (should (equal (plist-get params :source_paths)
                                 (vector bib)))
                  (should (eq (plist-get params :include_configured_sources) t))
                  (should (equal (plist-get (car syncs) :path) bib))
                  (should (eq (plist-get (car syncs) :explicit) t))
                  (should (member "title"
                                  (append (plist-get params :field_names)
                                          nil)))
                  (should (equal (plist-get params :ranked)
                                 :json-false)))))))
      (delete-directory root t))))

(ert-deftest refbox-latex-test-capf-setup-is-buffer-local ()
  "LaTeX CAPF setup should install a buffer-local completion function."
  (refbox-latex-test-with-buffer "|"
    (setq-local completion-at-point-functions nil)
    (refbox-latex-setup-capf)
    (should (memq #'refbox-latex-completion-at-point
                  completion-at-point-functions))
    (should (local-variable-p 'completion-at-point-functions))))

(provide 'test-refbox-latex)

;;; test-refbox-latex.el ends here
