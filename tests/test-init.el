;;; test-init.el --- Batch test initialization -*- lexical-binding: t; -*-

(require 'package)

(setq package-enable-at-startup nil)
(package-initialize)

(provide 'test-init)

;;; test-init.el ends here
