;;; render-candidates.el --- Batch candidate-rendering benchmark -*- lexical-binding: t; -*-

;;; Commentary:

;; This script is intentionally small and private to the benchmark harness.  It
;; measures Emacs-side candidate display formatting from already fetched daemon
;; candidates, so daemon query latency and display latency stay separate.

;;; Code:

(require 'json)
(require 'refbox)

(defun refbox-bench--read-json (path)
  "Read JSON object from PATH as plists and vectors."
  (with-temp-buffer
    (insert-file-contents path)
    (json-parse-buffer :object-type 'plist
                       :array-type 'array
                       :null-object nil
                       :false-object nil)))

(defun refbox-bench--candidates (path)
  "Return candidate list from JSON payload at PATH."
  (append (plist-get (refbox-bench--read-json path) :entries) nil))

(defun refbox-bench--render-once (candidates)
  "Render CANDIDATES once and return elapsed milliseconds."
  (let ((gc-cons-threshold
         (max gc-cons-threshold refbox--completion-gc-cons-threshold))
        (start (float-time)))
      (refbox--with-dynamic-cache (make-hash-table :test 'eq)
        (let ((seen (make-hash-table :test 'equal))
              (selection-map (make-hash-table :test 'equal))
              rendered)
          (dolist (candidate candidates)
            (push (refbox--completion-candidate-display
                   candidate seen selection-map)
                  rendered))
          (refbox--completion-affixation (nreverse rendered))))
    (* 1000.0 (- (float-time) start))))

(defun refbox-bench--main ()
  "Run the batch rendering benchmark."
  (when (equal (car command-line-args-left) "--")
    (pop command-line-args-left))
  (let* ((candidate-file (pop command-line-args-left))
         (iterations (string-to-number (or (pop command-line-args-left) "20")))
         (candidates (refbox-bench--candidates candidate-file))
         samples)
    (unless candidates
      (error "candidate payload is empty"))
    (setq refbox-reference-cited-predicate nil)
    (refbox-bench--render-once candidates)
    (dotimes (_ iterations)
      (push (refbox-bench--render-once candidates) samples))
    (princ (json-encode `((samples_ms . ,(vconcat (nreverse samples))))))))

(refbox-bench--main)

;;; render-candidates.el ends here
