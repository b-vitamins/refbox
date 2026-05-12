;;; test-refbox-markdown.el --- Tests for refbox Markdown integration -*- lexical-binding: t; -*-

;;; Commentary:

;; Buffer-level checks for Pandoc-style Markdown citation workflows.

;;; Code:

(require 'ert)
(require 'cl-lib)
(require 'refbox-markdown)

(defmacro refbox-markdown-test-with-buffer (contents &rest body)
  "Create a Markdown buffer from CONTENTS and evaluate BODY.

A single `|' in CONTENTS marks point and is removed before BODY runs."
  (declare (indent 1))
  `(with-temp-buffer
     (let* ((text ,contents)
            (point-index (string-match-p "|" text)))
       (insert (replace-regexp-in-string "|" "" text nil t))
       (when point-index
         (goto-char (1+ point-index)))
       ,@body)))

(defun refbox-markdown-test-candidate (key)
  "Return a minimal refbox candidate for KEY."
  (list :key key))

(ert-deftest refbox-markdown-test-inserts-one-key ()
  "Bare key insertion should insert one Pandoc key."
  (refbox-markdown-test-with-buffer "Alpha |omega"
    (cl-letf (((symbol-function 'refbox-read-reference)
               (lambda (&rest _args)
                 (refbox-markdown-test-candidate "alpha"))))
      (refbox-markdown-insert-key)
      (should (equal (buffer-string) "Alpha @alphaomega")))))

(ert-deftest refbox-markdown-test-inserts-multiple-citation-keys ()
  "Citation insertion should support multiple keys."
  (refbox-markdown-test-with-buffer "Alpha |omega"
    (cl-letf (((symbol-function 'refbox-read-references)
               (lambda (&rest _args)
                 (list (refbox-markdown-test-candidate "alpha")
                       (refbox-markdown-test-candidate "beta")))))
      (refbox-markdown-insert-citation)
      (should (equal (buffer-string) "Alpha [@alpha; @beta]omega")))))

(ert-deftest refbox-markdown-test-detects-key-at-point ()
  "Key helper should find keys inside bracketed citations."
  (refbox-markdown-test-with-buffer "See [@alpha; -@be|ta]."
    (should (equal (refbox-markdown-key-at-point) "beta"))))

(ert-deftest refbox-markdown-test-detects-citation-at-point ()
  "Citation helper should return bracketed citation metadata."
  (refbox-markdown-test-with-buffer "See [see @al|pha pp. 1-2; @beta]."
    (let ((citation (refbox-markdown-citation-at-point)))
      (should (equal (plist-get citation :keys) '("alpha" "beta")))
      (should (equal (buffer-substring-no-properties
                      (plist-get citation :begin)
                      (plist-get citation :end))
                     "[see @alpha pp. 1-2; @beta]")))))

(ert-deftest refbox-markdown-test-edits-existing-citation ()
  "Insertion at a citation should replace the bracketed citation."
  (refbox-markdown-test-with-buffer "A [@al|pha] Z"
    (let ((refbox-markdown-default-prefix "see")
          (refbox-markdown-default-suffix "p. 4"))
      (cl-letf (((symbol-function 'refbox-read-references)
                 (lambda (&rest _args)
                   (list (refbox-markdown-test-candidate "gamma")))))
        (refbox-markdown-insert-citation)
        (should (equal (buffer-string) "A [see @gamma p. 4] Z"))))))

(ert-deftest refbox-markdown-test-prompted-affixes ()
  "Prompted affixes should be reflected in inserted citations."
  (refbox-markdown-test-with-buffer "|"
    (let ((refbox-markdown-prompt-for-affixes t))
      (cl-letf (((symbol-function 'read-string)
                 (lambda (prompt &rest _args)
                   (if (string-prefix-p "Citation prefix" prompt)
                       "compare"
                     "chap. 3")))
                ((symbol-function 'refbox-read-references)
                 (lambda (&rest _args)
                   (list (refbox-markdown-test-candidate "alpha")))))
        (refbox-markdown-insert-citation)
        (should (equal (buffer-string) "[compare @alpha chap. 3]"))))))

(ert-deftest refbox-markdown-test-lists-current-buffer-keys ()
  "Current-buffer key listing should deduplicate Pandoc keys."
  (refbox-markdown-test-with-buffer "[@alpha; @beta]\nText @alpha and [-@gamma]."
    (should (equal (refbox-markdown-list-keys)
                   '("alpha" "beta" "gamma")))))

(provide 'test-refbox-markdown)

;;; test-refbox-markdown.el ends here
