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

(defun refbox-markdown-test-search-candidate (key source-path)
  "Return a search candidate for KEY from SOURCE-PATH."
  (list :key key
        :source_path source-path
        :entry_type "article"
        :score 0.0
        :fields nil
        :resources nil))

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
    (let ((refbox-markdown-prompt-for-extra-arguments nil))
      (cl-letf (((symbol-function 'refbox-read-references)
                 (lambda (&rest _args)
                   (list (refbox-markdown-test-candidate "alpha")
                         (refbox-markdown-test-candidate "beta")))))
        (refbox-markdown-insert-citation)
        (should (equal (buffer-string) "Alpha [@alpha; @beta]omega"))))))

(ert-deftest refbox-markdown-test-inserts_supplied_citation_keys ()
  "Citation insertion should accept direct key lists."
  (refbox-markdown-test-with-buffer "Alpha |omega"
    (let ((refbox-markdown-prompt-for-extra-arguments nil))
      (refbox-markdown-insert-citation '("alpha" "beta"))
      (should (equal (buffer-string) "Alpha [@alpha; @beta]omega")))))

(ert-deftest refbox-markdown-test-detects-key-at-point ()
  "Key helper should find keys inside bracketed citations."
  (refbox-markdown-test-with-buffer "See [@alpha; -@be|ta]."
    (should (equal (refbox-markdown-key-at-point) "beta"))))

(ert-deftest refbox-markdown-test-public_key_regexp_captures_group_one ()
  "The public Pandoc key regexp should capture citation keys in group one."
  (should (string-match refbox-markdown-citation-key-regexp "-@doe-2020"))
  (should (equal (match-string 1 "-@doe-2020") "doe-2020"))
  (should (string-match refbox-markdown-citation-key-regexp "@{doe key}"))
  (should (equal (match-string 1 "@{doe key}") "doe key")))

(ert-deftest refbox-markdown-test-detects_braced_pandoc_keys ()
  "Markdown helpers should understand Pandoc brace-delimited keys."
  (refbox-markdown-test-with-buffer "See [@alpha; @{braced-key}; -@{ne|g key}]."
    (should (equal (refbox-markdown-key-at-point) "neg key"))
    (should (equal (plist-get (refbox-markdown-citation-at-point) :keys)
                   '("alpha" "braced-key" "neg key"))))
  (refbox-markdown-test-with-buffer "Text @{braced-key} and [-@{neg key}]."
    (should (equal (refbox-markdown-list-keys)
                   '("braced-key" "neg key")))))

(ert-deftest refbox-markdown-test-key_at_point_uses_actual_key_span ()
  "Key lookup should preserve full Pandoc key bounds."
  (refbox-markdown-test-with-buffer "See [@{bra|ced key}; @beta]."
    (pcase-let ((`(,key ,begin ,end)
                 (refbox-markdown--key-and-bounds-at-point)))
      (should (equal key "braced key"))
      (should (equal (buffer-substring-no-properties begin end)
                     "@{braced key}"))
      (should (equal (refbox-markdown-key-at-point) "braced key"))))
  (refbox-markdown-test-with-buffer "Text @al|pha outside."
    (pcase-let ((`(,key ,begin ,end)
                 (refbox-markdown--key-and-bounds-at-point)))
      (should (equal key "alpha"))
      (should (equal (buffer-substring-no-properties begin end)
                     "@alpha")))))

(ert-deftest refbox-markdown-test-detects-citation-at-point ()
  "Citation helper should return bracketed citation metadata."
  (refbox-markdown-test-with-buffer "See [see @al|pha pp. 1-2; @beta]."
    (let ((citation (refbox-markdown-citation-at-point)))
      (should (equal (plist-get citation :keys) '("alpha" "beta")))
      (should (equal (buffer-substring-no-properties
                      (plist-get citation :begin)
                      (plist-get citation :end))
                     "[see @alpha pp. 1-2; @beta]")))))

(ert-deftest refbox-markdown-test-detects_multiline_citation_at_point ()
  "Citation helper should handle balanced bracket expressions across lines."
  (refbox-markdown-test-with-buffer "See [compare @alpha;\n  @be|ta pp. 1-2]."
    (let ((citation (refbox-markdown-citation-at-point)))
      (should (equal (plist-get citation :keys) '("alpha" "beta")))
      (should (equal (buffer-substring-no-properties
                      (plist-get citation :begin)
                      (plist-get citation :end))
                     "[compare @alpha;\n  @beta pp. 1-2]")))))

(ert-deftest refbox-markdown-test-citation_lookup_uses_containing_brackets ()
  "Citation lookup should ignore unrelated previous bracketed text."
  (refbox-markdown-test-with-buffer "[not @alpha]\n\nplain |text"
    (should-not (refbox-markdown-citation-at-point)))
  (refbox-markdown-test-with-buffer "|[@alpha]"
    (should (equal (plist-get (refbox-markdown-citation-at-point) :keys)
                   '("alpha"))))
  (refbox-markdown-test-with-buffer "[@alpha]|"
    (should (equal (plist-get (refbox-markdown-citation-at-point) :keys)
                   '("alpha")))))

(ert-deftest refbox-markdown-test-adds-to-existing-citation ()
  "Insertion at a citation should add selected keys."
  (refbox-markdown-test-with-buffer "A [@al|pha; @beta] Z"
    (let ((refbox-markdown-default-prefix "see")
          (refbox-markdown-default-suffix "p. 4"))
      (cl-letf (((symbol-function 'refbox-read-references)
                 (lambda (&rest _args)
                   (list (refbox-markdown-test-candidate "gamma")))))
        (refbox-markdown-insert-citation)
        (should (equal (buffer-string) "A [@alpha; @gamma; @beta] Z"))))))

(ert-deftest refbox-markdown-test-inserts_new_citation_at_bracket_edges ()
  "Insertion at citation bracket edges should match Citar's boundary behavior."
  (let ((refbox-markdown-prompt-for-extra-arguments nil))
    (refbox-markdown-test-with-buffer "A |[@alpha] Z"
      (refbox-markdown-insert-citation '("beta"))
      (should (equal (buffer-string) "A [@beta][@alpha] Z")))
    (refbox-markdown-test-with-buffer "A [@alpha]| Z"
      (refbox-markdown-insert-citation '("beta"))
      (should (equal (buffer-string) "A [@alpha][@beta] Z")))))

(ert-deftest refbox-markdown-test-prompted-affixes ()
  "Prompted affixes should be reflected in inserted citations."
  (refbox-markdown-test-with-buffer "|"
    (let ((refbox-markdown-prompt-for-extra-arguments t))
      (cl-letf (((symbol-function 'read-from-minibuffer)
                 (lambda (prompt &rest _args)
                   (if (string-prefix-p "Prenote" prompt)
                       "compare"
                     "chap. 3")))
                ((symbol-function 'refbox-read-references)
                 (lambda (&rest _args)
                   (list (refbox-markdown-test-candidate "alpha")))))
        (refbox-markdown-insert-citation)
        (should (equal (buffer-string) "[compare @alpha, chap. 3]"))))))

(ert-deftest refbox-markdown-test-lists-current-buffer-keys ()
  "Current-buffer key listing should deduplicate Pandoc keys."
  (refbox-markdown-test-with-buffer "[@alpha; @beta]\nText @alpha and [-@gamma]."
    (should (equal (refbox-markdown-list-keys)
                   '("alpha" "beta" "gamma")))))

(ert-deftest refbox-markdown-test-capf-completes-citation-keys ()
  "Markdown CAPF should complete citation keys through bounded search."
  (let ((calls nil)
        (refbox-capf-limit 11))
    (refbox-markdown-test-with-buffer "See [@al|]."
      (cl-letf (((symbol-function 'refbox-rpc-request)
                 (lambda (method params)
                   (should (equal method refbox-rpc-method-search-entries))
                   (push params calls)
                   (list :entries
                         (list (refbox-markdown-test-search-candidate
                                "alpha"
                                "/tmp/refs.bib"))))))
        (let* ((capf (refbox-markdown-completion-at-point))
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
            (should (equal (plist-get params :limit) 11))
            (should (member "title"
                            (append (plist-get params :field_names) nil)))
            (should (equal (plist-get params :ranked) :json-false))))))))

(ert-deftest refbox-markdown-test-capf-completes_braced_citation_keys ()
  "Markdown CAPF should complete inside brace-delimited Pandoc keys."
  (let ((refbox-capf-limit 11))
    (refbox-markdown-test-with-buffer "See [@{al|}]."
      (cl-letf (((symbol-function 'refbox-rpc-request)
                 (lambda (method params)
                   (should (equal method refbox-rpc-method-search-entries))
                   (should (equal (plist-get params :query) "al"))
                   (should (equal (plist-get params :limit) 11))
                   (should (member "title"
                                   (append (plist-get params :field_names)
                                           nil)))
                   (should (equal (plist-get params :ranked) :json-false))
                   (list :entries
                         (list (refbox-markdown-test-search-candidate
                                "alpha"
                                "/tmp/refs.bib"))))))
        (let* ((capf (refbox-markdown-completion-at-point))
               (start (nth 0 capf))
               (end (nth 1 capf))
               (table (nth 2 capf))
               (candidate (car (all-completions
                                (buffer-substring-no-properties start end)
                                table))))
          (should (equal (buffer-substring-no-properties start end) "al"))
          (should (equal (substring-no-properties candidate) "alpha")))))))

(ert-deftest refbox-markdown-test-capf-setup-is-buffer-local ()
  "Markdown CAPF setup should install a buffer-local completion function."
  (refbox-markdown-test-with-buffer "|"
    (setq-local completion-at-point-functions nil)
    (refbox-markdown-setup-capf)
    (should (memq #'refbox-markdown-completion-at-point
                  completion-at-point-functions))
    (should (local-variable-p 'completion-at-point-functions))))

(provide 'test-refbox-markdown)

;;; test-refbox-markdown.el ends here
