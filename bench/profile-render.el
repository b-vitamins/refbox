;;; profile-render.el --- Profile completion rendering -*- lexical-binding: t; -*-

;;; Commentary:

;; Internal benchmark helper for measuring the Emacs-side completion hot path.

;;; Code:

(require 'json)
(require 'elp)
(require 'refbox)

(defun refbox-profile-render--read-json (path)
  "Read candidate payload from PATH."
  (with-temp-buffer
    (insert-file-contents path)
    (json-parse-buffer :object-type 'plist
                       :array-type 'list
                       :null-object nil
                       :false-object nil)))

(defun refbox-profile-render--candidates (path)
  "Return candidate entries from JSON payload at PATH."
  (plist-get (refbox-profile-render--read-json path) :entries))

(defun refbox-profile-render--once (candidates)
  "Render CANDIDATES once."
  (refbox--with-dynamic-cache (make-hash-table :test 'eq)
    (let ((seen (make-hash-table :test 'equal))
          (selection-map (make-hash-table :test 'equal))
          rendered)
      (dolist (candidate candidates)
        (push (refbox--completion-candidate-display
               candidate seen selection-map)
              rendered))
      (refbox--completion-affixation (nreverse rendered)))))

(defun refbox-profile-render-main ()
  "Run candidate render profiling."
  (when (equal (car command-line-args-left) "--")
    (pop command-line-args-left))
  (let* ((path (pop command-line-args-left))
         (iterations (string-to-number (or (pop command-line-args-left) "200")))
         (candidates (refbox-profile-render--candidates path))
         (functions '(refbox--completion-candidate-display
                      refbox-reference-format-main
                      refbox-reference-format-suffix
                      refbox-reference-indicators
                      refbox--reference-format-main-default
                      refbox--reference-format-suffix-default
                      refbox--first-reference-field
                      refbox-reference-field
                      refbox--candidate-field-table
                      refbox-template-clean
                      refbox-template--fit
                      refbox--shorten-names-to-width
                      refbox--shorten-name
                      refbox--completion-affixation
                      refbox--indicator-text
                      refbox-reference-has-files-p
                      refbox-reference-has-links-p
                      refbox-reference-has-notes-p
                      refbox-resource-file-source-has-items-p
                      refbox-reference-has-any-resource-kind-p
                      refbox-reference-has-resource-kind-p
                      refbox--candidate-resource-kinds)))
    (setq refbox-reference-cited-predicate nil)
    (elp-instrument-list functions)
    (dotimes (_ iterations)
      (refbox-profile-render--once candidates))
    (elp-results)))

(refbox-profile-render-main)

;;; profile-render.el ends here
