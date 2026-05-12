;;; test-refbox.el --- Tests for refbox -*- lexical-binding: t; -*-

;;; Commentary:

;; Batch checks for the refbox Emacs package scaffold.

;;; Code:

(require 'ert)
(require 'cl-lib)
(require 'refbox)

(ert-deftest refbox-test-package-loads ()
  "The package entry feature should load cleanly."
  (should (featurep 'refbox)))

(ert-deftest refbox-test-package-load-has-no-process-side-effects ()
  "Loading the package should not start a daemon connection."
  (should-not (refbox-rpc-live-p))
  (should-not refbox--connection))

(ert-deftest refbox-test-rpc-command-construction ()
  "Daemon command construction should use validated user options."
  (let* ((root (make-temp-file "refbox-root-" t))
         (program (or (executable-find "true")
                      (executable-find "sh")))
         (db (expand-file-name "refbox.sqlite" root)))
    (unwind-protect
        (let ((refbox-server-program program)
              (refbox-bibliography-roots (list root))
              (refbox-database-file db))
          (should (equal (refbox-rpc--command)
                         (list program
                               "serve"
                               "--root" (file-truename root)
                               "--db" db))))
      (delete-directory root t))))

(ert-deftest refbox-test-configuration-errors-are-direct ()
  "Configuration validation should report actionable user errors."
  (let* ((root (make-temp-file "refbox-root-" t))
         (program (or (executable-find "true")
                      (executable-find "sh")))
         (db (expand-file-name "refbox.sqlite" root)))
    (unwind-protect
        (progn
          (let ((refbox-server-program program)
                (refbox-bibliography-roots nil)
                (refbox-database-file db))
            (should
             (string-match-p
              "refbox-bibliography-roots"
              (error-message-string
               (should-error (refbox-rpc--configuration)
                             :type 'user-error)))))
          (let ((refbox-server-program "refbox-definitely-missing")
                (refbox-bibliography-roots (list root))
                (refbox-database-file db))
            (should
             (string-match-p
              "executable not found"
              (error-message-string
               (should-error (refbox-rpc--configuration)
                             :type 'user-error)))))
          (let ((refbox-server-program program)
                (refbox-bibliography-roots (list root))
                (refbox-database-file
                 (expand-file-name "missing/refbox.sqlite" root)))
            (should
             (string-match-p
              "database directory does not exist"
              (error-message-string
               (should-error (refbox-rpc--configuration)
                             :type 'user-error))))))
      (delete-directory root t))))

(ert-deftest refbox-test-commands-send-task-shaped-rpc ()
  "Interactive commands should request daemon work only when invoked."
  (let (calls)
    (cl-letf (((symbol-function 'refbox-rpc-request)
               (lambda (method &optional params)
                 (push (list method params) calls)
                 (pcase method
                   ("refbox/status"
                    '(:counts (:file_count 1 :entry_count 2 :diagnostic_count 0)))
                   ("refbox/syncFull"
                    '(:changed_file_count 1 :removed_file_count 0
                      :indexed_entry_count 2))
                   ("refbox/syncFile"
                    '(:changed_file_count 1 :removed_file_count 0
                      :indexed_entry_count 2))))))
      (refbox-status)
      (refbox-sync)
      (refbox-sync-file "/tmp/example.bib"))
    (setq calls (nreverse calls))
    (should (equal (mapcar #'car calls)
                   '("refbox/status" "refbox/syncFull" "refbox/syncFile")))
    (should (equal (cadr (nth 2 calls))
                   (list :path "/tmp/example.bib")))))

(defconst refbox-test-reference-candidate
  '(:key "smith2020"
    :source_path "refs/main.bib"
    :entry_type "article"
    :score -1.25
    :fields ((:raw_name "author" :lookup_name "author" :value "{Smith, Jane}")
             (:raw_name "title" :lookup_name "title" :value "{Alpha Reference Title}")
             (:raw_name "date" :lookup_name "date" :value "{2020-05-12}")
             (:raw_name "file" :lookup_name "file" :value "paper.pdf")
             (:raw_name "doi" :lookup_name "doi" :value "10.1000/refbox"))
    :resources ((:key "smith2020" :source_path "refs/main.bib"
                  :owner_key "smith2020" :owner_source_path "refs/main.bib"
                  :kind "file" :raw_name "file" :lookup_name "file"
                  :value "paper.pdf")
                 (:key "smith2020" :source_path "refs/main.bib"
                  :owner_key "smith2020" :owner_source_path "refs/main.bib"
                  :kind "doi" :raw_name "doi" :lookup_name "doi"
                  :value "10.1000/refbox")))
  "Representative indexed reference candidate used by Elisp tests.")

(ert-deftest refbox-test-template-formatting-supports_field_features ()
  "Reference templates should support width, star width, fallback, and transforms."
  (should
   (equal
    (refbox-template-format
     "%{missing|title:8!refbox-template-clean}|%{date:4!refbox-template-year}|%{key:*!upcase}"
     refbox-test-reference-candidate
     23)
    "Alpha Re|2020|SMITH2020"))
  (should
   (equal (refbox-reference-format-note refbox-test-reference-candidate)
          "Alpha Reference Title"))
  (should
   (string-match-p
    "refs/main\\.bib"
    (refbox-reference-format-preview refbox-test-reference-candidate))))

(ert-deftest refbox-test-completion-candidates-carry_metadata ()
  "Completion candidates should come from bounded RPC search and carry metadata."
  (let ((refbox-reference-main-template "%{key} %{title!refbox-template-clean}")
        (refbox-reference-suffix-template
         "%{indicators} %{entry_type} %{source_path!file-name-nondirectory}")
        (refbox-reference-cited-predicate nil)
        calls)
    (cl-letf (((symbol-function 'refbox-rpc-request)
               (lambda (method params)
                 (push (list method params) calls)
                 (should (equal method refbox-rpc-method-search-entries))
                 (list :entries (list refbox-test-reference-candidate)))))
      (let* ((state (refbox--completion-state 7))
             (table (refbox--completion-table state))
             (candidates (funcall table "alpha" nil t))
             (candidate-string (car candidates))
             (candidate (get-text-property
                         0 'refbox-candidate candidate-string))
             (annotation (refbox--completion-annotation candidate-string))
             (affixation (car (refbox--completion-affixation
                               (list candidate-string)))))
        (should (equal (cadar calls) (list :query "alpha" :limit 7)))
        (should (string-match-p "smith2020" candidate-string))
        (should (equal (plist-get candidate :key) "smith2020"))
        (should (string-match-p
                 "F@ article main\\.bib"
                 annotation))
        (should (string-match-p
                 "F@ article main\\.bib"
                 (nth 2 affixation)))))))

(ert-deftest refbox-test-resource-file-parsers-handle-escaped-delimiters ()
  "File field parsers should handle path lists and triplet values."
  (should (equal (refbox-resource-parse-file-field-default
                  "foo\\;bar; baz ; ")
                 '("foo;bar" "baz")))
  (should (equal (refbox-resource-parse-file-field-triplet
                  ":foo.pdf:PDF,:bar.pdf:PDF")
                 '("foo.pdf" "bar.pdf")))
  (should (equal (refbox-resource-parse-file-field-triplet
                  "Title\\: Subtitle:C\\:\\\\title.pdf:PDF")
                 '("C:\\title.pdf"))))

(ert-deftest refbox-test-reference-files-resolve-fields-library-paths-and_extensions ()
  "File lookup should combine indexed file fields with configured libraries."
  (let* ((root (make-temp-file "refbox-resources-" t))
         (refs (expand-file-name "refs" root))
         (library (expand-file-name "library" root))
         (subdir (expand-file-name "nested" library))
         (candidate (copy-tree refbox-test-reference-candidate)))
    (unwind-protect
        (progn
          (make-directory refs t)
          (make-directory subdir t)
          (dolist (file (list (expand-file-name "paper.pdf" refs)
                              (expand-file-name "smith2020.pdf" library)
                              (expand-file-name "smith2020-extra.pdf" subdir)
                              (expand-file-name "smith2020.html" library)))
            (with-temp-file file))
          (setq candidate (plist-put candidate :source_path
                                     (expand-file-name "main.bib" refs)))
          (let ((refbox-resource-library-paths (list library))
                (refbox-resource-library-paths-recursive t)
                (refbox-resource-library-file-extensions '("pdf"))
                (refbox-resource-additional-file-separator "-"))
            (should
             (equal (mapcar #'file-name-nondirectory
                            (refbox-reference-files
                             candidate
                             (refbox--candidate-resources candidate)))
                    '("paper.pdf" "smith2020.pdf" "smith2020-extra.pdf")))))
      (delete-directory root t))))

(ert-deftest refbox-test-note-filename-uses-existing-or-default_path ()
  "Note filename generation should prefer existing notes and create stable names."
  (let* ((root (make-temp-file "refbox-notes-" t))
         (existing (expand-file-name "smith2020.org" root)))
    (unwind-protect
        (progn
          (with-temp-file existing)
          (let ((refbox-note-paths (list root))
                (refbox-note-file-extensions '("org" "md")))
            (should (equal (refbox-note-filename "smith2020") existing))
            (should (equal (refbox-note-filename "doe/2021")
                           (expand-file-name "doe_2021.org" root)))))
      (delete-directory root t))))

(ert-deftest refbox-test-link-resource-formatting ()
  "Identifier and URL resources should format into openable links."
  (should (equal (refbox-resource-link-url '(:kind "doi" :value "{10.1000/refbox}"))
                 "https://doi.org/10.1000/refbox"))
  (should (equal (refbox-resource-link-url '(:kind "url" :value "{https://example.test}"))
                 "https://example.test")))

(ert-deftest refbox-test-open-resource_commands_use_configured_functions ()
  "Resource open commands should delegate to configured open functions."
  (let* ((root (make-temp-file "refbox-open-" t))
         (file (expand-file-name "paper.pdf" root))
         opened)
    (unwind-protect
        (progn
          (with-temp-file file)
          (let ((candidate (copy-tree refbox-test-reference-candidate))
                (refbox-resource-open-file-function
                 (lambda (target) (push (cons 'file target) opened)))
                (refbox-resource-open-link-function
                 (lambda (target) (push (cons 'link target) opened)))
                (refbox-note-open-function
                 (lambda (target) (push (cons 'note target) opened)))
                (refbox-note-paths (list root))
                (refbox-note-file-extensions '("org")))
            (setq candidate
                  (plist-put candidate :resources
                             (list (list :kind "file" :lookup_name "file"
                                         :value file
                                         :owner_source_path
                                         (expand-file-name "main.bib" root))
                                   (list :kind "doi" :value "10.1000/refbox"))))
            (cl-letf (((symbol-function 'refbox-reference-resources)
                       (lambda (_candidate)
                         (refbox--candidate-resources candidate))))
              (refbox-open-files candidate)
              (refbox-open-links candidate)
              (refbox-create-note candidate)))
          (should (member (cons 'file file) opened))
          (should (member (cons 'link "https://doi.org/10.1000/refbox") opened))
          (should (member (cons 'note (expand-file-name "smith2020.org" root))
                          opened)))
      (delete-directory root t))))

(ert-deftest refbox-test-open-source-jumps-to-indexed-location ()
  "Source opening should use indexed file, line, and column information."
  (let* ((root (make-temp-file "refbox-source-" t))
         (source-file (expand-file-name "refs.bib" root)))
    (unwind-protect
        (progn
          (with-temp-file source-file
            (insert "@article{alpha,\n  title = {Alpha}\n}\n"))
          (cl-letf (((symbol-function 'refbox-rpc-request)
                     (lambda (method params)
                       (should (equal method refbox-rpc-method-source-location))
                       (should (equal params (list :key "alpha")))
                       `(:key "alpha"
                         :source_path ,source-file
                         :source (:start (:line 2 :column 2))))))
            (refbox-open-source "alpha")
            (should (equal (buffer-file-name) source-file))
            (should (= (line-number-at-pos) 2))
            (should (= (current-column) 2))))
      (when-let ((buffer (find-buffer-visiting source-file)))
        (kill-buffer buffer))
      (delete-directory root t))))

(ert-deftest refbox-test-raw-entry-insertion-preserves-indexed-text ()
  "Raw entry insertion should insert daemon-provided entry text unchanged."
  (let ((raw-alpha "@article{alpha,\n  title = {Alpha}\n}")
        (raw-beta "@book{beta,\n  title = {Beta}\n}"))
    (with-temp-buffer
      (cl-letf (((symbol-function 'refbox-rpc-request)
                 (lambda (_method params)
                   (pcase (plist-get params :key)
                     ("alpha" (list :raw raw-alpha))
                     ("beta" (list :raw raw-beta))))))
        (refbox-insert-raw-entry '("alpha" "beta")))
      (should (equal (buffer-string)
                     (concat raw-alpha "\n\n" raw-beta))))))

(ert-deftest refbox-test-export-bibliography-removes-configured_fields ()
  "Local bibliography export should remove configured no-export fields."
  (let* ((root (make-temp-file "refbox-export-" t))
         (output (expand-file-name "local.bib" root))
         (raw "@article{alpha,\n  title = {Alpha},\n  file = {alpha.pdf},\n  doi = {10.1000/alpha}\n}"))
    (unwind-protect
        (let ((refbox-export-no-export-fields '("file")))
          (cl-letf (((symbol-function 'refbox-rpc-request)
                     (lambda (_method _params)
                       (list :raw raw))))
            (should (equal (refbox-export-bibliography output '("alpha"))
                           output)))
          (with-temp-buffer
            (insert-file-contents output)
            (should (string-match-p "title = {Alpha}" (buffer-string)))
            (should (string-match-p "doi = {10.1000/alpha}" (buffer-string)))
            (should-not (string-match-p "file = " (buffer-string)))))
      (delete-directory root t))))

(ert-deftest refbox-test-add-file-to-library_sources ()
  "Library add helpers should cover buffer, file, and URL-style sources."
  (let* ((root (make-temp-file "refbox-library-" t))
         (library (expand-file-name "library" root))
         (source (expand-file-name "source.pdf" root)))
    (unwind-protect
        (let ((refbox-resource-library-paths (list library)))
          (with-temp-buffer
            (insert "buffer-pdf")
            (should (equal (refbox-add-buffer-to-library "alpha" "pdf")
                           (expand-file-name "alpha.pdf" library))))
          (with-temp-buffer
            (insert-file-contents (expand-file-name "alpha.pdf" library))
            (should (equal (buffer-string) "buffer-pdf")))
          (with-temp-file source
            (insert "file-pdf"))
          (should (equal (refbox-add-file-to-library-from-file "beta" source)
                         (expand-file-name "beta.pdf" library)))
          (with-temp-buffer
            (insert-file-contents (expand-file-name "beta.pdf" library))
            (should (equal (buffer-string) "file-pdf")))
          (cl-letf (((symbol-function 'url-copy-file)
                     (lambda (_url destination _overwrite)
                       (with-temp-file destination
                         (insert "url-pdf")))))
            (should (equal (refbox-add-file-to-library-from-url
                            "gamma" "https://example.test/paper.pdf" "pdf")
                           (expand-file-name "gamma.pdf" library))))
          (with-temp-buffer
            (insert-file-contents (expand-file-name "gamma.pdf" library))
            (should (equal (buffer-string) "url-pdf"))))
      (delete-directory root t))))

(ert-deftest refbox-test-csl-style-metadata-and-selection ()
  "CSL style selection should present metadata-backed choices."
  (let* ((root (make-temp-file "refbox-csl-" t))
         (style-dir (expand-file-name "styles" root))
         (style-file (expand-file-name "apa.csl" style-dir)))
    (unwind-protect
        (progn
          (make-directory style-dir t)
          (with-temp-file style-file
            (insert "<style><info><title>APA Test</title>"
                    "<id>http://www.zotero.org/styles/apa-test</id>"
                    "</info></style>"))
          (should (equal (refbox-csl-style-metadata style-file)
                         (list :file style-file
                               :id "http://www.zotero.org/styles/apa-test"
                               :title "APA Test")))
          (let ((refbox-csl-style-directories (list style-dir))
                refbox-csl-style)
            (cl-letf (((symbol-function 'completing-read)
                       (lambda (_prompt collection &rest _args)
                         (car (all-completions "" collection)))))
              (should (equal (refbox-select-csl-style) style-file))
              (should (equal refbox-csl-style style-file))))
          (let ((refbox-csl-style-directories (list style-dir))
                (refbox-csl-style "http://www.zotero.org/styles/apa-test"))
            (should (equal (refbox-csl-style-file) style-file))))
      (delete-directory root t))))

(ert-deftest refbox-test-format-references-uses-daemon-and-csl_configuration ()
  "Reference formatting should call the daemon with selected style and locale."
  (let* ((root (make-temp-file "refbox-format-" t))
         (style (expand-file-name "style.csl" root))
         (locale (expand-file-name "locales-en-US.xml" root))
         calls)
    (unwind-protect
        (progn
          (with-temp-file style)
          (with-temp-file locale)
          (let ((refbox-csl-style style)
                (refbox-csl-locale locale))
            (cl-letf (((symbol-function 'refbox-rpc-request)
                       (lambda (method params)
                         (push (list method params) calls)
                         (list :references
                               (list (list :key "alpha"
                                           :text "Formatted Alpha")
                                     (list :key "beta"
                                           :text "Formatted Beta"))))))
              (should (equal (refbox-format-references '("alpha" "beta"))
                             '("Formatted Alpha" "Formatted Beta")))))
          (should (equal (caar calls) refbox-rpc-method-format-references))
          (should (equal (cadar calls)
                         (list :keys '("alpha" "beta")
                               :style_path style
                               :locale_path locale))))
      (delete-directory root t))))

(ert-deftest refbox-test-insert-and-copy-formatted_references ()
  "Insert and copy commands should use formatted reference text."
  (let ((formatted '("Alpha Reference" "Beta Reference")))
    (cl-letf (((symbol-function 'refbox-format-references)
               (lambda (_references) formatted)))
      (with-temp-buffer
        (refbox-insert-reference '("alpha" "beta"))
        (should (equal (buffer-string)
                       "Alpha Reference\n\nBeta Reference")))
      (should (equal (refbox-copy-reference '("alpha" "beta"))
                     "Alpha Reference\n\nBeta Reference"))
      (should (equal (current-kill 0) "Alpha Reference\n\nBeta Reference")))))

(ert-deftest refbox-test-formatting_configuration_errors_are_actionable ()
  "Missing style and locale configuration should fail directly."
  (should
   (string-match-p
    "refbox-csl-style"
    (error-message-string
     (should-error (let ((refbox-csl-style nil))
                     (refbox-csl-style-file))
                   :type 'user-error))))
  (should
   (string-match-p
    "locale not found"
    (error-message-string
     (should-error (let ((refbox-csl-locale "missing")
                         (refbox-csl-locale-directories nil))
                     (refbox-csl-locale-file))
                   :type 'user-error))))
  (should
   (string-match-p
    "refbox-csl-locale"
    (error-message-string
     (should-error (let ((refbox-csl-locale nil))
                     (refbox-csl-locale-file))
                   :type 'user-error)))))

(ert-deftest refbox-test-csl-locale-resolution_accepts_locale_ids ()
  "CSL locale lookup should accept common locale ids."
  (let* ((root (make-temp-file "refbox-locale-" t))
         (locale-dir (expand-file-name "locales" root))
         (locale-file (expand-file-name "locales-en-US.xml" locale-dir)))
    (unwind-protect
        (progn
          (make-directory locale-dir t)
          (with-temp-file locale-file
            (insert "<locale></locale>"))
          (let ((refbox-csl-locale-directories (list locale-dir))
                (refbox-csl-locale "en-US"))
            (should (equal (refbox-csl-locale-file) locale-file))))
      (delete-directory root t))))

(ert-deftest refbox-test-read-references_repeats_bounded_single_reads ()
  "Multiple selection should be a sequence of bounded single-reference reads."
  (let ((remaining (list refbox-test-reference-candidate
                         (plist-put (copy-sequence refbox-test-reference-candidate)
                                    :key "doe2021")
                         nil))
        calls)
    (cl-letf (((symbol-function 'refbox--read-reference)
               (lambda (&rest args)
                 (push args calls)
                 (pop remaining))))
      (let ((selected (refbox-read-references "Reference: " "alpha" 5)))
        (should (equal (mapcar (lambda (candidate)
                                 (plist-get candidate :key))
                               selected)
                       '("smith2020" "doe2021")))
        (should (= (length calls) 3))
        (should (equal (nth 1 (car (last calls))) "alpha"))))))

(ert-deftest refbox-test-ensure-restarts-on-configuration-change ()
  "Connection-relevant configuration changes should force reconnection."
  (let* ((root (make-temp-file "refbox-root-" t))
         (program (or (executable-find "true")
                      (executable-find "sh")))
         (db (expand-file-name "refbox.sqlite" root))
         (refbox-server-program program)
         (refbox-bibliography-roots (list root))
         (refbox-database-file db)
         (refbox--connection 'old-connection)
         (refbox--connection-configuration
          (list :program program :root root :db "/tmp/old.sqlite"))
         restarted)
    (unwind-protect
        (cl-letf (((symbol-function 'jsonrpc-running-p)
                   (lambda (connection)
                     (eq connection 'old-connection)))
                  ((symbol-function 'refbox-rpc-shutdown)
                   (lambda ()
                     (setq restarted t
                           refbox--connection nil
                           refbox--connection-configuration nil)))
                  ((symbol-function 'make-instance)
                   (lambda (&rest _args)
                     'new-connection)))
          (should (eq (refbox-rpc-ensure) 'new-connection))
          (should restarted)
          (should (equal refbox--connection 'new-connection)))
      (delete-directory root t))))

(let ((org-tests (expand-file-name
                  "test-refbox-org.el"
                  (file-name-directory (or load-file-name buffer-file-name)))))
  (when (file-exists-p org-tests)
    (load org-tests nil t)))

(let ((latex-tests (expand-file-name
                    "test-refbox-latex.el"
                    (file-name-directory (or load-file-name buffer-file-name)))))
  (when (file-exists-p latex-tests)
    (load latex-tests nil t)))

(let ((markdown-tests (expand-file-name
                       "test-refbox-markdown.el"
                       (file-name-directory (or load-file-name buffer-file-name)))))
  (when (file-exists-p markdown-tests)
    (load markdown-tests nil t)))

(let ((embark-tests (expand-file-name
                     "test-refbox-embark.el"
                     (file-name-directory (or load-file-name buffer-file-name)))))
  (when (file-exists-p embark-tests)
    (load embark-tests nil t)))

(provide 'test-refbox)

;;; test-refbox.el ends here
