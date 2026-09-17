;;; switchboard-consult.el --- consult integration for Switchboard -*- lexical-binding: t; -*-

;; Copyright (C) 2026 sumisonic

;; Author: sumisonic
;; Keywords: tools, processes, convenience
;; URL: https://github.com/sumisonic/switchboard.el

;; This file is not part of GNU Emacs.

;; This program is free software: you can redistribute it and/or modify
;; it under the terms of the GNU General Public License as published by
;; the Free Software Foundation, either version 3 of the License, or
;; (at your option) any later version.

;; This program is distributed in the hope that it will be useful,
;; but WITHOUT ANY WARRANTY; without even the implied warranty of
;; MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
;; GNU General Public License for more details.

;; You should have received a copy of the GNU General Public License
;; along with this program.  If not, see <https://www.gnu.org/licenses/>.

;;; Commentary:

;; Choosing a Claude Code background session with consult.  This file
;; is the only part of Switchboard that calls consult; switchboard.el
;; itself works without it.
;;
;; It provides:
;;
;;   `switchboard-consult'            pick a session, previewed, and open it
;;   `switchboard-consult-read-agent' the reader `switchboard-read-agent'
;;                                    uses for the consult backend of
;;                                    `switchboard-completion-backend'
;;   `switchboard-consult-source'     a source for `consult-buffer-sources'
;;
;; The picker goes through `consult--multi', the entry point behind
;; `consult-buffer', with the sources defined here: one per state
;; group for the picker, and one with every session for
;; `consult-buffer'.  The highlighted session is previewed with its
;; transcript, or with its terminal buffer when one is attached.  The
;; sources are variables so that `consult-customize' applies to them.
;;
;; With `switchboard-completion-backend' at `auto' (the default) this
;; file is loaded on demand as soon as consult is installed.  To have
;; sessions show up in `consult-buffer' as well:
;;
;;   (with-eval-after-load 'consult
;;     (require 'switchboard-consult)
;;     (add-to-list 'consult-buffer-sources 'switchboard-consult-source t))

;;; Code:

(require 'switchboard)

;; consult is loaded by the commands, not here, so that this file
;; byte-compiles as part of the package even where consult is absent.
(declare-function consult--multi "consult" (sources &rest options))
(declare-function consult--buffer-preview "consult" ())

(defun switchboard--consult-require ()
  "Load consult, or signal a user error if it is not installed."
  (unless (require 'consult nil t)
    (user-error "Switchboard: the consult package is not installed")))

(defvar switchboard--consult-all nil
  "Non-nil while the consult sources offer every session.
Otherwise they offer the visible ones, like the list does.")

(defconst switchboard--preview-buffer-name "*switchboard preview*"
  "Base name of the buffers a session's transcript is previewed in.
Each state function owns one, created on first use and killed when
the minibuffer exits.")

(defun switchboard--consult-group (agent)
  "Return the group of AGENT: `needs-you', `working' or `finished'."
  (pcase (switchboard-agent-state agent)
    ((or 'blocked 'failed) 'needs-you)
    ('working 'working)
    (_ 'finished)))

(defun switchboard--consult-items (&optional group)
  "Return the candidates of the sessions in GROUP, most urgent first.
GROUP nil means every session.  Only the current snapshot is read;
nothing is fetched, so a `consult-buffer' source never blocks the
minibuffer.  `switchboard-watch-mode' keeps the snapshot fresh."
  (mapcar #'switchboard--candidate
          (seq-filter (lambda (agent)
                        (or (null group)
                            (eq (switchboard--consult-group agent) group)))
                      (switchboard--sort-agents
                       (switchboard--visible-agents switchboard--consult-all)))))

(defun switchboard--consult-preview-buffer (candidate buffer)
  "Return the buffer that previews CANDIDATE's session, or nil.
A terminal buffer already attached to the session is shown as it is.
Otherwise the transcript is rendered into BUFFER, which is returned.
A preview never attaches: that would start a process."
  (when-let* ((agent (switchboard-agent-by-id (switchboard--candidate-id candidate))))
    (or (switchboard--attached-buffer agent)
        (when-let* ((file (switchboard-transcript-file agent)))
          (condition-case err
              (progn
                (switchboard--transcript-render buffer agent file
                                                switchboard-transcript-chunk)
                buffer)
            (error
             (message "Switchboard: preview failed: %s" (error-message-string err))
             nil))))))

(defun switchboard--consult-state ()
  "Return a consult state function that previews the highlighted session.
The buffer `switchboard--consult-preview-buffer' returns is shown the
way consult shows a buffer candidate, scrolled to the end of the
transcript.  The state owns one preview buffer, created on first use
and killed when the minibuffer exits; only a preview renders into it,
the final `return' does not."
  (let ((preview (consult--buffer-preview))
        (own nil))
    (lambda (action candidate)
      (let ((buffer (and (eq action 'preview)
                         candidate
                         (progn
                           (unless (buffer-live-p own)
                             (setq own (generate-new-buffer
                                        switchboard--preview-buffer-name)))
                           (switchboard--consult-preview-buffer candidate own)))))
        (funcall preview action buffer)
        ;; The window kept its old start when the buffer was reused, so
        ;; bring the end of the transcript into view now that it shows.
        ;; Only after a preview into our own buffer: with no candidate
        ;; BUFFER is nil, and so is OWN until the first preview.
        (when (and buffer (eq buffer own))
          (switchboard--transcript-show-tail own)))
      (when (and (eq action 'exit) (buffer-live-p own))
        (kill-buffer own)))))

(defcustom switchboard-consult-display-buffer-function #'pop-to-buffer-same-window
  "Function that shows the session chosen in the consult picker.
It is called with the terminal or transcript buffer.  The default
takes over the selected window, as choosing a buffer in
`consult-buffer' does; `pop-to-buffer' follows your `display-buffer'
rules instead, usually another window.  It stands in for
`switchboard-display-buffer-function' while the choice is opened, so a
`switchboard-attach-function' of your own is free to ignore it."
  :type '(choice (const :tag "The selected window" pop-to-buffer-same-window)
                 (const :tag "As display-buffer decides (usually another window)"
                        pop-to-buffer)
                 function)
  :group 'switchboard)

(defun switchboard--consult-action (candidate)
  "Attach to CANDIDATE's session when alive, else show its transcript.
Attaching to a stopped session would start it again; that is left to
an explicit `switchboard-attach'.  The buffer is shown with
`switchboard-consult-display-buffer-function'."
  (let ((agent (switchboard--coerce-agent candidate))
        (switchboard-display-buffer-function
         switchboard-consult-display-buffer-function))
    (if (switchboard-agent-alive-p agent)
        (switchboard-attach agent)
      (switchboard-transcript agent))))

(defun switchboard--consult-make-source (name narrow &optional group)
  "Return a consult source called NAME with narrowing key NARROW.
GROUP restricts it to one `switchboard--consult-group'; nil offers
every session."
  (list :name name
        :narrow narrow
        :category 'switchboard-agent
        :annotate #'switchboard--annotate-candidate
        :items (lambda () (switchboard--consult-items group))
        :state #'switchboard--consult-state
        :action #'switchboard--consult-action))

(defvar switchboard-consult-source
  (switchboard--consult-make-source "Claude sessions" ?c)
  "The consult source of the visible sessions, most urgent first.
Add it to `consult-buffer-sources' to have sessions show up in
`consult-buffer', narrowed with `c':

  (add-to-list \\='consult-buffer-sources \\='switchboard-consult-source t)

Choosing one attaches to it, or shows its transcript if it is not
running; the highlighted one is previewed.  Only the current snapshot
is shown: `switchboard-watch-mode' keeps it fresh.  Tune the source
with `consult-customize' once switchboard is loaded, for example

  (consult-customize switchboard-consult-source
                     :preview-key \\='(:debounce 0.3 any))")

(defvar switchboard-consult-source-needs-you
  (switchboard--consult-make-source "Needs you" ?b 'needs-you)
  "The consult source of the blocked and failed sessions.")

(defvar switchboard-consult-source-working
  (switchboard--consult-make-source "Working" ?w 'working)
  "The consult source of the working sessions.")

(defvar switchboard-consult-source-finished
  (switchboard--consult-make-source "Finished" ?d 'finished)
  "The consult source of the done and stopped sessions.")

(defcustom switchboard-consult-sources
  '(switchboard-consult-source-needs-you
    switchboard-consult-source-working
    switchboard-consult-source-finished)
  "Sources of `switchboard-consult', in display order.
The consult backend of `switchboard-read-agent' uses them too.  Each
is the symbol of a consult source shaped like
`switchboard-consult-source'."
  :type '(repeat symbol)
  :group 'switchboard)

;;;###autoload
(defun switchboard-consult-read-agent (prompt &optional all)
  "Read a session with `consult--multi', prompting with PROMPT.
ALL non-nil offers every session.  The sources are those of
`switchboard-consult-sources' without their actions, so that the
choice is returned instead of acted on.  This is what
`switchboard-read-agent' calls for the consult backend of
`switchboard-completion-backend'."
  (switchboard--consult-require)
  (let ((switchboard--consult-all all)
        (sources (mapcar (lambda (source)
                           (plist-put (copy-sequence (if (symbolp source)
                                                         (symbol-value source)
                                                       source))
                                      :action nil))
                         switchboard-consult-sources)))
    (switchboard--coerce-agent
     (car (consult--multi sources :prompt prompt :require-match t :sort nil)))))

;;;###autoload
(defun switchboard-consult (&optional all)
  "Choose a session with consult, previewing it, and open it.
Sessions come grouped as Needs you, Working and Finished, narrowable
with `b', `w' and `d' after `consult-narrow-key'.  The highlighted one
is previewed: its terminal buffer if one is attached, else its
transcript.  RET attaches to a running session and shows the
transcript of one that is not; Embark offers the other actions (see
`switchboard-embark-map').  With prefix argument ALL, sessions hidden
by `switchboard-done-retention' are offered too."
  (interactive "P")
  (switchboard--consult-require)
  (switchboard--ensure-snapshot)
  (let ((switchboard--consult-all all))
    (unless (switchboard--consult-items)
      (user-error "Switchboard: no sessions to choose from"))
    (consult--multi switchboard-consult-sources
                    :prompt "Session: " :require-match t :sort nil))
  nil)

(provide 'switchboard-consult)
;;; switchboard-consult.el ends here
