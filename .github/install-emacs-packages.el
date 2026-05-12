;;; install-emacs-packages.el --- CI package bootstrap -*- lexical-binding: t; -*-

(require 'package)

(setq package-archives
      '(("gnu" . "https://elpa.gnu.org/packages/")))

(package-initialize)
(package-refresh-contents)

(defun refbox-ci-install-package (package minimum-version)
  "Install PACKAGE unless at least MINIMUM-VERSION is available."
  (unless (package-installed-p package (version-to-list minimum-version))
    (package-install package)))

(refbox-ci-install-package 'org "9.8")

;;; install-emacs-packages.el ends here
