;;; switchboard.el --- Monitor and attach to Claude Code background sessions -*- lexical-binding: t; -*-

;; Copyright (C) 2026 sumisonic

;; Author: sumisonic
;; Version: 0.1.0
;; Package-Requires: ((emacs "29.1"))
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

;; Switchboard is an Emacs front-end for the background sessions that
;; Claude Code runs under `claude agents'.  Like a telephone switchboard
;; it shows one line per session, lights a lamp when a session needs
;; you (blocked), has finished (done) or has failed, and lets you plug
;; in (`claude attach') without leaving Emacs.
;;
;; Scope: background sessions only, i.e. the sessions that
;; `claude agents --json' lists.  An interactive `claude' session is
;; not tracked until you background it.  Switchboard is not a generic
;; agent framework.
;;
;; Switchboard only uses the public Claude Code CLI:
;;
;;   claude agents --json --all   session list (the source of truth)
;;   claude attach <id>           attach a terminal to a session
;;   claude --bg <prompt>         dispatch a new session
;;   claude stop|respawn|rm <id>  lifecycle
;;
;; It never reads the supervisor's private state under ~/.claude/jobs/.
;; It does read session transcripts, the JSON Lines files under
;; ~/.claude/projects/ that Claude Code also hands to hooks as
;; transcript_path, to show a conversation as Markdown.
;;
;; Quick start:
;;
;;   (switchboard-watch-mode 1)   ; poll, diff, light the mode-line lamp
;;   M-x switchboard              ; the list
;;   M-x switchboard-consult      ; pick a session with a preview (consult)
;;
;; consult and Embark are optional.  With consult installed, sessions
;; are chosen with a preview of their transcript (switchboard-consult.el,
;; loaded on demand), and `switchboard-consult-source' can join
;; `consult-buffer-sources'.  `switchboard-embark-setup' adds Embark
;; actions on sessions in the minibuffer, the list, transcript and
;; attached buffers.
;;
;; How state reaches Emacs:
;;
;;   - Polling: every `switchboard-poll-interval' seconds while
;;     `switchboard-watch-mode' is on (nil disables polling).
;;   - Push: a Claude Code hook can run
;;       emacsclient -e '(switchboard-refresh "SESSION-ID")'
;;     to trigger an immediate refresh.  See bin/switchboard-hook.
;;
;; Either way the JSON is re-fetched and diffed against the previous
;; snapshot, and only state *transitions* run
;; `switchboard-state-change-functions'.  The first snapshot never
;; notifies, so restarting Emacs does not replay old events.  The lamp,
;; on the other hand, always reflects the current snapshot: sessions
;; that were already blocked when Emacs started do light it.
;;
;; What happens on a transition is yours to decide.  The default is the
;; lamp plus a `message'.  OS notifications and jumps to a terminal
;; multiplexer belong in your init file.
;;
;; This is an unofficial project.  It is not affiliated with or
;; endorsed by Anthropic.  "Claude" and "Claude Code" are trademarks
;; of Anthropic, PBC.

;;; Code:

(require 'cl-lib)
(require 'seq)
(require 'subr-x)
(require 'tabulated-list)
(require 'project)
(require 'parse-time)

;; Optional terminal backends for attaching.  None is a hard dependency.
(declare-function eat-mode "eat" ())
(declare-function eat-exec "eat" (buffer name command startfile switches))
(defvar eat-kill-buffer-on-exit)
(declare-function vterm-mode "vterm" ())
(defvar vterm-shell)
(defvar vterm-kill-buffer-on-exit)
(declare-function ghostel-exec "ghostel" (buffer program &optional args identity))
(declare-function ghostel-send-key "ghostel" (key-name &optional mods))
(defvar ghostel-kill-buffer-on-exit)
;; Optional completion integrations, also soft dependencies.  The
;; consult one lives in switchboard-consult.el; its entry points are
;; autoloaded here too, so that they work when this file is loaded from
;; a plain load-path without package autoloads.
(autoload 'switchboard-consult "switchboard-consult"
  "Choose a session with consult, previewing it, and open it." t)
(autoload 'switchboard-consult-read-agent "switchboard-consult"
  "Read a session with `consult--multi', prompting with PROMPT.
ALL non-nil offers every session.")
(defvar embark-keymap-alist)
(defvar embark-target-finders)
(declare-function json-encode "json" (object))
(declare-function markdown-mode "markdown-mode" ())
(defvar json-encoding-pretty-print)
(defvar json-encoding-default-indentation)

;;;; Customization

(defgroup switchboard nil
  "Monitor and attach to Claude Code background sessions."
  :group 'tools
  :prefix "switchboard-"
  :link '(url-link "https://github.com/sumisonic/switchboard.el"))

(defcustom switchboard-claude-program "claude"
  "Name or path of the Claude Code executable."
  :type 'string)

(defcustom switchboard-poll-interval 5
  "Seconds between polls while `switchboard-watch-mode' is on.
Set to nil to disable polling; refreshes then happen only through
`switchboard-refresh', for example from a Claude Code hook.  Toggle
`switchboard-watch-mode' for a change to take effect."
  :type '(choice (const :tag "Disabled" nil) (number :tag "Seconds")))

(defcustom switchboard-idle-poll-interval 30
  "Seconds between polls while no session has a live process.
Nothing can change state then except a new dispatch, so polling can
slow down.  nil uses `switchboard-poll-interval' throughout."
  :type '(choice (const :tag "Same as poll interval" nil)
                 (number :tag "Seconds")))

(defcustom switchboard-fetch-timeout 30
  "Seconds after which a fetch that has not finished is abandoned.
Guards against a hung `claude' and against a descendant process that
keeps the pipes open.  nil waits forever."
  :type '(choice (const :tag "Wait forever" nil) (number :tag "Seconds")))

(defcustom switchboard-notify-states '(blocked done failed)
  "States whose entry runs `switchboard-state-change-functions'.
Possible states are `working', `blocked', `done', `failed' and
`stopped'."
  :type '(repeat symbol))

(defcustom switchboard-state-change-functions nil
  "Abnormal hook run when a session enters a state in `switchboard-notify-states'.
Each function is called with three arguments: the `switchboard-agent'
struct, the previous state symbol (nil when the session is new) and
the new state symbol.  The hook is not run for the first snapshot
after Emacs starts.  An error in one function is reported and does
not stop the others."
  :type 'hook)

(defcustom switchboard-echo-transitions t
  "Non-nil means `message' every transition that runs the hook."
  :type 'boolean)

(defcustom switchboard-attach-function #'switchboard-attach-in-terminal
  "Function used to attach to a session.
Called with one argument, a `switchboard-agent'.  The default opens
`claude attach ID' in a terminal buffer inside Emacs (see
`switchboard-terminal-backend').  Replace it to open the session
elsewhere, for example in an external terminal multiplexer."
  :type 'function)

(defcustom switchboard-terminal-backend 'auto
  "Terminal used by `switchboard-attach-in-terminal'.
`auto' picks the first of ghostel, vterm and eat that is installed.
The native ones come first because a busy session redraws its screen
many times a second and replays its transcript on attach; eat, being
pure Emacs Lisp, was measured to stall Emacs for minutes on that,
while ghostel and vterm keep up.  None of the packages is a hard
dependency.  A function is called with two arguments, a
buffer name and the command as a list of strings, and must return the
terminal buffer."
  :type '(choice (const auto) (const ghostel) (const vterm) (const eat) function))

(defcustom switchboard-kill-buffer-on-exit t
  "Non-nil kills the terminal buffer when `claude attach' exits.
Detaching with `Ctrl+Z' ends the attach process; the session itself
keeps running under the supervisor."
  :type 'boolean)

(defcustom switchboard-attach-hook nil
  "Hook run in a terminal buffer right after it attached to a session.
The buffer's major mode is already set, so buffer-local settings made
here survive.  Use it for things your terminal or input-method setup
needs in these buffers."
  :type 'hook)

(defcustom switchboard-display-buffer-function #'pop-to-buffer
  "Function that shows a session's terminal or transcript buffer.
It is called with the buffer.  The default, `pop-to-buffer', follows
your `display-buffer' rules, which usually means another window, so
that the list stays in view; `pop-to-buffer-same-window' takes over
the selected window instead.  Any function of one argument works, for
example one that calls `pop-to-buffer' with a `display-buffer' action
of your own.  The default attach function and `switchboard-transcript'
use it; a `switchboard-attach-function' of your own need not.  The
consult picker has its own, `switchboard-consult-display-buffer-function'."
  :type '(choice (const :tag "As display-buffer decides (usually another window)"
                        pop-to-buffer)
                 (const :tag "The selected window" pop-to-buffer-same-window)
                 function))

(defcustom switchboard-newline-sequence "\e[13;2u"
  "Bytes `switchboard-send-newline' sends to insert a newline in the prompt.
This is the CSI u encoding of Shift+Return; Claude Code reads it as a
newline inside its prompt (verified with 2.1.274).  eat and vterm
cannot encode Shift+Return themselves, so the bytes are written to the
pty directly.  In a ghostel buffer the key goes through ghostel's own
encoder instead and this sequence is not used."
  :type 'string)

(defcustom switchboard-done-retention (* 24 60 60)
  "Seconds after which old sessions drop out of the list and the lamp.
A session is always kept while it is working, while it is blocked or
failed with its process still alive, or while it changed state during
this Emacs session.  Any other session, including one that was blocked
when its process exited, is kept only while it started less than this
many seconds ago.  nil keeps every session `claude agents --json --all'
returns.  `switchboard-toggle-show-all' overrides this in the list
buffer."
  :type '(choice (const :tag "Keep all" nil) (integer :tag "Seconds")))

(defcustom switchboard-lamp-glyphs
  '((blocked . "!") (done . "✓") (failed . "✗") (error . "⚠"))
  "Glyphs used in the mode-line lamp and the list's first column."
  :type '(alist :key-type symbol :value-type string))

(defcustom switchboard-projects-directory "~/.claude/projects/"
  "Directory where Claude Code keeps session transcripts.
Each session is a JSON Lines file named after its session id, in a
subdirectory derived from the session's working directory."
  :type 'directory)

(defcustom switchboard-transcript-turns 10
  "Minimum number of recent turns `switchboard-transcript' reads.
A turn is one prompt of yours or one reply of Claude's.  The file is
read from its end, `switchboard-transcript-chunk' bytes at a time,
until at least this many turns are found; `+' in the transcript
buffer reads further back."
  :type 'integer)

(defcustom switchboard-transcript-chunk 262144
  "Bytes read from the end of a transcript per attempt.
The read starts here and doubles until `switchboard-transcript-turns'
turns are found, up to `switchboard-transcript-max-bytes'."
  :type 'integer)

(defcustom switchboard-transcript-max-bytes 4194304
  "Bytes from the end of a transcript the first read grows up to.
The read doubles from `switchboard-transcript-chunk' and stops at this
limit even when fewer than `switchboard-transcript-turns' turns were
found: transcripts grow to many megabytes, and a session with few but
huge turns would otherwise be read whole.  Only the automatic growth
is limited; a chunk larger than this is read as it is, and `+' in the
transcript buffer reads further back regardless.  nil removes the
limit."
  :type '(choice (const :tag "No limit" nil) (integer :tag "Bytes")))

(defcustom switchboard-completion-backend 'auto
  "How `switchboard-read-agent' offers sessions outside the list.
`consult' reads with `consult--multi': sessions are grouped by state,
narrowable, and the highlighted one is previewed (see
`switchboard-consult').  `completing-read' uses plain
`completing-read', which vertico, Embark and friends enhance on their
own.  `auto' is `consult' when the consult package is installed, else
`completing-read'.  consult is not a hard dependency."
  :type '(choice (const auto) (const consult) (const completing-read)))

(defcustom switchboard-buffer-name "*switchboard*"
  "Name of the list buffer."
  :type 'string)

;;;; Faces

(defface switchboard-blocked
  '((t :inherit warning :weight bold))
  "Face for sessions that are waiting on you.")

(defface switchboard-done
  '((t :inherit success))
  "Face for sessions that finished.")

(defface switchboard-failed
  '((t :inherit error :weight bold))
  "Face for sessions that failed.")

(defface switchboard-working
  '((t :inherit shadow))
  "Face for sessions that are working.")

(defface switchboard-stopped
  '((t :inherit shadow :slant italic))
  "Face for sessions that were stopped.")

;;;; Data model

(cl-defstruct (switchboard-agent
               (:constructor switchboard--agent-create)
               (:copier nil))
  "One background session as reported by `claude agents --json'.
STATE, STATUS and KIND are symbols; WAITING-FOR is a string or nil.
PID and STATUS are only present while the session's process is
alive; WAITING-FOR only while STATUS is `waiting'.  The accessors and
`switchboard-agent-p' are public; Switchboard builds the structs
itself, so the constructor is not."
  id session-id name cwd kind state status waiting-for pid started-at)

(defun switchboard--agent-from-alist (record)
  "Build a `switchboard-agent' from RECORD, one parsed JSON object."
  (let-alist record
    (switchboard--agent-create
     :id .id
     :session-id .sessionId
     :name .name
     :cwd .cwd
     :kind (and .kind (intern .kind))
     :state (and .state (intern .state))
     :status (and .status (intern .status))
     :waiting-for .waitingFor
     :pid .pid
     :started-at .startedAt)))

(defun switchboard--parse-agents (json)
  "Parse JSON, the output of `claude agents --json --all'.
Return a list of `switchboard-agent' structs in the order given."
  (mapcar #'switchboard--agent-from-alist
          (json-parse-string json
                             :object-type 'alist
                             :array-type 'list
                             :null-object nil
                             :false-object nil)))

(defun switchboard-agent-directory (agent)
  "Return the last component of AGENT's working directory."
  (let ((cwd (switchboard-agent-cwd agent)))
    (if cwd
        (file-name-nondirectory (directory-file-name cwd))
      "")))

(defun switchboard-agent-alive-p (agent)
  "Return non-nil if AGENT's process is alive."
  (and (switchboard-agent-pid agent) t))

(defun switchboard-agent-age (agent)
  "Return seconds since AGENT started, or nil if unknown."
  (when-let* ((ms (switchboard-agent-started-at agent)))
    (- (float-time) (/ ms 1000.0))))

;;;; State

(defvar switchboard--agents nil
  "Latest snapshot, a list of `switchboard-agent'.")

(defvar switchboard--states (make-hash-table :test #'equal)
  "Session id to its state in the latest snapshot.")

(defvar switchboard--transitioned (make-hash-table :test #'equal)
  "Ids of sessions that changed state during this Emacs session.")

(defvar switchboard--unacknowledged (make-hash-table :test #'equal)
  "Ids of sessions that finished or failed and were not acknowledged.
The value is the state, `done' or `failed'.")

(defvar switchboard--initialized nil
  "Non-nil once the first snapshot has been taken.")

(defvar switchboard--last-error nil
  "Last fetch error message, or nil after a successful fetch.")

(defvar switchboard--process nil
  "The fetch process in flight, if any.")

(defvar switchboard--refresh-pending nil
  "Non-nil if a refresh was requested while one was in flight.")

(defvar switchboard--timer nil
  "Polling timer of `switchboard-watch-mode'.")

(defun switchboard--reset ()
  "Forget every snapshot and mark.  Used by the test suite."
  (setq switchboard--agents nil
        switchboard--initialized nil
        switchboard--last-error nil)
  (clrhash switchboard--states)
  (clrhash switchboard--transitioned)
  (clrhash switchboard--unacknowledged))

(defun switchboard-agent-by-id (id)
  "Return the agent whose short or full id is ID, or nil."
  (seq-find (lambda (a)
              (or (equal (switchboard-agent-id a) id)
                  (equal (switchboard-agent-session-id a) id)))
            switchboard--agents))

;;;; Fetching

(defun switchboard--report-error (message)
  "Record MESSAGE as the last error and echo it if it is new."
  (unless (equal message switchboard--last-error)
    (message "Switchboard: %s" message))
  (setq switchboard--last-error message)
  (switchboard--after-update))

(defun switchboard--program ()
  "Return the absolute path of the Claude executable, or nil."
  (executable-find switchboard-claude-program))

(defun switchboard--buffer-string (buffer)
  "Return the contents of BUFFER, or an empty string if it is dead."
  (if (buffer-live-p buffer)
      (with-current-buffer buffer (buffer-string))
    ""))

(defun switchboard--agents-json ()
  "Return the output of `claude agents --json --all' as a string.
Synchronous: used for the first snapshot of an interactive command
and by the tests.  The watch loop uses `switchboard-refresh'."
  (let ((program (or (switchboard--program)
                     (error "%s not found in `exec-path'"
                            switchboard-claude-program))))
    (with-temp-buffer
      (let ((status (call-process program nil (list t nil) nil
                                  "agents" "--json" "--all")))
        (unless (eql status 0)
          (error "`%s agents --json' exited with %s"
                 switchboard-claude-program status))
        (buffer-string)))))

;;;###autoload
(defun switchboard-refresh (&optional session-id)
  "Re-fetch the session list asynchronously and diff it against the last snapshot.
SESSION-ID, when non-nil, names the session that triggered the
refresh, for example from a Claude Code hook; the whole list is
fetched regardless.  Never blocks and never signals, so it is safe to
call from `emacsclient -e'.  A call while a fetch is in flight
schedules one more fetch after it."
  (interactive)
  (ignore session-id)
  (condition-case err
      (if switchboard--process
          (setq switchboard--refresh-pending t)
        (switchboard--start-fetch))
    (error
     (switchboard--report-error
      (format "refresh failed: %s" (error-message-string err)))))
  nil)

(defun switchboard--start-fetch ()
  "Start `claude agents --json --all' and parse it when it exits.
`switchboard--process' stays non-nil until the result has been
applied, which is what \"in flight\" means to `switchboard-refresh'."
  (let ((program (switchboard--program)))
    (if (not program)
        (switchboard--report-error
         (format "%s not found in `exec-path'" switchboard-claude-program))
      (let ((stdout (generate-new-buffer " *switchboard-fetch*"))
            (stderr (generate-new-buffer " *switchboard-fetch-stderr*"))
            (process nil))
        (condition-case err
            (setq process
                  (make-process :name "switchboard-fetch"
                                :buffer stdout
                                :stderr stderr
                                :command (list program "agents" "--json" "--all")
                                :connection-type 'pipe
                                :coding 'utf-8-unix
                                :noquery t
                                :sentinel #'switchboard--fetch-sentinel))
          (error
           (when (buffer-live-p stdout) (kill-buffer stdout))
           (when (buffer-live-p stderr) (kill-buffer stderr))
           (switchboard--report-error
            (format "could not start `%s agents --json': %s"
                    switchboard-claude-program
                    (error-message-string err)))))
        (when process
          (process-put process 'switchboard-stdout stdout)
          (process-put process 'switchboard-stderr stderr)
          ;; `:stderr' with a buffer makes Emacs create a second pipe
          ;; process; its default sentinel would write a status line
          ;; into the buffer, so give it ours, which also joins the
          ;; two processes before finishing.
          (when-let* ((stderr-process (get-buffer-process stderr)))
            (process-put process 'switchboard-stderr-process stderr-process)
            (process-put stderr-process 'switchboard-main process)
            (set-process-sentinel stderr-process
                                  #'switchboard--fetch-stderr-sentinel))
          (setq switchboard--process process)
          (when-let* ((seconds (switchboard--valid-interval
                               switchboard-fetch-timeout
                               'switchboard-fetch-timeout)))
            (process-put process 'switchboard-timeout-timer
                         (run-with-timer seconds nil
                                         #'switchboard--abort-fetch
                                         process "timed out")))
          ;; `claude' must not wait for stdin.  If the process has
          ;; already exited this signals, and then EOF is moot.
          (ignore-errors (process-send-eof process)))))))

(defun switchboard--fetch-sentinel (process _event)
  "Finish the fetch of PROCESS once it has exited."
  (when (memq (process-status process) '(exit signal))
    (switchboard--maybe-finish-fetch process)))

(defun switchboard--fetch-stderr-sentinel (stderr-process _event)
  "Finish the fetch whose stderr pipe STDERR-PROCESS closed."
  (when-let* ((process (process-get stderr-process 'switchboard-main)))
    (switchboard--maybe-finish-fetch process)))

(defconst switchboard--stderr-drain-seconds 1
  "Seconds to wait for a closed process's stderr pipe before cutting it.
A descendant that inherited the pipe, such as a daemon the CLI
started, would otherwise keep the fetch open forever.")

(defun switchboard--maybe-finish-fetch (process)
  "Finish PROCESS once both it and its stderr pipe are done, exactly once.
The two sentinels can run in either order; whichever comes second
does the work.  If the pipe stays open after PROCESS exited, it is
cut after `switchboard--stderr-drain-seconds'."
  (let ((stderr-process (process-get process 'switchboard-stderr-process)))
    (cond
     ((process-get process 'switchboard-finished))
     ((not (memq (process-status process) '(exit signal))))
     ((and stderr-process (process-live-p stderr-process))
      (unless (process-get process 'switchboard-drain-timer)
        (process-put process 'switchboard-drain-timer
                     (run-with-timer switchboard--stderr-drain-seconds nil
                                     #'switchboard--cut-stderr process))))
     (t
      (process-put process 'switchboard-finished t)
      (switchboard--finish-fetch process)))))

(defun switchboard--cut-stderr (process)
  "Close the stderr pipe of PROCESS that a descendant kept open, then finish."
  (process-put process 'switchboard-drain-timer nil)
  (unless (process-get process 'switchboard-finished)
    (when-let* ((stderr-process (process-get process 'switchboard-stderr-process)))
      (when (process-live-p stderr-process)
        (set-process-sentinel stderr-process #'ignore)
        (ignore-errors (delete-process stderr-process))))
    (switchboard--maybe-finish-fetch process)))

(defun switchboard--cancel-fetch-timers (process)
  "Cancel the timeout and drain timers of PROCESS."
  (dolist (key '(switchboard-timeout-timer switchboard-drain-timer))
    (when-let* ((timer (process-get process key)))
      (cancel-timer timer)
      (process-put process key nil))))

(defun switchboard--finish-fetch (process)
  "Apply the output of the finished PROCESS, then release the fetch slot."
  (switchboard--cancel-fetch-timers process)
  (let ((stdout (process-get process 'switchboard-stdout))
        (stderr (process-get process 'switchboard-stderr)))
    (unwind-protect
        (if (and (eq (process-status process) 'exit)
                 (eql (process-exit-status process) 0))
            (condition-case err
                (switchboard--apply-snapshot
                 (switchboard--parse-agents (switchboard--buffer-string stdout)))
              (error
               (switchboard--report-error
                (format "could not parse `%s agents --json': %s"
                        switchboard-claude-program
                        (error-message-string err)))))
          (switchboard--report-error
           (format "`%s agents --json' %s %s%s"
                   switchboard-claude-program
                   (if (eq (process-status process) 'exit)
                       "exited with"
                     "was killed by signal")
                   (process-exit-status process)
                   (let ((text (string-trim (switchboard--buffer-string stderr))))
                     (if (string-empty-p text) "" (concat ": " text))))))
      (when (buffer-live-p stdout) (kill-buffer stdout))
      (when (buffer-live-p stderr) (kill-buffer stderr))
      (switchboard--fetch-done process))))

(defun switchboard--abort-fetch (process reason)
  "Abandon PROCESS, report REASON and release the fetch slot.
The fetch is marked finished and the sentinels are disarmed before
anything is deleted, so nothing this triggers applies a snapshot.
Safe to call more than once."
  (unless (process-get process 'switchboard-finished)
    (process-put process 'switchboard-finished t)
    (switchboard--cancel-fetch-timers process)
    (unwind-protect
        (progn
          (dolist (p (list process
                           (process-get process 'switchboard-stderr-process)))
            (when (processp p)
              (set-process-sentinel p #'ignore)
              (ignore-errors (delete-process p))))
          (dolist (b (list (process-get process 'switchboard-stdout)
                           (process-get process 'switchboard-stderr)))
            (when (buffer-live-p b) (kill-buffer b)))
          (switchboard--report-error
           (format "`%s agents --json' %s" switchboard-claude-program reason)))
      (switchboard--fetch-done process))))

(defun switchboard--fetch-done (process)
  "Release the fetch slot held by PROCESS and run a pending refresh.
Only the owner releases the slot: a hook run from the snapshot may
already have queued the next fetch."
  (when (eq switchboard--process process)
    (setq switchboard--process nil)
    (when switchboard--refresh-pending
      (setq switchboard--refresh-pending nil)
      (switchboard-refresh))))

;;;; Diffing and notification

(defun switchboard--apply-snapshot (agents)
  "Replace the snapshot with AGENTS and act on state transitions.
The first snapshot only initializes.  Afterwards every session whose
state differs from the previous snapshot (or that is new) counts as a
transition; those into `switchboard-notify-states' run
`switchboard-state-change-functions'."
  (let ((first (not switchboard--initialized))
        (new-states (make-hash-table :test #'equal))
        transitions)
    (dolist (agent agents)
      (let* ((id (switchboard-agent-id agent))
             (old (gethash id switchboard--states))
             (new (switchboard-agent-state agent)))
        (puthash id new new-states)
        (unless (or first (eq old new))
          (push (list agent old new) transitions))))
    (setq switchboard--states new-states
          switchboard--agents agents
          switchboard--initialized t
          switchboard--last-error nil)
    (switchboard--forget-missing new-states)
    (dolist (transition (nreverse transitions))
      (pcase-let ((`(,agent ,old ,new) transition))
        (let ((id (switchboard-agent-id agent)))
          (puthash id t switchboard--transitioned)
          (if (memq new '(done failed))
              (puthash id new switchboard--unacknowledged)
            (remhash id switchboard--unacknowledged)))
        (when (memq new switchboard-notify-states)
          (when switchboard-echo-transitions
            (message "Switchboard: %s (%s) %s"
                     (switchboard-agent-name agent)
                     (switchboard-agent-directory agent)
                     new))
          (switchboard--run-state-change-hook agent old new))))
    (switchboard--after-update)))

(defun switchboard--forget-missing (states)
  "Drop the entries of sessions that are absent from STATES."
  (dolist (table (list switchboard--transitioned switchboard--unacknowledged))
    (let (gone)
      (maphash (lambda (id _)
                 (when (eq (gethash id states 'switchboard--missing)
                           'switchboard--missing)
                   (push id gone)))
               table)
      (dolist (id gone) (remhash id table)))))

(defun switchboard--run-state-change-hook (agent old new)
  "Run `switchboard-state-change-functions' with AGENT OLD NEW.
An error in one function is reported and the others still run."
  (run-hook-wrapped
   'switchboard-state-change-functions
   (lambda (function)
     (condition-case err
         (funcall function agent old new)
       (error
        (message "Switchboard: error in %S: %s"
                 function (error-message-string err))))
     nil)))

(defun switchboard--after-update ()
  "Refresh everything that displays the snapshot."
  (force-mode-line-update t)
  (when-let* ((buffer (get-buffer switchboard-buffer-name)))
    (with-current-buffer buffer
      (when (derived-mode-p 'switchboard-mode)
        (tabulated-list-print t)))))

;;;; Visibility

(defun switchboard--visible-p (agent)
  "Return non-nil if AGENT passes `switchboard-done-retention'.
Working sessions, blocked or failed sessions whose process is alive,
and sessions that changed state during this Emacs session are always
visible.  Everything else, including a blocked session whose process
has exited, is visible only while younger than the retention."
  (let ((state (switchboard-agent-state agent)))
    (or (null switchboard-done-retention)
        (eq state 'working)
        (and (memq state '(blocked failed))
             (switchboard-agent-alive-p agent))
        (gethash (switchboard-agent-id agent) switchboard--transitioned)
        (let ((age (switchboard-agent-age agent)))
          (and age (< age switchboard-done-retention))))))

(defun switchboard--visible-agents (&optional all)
  "Return the agents to show.\nWith ALL non-nil, skip the retention filter."
  (if all
      switchboard--agents
    (seq-filter #'switchboard--visible-p switchboard--agents)))

(defun switchboard--urgency (agent)
  "Return AGENT's display rank; lower is more urgent.
A blocked session whose process exited ranks below a failed one: it
is either stale or parked by the supervisor, so it is less pressing
than a fresh failure."
  (pcase (switchboard-agent-state agent)
    ('blocked (if (switchboard-agent-alive-p agent) 0 2))
    ('failed 1)
    ('working 3)
    ('done 4)
    ('stopped 5)
    (_ 6)))

(defun switchboard--sort-agents (agents)
  "Return AGENTS ordered by urgency, then by start time, newest first."
  (sort (copy-sequence agents)
        (lambda (a b)
          (let ((ra (switchboard--urgency a))
                (rb (switchboard--urgency b)))
            (if (/= ra rb)
                (< ra rb)
              (> (or (switchboard-agent-started-at a) 0)
                 (or (switchboard-agent-started-at b) 0)))))))

;;;; Mode line

(defun switchboard--glyph (key)
  "Return the lamp glyph for KEY."
  (or (alist-get key switchboard-lamp-glyphs) (symbol-name key)))

(defun switchboard--state-face (state)
  "Return the face for STATE."
  (pcase state
    ('blocked 'switchboard-blocked)
    ('done 'switchboard-done)
    ('failed 'switchboard-failed)
    ('stopped 'switchboard-stopped)
    (_ 'switchboard-working)))

(defvar switchboard--mode-line-map
  (let ((map (make-sparse-keymap)))
    (define-key map [mode-line mouse-1] #'switchboard)
    map)
  "Keymap of the mode-line lamp.")

(defun switchboard--lamp-counts ()
  "Return (BLOCKED DONE FAILED) counts for the lamp."
  (let ((blocked (seq-count (lambda (a) (eq (switchboard-agent-state a) 'blocked))
                            (switchboard--visible-agents)))
        (done 0)
        (failed 0))
    (maphash (lambda (_ state)
               (if (eq state 'failed) (cl-incf failed) (cl-incf done)))
             switchboard--unacknowledged)
    (list blocked done failed)))

(defun switchboard--mode-line-string ()
  "Return the lamp, or an empty string when there is nothing to show."
  (pcase-let ((`(,blocked ,done ,failed) (switchboard--lamp-counts)))
    (let ((parts
           (delq nil
                 (list
                  (and (> blocked 0)
                       (propertize (format "%s%d" (switchboard--glyph 'blocked) blocked)
                                   'face 'switchboard-blocked))
                  (and (> done 0)
                       (propertize (format "%s%d" (switchboard--glyph 'done) done)
                                   'face 'switchboard-done))
                  (and (> failed 0)
                       (propertize (format "%s%d" (switchboard--glyph 'failed) failed)
                                   'face 'switchboard-failed))
                  (and switchboard--last-error
                       (propertize (switchboard--glyph 'error)
                                   'face 'switchboard-failed))))))
      (if (null parts)
          ""
        (propertize (concat " [" (string-join parts " ") "]")
                    'help-echo (or switchboard--last-error
                                   "Claude Code sessions: blocked / done / failed\nmouse-1: open Switchboard")
                    'mouse-face 'mode-line-highlight
                    'local-map switchboard--mode-line-map)))))

(defconst switchboard--mode-line-construct
  '(:eval (switchboard--mode-line-string))
  "Mode-line construct added to `global-mode-string'.")

;;;; Polling

(defun switchboard--cancel-timer ()
  "Cancel the polling timer."
  (when switchboard--timer
    (cancel-timer switchboard--timer)
    (setq switchboard--timer nil)))

(defun switchboard--valid-interval (value name)
  "Return VALUE if it is a positive number, else nil after reporting NAME."
  (cond
   ((null value) nil)
   ((and (numberp value) (> value 0)) value)
   (t (switchboard--report-error
       (format "%s must be a positive number, not %S; polling disabled"
               name value))
      nil)))

(defun switchboard--current-interval ()
  "Return the seconds until the next poll, or nil for no polling."
  (when-let* ((base (switchboard--valid-interval switchboard-poll-interval
                                                'switchboard-poll-interval)))
    (let ((idle (switchboard--valid-interval switchboard-idle-poll-interval
                                             'switchboard-idle-poll-interval)))
      (if (and idle
               switchboard--initialized
               (not (seq-some #'switchboard-agent-alive-p switchboard--agents)))
          (max base idle)
        base))))

(defun switchboard--schedule-poll ()
  "Schedule the next poll according to `switchboard--current-interval'."
  (switchboard--cancel-timer)
  (when-let* ((seconds (switchboard--current-interval)))
    (setq switchboard--timer
          (run-with-timer seconds nil #'switchboard--poll-tick))))

(defvar switchboard-watch-mode)

(defun switchboard--poll-tick ()
  "Refresh and schedule the next poll."
  (setq switchboard--timer nil)
  (when switchboard-watch-mode
    (switchboard-refresh)
    (switchboard--schedule-poll)))

(defun switchboard--show-lamp ()
  "Add the lamp to `global-mode-string', whatever shape it has.
Follows `display-time-mode': a nil value becomes a list, a list gets
the lamp appended, and a bare construct is wrapped in a list."
  (cond
   ((null global-mode-string)
    (setq global-mode-string (list "" switchboard--mode-line-construct)))
   ((and (listp global-mode-string)
         (not (keywordp (car global-mode-string))))
    (unless (member switchboard--mode-line-construct global-mode-string)
      (setq global-mode-string
            (append global-mode-string (list switchboard--mode-line-construct)))))
   (t
    (setq global-mode-string
          (list "" global-mode-string switchboard--mode-line-construct)))))

(defun switchboard--hide-lamp ()
  "Remove the lamp from `global-mode-string'.
A value that `switchboard--show-lamp' built from nil goes back to nil."
  (when (and (listp global-mode-string)
             (member switchboard--mode-line-construct global-mode-string))
    (setq global-mode-string
          (remove switchboard--mode-line-construct global-mode-string))
    (when (equal global-mode-string '(""))
      (setq global-mode-string nil))))

;;;###autoload
(define-minor-mode switchboard-watch-mode
  "Poll Claude Code background sessions and show a lamp in the mode line.
While on, `claude agents --json --all' is fetched every
`switchboard-poll-interval' seconds, transitions run
`switchboard-state-change-functions', and `global-mode-string'
carries a lamp such as \"[!1 ✓2]\" (blocked, unacknowledged done).
Click the lamp to open the list.

Turning the mode off cancels the timer; a fetch already in flight,
and at most one queued behind it, still completes."
  :global t
  :group 'switchboard
  (switchboard--cancel-timer)
  (if switchboard-watch-mode
      (progn
        (switchboard--show-lamp)
        (switchboard-refresh)
        (switchboard--schedule-poll))
    (switchboard--hide-lamp))
  (force-mode-line-update t))

;;;; List buffer

(defvar-local switchboard--show-all nil
  "Non-nil shows every session regardless of `switchboard-done-retention'.")

(defvar-keymap switchboard-mode-map
  :doc "Keymap of `switchboard-mode'."
  :parent tabulated-list-mode-map
  "RET" #'switchboard-attach
  "SPC" #'switchboard-transcript
  "l" #'switchboard-transcript
  "g" #'switchboard-refresh
  "a" #'switchboard-acknowledge
  "A" #'switchboard-toggle-show-all
  "d" #'switchboard-dispatch
  "s" #'switchboard-stop
  "r" #'switchboard-respawn
  "k" #'switchboard-remove)

(define-derived-mode switchboard-mode tabulated-list-mode "Switchboard"
  "Major mode listing Claude Code background sessions.
\\<switchboard-mode-map>
Sessions that need you come first.  \\[switchboard-attach] attaches,
\\[switchboard-transcript] shows the conversation, \\[switchboard-acknowledge]
acknowledges a finished session, \\[switchboard-toggle-show-all]
shows sessions hidden by `switchboard-done-retention',
\\[switchboard-refresh] refreshes.  \\[switchboard-dispatch] starts a
new session; \\[switchboard-stop], \\[switchboard-respawn] and
\\[switchboard-remove] act on the one at point."
  (setq tabulated-list-format
        [("" 2 nil)
         ("State" 8 nil)
         ("Waiting" 14 nil)
         ("Dir" 18 nil)
         ("Name" 40 nil)
         ("Id" 9 nil)
         ("Age" 5 nil)]
        tabulated-list-padding 1
        tabulated-list-sort-key nil
        tabulated-list-entries #'switchboard--list-entries)
  (add-hook 'tabulated-list-revert-hook #'switchboard-refresh nil t)
  (tabulated-list-init-header))

(defun switchboard--format-age (seconds)
  "Format SECONDS as a short age such as \"5m\" or \"2d\"."
  (cond
   ((null seconds) "")
   ((< seconds 60) "now")
   ((< seconds 3600) (format "%dm" (/ seconds 60)))
   ((< seconds 86400) (format "%dh" (/ seconds 3600)))
   (t (format "%dd" (/ seconds 86400)))))

(defun switchboard--list-entry (agent)
  "Return the `tabulated-list-entries' element for AGENT."
  (let* ((id (switchboard-agent-id agent))
         (state (switchboard-agent-state agent))
         (face (switchboard--state-face state))
         (mark (or (gethash id switchboard--unacknowledged)
                   (and (eq state 'blocked) 'blocked)))
         (waiting (or (switchboard-agent-waiting-for agent)
                      (and (eq state 'blocked)
                           (not (switchboard-agent-alive-p agent))
                           "exited")
                      "")))
    (list id
          (vector
           (if mark (propertize (switchboard--glyph mark) 'face face) "")
           (propertize (symbol-name (or state 'unknown)) 'face face)
           (propertize waiting 'face face)
           (propertize (switchboard-agent-directory agent)
                       'help-echo (switchboard-agent-cwd agent))
           (or (switchboard-agent-name agent) "")
           id
           (switchboard--format-age (switchboard-agent-age agent))))))

(defun switchboard--list-entries ()
  "Return the entries for the list buffer."
  (mapcar #'switchboard--list-entry
          (switchboard--sort-agents
           (switchboard--visible-agents switchboard--show-all))))

(defun switchboard--agent-at-point ()
  "Return the agent on the current line, or signal a user error."
  (or (and (derived-mode-p 'switchboard-mode)
           (switchboard-agent-by-id (tabulated-list-get-id)))
      (user-error "No session on this line")))

(defun switchboard--agent-at-point-or-read (prompt)
  "Return the agent at point in the list, or read one with PROMPT."
  (if (derived-mode-p 'switchboard-mode)
      (switchboard--agent-at-point)
    (switchboard-read-agent prompt)))

;;;###autoload
(defun switchboard ()
  "List Claude Code background sessions."
  (interactive)
  (let ((buffer (get-buffer-create switchboard-buffer-name)))
    (with-current-buffer buffer
      (unless (derived-mode-p 'switchboard-mode)
        (switchboard-mode))
      (tabulated-list-print t))
    (switchboard-refresh)
    (pop-to-buffer buffer)))

(defun switchboard-toggle-show-all ()
  "Toggle showing sessions hidden by `switchboard-done-retention'."
  (interactive)
  (unless (derived-mode-p 'switchboard-mode)
    (user-error "Not in a Switchboard buffer"))
  (setq switchboard--show-all (not switchboard--show-all))
  (tabulated-list-print t)
  (message "Switchboard: %s" (if switchboard--show-all
                                 "showing all sessions"
                               "showing recent sessions")))

(defun switchboard-acknowledge (&optional all)
  "Acknowledge the finished session at point, turning its lamp off.
With prefix argument ALL, or outside the list buffer, acknowledge every
finished or failed session."
  (interactive "P")
  (if (or all (not (derived-mode-p 'switchboard-mode)))
      (clrhash switchboard--unacknowledged)
    (remhash (switchboard-agent-id (switchboard--agent-at-point))
             switchboard--unacknowledged))
  (switchboard--after-update))

;;;; Transcript

(defvar-local switchboard--transcript-agent nil
  "The agent whose transcript this buffer shows.")

(defvar-local switchboard--transcript-file nil
  "The transcript file this buffer shows.")

(defvar-local switchboard--transcript-bytes nil
  "How many bytes from the end of the transcript this buffer shows.")

(defun switchboard-transcript-file (agent)
  "Return AGENT's transcript file, or nil if there is none.
Transcripts live under `switchboard-projects-directory' in a
subdirectory named after the working directory.  That name is lossy
for non-ASCII paths, so the file is found by session id instead; if
several match, the newest wins.  An id with anything but letters,
digits, `.', `_' and `-' is not looked up: it would be a glob or a
path, not a session."
  (when-let* ((id (switchboard-agent-session-id agent)))
    (when (string-match-p "\\`[A-Za-z0-9._-]+\\'" id)
      (car (sort (file-expand-wildcards
                  (expand-file-name (concat "*/" id ".jsonl")
                                    switchboard-projects-directory)
                  t)
                 #'file-newer-than-file-p)))))

(defun switchboard--transcript-records (file bytes)
  "Parse the records in the last BYTES of FILE.
Return (RECORDS . COMPLETE): RECORDS oldest first, COMPLETE non-nil
when the whole file was read.  The file is JSON Lines and a newline
is the commit boundary: the partial first line of a tail is dropped,
so is a last line that no newline terminates yet, and any other line
that does not parse is skipped."
  (let* ((size (file-attribute-size (file-attributes file)))
         (beg (max 0 (- size bytes)))
         (records nil))
    (with-temp-buffer
      (set-buffer-multibyte nil)
      (insert-file-contents-literally file nil beg size)
      (goto-char (point-min))
      (when (> beg 0)
        (if (search-forward "\n" nil t)
            (delete-region (point-min) (point))
          (erase-buffer)))
      ;; A last line still being written has no newline yet.
      (goto-char (point-max))
      (unless (or (bobp) (eq (char-before) ?\n))
        (delete-region (line-beginning-position) (point-max)))
      (goto-char (point-min))
      (while (not (eobp))
        (let ((line (buffer-substring-no-properties (line-beginning-position)
                                                    (line-end-position))))
          (unless (string-empty-p line)
            (condition-case nil
                (push (json-parse-string (decode-coding-string line 'utf-8)
                                         :object-type 'alist
                                         :array-type 'list
                                         :null-object nil
                                         :false-object nil)
                      records)
              (error nil))))
        (forward-line 1)))
    (cons (nreverse records) (zerop beg))))

(defun switchboard--transcript-blocks-text (content)
  "Return the text of the `text' blocks in CONTENT, or nil if none.
CONTENT is a string or a list of content blocks."
  (cond
   ((stringp content) (and (not (string-blank-p content)) content))
   ((listp content)
    (let ((texts (delq nil (mapcar (lambda (block)
                                     (and (equal (alist-get 'type block) "text")
                                          (alist-get 'text block)))
                                   content))))
      (and texts (string-join texts "\n\n"))))))

(defun switchboard--transcript-tool-summary (block)
  "Return a one-line summary of the `tool_use' BLOCK."
  (let* ((input (alist-get 'input block))
         (detail (seq-some (lambda (key)
                            (let ((value (alist-get key input)))
                              (and (stringp value) (not (string-blank-p value)) value)))
                          '(description command file_path pattern query url prompt skill))))
    (concat "⏺ " (alist-get 'name block)
            (if detail
                (concat ": " (truncate-string-to-width
                              (car (split-string detail "\n")) 80 nil nil "…"))
              ""))))

(defun switchboard--transcript-assistant-text (content)
  "Return the Markdown of an assistant CONTENT, or nil if none.
Text blocks are kept, tool calls become one-line summaries and
thinking is left out."
  (let ((parts (delq nil
                     (mapcar (lambda (block)
                               (pcase (alist-get 'type block)
                                 ("text" (let ((text (alist-get 'text block)))
                                           (and (not (string-blank-p text)) text)))
                                 ("tool_use" (switchboard--transcript-tool-summary block))
                                 (_ nil)))
                             (if (listp content) content nil)))))
    (and parts (string-join parts "\n\n"))))

(defun switchboard--transcript-system-user-p (record)
  "Return non-nil if the user RECORD was written by Claude Code, not typed.
Known markers: `isMeta' for injected messages and `isCompactSummary'
for the summary that replaces a compacted conversation."
  (or (eq (alist-get 'isMeta record) t)
      (eq (alist-get 'isCompactSummary record) t)))

(defun switchboard--transcript-turns (records)
  "Return the conversation in RECORDS as a list of entries, oldest first.
Each turn is (ROLE TIME TEXT) with ROLE `user' or `assistant', TIME
the record's timestamp string and TEXT Markdown.  Tool results and
system-injected messages are left out.  Consecutive records of one
role, which Claude Code writes per content block, are merged."
  (let (turns)
    (dolist (record records)
      (let* ((type (alist-get 'type record))
             (message (alist-get 'message record))
             (content (alist-get 'content message))
             (role (cond ((and (equal type "user")
                               (not (switchboard--transcript-system-user-p record)))
                          'user)
                         ((equal type "assistant") 'assistant)))
             (text (pcase role
                     ('user (switchboard--transcript-blocks-text content))
                     ('assistant (switchboard--transcript-assistant-text content)))))
        (when text
          (if (and turns (eq (car (car turns)) role))
              (setcar (nthcdr 2 (car turns))
                      (concat (nth 2 (car turns)) "\n\n" text))
            (push (list role (alist-get 'timestamp record) text) turns)))))
    (nreverse turns)))

(defun switchboard--transcript-time (timestamp)
  "Format TIMESTAMP, an ISO 8601 string, in local time; nil gives \"\"."
  (if (not timestamp)
      ""
    (condition-case nil
        (format-time-string "%Y-%m-%d %H:%M" (parse-iso8601-time-string timestamp))
      (error timestamp))))

(defun switchboard--transcript-read (file bytes)
  "Read from the end of FILE until `switchboard-transcript-turns' is met.
Start with BYTES and double it until enough turns are found, the file
is exhausted, or `switchboard-transcript-max-bytes' is reached.  A
tail can start in the middle of a reply, so the first turn of an
incomplete read is dropped rather than shown cut off.
Return (TURNS BYTES COMPLETE)."
  (unless (and (integerp bytes) (> bytes 0))
    (user-error "Switchboard: switchboard-transcript-chunk must be a positive integer, not %S"
                bytes))
  (let (result)
    (while (not result)
      (pcase-let* ((`(,records . ,complete) (switchboard--transcript-records file bytes))
                   (turns (switchboard--transcript-turns records)))
        (unless complete
          (setq turns (cdr turns)))
        (if (or complete
                (>= (length turns) (max 0 switchboard-transcript-turns))
                (and switchboard-transcript-max-bytes
                     (>= bytes switchboard-transcript-max-bytes)))
            (setq result (list turns bytes complete))
          ;; Double, but never past the limit; a BYTES already at or
          ;; beyond it (from `+') was accepted above as it is.
          (setq bytes (if switchboard-transcript-max-bytes
                          (min (* 2 bytes) switchboard-transcript-max-bytes)
                        (* 2 bytes))))))
    result))

(defvar-keymap switchboard-transcript-mode-map
  :doc "Keymap of `switchboard-transcript-mode'."
  "g" #'switchboard-transcript-revert
  "+" #'switchboard-transcript-more
  "q" #'quit-window)

(define-minor-mode switchboard-transcript-mode
  "Minor mode of buffers showing a session's conversation.
The major mode is `markdown-mode' when it is installed, `text-mode'
otherwise.  \\<switchboard-transcript-mode-map>\\[switchboard-transcript-revert]
reads the transcript again, \\[switchboard-transcript-more] reads
further back, \\[quit-window] closes the window."
  :lighter " Switchboard"
  :keymap switchboard-transcript-mode-map)

(defun switchboard--transcript-render (buffer agent file bytes)
  "Fill BUFFER with the last BYTES of AGENT's transcript FILE."
  (pcase-let ((`(,turns ,bytes ,complete) (switchboard--transcript-read file bytes)))
    (with-current-buffer buffer
      (unless (memq major-mode '(markdown-mode text-mode))
        (if (fboundp 'markdown-mode) (markdown-mode) (text-mode)))
      (switchboard-transcript-mode 1)
      (setq switchboard--transcript-agent agent
            switchboard--transcript-file file
            switchboard--transcript-bytes bytes)
      (let ((inhibit-read-only t))
        (erase-buffer)
        (insert (format "# %s  (%s)\n\n"
                        (or (switchboard-agent-name agent) "")
                        (switchboard-agent-id agent)))
        (unless complete
          (insert "*Earlier turns not shown: press + to read further back.*\n\n"))
        (if (null turns)
            (insert "*No conversation turns found.*\n")
          (dolist (turn turns)
            (pcase-let ((`(,role ,time ,text) turn))
              (insert (format "## %s  %s\n\n%s\n\n"
                              (if (eq role 'user) "You" "Claude")
                              (switchboard--transcript-time time)
                              text))))))
      (setq buffer-read-only t)
      (goto-char (point-max)))))

(defun switchboard--display-buffer (buffer)
  "Show BUFFER with `switchboard-display-buffer-function'."
  (funcall switchboard-display-buffer-function buffer))

(defun switchboard--transcript-show-tail (buffer)
  "Scroll the window showing BUFFER so that its last line is at the bottom.
The window is the selected one when it shows BUFFER, else the first
window showing it on any frame; other windows are left alone.  The
newest part of a conversation is what matters, and a window that
already showed the buffer keeps its old start when the text is
replaced, which would leave it at the top."
  (when-let* ((window (if (eq (window-buffer) buffer)
                         (selected-window)
                       (get-buffer-window buffer t))))
    (with-selected-window window
      (goto-char (point-max))
      (recenter -1))))

(defun switchboard--transcript-rerender (bytes)
  "Read the transcript shown in this buffer again, BYTES from its end.
Point and the window start of every window showing the buffer keep
their distance from the end, so reading further back with
`switchboard-transcript-more' stays where it was, and a window that
was at the end stays there when `switchboard-transcript-revert' picks
up new turns."
  (let* ((buffer (current-buffer))
         (from-end (- (point-max) (point)))
         (windows (mapcar (lambda (window)
                            (list window
                                  (- (point-max) (window-point window))
                                  (- (point-max) (window-start window))))
                          (get-buffer-window-list buffer nil t))))
    (switchboard--transcript-render buffer switchboard--transcript-agent
                                    switchboard--transcript-file bytes)
    (goto-char (max (point-min) (- (point-max) from-end)))
    (pcase-dolist (`(,window ,point ,start) windows)
      (set-window-point window (max (point-min) (- (point-max) point)))
      (set-window-start window (max (point-min) (- (point-max) start))))))

;;;###autoload
(defun switchboard-transcript (agent)
  "Show the recent part of AGENT's conversation as Markdown.
The transcript is the JSON Lines file Claude Code keeps for the
session; it is read from the end, so large files are cheap, and the
buffer is scrolled to its end.  Works for finished sessions too.  In
the list, AGENT is the session at point; elsewhere it is read with
completion."
  (interactive (list (switchboard--agent-at-point-or-read "Transcript of session: ")))
  (let* ((agent (switchboard--coerce-agent agent))
         (file (or (switchboard-transcript-file agent)
                   (user-error "Switchboard: no transcript found for %s"
                               (or (switchboard-agent-name agent)
                                   (switchboard-agent-id agent)))))
         (buffer (get-buffer-create
                  (format "*switchboard transcript: %s*"
                          (or (switchboard-agent-name agent)
                              (switchboard-agent-id agent))))))
    (switchboard--transcript-render buffer agent file switchboard-transcript-chunk)
    (switchboard--display-buffer buffer)
    (switchboard--transcript-show-tail buffer)))

(defun switchboard-transcript-revert ()
  "Read the transcript shown in this buffer again."
  (interactive)
  (unless switchboard--transcript-agent
    (user-error "Not in a Switchboard transcript buffer"))
  (switchboard--transcript-rerender switchboard--transcript-bytes))

(defun switchboard-transcript-more ()
  "Read twice as far back in the transcript shown in this buffer."
  (interactive)
  (unless switchboard--transcript-agent
    (user-error "Not in a Switchboard transcript buffer"))
  (switchboard--transcript-rerender (* 2 switchboard--transcript-bytes)))

;;;; Choosing a session outside the list

(defun switchboard--ensure-snapshot ()
  "Take a first snapshot if none exists yet, waiting for it.
Interactive commands call this so that they have sessions to offer.
The wait uses the ordinary asynchronous fetch, so it is bounded by
`switchboard-fetch-timeout' and reports errors the same way;
`switchboard-refresh' itself never waits."
  (unless switchboard--initialized
    (switchboard-refresh)
    (while (and (not switchboard--initialized) switchboard--process)
      (accept-process-output nil 0.05))
    (unless switchboard--initialized
      (user-error "Switchboard: %s" (or switchboard--last-error
                                        "could not fetch the session list")))))

(defun switchboard--candidate (agent)
  "Return the completion candidate for AGENT: its id, then its name.
The string carries the face of AGENT's state."
  (propertize (format "%-8s  %s" (switchboard-agent-id agent)
                      (or (switchboard-agent-name agent) ""))
              'face (switchboard--state-face (switchboard-agent-state agent))))

(defun switchboard--candidate-id (candidate)
  "Return the session id at the start of CANDIDATE."
  (car (split-string candidate)))

(defun switchboard--annotate-candidate (candidate)
  "Return the annotation for CANDIDATE: state, directory and age."
  (when-let* ((agent (switchboard-agent-by-id
                     (switchboard--candidate-id candidate))))
    (let ((state (switchboard-agent-state agent)))
      (concat "  "
              (propertize (symbol-name (or state 'unknown))
                          'face (switchboard--state-face state))
              (let ((waiting (switchboard-agent-waiting-for agent)))
                (if waiting (concat " (" waiting ")") ""))
              "  " (switchboard-agent-directory agent)
              "  " (switchboard--format-age (switchboard-agent-age agent))))))

(defun switchboard--coerce-agent (thing)
  "Return the agent THING stands for.
THING is a `switchboard-agent', a session id, or a completion
candidate as returned by `switchboard-read-agent'."
  (cond
   ((switchboard-agent-p thing) thing)
   ((stringp thing)
    (or (switchboard-agent-by-id (switchboard--candidate-id thing))
        (user-error "Switchboard: no session %S" thing)))
   (t (user-error "Switchboard: not a session: %S" thing))))

(defun switchboard--completion-backend ()
  "Return the backend `switchboard-completion-backend' resolves to.
`auto' is consult when the consult package is installed, else
`completing-read'."
  (if (eq switchboard-completion-backend 'auto)
      (if (locate-library "consult") 'consult 'completing-read)
    switchboard-completion-backend))

(defun switchboard--completing-read (prompt agents)
  "Read one of AGENTS with `completing-read', prompting with PROMPT."
  (let* ((candidates (mapcar #'switchboard--candidate agents))
         (table (lambda (string predicate action)
                  (if (eq action 'metadata)
                      `(metadata
                        (category . switchboard-agent)
                        (annotation-function . switchboard--annotate-candidate)
                        (display-sort-function . identity)
                        (cycle-sort-function . identity))
                    (complete-with-action action candidates string predicate)))))
    (switchboard--coerce-agent (completing-read prompt table nil t))))

(defun switchboard-read-agent (prompt &optional all)
  "Read a session with completion, prompting with PROMPT, and return it.
The value is the `switchboard-agent' struct from the current snapshot.
Candidates are the visible sessions, most urgent first; ALL non-nil
offers every session, including those `switchboard-done-retention'
hides.  The completion category is `switchboard-agent', so Embark
actions apply (see `switchboard-embark-map').  With the consult
backend of `switchboard-completion-backend' the sessions are grouped
by state and the highlighted one is previewed."
  (switchboard--ensure-snapshot)
  (let ((agents (switchboard--sort-agents (switchboard--visible-agents all))))
    (unless agents
      (user-error "Switchboard: no sessions to choose from"))
    (pcase (switchboard--completion-backend)
      ('consult (switchboard-consult-read-agent prompt all))
      ('completing-read (switchboard--completing-read prompt agents))
      (other (user-error "Switchboard: unknown completion backend %S" other)))))

;;;; Attach

(defvar-local switchboard--attach-agent nil
  "The agent this terminal buffer is attached to.
Set before the terminal mode starts and kept across the mode change,
so that a process that exits at once still finds it.")
(put 'switchboard--attach-agent 'permanent-local t)

(defvar-local switchboard--attach-process nil
  "The `claude attach' process started in this buffer.
A buffer is only reused while this is still its process, so a buffer
recycled for something else is left alone.")
(put 'switchboard--attach-process 'permanent-local t)

;;;###autoload
(defun switchboard-attach (agent)
  "Attach to AGENT with `switchboard-attach-function'.
The default attach function shows the buffer with
`switchboard-display-buffer-function'.  In the list, AGENT is the
session at point; elsewhere it is read with
completion."
  (interactive (list (switchboard--agent-at-point-or-read "Attach to session: ")))
  (funcall switchboard-attach-function (switchboard--coerce-agent agent)))

(defun switchboard--attach-buffer-name (agent)
  "Return a fresh name for the terminal buffer attached to AGENT.
Another buffer of the same base name, for example one attached to a
different session with the same display name, gets a suffix."
  (generate-new-buffer-name
   (format "*switchboard: %s*"
           (or (switchboard-agent-name agent) (switchboard-agent-id agent)))))

(defun switchboard--attached-buffer (agent)
  "Return the live terminal buffer attached to AGENT's session, or nil.
The match is by session id, not by buffer name."
  (let ((id (switchboard-agent-id agent)))
    (seq-find (lambda (buffer)
                (let ((attached (buffer-local-value 'switchboard--attach-agent buffer))
                      (process (get-buffer-process buffer)))
                  (and attached
                       (equal (switchboard-agent-id attached) id)
                       process
                       (eq process (buffer-local-value 'switchboard--attach-process
                                                       buffer))
                       (process-live-p process))))
              (buffer-list))))

(defun switchboard-attach-in-terminal (agent)
  "Attach to AGENT with `claude attach' in a terminal buffer inside Emacs.
The terminal is chosen by `switchboard-terminal-backend'.  A buffer
already attached to the same session is reused.  Detach with
`Ctrl+Z'; the session keeps running, and the buffer is killed if
`switchboard-kill-buffer-on-exit' is non-nil."
  (let* ((agent (switchboard--coerce-agent agent))
         (program (or (switchboard--program)
                      (user-error "Switchboard: %s not found in `exec-path'"
                                  switchboard-claude-program)))
         (existing (switchboard--attached-buffer agent)))
    (if existing
        (switchboard--display-buffer existing)
      (let ((buffer (switchboard--make-terminal
                     (switchboard--attach-buffer-name agent)
                     (list program "attach" (switchboard-agent-id agent))
                     agent)))
        (when (buffer-live-p buffer)
          (with-current-buffer buffer
            (setq switchboard--attach-agent agent
                  switchboard--attach-process (get-buffer-process buffer))
            (switchboard-attach-mode 1)
            (run-hooks 'switchboard-attach-hook))
          ;; A hook, or the exit of a process that died at once, may
          ;; have killed the buffer meanwhile.
          (when (buffer-live-p buffer)
            (switchboard--display-buffer buffer)))))))

(defun switchboard-send-newline ()
  "Insert a newline in the attached session's prompt, like Shift+Return.
Sends only to the `claude attach' process this buffer was created for;
a buffer recycled for another process gets a `user-error'."
  (interactive)
  (let ((process switchboard--attach-process))
    (unless (and (process-live-p process)
                 (eq process (get-buffer-process (current-buffer))))
      (user-error "Switchboard: this buffer is no longer attached to a session"))
    (if (derived-mode-p 'ghostel-mode)
        ;; ghostel encodes keys itself (Kitty keyboard protocol when
        ;; the application asked for it, CSI u otherwise).
        (ghostel-send-key "return" "shift")
      (process-send-string process switchboard-newline-sequence))))

(defvar-keymap switchboard-attach-mode-map
  :doc "Keymap of `switchboard-attach-mode'."
  "S-<return>" #'switchboard-send-newline)

(define-minor-mode switchboard-attach-mode
  "Minor mode of terminal buffers attached to a Claude Code session.
\\<switchboard-attach-mode-map>\\[switchboard-send-newline] inserts a
newline in the prompt, which the terminal emulator cannot send itself."
  :lighter " Switchboard"
  :keymap switchboard-attach-mode-map)

(defun switchboard--terminal-backend ()
  "Return the backend `switchboard-terminal-backend' resolves to.
`auto' is ghostel, then vterm, then eat.  vterm counts only when its
native module is built too; loading vterm without the module prompts
to compile it, which must not happen in the middle of an attach."
  (if (eq switchboard-terminal-backend 'auto)
      (cond
       ((locate-library "ghostel") 'ghostel)
       ((and (locate-library "vterm") (locate-library "vterm-module")) 'vterm)
       (t 'eat))
    switchboard-terminal-backend))

(defun switchboard--make-terminal (name command &optional agent)
  "Return a terminal buffer called NAME running COMMAND, a list of strings.
Dispatches on `switchboard-terminal-backend'.  AGENT, when given, is
recorded in the buffer before the process starts."
  (pcase (switchboard--terminal-backend)
    ('eat (switchboard--make-eat-terminal name command agent))
    ('vterm (switchboard--make-vterm-terminal name command agent))
    ('ghostel (switchboard--make-ghostel-terminal name command agent))
    ((and (pred functionp) backend) (funcall backend name command))
    (other (user-error "Switchboard: unknown terminal backend %S" other))))

(defun switchboard--make-eat-terminal (name command &optional agent)
  "Return an eat buffer called NAME running COMMAND, attached to AGENT."
  (unless (require 'eat nil t)
    (user-error "Switchboard: the eat package is not installed"))
  (let ((buffer (get-buffer-create name)))
    (with-current-buffer buffer
      (setq switchboard--attach-agent agent)
      (unless (derived-mode-p 'eat-mode)
        (eat-mode))
      (setq-local eat-kill-buffer-on-exit switchboard-kill-buffer-on-exit)
      (eat-exec buffer name (car command) nil (cdr command)))
    buffer))

(defun switchboard--make-ghostel-terminal (name command &optional agent)
  "Return a ghostel buffer called NAME running COMMAND, attached to AGENT.
`ghostel-exec' runs the command directly, without a shell.  The
buffer is sized to 80x24 until it is displayed, then follows its
window."
  (unless (require 'ghostel nil t)
    (user-error "Switchboard: the ghostel package is not installed"))
  (let ((buffer (get-buffer-create name)))
    (with-current-buffer buffer
      (setq switchboard--attach-agent agent)
      (ghostel-exec buffer (car command) (cdr command))
      ;; After `ghostel-exec': it sets the major mode, which resets
      ;; buffer-local variables.
      (setq-local ghostel-kill-buffer-on-exit switchboard-kill-buffer-on-exit))
    buffer))

(defun switchboard--make-vterm-terminal (name command &optional agent)
  "Return a vterm buffer called NAME running COMMAND, attached to AGENT.
vterm starts `vterm-shell' through /bin/sh -c \"... && exec ...\", so
the command is quoted for the shell and the shell replaces itself with
`claude'; no shell stays between Emacs and the session."
  (unless (require 'vterm nil t)
    (user-error "Switchboard: the vterm package is not installed"))
  (let ((buffer (get-buffer-create name)))
    (with-current-buffer buffer
      (setq switchboard--attach-agent agent)
      (let ((vterm-shell (mapconcat #'shell-quote-argument command " "))
            (vterm-kill-buffer-on-exit switchboard-kill-buffer-on-exit))
        (vterm-mode))
      (when (buffer-live-p buffer)
        (setq-local vterm-kill-buffer-on-exit switchboard-kill-buffer-on-exit)))
    buffer))

;;;; Dispatch and lifecycle

(defun switchboard--strip-escapes (raw)
  "Strip ANSI escape sequences and CR characters from RAW."
  (replace-regexp-in-string
   (rx (or (seq "\e[" (* (in "0-9;?")) (* (in " -/")) (in "@-~"))
           (seq "\e]" (* (not (in "\a"))) "\a")
           (seq "\e" (in "()") (in "A-Z0-9"))
           (seq "\e" (in "=>"))
           "\r"))
   "" raw t t))

(defun switchboard--run-claude (args on-done)
  "Run the Claude CLI with ARGS and call ON-DONE with (STATUS OUTPUT).
OUTPUT is stdout and stderr with escape sequences stripped.  A start
failure does not signal; it is delivered synchronously as STATUS
`error' with the message as OUTPUT."
  (let ((program (switchboard--program))
        (stdout (generate-new-buffer " *switchboard-claude*"))
        (process nil))
    (if (not program)
        (progn
          (kill-buffer stdout)
          (funcall on-done 'error
                   (format "%s not found in `exec-path'" switchboard-claude-program)))
      (condition-case err
          (setq process
                (make-process
                 :name "switchboard-claude"
                 :buffer stdout
                 :command (cons program args)
                 :connection-type 'pipe
                 :coding 'utf-8-unix
                 :noquery t
                 :sentinel
                 (lambda (process _event)
                   (when (memq (process-status process) '(exit signal))
                     (let ((output (string-trim
                                    (switchboard--strip-escapes
                                     (switchboard--buffer-string stdout)))))
                       (when (buffer-live-p stdout) (kill-buffer stdout))
                       (funcall on-done (process-exit-status process) output))))))
        (error
         (when (buffer-live-p stdout) (kill-buffer stdout))
         (funcall on-done 'error (error-message-string err))))
      (when process
        (ignore-errors (process-send-eof process))))))

(defun switchboard--default-directory ()
  "Return the directory a new session should start in."
  (or (when-let* ((project (and (fboundp 'project-current) (project-current))))
        (project-root project))
      default-directory))

(defun switchboard--output-id (output)
  "Return the first session id in OUTPUT of `claude --bg', or nil."
  (when (string-match "\\_<\\([0-9a-f]\\{8\\}\\)\\_>" output)
    (match-string 1 output)))

;;;###autoload
(defun switchboard-dispatch (prompt &optional directory name)
  "Start a new background session with PROMPT in DIRECTORY.
DIRECTORY defaults to the current project root, or the current
directory; with a prefix argument it is read.  NAME, when non-nil,
is the session's display name.  Runs `claude --bg' and refreshes
when it returns."
  (interactive
   (list (read-string "Dispatch to Claude: ")
         (if current-prefix-arg
             (read-directory-name "In directory: " nil nil t)
           (switchboard--default-directory))
         nil))
  (when (string-blank-p prompt)
    (user-error "Switchboard: the prompt is empty"))
  ;; `default-directory' is dynamically bound, so the callback below
  ;; must capture the directory in a lexical variable of its own.
  (let* ((directory (file-name-as-directory
                     (expand-file-name (or directory default-directory))))
         (default-directory directory)
         (label (abbreviate-file-name directory)))
    (message "Switchboard: dispatching in %s..." label)
    ;; "--" keeps a prompt that starts with "-" from being read as an
    ;; option (verified against Claude Code 2.1.274).
    (switchboard--run-claude
     (append (list "--bg") (and name (list "--name" name)) (list "--" prompt))
     (lambda (status output)
       (if (eql status 0)
           (progn
             (message "Switchboard: dispatched %s in %s"
                      (or (switchboard--output-id output) "a session") label)
             (switchboard-refresh))
         (message "Switchboard: dispatch failed (%s): %s" status output))))
    nil))

(defun switchboard--existing-cwd (agent)
  "Return AGENT's working directory, or signal a user error if it is gone."
  (let ((directory (switchboard-agent-cwd agent)))
    (unless (and directory (file-directory-p directory))
      (user-error "Switchboard: the working directory of %s is gone"
                  (or (switchboard-agent-name agent) (switchboard-agent-id agent))))
    directory))

;;;###autoload
(defun switchboard-dispatch-here (agent)
  "Start a new background session in AGENT's working directory.
The prompt is read as for `switchboard-dispatch'.  Use it to hand a
second task to the project a session already works in.  In the list,
AGENT is the session at point; elsewhere it is read with completion."
  (interactive
   (list (switchboard--agent-at-point-or-read "Dispatch alongside session: ")))
  (let* ((agent (switchboard--coerce-agent agent))
         (directory (switchboard--existing-cwd agent)))
    (switchboard-dispatch
     (read-string (format "Dispatch to Claude in %s: "
                          (abbreviate-file-name directory)))
     directory)))

;;;###autoload
(defun switchboard-dired (agent)
  "Open AGENT's working directory in Dired.
In the list, AGENT is the session at point; elsewhere it is read with
completion."
  (interactive (list (switchboard--agent-at-point-or-read "Directory of session: ")))
  (dired (switchboard--existing-cwd (switchboard--coerce-agent agent))))

;;;###autoload
(defun switchboard-copy-id (agent &optional full)
  "Copy AGENT's short id, the one `claude attach' takes, to the kill ring.
With prefix argument FULL, copy the full session id instead.  In the
list, AGENT is the session at point; elsewhere it is read with
completion."
  (interactive (list (switchboard--agent-at-point-or-read "Copy id of session: ")
                     current-prefix-arg))
  (let* ((agent (switchboard--coerce-agent agent))
         (id (or (if full
                     (switchboard-agent-session-id agent)
                   (switchboard-agent-id agent))
                 (user-error "Switchboard: session %s has no %s"
                             (or (switchboard-agent-name agent) "")
                             (if full "session id" "id")))))
    (kill-new id)
    (message "Switchboard: copied %s" id)))

(defun switchboard--lifecycle (verb agent)
  "Run `claude VERB ID' for AGENT, then refresh."
  (let* ((agent (switchboard--coerce-agent agent))
         (id (switchboard-agent-id agent))
         (label (or (switchboard-agent-name agent) id)))
    (message "Switchboard: %s %s..." verb label)
    (switchboard--run-claude
     (list verb id)
     (lambda (status output)
       (if (eql status 0)
           (message "Switchboard: %s %s%s" verb label
                    (if (string-empty-p output) "" (concat ": " output)))
         (message "Switchboard: %s %s failed (%s): %s" verb label status output))
       (switchboard-refresh)))))

;;;###autoload
(defun switchboard-stop (agent)
  "Stop AGENT's session with `claude stop'."
  (interactive (list (switchboard--agent-at-point-or-read "Stop session: ")))
  (switchboard--lifecycle "stop" agent))

;;;###autoload
(defun switchboard-respawn (agent)
  "Start AGENT's stopped or failed session again with `claude respawn'."
  (interactive (list (switchboard--agent-at-point-or-read "Respawn session: ")))
  (switchboard--lifecycle "respawn" agent))

;;;###autoload
(defun switchboard-remove (agent)
  "Delete AGENT's session with `claude rm', after confirmation."
  (interactive (list (switchboard--agent-at-point-or-read "Remove session: ")))
  (let ((agent (switchboard--coerce-agent agent)))
    (when (yes-or-no-p (format "Remove session %s (%s)? "
                               (or (switchboard-agent-name agent) "")
                               (switchboard-agent-id agent)))
      (switchboard--lifecycle "rm" agent))))

;;;; Embark

;; Embark is optional.  `switchboard-embark-setup' registers the action
;; map for the `switchboard-agent' completion category and a target
;; finder, so that the session at point in the list, in a transcript
;; buffer or in an attached buffer is a target too.

(defvar-keymap switchboard-embark-map
  :doc "Embark actions on a session.
The target is a completion candidate of `switchboard-read-agent', the
line at point in the list, or the session a transcript or attached
buffer shows.  RET is the default action outside the minibuffer."
  "RET" #'switchboard-attach
  "a" #'switchboard-attach
  "l" #'switchboard-transcript
  "d" #'switchboard-dispatch-here
  "j" #'switchboard-dired
  "w" #'switchboard-copy-id
  "s" #'switchboard-stop
  "k" #'switchboard-remove)

(defun switchboard-embark-target ()
  "Return the session at point as an Embark target, or nil.
In the list it is the session on the current line, with the line as
its bounds; in a transcript or attached buffer it is the session the
buffer shows, unless a region is active there.  The target is the
completion candidate string, which every command in
`switchboard-embark-map' accepts."
  (cond
   ((derived-mode-p 'switchboard-mode)
    (when-let* ((agent (switchboard-agent-by-id (tabulated-list-get-id))))
      `(switchboard-agent ,(switchboard--candidate agent)
                          ,(line-beginning-position) . ,(line-end-position))))
   ;; In a transcript or attached buffer an active region is the
   ;; user's own target; the session comes first only otherwise.
   ((and (not (use-region-p))
         (or switchboard--transcript-agent switchboard--attach-agent))
    (cons 'switchboard-agent
          (switchboard--candidate (or switchboard--transcript-agent
                                      switchboard--attach-agent))))))

(defun switchboard-embark-setup ()
  "Register Switchboard's Embark integration.
`switchboard-embark-map', with `embark-general-map' behind it, becomes
the action map of `switchboard-agent' targets, and
`switchboard-embark-target' finds the session at point.  Call it once
Embark is loaded, for example with
\(with-eval-after-load \\='embark (switchboard-embark-setup))."
  (unless (require 'embark nil t)
    (user-error "Switchboard: the embark package is not installed"))
  (setf (alist-get 'switchboard-agent embark-keymap-alist)
        '(switchboard-embark-map embark-general-map))
  (add-hook 'embark-target-finders #'switchboard-embark-target))

;;;; Hook setup

(defun switchboard-hook-script ()
  "Return the absolute path of the bundled switchboard-hook script.
It is looked for in bin/ next to the library, then next to the
library itself, which is where a package build that flattens the
tree puts it."
  (let* ((library (or (locate-library "switchboard")
                      (error "Switchboard: cannot locate the switchboard library")))
         (directory (file-name-directory library))
         (candidates (list (expand-file-name "bin/switchboard-hook" directory)
                           (expand-file-name "switchboard-hook" directory))))
    (or (seq-find #'file-regular-p candidates)
        (error "Switchboard: switchboard-hook is not installed next to %s" library))))

;;;###autoload
(defun switchboard-hook-settings ()
  "Show the Claude Code hook settings that make Switchboard refresh instantly.
The JSON is an object with one \"hooks\" member, to be merged into the
top level of ~/.claude/settings.json: if \"Stop\" or \"Notification\"
already exist there, append the entry to those arrays instead of
replacing them.  The JSON is also copied to the kill ring."
  (interactive)
  (require 'json)
  (let* ((command (concat "bash " (shell-quote-argument (switchboard-hook-script))))
         (entry (vector `((matcher . "")
                          (hooks . ,(vector `((type . "command")
                                              (command . ,command)))))))
         (json (let ((json-encoding-pretty-print t)
                     (json-encoding-default-indentation "  "))
                 (json-encode `((hooks . ((Stop . ,entry)
                                          (Notification . ,entry))))))))
    (kill-new json)
    (with-current-buffer (get-buffer-create "*switchboard hook settings*")
      (let ((inhibit-read-only t))
        (erase-buffer)
        (insert ";; Merge the \"hooks\" member below into the top level of\n"
                ";; ~/.claude/settings.json.  If \"Stop\" or \"Notification\" already\n"
                ";; exist, append the entry to those arrays.  Copied to the kill ring.\n"
                ";; The script only nudges Emacs to refresh and always exits 0.\n\n"
                json "\n"))
      (special-mode)
      (pop-to-buffer (current-buffer)))))

(provide 'switchboard)
;;; switchboard.el ends here
