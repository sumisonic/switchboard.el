;;; switchboard-test.el --- Tests for switchboard -*- lexical-binding: t; -*-

;;; Commentary:

;; Run with:
;;   emacs -Q --batch -L . -l switchboard.el -l test/switchboard-test.el \
;;     -f ert-run-tests-batch-and-exit

;;; Code:

(require 'ert)
(require 'switchboard)

;;;; Fixtures

(defconst switchboard-test--json
  (concat
   "["
   "{\"id\":\"1eefb60f\",\"cwd\":\"/home/me/proj\",\"kind\":\"background\","
   "\"startedAt\":1783737078185,"
   "\"sessionId\":\"1eefb60f-a9e1-4ab7-96fc-e3b37a7ba016\","
   "\"name\":\"first\",\"state\":\"done\"},"
   "{\"pid\":2069,\"id\":\"2f82c2f8\",\"cwd\":\"/home/me/other\","
   "\"kind\":\"background\",\"startedAt\":1789640397995,"
   "\"sessionId\":\"2f82c2f8-6d46-4dba-aff5-beec913be026\","
   "\"name\":\"second\",\"status\":\"waiting\","
   "\"waitingFor\":\"permission prompt\",\"state\":\"blocked\"}"
   "]")
  "Two records in the shape `claude agents --json --all' prints.
The first is a finished session whose process has exited (no pid,
status or waitingFor); the second is alive and waiting on a
permission prompt.")

(defun switchboard-test--agent (id state &rest props)
  "Make an agent ID in STATE; PROPS override other slots.
Defaults to a process that is alive and a start time of now.  PROPS
come first because the first occurrence of a keyword wins."
  (apply #'switchboard--agent-create
         (append props
                 (list :id id
                       :session-id (concat id "-0000-0000")
                       :name (concat "job " id)
                       :cwd (concat "/home/me/" id)
                       :kind 'background
                       :state state
                       :pid 1
                       :started-at (floor (* 1000 (float-time)))))))

(defmacro switchboard-test--with-clean-state (&rest body)
  "Run BODY with fresh Switchboard state and no user hooks or echo."
  (declare (indent 0))
  `(let ((switchboard-state-change-functions nil)
         (switchboard-echo-transitions nil)
         (switchboard-notify-states '(blocked done failed))
         (switchboard-done-retention (* 24 60 60))
         (switchboard-buffer-name " *switchboard-test*"))
     (switchboard--reset)
     (unwind-protect
         (progn ,@body)
       (switchboard--reset))))

(defun switchboard-test--record-hook (log)
  "Return a hook function pushing (ID OLD NEW) onto the list in LOG.
LOG is a cons cell whose car holds the list."
  (lambda (agent old new)
    (push (list (switchboard-agent-id agent) old new) (car log))))

(defconst switchboard-test--fake-claude
  (expand-file-name "fake-claude.sh"
                    (file-name-directory (or load-file-name buffer-file-name)))
  "Path of the stand-in `claude' script.")

(defun switchboard-test--wait-for-fetch (&optional seconds)
  "Pump process output until no fetch is in flight, at most SECONDS."
  (let ((deadline (+ (float-time) (or seconds 5))))
    (while (and switchboard--process (< (float-time) deadline))
      (accept-process-output nil 0.05))
    (null switchboard--process)))

(defmacro switchboard-test--with-fake-claude (env &rest body)
  "Run BODY with the fake `claude' and the environment variables in ENV.
ENV is a list of \"NAME=VALUE\" strings."
  (declare (indent 1))
  `(let ((switchboard-claude-program switchboard-test--fake-claude)
         (process-environment (append ,env process-environment)))
     ,@body))

;;;; Parsing

(ert-deftest switchboard-parse-agents ()
  "Every field of both records lands in the struct, absent ones as nil."
  (let ((agents (switchboard--parse-agents switchboard-test--json)))
    (should (= (length agents) 2))
    (let ((a (nth 0 agents))
          (b (nth 1 agents)))
      (should (equal (switchboard-agent-id a) "1eefb60f"))
      (should (equal (switchboard-agent-session-id a)
                     "1eefb60f-a9e1-4ab7-96fc-e3b37a7ba016"))
      (should (equal (switchboard-agent-name a) "first"))
      (should (equal (switchboard-agent-cwd a) "/home/me/proj"))
      (should (eq (switchboard-agent-kind a) 'background))
      (should (eq (switchboard-agent-state a) 'done))
      (should (null (switchboard-agent-status a)))
      (should (null (switchboard-agent-waiting-for a)))
      (should (null (switchboard-agent-pid a)))
      (should-not (switchboard-agent-alive-p a))
      (should (= (switchboard-agent-started-at a) 1783737078185))
      (should (eq (switchboard-agent-state b) 'blocked))
      (should (eq (switchboard-agent-status b) 'waiting))
      (should (equal (switchboard-agent-waiting-for b) "permission prompt"))
      (should (= (switchboard-agent-pid b) 2069))
      (should (switchboard-agent-alive-p b))
      (should (equal (switchboard-agent-directory b) "other")))))

(ert-deftest switchboard-parse-agents-empty ()
  "An empty array parses to nil."
  (should (null (switchboard--parse-agents "[]"))))

(ert-deftest switchboard-id-is-session-id-prefix ()
  "The short id is the first 8 characters of the session id.
This is what lets a hook's session_id be mapped to a row."
  (dolist (a (switchboard--parse-agents switchboard-test--json))
    (should (string-prefix-p (switchboard-agent-id a)
                             (switchboard-agent-session-id a)))))

;;;; Diff engine

(ert-deftest switchboard-first-snapshot-never-notifies ()
  "Sessions already blocked at startup light the lamp but run no hook."
  (switchboard-test--with-clean-state
    (let ((log (list nil)))
      (add-hook 'switchboard-state-change-functions
                (switchboard-test--record-hook log))
      (switchboard--apply-snapshot
       (list (switchboard-test--agent "a" 'blocked)
             (switchboard-test--agent "b" 'done)))
      (should switchboard--initialized)
      (should (null (car log)))
      (should (equal (switchboard--lamp-counts) '(1 0 0)))
      (should (= (hash-table-count switchboard--unacknowledged) 0)))))

(ert-deftest switchboard-transition-runs-hook-once ()
  "working -> blocked runs the hook once; the same state again does not."
  (switchboard-test--with-clean-state
    (let ((log (list nil)))
      (add-hook 'switchboard-state-change-functions
                (switchboard-test--record-hook log))
      (switchboard--apply-snapshot (list (switchboard-test--agent "a" 'working)))
      (switchboard--apply-snapshot (list (switchboard-test--agent "a" 'blocked)))
      (should (equal (car log) '(("a" working blocked))))
      (switchboard--apply-snapshot (list (switchboard-test--agent "a" 'blocked)))
      (should (equal (car log) '(("a" working blocked)))))))

(ert-deftest switchboard-new-session-counts-as-transition ()
  "A session that appears already blocked runs the hook with OLD nil."
  (switchboard-test--with-clean-state
    (let ((log (list nil)))
      (add-hook 'switchboard-state-change-functions
                (switchboard-test--record-hook log))
      (switchboard--apply-snapshot (list (switchboard-test--agent "a" 'working)))
      (switchboard--apply-snapshot (list (switchboard-test--agent "a" 'working)
                                         (switchboard-test--agent "b" 'blocked)))
      (should (equal (car log) '(("b" nil blocked)))))))

(ert-deftest switchboard-non-notify-state-runs-no-hook ()
  "blocked -> working is a transition but not a notification."
  (switchboard-test--with-clean-state
    (let ((log (list nil)))
      (add-hook 'switchboard-state-change-functions
                (switchboard-test--record-hook log))
      (switchboard--apply-snapshot (list (switchboard-test--agent "a" 'blocked)))
      (switchboard--apply-snapshot (list (switchboard-test--agent "a" 'working)))
      (should (null (car log)))
      (should (gethash "a" switchboard--transitioned)))))

(ert-deftest switchboard-done-is-unacknowledged-until-acknowledged ()
  "done lights the lamp until acknowledged or until the session works again."
  (switchboard-test--with-clean-state
    (switchboard--apply-snapshot (list (switchboard-test--agent "a" 'working)
                                       (switchboard-test--agent "b" 'working)))
    (switchboard--apply-snapshot (list (switchboard-test--agent "a" 'done)
                                       (switchboard-test--agent "b" 'failed)))
    (should (equal (switchboard--lamp-counts) '(0 1 1)))
    (should (string-match-p "✓1 ✗1" (switchboard--mode-line-string)))
    (switchboard-acknowledge t)
    (should (equal (switchboard--lamp-counts) '(0 0 0)))
    (should (equal (switchboard--mode-line-string) ""))
    (switchboard--apply-snapshot (list (switchboard-test--agent "a" 'working)
                                       (switchboard-test--agent "b" 'done)))
    (should (equal (switchboard--lamp-counts) '(0 1 0)))
    (switchboard--apply-snapshot (list (switchboard-test--agent "a" 'working)
                                       (switchboard-test--agent "b" 'working)))
    (should (equal (switchboard--lamp-counts) '(0 0 0)))))

(ert-deftest switchboard-removed-session-is-forgotten ()
  "A session that disappears loses its marks."
  (switchboard-test--with-clean-state
    (switchboard--apply-snapshot (list (switchboard-test--agent "a" 'working)))
    (switchboard--apply-snapshot (list (switchboard-test--agent "a" 'done)))
    (should (gethash "a" switchboard--unacknowledged))
    (switchboard--apply-snapshot nil)
    (should (null (gethash "a" switchboard--unacknowledged)))
    (should (null (gethash "a" switchboard--transitioned)))
    (should (null switchboard--agents))))

(ert-deftest switchboard-hook-error-does-not-stop-others ()
  "An error in one hook function is reported; the next one still runs."
  (switchboard-test--with-clean-state
    (let ((log (list nil)))
      (add-hook 'switchboard-state-change-functions
                (lambda (&rest _) (error "Boom")))
      (add-hook 'switchboard-state-change-functions
                (switchboard-test--record-hook log)
                t)
      (switchboard--apply-snapshot (list (switchboard-test--agent "a" 'working)))
      (switchboard--apply-snapshot (list (switchboard-test--agent "a" 'failed)))
      (should (equal (car log) '(("a" working failed))))
      (should switchboard--initialized))))

;;;; Visibility and ordering

(ert-deftest switchboard-retention-hides-old-finished-sessions ()
  "Old done sessions and old exited-blocked ones are hidden.
Working, live blocked or failed, recent and transitioned ones stay."
  (switchboard-test--with-clean-state
    (let ((old (- (floor (* 1000 (float-time))) (* 1000 60 60 48))))
      (switchboard--apply-snapshot
       (list (switchboard-test--agent "old-done" 'done :started-at old :pid nil)
             (switchboard-test--agent "old-working" 'working :started-at old)
             (switchboard-test--agent "old-blocked-exited" 'blocked
                                      :started-at old :pid nil)
             (switchboard-test--agent "old-blocked-live" 'blocked :started-at old)
             (switchboard-test--agent "old-failed-live" 'failed :started-at old)
             (switchboard-test--agent "old-failed-exited" 'failed
                                      :started-at old :pid nil)
             (switchboard-test--agent "recent-done" 'done :pid nil)))
      (should (equal (mapcar #'switchboard-agent-id (switchboard--visible-agents))
                     '("old-working" "old-blocked-live" "old-failed-live"
                       "recent-done")))
      (should (= (length (switchboard--visible-agents t)) 7))
      ;; Only the live blocked session lights the lamp.
      (should (equal (switchboard--lamp-counts) '(1 0 0)))
      ;; Once a hidden session changes state it is visible again.
      (switchboard--apply-snapshot
       (list (switchboard-test--agent "old-done" 'working :started-at old)))
      (should (equal (mapcar #'switchboard-agent-id (switchboard--visible-agents))
                     '("old-done")))
      (let ((switchboard-done-retention nil))
        (switchboard--apply-snapshot
         (list (switchboard-test--agent "x" 'done :started-at old :pid nil)))
        (should (= (length (switchboard--visible-agents)) 1))))))

(ert-deftest switchboard-sort-order ()
  "Live blocked, failed, exited blocked, working, done, stopped; newest first."
  (let* ((now (floor (* 1000 (float-time))))
         (agents (list (switchboard-test--agent "stopped" 'stopped)
                       (switchboard-test--agent "done" 'done)
                       (switchboard-test--agent "working-old" 'working
                                                :started-at (- now 5000))
                       (switchboard-test--agent "working-new" 'working
                                                :started-at now)
                       (switchboard-test--agent "blocked-exited" 'blocked :pid nil)
                       (switchboard-test--agent "failed" 'failed)
                       (switchboard-test--agent "blocked-live" 'blocked))))
    (should (equal (mapcar #'switchboard-agent-id (switchboard--sort-agents agents))
                   '("blocked-live" "failed" "blocked-exited"
                     "working-new" "working-old" "done" "stopped")))))

(ert-deftest switchboard-list-entry-marks-and-columns ()
  "The first column carries the lamp glyph; waiting shows waitingFor or exited."
  (switchboard-test--with-clean-state
    (switchboard--apply-snapshot
     (list (switchboard-test--agent "live" 'blocked :waiting-for "input needed")
           (switchboard-test--agent "gone" 'blocked :pid nil)
           (switchboard-test--agent "busy" 'working)))
    (let ((rows (mapcar (lambda (e) (cons (car e) (append (cadr e) nil)))
                        (switchboard--list-entries))))
      (should (equal (assoc-default "live" rows)
                     '("!" "blocked" "input needed" "live" "job live" "live" "now")))
      (should (equal (nth 2 (assoc-default "gone" rows)) "exited"))
      (should (equal (nth 0 (assoc-default "busy" rows)) ""))
      (should (equal (nth 1 (assoc-default "busy" rows)) "working"))
      (should (equal (nth 2 (assoc-default "busy" rows)) "")))))

(ert-deftest switchboard-format-age ()
  "Ages are short and coarse."
  (should (equal (switchboard--format-age nil) ""))
  (should (equal (switchboard--format-age 5) "now"))
  (should (equal (switchboard--format-age 125) "2m"))
  (should (equal (switchboard--format-age 7300) "2h"))
  (should (equal (switchboard--format-age (* 3 86400)) "3d")))

;;;; Polling interval

(ert-deftest switchboard-poll-interval-slows-down-when-idle ()
  "With no live process the idle interval applies; nil disables polling."
  (switchboard-test--with-clean-state
    (let ((switchboard-poll-interval 5)
          (switchboard-idle-poll-interval 30))
      (should (= (switchboard--current-interval) 5))
      (switchboard--apply-snapshot (list (switchboard-test--agent "a" 'done :pid nil)))
      (should (= (switchboard--current-interval) 30))
      (switchboard--apply-snapshot (list (switchboard-test--agent "a" 'working)))
      (should (= (switchboard--current-interval) 5))
      (let ((switchboard-idle-poll-interval nil))
        (switchboard--apply-snapshot (list (switchboard-test--agent "a" 'done :pid nil)))
        (should (= (switchboard--current-interval) 5)))
      (let ((switchboard-poll-interval nil))
        (should (null (switchboard--current-interval)))))))

;;;; Fetch slot, re-entrancy and error containment

(ert-deftest switchboard-refresh-coalesces-while-in-flight ()
  "Refreshes during a fetch queue exactly one more; ownership is respected."
  (switchboard-test--with-clean-state
    (let ((starts 0))
      (cl-letf (((symbol-function 'switchboard--start-fetch)
                 (lambda () (cl-incf starts) (setq switchboard--process 'fake))))
        (setq switchboard--process nil switchboard--refresh-pending nil)
        (switchboard-refresh)
        (should (= starts 1))
        (switchboard-refresh)
        (switchboard-refresh)
        (should (= starts 1))
        (should switchboard--refresh-pending)
        ;; A stranger's completion does not release the slot.
        (switchboard--fetch-done 'other)
        (should (eq switchboard--process 'fake))
        (should (= starts 1))
        ;; The owner's completion does, and runs the queued refresh once.
        (switchboard--fetch-done 'fake)
        (should (= starts 2))
        (should-not switchboard--refresh-pending)
        (switchboard--fetch-done 'fake)
        (should (= starts 2))
        (setq switchboard--process nil)))))

(ert-deftest switchboard-hook-script-is-found-in-bin-or-flattened ()
  "The hook script is found under bin/ or, after a flattening package build, next to the library."
  (let ((root (make-temp-file "switchboard-pkg" t)))
    (unwind-protect
        (cl-letf (((symbol-function 'locate-library)
                   (lambda (&rest _) (expand-file-name "switchboard.el" root))))
          (should-error (switchboard-hook-script))
          ;; A directory of that name does not count.
          (make-directory (expand-file-name "switchboard-hook" root))
          (should-error (switchboard-hook-script))
          (delete-directory (expand-file-name "switchboard-hook" root))
          (with-temp-file (expand-file-name "switchboard-hook" root) (insert "#!/bin/sh\n"))
          (should (equal (switchboard-hook-script) (expand-file-name "switchboard-hook" root)))
          (make-directory (expand-file-name "bin" root))
          (with-temp-file (expand-file-name "bin/switchboard-hook" root) (insert "#!/bin/sh\n"))
          (should (equal (switchboard-hook-script) (expand-file-name "bin/switchboard-hook" root))))
      (delete-directory root t))))

(ert-deftest switchboard-hook-may-call-refresh ()
  "A hook that calls `switchboard-refresh' while the slot is held queues it."
  (switchboard-test--with-clean-state
    (let ((starts 0))
      (cl-letf (((symbol-function 'switchboard--start-fetch)
                 (lambda () (cl-incf starts) (setq switchboard--process 'fake))))
        (add-hook 'switchboard-state-change-functions
                  (lambda (&rest _) (switchboard-refresh)))
        (setq switchboard--process 'fake switchboard--refresh-pending nil)
        (switchboard--apply-snapshot (list (switchboard-test--agent "a" 'working)))
        (switchboard--apply-snapshot (list (switchboard-test--agent "a" 'blocked)))
        (should (= starts 0))
        (should switchboard--refresh-pending)
        (switchboard--fetch-done 'fake)
        (should (= starts 1))
        (setq switchboard--process nil)))))

(ert-deftest switchboard-refresh-never-signals ()
  "An error while starting a fetch is reported, not raised."
  (switchboard-test--with-clean-state
    (cl-letf (((symbol-function 'switchboard--start-fetch)
               (lambda () (error "Boom"))))
      (setq switchboard--process nil)
      (should (null (switchboard-refresh)))
      (should (string-match-p "Boom" switchboard--last-error)))))

(ert-deftest switchboard-fetch-end-to-end-with-fake-claude ()
  "The real process path parses stdout, joins stderr and reports failures."
  (switchboard-test--with-clean-state
    (switchboard-test--with-fake-claude
        (list (concat "FAKE_CLAUDE_JSON=" switchboard-test--json))
      (switchboard-refresh)
      (should switchboard--process)
      (should (switchboard-test--wait-for-fetch))
      (should switchboard--initialized)
      (should (null switchboard--last-error))
      (should (equal (mapcar #'switchboard-agent-id switchboard--agents)
                     '("1eefb60f" "2f82c2f8"))))
    ;; Non-zero exit with text on stderr: the error carries the text.
    (switchboard-test--with-fake-claude
        '("FAKE_CLAUDE_EXIT=3" "FAKE_CLAUDE_STDERR=supervisor is down")
      (switchboard-refresh)
      (should (switchboard-test--wait-for-fetch))
      (should (string-match-p "exited with 3" switchboard--last-error))
      (should (string-match-p "supervisor is down" switchboard--last-error))
      ;; The previous snapshot survives a failed fetch.
      (should (= (length switchboard--agents) 2)))
    ;; Garbage on stdout is a parse error, also reported.
    (switchboard-test--with-fake-claude '("FAKE_CLAUDE_JSON=not json")
      (switchboard-refresh)
      (should (switchboard-test--wait-for-fetch))
      (should (string-match-p "could not parse" switchboard--last-error)))
    ;; A refresh during a slow fetch runs once more afterwards.
    (switchboard-test--with-fake-claude '("FAKE_CLAUDE_DELAY=0.3" "FAKE_CLAUDE_JSON=[]")
      (switchboard-refresh)
      (switchboard-refresh)
      (should switchboard--refresh-pending)
      (should (switchboard-test--wait-for-fetch 2))
      ;; The queued fetch is now in flight or done; either way no error.
      (switchboard-test--wait-for-fetch 2)
      (should (null switchboard--last-error))
      (should (null switchboard--refresh-pending)))))

(ert-deftest switchboard-fetch-finishes-when-a-child-holds-stderr ()
  "A descendant keeping the stderr pipe open does not block the fetch."
  (switchboard-test--with-clean-state
    (switchboard-test--with-fake-claude
        (list (concat "FAKE_CLAUDE_JSON=" switchboard-test--json)
              "FAKE_CLAUDE_HOLD_STDERR=3")
      (let ((t0 (float-time)))
        (switchboard-refresh)
        (should (switchboard-test--wait-for-fetch 3))
        ;; Finished by the drain timer, well before the child exits.
        (should (< (- (float-time) t0) 2.5))
        (should (null switchboard--last-error))
        (should (= (length switchboard--agents) 2))
        (should (null (get-buffer " *switchboard-fetch-stderr*")))))))

(ert-deftest switchboard-fetch-times-out ()
  "A hung fetch is abandoned, reported, and the slot released."
  (switchboard-test--with-clean-state
    (switchboard--apply-snapshot (list (switchboard-test--agent "keep" 'working)))
    (switchboard-test--with-fake-claude '("FAKE_CLAUDE_DELAY=5")
      (let ((switchboard-fetch-timeout 0.3))
        (switchboard-refresh)
        (should (switchboard-test--wait-for-fetch 3))
        (should (string-match-p "timed out" switchboard--last-error))
        ;; The old snapshot is intact and nothing leaked.
        (should (equal (mapcar #'switchboard-agent-id switchboard--agents) '("keep")))
        (should-not (seq-some (lambda (b) (string-prefix-p " *switchboard-fetch" (buffer-name b)))
                              (buffer-list)))))))

(ert-deftest switchboard-start-failure-cleans-up ()
  "If `make-process' signals, buffers are freed and the error reported."
  (switchboard-test--with-clean-state
    (switchboard-test--with-fake-claude nil
      (cl-letf (((symbol-function 'make-process)
                 (lambda (&rest _) (error "Resource temporarily unavailable"))))
        (switchboard-refresh)
        (should (null switchboard--process))
        (should (string-match-p "could not start" switchboard--last-error))
        (should-not (seq-some (lambda (b) (string-prefix-p " *switchboard-fetch" (buffer-name b)))
                              (buffer-list)))))))

(ert-deftest switchboard-forget-missing-keeps-sessions-with-nil-state ()
  "A present session whose state is nil is not treated as gone."
  (switchboard-test--with-clean-state
    (switchboard--apply-snapshot (list (switchboard-test--agent "a" 'working)))
    (switchboard--apply-snapshot (list (switchboard-test--agent "a" 'done)))
    (should (gethash "a" switchboard--unacknowledged))
    (switchboard--apply-snapshot (list (switchboard-test--agent "a" nil)))
    (should (gethash "a" switchboard--transitioned))))

;;;; Mode line and polling

(ert-deftest switchboard-lamp-in-global-mode-string ()
  "The lamp is added to and removed from every shape of `global-mode-string'."
  (dolist (initial (list nil "clock" '("a" "b") '(:eval (identity "x"))))
    (let ((global-mode-string initial))
      (switchboard--show-lamp)
      (should (listp global-mode-string))
      (should (member switchboard--mode-line-construct global-mode-string))
      (switchboard--show-lamp)
      (should (= 1 (seq-count (lambda (e) (equal e switchboard--mode-line-construct))
                              global-mode-string)))
      (switchboard--hide-lamp)
      (should-not (member switchboard--mode-line-construct global-mode-string))
      ;; What was there before is still there; nil is nil again.
      (cond
       ((null initial) (should (null global-mode-string)))
       ((and (listp initial) (not (keywordp (car initial))))
        (should (equal global-mode-string initial)))
       (t (should (member initial global-mode-string)))))))

(ert-deftest switchboard-invalid-poll-interval-disables-polling ()
  "Zero or negative intervals disable polling instead of spinning."
  (switchboard-test--with-clean-state
    (dolist (bad '(0 -1 "5"))
      (let ((switchboard-poll-interval bad))
        (should (null (switchboard--current-interval)))
        (should (string-match-p "positive number" switchboard--last-error))))
    (let ((switchboard-poll-interval 5)
          (switchboard-idle-poll-interval -1))
      (switchboard--apply-snapshot (list (switchboard-test--agent "a" 'done :pid nil)))
      (should (= (switchboard--current-interval) 5)))))

;;;; CLI output

(ert-deftest switchboard-strip-escapes ()
  "CSI, OSC and CR are removed, text is kept."
  (should (equal (switchboard--strip-escapes
                  "\e[31mred\e[0m \e]0;title\a ok\r\n\e[2J\e[H\e(Bdone")
                 "red  ok\ndone")))

;;;; Phase 2: choosing, dispatch, lifecycle, attach

(defun switchboard-test--wait-until (predicate &optional seconds)
  "Pump process output until PREDICATE returns non-nil, at most SECONDS."
  (let ((deadline (+ (float-time) (or seconds 5))))
    (while (and (not (funcall predicate)) (< (float-time) deadline))
      (accept-process-output nil 0.05))
    (funcall predicate)))

(ert-deftest switchboard-candidates-round-trip ()
  "A candidate names the session by id; coercion accepts every form."
  (switchboard-test--with-clean-state
    (switchboard--apply-snapshot (list (switchboard-test--agent "abc12345" 'working
                                                                :name "my job")))
    (let* ((agent (car switchboard--agents))
           (candidate (switchboard--candidate agent)))
      (should (string-prefix-p "abc12345" candidate))
      (should (string-suffix-p "my job" candidate))
      (should (equal (switchboard--candidate-id candidate) "abc12345"))
      (should (eq (switchboard--coerce-agent agent) agent))
      (should (eq (switchboard--coerce-agent candidate) agent))
      (should (eq (switchboard--coerce-agent "abc12345") agent))
      (should-error (switchboard--coerce-agent "nope") :type 'user-error)
      (should-error (switchboard--coerce-agent 42) :type 'user-error)
      (should (string-match-p "working" (switchboard--annotate-candidate candidate)))
      (should (eq (get-text-property 0 'face candidate) 'switchboard-working)))))

(ert-deftest switchboard-read-agent-uses-completion-with-category ()
  "Reading a session goes through `completing-read' with our category."
  (switchboard-test--with-clean-state
    (switchboard--apply-snapshot (list (switchboard-test--agent "aaaaaaaa" 'done :pid nil)
                                       (switchboard-test--agent "bbbbbbbb" 'blocked)))
    (let ((switchboard-completion-backend 'completing-read)
          seen-table)
      (cl-letf (((symbol-function 'completing-read)
                 (lambda (_prompt table &rest _)
                   (setq seen-table table)
                   (car (all-completions "" table)))))
        ;; Most urgent first: the blocked one is offered first.
        (should (equal (switchboard-agent-id (switchboard-read-agent "S: ")) "bbbbbbbb"))
        (should (eq (alist-get 'category (cdr (funcall seen-table "" nil 'metadata)))
                    'switchboard-agent))))
    (switchboard--apply-snapshot nil)
    (should-error (switchboard-read-agent "S: ") :type 'user-error)))

(ert-deftest switchboard-output-id ()
  "The id `claude --bg' prints is found in its decorated output."
  (should (equal (switchboard--output-id
                  "backgrounded · 22fcedd2 (idle — send a prompt to start)\n  claude attach 22fcedd2")
                 "22fcedd2"))
  (should (null (switchboard--output-id "nothing here")))
  (should (null (switchboard--output-id "deadbeefcafe is too long"))))

(ert-deftest switchboard-run-claude-reports-status-and-output ()
  "The CLI runner delivers exit status and stripped output, never signals."
  (switchboard-test--with-fake-claude nil
    (let (result)
      (switchboard--run-claude '("stop" "x") (lambda (status output) (setq result (list status output))))
      (should (switchboard-test--wait-until (lambda () result)))
      (should (equal result '(0 "fake-claude [stop] [x]")))))
  ;; Arguments reach the CLI one by one: spaces, quotes and a leading
  ;; dash inside an argument stay inside it.
  (switchboard-test--with-fake-claude nil
    (let (result)
      (switchboard--run-claude '("--bg" "--name" "my job" "--" "-fix \"it\" now")
                               (lambda (_status output) (setq result output)))
      (should (switchboard-test--wait-until (lambda () result)))
      (should (equal result "fake-claude [--bg] [--name] [my job] [--] [-fix \"it\" now]"))))
  (switchboard-test--with-fake-claude '("FAKE_CLAUDE_EXIT=2" "FAKE_CLAUDE_STDERR=nope")
    (let (result)
      (switchboard--run-claude '("rm" "x") (lambda (status output) (setq result (list status output))))
      (should (switchboard-test--wait-until (lambda () result)))
      (should (eql (car result) 2))
      (should (string-match-p "nope" (cadr result)))))
  (let ((switchboard-claude-program "/nonexistent/claude") result)
    (switchboard--run-claude '("stop" "x") (lambda (status output) (setq result (list status output))))
    (should (eq (car result) 'error))
    (should (string-match-p "not found" (cadr result)))))

(ert-deftest switchboard-dispatch-passes-args-and-directory ()
  "Dispatch runs claude --bg [--name NAME] -- PROMPT inside DIRECTORY."
  (switchboard-test--with-clean-state
    (let ((runs nil)
          (dir (file-name-as-directory (expand-file-name temporary-file-directory))))
      (cl-letf (((symbol-function 'switchboard--run-claude)
                 (lambda (args _on-done) (push (cons default-directory args) runs)))
                ((symbol-function 'message) #'ignore))
        (switchboard-dispatch "-looks like an option" dir "job name")
        (should (equal (car runs)
                       (list dir "--bg" "--name" "job name" "--" "-looks like an option")))
        (switchboard-dispatch "plain" (directory-file-name dir))
        (should (equal (car runs) (list dir "--bg" "--" "plain")))
        (should-error (switchboard-dispatch "   ") :type 'user-error)))))

(ert-deftest switchboard-dispatch-end-to-end-with-fake-claude ()
  "The fake CLI runs in DIRECTORY and the success message follows."
  (switchboard-test--with-clean-state
    (switchboard-test--with-fake-claude '("FAKE_CLAUDE_ECHO_CWD=1")
      (let ((messages nil)
            (dir (file-name-as-directory (expand-file-name temporary-file-directory))))
        (cl-letf (((symbol-function 'message)
                   (lambda (fmt &rest args) (push (apply #'format fmt args) messages))))
          (switchboard-dispatch "do the thing" dir)
          (should (switchboard-test--wait-until
                   (lambda () (seq-some (lambda (m) (string-match-p "dispatched" m)) messages))))
          (should (switchboard-test--wait-for-fetch)))
        (should (seq-some (lambda (m) (string-match-p "dispatched a session" m)) messages))
        ;; The completion message names the dispatch directory, not the
        ;; directory that happened to be current when the process exited.
        (should (seq-some (lambda (m) (and (string-match-p "dispatched" m)
                                           (string-match-p (regexp-quote (abbreviate-file-name dir)) m)))
                          messages))))))

(ert-deftest switchboard-run-claude-failure-message-survives ()
  "A synchronous start failure is not overwritten by the progress message."
  (switchboard-test--with-clean-state
    (switchboard--apply-snapshot (list (switchboard-test--agent "abc12345" 'done :pid nil)))
    (let ((messages nil)
          (switchboard-claude-program "/nonexistent/claude"))
      (cl-letf (((symbol-function 'message)
                 (lambda (fmt &rest args) (push (apply #'format fmt args) messages))))
        (switchboard-stop "abc12345"))
      ;; Newest first: the failure comes after "stop ...", and nothing
      ;; after it says "..." again.
      (let ((progress (seq-position messages "Switchboard: stop job abc12345..."))
            (failure (seq-position messages "failed" (lambda (m needle) (string-match-p needle m)))))
        (should progress)
        (should failure)
        (should (< failure progress))))))

(ert-deftest switchboard-remove-asks-first ()
  "Remove runs `claude rm' only after confirmation."
  (switchboard-test--with-clean-state
    (switchboard--apply-snapshot (list (switchboard-test--agent "abc12345" 'done :pid nil)))
    (let ((runs nil))
      (cl-letf (((symbol-function 'switchboard--run-claude)
                 (lambda (args _on-done) (push args runs)))
                ((symbol-function 'yes-or-no-p) (lambda (_) nil)))
        (switchboard-remove "abc12345")
        (should (null runs)))
      (cl-letf (((symbol-function 'switchboard--run-claude)
                 (lambda (args _on-done) (push args runs)))
                ((symbol-function 'yes-or-no-p) (lambda (_) t)))
        (switchboard-remove "abc12345")
        (should (equal runs '(("rm" "abc12345"))))
        (switchboard-stop "abc12345")
        (switchboard-respawn "abc12345")
        (should (equal (car runs) '("respawn" "abc12345")))
        (should (equal (cadr runs) '("stop" "abc12345")))))))

(ert-deftest switchboard-attach-uses-backend-and-reuses-buffer ()
  "A function backend gets (NAME COMMAND); a live buffer is reused by id."
  (switchboard-test--with-clean-state
    (switchboard-test--with-fake-claude nil
      (switchboard--apply-snapshot (list (switchboard-test--agent "abc12345" 'blocked :name "fix")
                                         (switchboard-test--agent "ffffffff" 'blocked :name "fix")))
      (let* ((calls nil)
             (switchboard-terminal-backend
              (lambda (name command)
                (push (list name command) calls)
                (let ((buffer (get-buffer-create name)))
                  (make-process :name "sb-test-term" :buffer buffer
                                :command '("sleep" "5") :noquery t)
                  buffer)))
             (buffer nil))
        (unwind-protect
            (progn
              (switchboard-attach "abc12345")
              (setq buffer (get-buffer "*switchboard: fix*"))
              (should buffer)
              (should (= (length calls) 1))
              (should (equal (car (car calls)) "*switchboard: fix*"))
              (should (equal (cdr (cadr (car calls))) '("attach" "abc12345")))
              (should (eq (buffer-local-value 'switchboard--attach-agent buffer)
                          (car switchboard--agents)))
              ;; Attaching again reuses the buffer with its live process.
              (switchboard-attach "abc12345")
              (should (= (length calls) 1))
              ;; A different session with the same name gets its own buffer.
              (switchboard-attach "ffffffff")
              (should (= (length calls) 2))
              (should (equal (car (car calls)) "*switchboard: fix*<2>"))
              (should (equal (cdr (cadr (car calls))) '("attach" "ffffffff")))
              ;; A renamed session is still found by id.
              (switchboard--apply-snapshot
               (list (switchboard-test--agent "abc12345" 'blocked :name "renamed")))
              (switchboard-attach "abc12345")
              (should (= (length calls) 2)))
          (dolist (name '("*switchboard: fix*" "*switchboard: fix*<2>"))
            (when-let* ((b (get-buffer name)))
              (when-let* ((p (get-buffer-process b))) (delete-process p))
              (kill-buffer b))))
        (let ((switchboard-terminal-backend 'no-such-backend))
          (should-error (switchboard--make-terminal "x" '("true")) :type 'user-error))))))

(ert-deftest switchboard-attach-and-transcript-use-the-display-function ()
  "Attach (new and reused buffer) and transcript show their buffer with the custom function."
  (switchboard-test--with-clean-state
    (switchboard-test--with-fake-claude nil
      (switchboard--apply-snapshot (list (switchboard-test--agent "abc12345" 'blocked :name "shown")))
      (let* ((shown nil)
             (switchboard-display-buffer-function (lambda (buffer) (push buffer shown)))
             (switchboard-terminal-backend
              (lambda (name _command)
                (let ((buffer (get-buffer-create name)))
                  (make-process :name "sb-test-cat" :buffer buffer :command '("cat")
                                :connection-type 'pipe :noquery t)
                  buffer)))
             (buffer nil))
        (unwind-protect
            (progn
              (switchboard-attach "abc12345")
              (setq buffer (get-buffer "*switchboard: shown*"))
              (should (equal shown (list buffer)))
              (switchboard-attach "abc12345")
              (should (equal shown (list buffer buffer))))
          (when (buffer-live-p buffer)
            (when-let* ((p (get-buffer-process buffer))) (delete-process p))
            (kill-buffer buffer))))))
  (switchboard-test--with-clean-state
    (switchboard-test--with-transcript (agent "abcdef01-0000-4000-8000-000000000007")
      (let* ((shown nil)
             (switchboard-display-buffer-function (lambda (buffer) (push buffer shown))))
        (unwind-protect
            (progn
              (switchboard-transcript agent)
              (should (equal shown (list (get-buffer "*switchboard transcript: fixture*")))))
          (when-let* ((b (get-buffer "*switchboard transcript: fixture*"))) (kill-buffer b)))))))

(ert-deftest switchboard-auto-backend-order ()
  "auto resolves to ghostel, then vterm (with its module), then eat."
  (let ((switchboard-terminal-backend 'auto))
    (cl-letf (((symbol-function 'locate-library)
               (lambda (name &rest _) (and (member name '("ghostel" "vterm" "vterm-module")) "/x/lib"))))
      (should (eq (switchboard--terminal-backend) 'ghostel)))
    (cl-letf (((symbol-function 'locate-library)
               (lambda (name &rest _) (and (member name '("vterm" "vterm-module")) "/x/vterm"))))
      (should (eq (switchboard--terminal-backend) 'vterm)))
    ;; vterm.el without its native module does not count.
    (cl-letf (((symbol-function 'locate-library)
               (lambda (name &rest _) (and (equal name "vterm") "/x/vterm.el"))))
      (should (eq (switchboard--terminal-backend) 'eat)))
    (cl-letf (((symbol-function 'locate-library) (lambda (&rest _) nil)))
      (should (eq (switchboard--terminal-backend) 'eat))))
  (let ((switchboard-terminal-backend 'eat))
    (should (eq (switchboard--terminal-backend) 'eat))))

(ert-deftest switchboard-attach-mode-and-hook ()
  "The attach buffer gets the minor mode, the hook runs in it, and S-RET sends the sequence."
  (switchboard-test--with-clean-state
    (switchboard-test--with-fake-claude nil
      (switchboard--apply-snapshot (list (switchboard-test--agent "abc12345" 'blocked :name "nl")))
      (let* ((hook-buffer nil)
             (switchboard-attach-hook (list (lambda () (setq hook-buffer (current-buffer)))))
             (switchboard-terminal-backend
              (lambda (name _command)
                (let ((buffer (get-buffer-create name)))
                  ;; A pipe, not a pty: a pty's line discipline would hold
                  ;; the newline-less sequence back from cat.
                  (make-process :name "sb-test-cat" :buffer buffer :command '("cat")
                                :connection-type 'pipe :noquery t)
                  buffer)))
             (buffer nil))
        (unwind-protect
            (progn
              (switchboard-attach "abc12345")
              (setq buffer (get-buffer "*switchboard: nl*"))
              (should (eq hook-buffer buffer))
              (should (buffer-local-value 'switchboard-attach-mode buffer))
              (should (eq (lookup-key (buffer-local-value 'switchboard-attach-mode-map buffer)
                                      (kbd "S-<return>"))
                          'switchboard-send-newline))
              (with-current-buffer buffer
                (switchboard-send-newline)
                (should (switchboard-test--wait-until
                         (lambda () (string-search "\e[13;2u" (buffer-string)))))
                ;; A buffer recycled for another process is refused.
                (let ((original (get-buffer-process buffer)))
                  (delete-process original)
                  (make-process :name "sb-test-other" :buffer buffer :command '("cat")
                                :connection-type 'pipe :noquery t)
                  (should-error (switchboard-send-newline) :type 'user-error))))
          (when (buffer-live-p buffer)
            (when-let* ((p (get-buffer-process buffer))) (delete-process p))
            (kill-buffer buffer)))))))

(ert-deftest switchboard-send-newline-uses-ghostel-encoder ()
  "In a ghostel buffer the newline goes through ghostel-send-key, not the pty."
  (with-temp-buffer
    (let ((sent nil) (written nil))
      (cl-letf (((symbol-function 'ghostel-send-key)
                 (lambda (key &optional mods) (setq sent (list key mods))))
                ((symbol-function 'process-send-string)
                 (lambda (&rest args) (setq written args)))
                ((symbol-function 'process-live-p) (lambda (_) t))
                ((symbol-function 'get-buffer-process) (lambda (&rest _) 'fake)))
        (setq switchboard--attach-process 'fake)
        (setq major-mode 'ghostel-mode)
        (switchboard-send-newline)
        (should (equal sent '("return" "shift")))
        (should (null written))
        (setq major-mode 'vterm-mode)
        (switchboard-send-newline)
        (should (equal written (list 'fake switchboard-newline-sequence)))))))

(ert-deftest switchboard-attach-survives-hook-killing-the-buffer ()
  "A hook that kills the new buffer does not make attach signal."
  (switchboard-test--with-clean-state
    (switchboard-test--with-fake-claude nil
      (switchboard--apply-snapshot (list (switchboard-test--agent "abc12345" 'blocked :name "k")))
      (let ((switchboard-attach-hook (list (lambda ()
                                             (when-let* ((p (get-buffer-process (current-buffer))))
                                               (delete-process p))
                                             (kill-buffer (current-buffer)))))
            (switchboard-terminal-backend
             (lambda (name _command)
               (let ((buffer (get-buffer-create name)))
                 (make-process :name "sb-test-k" :buffer buffer :command '("cat")
                               :connection-type 'pipe :noquery t)
                 buffer))))
        (switchboard-attach "abc12345")
        (should-not (get-buffer "*switchboard: k*"))))))

(ert-deftest switchboard-eat-backend-runs-command ()
  "With eat installed, the eat backend runs the command and kills the buffer on exit."
  (skip-unless (require 'eat nil t))
  (let* ((switchboard-kill-buffer-on-exit t)
         (buffer (switchboard--make-eat-terminal "*sb eat test*" '("sh" "-c" "echo switchboard-ok"))))
    (should (buffer-live-p buffer))
    (should (eq (buffer-local-value 'major-mode buffer) 'eat-mode))
    (should (switchboard-test--wait-until (lambda () (not (buffer-live-p buffer))) 10))))

;;;; Transcript

(defconst switchboard-test--transcript-lines
  (list
   ;; system-injected user message: skipped
   "{\"type\":\"user\",\"isMeta\":true,\"timestamp\":\"2026-09-17T03:00:00.000Z\",\"message\":{\"role\":\"user\",\"content\":[{\"type\":\"text\",\"text\":\"injected\"}]}}"
   "{\"type\":\"user\",\"timestamp\":\"2026-09-17T03:01:00.000Z\",\"message\":{\"role\":\"user\",\"content\":\"Fix the **build**\"}}"
   "{\"type\":\"assistant\",\"timestamp\":\"2026-09-17T03:01:05.000Z\",\"message\":{\"role\":\"assistant\",\"content\":[{\"type\":\"thinking\",\"thinking\":\"hmm\"}]}}"
   "{\"type\":\"assistant\",\"timestamp\":\"2026-09-17T03:01:06.000Z\",\"message\":{\"role\":\"assistant\",\"content\":[{\"type\":\"text\",\"text\":\"Looking at it.\"}]}}"
   "{\"type\":\"assistant\",\"timestamp\":\"2026-09-17T03:01:07.000Z\",\"message\":{\"role\":\"assistant\",\"content\":[{\"type\":\"tool_use\",\"name\":\"Bash\",\"input\":{\"command\":\"make\\nmake test\",\"description\":\"Run the build\"}}]}}"
   "{\"type\":\"user\",\"timestamp\":\"2026-09-17T03:01:08.000Z\",\"message\":{\"role\":\"user\",\"content\":[{\"type\":\"tool_result\",\"tool_use_id\":\"t1\",\"content\":\"ok\"}]}}"
   "{\"type\":\"attachment\",\"timestamp\":\"2026-09-17T03:01:09.000Z\"}"
   "{\"type\":\"assistant\",\"timestamp\":\"2026-09-17T03:01:10.000Z\",\"message\":{\"role\":\"assistant\",\"content\":[{\"type\":\"text\",\"text\":\"Done:\\n\\n- fixed `Makefile`\"}]}}"
   "{\"type\":\"user\",\"isCompactSummary\":true,\"timestamp\":\"2026-09-17T03:01:30.000Z\",\"message\":{\"role\":\"user\",\"content\":\"This session is being continued from a previous conversation...\"}}"
   "{\"type\":\"user\",\"timestamp\":\"2026-09-17T03:02:00.000Z\",\"message\":{\"role\":\"user\",\"content\":[{\"type\":\"text\",\"text\":\"thanks\"}]}}")
  "A transcript in the shape Claude Code writes, one record per line.")

(defmacro switchboard-test--with-transcript (spec &rest body)
  "Write the fixture transcript for session SPEC and run BODY.
SPEC is (VAR SESSION-ID &optional TRAILING): VAR is bound to the
agent, TRAILING is appended verbatim (for a half-written last line).
`switchboard-projects-directory' points at a temporary directory."
  (declare (indent 1))
  (let ((var (nth 0 spec)) (id (nth 1 spec)) (trailing (nth 2 spec)))
    `(let* ((root (make-temp-file "switchboard-projects" t))
            (dir (expand-file-name "-Users-me-proj" root))
            (switchboard-projects-directory root)
            (,var (switchboard-test--agent (substring ,id 0 8) 'done
                                           :session-id ,id :name "fixture")))
       (make-directory dir)
       (with-temp-file (expand-file-name (concat ,id ".jsonl") dir)
         (set-buffer-multibyte t)
         (insert (mapconcat #'identity switchboard-test--transcript-lines "\n") "\n")
         (when ,trailing (insert ,trailing)))
       (unwind-protect (progn ,@body)
         (delete-directory root t)))))

(ert-deftest switchboard-transcript-file-found-by-session-id ()
  "The transcript is located by session id; an id that is not a plain name is refused."
  (switchboard-test--with-transcript (agent "abcdef01-0000-4000-8000-000000000001")
    (should (string-suffix-p "abcdef01-0000-4000-8000-000000000001.jsonl"
                             (switchboard-transcript-file agent)))
    (should (null (switchboard-transcript-file
                   (switchboard-test--agent "ffffffff" 'done :session-id "ffffffff-none"))))
    (dolist (bad '("*" "../abcdef01-0000-4000-8000-000000000001" "a/b" "" "x y"))
      (should (null (switchboard-transcript-file
                     (switchboard-test--agent "bad00000" 'done :session-id bad)))))
    (should (null (switchboard-transcript-file
                   (switchboard-test--agent "nil00000" 'done :session-id nil))))))

(ert-deftest switchboard-transcript-read-stops-at-max-bytes ()
  "The first read stops doubling at the limit instead of reading the whole file."
  (switchboard-test--with-transcript (agent "abcdef01-0000-4000-8000-000000000010")
    (let ((file (switchboard-transcript-file agent))
          (switchboard-transcript-turns 1000))
      (let ((switchboard-transcript-max-bytes 300))
        (pcase-let ((`(,_turns ,bytes ,complete) (switchboard--transcript-read file 100)))
          (should-not complete)
          ;; 100 -> 200 -> 300, never past the limit.
          (should (= bytes 300))))
      ;; A chunk already beyond the limit (as `+' passes) is read as it is.
      (let ((switchboard-transcript-max-bytes 300))
        (pcase-let ((`(,_turns ,bytes ,_complete) (switchboard--transcript-read file 500)))
          (should (= bytes 500))))
      (let ((switchboard-transcript-max-bytes nil))
        (pcase-let ((`(,_turns ,_bytes ,complete) (switchboard--transcript-read file 100)))
          (should complete))))))

(ert-deftest switchboard-transcript-tail-parses-lines ()
  "A tail smaller than the file drops its partial first line; a half-written last line is skipped."
  (switchboard-test--with-transcript (agent "abcdef01-0000-4000-8000-000000000002"
                                            "{\"type\":\"assistant\",\"message\":{\"content\":[]}}")
    (let* ((file (switchboard-transcript-file agent))
           (size (file-attribute-size (file-attributes file))))
      ;; Whole file: every newline-terminated line parses; the last line,
      ;; valid JSON but not yet terminated, is left out.
      (pcase-let ((`(,records . ,complete) (switchboard--transcript-records file (* 2 size))))
        (should complete)
        (should (= (length records) (length switchboard-test--transcript-lines))))
      ;; A small tail: fewer records, none of them garbage.
      (pcase-let ((`(,records . ,complete) (switchboard--transcript-records file 300)))
        (should-not complete)
        (should (< (length records) (length switchboard-test--transcript-lines)))
        (should (seq-every-p (lambda (r) (alist-get 'type r)) records))))))

(ert-deftest switchboard-transcript-turns-extraction ()
  "Prompts and replies become turns; tool calls are summarized; the rest is dropped."
  (switchboard-test--with-transcript (agent "abcdef01-0000-4000-8000-000000000003")
    (let* ((file (switchboard-transcript-file agent))
           (turns (switchboard--transcript-turns
                   (car (switchboard--transcript-records file 1000000)))))
      (should (equal (mapcar #'car turns) '(user assistant user)))
      (should (equal (nth 2 (nth 0 turns)) "Fix the **build**"))
      ;; Three assistant records merge into one turn, thinking left out.
      (should (equal (nth 2 (nth 1 turns))
                     "Looking at it.\n\n⏺ Bash: Run the build\n\nDone:\n\n- fixed `Makefile`"))
      (should (equal (nth 2 (nth 2 turns)) "thanks"))
      (should-not (seq-some (lambda (turn) (string-match-p "continued from" (nth 2 turn))) turns))
      (should (string-match-p "^2026-09-17 " (switchboard--transcript-time (nth 1 (nth 0 turns))))))))

(ert-deftest switchboard-transcript-tail-drops-partial-first-turn ()
  "A tail starting inside a multi-record reply does not show that reply cut off."
  (switchboard-test--with-transcript (agent "abcdef01-0000-4000-8000-000000000005")
    (let* ((file (switchboard-transcript-file agent))
           (switchboard-transcript-turns 1)
           ;; Enough bytes to land inside the three assistant records
           ;; (the tool_use and "Done" lines plus the trailing user turns).
           (result (switchboard--transcript-read file 700)))
      (pcase-let ((`(,turns ,_bytes ,complete) result))
        (should-not complete)
        ;; The first (possibly partial) Claude turn is gone; what remains
        ;; starts with a turn that began inside the read range.
        (should (equal (car (car turns)) 'user))
        (should (equal (nth 2 (car turns)) "thanks"))))))

(ert-deftest switchboard-transcript-chunk-must-be-positive ()
  "A zero or negative chunk is refused instead of looping forever."
  (switchboard-test--with-transcript (agent "abcdef01-0000-4000-8000-000000000006")
    (let ((file (switchboard-transcript-file agent)))
      (should-error (switchboard--transcript-read file 0) :type 'user-error)
      (should-error (switchboard--transcript-read file -5) :type 'user-error))))

(ert-deftest switchboard-transcript-more-keeps-the-reading-position ()
  "Reading further back keeps point and the window at the same distance from the end."
  (switchboard-test--with-transcript (agent "abcdef01-0000-4000-8000-000000000008")
    (let ((switchboard-transcript-chunk 350)
          (switchboard-transcript-turns 1)
          (buffer nil))
      (unwind-protect
          (progn
            (cl-letf (((symbol-function 'pop-to-buffer) #'ignore))
              (switchboard-transcript agent))
            (setq buffer (get-buffer "*switchboard transcript: fixture*"))
            (with-current-buffer buffer
              (should (string-match-p "Earlier turns not shown" (buffer-string)))
              ;; Read the last heading; remember how far it is from the end.
              (goto-char (point-max))
              (re-search-backward "^## ")
              (let ((from-end (- (point-max) (point)))
                    (heading (buffer-substring (point) (line-end-position))))
                (switchboard-transcript-more)
                (should (> (point-max) from-end))
                (should (= (- (point-max) (point)) from-end))
                (should (equal (buffer-substring (point) (line-end-position)) heading)))))
        (when buffer (kill-buffer buffer))))))

(ert-deftest switchboard-transcript-show-tail-scrolls-one-window ()
  "The tail is brought into the selected window only; another window keeps its place."
  (let ((buffer (generate-new-buffer "*sb-test-tail*"))
        (other nil))
    (unwind-protect
        (progn
          (with-current-buffer buffer
            (dotimes (i 200) (insert (format "line %d\n" i))))
          (switch-to-buffer buffer)
          (setq other (split-window (selected-window) 6))
          (set-window-buffer other buffer)
          (set-window-start (selected-window) 1)
          (set-window-point (selected-window) 1)
          (set-window-start other 1)
          (set-window-point other 1)
          (switchboard--transcript-show-tail buffer)
          (should (= (window-point (selected-window)) (with-current-buffer buffer (point-max))))
          (should (> (window-start (selected-window)) 1))
          (should (= (window-start other) 1))
          (should (= (window-point other) 1))
          ;; From a window not showing it, the first window showing it is used.
          (set-window-start (selected-window) 1)
          (set-window-point (selected-window) 1)
          (with-temp-buffer
            (switchboard--transcript-show-tail buffer))
          (should (> (window-start (selected-window)) 1)))
      (when (window-live-p other) (delete-window other))
      (kill-buffer buffer))))

(ert-deftest switchboard-transcript-buffer-renders-markdown ()
  "The transcript buffer has headings per turn and reads further back with +."
  (switchboard-test--with-transcript (agent "abcdef01-0000-4000-8000-000000000004")
    (let ((switchboard-transcript-chunk 350)
          (switchboard-transcript-turns 1)
          (buffer nil))
      (unwind-protect
          (progn
            (cl-letf (((symbol-function 'pop-to-buffer) #'ignore))
              (switchboard-transcript agent))
            (setq buffer (get-buffer "*switchboard transcript: fixture*"))
            (should buffer)
            (with-current-buffer buffer
              (should switchboard-transcript-mode)
              (should buffer-read-only)
              (should (string-match-p "^# fixture" (buffer-string)))
              ;; A small tail shows only the last complete turn.
              (should (string-match-p "^## You  2026-09-17 [0-9:]+\n\nthanks" (buffer-string)))
              (should-not (string-match-p "^## Claude" (buffer-string)))
              (should (string-match-p "Earlier turns not shown" (buffer-string)))
              ;; The first read may already have doubled the chunk to
              ;; reach one complete turn; + doubles from there.
              (let ((bytes switchboard--transcript-bytes))
                (should (>= bytes 350))
                (switchboard-transcript-more)
                (should (= switchboard--transcript-bytes (* 2 bytes))))
              ;; Keep reading back until the whole file is in.
              (let ((n 0))
                (while (and (string-match-p "Earlier turns" (buffer-string)) (< n 6))
                  (switchboard-transcript-more)
                  (cl-incf n)))
              (should-not (string-match-p "Earlier turns" (buffer-string)))
              (should (string-match-p "^## You  2026-09-17 [0-9:]+\n\nFix the \\*\\*build\\*\\*" (buffer-string)))
              (should (string-match-p "^## Claude  2026" (buffer-string)))
              (should (string-match-p "⏺ Bash: Run the build" (buffer-string)))
              (should-not (string-match-p "injected" (buffer-string)))
              (should-not (string-match-p "continued from" (buffer-string)))))
        (when buffer (kill-buffer buffer))))))

;;;; consult

(defun switchboard-test--consult-p ()
  "Load switchboard-consult when consult is installed; nil otherwise."
  (and (require 'consult nil t) (require 'switchboard-consult nil t)))

(ert-deftest switchboard-consult-entry-points-are-autoloaded ()
  "Loading switchboard alone makes the consult picker a command."
  (should (commandp 'switchboard-consult))
  (should (fboundp 'switchboard-consult-read-agent)))

(ert-deftest switchboard-completion-backend-resolution ()
  "auto is consult when the library is installed, else completing-read."
  (let ((switchboard-completion-backend 'auto))
    (cl-letf (((symbol-function 'locate-library)
               (lambda (name &rest _) (and (equal name "consult") "/x/consult.el"))))
      (should (eq (switchboard--completion-backend) 'consult)))
    (cl-letf (((symbol-function 'locate-library) (lambda (&rest _) nil)))
      (should (eq (switchboard--completion-backend) 'completing-read))))
  (let ((switchboard-completion-backend 'completing-read))
    (should (eq (switchboard--completion-backend) 'completing-read))))

(ert-deftest switchboard-consult-sources-partition-sessions ()
  "The picker sources split the sessions by state; the single source has them all."
  (skip-unless (switchboard-test--consult-p))
  (switchboard-test--with-clean-state
    (switchboard--apply-snapshot (list (switchboard-test--agent "aaaaaaaa" 'done :pid nil)
                                       (switchboard-test--agent "bbbbbbbb" 'blocked)
                                       (switchboard-test--agent "cccccccc" 'working)
                                       (switchboard-test--agent "dddddddd" 'failed)
                                       (switchboard-test--agent "eeeeeeee" 'stopped :pid nil)))
    (cl-flet ((ids (source)
                (mapcar #'switchboard--candidate-id
                        (funcall (plist-get (symbol-value source) :items)))))
      (should (equal (ids 'switchboard-consult-source-needs-you) '("bbbbbbbb" "dddddddd")))
      (should (equal (ids 'switchboard-consult-source-working) '("cccccccc")))
      (should (equal (ids 'switchboard-consult-source-finished) '("aaaaaaaa" "eeeeeeee")))
      (should (equal (ids 'switchboard-consult-source)
                     '("bbbbbbbb" "dddddddd" "cccccccc" "aaaaaaaa" "eeeeeeee"))))
    (should (eq (plist-get switchboard-consult-source :category) 'switchboard-agent))
    (should (eql (plist-get switchboard-consult-source :narrow) ?c))
    (should (eq (plist-get switchboard-consult-source :action) #'switchboard--consult-action)))
  ;; The retention applies unless every session is asked for.  An old
  ;; session is hidden only when it was in the first snapshot: a session
  ;; that appears later counts as a transition and stays visible.
  (switchboard-test--with-clean-state
    (switchboard--apply-snapshot (list (switchboard-test--agent "old00000" 'done :pid nil
                                                                :started-at 0)))
    (should (null (switchboard--consult-items)))
    (let ((switchboard--consult-all t))
      (should (equal (mapcar #'switchboard--candidate-id (switchboard--consult-items))
                     '("old00000"))))))

(ert-deftest switchboard-consult-preview-prefers-attached-buffer ()
  "A live attached buffer is previewed as is; otherwise the transcript is rendered."
  (skip-unless (switchboard-test--consult-p))
  (switchboard-test--with-clean-state
    (switchboard-test--with-transcript (agent "abcdef01-0000-4000-8000-000000000005")
      (switchboard--apply-snapshot (list agent))
      (let ((candidate (switchboard--candidate agent))
            (own (generate-new-buffer " *sb-test-preview*"))
            (attached nil))
        (unwind-protect
            (progn
              (should (null (switchboard--consult-preview-buffer "nope0000  x" own)))
              (should (eq (switchboard--consult-preview-buffer candidate own) own))
              (with-current-buffer own
                (should (string-match-p "^## You" (buffer-string)))
                (should (eq switchboard--transcript-agent agent)))
              ;; With a terminal attached to the session, that buffer wins.
              (setq attached (generate-new-buffer "*sb-test-attached*"))
              (with-current-buffer attached
                (setq switchboard--attach-agent agent
                      switchboard--attach-process
                      (make-process :name "sb-test-term" :buffer attached
                                    :command '("sleep" "5") :noquery t)))
              (should (eq (switchboard--consult-preview-buffer candidate own) attached)))
          (kill-buffer own)
          (when (buffer-live-p attached)
            (when-let* ((p (get-buffer-process attached))) (delete-process p))
            (kill-buffer attached)))))))

(defun switchboard-test--preview-buffers ()
  "Return the live preview buffers."
  (seq-filter (lambda (b) (string-prefix-p switchboard--preview-buffer-name (buffer-name b)))
              (buffer-list)))

(ert-deftest switchboard-consult-state-shows-preview-and-cleans-up ()
  "The state shows its own preview buffer, kills it on exit, and `return' makes none."
  (skip-unless (switchboard-test--consult-p))
  (switchboard-test--with-clean-state
    (switchboard-test--with-transcript (agent "abcdef01-0000-4000-8000-000000000006")
      (switchboard--apply-snapshot (list agent))
      (let ((state (switchboard--consult-state))
            (candidate (switchboard--candidate agent))
            (original (window-buffer))
            (other (split-window (selected-window) 6)))
        (unwind-protect
            (progn
              ;; Before any preview the state has no buffer of its own;
              ;; setup, a reset and exit must leave the current buffer alone.
              (with-current-buffer original
                (let ((inhibit-read-only t)) (erase-buffer) (dotimes (i 200) (insert (format "line %d\n" i))))
                (goto-char (point-min)))
              (set-window-start (selected-window) 1)
              ;; consult calls the state with the original window selected
              ;; and its buffer current.
              (with-current-buffer original
                (funcall state 'setup nil)
                (funcall state 'preview nil))
              (should (= (window-point (selected-window)) 1))
              (should (= (window-start (selected-window)) 1))
              (funcall state 'preview candidate)
              (should (= 1 (length (switchboard-test--preview-buffers))))
              (should (memq (window-buffer) (switchboard-test--preview-buffers)))
              ;; The end of the transcript is in view, in a window too
              ;; small for the whole buffer.  (`pos-visible-in-window-p'
              ;; needs a real display, so count screen lines instead.)
              (let ((window (selected-window)))
                (cl-flet ((tail-in-view-p ()
                            (with-current-buffer (window-buffer window)
                              (and (= (window-point window) (point-max))
                                   (> (window-start window) 1)
                                   (<= (count-screen-lines (window-start window)
                                                           (window-point window) nil window)
                                       (window-text-height window))))))
                  (should (tail-in-view-p))
                  ;; A second preview reuses the buffer; the window kept
                  ;; the old start, which must not leave it at the top.
                  (set-window-start window 1)
                  (funcall state 'preview candidate)
                  (should (= 1 (length (switchboard-test--preview-buffers))))
                  (should (tail-in-view-p))))
              (funcall state 'preview nil)
              (should (eq (window-buffer) original))
              ;; The lifecycle consult follows: reset, exit, then return
              ;; with the chosen candidate.  Nothing must be rendered after
              ;; exit.
              (funcall state 'exit nil)
              (should (null (switchboard-test--preview-buffers)))
              (funcall state 'return candidate)
              (should (null (switchboard-test--preview-buffers)))
              ;; Two states do not share a buffer.
              (let ((other (switchboard--consult-state)))
                (funcall other 'preview candidate)
                (funcall state 'preview candidate)
                (should (= 2 (length (switchboard-test--preview-buffers))))
                (funcall other 'exit nil)
                (should (= 1 (length (switchboard-test--preview-buffers))))
                (funcall state 'exit nil)
                (should (null (switchboard-test--preview-buffers)))))
          (when (window-live-p other) (delete-window other))
          (mapc #'kill-buffer (switchboard-test--preview-buffers)))))))

(ert-deftest switchboard-read-agent-with-consult-returns-the-choice ()
  "The consult backend reads through `consult--multi' with the actions removed."
  (skip-unless (switchboard-test--consult-p))
  (switchboard-test--with-clean-state
    (switchboard--apply-snapshot (list (switchboard-test--agent "aaaaaaaa" 'done :pid nil)
                                       (switchboard-test--agent "bbbbbbbb" 'blocked)))
    (let ((switchboard-completion-backend 'consult)
          (seen nil))
      (cl-letf (((symbol-function 'consult--multi)
                 (lambda (sources &rest options)
                   (setq seen (list sources options))
                   (cons (seq-some (lambda (src) (car (funcall (plist-get src :items))))
                                   sources)
                         (list :match t)))))
        (should (equal (switchboard-agent-id (switchboard-read-agent "S: ")) "bbbbbbbb"))
        (should (equal (plist-get (cadr seen) :prompt) "S: "))
        (should (equal (mapcar (lambda (src) (plist-get src :name)) (car seen))
                       '("Needs you" "Working" "Finished")))
        (should (seq-every-p (lambda (src) (null (plist-get src :action))) (car seen)))
        ;; The exported sources keep their actions.
        (should (plist-get switchboard-consult-source-needs-you :action))
        ;; ALL lifts the retention while the sources are read.
        (switchboard--apply-snapshot (list (switchboard-test--agent "old00000" 'done :pid nil
                                                                    :started-at 0)))
        (switchboard--reset)
        (switchboard--apply-snapshot (list (switchboard-test--agent "old00000" 'done :pid nil
                                                                    :started-at 0)))
        (should-error (switchboard-read-agent "S: ") :type 'user-error)
        (should (equal (switchboard-agent-id (switchboard-read-agent "S: " t)) "old00000"))))))

(ert-deftest switchboard-consult-action-uses-its-display-function ()
  "The picker attaches to a live session, shows the transcript of a dead one, with its own display function."
  (skip-unless (switchboard-test--consult-p))
  (switchboard-test--with-clean-state
    (switchboard--apply-snapshot (list (switchboard-test--agent "aaaaaaaa" 'done :pid nil)
                                       (switchboard-test--agent "bbbbbbbb" 'blocked)))
    (let* ((calls nil)
           (record (lambda (kind)
                     (lambda (agent)
                       (push (list kind (switchboard-agent-id (switchboard--coerce-agent agent))
                                   switchboard-display-buffer-function)
                             calls)))))
      (cl-letf (((symbol-function 'switchboard-attach) (funcall record 'attach))
                ((symbol-function 'switchboard-transcript) (funcall record 'transcript)))
        (switchboard--consult-action (switchboard--candidate (switchboard-agent-by-id "bbbbbbbb")))
        (switchboard--consult-action (switchboard--candidate (switchboard-agent-by-id "aaaaaaaa")))
        (should (equal (nreverse calls)
                       (list (list 'attach "bbbbbbbb" switchboard-consult-display-buffer-function)
                             (list 'transcript "aaaaaaaa" switchboard-consult-display-buffer-function))))
        (should (eq switchboard-consult-display-buffer-function #'pop-to-buffer-same-window))
        ;; Outside the picker the general function is untouched.
        (should (eq switchboard-display-buffer-function #'pop-to-buffer))))))

(ert-deftest switchboard-consult-command-uses-the-sources ()
  "The picker offers the sources as they are; a prefix argument lifts the retention."
  (skip-unless (switchboard-test--consult-p))
  (switchboard-test--with-clean-state
    (switchboard--apply-snapshot (list (switchboard-test--agent "aaaaaaaa" 'done :pid nil
                                                                :started-at 0)))
    (let ((seen nil))
      (cl-letf (((symbol-function 'consult--multi)
                 (lambda (sources &rest options)
                   (setq seen (list sources options (switchboard--consult-items)))
                   nil)))
        (should-error (switchboard-consult) :type 'user-error)
        (switchboard-consult t)
        (should (eq (car seen) switchboard-consult-sources))
        (should (equal (plist-get (cadr seen) :prompt) "Session: "))
        (should (equal (mapcar #'switchboard--candidate-id (nth 2 seen)) '("aaaaaaaa")))))))

;;;; Embark and session commands

(ert-deftest switchboard-embark-map-bindings ()
  "The map has the session actions, RET as default, and no respawn."
  (should (eq (keymap-lookup switchboard-embark-map "RET") #'switchboard-attach))
  (should (eq (keymap-lookup switchboard-embark-map "d") #'switchboard-dispatch-here))
  (should (eq (keymap-lookup switchboard-embark-map "j") #'switchboard-dired))
  (should (eq (keymap-lookup switchboard-embark-map "w") #'switchboard-copy-id))
  (should (eq (keymap-lookup switchboard-embark-map "k") #'switchboard-remove))
  (should-not (keymap-lookup switchboard-embark-map "r")))

(ert-deftest switchboard-embark-target-at-point ()
  "The finder returns the session on the list line, or of a transcript or attached buffer."
  (switchboard-test--with-clean-state
    (switchboard--apply-snapshot (list (switchboard-test--agent "abc12345" 'working :name "job")))
    (let ((agent (car switchboard--agents)))
      (with-temp-buffer
        (should-not (switchboard-embark-target)))
      (with-temp-buffer
        (setq switchboard--transcript-agent agent)
        (let ((target (switchboard-embark-target)))
          (should (eq (car target) 'switchboard-agent))
          (should (eq (switchboard--coerce-agent (cdr target)) agent))))
      (with-temp-buffer
        (setq switchboard--attach-agent agent)
        (should (eq (switchboard--coerce-agent (cdr (switchboard-embark-target))) agent))
        ;; An active region there belongs to the user, not to the session.
        (insert "some text")
        (let ((transient-mark-mode t))
          (set-mark (point-min))
          (goto-char (point-max))
          (should (use-region-p))
          (should-not (switchboard-embark-target))))
      (with-current-buffer (get-buffer-create switchboard-buffer-name)
        (unwind-protect
            (progn
              (switchboard-mode)
              (tabulated-list-print t)
              (goto-char (point-min))
              (pcase-let ((`(,type ,candidate ,beg . ,end) (switchboard-embark-target)))
                (should (eq type 'switchboard-agent))
                (should (eq (switchboard--coerce-agent candidate) agent))
                (should (= beg (line-beginning-position)))
                (should (= end (line-end-position))))
              ;; Past the last row there is no target.
              (goto-char (point-max))
              (should-not (switchboard-embark-target)))
          (kill-buffer))))))

(ert-deftest switchboard-embark-setup-registers-map-and-finder ()
  "Setup registers the map with the general map behind it, and the finder, once."
  (skip-unless (require 'embark nil t))
  (let ((embark-keymap-alist (copy-sequence embark-keymap-alist))
        (embark-target-finders (copy-sequence embark-target-finders)))
    (switchboard-embark-setup)
    (switchboard-embark-setup)
    (should (equal (alist-get 'switchboard-agent embark-keymap-alist)
                   '(switchboard-embark-map embark-general-map)))
    (should (= 1 (seq-count (lambda (entry) (eq (car entry) 'switchboard-agent))
                            embark-keymap-alist)))
    (should (= 1 (seq-count (lambda (fn) (eq fn #'switchboard-embark-target))
                            embark-target-finders)))))

(ert-deftest switchboard-dispatch-here-uses-the-session-directory ()
  "dispatch-here dispatches in the session's cwd; a missing cwd is a user error."
  (switchboard-test--with-clean-state
    (let ((dir (file-name-as-directory (expand-file-name temporary-file-directory)))
          (runs nil))
      (switchboard--apply-snapshot
       (list (switchboard-test--agent "abc12345" 'working :cwd (directory-file-name dir))
             (switchboard-test--agent "gone0000" 'working :cwd "/nonexistent/switchboard")))
      (cl-letf (((symbol-function 'switchboard--run-claude)
                 (lambda (args _on-done) (push (cons default-directory args) runs)))
                ((symbol-function 'read-string) (lambda (&rest _) "more work"))
                ((symbol-function 'message) #'ignore))
        (switchboard-dispatch-here "abc12345")
        (should (equal (car runs) (list dir "--bg" "--" "more work")))
        (should-error (switchboard-dispatch-here "gone0000") :type 'user-error)
        (should (= (length runs) 1))))))

(ert-deftest switchboard-dired-and-copy-id ()
  "dired opens the session's cwd; copy-id copies the short id, or the full one."
  (switchboard-test--with-clean-state
    (let ((dir (directory-file-name (expand-file-name temporary-file-directory)))
          (opened nil)
          (kill-ring nil))
      (switchboard--apply-snapshot
       (list (switchboard-test--agent "abc12345" 'working :cwd dir
                                      :session-id "abc12345-full-id")))
      (cl-letf (((symbol-function 'dired) (lambda (d) (setq opened d)))
                ((symbol-function 'message) #'ignore))
        (switchboard-dired "abc12345")
        (should (equal opened dir))
        (switchboard-copy-id "abc12345")
        (should (equal (car kill-ring) "abc12345"))
        (switchboard-copy-id "abc12345" t)
        (should (equal (car kill-ring) "abc12345-full-id"))))))

(provide 'switchboard-test)
;;; switchboard-test.el ends here
