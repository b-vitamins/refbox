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

(provide 'refbox)

;;; refbox.el ends here
