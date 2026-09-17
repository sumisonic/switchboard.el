;;; checkdoc-batch.el --- Run checkdoc on the package files and exit non-zero on findings -*- lexical-binding: t; -*-

;;; Commentary:

;; emacs -Q --batch -l test/checkdoc-batch.el

;;; Code:

(require 'checkdoc)

(let ((checkdoc-diagnostic-buffer "*switchboard-checkdoc*")
      (checkdoc-autofix-flag 'never))
  (dolist (file '("switchboard.el" "switchboard-consult.el"))
    (with-current-buffer (find-file-noselect (expand-file-name file))
      (checkdoc-current-buffer t)))
  (with-current-buffer checkdoc-diagnostic-buffer
    (let ((findings (count-matches "\\.el:[0-9]+:" (point-min) (point-max))))
      (princ (buffer-string))
      (princ (format "checkdoc: %d finding(s)\n" findings))
      (kill-emacs (if (> findings 0) 1 0)))))

;;; checkdoc-batch.el ends here
