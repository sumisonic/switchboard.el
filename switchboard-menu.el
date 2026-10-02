;;; switchboard-menu.el --- Transient menu of the Switchboard list -*- lexical-binding: t; -*-

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

;; `switchboard-menu', bound to `?' in the list, shows the list's
;; commands in a transient menu, like `?' in Magit.  The menu uses the
;; list's own keys, so it doubles as a reminder of them, and its
;; heading names the session at point and its state.
;;
;; Transient comes with Emacs, and the menu uses only what the version
;; in Emacs 29.1 provides.  This file is loaded the first time the menu
;; is opened: switchboard.el is often loaded at startup, to enable
;; `switchboard-watch-mode', and should not bring transient with it.

;;; Code:

(require 'switchboard)
(require 'transient)

(defvar switchboard--menu-agent nil
  "The session on the line `switchboard-menu' was opened on, or nil.
It is taken when the menu opens, because transient versions differ
in the buffer they show the heading from.")

(defun switchboard--menu-heading (&optional _object)
  "Return the heading of `switchboard-menu': the session's name and state.
OBJECT, the group a newer transient passes, is ignored."
  (if-let* ((agent switchboard--menu-agent))
      (let ((state (switchboard-agent-state agent)))
        (concat (propertize (or (switchboard-agent-name agent)
                                (switchboard-agent-id agent))
                            'face 'transient-heading)
                "  "
                (propertize (symbol-name (or state 'unknown))
                            'face (switchboard--state-face state))))
    "No session on this line"))

(defun switchboard--menu-check-session ()
  "Signal a user error unless point is on the menu's session.
A refresh while the menu is open redraws the list.  Point follows the
session while it is listed, but moves to another line once it has
left the list, and a command would then act on a session other than
the one the heading names."
  (let ((agent switchboard--menu-agent))
    (cond
     ((not agent)
      (user-error "No session on this line"))
     ((not (equal (tabulated-list-get-id) (switchboard-agent-id agent)))
      (user-error "Switchboard: point is no longer on %s; open the menu again"
                  (or (switchboard-agent-name agent) (switchboard-agent-id agent)))))))

(defmacro switchboard--define-menu-command (name command)
  "Define NAME, a menu command for COMMAND on the menu's session.
NAME calls COMMAND interactively once `switchboard--menu-check-session'
has passed."
  `(defun ,name ()
     ,(format "Run `%s' on the menu's session.
See `switchboard--menu-check-session'." command)
     (interactive)
     (switchboard--menu-check-session)
     (call-interactively #',command)))

(switchboard--define-menu-command switchboard--menu-attach switchboard-attach)
(switchboard--define-menu-command switchboard--menu-transcript switchboard-transcript)
(switchboard--define-menu-command switchboard--menu-stop switchboard-stop)
(switchboard--define-menu-command switchboard--menu-respawn switchboard-respawn)
(switchboard--define-menu-command switchboard--menu-remove switchboard-remove)

(defun switchboard--menu-acknowledge (&optional all)
  "Acknowledge the menu's session.
With prefix argument ALL, acknowledge every session wherever point
is, as `switchboard-acknowledge' does in the list.  See
`switchboard--menu-check-session'."
  (interactive "P")
  (unless all
    (switchboard--menu-check-session))
  (switchboard-acknowledge all))

(defun switchboard--menu-acknowledge-all ()
  "Acknowledge every finished or failed session, turning the lamp off.
This is `switchboard-acknowledge' with a prefix argument, for the menu."
  (interactive)
  (switchboard-acknowledge t))

;;;###autoload (autoload 'switchboard-menu "switchboard-menu" nil t)
(transient-define-prefix switchboard-menu ()
  "Show the commands of the Switchboard list in a transient menu.
The heading names the session at point and its state.  The keys are
those of the list, see `switchboard-mode', plus U, which acknowledges
every session.  The session commands act on the session the heading
names, and refuse if a refresh has dropped it from the list.  As in
the list, `a' with a prefix argument acknowledges every session.
Only available in the list buffer."
  [:description switchboard--menu-heading
   ["Session"
    ("RET" "Attach" switchboard--menu-attach)
    ("l" "Transcript" switchboard--menu-transcript)
    ("a" "Acknowledge" switchboard--menu-acknowledge)
    ("s" "Stop" switchboard--menu-stop)
    ("r" "Respawn" switchboard--menu-respawn)
    ("k" "Remove" switchboard--menu-remove)]
   ["List"
    ("g" "Refresh" switchboard-refresh)
    ("A" "Toggle show all" switchboard-toggle-show-all)
    ("U" "Acknowledge all" switchboard--menu-acknowledge-all)
    ("d" "Dispatch" switchboard-dispatch)]]
  (interactive)
  (unless (derived-mode-p 'switchboard-mode)
    (user-error "Not in a Switchboard buffer"))
  (setq switchboard--menu-agent (switchboard-agent-by-id (tabulated-list-get-id)))
  (transient-setup 'switchboard-menu))

(provide 'switchboard-menu)
;;; switchboard-menu.el ends here
