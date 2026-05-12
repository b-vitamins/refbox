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
             (:raw_name "doi" :lookup_name "doi" :value "10.1000/refbox")))
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

(provide 'test-refbox)

;;; test-refbox.el ends here
