;;; install-emacs-packages.el --- CI package bootstrap -*- lexical-binding: t; -*-

(require 'package)

(setq package-archives
      '(("gnu" . "https://elpa.gnu.org/packages/")))
(setq package-install-upgrade-built-in t)

(package-initialize)
(package-refresh-contents)

(defun refbox-ci-install-package (package minimum-version)
  "Install PACKAGE unless at least MINIMUM-VERSION is available."
  (let ((minimum (version-to-list minimum-version)))
    (unless (package-installed-p package minimum)
      (package-install package))
    (unless (package-installed-p package minimum)
      (error "%s %s or newer is required" package minimum-version))))

(refbox-ci-install-package 'org "9.8")

;;; install-emacs-packages.el ends here
