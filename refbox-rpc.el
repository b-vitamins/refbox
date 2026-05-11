;;; refbox-rpc.el --- JSON-RPC client for refbox -*- lexical-binding: t; -*-

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

(defcustom refbox-bibliography-root nil
  "Root directory containing bibliography files for refbox."
  :type 'directory
  :group 'refbox)

(defcustom refbox-database-file
  (expand-file-name "refbox.sqlite" user-emacs-directory)
  "Path to the local refbox SQLite database."
  :type 'file
  :group 'refbox)

(defvar refbox--connection nil
  "Live JSON-RPC connection to the local refbox process.")

(defconst refbox-rpc-method-ping "refbox/ping")

(defun refbox-rpc-live-p ()
  "Return non-nil when the refbox JSON-RPC process is live."
  (and refbox--connection
       (jsonrpc-running-p refbox--connection)))

(defun refbox-rpc--command ()
  "Return the daemon command for the current configuration."
  (list refbox-server-program
        "serve"
        "--root" (expand-file-name refbox-bibliography-root)
        "--db" (expand-file-name refbox-database-file)))

(defun refbox-rpc-ensure ()
  "Start and return the refbox JSON-RPC connection."
  (unless (file-directory-p refbox-bibliography-root)
    (user-error "`refbox-bibliography-root' must name an existing directory"))
  (unless (refbox-rpc-live-p)
    (setq refbox--connection
          (make-instance
           'jsonrpc-process-connection
           :name "refbox"
           :events-buffer-config '(:size 200 :format full)
           :process (lambda ()
                      (make-process
                       :name "refbox"
                       :command (refbox-rpc--command)
                       :connection-type 'pipe
                       :coding 'binary
                       :noquery t
                       :stderr (get-buffer-create "*refbox stderr*")))
           :notification-dispatcher #'ignore
           :request-dispatcher #'ignore
           :on-shutdown (lambda (_conn)
                          (setq refbox--connection nil)))))
  refbox--connection)

(defun refbox-rpc-request (method &optional params)
  "Send METHOD with PARAMS to the local refbox daemon."
  (jsonrpc-request (refbox-rpc-ensure) method params))

(provide 'refbox-rpc)

;;; refbox-rpc.el ends here
