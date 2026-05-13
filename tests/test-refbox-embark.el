;;; test-refbox-embark.el --- Tests for refbox Embark integration -*- lexical-binding: t; -*-

;;; Commentary:

;; Optional Embark integration checks.

;;; Code:

(require 'ert)
(require 'cl-lib)
(require 'refbox-embark)
(require 'refbox-latex)

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

(ert-deftest refbox-embark-test-citation-target-at-point ()
  "Citation targets should expose the key at point."
  (with-temp-buffer
    (setq major-mode 'latex-mode)
    (insert "\\cite{alpha}")
    (search-backward "alpha")
    (forward-char 2)
    (let* ((target (refbox-embark-target-citation-at-point))
           (encoded (nth 1 target))
           (reference (refbox-embark-reference encoded)))
      (should (eq (car target) 'refbox-citation))
      (should (equal reference (list :key "alpha")))
      (should (equal (substring-no-properties encoded) "alpha")))))

(ert-deftest refbox-embark-test-setup-registers-finders-and-keymaps ()
  "Setup should register target finders and keymaps only when requested."
  (skip-unless (require 'embark nil t))
  (let ((embark-target-finders nil)
        (embark-keymap-alist nil)
        (embark-multitarget-actions nil))
    (refbox-embark-setup)
    (should (memq #'refbox-embark-target-reference-candidate
                  embark-target-finders))
    (should (memq #'refbox-embark-target-citation-at-point
                  embark-target-finders))
    (should (eq (cdr (assq 'refbox-reference embark-keymap-alist))
                'refbox-embark-reference-map))
    (should (eq (cdr (assq 'refbox-citation embark-keymap-alist))
                'refbox-embark-citation-map))
    (should (eq (lookup-key refbox-embark-reference-map (kbd "s"))
                #'refbox-embark-open-source))
    (should (eq (lookup-key refbox-embark-reference-map (kbd "C"))
                #'refbox-embark-copy-references))
    (should (memq #'refbox-embark-copy-references
                  embark-multitarget-actions))))

(ert-deftest refbox-embark-test-mode_can_disable_registered_surface ()
  "The global mode should be reversible."
  (skip-unless (require 'embark nil t))
  (let ((embark-target-finders nil)
        (embark-keymap-alist nil)
        (embark-multitarget-actions nil)
        refbox-embark-mode)
    (refbox-embark-mode 1)
    (should (memq #'refbox-embark-target-reference-candidate
                  embark-target-finders))
    (should (assq 'refbox-reference embark-keymap-alist))
    (should (memq #'refbox-embark-copy-references
                  embark-multitarget-actions))
    (refbox-embark-mode -1)
    (should-not (memq #'refbox-embark-target-reference-candidate
                      embark-target-finders))
    (should-not (assq 'refbox-reference embark-keymap-alist))
    (should-not (memq #'refbox-embark-copy-references
                      embark-multitarget-actions))))

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
