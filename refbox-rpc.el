;;; refbox-rpc.el --- JSON-RPC client for refbox -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Ayan Das

;; Author: Ayan Das <bvits@riseup.net>
;; Maintainer: Ayan Das <bvits@riseup.net>
;; Version: 0.4.1
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

;; Internal JSON-RPC transport helpers for `refbox'.

;;; Code:

(require 'jsonrpc)
(require 'subr-x)

(defgroup refbox nil
  "Local-first bibliography tools."
  :group 'applications
  :prefix "refbox-")

(defcustom refbox-server-program "refbox"
  "Path to the refbox server executable."
  :type 'file
  :group 'refbox)

(defcustom refbox-bibliography-roots nil
  "Bibliography root directories indexed by refbox.

The first root is used when starting the current daemon.  Multiple
roots are retained in configuration so later discovery surfaces can
present the user's full bibliography policy without changing option
names."
  :type '(repeat directory)
  :group 'refbox)

(defcustom refbox-bibliography nil
  "Explicit bibliography files that belong to the user's refbox corpus."
  :type '(repeat file)
  :group 'refbox)

(defcustom refbox-bibliography-extensions '("bib" "bibtex")
  "File extensions considered bibliography files during discovery."
  :type '(repeat string)
  :group 'refbox)

(defcustom refbox-bibliography-include-globs nil
  "Glob patterns included during bibliography discovery."
  :type '(repeat string)
  :group 'refbox)

(defcustom refbox-bibliography-exclude-globs nil
  "Glob patterns excluded during bibliography discovery."
  :type '(repeat string)
  :group 'refbox)

(defcustom refbox-bibliography-include-hidden nil
  "When non-nil, include hidden files and directories during discovery."
  :type 'boolean
  :group 'refbox)

(defcustom refbox-search-default-limit 20
  "Default maximum number of search results requested by refbox commands."
  :type 'natnum
  :group 'refbox)

(defcustom refbox-search-maximum-limit 100
  "Hard maximum number of search results requested by refbox commands."
  :type 'natnum
  :group 'refbox)

(defcustom refbox-database-file
  (expand-file-name "refbox.sqlite" user-emacs-directory)
  "Path to the local refbox SQLite database."
  :type 'file
  :group 'refbox)

(defcustom refbox-rpc-request-timeout 300
  "Seconds to wait for a refbox RPC response.

Cold starts may include schema migrations or first-time index work,
so this timeout must allow legitimate one-time setup to finish."
  :type 'natnum
  :group 'refbox)

(defvar refbox--connection nil
  "Live JSON-RPC connection to the local refbox process.")

(defvar refbox--connection-configuration nil
  "Configuration plist used to start `refbox--connection'.")

(defconst refbox-rpc-method-ping "refbox/ping")
(defconst refbox-rpc-method-status "refbox/status")
(defconst refbox-rpc-method-sync-full "refbox/syncFull")
(defconst refbox-rpc-method-sync-file "refbox/syncFile")
(defconst refbox-rpc-method-search-entries "refbox/searchEntries")
(defconst refbox-rpc-method-list-entries "refbox/listEntries")
(defconst refbox-rpc-method-entry-by-key "refbox/entryByKey")
(defconst refbox-rpc-method-resources-by-key "refbox/resourcesByKey")
(defconst refbox-rpc-method-resources-by-keys "refbox/resourcesByKeys")
(defconst refbox-rpc-method-resolve-files "refbox/resolveFiles")
(defconst refbox-rpc-method-library-files-by-keys "refbox/libraryFilesByKeys")
(defconst refbox-rpc-method-raw-entry "refbox/rawEntry")
(defconst refbox-rpc-method-source-location "refbox/sourceLocation")
(defconst refbox-rpc-method-format-references "refbox/formatReferences")

(defun refbox-rpc-live-p ()
  "Return non-nil when the refbox JSON-RPC process is live."
  (and refbox--connection
       (jsonrpc-running-p refbox--connection)))

(defun refbox-rpc--daemon-root ()
  "Return the configured daemon root or signal a direct user error."
  (unless refbox-bibliography-roots
    (user-error "`refbox-bibliography-roots' must contain at least one directory"))
  (let ((root (expand-file-name (car refbox-bibliography-roots))))
    (unless (file-directory-p root)
      (user-error "refbox bibliography root does not exist: %s" root))
    (file-truename root)))

(defun refbox-rpc--resolve-server-program ()
  "Return the executable path for `refbox-server-program'."
  (unless (and (stringp refbox-server-program)
               (not (string-empty-p refbox-server-program)))
    (user-error "`refbox-server-program' must name an executable"))
  (let ((program (if (file-name-directory refbox-server-program)
                     (expand-file-name refbox-server-program)
                   (executable-find refbox-server-program))))
    (unless (and program (file-executable-p program))
      (user-error "refbox server executable not found: %s" refbox-server-program))
    program))

(defun refbox-rpc--database-file ()
  "Return the configured database path or signal a direct user error."
  (unless (and (stringp refbox-database-file)
               (not (string-empty-p refbox-database-file)))
    (user-error "`refbox-database-file' must name a SQLite database file"))
  (let* ((db (expand-file-name refbox-database-file))
         (parent (file-name-directory (directory-file-name db))))
    (when (file-directory-p db)
      (user-error "refbox database path is a directory: %s" db))
    (unless (and parent (file-directory-p parent))
      (user-error "refbox database directory does not exist: %s" parent))
    (unless (file-writable-p parent)
      (user-error "refbox database directory is not writable: %s" parent))
    db))

(defun refbox-rpc--search-limit (&optional limit)
  "Return LIMIT clamped to configured refbox search bounds."
  (let ((limit (or limit refbox-search-default-limit))
        (maximum refbox-search-maximum-limit))
    (unless (and (integerp limit) (>= limit 0))
      (user-error "`refbox-search-default-limit' must be a non-negative integer"))
    (unless (and (integerp maximum) (> maximum 0))
      (user-error "`refbox-search-maximum-limit' must be a positive integer"))
    (min limit maximum)))

(defun refbox-rpc--configuration ()
  "Return the connection-relevant refbox daemon configuration."
  (list :program (refbox-rpc--resolve-server-program)
        :root (refbox-rpc--daemon-root)
        :db (refbox-rpc--database-file)))

(defun refbox-rpc--command (&optional configuration)
  "Return the daemon command for CONFIGURATION.

When CONFIGURATION is nil, validate and use the current user options."
  (let ((configuration (or configuration (refbox-rpc--configuration))))
    (list (plist-get configuration :program)
          "serve"
          "--root" (plist-get configuration :root)
          "--db" (plist-get configuration :db))))

(defun refbox-rpc-shutdown ()
  "Stop the live refbox JSON-RPC connection, if any."
  (when refbox--connection
    (ignore-errors
      (jsonrpc-shutdown refbox--connection)))
  (setq refbox--connection nil
        refbox--connection-configuration nil))

(defun refbox-rpc-ensure ()
  "Start and return the refbox JSON-RPC connection."
  (let ((configuration (refbox-rpc--configuration)))
    (when (and (refbox-rpc-live-p)
               (not (equal configuration refbox--connection-configuration)))
      (refbox-rpc-shutdown))
    (unless (refbox-rpc-live-p)
      (setq refbox--connection-configuration configuration
            refbox--connection
            (make-instance
             'jsonrpc-process-connection
             :name "refbox"
             :events-buffer-config '(:size 200 :format full)
             :process (lambda ()
                        (make-process
                         :name "refbox"
                         :command (refbox-rpc--command configuration)
                         :connection-type 'pipe
                         :coding 'binary
                         :noquery t
                         :stderr (get-buffer-create "*refbox stderr*")))
             :notification-dispatcher #'ignore
             :request-dispatcher #'ignore
             :on-shutdown (lambda (_conn)
                            (setq refbox--connection nil
                                  refbox--connection-configuration nil))))))
  refbox--connection)

(defun refbox-rpc-request (method &optional params)
  "Send METHOD with PARAMS to the local refbox daemon."
  (jsonrpc-request
   (refbox-rpc-ensure)
   method
   params
   :timeout refbox-rpc-request-timeout))

(provide 'refbox-rpc)

;;; refbox-rpc.el ends here
