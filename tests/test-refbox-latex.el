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

(ert-deftest refbox-latex-test-detects-plain-cite ()
  "Plain \\cite commands should expose citation and key metadata."
  (refbox-latex-test-with-buffer "Text \\cite{al|pha}."
    (let ((citation (refbox-latex-citation-at-point)))
      (should (equal (plist-get citation :command) "cite"))
      (should (equal (plist-get citation :keys) '("alpha")))
      (should (equal (refbox-latex-key-at-point) "alpha")))))

(ert-deftest refbox-latex-test-detects-natbib-optional-arguments ()
  "Natbib-style citations should preserve optional arguments and multiple keys."
  (refbox-latex-test-with-buffer "\\citet[see][p. 7]{alpha, be|ta}"
    (let ((citation (refbox-latex-citation-at-point)))
      (should (equal (plist-get citation :command) "citet"))
      (should (equal (plist-get citation :optional-args) '("see" "p. 7")))
      (should (equal (plist-get citation :keys) '("alpha" "beta")))
      (should (equal (refbox-latex-key-at-point) "beta")))))

(ert-deftest refbox-latex-test-inserts-default-command ()
  "Insertion should honor the configured default command."
  (refbox-latex-test-with-buffer "Before | after"
    (let ((refbox-latex-default-command "parencite")
          (refbox-latex-prompt-for-command nil)
          (refbox-latex-default-optional-arguments nil))
      (cl-letf (((symbol-function 'refbox-read-references)
                 (lambda (&rest _args)
                   (list (refbox-latex-test-candidate "alpha")
                         (refbox-latex-test-candidate "beta")))))
        (refbox-latex-insert-citation)
        (should (equal (buffer-string)
                       "Before \\parencite{alpha, beta} after"))))))

(ert-deftest refbox-latex-test-prompts-for-command-and-optional-arguments ()
  "Prompt settings should drive command and optional argument selection."
  (refbox-latex-test-with-buffer "|"
    (let ((refbox-latex-prompt-for-command t)
          (refbox-latex-prompt-for-optional-arguments t))
      (cl-letf (((symbol-function 'completing-read)
                 (lambda (&rest _args) "textcite"))
                ((symbol-function 'read-string)
                 (lambda (prompt &rest _args)
                   (if (string-prefix-p "First" prompt) "see" "p. 2")))
                ((symbol-function 'refbox-read-references)
                 (lambda (&rest _args)
                   (list (refbox-latex-test-candidate "alpha")))))
        (refbox-latex-insert-citation)
        (should (equal (buffer-string)
                       "\\textcite[see][p. 2]{alpha}"))))))

(ert-deftest refbox-latex-test-replaces-existing-citation ()
  "Insertion at an existing citation should replace that citation."
  (refbox-latex-test-with-buffer "A \\cite{al|pha} Z"
    (let ((refbox-latex-default-command "autocite")
          (refbox-latex-default-optional-arguments nil))
      (cl-letf (((symbol-function 'refbox-read-references)
                 (lambda (&rest _args)
                   (list (refbox-latex-test-candidate "gamma")))))
        (refbox-latex-insert-citation)
        (should (equal (buffer-string)
                       "A \\autocite{gamma} Z"))))))

(ert-deftest refbox-latex-test-formats-biblatex-and-optional-arguments ()
  "Formatter should support biblatex-style commands and optional arguments."
  (let ((refbox-latex-key-separator ","))
    (should (equal (refbox-latex-format-citation
                    "parencite"
                    '("alpha" "beta")
                    '("see" "chap. 2"))
                   "\\parencite[see][chap. 2]{alpha,beta}"))))

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
            (should (equal (refbox-latex-bibliography-files)
                           (list (expand-file-name "refs/a.bib" root)
                                 (expand-file-name "refs/b.bib" root))))))
      (delete-directory root t))))

(ert-deftest refbox-latex-test-optional-package-signals-are-optional ()
  "Discovery should read optional helper variables only when already present."
  (refbox-latex-test-with-buffer "|"
    (let ((reftex-default-bibliography '("global.bib"))
          (LaTeX-bibliography-list '("local")))
      (should (equal (refbox-latex-bibliography-files)
                     (list (expand-file-name "global.bib")
                           (expand-file-name "local.bib")))))))

(provide 'test-refbox-latex)

;;; test-refbox-latex.el ends here
