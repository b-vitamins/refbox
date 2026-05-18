;;; test-refbox.el --- Tests for refbox -*- lexical-binding: t; -*-

;;; Commentary:

;; Batch checks for the refbox Emacs package scaffold.

;;; Code:

(require 'ert)
(require 'cl-lib)
(require 'refbox)

(defvar embark-default-action-overrides)
(defvar org-cite-csl--fallback-locales-dir)
(defvar pdf-tools-enabled-modes)
(defvar truncate-string-ellipsis)

(ert-deftest refbox-test-package-loads ()
  "The package entry feature should load cleanly."
  (should (featurep 'refbox)))

(defun refbox-test-key-table (keys function)
  "Return a key-indexed item table for KEYS using FUNCTION."
  (let ((table (make-hash-table :test 'equal)))
    (dolist (key keys table)
      (let ((items (funcall function key)))
        (when items
          (puthash key items table))))))

(ert-deftest refbox-test-package-load-has-no-process-side-effects ()
  "Loading the package should not start a daemon connection."
  (should-not (refbox-rpc-live-p))
  (should-not refbox--connection))

(defun refbox-test-face-includes-p (face-property face)
  "Return non-nil when FACE-PROPERTY contains FACE."
  (cond
   ((eq face-property face) t)
   ((listp face-property)
    (cl-some (lambda (item)
               (or (eq item face)
                   (and (listp item) (memq face item))))
             face-property))))

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
                               "--db" db
                               "--root" root
                               "--extension" "bib"
                               "--extension" "bibtex"))))
      (delete-directory root t))))

(ert-deftest refbox-test-rpc-command-allows-explicit_file_only_corpus ()
  "Explicit bibliography files should not depend on root discovery options."
  (let* ((root (make-temp-file "refbox-root-" t))
         (program (or (executable-find "true")
                      (executable-find "sh")))
         (db (expand-file-name "refbox.sqlite" root))
         (file (expand-file-name "refs.bib" root)))
    (unwind-protect
        (let ((refbox-server-program program)
              (refbox-bibliography-roots nil)
              (refbox-bibliography (list file))
              (refbox-bibliography-extensions nil)
              (refbox-database-file db))
          (should (equal (refbox-rpc--command)
                         (list program
                               "serve"
                               "--db" db
                               "--file" file))))
      (delete-directory root t))))

(ert-deftest refbox-test-rpc-command-accepts-string_path_options ()
  "Path-like options should treat one string as one configured item."
  (let* ((root (make-temp-file "refbox-root-" t))
         (program (or (executable-find "true")
                      (executable-find "sh")))
         (db (expand-file-name "refbox.sqlite" root))
         (file (expand-file-name "refs.bib" root)))
    (unwind-protect
        (let ((refbox-server-program program)
              (refbox-bibliography-roots root)
              (refbox-bibliography file)
              (refbox-bibliography-extensions "bib")
              (refbox-bibliography-include-globs "**/*.bib")
              (refbox-bibliography-exclude-globs "**/.#*")
              (refbox-database-file db))
          (should (equal (refbox-rpc--command)
                         (list program
                               "serve"
                               "--db" db
                               "--root" root
                               "--file" file
                               "--extension" "bib"
                               "--include-glob" "**/*.bib"
                               "--exclude-glob" "**/.#*"))))
      (delete-directory root t))))

(ert-deftest refbox-test-rpc-configuration-tracks_server_executable_identity ()
  "Rebuilt daemon executables should force Emacs to reconnect."
  (let* ((root (make-temp-file "refbox-root-" t))
         (program (expand-file-name "refbox-test-server" root))
         (replacement (expand-file-name "refbox-test-server.new" root))
         (db (expand-file-name "refbox.sqlite" root)))
    (unwind-protect
        (let (first-signature second-signature)
          (with-temp-file program
            (insert "#!/bin/sh\nexit 0\n"))
          (set-file-modes program #o755)
          (let ((refbox-server-program program)
                (refbox-bibliography-roots (list root))
                (refbox-database-file db))
            (setq first-signature
                  (plist-get (refbox-rpc--configuration)
                             :program-signature))
            (should (equal (refbox-rpc--command)
                           (list program
                                 "serve"
                                 "--db" db
                                 "--root" root
                                 "--extension" "bib"
                                 "--extension" "bibtex"))))
          (with-temp-file replacement
            (insert "#!/bin/sh\nprintf rebuilt\n"))
          (set-file-modes replacement #o755)
          (rename-file replacement program t)
          (let ((refbox-server-program program)
                (refbox-bibliography-roots (list root))
                (refbox-database-file db))
            (setq second-signature
                  (plist-get (refbox-rpc--configuration)
                             :program-signature)))
          (should first-signature)
          (should second-signature)
          (should-not (equal first-signature second-signature)))
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
                (refbox-bibliography nil)
                (refbox-database-file db))
            (should
             (string-match-p
              "refbox-bibliography-roots.*refbox-bibliography"
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

(ert-deftest refbox-test-autosync-mode-syncs-explicit-bibliography-file ()
  "Explicit bibliography files should be syncable outside discovery roots."
  (let* ((root (make-temp-file "refbox-root-" t))
         (file (expand-file-name "manual/source.txt" root))
         (refbox-autosync-sync-on-enable nil)
         (refbox-bibliography-roots nil)
         (refbox-bibliography (list file))
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
               (lambda () '(("alpha" "beta") . (1 . 12))))
              ((symbol-function 'refbox-test-insert-citation)
               (lambda (keys arg)
                 (insert (format "%s/%s" (string-join keys "|") arg))))
              ((symbol-function 'refbox-test-insert-edit)
               (lambda (arg)
                 (insert (format "edit/%s" arg))))
              ((symbol-function 'refbox-read-references)
               (lambda (&rest _args)
                 (list (list :key "alpha")
                       (list :key "beta"))))
              ((symbol-function 'refbox-select-refs)
               (lambda (&rest _args)
                 '("theta" "iota"))))
      (let ((refbox-major-mode-functions
             '(((refbox-test-mode) .
                ((insert-keys . refbox-test-insert-keys)
                 (insert-citation . refbox-test-insert-citation)
                 (insert-edit . refbox-test-insert-edit)
                 (key-at-point . refbox-test-key-at-point)
                 (citation-at-point . refbox-test-citation-at-point))))))
        (with-temp-buffer
          (refbox-test-mode)
          (call-interactively #'refbox-insert-keys)
          (should (equal (buffer-string) "theta|iota"))
          (erase-buffer)
          (refbox-insert-citation '("gamma" "delta") 'style)
          (should (equal (buffer-string) "gamma|delta/style"))
          (erase-buffer)
          (call-interactively #'refbox-insert-citation)
          (should (equal (buffer-string) "theta|iota/nil"))
          (erase-buffer)
          (refbox-insert-edit 'arg)
          (should (equal (buffer-string) "edit/arg"))
          (let ((refbox-default-action
                 (lambda (references)
                   (setq default-action-refs references))))
            (refbox-dwim)
            (should (equal default-action-refs '("alpha" "beta")))))))))

(ert-deftest refbox-test-at_point_helpers_strip_adapter_bounds ()
  "Generic at-point helpers should expose Citar-style adapter values."
  (cl-letf (((symbol-function 'refbox-test-key-at-point)
             (lambda () '("alpha" . (1 . 7))))
            ((symbol-function 'refbox-test-citation-at-point)
             (lambda () '(("alpha" "beta") . (1 . 14)))))
    (let ((refbox-major-mode-functions
           '(((refbox-test-mode) .
              ((key-at-point . refbox-test-key-at-point)
               (citation-at-point . refbox-test-citation-at-point))))))
      (with-temp-buffer
        (refbox-test-mode)
        (should (equal (refbox-key-at-point) "alpha"))
        (should (equal (refbox-citation-at-point) '("alpha" "beta")))))))

(ert-deftest refbox-test-insert-edit_without_adapter_matches_citar_message ()
  "Generic citation edit should not fall back to citation insertion."
  (let ((refbox-major-mode-functions
         '(((refbox-test-mode) .
            ((insert-citation . ignore)))))
        messages)
    (cl-letf (((symbol-function 'message)
               (lambda (format-string &rest args)
                 (let ((text (apply #'format format-string args)))
                   (push text messages)
                   text))))
      (with-temp-buffer
        (refbox-test-mode)
        (should (equal (refbox-insert-edit)
                       "Citation editing is not supported for refbox-test-mode"))
        (should (equal (buffer-string) ""))
        (should (equal messages
                       '("Citation editing is not supported for refbox-test-mode")))))))

(ert-deftest refbox-test-insert-citation_without_adapter_matches_citar_contract ()
  "Programmatic unsupported citation insertion should use the adapter default."
  (let ((refbox-major-mode-functions nil))
    (with-temp-buffer
      (refbox-test-mode)
      (should-not (refbox-insert-citation nil))
      (should (equal (buffer-string) ""))
      (let ((error-data
             (should-error (call-interactively #'refbox-insert-citation)
                           :type 'error)))
        (should (eq (car error-data) 'error))
        (should (string-match-p
                 "Citation insertion is not supported for refbox-test-mode"
                 (cadr error-data)))))))

(ert-deftest refbox-test-dwim_without_citation_matches_citar_error ()
  "DWIM should not prompt when no citation is at point."
  (let (default-action-refs prompted)
    (cl-letf (((symbol-function 'refbox-key-at-point)
               (lambda () nil))
              ((symbol-function 'refbox-citation-at-point)
               (lambda () nil))
              ((symbol-function 'refbox-read-references)
               (lambda (&rest _args)
                 (setq prompted t)
                 (list (list :key "alpha")))))
      (let ((refbox-default-action
             (lambda (references)
               (setq default-action-refs references))))
        (should-error (refbox-dwim) :type 'user-error)
        (should-not prompted)
        (should-not default-action-refs)))))

(ert-deftest refbox-test-run-default-action_matches_citar_contract ()
  "Default action dispatch should pass REFERENCES through unchanged."
  (let (calls)
    (let ((refbox-default-action
           (lambda (references)
             (push references calls))))
      (refbox-run-default-action nil)
      (should (equal calls '(nil)))
      (refbox-run-default-action '("alpha"))
      (should (equal calls '(("alpha") nil))))))

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

(ert-deftest refbox-test-key_resolution_prefers_current_local_bibliography ()
  "Key-only metadata commands should use the current buffer's local bibliography."
  (let* ((root (make-temp-file "refbox-local-resolution-" t))
         (local (expand-file-name "local.bib" root))
         (global (expand-file-name "global.bib" root))
         (local-candidate
          `(:id 10
            :key "dup2020"
            :source_path ,local
            :fields ((:raw_name "title"
                      :lookup_name "title"
                      :value "Local Title"))))
         (global-candidate
          `(:id 20
            :key "dup2020"
            :source_path ,global
            :fields ((:raw_name "title"
                      :lookup_name "title"
                      :value "Global Title"))))
         (refbox-major-mode-functions
          '(((refbox-test-mode) .
             ((local-bib-files . refbox-test-local-bib-files)))))
         (refbox-templates '((preview . "%{title}"))))
    (unwind-protect
        (progn
          (with-temp-file local)
          (cl-letf (((symbol-function 'refbox-test-local-bib-files)
                     (lambda (&optional _buffer) (list local)))
                    ((symbol-function 'refbox-entry-by-key)
                     (lambda (_key)
                       (error "context resolver should avoid fallback lookup")))
                    ((symbol-function 'refbox-search-references)
                     (lambda (query _limit source-paths &rest args)
                       (should (equal query ""))
                       (should (equal source-paths (list local)))
                       (should (equal (nth 5 args) '("dup2020")))
                       (should (eq (nth 6 args) t))
                       (list global-candidate local-candidate))))
            (with-temp-buffer
              (refbox-test-mode)
              (should (equal (refbox-format-reference '("dup2020"))
                             "Local Title")))))
      (delete-directory root t))))

(ert-deftest refbox-test-read_reference_defaults_to_current_local_bibliography ()
  "Generic selection should include local bibliographies by default."
  (let* ((root (make-temp-file "refbox-local-read-" t))
         (local (expand-file-name "local.bib" root))
         (candidate `(:key "local2020" :source_path ,local))
         (refbox-major-mode-functions
          '(((refbox-test-mode) .
             ((local-bib-files . refbox-test-local-bib-files))))))
    (unwind-protect
        (progn
          (with-temp-file local)
          (cl-letf (((symbol-function 'refbox-test-local-bib-files)
                     (lambda (&optional _buffer) (list local)))
                    ((symbol-function 'completing-read)
                     (lambda (&rest _args) "local2020"))
                    ((symbol-function 'refbox-search-references)
                     (lambda (query _limit source-paths &rest args)
                       (should (equal query ""))
                       (should (equal source-paths (list local)))
                       (should (equal (nth 5 args) '("local2020")))
                       (should (eq (nth 6 args) t))
                       (list candidate))))
            (with-temp-buffer
              (refbox-test-mode)
              (should (equal (refbox-read-reference) candidate)))))
      (delete-directory root t))))

(ert-deftest refbox-test-source_lookup_resolves_current_local_bibliography ()
  "Key-only source commands should resolve local-buffer bibliography keys."
  (let* ((root (make-temp-file "refbox-local-source-" t))
         (local (expand-file-name "local.bib" root))
         (candidate `(:id 5 :key "local2020" :source_path ,local))
         (location `(:source_path ,local
                     :source (:start (:line 7 :column 3))))
         (refbox-major-mode-functions
          '(((refbox-test-mode) .
             ((local-bib-files . refbox-test-local-bib-files))))))
    (unwind-protect
        (progn
          (with-temp-file local)
          (cl-letf (((symbol-function 'refbox-test-local-bib-files)
                     (lambda (&optional _buffer) (list local)))
                    ((symbol-function 'refbox-search-references)
                     (lambda (query _limit source-paths &rest args)
                       (should (equal query ""))
                       (should (equal source-paths (list local)))
                       (should (equal (nth 5 args) '("local2020")))
                       (should (eq (nth 6 args) t))
                       (list candidate)))
                    ((symbol-function 'refbox-rpc-request)
                     (lambda (method params)
                       (should (equal method refbox-rpc-method-source-location))
                       (should (equal (plist-get params :id) 5))
                       (should (equal (plist-get params :source_path) local))
                       location)))
            (with-temp-buffer
              (refbox-test-mode)
              (should (equal (refbox-source-location "local2020") location)))))
      (delete-directory root t))))

(ert-deftest refbox-test-local_bibliography_paths_use_truenames ()
  "Local bibliography source paths should match Citar's truename identity."
  (let* ((root (make-temp-file "refbox-local-truename-" t))
         (real (expand-file-name "real.bib" root))
         (link (expand-file-name "link.bib" root))
         (refbox-major-mode-functions
          '(((refbox-test-mode) .
             ((local-bib-files . refbox-test-local-bib-files))))))
    (unwind-protect
        (progn
          (with-temp-file real)
          (condition-case _
              (make-symbolic-link real link)
            (file-error (ert-skip "symbolic links are unavailable")))
          (cl-letf (((symbol-function 'refbox-test-local-bib-files)
                     (lambda (&optional _buffer) (list link real))))
            (with-temp-buffer
              (refbox-test-mode)
              (should (equal (refbox--current-local-bibliography-source-paths)
                             (list (file-truename real)))))))
      (delete-directory root t))))

(ert-deftest refbox-test-local_bibliography_paths_error_when_missing ()
  "A declared missing local bibliography should be a direct user error."
  (let* ((root (make-temp-file "refbox-local-missing-" t))
         (missing (expand-file-name "missing.bib" root))
         (refbox-major-mode-functions
          '(((refbox-test-mode) .
             ((local-bib-files . refbox-test-local-bib-files))))))
    (unwind-protect
        (cl-letf (((symbol-function 'refbox-test-local-bib-files)
                   (lambda (&optional _buffer) (list missing))))
          (with-temp-buffer
            (refbox-test-mode)
            (should
             (string-match-p
              "Cannot find file"
              (error-message-string
               (should-error
                (refbox--current-local-bibliography-source-paths)
                :type 'user-error))))))
      (delete-directory root t))))

(ert-deftest refbox-test-diagnostics_requests_bounded_rpc ()
  "Diagnostic lookup should use the bounded daemon diagnostics method."
  (let ((refbox-diagnostics-limit 12)
        (refbox-search-maximum-limit 50)
        (diagnostic '(:severity "error" :message "bad entry"))
        calls)
    (cl-letf (((symbol-function 'refbox-rpc-request)
               (lambda (method params)
                 (push (list method params) calls)
                 (should (equal method refbox-rpc-method-diagnostics))
                 (list :diagnostics (list diagnostic)))))
      (should (equal (refbox-diagnostics)
                     (list diagnostic)))
      (should (equal (cadr (car calls))
                     (list :limit 12)))
      (setq calls nil)
      (should (equal (refbox-diagnostics 200)
                     (list diagnostic)))
      (should (equal (cadr (car calls))
                     (list :limit 50))))))

(ert-deftest refbox-test_duplicate_groups_request_bounded_rpc ()
  "Duplicate-key lookup should use the bounded daemon duplicate-group method."
  (let ((refbox-duplicate-groups-limit 9)
        (refbox-search-maximum-limit 25)
        (group '(:key "dup2020"
                 :entries ((:id 1 :key "dup2020" :source_path "/tmp/a.bib")
                           (:id 2 :key "dup2020" :source_path "/tmp/b.bib"))))
        calls)
    (cl-letf (((symbol-function 'refbox-rpc-request)
               (lambda (method params)
                 (push (list method params) calls)
                 (should (equal method refbox-rpc-method-duplicate-groups))
                 (list :groups (list group)))))
      (should (equal (refbox-duplicate-groups)
                     (list group)))
      (should (equal (cadr (car calls))
                     (list :limit 9)))
      (setq calls nil)
      (should (equal (refbox-duplicate-groups 200)
                     (list group)))
      (should (equal (cadr (car calls))
                     (list :limit 25))))))

(ert-deftest refbox-test-diagnostic_location_includes_source_position ()
  "Diagnostic row locations should include indexed source spans."
  (let ((file (expand-file-name "bad.bib" temporary-file-directory)))
    (should (equal (refbox--diagnostic-location
                    `(:file_path ,file
                      :source (:start (:line 3 :column 5))))
                   (concat (abbreviate-file-name file) ":3:5")))))

(ert-deftest refbox-test-diagnostic_and_duplicate_lists_use_tabulated_buffers ()
  "Diagnostic and duplicate commands should build bounded list buffers."
  (let ((diagnostic '(:severity "error"
                     :code "parse"
                     :file_path "/tmp/bad.bib"
                     :message "bad entry"
                     :source (:start (:line 3 :column 5))))
        (group '(:key "dup2020"
                 :entries ((:id 1 :key "dup2020" :source_path "/tmp/a.bib")
                           (:id 2 :key "dup2020" :source_path "/tmp/b.bib")))))
    (cl-letf (((symbol-function 'refbox-diagnostics)
               (lambda (limit)
                 (should (equal limit 7))
                 (list diagnostic)))
              ((symbol-function 'refbox-duplicate-groups)
               (lambda (limit)
                 (should (equal limit 4))
                 (list group)))
              ((symbol-function 'pop-to-buffer)
               (lambda (buffer &rest _args) buffer)))
      (unwind-protect
          (progn
            (refbox-list-diagnostics 7)
            (with-current-buffer refbox-diagnostics-buffer-name
              (should (eq major-mode 'refbox-diagnostics-list-mode))
              (should (equal (caar tabulated-list-entries) diagnostic)))
            (refbox-list-duplicates 4)
            (with-current-buffer refbox-duplicates-buffer-name
              (should (eq major-mode 'refbox-duplicates-list-mode))
              (should (equal (caar tabulated-list-entries) group))))
        (when (get-buffer refbox-diagnostics-buffer-name)
          (kill-buffer refbox-diagnostics-buffer-name))
        (when (get-buffer refbox-duplicates-buffer-name)
          (kill-buffer refbox-duplicates-buffer-name))))))

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

(ert-deftest refbox-test-template-formatting_pads_to_display_width ()
  "Fixed-width template fields should reserve display columns, not characters."
  (let ((formatted
         (refbox-template-format
          "%{title:6}|%{key}"
          '(:key "alpha"
            :fields ((:lookup_name "title" :value "界"))))))
    (should (equal (substring formatted (string-match-p "|" formatted))
                   "|alpha"))
    (should (= (string-width (substring formatted 0
                                         (string-match-p "|" formatted)))
               6))))

(ert-deftest refbox-test-template-formatting_allocates_star_width_remainder ()
  "Star-width fields should consume all leftover display columns."
  (let* ((candidate '(:key "k"
                      :fields ((:lookup_name "title" :value "abcdef")
                               (:lookup_name "journal" :value "wxyzuv"))))
         (formatted (refbox-template-format
                     "%{title:*}|%{journal:*}|%{key}"
                     candidate
                     12)))
    (should (equal formatted "abcde|wxyz|k"))
    (should (= (string-width formatted) 12))))

(ert-deftest refbox-test-author_display_removes_protective_bibtex_braces ()
  "Author shortening should not leak BibTeX protection braces into candidates."
  (let ((candidate
         '(:key "braced"
           :entry_type "article"
           :fields ((:lookup_name "author"
                     :value "{Aaboud}, Morad and {CMS Collaboration}")
                    (:lookup_name "year" :value "2020")
                    (:lookup_name "title" :value "Braced Author Names"))
           :resources nil)))
    (should (equal (refbox-template-format "${author:30%sn}" candidate)
                   "Aaboud, CMS Collaboration     "))))

(ert-deftest refbox-test-template-formatting-supports_configured_ellipsis ()
  "Template field truncation should support a configured ellipsis marker."
  (let ((refbox-ellipsis "..."))
    (should (equal (refbox-template-format
                    "%{title:10!refbox-template-clean}"
                    refbox-test-reference-candidate)
                   "Alpha R..."))))

(ert-deftest refbox-test-template-formatting_supports_default_ellipsis ()
  "Template truncation should accept t for Emacs' default ellipsis."
  (let ((refbox-ellipsis t)
        (truncate-string-ellipsis "~"))
    (should (equal (refbox-template-format
                    "%{title:10!refbox-template-clean}"
                    refbox-test-reference-candidate)
                   "Alpha Ref~"))))

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

(ert-deftest refbox-test-template_formatting_preserves_placeholder_properties ()
  "Template fields should inherit Citar-style placeholder text properties."
  (clrhash refbox-template--parse-cache)
  (let ((styled (copy-sequence "${title:8} plain"))
        (plain "${title:8} plain"))
    (add-text-properties 0 10 '(face bold refbox-test t) styled)
    (let ((styled-output
           (refbox-template-format styled refbox-test-reference-candidate))
          (plain-output
           (refbox-template-format plain refbox-test-reference-candidate)))
      (should (equal (substring-no-properties styled-output)
                     "Alpha Re plain"))
      (should (equal (substring-no-properties plain-output)
                     "Alpha Re plain"))
      (should (eq (get-text-property 0 'face styled-output) 'bold))
      (should (eq (get-text-property 0 'refbox-test styled-output) t))
      (should-not (get-text-property 9 'face styled-output))
      (should-not (get-text-property 0 'face plain-output)))))

(ert-deftest refbox-test-template_formatting_matches_citar_zero_width_parsing ()
  "Template width parsing should keep Citar's string-to-number behavior."
  (dolist (template '("${title:}" "${title:0}" "${title:00}" "${title:abc}"))
    (should (equal (refbox-template-format
                    template
                    refbox-test-reference-candidate)
                   "Alpha Reference Title"))))

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

(ert-deftest refbox-test-completion_field_names_cover_selected_actions ()
  "Completion hydration should include fields needed after selection."
  (let ((refbox-templates
         '((main . "%{key}")
           (suffix . "%{entry_type}")
           (preview . "${journal journaltitle}")
           (note . "${abstract}")))
        (refbox-crossref-variable "xref")
        (refbox-additional-fields '("custom" "journal")))
    (should (equal (refbox--completion-field-names)
                   '("key" "entry_type" "journal" "journaltitle"
                     "abstract" "xref" "custom")))))

(ert-deftest refbox-test-completion-candidates-carry_metadata ()
  "Completion candidates should come from bounded RPC search and carry metadata."
  (let ((refbox-templates
         '((main . "%{key} %{title}")
           (suffix . "%{indicators} %{entry_type} %{source_path!file-name-nondirectory}")))
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
          (should (eq (plist-get params :ranked) :json-false))
          (should (equal (plist-get params :field_value_char_limit)
                         refbox-completion-field-value-limit))
          (should (eq (plist-get params :include_field_sources) :json-false))
          (should (equal (append (plist-get params :field_names) nil)
                         '("key" "title" "indicators"
                           "entry_type" "source_path" "crossref")))
          (should (equal (append (plist-get params :crossref_fields) nil)
                         '("crossref")))
          (should (equal (append (plist-get params :search_fields) nil)
                         refbox-completion-search-fields))
          (should (eq (plist-get params :include_resources) :json-false))
          (should-not (plist-member params :include_fields)))
        (should (string-match-p "smith2020" candidate-string))
        (should (equal (plist-get candidate :key) "smith2020"))
        (should-not (plist-get candidate :refbox_partial))
        (should (eq (get-text-property 0 'face candidate-string)
                    'refbox-highlight))
        (should
         (cl-loop for pos = 0 then (next-single-property-change
                                    pos 'face candidate-string)
                  while pos
                  thereis (eq (get-text-property pos 'face candidate-string)
                              'refbox)))
        (should (string-match-p
                 "L F +article main\\.bib"
                 candidate-string))
        (should (string-match-p
                 "L F"
                 (nth 1 affixation)))
        (should (string-empty-p (nth 2 affixation)))))))

(ert-deftest refbox-test-native_completion_requests_only_display_fields ()
  "Native completion should defer non-display fields until selection."
  (let ((calls nil))
    (cl-letf (((symbol-function 'refbox-rpc-request)
               (lambda (method params)
                 (push (list method params) calls)
                 (should (equal method refbox-rpc-method-search-entries))
                 (list :entries (list refbox-test-reference-candidate)))))
      (let* ((state (refbox--completion-state 7))
             (table (refbox--completion-table state))
             (candidates (funcall table "alpha" nil t))
             (candidate (get-text-property 0 'refbox-candidate (car candidates)))
             (params (cadar calls)))
        (should (equal (append (plist-get params :field_names) nil)
                       (append refbox--native-completion-field-names
                               (refbox--crossref-field-names))))
        (should (eq (plist-get params :include_completion_display) t))
        (should (eq (plist-get params :include_fields) :json-false))
        (should (plist-get candidate :refbox_partial))))))

(ert-deftest refbox-test-read_reference_hydrates_partial_completion_candidate ()
  "Selected lightweight completion candidates should hydrate before returning."
  (let* ((state (refbox--completion-state 7))
         (partial '(:key "smith2020"
                    :source_path "/tmp/main.bib"
                    :fields nil
                    :refbox_partial t))
         (full '(:key "smith2020"
                 :source_path "/tmp/main.bib"
                 :fields ((:lookup_name "title" :value "Full Title")))))
    (puthash "visible row" partial (plist-get state :map))
    (cl-letf (((symbol-function 'completing-read)
               (lambda (&rest _args) "visible row"))
              ((symbol-function 'refbox--sync-current-bibliography-buffer-if-needed)
               #'ignore)
              ((symbol-function 'refbox-entry-by-key)
               (lambda (reference)
                 (should (eq reference partial))
                 full)))
      (should (eq (refbox--read-reference-from-state
                   "Reference: " nil nil nil state)
                  full)))))

(ert-deftest refbox-test-default_indicator_order_matches_citar ()
  "Default indicators should preserve Citar's link/file/note/cited order."
  (should (equal (mapcar #'refbox-indicator-tag refbox-indicators)
                 '("has:links" "has:files" "has:notes" "is:cited"))))

(ert-deftest refbox-test-indicator_configuration_uses_single_path ()
  "Indicator customization should use `refbox-indicators' only."
  (dolist (symbol '(refbox-reference-resource-indicator
                    refbox-reference-link-indicator
                    refbox-reference-note-indicator
                    refbox-reference-cited-indicator
                    refbox-reference-note-predicate
                    refbox-reference-cited-predicate
                    refbox-symbols
                    refbox-symbol-separator))
    (should-not (boundp symbol))))

(ert-deftest refbox-test-resource_field_configuration_uses_single_path ()
  "Resource field configuration should use Citar-shaped variables only."
  (dolist (symbol '(refbox-crossref-field-names
                    refbox-resource-file-field-names
                    refbox-reference-resource-field-names))
    (should-not (boundp symbol)))
  (let ((refbox-crossref-variable "xref")
        (refbox-file-variable "pdf"))
    (should (equal (refbox--crossref-field-names) '("xref")))
    (should (equal (refbox--file-field-names) '("pdf")))))

(ert-deftest refbox-test-default_indicator_fast_path_matches_configured_links ()
  "Default indicator rendering should be fast, ordered, and link-field driven."
  (should (refbox--default-reference-indicators-p))
  (should (string-prefix-p
           "L F"
           (substring-no-properties
            (refbox-reference-indicators
             '(:key "alpha" :resource_kinds ["file" "doi"])))))
  (should-not
   (string-match-p
    "L"
    (substring-no-properties
     (refbox-reference-indicators
      '(:key "beta" :resource_kinds ["eprint"])))))
  (let ((refbox-link-fields
         '((eprint . "https://example.test/eprint/%s"))))
    (should
     (string-match-p
      "L"
      (substring-no-properties
      (refbox-reference-indicators
       '(:key "gamma" :resource_kinds ["eprint"])))))))

(ert-deftest refbox-test-custom_builtin_indicators_use_batched_fast_path ()
  "Custom symbols backed by built-in predicates should keep one-pass matching."
  (let* ((note-checks 0)
         (refbox-indicators
          (list
           (refbox-indicator-create
            :symbol "N" :function #'refbox-has-notes :tag "has:notes")
           (refbox-indicator-create
            :symbol "P" :function #'refbox-has-files :tag "has:files")
           (refbox-indicator-create
            :symbol "L" :function #'refbox-has-links :tag "has:links")))
         (refbox-notes-source 'mock)
         (refbox-notes-sources
          `((mock
             :items ,#'ignore
             :hasitems ,(lambda ()
                          (lambda (_key)
                            (setq note-checks (1+ note-checks))
                            t))
             :open ,#'ignore))))
    (should (refbox--builtin-indicators-p))
    (should
     (string-prefix-p
      "N P L"
      (substring-no-properties
       (refbox-reference-indicators
        '(:key "alpha" :resource_kinds ["file" "doi"])))))
    (should (= note-checks 1))))

(ert-deftest refbox-test-completion-uses_daemon_shaped_default_display ()
  "Default completion display should use daemon-shaped rows when present."
  (let* ((candidate (append
                     (copy-tree refbox-test-reference-candidate)
                     (list :completion_display
                           '(:main "Native Main"
                             :suffix "Native Suffix"))))
         (seen (make-hash-table :test 'equal))
         (selection-map (make-hash-table :test 'equal))
         (display (refbox--completion-candidate-display
                   candidate seen selection-map)))
    (should (string-match-p "Native Main" display))
    (should (string-match-p "Native Suffix" display))
    (should
     (=
      (string-width (substring display
                               0
                               (string-match-p "Native Suffix" display)))
      refbox--native-completion-main-display-width))
    (should-not (string-match-p "Alpha Reference Title" display))))

(ert-deftest refbox-test-completion_highlights_native_title_matches ()
  "Native completion rows should highlight visible title terms themselves."
  (let* ((candidate (append
                     (copy-tree refbox-test-reference-candidate)
                     (list :completion_display
                           '(:main "Hoover, Krotov                2025     Dense Associative Memory with Energy"
                             :suffix "          hoover2025dense article"))))
         (seen (make-hash-table :test 'equal))
         (selection-map (make-hash-table :test 'equal))
         (display (refbox--completion-candidate-display
                   candidate seen selection-map "associative memory"))
         (case-fold-search t))
    (dolist (term '("Associative" "Memory"))
      (let ((pos (string-match-p term display)))
        (should pos)
        (should (refbox-test-face-includes-p
                 (get-text-property pos 'face display)
                 'refbox-match))))))

(ert-deftest refbox-test-completion_normalizes_native_main_display_width ()
  "Native main rows should be re-fitted with Emacs display-width rules."
  (let* ((candidate (append
                     (copy-tree refbox-test-reference-candidate)
                     (list :completion_display
                           (list :main (concat (make-string 91 ?x) "漢")
                                 :suffix "Suffix"))))
         (seen (make-hash-table :test 'equal))
         (selection-map (make-hash-table :test 'equal))
         (display (refbox--completion-candidate-display
                   candidate seen selection-map)))
    (should
     (=
      (string-width (substring display
                               0
                               (string-match-p "Suffix" display)))
      refbox--native-completion-main-display-width))))

(ert-deftest refbox-test-completion-hides_duplicate_source_identity ()
  "Duplicate rows should not expose source paths in the visible display."
  (let* ((refbox-templates
          '((main . "%{author:16} %{date:4} %{title:24}")
            (suffix . "  %{=key=:12} %{=type=:10}")))
         (refbox-indicators nil)
         (first
          '(:key "krotov2018dense"
            :entry_type "article"
            :source_path "/home/b/projects/bibliography/journals/neco/2018.bib"
            :fields ((:lookup_name "author" :value "Krotov, Hopfield")
                     (:lookup_name "date" :value "2018")
                     (:lookup_name "title" :value "Dense Associative Memory"))))
         (second
          '(:key "krotov2018dense"
            :entry_type "article"
            :source_path "/home/b/projects/bibliography/references/references.bib"
            :fields ((:lookup_name "author" :value "Krotov, Hopfield")
                     (:lookup_name "date" :value "2018")
                     (:lookup_name "title" :value "Dense Associative Memory"))))
         (seen (make-hash-table :test 'equal))
         (selection-map (make-hash-table :test 'equal))
         (first-display (refbox--completion-candidate-display
                         first seen selection-map))
         (second-display (refbox--completion-candidate-display
                          second seen selection-map))
         (hidden-pos (text-property-any
                      0 (length second-display)
                      'refbox-internal-identity t second-display)))
    (should (equal (get-text-property 0 'refbox-visible-text first-display)
                   (get-text-property 0 'refbox-visible-text second-display)))
    (should hidden-pos)
    (should (equal (get-text-property hidden-pos 'display second-display) ""))
    (should-not (string-match-p
                 "bibliography"
                 (get-text-property 0 'refbox-visible-text second-display)))
    (should (equal (gethash (substring-no-properties first-display)
                            selection-map)
                   first))
    (should (equal (gethash (substring-no-properties second-display)
                            selection-map)
                   second))))

(ert-deftest refbox-test-completion_preserves_suffix_column_alignment ()
  "Completion display should keep main-field padding before suffix columns."
  (let* ((refbox-templates
          '((main . "%{author:12} %{date:4} %{title:24}")
            (suffix . "  %{=key=:12} %{=type=:10}")))
         (refbox-indicators nil)
         (short
          '(:key "short2020"
            :entry_type "article"
            :fields ((:lookup_name "author" :value "Smith")
                     (:lookup_name "date" :value "2020")
                     (:lookup_name "title" :value "A"))))
         (long
          '(:key "long2021"
            :entry_type "article"
            :fields ((:lookup_name "author" :value "Jones")
                     (:lookup_name "date" :value "2021")
                     (:lookup_name "title" :value "A much longer title"))))
         (seen (make-hash-table :test 'equal))
         (selection-map (make-hash-table :test 'equal))
         (short-display (refbox--completion-candidate-display
                         short seen selection-map))
         (long-display (refbox--completion-candidate-display
                        long seen selection-map)))
    (should
     (=
      (string-width (substring short-display 0
                               (string-match-p "short2020" short-display)))
      (string-width (substring long-display 0
                               (string-match-p "long2021" long-display)))))))

(ert-deftest refbox-test-capf_annotations_use_author_and_title ()
  "CAPF annotations should mirror the concise author/title display."
  (let* ((completion (refbox-capf--candidate
                      refbox-test-reference-candidate
                      (make-hash-table :test 'equal)))
         (annotation (refbox-capf-annotate completion)))
    (should (string-match-p "\\`   Smith *  Alpha Reference Title"
                            annotation))
    (should-not (string-match-p "smith2020" annotation))))

(ert-deftest refbox-test-capf_metadata_uses_key_annotations_not_affixation ()
  "CAPF metadata should expose citekey candidates with concise annotations."
  (let* ((table (refbox-capf--completion-table (refbox-capf--state 10)))
         (metadata (funcall table "" nil 'metadata)))
    (should (assq 'annotation-function (cdr metadata)))
    (should (assq 'company-docsig (cdr metadata)))
    (should-not (assq 'affixation-function (cdr metadata)))))

(ert-deftest refbox-test-capf_return_exposes_citar_properties ()
  "CAPF return data should expose Citar-compatible annotation and exit hooks."
  (let* ((capf (refbox-capf-at-bounds (cons 1 1)))
         (properties (nthcdr 3 capf)))
    (should (eq (plist-get properties :annotation-function)
                #'refbox-capf-annotate))
    (should (eq (plist-get properties :exit-function)
                #'refbox-capf--exit))
    (with-temp-buffer
      (insert "key")
      (goto-char (point-min))
      (funcall (plist-get properties :exit-function) "smith2020" 'finished)
      (should (equal (buffer-string) "key")))))

(ert-deftest refbox-test-capf_hydrates_only_annotation_fields ()
  "CAPF search should not hydrate minibuffer display fields."
  (let ((calls nil))
    (cl-letf (((symbol-function 'refbox-rpc-request)
               (lambda (method params)
                 (push (list method params) calls)
                 (should (equal method refbox-rpc-method-search-entries))
                 (list :entries (list refbox-test-reference-candidate)))))
      (let* ((table (refbox-capf--completion-table (refbox-capf--state 13)))
             (candidates (funcall table "smith" nil t))
             (params (cadar calls)))
        (should (equal (mapcar #'substring-no-properties candidates)
                       '("smith2020")))
        (should (equal (append (plist-get params :field_names) nil)
                       refbox-capf--field-names))
        (should (equal (plist-get params :include_resources) :json-false))
        (should-not (plist-member params :include_completion_display))))))

(ert-deftest refbox-test-reference_indicators_reserve_absent_slots ()
  "Indicator prefixes should stay width-stable when indicators are absent."
  (let* ((refbox-indicators
          (list
           (refbox-indicator-create
            :symbol "F"
            :emptysymbol " "
            :padding "  "
            :function (lambda ()
                        (lambda (candidate)
                          (equal (refbox-reference-field candidate "key")
                                 "smith2020"))))
           (refbox-indicator-create
            :symbol "L"
            :emptysymbol " "
            :padding "  "
            :function (lambda () (lambda (_candidate) nil)))))
         (matched refbox-test-reference-candidate)
         (unmatched (plist-put (copy-tree refbox-test-reference-candidate)
                               :key "doe2021"))
         (matched-text (refbox-reference-indicators matched))
         (unmatched-text (refbox-reference-indicators unmatched)))
    (should (= (string-width matched-text)
               (string-width unmatched-text)))
    (should (= (length matched-text)
               (length unmatched-text)))
    (should (get-text-property (1- (length matched-text))
                               'display matched-text))
    (should (get-text-property (1- (length unmatched-text))
                               'display unmatched-text))))

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

(ert-deftest refbox-test-completion-short_inputs_use_fast_unranked_search ()
  "Very short minibuffer probes should avoid expensive broad ranking."
  (let ((refbox-completion-ranked-min-input 3)
        calls)
    (cl-letf (((symbol-function 'refbox-rpc-request)
               (lambda (method params)
                 (push (list method params) calls)
                 (should (equal method refbox-rpc-method-search-entries))
                 (list :entries (list refbox-test-reference-candidate)))))
      (let* ((state (refbox--completion-state 7))
             (table (refbox--completion-table state)))
        (funcall table "po" nil t)
        (should (equal (plist-get (cadar calls) :ranked) :json-false))
        (should (equal (plist-get (cadar calls) :include_completion_display)
                       t))))))

(ert-deftest refbox-test-completion-delegates_visible_text_to_completion_styles ()
  "The minibuffer table should let completion styles filter display strings."
  (let ((refbox-templates '((main . "%{key} %{title}")))
        (refbox-completion-category-styles '(substring basic))
        (completion-styles '(substring basic)))
    (cl-letf (((symbol-function 'refbox-search-references)
               (lambda (_query &rest _args)
                 (list refbox-test-reference-candidate
                       (plist-put
                        (copy-tree refbox-test-reference-candidate)
                        :key "doe2021")))))
      (let* ((state (refbox--completion-state 10))
             (table (refbox--completion-table state))
             (candidates (funcall table "doe" nil t)))
        (should (= (length candidates) 1))
        (should (string-match-p "doe2021" (car candidates)))))))

(ert-deftest refbox-test-completion-basic_category_skips_global_styles ()
  "The native basic category should not run global completion styles again."
  (let ((refbox-completion-category-styles '(basic))
        (completion-styles '(orderless basic))
        (called nil))
    (cl-letf (((symbol-function 'refbox-search-references)
               (lambda (_query &rest _args)
                 (list refbox-test-reference-candidate)))
              ((symbol-function 'complete-with-action)
               (lambda (&rest _args)
                 (setq called t)
                 nil)))
      (let* ((state (refbox--completion-state 10))
             (table (refbox--completion-table state))
             (candidates (funcall table "alpha" nil t)))
        (should (= (length candidates) 1))
        (should-not called)))))

(ert-deftest refbox-test-completion-keeps_native_matches_when_styles_reject_display ()
  "Native search hits should remain visible for non-prefix typeahead input."
  (let ((refbox-templates '((main . "%{author:16}     %{title:32}")
                            (suffix . "          %{=key=:12}")))
        (completion-styles '(basic)))
    (cl-letf (((symbol-function 'refbox-search-references)
               (lambda (query &rest _args)
                 (should (equal query "Relational Interaction"))
                 (list refbox-test-reference-candidate))))
      (let* ((state (refbox--completion-state 10))
             (table (refbox--completion-table state))
             (candidates (funcall table "Relational Interaction" nil t)))
        (should (= (length candidates) 1))
        (should (string-match-p "Alpha Reference Title" (car candidates)))
        (should (equal
                 (plist-get (get-text-property 0 'refbox-candidate
                                               (car candidates))
                            :key)
                 "smith2020"))))))

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
               (lambda (query &rest _args)
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

(ert-deftest refbox-test-read-reference_accepts_exact_key_fallback ()
  "Selection readers should accept an exact citekey returned by completion UIs."
  (let (requested-key require-match)
    (cl-letf (((symbol-function 'refbox--sync-current-bibliography-buffer-if-needed)
               #'ignore)
              ((symbol-function 'completing-read)
               (lambda (_prompt collection _predicate require &rest _args)
                 (setq require-match require)
                 (funcall collection "smith2020" nil t)
                 "smith2020"))
              ((symbol-function 'refbox-search-references)
               (lambda (&rest _args) nil))
              ((symbol-function 'refbox-entry-by-key)
               (lambda (key)
                 (setq requested-key key)
                 refbox-test-reference-candidate)))
      (let ((selected (refbox--read-reference "Reference: " nil 5 nil)))
        (should-not require-match)
        (should (equal requested-key "smith2020"))
        (should (equal (plist-get selected :key) "smith2020"))))))

(ert-deftest refbox-test-read-reference_rejects_freeform_by_default ()
  "Candidate readers should stay strict unless key selection asks otherwise."
  (cl-letf (((symbol-function 'refbox--sync-current-bibliography-buffer-if-needed)
             #'ignore)
            ((symbol-function 'completing-read)
             (lambda (_prompt collection _predicate _require &rest _args)
               (funcall collection "missing2026" nil t)
               "missing2026"))
            ((symbol-function 'refbox-search-references)
             (lambda (&rest _args) nil))
            ((symbol-function 'refbox-entry-by-key)
             (lambda (_key)
               (user-error "Key not found"))))
    (should-error (refbox-read-reference) :type 'user-error)))

(ert-deftest refbox-test-select_refs_accepts_freeform_keys_like_citar ()
  "Key readers should accept raw typed citation keys like Citar."
  (let (requested-key require-match)
    (cl-letf (((symbol-function 'refbox--sync-current-bibliography-buffer-if-needed)
               #'ignore)
              ((symbol-function 'completing-read)
               (lambda (_prompt collection _predicate require &rest _args)
                 (setq require-match require)
                 (funcall collection "missing2026" nil t)
                 "missing2026"))
              ((symbol-function 'refbox-search-references)
               (lambda (&rest _args) nil))
              ((symbol-function 'refbox-entry-by-key)
               (lambda (key)
                 (setq requested-key key)
                 (user-error "Key not found"))))
      (should (equal (refbox-select-refs :multiple nil)
                     '("missing2026")))
      (should-not require-match)
      (should (equal requested-key "missing2026")))))

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

(ert-deftest refbox-test-completion-preloads_note_source_once_per_page ()
  "Completion rendering should batch preload note-source metadata."
  (let* ((first (copy-tree refbox-test-reference-candidate))
         (second (plist-put (copy-tree refbox-test-reference-candidate)
                            :key "doe2021"))
         (preloaded nil)
         (hasitems 0)
         (refbox-templates '((main . "%{key}")
                             (suffix . "%{indicators}")))
         (refbox-indicators
          (list (refbox-indicator-create
                 :symbol "N"
                 :function #'refbox-has-notes
                 :tag "has:notes")))
         (refbox-notes-source 'mock)
         (refbox-notes-sources
          `((mock
             :name "Mock Notes"
             :items ,#'ignore
             :open ,#'ignore
             :preload ,(lambda (references)
                         (setq preloaded
                               (mapcar
                                (lambda (reference)
                                  (refbox-reference-field reference "key"))
                                references)))
             :hasitems ,(lambda ()
                          (lambda (_key)
                            (setq hasitems (1+ hasitems))
                            nil))))))
    (cl-letf (((symbol-function 'refbox-rpc-request)
               (lambda (method _params)
                 (should (equal method refbox-rpc-method-search-entries))
                 (list :entries (list first second)))))
      (let* ((state (refbox--completion-state 2))
             (table (refbox--completion-table state)))
        (funcall table "" nil t)
        (should (equal preloaded '("smith2020" "doe2021")))
        (should (= hasitems 2))))))

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

(ert-deftest refbox-test-custom_resource_indicators_use_daemon_metadata ()
  "Custom resource indicators should not call expensive generic predicates."
  (let* ((candidate
          '(:key "alpha"
            :fields nil
            :resources nil
            :resource_kinds ["file" "doi"]))
         (refbox-indicators
          (list (refbox-indicator-create
                 :symbol "F"
                 :emptysymbol "-"
                 :padding ""
                 :function #'refbox-has-files
                 :tag "has:files")
                (refbox-indicator-create
                 :symbol "L"
                 :emptysymbol "-"
                 :padding ""
                 :function #'refbox-has-links
                 :tag "has:links"))))
    (cl-letf (((symbol-function 'refbox-reference-has-files-p)
               (lambda (&rest _)
                 (error "file indicator should use resource metadata")))
              ((symbol-function 'refbox-reference-has-links-p)
               (lambda (&rest _)
                 (error "link indicator should use resource metadata"))))
      (should (equal (substring-no-properties
                      (refbox-reference-indicators candidate))
                     "FL")))))

(ert-deftest refbox-test-custom_unknown_indicator_uses_configured_predicate ()
  "Unknown custom indicators should still use their configured predicate."
  (let ((calls 0)
        (candidate '(:key "alpha" :fields nil :resources nil)))
    (let ((refbox-indicators
           (list (refbox-indicator-create
                  :symbol "X"
                  :emptysymbol "-"
                  :padding ""
                  :function
                  (lambda ()
                    (lambda (reference)
                      (setq calls (1+ calls))
                      (equal (plist-get reference :key) "alpha")))))))
      (should (equal (substring-no-properties
                      (refbox-reference-indicators candidate))
                     "X"))
      (should (= calls 1)))))

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
        (should (equal (plist-get (cadar calls) :crossref_fields)
                       ["crossref"]))
        (should (equal (plist-get (car results) :key) "smith2020"))))))

(ert-deftest refbox-test-search-tag_shortcuts_use_daemon_resource_filters ()
  "Short indicator tokens should map to their long search tags."
  (let (calls)
    (cl-letf (((symbol-function 'refbox-rpc-request)
               (lambda (method params)
                 (push (list method params) calls)
                 (should (equal method refbox-rpc-method-search-entries))
                 (list :entries (list refbox-test-reference-candidate)))))
      (let ((results (refbox-search-references ":p alpha" 7)))
        (should (equal (plist-get (cadar calls) :query) "alpha"))
        (should (equal (plist-get (cadar calls) :resource_kinds)
                       ["file"]))
        (should (equal (plist-get (cadar calls) :crossref_fields)
                       ["crossref"]))
        (should (equal (plist-get (car results) :key) "smith2020"))))))

(ert-deftest refbox-test-search_link_tags_follow_link_fields ()
  "Link search tags should use the configured openable link fields."
  (let (calls)
    (cl-letf (((symbol-function 'refbox-rpc-request)
               (lambda (method params)
                 (push (list method params) calls)
                 (should (equal method refbox-rpc-method-search-entries))
                 (list :entries (list refbox-test-reference-candidate)))))
      (let ((results (refbox-search-references "has:links alpha" 7)))
        (should (equal (plist-get (cadar calls) :query) "alpha"))
        (should (equal (plist-get (cadar calls) :resource_kinds)
                       ["doi" "pmid" "pmcid" "url"]))
        (should (equal (plist-get (car results) :key) "smith2020")))))
  (let ((refbox-link-fields nil)
        calls)
    (cl-letf (((symbol-function 'refbox-rpc-request)
               (lambda (&rest _args)
                 (setq calls t)
                 (error "empty link field set should not query"))))
      (should-not (refbox-search-references "has:links alpha" 7))
      (should-not calls))))

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
                       (list :query "" :limit 7
                             :crossref_fields ["crossref"]
                             :allow_empty_query t)))
        (should (equal (plist-get (car results) :key) "smith2020"))))))

(ert-deftest refbox-test-search-can_restrict_native_search_fields ()
  "Search callers should be able to limit daemon FTS fields."
  (let (calls)
    (cl-letf (((symbol-function 'refbox-rpc-request)
               (lambda (method params)
                 (push (list method params) calls)
                 (should (equal method refbox-rpc-method-search-entries))
                 (list :entries (list refbox-test-reference-candidate)))))
      (let ((results (refbox-search-references
                      "alpha" 7 nil nil nil nil '("title" "entry_key"))))
        (should (equal (append (plist-get (cadar calls) :search_fields) nil)
                       '("title" "entry_key")))
        (should (equal (plist-get (car results) :key) "smith2020"))))))

(ert-deftest refbox-test-search-source_paths_sync_local_bibliographies_once ()
  "Scoped searches should index local source files without repeated hot-path syncs."
  (let* ((root (make-temp-file "refbox-local-source-" t))
         (source (expand-file-name "local.bib" root))
         (refbox--source-path-freshness (make-hash-table :test 'equal))
         calls)
    (unwind-protect
        (progn
          (with-temp-file source
            (insert "@article{alpha, title = {Alpha}}\n"))
          (cl-letf (((symbol-function 'refbox-rpc-request)
                     (lambda (method params)
                       (push (list method params) calls)
                       (cond
                        ((equal method refbox-rpc-method-sync-file)
                         '(:changed_file_count 1 :removed_file_count 0
                           :indexed_entry_count 1))
                        ((equal method refbox-rpc-method-search-entries)
                         (list :entries (list refbox-test-reference-candidate)))
                        (t
                         (error "unexpected method: %s" method))))))
            (refbox-search-references "alpha" 5 (list source))
            (refbox-search-references "alpha" 5 (list source))
            (let ((ordered (nreverse calls)))
              (should (equal (caar ordered) refbox-rpc-method-sync-file))
              (should (equal (plist-get (cadar ordered) :path) source))
              (should (eq (plist-get (cadar ordered) :explicit) t))
              (should (= (cl-count refbox-rpc-method-sync-file ordered
                                   :key #'car
                                   :test #'equal)
                         1))
              (should (= (cl-count refbox-rpc-method-search-entries ordered
                                   :key #'car
                                   :test #'equal)
                         2)))))
      (delete-directory root t))))

(ert-deftest refbox-test-search_cited_tag_uses_current_buffer_key_filter ()
  "The cited search tag should use a bounded current-buffer key filter."
  (let* ((cited (copy-tree refbox-test-reference-candidate))
         calls)
    (cl-letf (((symbol-function 'refbox-current-buffer-citation-keys)
               (lambda (&optional _buffer)
                 '("smith2020")))
              ((symbol-function 'refbox-rpc-request)
               (lambda (method params)
                 (push (list method params) calls)
                 (should (equal method refbox-rpc-method-search-entries))
                 (should (equal (append (plist-get params :keys) nil)
                                '("smith2020")))
                 (list :entries (list cited)))))
      (let ((results (refbox-search-references "is:cited" 5)))
        (should (equal (plist-get (cadar calls) :query) ""))
        (should (equal (plist-get (cadar calls) :limit) 5))
        (should (equal (plist-get (cadar calls) :allow_empty_query) t))
        (should (equal (mapcar (lambda (candidate)
                                 (plist-get candidate :key))
                               results)
                       '("smith2020")))))))

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
          (should (eq (plist-get params :ranked) :json-false))
          (should (equal (append (plist-get params :field_names) nil)
                         '("key" "title" "crossref")))
          (should (equal (append (plist-get params :search_fields) nil)
                         refbox-completion-search-fields)))))))

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

(ert-deftest refbox-test-entries-by-keys-uses_batched_rpc ()
  "Exact key hydration should use the daemon's batched key lookup."
  (let ((candidate (copy-tree refbox-test-reference-candidate))
        calls)
    (cl-letf (((symbol-function 'refbox-rpc-request)
               (lambda (method params)
                 (push (list method params) calls)
                 (should (equal method refbox-rpc-method-entries-by-keys))
                 (should (equal (append (plist-get params :keys) nil)
                                '("smith2020" "doe2021")))
                 (should (equal (plist-get params :limit_per_key) 2))
                 (should (equal (append (plist-get params :crossref_fields) nil)
                                '("xref")))
                 (list :entries (list candidate)))))
      (let ((refbox-crossref-variable "xref"))
        (should (equal (refbox-entries-by-keys
                        '("smith2020" "doe2021" "smith2020")
                        2)
                       (list candidate))))
      (should (= (length calls) 1)))))

(ert-deftest refbox-test-resolved_references_batch_exact_key_hydration ()
  "Reference resolution should not issue one lookup per citation key."
  (let ((alpha (list :key "alpha" :source_path "/tmp/a.bib"))
        (beta (list :key "beta" :source_path "/tmp/b.bib")))
    (cl-letf (((symbol-function 'refbox-entries-by-keys)
	       (lambda (keys limit)
	         (should (equal keys '("beta" "alpha")))
	         (should (equal limit 1))
	         (list alpha beta)))
              ((symbol-function 'refbox-entry-by-key)
               (lambda (_key)
                 (error "unique batched keys should not use scalar lookup"))))
      (should (equal (mapcar #'refbox--reference-key
                             (refbox--resolved-reference-list
                              '("beta" "alpha" "beta")))
                     '("beta" "alpha" "beta"))))))

(ert-deftest refbox-test-resolved_references_use_first_duplicate_like_citar ()
  "Batched exact lookup should keep the first duplicate candidate."
  (let ((first '(:key "dup2020" :source_path "/tmp/a.bib"))
        (second '(:key "dup2020" :source_path "/tmp/b.bib")))
    (cl-letf (((symbol-function 'refbox-entries-by-keys)
	       (lambda (_keys limit)
	         (should (equal limit 1))
	         (list first second)))
	      ((symbol-function 'refbox-entry-by-key)
	       (lambda (_key)
	         (error "duplicate first-hit resolution should stay batched"))))
      (should (equal (refbox--resolved-reference-list '("dup2020"))
		     (list first))))))

(ert-deftest refbox-test-get_entries_requires_explicit_limit ()
  "Entry hash materialization should stay bounded."
  (should-error (refbox-get-entries nil) :type 'user-error)
  (let (calls)
    (cl-letf (((symbol-function 'refbox-list-references)
               (lambda (limit offset)
                 (push (list limit offset) calls)
                 (if (zerop offset)
                     (list refbox-test-reference-candidate)
                   nil))))
      (let ((entries (refbox-get-entries 1)))
        (should (equal (gethash "smith2020" entries)
                       (refbox-reference-entry-alist
                        refbox-test-reference-candidate)))
        (should (equal (nreverse calls)
                       '((1 0))))))))

(ert-deftest refbox-test-entry-field-accessors-return_entry_alists ()
  "Entry lookup helpers should expose field values for extension code."
  (let (calls)
    (cl-letf (((symbol-function 'refbox-entries-by-keys)
               (lambda (keys limit-per-key)
                 (push (list keys limit-per-key) calls)
                 (list refbox-test-reference-candidate))))
      (let ((entry (refbox-get-entry "smith2020")))
        (should (equal calls '((("smith2020") 1))))
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

(ert-deftest refbox-test-get_entry_missing_key_matches_citar ()
  "Missing public entry lookups should return nil like Citar."
  (cl-letf (((symbol-function 'refbox-entries-by-keys)
	       (lambda (keys limit-per-key)
	         (should (equal keys '("missing2020")))
	         (should (equal limit-per-key 1))
	         nil))
            ((symbol-function 'refbox-entry-by-key)
             (lambda (&rest _args)
               (error "missing get-entry should not use scalar lookup"))))
    (should-not (refbox-get-entry "missing2020"))
    (should-not (refbox-get-value "title" "missing2020"))
    (should-not (refbox-get-field-with-value '("title") "missing2020"))))

(ert-deftest refbox-test-get_entry_uses_first_duplicate_like_citar ()
  "Public entry lookup should return the first duplicate entry like Citar."
  (let ((first '(:key "dup2020"
                 :fields ((:raw_name "title"
                           :lookup_name "title"
                           :value "First"))))
        (second '(:key "dup2020"
                  :fields ((:raw_name "title"
                            :lookup_name "title"
                            :value "Second")))))
    (cl-letf (((symbol-function 'refbox-entries-by-keys)
	       (lambda (_keys limit-per-key)
	         (should (equal limit-per-key 1))
	         (list first second)))
	      ((symbol-function 'refbox-entry-by-key)
	       (lambda (_key)
	         (error "get-entry should not use scalar duplicate fallback"))))
      (should (equal (cdr (assoc-string "title" (refbox-get-entry "dup2020") t))
                     "First")))))

(ert-deftest refbox-test-read-reference_accepts_candidate_predicates ()
  "Reference selection should support filtering by candidate metadata."
  (let* ((alpha (copy-tree refbox-test-reference-candidate))
         (beta (plist-put (copy-tree refbox-test-reference-candidate)
                          :key "beta2021")))
    (cl-letf (((symbol-function 'refbox-rpc-request)
               (lambda (_method _params)
                 (list :entries (list alpha beta))))
              ((symbol-function 'refbox-entry-by-key)
               (lambda (candidate)
                 (plist-put (copy-sequence candidate) :refbox_partial nil)))
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
  "File field parsers should match Citar's path-list parsing."
  (should-not (refbox-resource-parse-file-field-default " "))
  (should (equal (delete-dups (refbox-resource-parse-file-field-default "foo"))
                 '("foo")))
  (should (equal (delete-dups (refbox-resource-parse-file-field-default "foo;bar"))
                 '("foo" "bar")))
  (should (equal (delete-dups (refbox-resource-parse-file-field-default " foo ; bar ; "))
                 '("foo" "bar")))
  (should (equal (delete-dups (refbox-resource-parse-file-field-default "foo:bar;baz"))
                 '("foo:bar" "baz")))
  (should (equal (delete-dups (refbox-resource-parse-file-field-default "foo:bar;;baz"))
                 '("foo:bar" "baz")))
  (should (equal (refbox-resource-parse-file-field-default
                  "foo\\;bar; baz ; ")
                 '("foo;bar" "foo\\;bar" "baz")))
  (should (equal (delete-dups (refbox-resource-parse-file-field-default "foo;bar\\"))
                 '("foo" "bar\\"))))

(ert-deftest refbox-test-resource-triplet-file-parser-matches-citar ()
  "Triplet file parser should preserve Citar's candidate behavior."
  (should-not (refbox-resource-parse-file-field-triplet "foo.pdf"))
  (should (equal (delete-dups
                  (refbox-resource-parse-file-field-triplet
                   ":foo.pdf:PDF"))
                 '("foo.pdf")))
  (should (equal (delete-dups
                  (refbox-resource-parse-file-field-triplet
                   ":foo.pdf:PDF,:bar.pdf:PDF"))
                 '("foo.pdf:PDF,:bar.pdf" "foo.pdf" "bar.pdf")))
  (should (equal (refbox-resource-parse-file-field-triplet
                  ": foo.pdf :PDF, : bar.pdf :PDF")
                 '(" foo.pdf :PDF, : bar.pdf " " foo.pdf :PDF, : bar.pdf "
                   " foo.pdf " " foo.pdf " " bar.pdf " " bar.pdf ")))
  (should (equal (refbox-resource-parse-file-field-triplet
                  ":foo,bar.pdf:PDF")
                 '("foo,bar.pdf" "foo,bar.pdf")))
  (should (equal (refbox-resource-parse-file-field-triplet
                  "Title\\: Subtitle:C\\:\\\\title.pdf:PDF")
                 '("C:\\title.pdf" "C\\:\\\\title.pdf"
                   "C:\\title.pdf" "C\\:\\\\title.pdf"))))

(ert-deftest refbox-test-reference-files-resolve_unescaped_file_fields ()
  "File lookup should try unescaped variants from bibliography file fields."
  (let* ((root (make-temp-file "refbox-escaped-file-" t))
         (refs (expand-file-name "refs" root))
         (candidate
          (list :key "escaped"
                :source_path (expand-file-name "main.bib" refs)
                :resources
                (list (list :key "escaped"
                            :source_path (expand-file-name "main.bib" refs)
                            :owner_key "escaped"
                            :owner_source_path (expand-file-name "main.bib" refs)
                            :kind "file"
                            :raw_name "file"
                            :lookup_name "file"
                            :value "paper\\:edition.pdf")))))
    (unwind-protect
        (progn
          (make-directory refs t)
          (with-temp-file (expand-file-name "paper:edition.pdf" refs))
          (should (equal (mapcar #'file-name-nondirectory
                                 (refbox-reference-files
                                  candidate
                                  (refbox--candidate-resources candidate)))
                         '("paper:edition.pdf"))))
      (delete-directory root t))))

(ert-deftest refbox-test-reference-files_resolve_field_files_like_citar ()
  "File-field lookup should use Citar's library-then-bibliography order."
  (let* ((root (make-temp-file "refbox-field-files-" t))
         (refs (expand-file-name "refs" root))
         (library (expand-file-name "library" root))
         (source (expand-file-name "main.bib" refs))
         (paper (expand-file-name "paper.pdf" refs))
         (library-paper (expand-file-name "paper.pdf" library))
         (supplement (expand-file-name "supplement.pdf" library))
         (candidate
          (list :key "mixed"
                :source_path source
                :resources
                (list (list :key "mixed"
                            :source_path source
                            :owner_key "mixed"
                            :owner_source_path source
                            :kind "file"
                            :raw_name "file"
                            :lookup_name "file"
                            :value "paper.pdf; supplement.pdf")))))
    (unwind-protect
        (progn
          (make-directory refs t)
          (make-directory library t)
          (with-temp-file paper)
          (with-temp-file library-paper)
          (with-temp-file supplement)
          (let ((refbox-library-paths (list library))
                (refbox-library-file-extensions '("pdf"))
                (refbox-file-sources (list (car refbox--default-file-sources))))
	            (should (equal (refbox-reference-files
	                            candidate
	                            (refbox--candidate-resources candidate))
	                           (list library-paper supplement)))))
      (delete-directory root t))))

(ert-deftest refbox-test-reference-files_resolve_field_files_from_all_bibliography_dirs ()
  "File-field lookup should use every explicit bibliography directory like Citar."
  (let* ((root (make-temp-file "refbox-field-all-bib-dirs-" t))
         (refs-a (expand-file-name "refs-a" root))
         (refs-b (expand-file-name "refs-b" root))
         (source-a (expand-file-name "a.bib" refs-a))
         (source-b (expand-file-name "b.bib" refs-b))
         (paper (expand-file-name "paper.pdf" refs-b))
         (candidate
          (list :key "mixed"
                :source_path source-a
                :resources
                (list (list :key "mixed"
                            :source_path source-a
                            :owner_key "mixed"
                            :owner_source_path source-a
                            :kind "file"
                            :raw_name "file"
                            :lookup_name "file"
                            :value "paper.pdf")))))
    (unwind-protect
        (progn
          (make-directory refs-a t)
          (make-directory refs-b t)
          (with-temp-file source-a)
          (with-temp-file source-b)
          (with-temp-file paper)
          (let ((refbox-bibliography (list source-a source-b))
                (refbox-file-sources (list (car refbox--default-file-sources))))
            (should (equal (refbox-reference-files
                            candidate
                            (refbox--candidate-resources candidate))
                           (list paper)))))
      (delete-directory root t))))

(ert-deftest refbox-test-resource_extensions_are_literal_like_citar ()
  "Resource extension filters should not normalize case or leading dots."
  (let* ((root (make-temp-file "refbox-literal-extension-" t))
         (refs (expand-file-name "refs" root))
         (source (expand-file-name "main.bib" refs))
         (paper (expand-file-name "paper.PDF" refs))
         (candidate
          (list :key "mixed"
                :source_path source
                :resources
                (list (list :key "mixed"
                            :source_path source
                            :owner_key "mixed"
                            :owner_source_path source
                            :kind "file"
                            :raw_name "file"
                            :lookup_name "file"
                            :value "paper.PDF")))))
    (unwind-protect
        (progn
          (make-directory refs t)
          (with-temp-file paper)
          (let ((refbox-library-file-extensions '("pdf"))
                (refbox-file-sources (list (car refbox--default-file-sources))))
            (should-not (refbox-reference-files
                         candidate
                         (refbox--candidate-resources candidate))))
          (let ((refbox-library-file-extensions '("PDF"))
                (refbox-file-sources (list (car refbox--default-file-sources))))
            (should (equal (refbox-reference-files
                            candidate
                            (refbox--candidate-resources candidate))
                           (list paper))))
          (let ((refbox-library-file-extensions '(".PDF"))
                (refbox-file-sources (list (car refbox--default-file-sources))))
            (should-not (refbox-reference-files
                         candidate
                         (refbox--candidate-resources candidate)))))
      (delete-directory root t))))

(ert-deftest refbox-test-reference-files_combine_fields_and_library_like_citar ()
  "File lookup should combine field and library-path resources."
  (let* ((root (make-temp-file "refbox-resources-" t))
         (refs (expand-file-name "refs" root))
         (library (expand-file-name "library" root))
         (subdir (expand-file-name "nested" library))
         (paper (expand-file-name "paper.pdf" refs))
         (library-paper (expand-file-name "smith2020.pdf" library))
         (library-extra (expand-file-name "smith2020-extra.pdf" subdir))
         (candidate (copy-tree refbox-test-reference-candidate)))
    (unwind-protect
        (progn
          (make-directory refs t)
          (make-directory subdir t)
          (dolist (file (list paper
                              library-paper
                              library-extra
                              (expand-file-name "smith2020.html" library)))
            (with-temp-file file))
          (setq candidate (plist-put candidate :source_path
                                     (expand-file-name "main.bib" refs)))
          (let ((refbox-library-paths (list library))
                (refbox-library-paths-recursive t)
                (refbox-library-file-extensions '("pdf"))
                (refbox-file-additional-files-separator "-"))
            (cl-letf (((symbol-function 'refbox-rpc-request)
                       (lambda (method params)
                         (pcase method
                           ((pred (equal refbox-rpc-method-library-files-by-keys))
                            (should (equal (append (plist-get params :keys) nil)
                                           '("smith2020")))
                            (should (equal (append (plist-get params :roots) nil)
                                           (list (file-name-as-directory
                                                  library))))
                            (should (eq (plist-get params :recursive) t))
                            (should (equal (append (plist-get params :extensions) nil)
                                           '("pdf")))
                            (should (equal (plist-get params :additional_separator)
                                           "-"))
                            (list :files (list library-paper library-extra)))
                           ((pred (equal refbox-rpc-method-resolve-files))
                            (should (equal (append (plist-get params :files) nil)
                                           '("paper.pdf")))
                            (if (equal (append (plist-get params :roots) nil)
                                       (list (file-name-as-directory refs)))
                                (list :files (list paper))
                              (list :files nil)))
                           (_ (error "unexpected method: %s" method))))))
              (should
               (equal (mapcar #'file-name-nondirectory
                              (refbox-reference-files
                               candidate
                               (refbox--candidate-resources candidate)))
                      '("paper.pdf" "smith2020.pdf"
                        "smith2020-extra.pdf"))))))
      (delete-directory root t))))

(ert-deftest refbox-test-reference-files_accept_string_library_options ()
  "Library path and extension options should accept single strings."
  (let* ((root (make-temp-file "refbox-resources-" t))
         (library (expand-file-name "library" root))
         (paper (expand-file-name "smith2020.pdf" library))
         (candidate '(:key "smith2020" :resources nil)))
    (unwind-protect
        (progn
          (make-directory library t)
          (with-temp-file paper)
          (let ((refbox-library-paths library)
                (refbox-library-file-extensions "pdf"))
            (cl-letf (((symbol-function 'refbox-rpc-request)
                       (lambda (method params)
                         (should (eq method
                                     refbox-rpc-method-library-files-by-keys))
                         (should (equal (append (plist-get params :roots) nil)
                                        (list (file-name-as-directory
                                               library))))
                         (should (equal (append (plist-get params :extensions) nil)
                                        '("pdf")))
                         (list :files (list paper)))))
              (should
               (equal (refbox-reference-files candidate nil)
                      (list paper))))
            (cl-letf (((symbol-function 'refbox-rpc-request)
                       (lambda (&rest _args)
                         (error "unexpected RPC"))))
              (should (refbox-reference-has-files-p candidate)))))
      (delete-directory root t))))

(ert-deftest refbox-test-library_file_lookup_can_use_daemon_cache_only ()
  "Default open may ask the daemon for cached library matches only."
  (let* ((root (make-temp-file "refbox-cache-only-files-" t))
         (paper (expand-file-name "smith2020.pdf" root))
         calls)
    (unwind-protect
        (let ((refbox-library-paths (list root))
              (refbox-library-file-extensions '("pdf")))
          (with-temp-file paper)
          (cl-letf (((symbol-function 'refbox-rpc-request)
                     (lambda (method params)
                       (should (eq method refbox-rpc-method-library-files-by-keys))
                       (push params calls)
                       (if (plist-get params :cache_only)
                           (list :files nil)
                         (list :files (list paper))))))
            (let ((refbox--library-files-cache-only t))
              (let ((table (refbox-resource-file-source-library-items
                            '("smith2020"))))
                (should-not (gethash "smith2020" table))))
            (let ((table (refbox-resource-file-source-library-items
                          '("smith2020"))))
              (should (equal (gethash "smith2020" table)
                             (list paper))))
            (should (= (length calls) 2))
            (should (plist-get (cadr calls) :cache_only))
            (should-not (plist-get (car calls) :cache_only))))
      (delete-directory root t))))

(ert-deftest refbox-test-recursive_file_index_preserves_citar_order ()
  "Recursive file scans should return root files before sorted subdirectories."
  (let* ((root (make-temp-file "refbox-recursive-order-" t))
         (dir-a (expand-file-name "a" root))
         (dir-b (expand-file-name "b" root))
         (root-file (expand-file-name "alpha.pdf" root))
         (file-a (expand-file-name "alpha.pdf" dir-a))
         (file-b (expand-file-name "alpha.pdf" dir-b)))
    (unwind-protect
        (progn
          (make-directory dir-a t)
          (make-directory dir-b t)
          (dolist (file (list root-file file-a file-b))
            (with-temp-file file))
          (should
           (equal
            (refbox-resource--files-for-keys-normalized
             '("alpha")
             (list (file-name-as-directory root))
             t
             '("pdf")
             nil
             t)
            (list root-file file-a file-b))))
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
                 `((:items ,(lambda (keys)
                              (setq seen-items keys)
                              (refbox-test-key-table
                               keys
                               (lambda (_key)
                                 (list external))))
                    :hasitems ,(lambda ()
                                 (lambda (key)
                                   (push key seen-has)
                                   t))))))
            (should (equal (refbox-reference-files candidate nil)
                           (list external)))
            (should (refbox-reference-has-files-p candidate)))
          (should (equal seen-items '("alpha")))
          (should (equal (nreverse seen-has) '("alpha"))))
      (delete-directory root t))))

(ert-deftest refbox-test-resource_file_sources_fallback_to_items_for_has_files ()
  "File sources without :hasitems should still support indicators."
  (let ((candidate '(:key "alpha" :resources nil))
        called)
    (let ((refbox-file-sources
           `((:items ,(lambda (keys)
                        (setq called keys)
                        (refbox-test-key-table
                         keys
                         (lambda (_key)
                           '("/tmp/external.pdf"))))))))
      (should (refbox-reference-has-files-p candidate)))
    (should (equal called '("alpha")))))

(ert-deftest refbox-test-resource_file_sources_reject_invalid_items ()
  "Broken file sources should fail at the source boundary."
  (let ((candidate '(:key "alpha" :resources nil))
        (refbox-file-sources '((broken))))
    (should-error (refbox-reference-files candidate nil) :type 'user-error)))

(ert-deftest refbox-test-file_variable_drives_indexed_file_resources ()
  "The configured file variable should drive indexed file resources."
  (let ((candidate
         '(:key "alpha"
           :fields ((:lookup_name "pdf" :value "alpha.pdf"))
           :resources nil))
        (refbox-file-variable "pdf"))
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
                    :items ,(lambda (keys)
                              (refbox-test-key-table
                               keys
                               (lambda (key)
                                 (list (format "note:%s" key)))))
                    :hasitems ,#'ignore
                    :open ,#'ignore))))
            (cl-letf (((symbol-function 'refbox-entries-by-keys)
	               (lambda (keys limit)
	                 (should (equal keys '("alpha")))
	                 (should (equal limit 1))
	                 (list candidate)))
                      ((symbol-function 'refbox-entry-by-key)
                       (lambda (_key)
                         (error "resource lookup should use batched hydration"))))
              (let ((files (refbox-get-files "alpha"))
                    (links (refbox-get-links "alpha"))
                    (notes (refbox-get-notes '("alpha" "alpha"))))
                (should (equal (gethash "alpha" files) (list paper)))
                (should (equal (gethash "alpha" links)
                               '("https://doi.org/10.1000/alpha")))
                (should (equal (gethash "alpha" notes) '("note:alpha")))
                (should-error (refbox-get-files) :type 'user-error)
                (should-error (refbox-get-links) :type 'user-error)
                (should-error (refbox-get-notes) :type 'user-error)
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
             :items ,(lambda (_keys)
                       (make-hash-table :test 'equal))
             :hasitems ,(lambda ()
                          (lambda (key)
                            (equal key "smith2020")))
             :open ,#'ignore))))
    (cl-letf (((symbol-function 'refbox-entries-by-keys)
	       (lambda (keys limit)
	         (should (equal keys '("smith2020")))
	         (should (equal limit 1))
	         (list candidate)))
              ((symbol-function 'refbox-entry-by-key)
               (lambda (_key)
                 (error "resource predicates should use batched hydration"))))
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

(ert-deftest refbox-test-note_predicate_caches_source_predicate_and_keys ()
  "Note indicator checks should not rebuild predicates or recheck keys."
  (let* ((predicate-builds 0)
         (key-checks 0)
         (candidate '(:key "alpha" :fields nil :resources nil))
         (refbox-notes-source 'mock)
         (refbox-notes-sources
          `((mock
             :items ,(lambda (_keys)
                       (make-hash-table :test 'equal))
             :hasitems ,(lambda ()
                          (setq predicate-builds (1+ predicate-builds))
                          (lambda (key)
                            (setq key-checks (1+ key-checks))
                            (equal key "alpha")))
             :open ,#'ignore))))
    (refbox--with-dynamic-cache (make-hash-table :test 'eq)
      (should (refbox-reference-has-notes-p candidate))
      (should (refbox-reference-has-notes-p candidate)))
    (should (= predicate-builds 1))
    (should (= key-checks 1))))

(ert-deftest refbox-test-note_predicate_accepts_empty_source ()
  "Note sources may return nil when they can prove no notes exist."
  (let* ((candidate '(:key "alpha" :fields nil :resources nil))
         (refbox-notes-source 'mock)
         (refbox-notes-sources
          `((mock
             :items ,(lambda (_keys)
                       (make-hash-table :test 'equal))
             :hasitems ,(lambda () nil)
             :open ,#'ignore))))
    (should-not (refbox-reference-has-notes-p candidate))))

(ert-deftest refbox-test-file_note_predicate_skips_empty_note_paths ()
  "File-backed note indicators should be free when no note paths are configured."
  (let ((refbox-notes-paths nil))
    (should-not (refbox-note-source-file-has-items))))

(ert-deftest refbox-test-note_predicate_hydrates_key_references ()
  "Note predicates should check cross-reference keys from hydrated references."
  (let* ((candidate (plist-put (copy-tree refbox-test-reference-candidate)
                               :fields
                               (append
                                (plist-get refbox-test-reference-candidate
                                           :fields)
                                '((:raw_name "crossref"
                                   :lookup_name "crossref"
                                   :value "parent2020")))))
         (seen nil)
         (refbox-notes-source 'mock)
         (refbox-notes-sources
          `((mock
             :items ,(lambda (_keys)
                       (make-hash-table :test 'equal))
             :hasitems ,(lambda ()
                          (lambda (key)
                            (push key seen)
                            (equal key "parent2020")))
             :open ,#'ignore))))
    (cl-letf (((symbol-function 'refbox-entries-by-keys)
	       (lambda (keys limit)
	         (should (equal keys '("smith2020")))
	         (should (equal limit 1))
	         (list candidate)))
              ((symbol-function 'refbox-entry-by-key)
               (lambda (_key)
                 (error "note predicate should use batched hydration"))))
      (should (funcall (refbox-has-notes) "smith2020"))
      (should (equal (nreverse seen) '("smith2020" "parent2020"))))))

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
            (cl-letf (((symbol-function 'refbox-rpc-request)
                       (lambda (method params)
                         (should (equal method
                                        refbox-rpc-method-library-files-by-keys))
                         (should (equal (plist-get params :keys)
                                        ["child2021" "parent2020"]))
                         `(:files
                           (,(expand-file-name "parent2020.pdf" library))))))
              (should (equal (mapcar #'file-name-nondirectory
                                     (refbox-reference-files
                                      candidate
                                      (refbox--candidate-resources candidate)))
                             '("parent2020.pdf"))))
            (cl-letf (((symbol-function 'refbox-rpc-request)
                       (lambda (&rest _args)
                         (error "unexpected RPC"))))
              (should (refbox-reference-has-files-p candidate)))))
      (delete-directory root t))))

(ert-deftest refbox-test-indexed_file_lookup_skips_library_walk_without_file_resources ()
  "Link-only resources must not force recursive library discovery."
  (let ((candidate
         '(:key "alpha"
           :fields nil
           :resources ((:kind "doi"
                        :lookup_name "doi"
                        :value "10.1000/example")))))
    (cl-letf (((symbol-function 'refbox-resource--library-dirs)
               (lambda ()
                 (error "library directories should not be listed")))
              ((symbol-function 'refbox-resource--source-dirs)
               (lambda (&rest _)
                 (error "source directories should not be listed"))))
      (should-not
       (refbox-resource-file-source--indexed-items-for-candidate
        candidate
        (refbox--candidate-resources candidate))))))

(ert-deftest refbox-test-indexed_file_lookup_uses_daemon_cache_only ()
  "Default open must not cold-scan recursive library roots for file fields."
  (let* ((root (make-temp-file "refbox-field-cache-only-" t))
         (library (expand-file-name "library" root))
         (refs (expand-file-name "refs" root))
         (candidate
          (list :key "alpha"
                :source_path (expand-file-name "main.bib" refs)
                :resources
                '((:kind "file"
                   :lookup_name "file"
                   :value "alpha.pdf")))))
    (unwind-protect
        (progn
          (make-directory library t)
          (make-directory refs t)
          (let ((refbox-library-paths (list library))
                (refbox-library-paths-recursive t)
                (refbox-library-file-extensions '("pdf"))
                (refbox--library-files-cache-only t))
            (cl-letf (((symbol-function 'refbox-rpc-request)
                       (lambda (method params)
                         (should (eq method refbox-rpc-method-resolve-files))
                         (should (eq (plist-get params :cache_only) t))
                         (list :files nil))))
              (should-not
               (refbox-resource-file-source--indexed-items-for-candidate
                candidate
                (refbox--candidate-resources candidate))))))
      (delete-directory root t))))

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
                           (expand-file-name "doe/2021.org" root))))
          (let ((refbox-notes-paths root)
                (refbox-file-note-extensions "org"))
            (should (equal (refbox-note-filename "smith2020") existing))))
	      (delete-directory root t))))

(ert-deftest refbox-test-note_filename_uses_literal_extension_like_citar ()
  "Note filename generation should append the configured extension literally."
  (let* ((root (make-temp-file "refbox-note-literal-extension-" t))
         (expected (expand-file-name "smith2020..org" root)))
    (unwind-protect
        (let ((refbox-notes-paths (list root))
              (refbox-file-note-extensions '(".org")))
          (should (equal (refbox-note-filename "smith2020") expected)))
      (delete-directory root t))))

(ert-deftest refbox-test-file_note_keys_use_regexp_additional_separator ()
  "File-backed note key enumeration should use Citar-style regexp separators."
  (let* ((root (make-temp-file "refbox-note-keys-" t))
         (file (expand-file-name "alpha extra.org" root)))
    (unwind-protect
        (progn
          (with-temp-file file)
          (let ((refbox-notes-paths (list root))
                (refbox-file-note-extensions '("org"))
                (refbox-file-additional-files-separator "[[:space:]]"))
            (should (equal (sort (refbox-note-source-file-keys)
                                 #'string-lessp)
                           '("alpha" "alpha extra")))
            (should (equal (sort (refbox-search--key-filter-for-post-tag
                                  "has:notes")
                                 #'string-lessp)
                           '("alpha" "alpha extra")))))
      (delete-directory root t))))

(ert-deftest refbox-test-create_note_accepts_key_and_entry ()
  "Note creation should accept an explicit key and entry alist."
  (let (seen)
    (let ((refbox-notes-source 'mock)
          (refbox-notes-sources
           `((mock
              :items ,#'ignore
              :hasitems ,#'ignore
              :open ,#'ignore
              :create ,(lambda (key entry)
                         (setq seen (list key entry)))))))
      (refbox-create-note
       "alpha"
       '(("title" . "Alpha Reference")
         ("author" . "Smith, Jane")
         ("=type=" . "article"))))
    (should (equal (car seen) "alpha"))
    (should (equal (refbox-get-value "title" (cadr seen))
                   "Alpha Reference"))
    (should (equal (refbox-get-value "=type=" (cadr seen))
                   "article"))))

(ert-deftest refbox-test-default_org_note_format_matches_citar_layout ()
  "The default Org note template should include a bibliography section."
  (with-temp-buffer
    (refbox-org-format-note-default
     "smith2020"
     (refbox-reference-entry-alist refbox-test-reference-candidate))
    (should (equal (buffer-string)
                   "#+title: Notes on Smith, Alpha Reference Title\n\n\n\n#+print_bibliography:"))
    (should (looking-at "\n\n#\\+print_bibliography:"))))

(ert-deftest refbox-test-file_note_creation_uses_side_effect_formatter ()
  "File-backed note creation should let formatters initialize the note buffer."
  (let* ((root (make-temp-file "refbox-create-note-" t))
         (file (expand-file-name "alpha.org" root)))
    (unwind-protect
        (let ((refbox-notes-paths (list root))
              (refbox-file-note-extensions '("org"))
              (refbox-open-note-function #'find-file)
              (refbox-note-format-function
               (lambda (key entry)
                 (insert "note:" key ":" (refbox-get-value "=key=" entry)))))
          (should (equal (refbox-note-source-file-create
                          "alpha"
                          '(("=key=" . "alpha")))
                         file))
          (should (equal (buffer-string) "note:alpha:alpha")))
      (when-let ((buffer (find-buffer-visiting file)))
        (with-current-buffer buffer
          (set-buffer-modified-p nil))
        (kill-buffer buffer))
      (delete-directory root t))))

(ert-deftest refbox-test-file_note_creation_uses_find_file_like_citar ()
  "File-backed note creation should not route creation through the note opener."
  (let* ((root (make-temp-file "refbox-create-note-find-file-" t))
         (file (expand-file-name "alpha.org" root)))
    (unwind-protect
        (let ((refbox-notes-paths (list root))
              (refbox-file-note-extensions '("org"))
              (refbox-open-note-function
               (lambda (_file)
                 (error "creation should use find-file directly")))
              (refbox-note-format-function
               (lambda (key _entry)
                 (insert "created:" key))))
          (should (equal (refbox-note-source-file-create "alpha" nil)
                         file))
          (should (equal (buffer-string) "created:alpha")))
      (when-let ((buffer (find-buffer-visiting file)))
        (with-current-buffer buffer
          (set-buffer-modified-p nil))
        (kill-buffer buffer))
      (delete-directory root t))))

(ert-deftest refbox-test-file_note_creation_requires_formatter_like_citar ()
  "New file-backed notes should require a configured formatter."
  (let* ((root (make-temp-file "refbox-create-note-format-required-" t))
         (file (expand-file-name "alpha.org" root)))
    (unwind-protect
        (let ((refbox-notes-paths (list root))
              (refbox-file-note-extensions '("org"))
              (refbox-note-format-function nil))
          (should-error (refbox-note-source-file-create "alpha" nil)
                        :type 'user-error))
      (when-let ((buffer (find-buffer-visiting file)))
        (with-current-buffer buffer
          (set-buffer-modified-p nil))
        (kill-buffer buffer))
      (delete-directory root t))))

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
            (should (equal (refbox-note-source-items candidate)
                           (list note)))
            (should (refbox-note-source-has-items-p candidate))
            (let ((table (refbox-note-source-file-items '("parent2020"))))
              (should (equal (gethash "parent2020" table)
                             (list note))))
            (should (funcall (refbox-note-source-file-has-items)
                             "parent2020"))))
      (delete-directory root t))))

(ert-deftest refbox-test-note_sources_are_swappable ()
  "Note commands should use the configured note source protocol."
  (let (opened created)
    (let ((refbox-notes-source 'mock)
          (refbox-notes-sources
           `((mock
              :items ,(lambda (keys)
                        (refbox-test-key-table
                         keys
                         (lambda (key)
                           (list (format "note:%s" key)))))
              :all-items ,(lambda ()
                            '("note:all" "note:orphan"))
              :hasitems ,(lambda ()
                           (lambda (key)
                             (equal key "smith2020")))
              :open ,(lambda (item)
                       (push item opened))
              :create ,(lambda (key entry)
                         (push (list key (refbox-get-value "=key=" entry))
                               created)
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
      (should (equal created '(("smith2020" "smith2020"))))
      (should (equal opened '("note:smith2020")))
	      (cl-letf (((symbol-function 'completing-read)
	                 (lambda (_prompt collection &rest _args)
	                   (cadr (all-completions "" collection)))))
	        (call-interactively #'refbox-open-note))
	      (should (equal opened '("note:orphan" "note:smith2020"))))))

(ert-deftest refbox-test-note_source_all_items_uses_enumerated_note_keys ()
  "Note source global listing should not enumerate the bibliography."
  (let ((refbox-notes-source 'mock)
        (refbox-notes-sources
         `((mock
            :keys ,(lambda () '("alpha" "beta"))
            :items ,(lambda (keys)
                      (refbox-test-key-table
                       keys
                       (lambda (key)
                         (list (format "note:%s" key)))))
            :hasitems ,#'ignore
            :open ,#'ignore))))
    (should (equal (sort (refbox-note-source-all-items)
                         #'string-lessp)
                   '("note:alpha" "note:beta")))))

(ert-deftest refbox-test-note_source_all_items_accepts_empty_key_enumeration ()
  "Enumerable note sources may report no notes."
  (let ((refbox-notes-source 'mock)
        (refbox-notes-sources
         `((mock
            :keys ,(lambda () nil)
            :items ,#'ignore
            :hasitems ,#'ignore
            :open ,#'ignore))))
    (should-not (refbox-note-source-all-items))))

(ert-deftest refbox-test-note_source_all_items_requires_enumeration ()
  "Global note listing should fail when the note source cannot enumerate notes."
  (let ((refbox-notes-source 'mock)
        (refbox-notes-sources
         `((mock
            :items ,#'ignore
            :hasitems ,#'ignore
            :open ,#'ignore))))
    (should-error (refbox-note-source-all-items) :type 'user-error)))

(ert-deftest refbox-test-open_notes_accepts_single_note_by_default ()
  "Opening notes should not prompt when only one note is available."
  (let (opened)
    (let ((refbox-notes-source 'mock)
          (refbox-notes-sources
           `((mock
              :items ,(lambda (keys)
                        (refbox-test-key-table
                         keys
                         (lambda (key)
                           (list (format "note:%s" key)))))
              :hasitems ,(lambda ()
                           (lambda (key)
                             (equal key "smith2020")))
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
                 (list :items #'ignore
                       :hasitems #'ignore
                       :open #'ignore
                       :create #'ignore))
                'mock))
    (should (alist-get 'mock refbox-notes-sources))
    (should (eq (refbox-remove-notes-source 'mock) 'mock))
    (should-not (alist-get 'mock refbox-notes-sources))
    (should (eq (refbox-register-notes-source
                 'mock
                 (list :items #'ignore
                       :hasitems #'ignore
                       :open #'ignore))
                'mock))
    (should (alist-get 'mock refbox-notes-sources))
    (should (eq (refbox-remove-notes-source 'mock) 'mock))
    (should-not (alist-get 'mock refbox-notes-sources))))

(ert-deftest refbox-test-note_source_registration_validates_config ()
  "Note source registration should reject broken adapters up front."
  (let ((refbox-notes-sources nil))
    (should-error
     (refbox-register-notes-source
      "mock" (list :items #'ignore :hasitems #'ignore :open #'ignore))
     :type 'user-error)
    (should-error
     (refbox-register-notes-source
      'mock (list :items #'ignore :open #'ignore))
     :type 'user-error)
    (should-error
     (refbox-register-notes-source
      'mock (list :items #'ignore :hasitems #'ignore :open "no"))
     :type 'user-error)
    (should-error
     (refbox-register-notes-source
      'mock (list :name 'bad
                  :items #'ignore
                  :hasitems #'ignore
                  :open #'ignore))
     :type 'user-error)
    (should-error
     (refbox-register-notes-source
      'mock (list :category "bad"
                  :items #'ignore
                  :hasitems #'ignore
                  :open #'ignore))
     :type 'user-error)
    (should-error
     (refbox-register-notes-source
      'mock (list :items #'ignore
                  :hasitems "no"
                  :open #'ignore))
     :type 'user-error)
    (should (eq (refbox-register-notes-source
                 'mock
                 (list :category 'file
                       :items #'ignore
                       :hasitems #'ignore
                       :open #'ignore))
                'mock))
    (let (warnings)
      (cl-letf (((symbol-function 'display-warning)
                 (lambda (type message &rest _args)
                   (push (list type message) warnings))))
        (should (eq (refbox-register-notes-source
                     'mock
                     (list :items #'ignore
                           :hasitems #'ignore
                           :open #'ignore
                           :extra t))
                    'mock)))
      (should (alist-get 'mock refbox-notes-sources))
      (should (equal (caar warnings) 'refbox))
      (should (string-match-p "unknown property" (cadar warnings))))))

(ert-deftest refbox-test-link-resource-formatting ()
  "Identifier and URL resources should format into openable links."
  (should (equal (refbox-resource-link-url '(:kind "doi" :value "{10.1000/refbox}"))
                 "https://doi.org/10.1000/refbox"))
  (should (equal (refbox-resource-link-url '(:kind "doi" :value "https://example.test/id"))
                 "https://doi.org/https://example.test/id"))
  (should (equal (refbox-resource-link-url '(:kind "url" :value "{https://example.test}"))
                 "https://example.test")))

(ert-deftest refbox-test-link_resources_use_single_field_configuration ()
  "Link indicators and openers should share `refbox-link-fields'."
  (let ((candidate '(:key "alpha"
                     :resource_kinds ["eprint"]
                     :resources ((:kind "eprint" :value "12345")))))
    (should-not (refbox-reference-has-links-p candidate))
    (should-not (refbox-reference-links
                 candidate
                 (refbox--candidate-resources candidate)))
    (let ((refbox-link-fields
           '((eprint . "https://example.test/eprint/%s"))))
      (should (refbox-reference-has-links-p candidate))
      (should (equal (refbox-reference-links
                      candidate
                      (refbox--candidate-resources candidate))
                     '("https://example.test/eprint/12345"))))
    (let ((refbox-link-fields
           '(("eprint" . "https://example.test/string/%s"))))
      (should (refbox-reference-has-links-p candidate))
      (should (equal (refbox-reference-links
                      candidate
                      (refbox--candidate-resources candidate))
                     '("https://example.test/string/12345"))))))

(ert-deftest refbox-test-resource_choices_are_grouped_by_type ()
  "Resource completion should expose Citar-style type groups."
  (let* ((refbox-notes-source 'mock)
         (refbox-notes-sources
          '((mock :name "Slipbox Notes"
                  :items ignore
                  :hasitems ignore
                  :open ignore)))
         (choices '((:type file :label "file alpha")
                    (:type link :label "link alpha")
                    (:type note :label "note alpha")
                    (:type create-note :label "create alpha")))
         (labels (mapcar (lambda (choice)
                           (propertize (plist-get choice :label)
                                       'refbox-resource-choice choice))
                         choices))
         (metadata (funcall (refbox--resource-choice-completion-table labels)
                            "" nil 'metadata))
         (group-function (cdr (assq 'group-function (cdr metadata)))))
    (should (equal (mapcar (lambda (label)
                             (funcall group-function label nil))
                           labels)
                   '("Library Files" "Links" "Slipbox Notes"
                     "Create Slipbox Notes")))))

(ert-deftest refbox-test-resource_choice_metadata_matches_citar_categories ()
  "Resource completion metadata should use Citar-style resource categories."
  (cl-labels
      ((label (choice)
         (propertize (plist-get choice :label)
                     'refbox-resource-choice choice))
       (metadata-category (choices)
         (let* ((labels (mapcar #'label choices))
                (metadata (funcall
                           (refbox--resource-choice-completion-table labels)
                           "" nil 'metadata)))
           (cdr (assq 'category (cdr metadata)))))
       (candidate (text candidates)
         (cl-find text candidates
                  :key #'substring-no-properties
                  :test #'equal)))
    (let ((file-choice '(:type file
                         :target "/tmp/paper.pdf"
                         :label "/tmp/paper.pdf"))
          (link-choice '(:type link
                         :target "https://example.test/paper"
                         :label "https://example.test/paper"))
          (note-choice '(:type note
                         :target "/tmp/note.org"
                         :category file
                         :label "/tmp/note.org"))
          (create-choice '(:type create-note
                           :target "alpha"
                           :label "alpha")))
      (should (eq (metadata-category (list file-choice)) 'file))
      (should (eq (metadata-category (list link-choice)) 'url))
      (should (eq (metadata-category (list note-choice)) 'file))
      (should (eq (metadata-category (list create-choice)) 'refbox-reference))
      (let* ((labels (mapcar #'label
                             (list file-choice link-choice note-choice
                                   create-choice)))
             (table (refbox--resource-choice-completion-table labels))
             (metadata (funcall table "" nil 'metadata))
             (candidates (all-completions "" table))
             (file-target (get-text-property
                           0 'multi-category
                           (candidate "/tmp/paper.pdf" candidates)))
             (link-target (get-text-property
                           0 'multi-category
                           (candidate "https://example.test/paper"
                                      candidates)))
             (note-target (get-text-property
                           0 'multi-category
                           (candidate "/tmp/note.org" candidates)))
             (create-target (get-text-property
                             0 'multi-category
                             (candidate "alpha" candidates))))
        (should (eq (cdr (assq 'category (cdr metadata))) 'multi-category))
        (should (eq (car file-target) 'file))
        (should (eq (car link-target) 'url))
        (should (eq (car note-target) 'file))
        (should (eq (car create-target) 'refbox-reference))
        (should (eq (plist-get
                     (get-text-property
                      0 'refbox-resource-choice (cdr create-target))
                     :type)
                    'create-note))))))

(ert-deftest refbox-test-resource_choice_display_matches_citar ()
  "Resource completion candidates should keep Citar's resource-string shape."
  (let* ((root (make-temp-file "refbox-resource-display-" t))
         (file (expand-file-name "paper.pdf" root))
         (candidate (list :key "alpha"
                          :resources
                          (list (list :kind "file" :value file)
                                (list :kind "url"
                                      :value "https://example.test/a")))))
    (unwind-protect
        (let ((refbox-notes-source 'mock)
              (refbox-notes-sources
               `((mock :name "Slipbox Notes"
                       :items ,(lambda (keys)
                                 (refbox-test-key-table
                                  keys
                                  (lambda (_key)
                                    '("note:alpha"))))
                       :hasitems ,#'ignore
                       :open ,#'ignore
                       :transform ,(lambda (item)
                                     (concat "shown:" item))))))
          (with-temp-file file)
          (cl-letf (((symbol-function 'refbox-reference-resources)
                     (lambda (reference)
                       (plist-get reference :resources))))
            (let* ((file-choice (car (refbox--file-choices (list candidate))))
                   (link-choice (car (refbox--link-choices (list candidate))))
                   (note-choice (car (refbox--note-choices (list candidate))))
                   (labels (mapcar (lambda (choice)
                                     (propertize
                                      (plist-get choice :label)
                                      'refbox-resource-choice choice))
                                   (list file-choice link-choice note-choice)))
                   (metadata (funcall
                              (refbox--resource-choice-completion-table labels)
                              "" nil 'metadata))
                   (group-function (cdr (assq 'group-function
                                               (cdr metadata)))))
              (should (equal (plist-get file-choice :label) file))
              (should (equal (plist-get link-choice :label)
                             "https://example.test/a"))
              (should (equal (plist-get note-choice :label) "note:alpha"))
              (should (equal (funcall group-function (nth 0 labels) t)
                             "paper.pdf"))
              (should (equal (funcall group-function (nth 1 labels) t)
                             "https://example.test/a"))
              (should (equal (funcall group-function (nth 2 labels) t)
                             "shown:note:alpha")))))
      (delete-directory root t))))

(ert-deftest refbox-test-resource_choices_deduplicate_targets_like_citar ()
  "Repeated resource targets should only appear once in resource selection."
  (let* ((root (make-temp-file "refbox-resource-dedup-" t))
         (file (expand-file-name "paper.pdf" root))
         (first (list :key "alpha"
                      :resources (list (list :kind "file" :value file))))
         (second (list :key "beta"
                       :resources (list (list :kind "file" :value file)))))
    (unwind-protect
        (progn
          (with-temp-file file)
          (cl-letf (((symbol-function 'refbox-reference-resources)
                     (lambda (reference)
                       (plist-get reference :resources))))
            (let ((choices (refbox--file-choices (list first second))))
              (should (= (length choices) 1))
              (should (equal (plist-get (car choices) :target) file)))))
      (delete-directory root t))))

(ert-deftest refbox-test-create_note_choices_use_reference_display ()
  "Create-note choices should use reference rows, not synthetic labels."
  (let* ((candidate (copy-tree refbox-test-reference-candidate))
         (refbox-notes-source 'mock)
         (refbox-notes-sources
          '((mock :name "Slipbox Notes"
                  :items (lambda (_keys)
                           (make-hash-table :test 'equal))
                  :hasitems ignore
                  :open ignore
                  :create ignore
                  :create-label (lambda (key _reference)
                                  (format "new:%s" key)))))
         (choice (car (refbox--note-choices
                       (list candidate) t)))
         (label (plist-get choice :label)))
    (should (eq (plist-get choice :type) 'create-note))
    (should (get-text-property 0 'invisible label))
    (should (string-match-p "Alpha Reference Title" label))
    (should-not (string-match-p "new:smith2020" label))))

(ert-deftest refbox-test-create_note_choices_for_keys_have_visible_labels ()
  "Create-note choices for selected key strings should not render blank rows."
  (let* ((refbox-notes-source 'mock)
         (refbox-notes-sources
          '((mock :name "Slipbox Notes"
                  :items (lambda (_keys)
                           (make-hash-table :test 'equal))
                  :hasitems ignore
                  :open ignore
                  :create ignore
                  :create-label (lambda (key _reference)
                                  (format "new:%s" key))))))
    (cl-letf (((symbol-function 'refbox--get-entry-candidate)
               (lambda (_key) nil)))
      (let* ((choice (car (refbox--note-choices (list "smith2020") t)))
             (label (plist-get choice :label))
             (completion-label (propertize label
                                           'refbox-resource-choice choice))
             (table (refbox--resource-choice-completion-table
                     (list completion-label)))
             (metadata (funcall table "" nil 'metadata))
             (group-function (cdr (assq 'group-function (cdr metadata)))))
        (should (eq (plist-get choice :type) 'create-note))
        (should (get-text-property 0 'invisible label))
        (should (string-match-p "new:smith2020" label))
        (should (equal (funcall group-function completion-label t)
                       completion-label))))))

(ert-deftest refbox-test-resource_open_prompt_uses_this_command_like_citar ()
  "Single-resource prompting should follow `this-command'."
  (let* ((root (make-temp-file "refbox-resource-this-command-" t))
         (file (expand-file-name "paper.pdf" root))
         (candidate (list :key "alpha"
                          :resources (list (list :kind "file"
                                                  :value file))))
         opened
         prompted)
    (unwind-protect
        (progn
          (with-temp-file file)
          (let ((refbox-open-prompt '(refbox-open))
                (refbox-open-resources '(:files)))
            (cl-letf (((symbol-function 'refbox-reference-resources)
                       (lambda (reference)
                         (plist-get reference :resources)))
                      ((symbol-function 'refbox-file-open)
                       (lambda (target)
                         (push target opened)))
                      ((symbol-function 'completing-read)
                       (lambda (_prompt collection &rest _args)
                         (setq prompted t)
                         (car (all-completions "" collection)))))
              (let ((this-command nil))
                (refbox-open candidate))
              (should (equal opened (list file)))
              (should-not prompted)
              (setq opened nil
                    prompted nil)
              (let ((this-command 'refbox-open))
                (refbox-open candidate))
              (should (equal opened (list file)))
              (should prompted))))
      (delete-directory root t))))

(ert-deftest refbox-test-open_always_create_notes_uses_this_command_like_citar ()
  "Create-note forcing should follow `this-command'."
  (let* ((candidate (copy-tree refbox-test-reference-candidate))
         (refbox-open-always-create-notes '(refbox-open-notes))
         (refbox-notes-source 'mock)
         (refbox-notes-sources
          '((mock :name "Slipbox Notes"
                  :items (lambda (keys)
                           (refbox-test-key-table
                            keys
                            (lambda (_key)
                              '("note:smith2020"))))
                  :hasitems ignore
                  :open ignore
                  :create ignore
                  :create-label (lambda (key _reference)
                                  (format "new:%s" key))))))
    (let ((this-command nil))
      (should (equal (mapcar (lambda (choice)
                               (plist-get choice :type))
                             (refbox--note-choices (list candidate) t))
                     '(note))))
    (let ((this-command 'refbox-open-notes))
      (should (equal (mapcar (lambda (choice)
                               (plist-get choice :type))
                             (refbox--note-choices (list candidate) t))
                     '(note create-note))))))

(ert-deftest refbox-test-resource_selection_prompt_matches_citar ()
  "Resource commands should use Citar's resource selection prompt."
  (let* ((root (make-temp-file "refbox-resource-prompt-" t))
         (file-a (expand-file-name "a.pdf" root))
         (file-b (expand-file-name "b.pdf" root))
         (candidate (list :key "alpha"
                          :resources
                          (list (list :kind "file" :value file-a)
                                (list :kind "file" :value file-b))))
         opened)
    (unwind-protect
        (progn
          (with-temp-file file-a)
          (with-temp-file file-b)
          (cl-letf (((symbol-function 'completing-read)
                     (lambda (prompt collection &rest _args)
                       (should (equal prompt "Select resource: "))
                       (car (all-completions "" collection))))
                    ((symbol-function 'refbox-reference-resources)
                     (lambda (reference)
                       (plist-get reference :resources)))
                    ((symbol-function 'refbox-file-open)
                     (lambda (file)
                       (push file opened))))
            (refbox-open-files candidate)
            (should (equal opened (list file-a)))))
      (delete-directory root t))))

(ert-deftest refbox-test-resource_prompts_bind_embark_default_actions_like_citar ()
  "Resource prompts should expose prompt-local Embark default actions."
  (let ((candidate '(:key "alpha"))
        (file "/tmp/refbox-paper.pdf")
        captured
        target
        opened)
    (cl-letf (((symbol-function 'refbox-reference-files)
               (lambda (_reference) (list file)))
              ((symbol-function 'refbox--current-local-bibliography-source-paths)
               (lambda () nil))
              ((symbol-function 'refbox-file-open)
               (lambda (opened-file)
                 (setq opened opened-file)
                 :opened))
              ((symbol-function 'completing-read)
               (lambda (_prompt collection &rest _args)
                 (setq captured embark-default-action-overrides)
                 (setq target (car (all-completions "" collection)))
                 target)))
      (let ((this-command 'refbox-open)
            (refbox-open-prompt t)
            (refbox-open-resources '(:files)))
        (should (eq (refbox-open candidate) :opened))
        (should (equal opened file))
        (setq opened nil)
        (should (eq (funcall (cdr (assq t captured)) target) :opened))
        (should (equal opened file))
        (setq opened nil)
        (should (eq (funcall (cdr (assq 'file captured)) file) :opened))
        (should (equal opened file)))
      (setq captured nil
            target nil
            opened nil)
      (let ((this-command 'refbox-open-files)
            (refbox-open-prompt t))
        (should (eq (refbox-open-files candidate) :opened))
        (setq opened nil)
        (should (eq (funcall (cdr (assoc (cons 'file 'refbox-open-files)
                                         captured))
                             target)
                    :opened))
        (should (equal opened file))))))

(ert-deftest refbox-test-resource_note_choices_support_annotations ()
  "Note-source annotations should participate in resource completion."
  (let* ((refbox-notes-source 'mock)
         (refbox-notes-sources
          '((mock :items ignore
                  :hasitems ignore
                  :open ignore
                  :annotate (lambda (item)
                              (format " <%s>" item)))))
         (choice '(:type note :target "note:alpha" :label "note alpha"))
         (label (propertize (plist-get choice :label)
                            'refbox-resource-choice choice))
         (metadata (funcall (refbox--resource-choice-completion-table
                             (list label))
                            "" nil 'metadata))
         (annotation-function (cdr (assq 'annotation-function
                                         (cdr metadata)))))
    (should (equal (funcall annotation-function label)
                   " <note:alpha>"))))

(ert-deftest refbox-test-resource_note_choices_carry_source_category ()
  "Note choices should retain the note source completion category."
  (let* ((refbox-notes-source 'mock)
         (refbox-notes-sources
          '((mock :category file
                  :items (lambda (keys)
                           (refbox-test-key-table
                            keys
                            (lambda (_key)
                              '("/tmp/note.org"))))
                  :hasitems ignore
                  :open ignore)))
         (choice (car (refbox--note-choices (list '(:key "alpha"))))))
    (should (eq (plist-get choice :type) 'note))
    (should (eq (plist-get choice :category) 'file))
    (should (equal (plist-get choice :target) "/tmp/note.org"))))

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
            (cl-letf (((symbol-function 'find-file)
                       (lambda (target)
                         (push (cons 'find-file target) opened)
                         target))
                      ((symbol-function 'refbox-reference-resources)
                       (lambda (_candidate)
                         (refbox--candidate-resources candidate))))
              (refbox-open-files candidate)
              (refbox-open-links candidate)
              (refbox-create-note candidate)))
          (should (member (cons 'file file) opened))
          (should (member (cons 'link "https://doi.org/10.1000/refbox") opened))
          (should (member (cons 'find-file (expand-file-name "smith2020.org" root))
                          opened)))
      (delete-directory root t))))

(ert-deftest refbox-test-resource_openers_return_opener_results ()
  "Resource opener helpers should return configured opener results like Citar."
  (should (eq (refbox--open-target (lambda (_target) :opened) "/tmp/refbox")
              :opened))
  (let ((refbox-file-open-functions
         `(("pdf" . ,(lambda (_file) :pdf-opened)))))
    (should (eq (refbox-file-open "/tmp/refbox-test.pdf")
                :pdf-opened))))

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

(ert-deftest refbox-test-file_openers_default_pdf_uses_find_file ()
  "PDF resources should use the normal Emacs file opener by default."
  (let ((opened nil))
    (cl-letf (((symbol-function 'find-file)
               (lambda (file)
                 (setq opened file)
                 file)))
      (should (equal (refbox-file-open "/tmp/refbox-test.pdf")
                     "/tmp/refbox-test.pdf"))
      (should (equal opened "/tmp/refbox-test.pdf")))))

(ert-deftest refbox-test-pdf_open_mode_requires_pdf_tools_state ()
  "`pdf-view-mode' should only be selected after `pdf-tools' state exists."
  (let ((original-bound (boundp 'pdf-tools-enabled-modes))
        (original-value (and (boundp 'pdf-tools-enabled-modes)
                             (symbol-value 'pdf-tools-enabled-modes)))
        (required nil))
    (unwind-protect
        (progn
          (when (boundp 'pdf-tools-enabled-modes)
            (makunbound 'pdf-tools-enabled-modes))
          (cl-letf (((symbol-function 'require)
                     (lambda (feature &optional _filename _noerror)
                       (push feature required)
                       (pcase feature
                         ('pdf-tools t)
                         ('pdf-view t)
                         ('doc-view nil)
                         (_ nil))))
                    ((symbol-function 'fboundp)
                     (lambda (symbol)
                       (eq symbol 'pdf-view-mode))))
            (should-not (refbox--pdf-open-mode))
            (should (equal (nreverse required)
                           '(pdf-tools pdf-view doc-view)))))
      (if original-bound
          (set 'pdf-tools-enabled-modes original-value)
        (when (boundp 'pdf-tools-enabled-modes)
          (makunbound 'pdf-tools-enabled-modes))))))

(defun refbox-test-pdf-mode ()
  "Test mode used to prove PDF resources do not stay in raw text buffers."
  (setq major-mode 'refbox-test-pdf-mode)
  (setq mode-name "RefboxTestPDF"))

(ert-deftest refbox-test-file_open_pdf_kills_raw_buffers_and_activates_viewer ()
  "PDF opening should replace stale raw buffers with a PDF viewing mode."
  (let* ((root (make-temp-file "refbox-pdf-open-" t))
         (file (expand-file-name "paper.pdf" root)))
    (unwind-protect
        (progn
          (with-temp-file file
            (insert "%PDF-1.7\n"))
          (let ((buffer (find-file-noselect file)))
            (with-current-buffer buffer
              (fundamental-mode)
              (set-buffer-modified-p nil)))
          (cl-letf (((symbol-function 'refbox--pdf-open-mode)
                     (lambda () 'refbox-test-pdf-mode)))
            (should (equal (refbox-file-open-pdf file) file))
            (with-current-buffer (get-file-buffer file)
              (should (eq major-mode 'refbox-test-pdf-mode)))))
      (when-let ((buffer (get-file-buffer file)))
        (kill-buffer buffer))
      (delete-directory root t))))

(ert-deftest refbox-test-file_open_with_mode_bypasses_raw_pdf_auto_mode ()
  "Mode-specific opening should not let PDF auto-mode expose raw bytes."
  (let* ((root (make-temp-file "refbox-pdf-auto-mode-" t))
         (file (expand-file-name "paper.pdf" root)))
    (unwind-protect
        (progn
          (with-temp-file file
            (insert "%PDF-1.7\n"))
          (let ((auto-mode-alist
                 `(("\\.pdf\\'" . ,(lambda ()
                                      (error "PDF auto-mode should not run")))))
                (magic-mode-alist
                 `(("%PDF" . ,(lambda ()
                                (error "PDF magic-mode should not run")))))
                (magic-fallback-mode-alist nil))
            (should (equal (refbox--file-open-with-mode
                            file
                            'refbox-test-pdf-mode)
                           file))
            (with-current-buffer (get-file-buffer file)
              (should (eq major-mode 'refbox-test-pdf-mode)))))
      (when-let ((buffer (get-file-buffer file)))
        (kill-buffer buffer))
      (delete-directory root t))))

(ert-deftest refbox-test-file_open_pdf_falls_back_to_external_opener ()
  "PDF opening should fall back to an external opener when no viewer exists."
  (let ((opened nil))
    (cl-letf (((symbol-function 'refbox--pdf-open-mode)
               (lambda () nil))
              ((symbol-function 'refbox-file-open-external)
               (lambda (file)
                 (setq opened file)
                 file)))
      (should (equal (refbox-file-open-pdf "/tmp/refbox-test.pdf")
                     "/tmp/refbox-test.pdf"))
      (should (equal opened "/tmp/refbox-test.pdf")))))

(ert-deftest refbox-test-file_openers_require_matching_dispatch ()
  "File opening should fail when no extension or default opener matches."
  (let ((refbox-file-open-functions nil))
    (should-error (refbox-file-open "/tmp/refbox-test.pdf")
                  :type 'user-error)))

(ert-deftest refbox-test-open_without_note_paths_matches_citar_create_error ()
  "Create-note opening should surface file-source configuration errors."
  (let ((candidate '(:key "empty2020" :fields nil :resources nil))
        (refbox-notes-paths nil)
        (refbox-open-resources '(:create-notes))
        (refbox-open-prompt nil))
    (cl-letf (((symbol-function 'refbox-reference-resources)
               (lambda (_candidate) nil)))
      (should
       (string-match-p
        "refbox-notes-paths"
        (error-message-string
         (should-error (refbox-open candidate) :type 'user-error)))))))

(ert-deftest refbox-test-specific_resource_commands_tolerate_missing_items ()
  "Specific resource commands should match Citar's empty-resource behavior."
  (let ((candidate '(:key "empty2020" :fields nil :resources nil))
        (refbox-notes-paths nil)
        messages)
    (cl-letf (((symbol-function 'refbox-reference-resources)
               (lambda (_candidate) nil))
              ((symbol-function 'message)
               (lambda (format-string &rest args)
                 (push (apply #'format format-string args) messages))))
      (should-not (refbox-open-files candidate))
      (should-not (refbox-attach-files candidate))
      (should-not (refbox-open-links candidate))
      (should
       (string-match-p
        "refbox-notes-paths"
        (error-message-string
         (should-error (refbox-open-notes candidate) :type 'user-error))))
      (should-not (refbox-open-note nil))
      (should (member "No associated files for empty2020" messages))
      (should (member "No link found for empty2020" messages)))))

(ert-deftest refbox-test-file_commands_suppress_generic_message_when_source_has_items ()
  "File commands should let file sources explain item lookup failures."
  (let ((candidate '(:key "alpha" :fields nil :resources nil))
        messages)
    (let ((refbox-file-sources
           `((:items ,(lambda (keys)
                        (refbox-test-key-table keys #'ignore))
              :hasitems ,(lambda ()
                           (lambda (key)
                             (equal key "alpha")))))))
      (cl-letf (((symbol-function 'message)
                 (lambda (format-string &rest args)
                   (push (apply #'format format-string args) messages))))
        (should-not (refbox-open-files candidate))
        (should-not (refbox-attach-files candidate))))
    (should-not messages)))

(ert-deftest refbox-test-file_field_missing_path_reports_specific_reason ()
  "Declared file fields should explain unresolved file resources."
  (let* ((root (make-temp-file "refbox-missing-file-field-" t))
         (candidate
          (list :key "alpha"
                :source_path (expand-file-name "refs.bib" root)
                :resources
                (list (list :kind "file"
                            :lookup_name "file"
                            :value "missing.pdf"))))
         (refbox-file-sources (list (car refbox--default-file-sources)))
         messages)
    (unwind-protect
        (progn
          (cl-letf (((symbol-function 'message)
                     (lambda (format-string &rest args)
                       (push (apply #'format format-string args) messages))))
            (should-not (refbox-open-files candidate)))
          (should
           (member
            "None of the files for `alpha' exist; check `refbox-library-paths' and `refbox-file-parser-functions': (\"missing.pdf\")"
            messages))
          (should-not
           (cl-some (lambda (message)
                      (string-match-p "No associated files" message))
                    messages)))
      (delete-directory root t))))

(ert-deftest refbox-test-file_field_extension_filter_reports_specific_reason ()
  "Declared files rejected by extension filtering should say so."
  (let* ((root (make-temp-file "refbox-file-extension-" t))
         (txt (expand-file-name "paper.txt" root))
         (candidate
          (list :key "alpha"
                :source_path (expand-file-name "refs.bib" root)
                :resources
                (list (list :kind "file"
                            :lookup_name "file"
                            :value "paper.txt"))))
         (refbox-file-sources (list (car refbox--default-file-sources)))
         (refbox-library-file-extensions '("pdf"))
         messages)
    (unwind-protect
        (progn
          (with-temp-file txt)
          (cl-letf (((symbol-function 'message)
                     (lambda (format-string &rest args)
                       (push (apply #'format format-string args) messages))))
            (should-not (refbox-open-files candidate)))
          (should
           (cl-some
            (lambda (message)
              (and (string-match-p
                    "No files for `alpha' with `refbox-library-file-extensions'"
                    message)
                   (string-match-p (regexp-quote txt) message)))
            messages))
          (should-not
           (cl-some (lambda (message)
                      (string-match-p "No associated files" message))
                    messages)))
      (delete-directory root t))))

(ert-deftest refbox-test-file_field_parse_failures_report_specific_reason ()
  "Unparseable declared file fields should explain parser failure."
  (let ((candidate
         '(:key "alpha"
           :fields nil
           :resources ((:kind "file"
                        :lookup_name "file"
                        :value "paper.pdf"))))
        (refbox-file-sources (list (car refbox--default-file-sources)))
        (refbox-file-parser-functions
         '(refbox-resource-parse-file-field-triplet))
        messages)
    (cl-letf (((symbol-function 'message)
               (lambda (format-string &rest args)
                 (push (apply #'format format-string args) messages))))
      (should-not (refbox-open-files candidate)))
    (should
     (member
      "Could not parse `file' field of `alpha'; check `refbox-file-parser-functions': paper.pdf"
      messages))
    (should-not
     (cl-some (lambda (message)
                (string-match-p "No associated files" message))
              messages))))

(ert-deftest refbox-test-file_field_empty_values_report_specific_reason ()
  "Empty declared file fields should explain the empty field."
  (let ((candidate
         '(:key "alpha"
           :fields nil
           :resources ((:kind "file"
                        :lookup_name "file"
                        :value "   "))))
        (refbox-file-sources (list (car refbox--default-file-sources)))
        messages)
    (cl-letf (((symbol-function 'message)
               (lambda (format-string &rest args)
                 (push (apply #'format format-string args) messages))))
      (should-not (refbox-open-files candidate)))
    (should (member "Empty `file' field: alpha" messages))
    (should-not
     (cl-some (lambda (message)
                (string-match-p "No associated files" message))
              messages))))

(ert-deftest refbox-test-link_commands_respect_supplied_empty_resources ()
  "Link commands should not hydrate when candidates carry empty resources."
  (let ((candidate '(:key "alpha" :fields nil :resources nil))
        messages)
    (cl-letf (((symbol-function 'message)
               (lambda (format-string &rest args)
                 (push (apply #'format format-string args) messages))))
      (should-not (refbox-open-links candidate)))
    (should (equal messages '("No link found for alpha")))))

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

(ert-deftest refbox-test-open-entry_custom_function_receives_key ()
  "Custom entry openers should receive Citar-shaped key arguments."
  (let (opened)
    (let ((refbox-open-entry-function
           (lambda (key)
             (setq opened key)
             :opened)))
      (should (eq (refbox-open-entry refbox-test-reference-candidate) :opened))
      (should (equal opened "smith2020")))))

(ert-deftest refbox-test-open_entry_in_zotero_uses_citation_key_url ()
  "Zotero opening should use the selected citation key."
  (let (opened)
    (let ((refbox-zotero-open-function
           (lambda (url)
             (push url opened))))
      (refbox-open-entry-in-zotero refbox-test-reference-candidate)
      (should (equal opened
                     '("zotero://select/items/@smith2020"))))))

(ert-deftest refbox-test-file_open_external_preserves_url_targets ()
  "External opening should pass URL targets through unchanged."
  (let (called)
    (cl-letf (((symbol-function 'call-process)
               (lambda (program infile destination display &rest args)
                 (setq called
                       (list program infile destination display args))
                 0)))
      (should (equal (refbox-file-open-external
                      "zotero://select/items/@smith2020")
                     0))
      (should (equal (car (last called))
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

(ert-deftest refbox-test-raw-entry-insertion_selects_interactively ()
  "Interactive raw entry insertion should select references first."
  (let ((raw-alpha "@article{alpha,\n  title = {Alpha}\n}"))
    (with-temp-buffer
      (cl-letf (((symbol-function 'refbox-select-refs)
                 (lambda (&rest _args) '("alpha")))
                ((symbol-function 'refbox-rpc-request)
                 (lambda (_method params)
                   (should (equal (plist-get params :key) "alpha"))
                   (list :raw raw-alpha))))
        (call-interactively #'refbox-insert-raw-entry)
        (should (equal (buffer-string) raw-alpha))))))

(ert-deftest refbox-test-raw-entry-insertion_nil_is_empty_output ()
  "Programmatic nil raw entry insertion should not prompt."
  (with-temp-buffer
    (cl-letf (((symbol-function 'refbox-select-refs)
               (lambda (&rest _args)
                 (error "nil raw entry insertion should not select references")))
              ((symbol-function 'refbox-rpc-request)
               (lambda (&rest _args)
                 (error "nil raw entry insertion should not call the daemon"))))
      (should-not (refbox-insert-raw-entry nil))
      (should (equal (buffer-string) "")))))

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
      (should-not (string-match-p "file = " (buffer-string)))
      (should (string-suffix-p "\n\n" (buffer-string))))))

(ert-deftest refbox-test-insert-bibtex_nil_matches_citar_contract ()
  "Programmatic nil BibTeX insertion should insert nothing."
  (cl-letf (((symbol-function 'refbox-select-refs)
             (lambda (&rest _args)
               (error "nil BibTeX insertion should not select")))
            ((symbol-function 'refbox-read-references)
             (lambda (&rest _args)
               (error "nil BibTeX insertion should not prompt"))))
    (with-temp-buffer
      (refbox-insert-bibtex nil)
      (should (equal (buffer-string) "")))
    (should (equal (refbox--bibtex-export-text nil) ""))))

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
            (should-not (string-match-p "file = " (buffer-string)))
            (should (string-suffix-p "\n\n" (buffer-string)))))
      (delete-directory root t))))

(ert-deftest refbox-test-export-bibliography_empty_buffer_matches_citar ()
  "Local bibliography export should create an empty file for no citations."
  (let* ((root (make-temp-file "refbox-export-empty-" t))
         (output (expand-file-name "local.bib" root)))
    (unwind-protect
        (with-temp-buffer
          (should (equal (refbox-export-bibliography output) output))
          (with-temp-buffer
            (insert-file-contents output)
            (should (equal (buffer-string) ""))))
      (delete-directory root t))))

(ert-deftest refbox-test-export-local-bib-file_uses_buffer_directory ()
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
              (should (equal (refbox-export-local-bib-file) output))))
          (with-temp-buffer
            (insert-file-contents output)
            (should (string-match-p "@article{alpha" (buffer-string)))))
      (delete-directory root t))))

(ert-deftest refbox-test-export-local-bib-file_prefers_configured_extension ()
  "Local bibliography export should mirror Citar's global extension choice."
  (let* ((root (make-temp-file "refbox-local-export-ext-" t))
         (output (expand-file-name "local-bib.biblatex" root))
         (raw "@article{alpha,\n  title = {Alpha}\n}"))
    (unwind-protect
        (let ((refbox-bibliography '("main.biblatex"))
              (refbox-bibliography-extensions '("bib"))
              (refbox-major-mode-functions
               '((text-mode
                  . ((local-bib-files . refbox-test-local-bib-files))))))
          (with-temp-buffer
            (text-mode)
            (setq buffer-file-name (expand-file-name "paper.txt" root))
            (cl-letf (((symbol-function 'refbox-test-local-bib-files)
                       (lambda (&optional _buffer)
                         (list (expand-file-name "paper.json" root))))
                      ((symbol-function 'refbox-current-buffer-citation-keys)
                       (lambda (&optional _buffer)
                         '("alpha")))
                      ((symbol-function 'refbox-rpc-request)
                       (lambda (_method _params)
                         (list :raw raw))))
              (should (equal (refbox-export-local-bib-file) output)))))
      (delete-directory root t))))

(ert-deftest refbox-test-export-local-bib-file_accepts_explicit_file ()
  "An explicit local bibliography export path should be honored."
  (let* ((root (make-temp-file "refbox-local-export-explicit-" t))
         (output (expand-file-name "paper-local.bib" root))
         (raw "@article{alpha,\n  title = {Alpha}\n}"))
    (unwind-protect
        (cl-letf (((symbol-function 'refbox-current-buffer-citation-keys)
                   (lambda (&optional _buffer)
                     '("alpha")))
                  ((symbol-function 'refbox-rpc-request)
                   (lambda (_method _params)
                     (list :raw raw))))
          (should (equal (refbox-export-local-bib-file output) output))
          (with-temp-buffer
            (insert-file-contents output)
            (should (string-match-p "@article{alpha" (buffer-string)))))
      (delete-directory root t))))

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

(ert-deftest refbox-test-library-default-file-name_matches_citar ()
  "Default library file names should follow Citar's citekey-extension contract."
  (should (equal (refbox-library-default-file-name "alpha" nil) "alpha"))
  (should (equal (refbox-library-default-file-name "alpha" "") "alpha"))
  (should (equal (refbox-library-default-file-name "alpha" "pdf") "alpha.pdf"))
  (should (equal (refbox-library-default-file-name "alpha" ".pdf") "alpha.pdf"))
  (should (equal (refbox-library-default-file-name "nested/key" "pdf")
                 "nested/key.pdf")))

(ert-deftest refbox-test-save-file-to-library_accepts_empty_extension ()
  "Saving a library file with an empty extension should write the bare key."
  (let* ((root (make-temp-file "refbox-library-empty-extension-" t))
         (library (expand-file-name "library" root))
         (destination (expand-file-name "alpha" library)))
    (unwind-protect
        (let ((refbox-library-paths (list library)))
          (cl-letf (((symbol-function 'read-string)
                     (lambda (prompt &rest _args)
                       (should (equal prompt "File extension: "))
                       "")))
            (should (equal (refbox-save-file-to-library
                            "alpha"
                            (list :write-file
                                  (lambda (file _overwrite)
                                    (with-temp-file file
                                      (insert "bare-key")))))
                           destination)))
          (with-temp-buffer
            (insert-file-contents destination)
            (should (equal (buffer-string) "bare-key"))))
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
                  ,(lambda (key)
                     (setq called key)
                     (list :extension "pdf"
                           :write-file
                           (lambda (destination _overwrite)
                             (with-temp-file destination
                               (insert "custom-pdf")))))))))
          (cl-letf (((symbol-function 'read-multiple-choice)
                     (lambda (_prompt choices)
                       (car choices))))
            (should (equal (refbox-add-file-to-library '(:key "alpha"))
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

(ert-deftest refbox-test-add-file-url_source_infers_extension ()
  "The URL add-file source should infer a destination extension."
  (cl-letf (((symbol-function 'read-string)
             (lambda (&rest _args)
               "https://example.test/paper.pdf")))
    (let ((source (refbox-add-file-source-url "alpha")))
      (should (equal (plist-get source :extension) "pdf")))))

(ert-deftest refbox-test-add-file-to-library_uses_configured_writer ()
  "The interactive add-file command should dispatch through the configured writer."
  (let (called)
    (let ((refbox-add-file-sources
           `((?c "custom" "Use a test source"
              ,(lambda (_key)
                 (list :extension "pdf"
                       :write-file #'ignore)))))
          (refbox-library-paths (list temporary-file-directory))
          (refbox-add-file-function
           (lambda (key source)
             (setq called (list key source))
             "custom-destination")))
      (cl-letf (((symbol-function 'read-multiple-choice)
                 (lambda (_prompt choices)
                   (car choices))))
        (should (equal (refbox-add-file-to-library '(:key "alpha"))
                       "custom-destination"))))
    (should (equal (car called) "alpha"))
    (should (equal (plist-get (cadr called) :extension) "pdf"))))

(ert-deftest refbox-test-add-file-to-library_rejects_empty_sources ()
  "The interactive add-file command should fail at the source boundary."
  (let ((refbox-library-paths (list temporary-file-directory))
        (refbox-add-file-sources nil))
    (should-error (refbox-add-file-to-library "alpha") :type 'user-error)))

(ert-deftest refbox-test-add-file-to-library_rejects_invalid_writer ()
  "The interactive add-file command should fail on invalid writer config."
  (let ((refbox-library-paths (list temporary-file-directory))
        (refbox-add-file-function nil))
    (should-error (refbox-add-file-to-library "alpha") :type 'user-error)))

(ert-deftest refbox-test-add-file-to-library_rejects_empty_library_paths_first ()
  "The interactive add-file command should validate library paths before prompting."
  (let ((refbox-library-paths nil))
    (cl-letf (((symbol-function 'read-multiple-choice)
               (lambda (&rest _args)
                 (error "missing library paths should not prompt for a source"))))
      (should-error (refbox-add-file-to-library "alpha") :type 'user-error))))

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

(ert-deftest refbox-test-add-file-to-library_offers_recursive_directories ()
  "Library add helpers should match Citar's recursive directory choices."
  (let* ((root (make-temp-file "refbox-library-recursive-choice-" t))
         (library (expand-file-name "library" root))
         (subdir (expand-file-name "papers" library)))
    (unwind-protect
        (let ((refbox-library-paths (list library))
              (refbox-library-paths-recursive t))
          (make-directory subdir t)
          (cl-letf (((symbol-function 'completing-read)
                     (lambda (prompt collection &rest _args)
                       (should (equal prompt "Directory: "))
                       (should (member subdir collection))
                       subdir)))
            (with-temp-buffer
              (insert "buffer-pdf")
              (should (equal (refbox-add-buffer-to-library "alpha" "pdf")
                             (expand-file-name "alpha.pdf" subdir)))))
          (should (file-exists-p (expand-file-name "alpha.pdf" subdir))))
      (delete-directory root t))))

(ert-deftest refbox-test-add-file-to-library_preserves_relative_directory_choices ()
  "Library add helpers should offer relative directories like Citar."
  (let* ((root (make-temp-file "refbox-library-relative-choice-" t))
         (default-directory (file-name-as-directory root))
         (library "library")
         (subdir "library/papers"))
    (unwind-protect
        (let ((refbox-library-paths (list library))
              (refbox-library-paths-recursive t))
          (make-directory subdir t)
          (cl-letf (((symbol-function 'completing-read)
                     (lambda (prompt collection &rest _args)
                       (should (equal prompt "Directory: "))
                       (should (equal collection (list library subdir)))
                       subdir)))
            (with-temp-buffer
              (insert "buffer-pdf")
              (should (equal (refbox-add-buffer-to-library "alpha" "pdf")
                             (expand-file-name "alpha.pdf" subdir))))))
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

(ert-deftest refbox-test-add-buffer-to-library_handles_current_file_like_citar ()
  "Buffer-backed saves should preserve Citar's current-file branches."
  (let* ((root (make-temp-file "refbox-library-current-file-" t))
         (library (expand-file-name "library" root))
         (destination (expand-file-name "alpha.pdf" library))
         buffer
         saved-buffer-string)
    (unwind-protect
        (let ((refbox-library-paths (list library)))
          (make-directory library t)
          (with-temp-file destination
            (insert "old"))
          (setq buffer (find-file-noselect destination))
          (with-current-buffer buffer
            (should-not (buffer-modified-p))
            (let (messages)
              (cl-letf (((symbol-function 'message)
                         (lambda (format-string &rest args)
                           (push (apply #'format format-string args)
                                 messages)))
                        ((symbol-function 'yes-or-no-p)
                         (lambda (&rest _args)
                           (error "unmodified current file should not ask"))))
                (should (equal (refbox-add-buffer-to-library
                                "alpha" "pdf" 1)
                               destination))
                (should (equal messages
                               '("alpha.pdf exists and the current buffer is visiting it."))))))
          (with-current-buffer buffer
            (goto-char (point-max))
            (insert " new")
            (let (prompt)
              (cl-letf (((symbol-function 'yes-or-no-p)
                         (lambda (question)
                           (setq prompt question)
                           t)))
                (should (equal (refbox-add-buffer-to-library
                                "alpha" "pdf" 1)
                               destination))
                (should (equal prompt
                               "alpha.pdf exists and the current buffer is visiting it.  Save anyway? "))
                (should-not (buffer-modified-p))
                (setq saved-buffer-string (buffer-string)))))
          (with-temp-buffer
            (insert-file-contents destination)
            (should (equal (buffer-string) saved-buffer-string))))
      (when (buffer-live-p buffer)
        (kill-buffer buffer))
      (delete-directory root t))))

(ert-deftest refbox-test-csl-style-metadata-and-selection ()
  "CSL style selection should follow Citar's title-to-filename contract."
  (let* ((root (make-temp-file "refbox-csl-" t))
         (style-dir (expand-file-name "styles" root))
         (style-file (expand-file-name "apa.csl" style-dir))
         (other-style-file (expand-file-name "ieee.csl" style-dir)))
    (unwind-protect
        (progn
          (make-directory style-dir t)
          (with-temp-file style-file
            (insert "<style><info><title>APA Test</title>"
                    "<id>http://www.zotero.org/styles/apa-test</id>"
                    "</info></style>"))
          (should (equal (refbox-citeproc-csl-metadata style-file)
                         "APA Test"))
          (should (equal (refbox-csl--style-info style-file)
                         (list :file style-file
                               :id "http://www.zotero.org/styles/apa-test"
                               :title "APA Test")))
          (let ((refbox-citeproc-csl-styles-dir style-dir)
                refbox-citeproc-csl-style)
            (cl-letf (((symbol-function 'completing-read)
                       (lambda (&rest _args)
                         (error "single CSL style should not prompt"))))
              (should (equal (refbox-citeproc-select-csl-style) "apa.csl"))
              (should (equal refbox-citeproc-csl-style "apa.csl"))))
          (with-temp-file other-style-file
            (insert "<style><info><title>IEEE Test</title></info></style>"))
          (let ((refbox-citeproc-csl-styles-dir style-dir)
                refbox-citeproc-csl-style)
            (cl-letf (((symbol-function 'completing-read)
                       (lambda (prompt collection &rest _args)
                         (should (equal prompt "Select CSL style: "))
                         (should (equal (assoc "APA Test" collection)
                                        '("APA Test" . "apa.csl")))
                         "APA Test")))
              (should (equal (refbox-citeproc-select-csl-style) "apa.csl"))
              (should (equal refbox-citeproc-csl-style "apa.csl"))))
          (let ((refbox-citeproc-csl-styles-dir style-dir)
                (refbox-citeproc-csl-style "http://www.zotero.org/styles/apa-test"))
            (should (equal (refbox-csl--style-file) style-file))))
      (delete-directory root t))))

(ert-deftest refbox-test-csl-resolution_uses_org_fallback_directory ()
  "CSL lookup should use Org's bundled fallback directory when available."
  (let* ((root (make-temp-file "refbox-csl-fallback-" t))
         (style-file (expand-file-name "apa.csl" root))
         (locale-file (expand-file-name "locales-en-US.xml" root)))
    (unwind-protect
        (progn
          (with-temp-file style-file
            (insert "<style><info><title>APA Test</title></info></style>"))
          (with-temp-file locale-file
            (insert "<locale></locale>"))
          (let ((org-cite-csl--fallback-locales-dir root)
                (refbox-citeproc-csl-styles-dir nil)
                (refbox-citeproc-csl-locales-dir nil)
                (refbox-citeproc-csl-style "apa")
                (refbox-citeproc-csl-locale "en-US"))
            (should (equal (refbox-csl--style-file) style-file))
            (should (equal (refbox-csl--locale-file) locale-file))))
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

(ert-deftest refbox-test-format-reference_concatenates_previews_like_citar ()
  "Template reference formatting should not add separators outside the template."
  (let ((refbox-templates
         '((preview . "${=key=}")))
        (candidates
         (list
          '(:key "alpha" :entry_type "article" :fields nil :resources nil)
          '(:key "beta" :entry_type "article" :fields nil :resources nil))))
    (should (equal (refbox-format-references candidates)
                   '("alpha" "beta")))
    (should (equal (refbox-format-reference candidates)
                   "alphabeta"))))

(ert-deftest refbox-test-citeproc-format-reference-uses-citeproc-and-selected-csl_configuration ()
  "CSL reference formatting should use citeproc on selected reference payloads."
  (let* ((root (make-temp-file "refbox-format-" t))
         (style (expand-file-name "style.csl" root))
         (locale (expand-file-name "locales-en-US.xml" root))
         (candidate '(:id 42
                      :key "alpha"
                      :source_path "refs/main.bib"
                      :entry_type "article"
                      :fields ((:raw_name "title"
                                :lookup_name "title"
                                :value "Alpha Reference"))))
         created
         uncited
         csl-entry)
    (unwind-protect
        (progn
          (with-temp-file style)
          (with-temp-file locale)
          (let ((refbox-citeproc-csl-style style)
                (refbox-citeproc-csl-locale locale))
            (cl-letf (((symbol-function 'refbox-citeproc--require)
                       #'ignore)
                      ((symbol-function 'refbox-rpc-request)
                       (lambda (&rest _)
                         (error "citeproc formatting must not call the daemon")))
                      ((symbol-function 'citeproc-blt-entry-to-csl)
                       (lambda (entry)
                         (setq csl-entry entry)
                         '((title . "Alpha Reference"))))
                      ((symbol-function 'citeproc-locale-getter-from-dir)
                       (lambda (dir)
                         (list :locale-dir dir)))
                      ((symbol-function 'citeproc-create)
                       (lambda (style-path itemgetter locale-getter locale-id)
                         (setq created
                               (list :style style-path
                                     :items (funcall itemgetter '("alpha\00042"))
                                     :locale-getter locale-getter
                                     :locale-id locale-id))
                         'processor))
                      ((symbol-function 'citeproc-add-uncited)
                       (lambda (keys processor)
                         (setq uncited (list keys processor))))
                      ((symbol-function 'citeproc-render-bib)
                       (lambda (_processor _format)
                         (cons "Formatted Alpha" '((entry-spacing . 1))))))
              (should (equal (refbox-citeproc--format-references
                              (list candidate))
                             "Formatted Alpha"))
              (should (equal (refbox-citeproc-format-reference
                              (list candidate))
                             "Formatted Alpha"))))
          (should (equal (plist-get created :style) style))
          (should (equal (plist-get created :locale-getter)
                         (list :locale-dir (file-name-as-directory root))))
          (should (equal (plist-get created :locale-id) "en-US"))
          (should (equal (plist-get created :items)
                         '(("alpha\00042" (title . "Alpha Reference")))))
          (should (equal uncited '(("alpha\00042") processor)))
          (should (equal (cdr (assoc "key" csl-entry)) "alpha"))
          (should (equal (cdr (assoc "entry_id" csl-entry)) "42"))
          (should (equal (cdr (assoc "source_path" csl-entry)) "refs/main.bib"))
	          (should (equal (cdr (assoc "title" csl-entry)) "Alpha Reference")))
      (delete-directory root t))))

(ert-deftest refbox-test-citeproc-format-reference_nil_matches_citar_contract ()
  "CSL formatting should treat programmatic nil references as empty output."
  (cl-letf (((symbol-function 'refbox-citeproc--require)
             (lambda ()
               (error "nil citeproc formatting should not require citeproc")))
            ((symbol-function 'refbox-rpc-request)
             (lambda (&rest _)
               (error "nil citeproc formatting should not call the daemon"))))
    (should (equal (refbox-citeproc--format-references nil) ""))
    (should (equal (refbox-citeproc-format-reference nil) ""))))

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
                     "Copied:\nAlpha Reference\n\nBeta Reference"))
      (should (equal (current-kill 0) "Alpha Reference\n\nBeta Reference"))))

(ert-deftest refbox-test-copy-reference_matches_citar_empty_output ()
  "Empty formatted references should not replace the kill ring."
  (let ((kill-ring '("previous"))
        (kill-ring-yank-pointer nil)
        (refbox-format-reference-function
         (lambda (_references) "")))
    (should (equal (refbox-copy-reference '("missing"))
                   "Key not found."))
    (should (equal (current-kill 0) "previous"))))

(ert-deftest refbox-test-reference_actions_do_not_prompt_on_nil_like_citar ()
  "Programmatic nil references should pass through instead of prompting."
  (let ((refbox-format-reference-function nil))
    (cl-letf (((symbol-function 'refbox-read-references)
               (lambda (&rest _args)
                 (error "nil reference actions should not prompt")))
              ((symbol-function 'refbox-select-refs)
               (lambda (&rest _args)
                 (error "nil reference actions should not select")))
              ((symbol-function 'refbox-reference-format-preview)
               (lambda (_reference)
                 (error "nil reference actions should not format entries"))))
      (should (equal (refbox-format-references nil) nil))
      (should (equal (refbox-format-reference nil) ""))
      (with-temp-buffer
        (refbox-insert-keys nil)
        (should (equal (buffer-string) "")))
      (with-temp-buffer
        (refbox-insert-reference nil)
        (should (equal (buffer-string) "")))
      (should (equal (refbox-copy-reference nil) "Key not found.")))))

(ert-deftest refbox-test-resource_actions_do_not_prompt_on_nil_like_citar ()
  "Programmatic nil resource actions should not enter selection."
  (let (opened-entry)
    (cl-letf (((symbol-function 'refbox-read-references)
               (lambda (&rest _args)
                 (error "nil resource actions should not read references")))
              ((symbol-function 'refbox-read-reference)
               (lambda (&rest _args)
                 (error "nil resource actions should not read a reference")))
              ((symbol-function 'refbox-select-refs)
               (lambda (&rest _args)
                 (error "nil resource actions should not select references")))
              ((symbol-function 'refbox-select-ref)
               (lambda (&rest _args)
                 (error "nil resource actions should not select a reference"))))
      (should-not (refbox-open-files nil))
      (should-not (refbox-attach-files nil))
      (should-not (refbox-open-links nil))
      (should-not (refbox-open-notes nil))
      (should-error (refbox-open nil) :type 'user-error)
      (should-error (refbox-open-source nil) :type 'user-error)
      (let ((refbox-open-entry-function
	     (lambda (reference)
	       (setq opened-entry reference)
	       :opened)))
	(should (eq (refbox-open-entry nil) :opened))
	(should-not opened-entry)))))

(ert-deftest refbox-test-note_actions_do_not_prompt_on_nil_like_citar ()
  "Programmatic nil note actions should not enter selection."
  (let (created)
    (let ((refbox-notes-source 'mock)
          (refbox-notes-sources
           `((mock
              :items ,#'ignore
              :hasitems ,#'ignore
              :open ,(lambda (_item)
                       (error "nil open-note should not open a note"))
              :create ,(lambda (key reference)
                         (setq created (list key reference))
                         :created)))))
      (cl-letf (((symbol-function 'refbox-read-reference)
                 (lambda (&rest _args)
                   (error "nil note actions should not read a reference")))
                ((symbol-function 'refbox-select-ref)
                 (lambda (&rest _args)
                   (error "nil note actions should not select a reference"))))
        (should-not (refbox-open-note nil))
        (should (eq (refbox-create-note nil) :created))
        (should (equal created '(nil nil)))))))

(ert-deftest refbox-test-reference_commands_select_before_custom_formatter ()
  "Interactive reference formatting should pass selected keys to formatters."
  (let (formatter-input)
    (cl-letf (((symbol-function 'refbox-select-refs)
               (lambda (&rest _args)
                 '("alpha" "beta"))))
      (let ((refbox-format-reference-function
             (lambda (references)
               (setq formatter-input references)
               "Alpha Reference")))
        (with-temp-buffer
          (call-interactively #'refbox-insert-reference)
          (should (equal formatter-input '("alpha" "beta")))
          (should (equal (buffer-string) "Alpha Reference")))
        (setq formatter-input nil)
        (should (equal (call-interactively #'refbox-copy-reference)
                       "Copied:\nAlpha Reference"))
        (should (equal formatter-input '("alpha" "beta")))))))

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
          (let ((refbox-citeproc-csl-locales-dir locale-dir)
                (refbox-citeproc-csl-locale "en-US"))
            (should (equal (refbox-csl--locale-file) locale-file))))
      (delete-directory root t))))

(ert-deftest refbox-test-read-references_repeats_bounded_reads_until_empty ()
  "Multiple selection should keep reading until an empty selection."
  (let ((remaining (list refbox-test-reference-candidate
                         (plist-put (copy-sequence refbox-test-reference-candidate)
                                    :key "doe2021")
                         nil))
        calls)
    (cl-letf (((symbol-function 'refbox--read-reference-from-state)
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

(ert-deftest refbox-test-read-references_prompt_counts_match_citar ()
  "Multiple selection prompts should show selected and total counts."
  (let ((remaining (list refbox-test-reference-candidate nil))
        prompts)
    (cl-letf (((symbol-function 'refbox--reference-count)
               (lambda (&rest _args) 12))
              ((symbol-function 'refbox--read-reference-from-state)
               (lambda (&rest args)
                 (push (car args) prompts)
                 (pop remaining))))
      (refbox-read-references "References: " nil 5)
      (should (equal (nreverse prompts)
                     '("References:  (0/12): "
                       "References:  (1/12): "))))))

(ert-deftest refbox-test-read-references_ret_accepts_current_and_exits ()
  "RET in the multi-selector should accept one candidate and finish."
  (let (calls)
    (cl-letf (((symbol-function 'refbox--read-reference-from-state)
               (lambda (&rest args)
                 (push args calls)
                 (setq refbox--multiple-exit-requested t)
                 refbox-test-reference-candidate)))
      (let ((selected (refbox-read-references "References: " nil 5)))
        (should (equal (mapcar (lambda (candidate)
                                 (plist-get candidate :key))
                               selected)
                       '("smith2020")))
        (should (= (length calls) 1))))))

(ert-deftest refbox-test-read-references_toggles_existing_selection ()
  "Selecting the same reference twice should remove it from the result."
  (let ((remaining (list refbox-test-reference-candidate
                         refbox-test-reference-candidate
                         nil)))
    (cl-letf (((symbol-function 'refbox--read-reference-from-state)
               (lambda (&rest _args)
                 (pop remaining))))
      (should-not (refbox-read-references "References: " nil 5)))))

(ert-deftest refbox-test-read-references_restores_history_on_toggle ()
  "Toggling an already selected reference should restore read history."
  (let ((remaining (list refbox-test-reference-candidate
                         refbox-test-reference-candidate
                         nil))
        (refbox-history '("before")))
    (cl-letf (((symbol-function 'refbox--read-reference-from-state)
               (lambda (&rest _args)
                 (let ((candidate (pop remaining)))
                   (when candidate
                     (push (plist-get candidate :key) refbox-history))
                   candidate))))
      (should-not (refbox-read-references "References: " nil 5))
      (should (equal refbox-history '("smith2020" "before"))))))

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
                     (list "References: " "has:file" 7 #'ignore '("refs.bib") nil)))
      (should (eq (refbox-select-reference
                   :filter #'ignore
                   :preset "has:notes"
                   :limit 3
                   :source-paths '("local.bib"))
                  refbox-test-reference-candidate))
      (should (equal single-args
                     (list "Reference: " "has:notes" 3 #'ignore '("local.bib") nil)))
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
                     (list "Reference: " "has:links" 4 #'ignore nil nil))))))

(ert-deftest refbox-test-select-refs_returns_keys_and_filters_by_key ()
  "Key-oriented selection should expose key strings for extension code."
  (let (filter-seen reader-args)
    (cl-letf (((symbol-function 'refbox-read-references)
               (lambda (&rest args)
                 (setq reader-args args)
                 (let ((filter (nth 3 args)))
                   (when filter
                     (setq filter-seen
                           (funcall filter refbox-test-reference-candidate))))
                 (list refbox-test-reference-candidate))))
      (should (equal (refbox-select-refs
                      :filter (lambda (key)
                                (equal key "smith2020")))
                     '("smith2020")))
      (should filter-seen)
      (should (equal (list (nth 0 reader-args)
                           (nth 1 reader-args)
                           (nth 2 reader-args)
                           (nth 4 reader-args)
                           (nth 5 reader-args)
                           (nth 6 reader-args))
                     '("References: " nil nil nil nil t)))
      (should (functionp (nth 3 reader-args))))))

(ert-deftest refbox-test-selection_commands_are_quiet_like_citar ()
  "Interactive selection helpers should not emit extra echo messages."
  (let (messages)
    (cl-letf (((symbol-function 'refbox-read-references)
               (lambda (&rest _args)
                 (list refbox-test-reference-candidate)))
              ((symbol-function 'refbox--read-reference)
               (lambda (&rest _args)
                 refbox-test-reference-candidate))
              ((symbol-function 'message)
               (lambda (format-string &rest args)
                 (push (apply #'format format-string args) messages))))
      (should (equal (call-interactively #'refbox-select-references)
                     (list refbox-test-reference-candidate)))
      (should (eq (call-interactively #'refbox-read-reference)
                  refbox-test-reference-candidate))
      (should-not messages))))

(ert-deftest refbox-test-action_keymaps_match_citar_defaults ()
  "Default reference action maps should use Citar's visible bindings."
  (dolist (binding '(("a" . refbox-add-file-to-library)
                     ("b" . refbox-insert-bibtex)
                     ("c" . refbox-insert-citation)
                     ("e" . refbox-open-entry)
                     ("f" . refbox-open-files)
                     ("k" . refbox-insert-keys)
                     ("l" . refbox-open-links)
                     ("n" . refbox-open-notes)
                     ("o" . refbox-open)
                     ("r" . refbox-copy-reference)
                     ("R" . refbox-insert-reference)
                     ("RET" . refbox-run-default-action)))
    (should (eq (lookup-key refbox-map (kbd (car binding)))
                (cdr binding))))
  (dolist (key '("A" "N"))
    (should-not (lookup-key refbox-map (kbd key))))
  (dolist (binding '(("i" . refbox-insert-edit)
                     ("o" . refbox-open)
                     ("e" . refbox-open-entry)
                     ("l" . refbox-open-links)
                     ("n" . refbox-open-notes)
                     ("f" . refbox-open-files)
                     ("r" . refbox-copy-reference)
                     ("RET" . refbox-run-default-action)))
    (should (eq (lookup-key refbox-citation-map (kbd (car binding)))
                (cdr binding))))
  (should-not (lookup-key refbox-citation-map (kbd "b"))))

(ert-deftest refbox-test-open_interactive_keeps_selected_candidate_metadata ()
  "Opening from completion should not throw away the selected candidate."
  (let* ((candidate '(:key "alpha" :fields nil :resources nil))
         (choice (list :type 'link :reference candidate :target "https://example.test"))
         contextual-references
         opened-choice)
    (cl-letf (((symbol-function 'refbox-select-references)
               (lambda (&rest _args)
                 (list candidate)))
              ((symbol-function 'refbox-select-refs)
               (lambda (&rest _args)
                 (error "resource commands should select candidates, not keys")))
              ((symbol-function 'refbox--contextual-reference-list)
               (lambda (references)
                 (setq contextual-references references)
                 references))
              ((symbol-function 'refbox--file-choices)
               (lambda (_references) nil))
              ((symbol-function 'refbox--link-choices)
               (lambda (references)
                 (should (eq (car references) candidate))
                 (list choice)))
              ((symbol-function 'refbox--note-choices)
               (lambda (_references &optional _include-create) nil))
              ((symbol-function 'refbox--open-resource-choice)
               (lambda (choice)
                 (setq opened-choice choice))))
      (call-interactively #'refbox-open)
      (should (equal contextual-references (list candidate)))
      (should (eq opened-choice choice)))))

(ert-deftest refbox-test-insert-preset_allows_freeform_searches ()
  "Preset insertion should not require the input to match configured presets."
  (let (inserted)
    (cl-letf (((symbol-function 'minibufferp)
               (lambda (&optional _buffer) t))
              ((symbol-function 'completing-read)
               (lambda (_prompt _collection &rest args)
                 (should-not (nth 2 args))
                 "custom query"))
              ((symbol-function 'insert)
               (lambda (&rest strings)
                 (setq inserted (apply #'concat strings)))))
      (refbox-insert-preset)
      (should (equal inserted "custom query")))))

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
          (list :program program
                :db "/tmp/old.sqlite"
                :roots (list root)
                :files nil
                :extensions '("bib" "bibtex")
                :include-globs nil
                :exclude-globs nil
                :include-hidden nil))
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
