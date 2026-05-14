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

(ert-deftest refbox-test-autosync-mode-toggles-hooks-and-advices ()
  "Autosync mode should own only its explicit lifecycle hooks."
  (let ((refbox-autosync-sync-on-enable nil)
        (refbox-bibliography-roots (list temporary-file-directory)))
    (unwind-protect
        (progn
          (refbox-autosync-mode -1)
          (should-not (memq #'refbox--autosync-setup-file-h find-file-hook))
          (refbox-autosync-mode 1)
          (should (memq #'refbox--autosync-setup-file-h find-file-hook))
          (should (advice-member-p #'refbox--autosync-rename-file-a
                                   #'rename-file))
          (should (advice-member-p #'refbox--autosync-delete-file-a
                                   #'delete-file))
          (should (advice-member-p #'refbox--autosync-delete-file-a
                                   #'vc-delete-file)))
      (refbox-autosync-mode -1))))

(ert-deftest refbox-test-autosync-mode-syncs-on-enable ()
  "Autosync startup should catch on-disk changes through a full sync."
  (let ((refbox-autosync-sync-on-enable t)
        (refbox-bibliography-roots (list temporary-file-directory))
        calls)
    (unwind-protect
        (cl-letf (((symbol-function 'refbox-rpc-request)
                   (lambda (method &optional params)
                     (push (list method params) calls)
                     '(:changed_file_count 0 :removed_file_count 0
                       :indexed_entry_count 0))))
          (refbox-autosync-mode -1)
          (refbox-autosync-mode 1)
          (should (equal (nreverse calls)
                         (list (list refbox-rpc-method-sync-full nil)))))
      (refbox-autosync-mode -1))))

(ert-deftest refbox-test-autosync-mode-syncs-on-save ()
  "Saving a tracked bibliography buffer should update that file."
  (let* ((root (make-temp-file "refbox-root-" t))
         (file (expand-file-name "refs/main.bib" root))
         (refbox-autosync-sync-on-enable nil)
         (refbox-bibliography-roots (list root))
         (refbox-bibliography-extensions '("bib"))
         calls)
    (unwind-protect
        (progn
          (make-directory (file-name-directory file) t)
          (with-temp-file file
            (insert "@article{alpha, title = {Alpha}}\n"))
          (cl-letf (((symbol-function 'refbox-rpc-request)
                     (lambda (method &optional params)
                       (push (list method params) calls)
                       '(:changed_file_count 1 :removed_file_count 0
                         :indexed_entry_count 1))))
            (refbox-autosync-mode -1)
            (refbox-autosync-mode 1)
            (let ((buffer (find-file-noselect file)))
              (unwind-protect
                  (with-current-buffer buffer
                    (should (memq #'refbox--autosync-after-save-h
                                  after-save-hook))
                    (goto-char (point-max))
                    (insert "@article{beta, title = {Beta}}\n")
                    (save-buffer))
                (kill-buffer buffer)))))
      (refbox-autosync-mode -1)
      (delete-directory root t))
    (should (equal (nreverse calls)
                   (list (list refbox-rpc-method-sync-file
                               (list :path file)))))))

(ert-deftest refbox-test-autosync-mode-syncs-renames-and-deletes ()
  "Renaming or deleting a tracked bibliography file should update the index."
  (let* ((root (make-temp-file "refbox-root-" t))
         (old-file (expand-file-name "refs/old.bib" root))
         (new-file (expand-file-name "refs/new.bib" root))
         (refbox-autosync-sync-on-enable nil)
         (refbox-bibliography-roots (list root))
         (refbox-bibliography-extensions '("bib"))
         calls)
    (unwind-protect
        (progn
          (make-directory (file-name-directory old-file) t)
          (with-temp-file old-file
            (insert "@article{alpha, title = {Alpha}}\n"))
          (cl-letf (((symbol-function 'refbox-rpc-request)
                     (lambda (method &optional params)
                       (push (list method params) calls)
                       '(:changed_file_count 1 :removed_file_count 0
                         :indexed_entry_count 1))))
            (refbox-autosync-mode -1)
            (refbox-autosync-mode 1)
            (rename-file old-file new-file)
            (delete-file new-file)))
      (refbox-autosync-mode -1)
      (delete-directory root t))
    (should (equal (nreverse calls)
                   (list (list refbox-rpc-method-sync-file
                               (list :path old-file))
                         (list refbox-rpc-method-sync-file
                               (list :path new-file))
                         (list refbox-rpc-method-sync-file
                               (list :path new-file)))))))

(ert-deftest refbox-test-sync-current-file-saves-before-sync ()
  "Explicit current-file sync should write pending buffer changes first."
  (let* ((root (make-temp-file "refbox-root-" t))
         (file (expand-file-name "main.bib" root))
         calls
         saved-contents)
    (unwind-protect
        (progn
          (with-temp-file file
            (insert "@article{alpha, title = {Alpha}}\n"))
          (let ((buffer (find-file-noselect file)))
            (unwind-protect
                (with-current-buffer buffer
                  (goto-char (point-max))
                  (insert "@article{beta, title = {Beta}}\n")
                  (should (buffer-modified-p))
                  (cl-letf (((symbol-function 'refbox-rpc-request)
                             (lambda (method &optional params)
                               (push (list method params) calls)
                               '(:changed_file_count 1 :removed_file_count 0
                                 :indexed_entry_count 2))))
                    (refbox-sync-current-file))
                  (should-not (buffer-modified-p)))
              (kill-buffer buffer)))
          (with-temp-buffer
            (insert-file-contents file)
            (setq saved-contents (buffer-string))))
      (delete-directory root t))
    (should (equal (nreverse calls)
                   (list (list refbox-rpc-method-sync-file
                               (list :path file)))))
    (should (string-match-p "beta" saved-contents))))

(ert-deftest refbox-test-read-reference-syncs-modified-current-bibliography ()
  "Reference reads should save and sync a modified bibliography buffer first."
  (let* ((root (make-temp-file "refbox-root-" t))
         (file (expand-file-name "main.bib" root))
         (refbox-bibliography-roots (list root))
         (refbox-bibliography-extensions '("bib"))
         calls
         saved-contents)
    (unwind-protect
        (progn
          (with-temp-file file
            (insert "@article{alpha, title = {Alpha}}\n"))
          (let ((buffer (find-file-noselect file)))
            (unwind-protect
                (with-current-buffer buffer
                  (goto-char (point-max))
                  (insert "@article{beta, title = {Beta}}\n")
                  (should (buffer-modified-p))
                  (cl-letf (((symbol-function 'refbox-rpc-request)
                             (lambda (method &optional params)
                               (push (list method params) calls)
                               '(:changed_file_count 1 :removed_file_count 0
                                 :indexed_entry_count 2)))
                            ((symbol-function 'completing-read)
                             (lambda (&rest _args) "")))
                    (should-not
                     (refbox--read-reference "Reference: " nil 5 t)))
                  (should-not (buffer-modified-p)))
              (kill-buffer buffer)))
          (with-temp-buffer
            (insert-file-contents file)
            (setq saved-contents (buffer-string))))
      (delete-directory root t))
    (should (equal (nreverse calls)
                   (list (list refbox-rpc-method-sync-file
                               (list :path file)))))
    (should (string-match-p "beta" saved-contents))))

(define-derived-mode refbox-test-mode fundamental-mode "RefboxTest"
  "Temporary mode used by generic refbox command tests.")

(ert-deftest refbox-test-generic_commands_dispatch_through_major_mode_adapters ()
  "Generic commands should use the configured major-mode adapter surface."
  (let (default-action-refs)
    (cl-letf (((symbol-function 'refbox-test-insert-keys)
               (lambda (keys)
                 (insert (string-join keys "|"))))
              ((symbol-function 'refbox-test-key-at-point)
               (lambda () nil))
              ((symbol-function 'refbox-test-citation-at-point)
               (lambda () (list :keys ["alpha" "beta"])))
              ((symbol-function 'refbox-test-insert-citation)
               (lambda (keys arg)
                 (insert (format "%s/%s" (string-join keys "|") arg))))
              ((symbol-function 'refbox-test-insert-edit)
               (lambda (arg)
                 (insert (format "edit/%s" arg))))
              ((symbol-function 'refbox-read-references)
               (lambda (&rest _args)
                 (list (list :key "alpha")
                       (list :key "beta")))))
      (let ((refbox-major-mode-functions
             '(((refbox-test-mode) .
                ((insert-keys . refbox-test-insert-keys)
                 (insert-citation . refbox-test-insert-citation)
                 (insert-edit . refbox-test-insert-edit)
                 (key-at-point . refbox-test-key-at-point)
                 (citation-at-point . refbox-test-citation-at-point))))))
        (with-temp-buffer
          (refbox-test-mode)
          (refbox-insert-keys)
          (should (equal (buffer-string) "alpha|beta"))
          (erase-buffer)
          (refbox-insert-citation '("gamma" "delta") 'style)
          (should (equal (buffer-string) "gamma|delta/style"))
          (erase-buffer)
          (refbox-insert-edit 'arg)
          (should (equal (buffer-string) "edit/arg"))
          (let ((refbox-default-action
                 (lambda (references)
                   (setq default-action-refs references))))
            (refbox-dwim)
            (should (equal default-action-refs '("alpha" "beta")))))))))

(ert-deftest refbox-test-dwim_boolean_fallback_prompts_for_references ()
  "A non-nil at-point fallback should prompt before the default action."
  (let (default-action-refs)
    (cl-letf (((symbol-function 'refbox-key-at-point)
               (lambda () nil))
              ((symbol-function 'refbox-citation-at-point)
               (lambda () nil))
              ((symbol-function 'refbox-read-references)
               (lambda (&rest _args)
                 (list (list :key "alpha")))))
      (let ((refbox-at-point-fallback t)
            (refbox-default-action
             (lambda (references)
               (setq default-action-refs references))))
        (refbox-dwim)
        (should (equal (mapcar (lambda (reference)
                                 (plist-get reference :key))
                               default-action-refs)
                       '("alpha")))))))

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
  (let ((refbox-templates
         '((preview . "%{source_path}")
           (note . "%{title}"))))
    (should
     (equal (refbox-reference-format-note refbox-test-reference-candidate)
            "Alpha Reference Title"))
    (should
     (string-match-p
      "refs/main\\.bib"
      (refbox-reference-format-preview refbox-test-reference-candidate)))))

(ert-deftest refbox-test-template-formatting-caches_parsed_templates ()
  "Repeated formatting should reuse parsed template forms."
  (clrhash refbox-template--parse-cache)
  (let ((parse-count 0)
        (parser (symbol-function 'refbox-template-parse)))
    (cl-letf (((symbol-function 'refbox-template-parse)
               (lambda (template)
                 (setq parse-count (1+ parse-count))
                 (funcall parser template))))
      (dotimes (_ 3)
        (should (equal (refbox-template-format
                        "%{title}"
                        refbox-test-reference-candidate)
                       "Alpha Reference Title")))
      (should (= parse-count 1)))))

(ert-deftest refbox-test-default_templates_use_familiar_fields ()
  "Default templates should render cleaned reference metadata."
  (should (string-match-p
           "Smith[[:space:]]+2020[[:space:]]+Alpha Reference Title"
           (refbox-reference-format-main refbox-test-reference-candidate 100)))
  (should (string-match-p
           "smith2020[[:space:]]+article"
           (refbox-reference-format-suffix refbox-test-reference-candidate))))

(ert-deftest refbox-test-template-formatting-supports_configured_ellipsis ()
  "Template field truncation should support a configured ellipsis marker."
  (let ((refbox-ellipsis "..."))
    (should (equal (refbox-template-format
                    "%{title:10!refbox-template-clean}"
                    refbox-test-reference-candidate)
                   "Alpha R..."))))

(ert-deftest refbox-test-template-formatting-supports_display_placeholders ()
  "Templates should support familiar ${field:width%transform} placeholders."
  (let ((candidate
         (append
          (list :key "alpha"
                :entry_type "article"
                :fields '((:lookup_name "author"
                            :value "Smith, Jane and Doe, John and Public, Ann and Roe, Richard")
                           (:lookup_name "year" :value "2020")
                           (:lookup_name "title" :value "Alpha Reference Title"))
                :resources nil)
          nil)))
    (should (equal (refbox-template-format
                    "${author editor:%etal} (${year date}) ${title:5}"
                    candidate)
                   "Smith, Doe & Public et al. (2020) Alpha"))
    (should (equal (refbox-get-display-value
                    '("author")
                    (refbox-reference-entry-alist candidate)
                    '(refbox--shorten-names 1))
                   "Smith et al."))))

(ert-deftest refbox-test-template-formatting_supports_template_alist ()
  "Template alists should configure the standard reference display slots."
  (let ((refbox-templates
         '((main . "%{key}")
           (suffix . "%{entry_type}")
           (preview . "%{title!refbox-template-clean}")
           (note . "%{author!refbox-template-clean}"))))
    (should (equal (refbox-reference-format-main
                    refbox-test-reference-candidate)
                   "smith2020"))
    (should (equal (refbox-reference-format-suffix
                    refbox-test-reference-candidate)
                   "article"))
    (should (equal (refbox-reference-format-preview
                    refbox-test-reference-candidate)
                   "Alpha Reference Title"))
    (should (equal (refbox-reference-format-note
                    refbox-test-reference-candidate)
                   "Smith, Jane"))))

(ert-deftest refbox-test-completion-candidates-carry_metadata ()
  "Completion candidates should come from bounded RPC search and carry metadata."
  (let ((refbox-templates
         '((main . "%{key} %{title}")
           (suffix . "%{indicators} %{entry_type} %{source_path!file-name-nondirectory}")))
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
             (affixation (car (refbox--completion-affixation
                               (list candidate-string)))))
        (let ((params (cadar calls)))
          (should (equal (plist-get params :query) "alpha"))
          (should (equal (plist-get params :limit) 7))
          (should (equal (plist-get params :ranked) :json-false))
          (should (equal (plist-get params :field_value_char_limit)
                         refbox-completion-field-value-limit))
          (should (equal (append (plist-get params :field_names) nil)
                         '("key" "title" "indicators"
                           "entry_type" "source_path" "crossref")))
          (should (eq (plist-get params :include_resources) :json-false)))
        (should (string-match-p "smith2020" candidate-string))
        (should (equal (plist-get candidate :key) "smith2020"))
        (should (string-match-p
                 "F L +article main\\.bib"
                 candidate-string))
        (should (string-match-p
                 "F L"
                 (nth 1 affixation)))
        (should (string-empty-p (nth 2 affixation)))))))

(ert-deftest refbox-test-completion-uses_completion_limit_by_default ()
  "Minibuffer completion should request the configured completion page size."
  (let ((refbox-completion-limit 87)
        calls)
    (cl-letf (((symbol-function 'refbox-rpc-request)
               (lambda (method params)
                 (push (list method params) calls)
                 (should (equal method refbox-rpc-method-search-entries))
                 (list :entries nil))))
      (let* ((state (refbox--completion-state))
             (table (refbox--completion-table state)))
        (funcall table "alpha" nil t)
        (should (equal (plist-get (cadar calls) :limit) 87))))))

(ert-deftest refbox-test-completion-delegates_visible_text_to_completion_styles ()
  "The minibuffer table should let completion styles filter display strings."
  (let ((refbox-templates '((main . "%{key} %{title}")))
        (completion-styles '(substring basic)))
    (cl-letf (((symbol-function 'refbox-search-references)
               (lambda (_query &optional _limit _source-paths _unranked
                              _field-names _omit-resources)
                 (list refbox-test-reference-candidate
                       (plist-put
                        (copy-tree refbox-test-reference-candidate)
                        :key "doe2021")))))
      (let* ((state (refbox--completion-state 10))
             (table (refbox--completion-table state))
             (candidates (funcall table "doe" nil t)))
        (should (= (length candidates) 1))
        (should (string-match-p "doe2021" (car candidates)))))))

(ert-deftest refbox-test-completion-search-input-omits_negated_components ()
  "Daemon completion search should not require Orderless negated components."
  (should (equal (refbox--completion-search-input "alpha !beta gamma")
                 "alpha gamma")))

(ert-deftest refbox-test-read-reference-keeps_selection_map_after_final_probe ()
  "Final completion probes should not erase the selected candidate mapping."
  (let ((refbox-templates '((main . "%{author:30}     %{date:4}     %{title:48}")
                            (suffix . "%{=key=:15} %{=type=:12}")))
        selected-display)
    (cl-letf (((symbol-function 'refbox--sync-current-bibliography-buffer-if-needed)
               #'ignore)
              ((symbol-function 'refbox-search-references)
               (lambda (query &optional _limit _source-paths _unranked
                              _field-names _omit-resources)
                 (if (equal query "xu")
                     (list refbox-test-reference-candidate)
                   nil)))
              ((symbol-function 'completing-read)
               (lambda (_prompt collection &rest _args)
                 (setq selected-display
                       (substring-no-properties
                        (car (funcall collection "xu" nil t))))
                 ;; Some completion UIs probe again with the accepted display
                 ;; string before returning it, which used to clear the only
                 ;; display-to-candidate map.
                 (funcall collection selected-display nil t)
                 selected-display)))
      (let ((selected (refbox--read-reference "Reference: " nil 5 nil)))
        (should (equal (plist-get selected :key) "smith2020"))))))

(ert-deftest refbox-test-completion-caches_cited_indicator_scan ()
  "Cited indicators should scan the current buffer once per completion state."
  (let* ((cited (copy-tree refbox-test-reference-candidate))
         (uncited (plist-put (copy-tree refbox-test-reference-candidate)
                             :key "doe2021"))
         (refbox-templates '((main . "%{key}")
                             (suffix . "%{indicators}")))
         (refbox-indicators
          (list (refbox-indicator-create
                 :symbol "C"
                 :function #'refbox-is-cited
                 :tag "is:cited")))
         (scans 0))
    (cl-letf (((symbol-function 'refbox-current-buffer-citation-keys)
               (lambda (&optional _buffer)
                 (setq scans (1+ scans))
                 '("smith2020")))
              ((symbol-function 'refbox-rpc-request)
               (lambda (method _params)
                 (should (equal method refbox-rpc-method-search-entries))
                 (list :entries (list cited uncited)))))
      (let* ((state (refbox--completion-state 2))
             (table (refbox--completion-table state))
             (candidates (funcall table "" nil t)))
        (should (= scans 1))
        (should (string-match-p
                 "C"
                 (refbox--completion-annotation (car candidates))))
        (should-not (string-match-p
                     "C"
                     (refbox--completion-annotation (cadr candidates))))))))

(ert-deftest refbox-test-completion-skips_expensive_recursive_library_indicators ()
  "Recursive library source indicators should not scan directories cold."
  (let* ((root (make-temp-file "refbox-recursive-library-" t))
         (nested (expand-file-name "nested" root))
         (alpha (expand-file-name "alpha-extra.pdf" nested))
         (beta (expand-file-name "beta.pdf" nested))
         (candidates '((:key "alpha" :fields nil :resources nil)
                       (:key "beta" :fields nil :resources nil)))
         (refbox-templates '((main . "%{key}")
                             (suffix . "%{indicators}")))
         (refbox-indicators
          (list (refbox-indicator-create
                 :symbol "F"
                 :function #'refbox-has-files
                 :tag "has:files")))
         (refbox-library-paths (list root))
         (refbox-library-paths-recursive t)
         (refbox-library-file-extensions '("pdf"))
         (refbox-file-additional-files-separator "-")
         (directory-scans 0)
         (directory-files-original (symbol-function 'directory-files)))
    (unwind-protect
        (progn
          (make-directory nested)
          (with-temp-file alpha)
          (with-temp-file beta)
          (cl-letf (((symbol-function 'directory-files)
                     (lambda (&rest args)
                       (setq directory-scans (1+ directory-scans))
                       (apply directory-files-original args)))
                    ((symbol-function 'directory-files-recursively)
                     (lambda (&rest _args)
                       (error "recursive directory scan should not be used")))
                    ((symbol-function 'refbox-rpc-request)
                     (lambda (method _params)
                       (should (equal method refbox-rpc-method-search-entries))
                       (list :entries candidates))))
            (let* ((state (refbox--completion-state 2))
                   (table (refbox--completion-table state))
                   (rendered (funcall table "alpha" nil t)))
              (should (= directory-scans 0))
              (should (cl-every
                       (lambda (candidate)
                         (not
                          (string-match-p
                           "F"
                           (refbox--completion-annotation candidate))))
                       rendered)))))
      (delete-directory root t))))

(ert-deftest refbox-test-search-tags-use_daemon_resource_filters ()
  "Search tags backed by indexed resources should be sent to the daemon."
  (let (calls)
    (cl-letf (((symbol-function 'refbox-rpc-request)
               (lambda (method params)
                 (push (list method params) calls)
                 (should (equal method refbox-rpc-method-search-entries))
                 (list :entries (list refbox-test-reference-candidate)))))
      (let ((results (refbox-search-references "has:files alpha" 7)))
        (should (equal (plist-get (cadar calls) :query) "alpha"))
        (should (equal (plist-get (cadar calls) :limit) 7))
        (should (equal (plist-get (cadar calls) :resource_kinds)
                       ["file"]))
        (should (equal (plist-get (car results) :key) "smith2020"))))))

(ert-deftest refbox-test-search-empty_query_requests_bounded_page ()
  "Empty searches should ask the daemon for the first bounded page."
  (let (calls)
    (cl-letf (((symbol-function 'refbox-rpc-request)
               (lambda (method params)
                 (push (list method params) calls)
                 (should (equal method refbox-rpc-method-search-entries))
                 (list :entries (list refbox-test-reference-candidate)))))
      (let ((results (refbox-search-references "" 7)))
        (should (equal (cadar calls)
                       (list :query "" :limit 7 :allow_empty_query t)))
        (should (equal (plist-get (car results) :key) "smith2020"))))))

(ert-deftest refbox-test-search_tags_support_emacs_side_predicates ()
  "Search tags backed by local predicates should filter returned candidates."
  (let* ((cited (copy-tree refbox-test-reference-candidate))
         (uncited (plist-put (copy-tree refbox-test-reference-candidate)
                             :key "doe2021"))
         calls)
    (let ((refbox-reference-cited-predicate
           (lambda (candidate)
             (equal (refbox-reference-field candidate "key") "smith2020"))))
      (cl-letf (((symbol-function 'refbox-rpc-request)
                 (lambda (method params)
                   (push (list method params) calls)
                   (should (equal method refbox-rpc-method-search-entries))
                   (list :entries (list cited uncited)))))
        (let ((results (refbox-search-references "is:cited" 5)))
          (should (equal (plist-get (cadar calls) :query) ""))
          (should (equal (plist-get (cadar calls) :limit)
                         refbox-search-maximum-limit))
          (should (equal (plist-get (cadar calls) :allow_empty_query) t))
          (should (equal (mapcar (lambda (candidate)
                                   (plist-get candidate :key))
                                 results)
                         '("smith2020"))))))))

(ert-deftest refbox-test-read-reference-contract-returns_candidate_payload ()
  "The chooser should return candidate metadata, not display strings."
  (let ((refbox-templates '((main . "%{key} %{title}")))
        calls)
    (cl-letf (((symbol-function 'refbox-rpc-request)
               (lambda (method params)
                 (push (list method params) calls)
                 (should (equal method refbox-rpc-method-search-entries))
                 (list :entries (list refbox-test-reference-candidate))))
              ((symbol-function 'completing-read)
               (lambda (_prompt collection &rest _args)
                 (car (all-completions "smith" collection)))))
      (let ((selected (refbox-read-reference "Reference: " "smith" 3)))
        (should (equal (plist-get selected :key) "smith2020"))
        (should (equal (plist-get selected :source_path) "refs/main.bib"))
        (let ((params (cadar calls)))
          (should (equal (plist-get params :query) "smith"))
          (should (equal (plist-get params :limit) 3))
          (should (equal (plist-get params :ranked) :json-false))
          (should (equal (append (plist-get params :field_names) nil)
                         '("key" "title" "crossref"))))))))

(ert-deftest refbox-test-list-references-uses-paged-rpc ()
  "Whole-corpus enumeration should use the daemon's paged list method."
  (let (calls)
    (cl-letf (((symbol-function 'refbox-rpc-request)
               (lambda (method params)
                 (push (list method params) calls)
                 (should (equal method refbox-rpc-method-list-entries))
                 (list :entries (list refbox-test-reference-candidate)))))
      (let ((entries (refbox-list-references 25 50)))
        (should (equal (plist-get (car entries) :key) "smith2020"))
        (should (equal (cadar calls) (list :limit 25 :offset 50)))))))

(ert-deftest refbox-test-entry-field-accessors-return_entry_alists ()
  "Entry lookup helpers should expose field values for extension code."
  (let (calls)
    (cl-letf (((symbol-function 'refbox-rpc-request)
               (lambda (method params)
                 (push (list method params) calls)
                 (cond
                  ((equal method refbox-rpc-method-entry-by-key)
                   (should (equal params (list :key "smith2020")))
                   '(:key "smith2020"
                     :source_path "refs/main.bib"
                     :entry_type "article"))
                  ((equal method refbox-rpc-method-search-entries)
                   (should (equal (plist-get params :source_paths)
                                  (vector (expand-file-name "refs/main.bib"))))
                   (list :entries (list refbox-test-reference-candidate)))))))
      (let ((entry (refbox-get-entry "smith2020")))
        (should (equal (cdr (assoc-string "title" entry t))
                       "{Alpha Reference Title}"))
        (should (equal (refbox-get-value "author" entry) "{Smith, Jane}"))
        (should (equal (refbox-get-value "=key=" entry) "smith2020"))
        (should (equal (refbox-get-field-with-value
                        '("missing" "date")
                        entry)
                       '("date" . "{2020-05-12}")))
        (should (equal (refbox-get-display-value
                        '("title")
                        entry
                        '(refbox-template-clean))
                       "Alpha Reference Title"))))))

(ert-deftest refbox-test-read-reference_accepts_candidate_predicates ()
  "Reference selection should support filtering by candidate metadata."
  (let* ((alpha (copy-tree refbox-test-reference-candidate))
         (beta (plist-put (copy-tree refbox-test-reference-candidate)
                          :key "beta2021")))
    (cl-letf (((symbol-function 'refbox-rpc-request)
               (lambda (_method _params)
                 (list :entries (list alpha beta))))
              ((symbol-function 'completing-read)
               (lambda (_prompt collection predicate &rest _args)
                 (car (all-completions "beta" collection predicate)))))
      (let ((selected
             (refbox-read-reference
              "Reference: "
              "beta"
              5
              (lambda (candidate)
                (equal (plist-get candidate :key) "beta2021")))))
        (should (equal (plist-get selected :key) "beta2021"))))))

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
          (let ((refbox-library-paths (list library))
                (refbox-library-paths-recursive t)
                (refbox-library-file-extensions '("pdf"))
                (refbox-file-additional-files-separator "-"))
            (should
             (equal (mapcar #'file-name-nondirectory
                            (refbox-reference-files
                             candidate
                             (refbox--candidate-resources candidate)))
                    '("paper.pdf" "smith2020.pdf" "smith2020-extra.pdf")))))
      (delete-directory root t))))

(ert-deftest refbox-test-resource_file_sources_are_extensible ()
  "File lookup should dispatch through configured resource sources."
  (let* ((root (make-temp-file "refbox-file-source-" t))
         (external (expand-file-name "external.pdf" root))
         (candidate '(:key "alpha" :resources nil))
         seen-items
         seen-has)
    (unwind-protect
        (progn
          (with-temp-file external)
          (let ((refbox-file-sources
                 `((external
                    :items ,(lambda (reference resources)
                              (setq seen-items (list reference resources))
                              (list external))
                    :hasitems ,(lambda (reference resources)
                                 (setq seen-has (list reference resources))
                                 t)))))
            (should (equal (refbox-reference-files candidate nil)
                           (list external)))
            (should (refbox-reference-has-files-p candidate)))
          (should (equal seen-items (list candidate nil)))
          (should (equal seen-has (list candidate nil))))
      (delete-directory root t))))

(ert-deftest refbox-test-resource_file_sources_fallback_to_items_for_has_files ()
  "File sources without :hasitems should still support indicators."
  (let ((candidate '(:key "alpha" :resources nil))
        called)
    (let ((refbox-file-sources
           `((external
              :items ,(lambda (reference resources)
                        (setq called (list reference resources))
                        '("/tmp/external.pdf"))))))
      (should (refbox-reference-has-files-p candidate)))
    (should (equal called (list candidate nil)))))

(ert-deftest refbox-test-resource_file_sources_reject_invalid_items ()
  "Broken file sources should fail at the source boundary."
  (let ((candidate '(:key "alpha" :resources nil))
        (refbox-file-sources '((broken))))
    (should-error (refbox-reference-files candidate nil) :type 'user-error)))

(ert-deftest refbox-test-resource_file_sources_preserve_indicator_fields ()
  "File source has-items should honor configured indicator field names."
  (let ((candidate
         '(:key "alpha"
           :fields ((:lookup_name "pdf" :value "alpha.pdf"))
           :resources nil))
        (refbox-resource-file-field-names '("file"))
        (refbox-reference-resource-field-names '("pdf")))
    (should (refbox-reference-has-files-p candidate))))

(ert-deftest refbox-test-resource_getters_return_keyed_hash_tables ()
  "Resource getters should expose files, links, and notes by reference key."
  (let* ((root (make-temp-file "refbox-resource-getters-" t))
         (refs (expand-file-name "refs" root))
         (paper (expand-file-name "paper.pdf" refs))
         (candidate
          (list :key "alpha"
                :source_path (expand-file-name "main.bib" refs)
                :fields '((:lookup_name "doi" :value "10.1000/alpha"))
                :resources
                `((:key "alpha"
                   :source_path ,(expand-file-name "main.bib" refs)
                   :owner_key "alpha"
                   :owner_source_path ,(expand-file-name "main.bib" refs)
                   :kind "file"
                   :lookup_name "file"
                   :value ,paper)
                  (:key "alpha"
                   :source_path ,(expand-file-name "main.bib" refs)
                   :owner_key "alpha"
                   :owner_source_path ,(expand-file-name "main.bib" refs)
                   :kind "doi"
                   :lookup_name "doi"
                   :value "10.1000/alpha")))))
    (unwind-protect
        (progn
          (make-directory refs t)
          (with-temp-file paper)
          (let ((refbox-notes-source 'mock)
                (refbox-notes-sources
                 `((mock
                    :items ,(lambda (key _reference)
                              (list (format "note:%s" key)))
                    :open ,#'ignore))))
            (cl-letf (((symbol-function 'refbox-list-references)
                       (lambda (_limit offset)
                         (if (or (null offset) (zerop offset))
                             (list candidate)
                           nil)))
                      ((symbol-function 'refbox-entry-by-key)
                       (lambda (key)
                         (should (equal key "alpha"))
                         candidate)))
              (let ((files (refbox-get-files))
                    (links (refbox-get-links "alpha"))
                    (notes (refbox-get-notes '("alpha" "alpha"))))
                (should (equal (gethash "alpha" files) (list paper)))
                (should (equal (gethash "alpha" links)
                               '("https://doi.org/10.1000/alpha")))
                (should (equal (gethash "alpha" notes) '("note:alpha")))
                (should-not (refbox-get-files nil))
                (should-not (refbox-get-links nil))
                (should-not (refbox-get-notes nil))))))
      (delete-directory root t))))

(ert-deftest refbox-test-resource_predicates_accept_keys_and_candidates ()
  "Resource predicate helpers should work with keys and candidate plists."
  (let* ((candidate (copy-tree refbox-test-reference-candidate))
         (refbox-notes-source 'mock)
         (refbox-notes-sources
          `((mock
             :items ,(lambda (_key _reference)
                       nil)
             :hasitems ,(lambda (key _reference)
                          (equal key "smith2020"))
             :open ,#'ignore))))
    (cl-letf (((symbol-function 'refbox-entry-by-key)
               (lambda (key)
                 (should (equal key "smith2020"))
                 candidate)))
      (should (funcall (refbox-has-files) "smith2020"))
      (should (funcall (refbox-has-files) candidate))
      (should (funcall (refbox-has-links) "smith2020"))
      (should (funcall (refbox-has-links) candidate))
      (should (funcall (refbox-has-notes) "smith2020"))
      (should (funcall (refbox-has-notes) candidate)))
    (with-temp-buffer
      (insert "See smith2020.")
      (should (funcall (refbox-is-cited) "smith2020"))
      (should (funcall (refbox-is-cited) candidate)))))

(ert-deftest refbox-test-local_resource_lookup_uses_crossref_parent_keys ()
  "File lookup should include parent keys declared by cross-reference fields."
  (let* ((root (make-temp-file "refbox-crossref-files-" t))
         (library (expand-file-name "library" root))
         (candidate
          (list :key "child2021"
                :fields '((:raw_name "crossref" :lookup_name "crossref"
                            :value "{parent2020}")))))
    (unwind-protect
        (progn
          (make-directory library t)
          (with-temp-file (expand-file-name "parent2020.pdf" library))
          (let ((refbox-library-paths (list library))
                (refbox-library-file-extensions '("pdf")))
            (should (equal (refbox-reference-crossref-keys candidate)
                           '("parent2020")))
            (should (equal (mapcar #'file-name-nondirectory
                                   (refbox-reference-files
                                    candidate
                                    (refbox--candidate-resources candidate)))
                           '("parent2020.pdf")))
            (cl-letf (((symbol-function 'refbox-rpc-request)
                       (lambda (&rest _args)
                         (error "unexpected RPC"))))
              (should (refbox-reference-has-files-p candidate)))))
      (delete-directory root t))))

(ert-deftest refbox-test-file_variable_participates_in_file_resource_lookup ()
  "The conventional file field variable should be part of file lookup."
  (let ((candidate
         '(:key "alpha"
           :fields ((:lookup_name "pdf" :value "alpha.pdf"))
           :resources nil))
        (refbox-file-variable "pdf")
        (refbox-resource-file-field-names nil)
        (refbox-reference-resource-field-names nil))
    (should (refbox-reference-has-files-p candidate))))

(ert-deftest refbox-test-note-filename-uses-existing-or-default_path ()
  "Note filename generation should prefer existing notes and create stable names."
  (let* ((root (make-temp-file "refbox-notes-" t))
         (existing (expand-file-name "smith2020.org" root)))
    (unwind-protect
        (progn
          (with-temp-file existing)
          (let ((refbox-notes-paths (list root))
                (refbox-file-note-extensions '("org" "md")))
            (should (equal (refbox-note-filename "smith2020") existing))
            (should (equal (refbox-note-filename "doe/2021")
                           (expand-file-name "doe_2021.org" root)))))
      (delete-directory root t))))

(ert-deftest refbox-test-create_note_accepts_key_and_entry ()
  "Note creation should accept an explicit key and entry alist."
  (let (seen)
    (let ((refbox-notes-source 'mock)
          (refbox-notes-sources
           `((mock
              :items ,#'ignore
              :open ,#'ignore
              :create ,(lambda (key reference)
                         (setq seen (list key reference)))))))
      (refbox-create-note
       "alpha"
       '(("title" . "Alpha Reference")
         ("author" . "Smith, Jane")
         ("=type=" . "article"))))
    (should (equal (car seen) "alpha"))
    (should (equal (refbox-reference-field (cadr seen) "title")
                   "Alpha Reference"))
    (should (equal (refbox-reference-field (cadr seen) "entry_type")
                   "article"))))

(ert-deftest refbox-test-file_notes_use_crossref_parent_keys ()
  "File-backed note lookup should include cross-reference parent keys."
  (let* ((root (make-temp-file "refbox-crossref-notes-" t))
         (candidate
          (list :key "child2021"
                :fields '((:raw_name "crossref" :lookup_name "crossref"
                            :value "{parent2020}"))))
         (note (expand-file-name "parent2020.org" root)))
    (unwind-protect
        (progn
          (with-temp-file note)
          (let ((refbox-notes-paths (list root))
                (refbox-file-note-extensions '("org")))
            (should (equal (refbox-note-source-file-items
                            "child2021"
                            candidate)
                           (list note)))
            (should (refbox-note-source-file-has-items
                     "child2021"
                     candidate))))
      (delete-directory root t))))

(ert-deftest refbox-test-note_sources_are_swappable ()
  "Note commands should use the configured note source protocol."
  (let (opened created)
    (let ((refbox-notes-source 'mock)
          (refbox-notes-sources
           `((mock
              :items ,(lambda (key _reference)
                        (list (format "note:%s" key)))
              :all-items ,(lambda ()
                            '("note:all" "note:orphan"))
              :hasitems ,(lambda (key _reference)
                           (equal key "smith2020"))
              :open ,(lambda (item)
                       (push item opened))
              :create ,(lambda (key _reference)
                         (push key created)
                         (format "created:%s" key))
              :create-label ,(lambda (key _reference)
                               (format "new:%s" key))
              :transform ,(lambda (item)
                            (concat "label:" item)))))
          (refbox-open-prompt nil))
      (should (refbox-reference-has-notes-p refbox-test-reference-candidate))
      (should (equal (refbox-create-note refbox-test-reference-candidate)
                     "created:smith2020"))
      (refbox-open-notes refbox-test-reference-candidate)
      (should (equal created '("smith2020")))
      (should (equal opened '("note:smith2020")))
      (cl-letf (((symbol-function 'completing-read)
                 (lambda (_prompt collection &rest _args)
                   (cadr collection))))
        (refbox-open-note))
      (should (equal opened '("note:orphan" "note:smith2020"))))))

(ert-deftest refbox-test-open_notes_accepts_single_note_by_default ()
  "Opening notes should not prompt when only one note is available."
  (let (opened)
    (let ((refbox-notes-source 'mock)
          (refbox-notes-sources
           `((mock
              :items ,(lambda (key _reference)
                        (list (format "note:%s" key)))
              :open ,(lambda (item)
                       (push item opened))
              :create ,#'ignore))))
      (cl-letf (((symbol-function 'completing-read)
                 (lambda (&rest _args)
                   (error "unexpected prompt"))))
        (refbox-open-notes refbox-test-reference-candidate)
        (should (equal opened '("note:smith2020")))))))

(ert-deftest refbox-test-file_note_source_can_list_all_notes ()
  "The file note source should support direct note browsing."
  (let* ((root (make-temp-file "refbox-all-notes-" t))
         (org-note (expand-file-name "alpha.org" root))
         (md-note (expand-file-name "beta.md" root))
         (ignored (expand-file-name "gamma.txt" root)))
    (unwind-protect
        (progn
          (with-temp-file org-note)
          (with-temp-file md-note)
          (with-temp-file ignored)
          (let ((refbox-notes-paths (list root))
                (refbox-file-note-extensions '("org" "md")))
            (should (equal (mapcar #'file-name-nondirectory
                                   (refbox-note-source-file-all-items))
                           '("alpha.org" "beta.md")))))
      (delete-directory root t))))

(ert-deftest refbox-test-note_sources_can_be_registered_and_removed ()
  "Note source registration helpers should update the source table."
  (let ((refbox-notes-sources nil))
    (should (eq (refbox-register-notes-source
                 'mock
                 (list :items #'ignore :open #'ignore :create #'ignore))
                'mock))
    (should (alist-get 'mock refbox-notes-sources))
    (should (eq (refbox-remove-notes-source 'mock) 'mock))
    (should-not (alist-get 'mock refbox-notes-sources))
    (should (eq (refbox-register-notes-source
                 'mock
                 (list :items #'ignore :open #'ignore))
                'mock))
    (should (alist-get 'mock refbox-notes-sources))
    (should (eq (refbox-remove-notes-source 'mock) 'mock))
    (should-not (alist-get 'mock refbox-notes-sources))))

(ert-deftest refbox-test-note_source_registration_validates_config ()
  "Note source registration should reject broken adapters up front."
  (let ((refbox-notes-sources nil))
    (should-error
     (refbox-register-notes-source
      "mock" (list :items #'ignore :open #'ignore))
     :type 'user-error)
    (should-error
     (refbox-register-notes-source 'mock (list :items #'ignore))
     :type 'user-error)
    (should-error
     (refbox-register-notes-source 'mock (list :items #'ignore :open "no"))
     :type 'user-error)
    (should-error
     (refbox-register-notes-source
      'mock (list :name 'bad :items #'ignore :open #'ignore))
     :type 'user-error)
    (let (warnings)
      (cl-letf (((symbol-function 'display-warning)
                 (lambda (type message &rest _args)
                   (push (list type message) warnings))))
        (should (eq (refbox-register-notes-source
                     'mock
                     (list :items #'ignore :open #'ignore :extra t))
                    'mock)))
      (should (alist-get 'mock refbox-notes-sources))
      (should (equal (caar warnings) 'refbox))
      (should (string-match-p "unknown property" (cadar warnings))))))

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
                (refbox-file-open-functions
                 `((t . ,(lambda (target)
                           (push (cons 'file target) opened)))))
                (refbox-link-open-function
                 (lambda (target) (push (cons 'link target) opened)))
                (refbox-open-note-function
                 (lambda (target) (push (cons 'note target) opened)))
                (refbox-notes-paths (list root))
                (refbox-file-note-extensions '("org")))
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

(ert-deftest refbox-test-file_openers_default_html_to_external_opener ()
  "HTML resources should use the external file opener by default."
  (let ((opened nil))
    (cl-letf (((symbol-function 'refbox-file-open-external)
               (lambda (file)
                 (setq opened file)
                 file)))
      (should (equal (refbox-file-open "/tmp/refbox-test.html")
                     "/tmp/refbox-test.html"))
      (should (equal opened "/tmp/refbox-test.html")))))

(ert-deftest refbox-test-file_openers_require_matching_dispatch ()
  "File opening should fail when no extension or default opener matches."
  (let ((refbox-file-open-functions nil))
    (should-error (refbox-file-open "/tmp/refbox-test.pdf")
                  :type 'user-error)))

(ert-deftest refbox-test-open_without_note_paths_does_not_offer_uncreatable_notes ()
  "Resource opening should not fail while building unavailable note choices."
  (let ((candidate '(:key "empty2020" :fields nil :resources nil))
        (refbox-notes-paths nil)
        (refbox-open-resources '(:create-notes)))
    (cl-letf (((symbol-function 'refbox-reference-resources)
               (lambda (_candidate) nil)))
      (should-error (refbox-open candidate) :type 'user-error))))

(ert-deftest refbox-test-file_openers_support_extension_overrides_and_attachments ()
  "File resources should support extension-specific openers and MIME attach."
  (let* ((root (make-temp-file "refbox-file-openers-" t))
         (pdf (expand-file-name "paper.pdf" root))
         (html (expand-file-name "paper.html" root))
         opened
         attached)
    (unwind-protect
        (progn
          (dolist (file (list pdf html))
            (with-temp-file file))
          (let ((candidate (copy-tree refbox-test-reference-candidate))
                (refbox-file-open-functions
                 `(("html" . ,(lambda (target)
                                (push (cons 'html target) opened)))
                   (t . ,(lambda (target)
                           (push (cons 'default target) opened)))))
                (refbox-open-prompt nil))
            (setq candidate
                  (plist-put candidate :resources
                             (list (list :kind "file" :lookup_name "file"
                                         :value html
                                         :owner_source_path
                                         (expand-file-name "main.bib" root)))))
            (cl-letf (((symbol-function 'refbox-reference-resources)
                       (lambda (_candidate)
                         (refbox--candidate-resources candidate)))
                      ((symbol-function 'mml-attach-file)
                       (lambda (file &rest _args)
                         (push file attached))))
              (refbox-open-files candidate)
              (setq candidate
                    (plist-put candidate :resources
                               (list (list :kind "file" :lookup_name "file"
                                           :value pdf
                                           :owner_source_path
                                           (expand-file-name "main.bib" root)))))
              (refbox-attach-files candidate)))
          (should (member (cons 'html html) opened))
          (should (equal attached (list pdf))))
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
                         :source (:start (:line 2 :column 3))))))
            (refbox-open-source "alpha")
            (should (equal (buffer-file-name) source-file))
            (should (= (line-number-at-pos) 2))
            (should (= (current-column) 2))))
      (when-let ((buffer (find-buffer-visiting source-file)))
        (kill-buffer buffer))
      (delete-directory root t))))

(ert-deftest refbox-test-open-entry_uses_indexed_source_location ()
  "Entry opening should use the same source navigation as source opening."
  (let (opened)
    (cl-letf (((symbol-function 'refbox-open-source)
               (lambda (reference)
                 (setq opened reference)
                 :opened)))
      (should (eq (refbox-open-entry "alpha") :opened))
      (should (equal opened "alpha")))))

(ert-deftest refbox-test-open-entry_uses_configured_function ()
  "Entry opening should be customizable at the command level."
  (let (opened)
    (let ((refbox-open-entry-function
           (lambda (reference)
             (setq opened reference)
             :opened)))
      (should (eq (refbox-open-entry "alpha") :opened))
      (should (equal opened "alpha")))))

(ert-deftest refbox-test-open_in_zotero_uses_citation_key_url ()
  "Zotero opening should use the selected citation key."
  (let (opened)
    (let ((refbox-zotero-open-function
           (lambda (url)
             (push url opened))))
      (refbox-open-in-zotero refbox-test-reference-candidate)
      (should (equal opened
                     '("zotero://select/items/@smith2020"))))))

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

(ert-deftest refbox-test-insert-bibtex-removes-configured_fields ()
  "BibTeX insertion should omit fields configured for export removal."
  (let ((raw "@article{alpha,\n  title = {Alpha},\n  file = {alpha.pdf},\n  doi = {10.1000/alpha}\n}"))
    (with-temp-buffer
      (let ((refbox-bibtex-no-export-fields '("file")))
        (cl-letf (((symbol-function 'refbox-rpc-request)
                   (lambda (_method _params)
                     (list :raw raw))))
          (refbox-insert-bibtex '("alpha"))))
      (should (string-match-p "title = {Alpha}" (buffer-string)))
      (should (string-match-p "doi = {10.1000/alpha}" (buffer-string)))
      (should-not (string-match-p "file = " (buffer-string))))))

(ert-deftest refbox-test-export-bibliography-removes-configured_fields ()
  "Local bibliography export should remove configured no-export fields."
  (let* ((root (make-temp-file "refbox-export-" t))
         (output (expand-file-name "local.bib" root))
         (raw "@article{alpha,\n  title = {Alpha},\n  file = {alpha.pdf},\n  doi = {10.1000/alpha}\n}"))
    (unwind-protect
        (let ((refbox-bibtex-no-export-fields '("file")))
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

(ert-deftest refbox-test-export-local-bibliography_uses_buffer_directory ()
  "Local bibliography export should use the conventional local-bib name."
  (let* ((root (make-temp-file "refbox-local-export-" t))
         (output (expand-file-name "local-bib.bib" root))
         (raw "@article{alpha,\n  title = {Alpha}\n}"))
    (unwind-protect
        (let ((refbox-bibliography '("main.bib")))
          (with-temp-buffer
            (setq buffer-file-name (expand-file-name "paper.org" root))
            (cl-letf (((symbol-function 'refbox-current-buffer-citation-keys)
                       (lambda (&optional _buffer)
                         '("alpha")))
                      ((symbol-function 'refbox-rpc-request)
                       (lambda (_method _params)
                         (list :raw raw))))
              (should (equal (refbox-export-local-bibliography) output))))
          (with-temp-buffer
            (insert-file-contents output)
            (should (string-match-p "@article{alpha" (buffer-string)))))
      (delete-directory root t))))

(ert-deftest refbox-test-export-local-bib-file_uses_local_bibliography_export ()
  "The local bib-file command should use the same export path."
  (let (exported)
    (cl-letf (((symbol-function 'refbox-export-local-bibliography)
               (lambda (&optional file)
                 (setq exported file)
                 :exported)))
      (should (eq (refbox-export-local-bib-file "paper-local.bib") :exported))
      (should (equal exported "paper-local.bib")))))

(ert-deftest refbox-test-add-file-to-library_sources ()
  "Library add helpers should cover buffer, file, and URL-style sources."
  (let* ((root (make-temp-file "refbox-library-" t))
         (library (expand-file-name "library" root))
         (source (expand-file-name "source.pdf" root)))
    (unwind-protect
        (let ((refbox-library-paths (list library)))
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

(ert-deftest refbox-test-add-file-to-library_uses_configured_sources ()
  "The interactive add-file command should dispatch through configured sources."
  (let* ((root (make-temp-file "refbox-custom-source-" t))
         (library (expand-file-name "library" root))
         called)
    (unwind-protect
        (let ((refbox-library-paths (list library))
              (refbox-add-file-sources
               `((?c "custom" "Use a test source"
                  ,(lambda (reference)
                     (setq called reference)
                     (list :extension "pdf"
                           :write-file
                           (lambda (destination _overwrite)
                             (with-temp-file destination
                               (insert "custom-pdf")))))))))
          (cl-letf (((symbol-function 'read-multiple-choice)
                     (lambda (_prompt choices)
                       (car choices))))
            (should (equal (refbox-add-file-to-library "alpha")
                           (expand-file-name "alpha.pdf" library))))
          (with-temp-buffer
            (insert-file-contents (expand-file-name "alpha.pdf" library))
            (should (equal (buffer-string) "custom-pdf"))))
      (delete-directory root t))
    (should (equal called "alpha"))))

(ert-deftest refbox-test-add-file-to-library_default_buffer_source ()
  "The default buffer source should pass through the configured writer."
  (let* ((root (make-temp-file "refbox-default-source-" t))
         (library (expand-file-name "library" root)))
    (unwind-protect
        (let ((refbox-library-paths (list library)))
          (with-temp-buffer
            (insert "buffer-pdf")
            (cl-letf (((symbol-function 'read-multiple-choice)
                       (lambda (_prompt choices)
                         (car choices)))
                      ((symbol-function 'read-buffer)
                       (lambda (&rest _args)
                         (buffer-name)))
                      ((symbol-function 'read-string)
                       (lambda (&rest _args)
                         "pdf")))
              (should (equal (refbox-add-file-to-library "alpha")
                             (expand-file-name "alpha.pdf" library)))))
          (with-temp-buffer
            (insert-file-contents (expand-file-name "alpha.pdf" library))
            (should (equal (buffer-string) "buffer-pdf"))))
      (delete-directory root t))))

(ert-deftest refbox-test-add-file-to-library_uses_configured_writer ()
  "The interactive add-file command should dispatch through the configured writer."
  (let (called)
    (let ((refbox-add-file-sources
           `((?c "custom" "Use a test source"
              ,(lambda (_reference)
                 (list :extension "pdf"
                       :write-file #'ignore)))))
          (refbox-add-file-function
           (lambda (reference source)
             (setq called (list reference source))
             "custom-destination")))
      (cl-letf (((symbol-function 'read-multiple-choice)
                 (lambda (_prompt choices)
                   (car choices))))
        (should (equal (refbox-add-file-to-library "alpha")
                       "custom-destination"))))
    (should (equal (car called) "alpha"))
    (should (equal (plist-get (cadr called) :extension) "pdf"))))

(ert-deftest refbox-test-add-file-to-library_rejects_empty_sources ()
  "The interactive add-file command should fail at the source boundary."
  (let ((refbox-add-file-sources nil))
    (should-error (refbox-add-file-to-library "alpha") :type 'user-error)))

(ert-deftest refbox-test-add-file-to-library_rejects_invalid_writer ()
  "The interactive add-file command should fail on invalid writer config."
  (let ((refbox-add-file-function nil))
    (should-error (refbox-add-file-to-library "alpha") :type 'user-error)))

(ert-deftest refbox-test-add-file-to-library_prompts_for_multiple_directories ()
  "Library add helpers should let users choose among configured directories."
  (let* ((root (make-temp-file "refbox-library-choice-" t))
         (library-a (expand-file-name "library-a" root))
         (library-b (expand-file-name "library-b" root)))
    (unwind-protect
        (let ((refbox-library-paths (list library-a library-b)))
          (cl-letf (((symbol-function 'completing-read)
                     (lambda (_prompt collection &rest _args)
                       (cadr collection))))
            (with-temp-buffer
              (insert "buffer-pdf")
              (should (equal (refbox-add-buffer-to-library "alpha" "pdf")
                             (expand-file-name "alpha.pdf" library-b)))))
          (should-not (file-exists-p (expand-file-name "alpha.pdf" library-a)))
          (should (file-exists-p (expand-file-name "alpha.pdf" library-b))))
      (delete-directory root t))))

(ert-deftest refbox-test-add-buffer-to-library_confirms_before_overwrite ()
  "Buffer-backed library saves should confirm before replacing files."
  (let* ((root (make-temp-file "refbox-library-overwrite-" t))
         (library (expand-file-name "library" root))
         (destination (expand-file-name "alpha.pdf" library)))
    (unwind-protect
        (let ((refbox-library-paths (list library)))
          (make-directory library t)
          (with-temp-file destination
            (insert "old"))
          (cl-letf (((symbol-function 'yes-or-no-p)
                     (lambda (_prompt) t)))
            (with-temp-buffer
              (insert "new")
              (should (equal (refbox-add-buffer-to-library "alpha" "pdf" 1)
                             destination))))
          (with-temp-buffer
            (insert-file-contents destination)
            (should (equal (buffer-string) "new"))))
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
          (should (equal (refbox-citeproc-csl-metadata style-file)
                         (list :file style-file
                               :id "http://www.zotero.org/styles/apa-test"
                               :title "APA Test")))
          (let ((refbox-citeproc-csl-styles-dir (list style-dir))
                refbox-citeproc-csl-style)
            (cl-letf (((symbol-function 'completing-read)
                       (lambda (_prompt collection &rest _args)
                         (car (all-completions "" collection)))))
              (should (equal (refbox-citeproc-select-csl-style) style-file))
              (should (equal refbox-citeproc-csl-style style-file))))
          (let ((refbox-citeproc-csl-styles-dir (list style-dir))
                (refbox-citeproc-csl-style "http://www.zotero.org/styles/apa-test"))
            (should (equal (refbox-csl--style-file) style-file))))
      (delete-directory root t))))

(ert-deftest refbox-test-format-reference-default_uses_preview_template ()
  "Default reference formatting should use the configured preview template."
  (let ((refbox-templates
         '((preview . "${author:%sn} (${year}) ${title}")))
        (candidate
         '(:key "alpha"
           :entry_type "article"
           :fields ((:lookup_name "author" :value "Smith, Jane")
                    (:lookup_name "year" :value "2020")
                    (:lookup_name "title" :value "Alpha Reference"))
           :resources nil)))
    (should (equal (refbox-format-references (list candidate))
                   '("Smith (2020) Alpha Reference")))
    (should (equal (refbox-format-reference (list candidate))
                   "Smith (2020) Alpha Reference"))))

(ert-deftest refbox-test-citeproc-format-reference-uses-daemon-and-csl_configuration ()
  "CSL reference formatting should call the daemon with selected style and locale."
  (let* ((root (make-temp-file "refbox-format-" t))
         (style (expand-file-name "style.csl" root))
         (locale (expand-file-name "locales-en-US.xml" root))
         calls)
    (unwind-protect
        (progn
          (with-temp-file style)
          (with-temp-file locale)
          (let ((refbox-citeproc-csl-style style)
                (refbox-citeproc-csl-locale locale))
            (cl-letf (((symbol-function 'refbox-rpc-request)
                       (lambda (method params)
                         (push (list method params) calls)
                         (list :references
                               (list (list :key "alpha"
                                           :text "Formatted Alpha")
                                     (list :key "beta"
                                           :text "Formatted Beta"))))))
	              (should (equal (refbox-citeproc--format-references
                                   '("alpha" "beta"))
	                             '("Formatted Alpha" "Formatted Beta")))
	              (should (equal (refbox-citeproc-format-reference
                                   '("alpha" "beta"))
	                             "Formatted Alpha\n\nFormatted Beta"))))
          (should (equal (caar calls) refbox-rpc-method-format-references))
          (should (equal (cadar calls)
                         (list :keys ["alpha" "beta"]
                               :style_path style
                               :locale_path locale))))
      (delete-directory root t))))

(ert-deftest refbox-test-insert-and-copy-formatted_references ()
  "Insert and copy commands should use formatted reference text."
  (let ((refbox-format-reference-function
         (lambda (_references)
           "Alpha Reference\n\nBeta Reference")))
      (with-temp-buffer
        (refbox-insert-reference '("alpha" "beta"))
        (should (equal (buffer-string)
                       "Alpha Reference\n\nBeta Reference")))
      (should (equal (refbox-copy-reference '("alpha" "beta"))
                     "Alpha Reference\n\nBeta Reference"))
      (should (equal (current-kill 0) "Alpha Reference\n\nBeta Reference"))))

(ert-deftest refbox-test-formatting_configuration_errors_are_actionable ()
  "Missing style and locale configuration should fail directly."
  (should
   (string-match-p
    "refbox-citeproc-csl-style"
    (error-message-string
     (should-error (let ((refbox-citeproc-csl-style nil))
                     (refbox-csl--style-file))
                   :type 'user-error))))
  (should
   (string-match-p
    "locale not found"
    (error-message-string
     (should-error (let ((refbox-citeproc-csl-locale "missing")
                         (refbox-citeproc-csl-locales-dir nil))
                     (refbox-csl--locale-file))
                   :type 'user-error))))
  (should
   (string-match-p
    "refbox-citeproc-csl-locale"
    (error-message-string
     (should-error (let ((refbox-citeproc-csl-locale nil))
                     (refbox-csl--locale-file))
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
          (let ((refbox-citeproc-csl-locales-dir (list locale-dir))
                (refbox-citeproc-csl-locale "en-US"))
            (should (equal (refbox-csl--locale-file) locale-file))))
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

(ert-deftest refbox-test-select-references_dispatches_to_single_or_multiple_readers ()
  "Selection helpers should expose both multiple and single-reference reads."
  (let (multiple-args single-args)
    (cl-letf (((symbol-function 'refbox-read-references)
               (lambda (&rest args)
                 (setq multiple-args args)
                 (list refbox-test-reference-candidate)))
              ((symbol-function 'refbox-read-reference)
               (lambda (&rest args)
                 (setq single-args args)
                 refbox-test-reference-candidate)))
      (should (equal (refbox-select-references
                      :filter #'ignore
                      :preset "has:file"
                      :limit 7
                      :source-paths '("refs.bib"))
                     (list refbox-test-reference-candidate)))
      (should (equal multiple-args
                     (list "References: " "has:file" 7 #'ignore '("refs.bib"))))
      (should (eq (refbox-select-reference
                   :filter #'ignore
                   :preset "has:notes"
                   :limit 3
                   :source-paths '("local.bib"))
                  refbox-test-reference-candidate))
      (should (equal single-args
                     (list "Reference: " "has:notes" 3 #'ignore '("local.bib"))))
      (setq multiple-args nil
            single-args nil)
      (let ((refbox-select-multiple nil))
        (should (eq (refbox-select-references
                     :multiple t
                     :filter #'ignore
                     :preset "has:links"
                     :limit 4)
                    refbox-test-reference-candidate)))
      (should-not multiple-args)
      (should (equal single-args
                     (list "Reference: " "has:links" 4 #'ignore nil))))))

(ert-deftest refbox-test-select-refs_returns_keys_and_filters_by_key ()
  "Key-oriented selection should expose key strings for extension code."
  (let (filter-seen)
    (cl-letf (((symbol-function 'refbox-select-references)
               (lambda (&rest args)
                 (let ((filter (plist-get args :filter)))
                   (when filter
                     (setq filter-seen
                           (funcall filter refbox-test-reference-candidate))))
                 (list refbox-test-reference-candidate))))
      (should (equal (refbox-select-refs
                      :filter (lambda (key)
                                (equal key "smith2020")))
                     '("smith2020")))
      (should filter-seen))))

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
