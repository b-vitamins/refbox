;;; refbox.el --- Local-first bibliography tools -*- lexical-binding: t; -*-

;; Copyright (C) 2026 refbox contributors

;; Author: refbox contributors <maintainers@example.invalid>
;; Maintainer: refbox contributors <maintainers@example.invalid>
;; Version: 0.0.0
;; Package-Requires: ((emacs "29.1") (jsonrpc "1.0.27"))
;; Keywords: bib, tex, files, convenience

;; This file is not part of GNU Emacs.

;; refbox is free software: you can redistribute it and/or modify
;; it under the terms of the GNU General Public License as published by
;; the Free Software Foundation, either version 3 of the License, or
;; (at your option) any later version.
;;
;; refbox is distributed in the hope that it will be useful,
;; but WITHOUT ANY WARRANTY; without even the implied warranty of
;; MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
;; GNU General Public License for more details.
;;
;; You should have received a copy of the GNU General Public License
;; along with refbox.  If not, see <https://www.gnu.org/licenses/>.

;;; Commentary:

;; refbox provides a local-first bibliography workflow backed by a dedicated
;; index and query engine.  This file contains the package entry points and
;; user-facing commands.

;;; Code:

(require 'refbox-rpc)

;;;###autoload
(defun refbox-ping ()
  "Check that the local refbox daemon responds."
  (interactive)
  (let* ((response (refbox-rpc-request refbox-rpc-method-ping))
         (version (plist-get response :version))
         (root (plist-get response :root)))
    (message "refbox %s at %s" version root)
    response))

;;;###autoload
(defun refbox-status ()
  "Show the current refbox daemon and index status."
  (interactive)
  (let* ((response (refbox-rpc-request refbox-rpc-method-status))
         (counts (plist-get response :counts))
         (files (plist-get counts :file_count))
         (entries (plist-get counts :entry_count))
         (diagnostics (plist-get counts :diagnostic_count)))
    (message "refbox: %s files, %s entries, %s diagnostics"
             files entries diagnostics)
    response))

;;;###autoload
(defun refbox-sync ()
  "Synchronize all configured bibliography roots."
  (interactive)
  (let* ((response (refbox-rpc-request refbox-rpc-method-sync-full))
         (changed (plist-get response :changed_file_count))
         (removed (plist-get response :removed_file_count))
         (entries (plist-get response :indexed_entry_count)))
    (message "refbox sync: %s changed, %s removed, %s indexed entries"
             changed removed entries)
    response))

;;;###autoload
(defun refbox-sync-file (file)
  "Synchronize bibliography FILE."
  (interactive "fSync bibliography file: ")
  (let* ((path (expand-file-name file))
         (response (refbox-rpc-request refbox-rpc-method-sync-file
                                       (list :path path)))
         (changed (plist-get response :changed_file_count))
         (removed (plist-get response :removed_file_count))
         (entries (plist-get response :indexed_entry_count)))
    (message "refbox file sync: %s changed, %s removed, %s indexed entries"
             changed removed entries)
    response))

;;;###autoload
(defun refbox-sync-current-file ()
  "Synchronize the file visited by the current buffer."
  (interactive)
  (unless buffer-file-name
    (user-error "Current buffer is not visiting a file"))
  (refbox-sync-file buffer-file-name))

(provide 'refbox)

;;; refbox.el ends here
