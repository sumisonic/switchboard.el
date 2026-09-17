# Switchboard

An Emacs front-end for Claude Code background sessions (`claude agents`).

Like a telephone switchboard, it shows one line per session, lights a lamp
when a session needs you, has finished or has failed, and lets you plug in
(`claude attach`) without leaving Emacs.

Switchboard is an unofficial project. It is not affiliated with or endorsed
by Anthropic. "Claude" and "Claude Code" are trademarks of Anthropic, PBC.

> **Status: 0.1.0, early.** Everything below works, is covered by tests and
> was measured against Claude Code 2.1.274 to 2.1.278, but the package is
> young and not on MELPA yet.

## What it does

```
 [!1 ✓2]                     <- mode-line lamp: 1 blocked, 2 done (unacknowledged)

 *switchboard*
   State    Waiting         Dir           Name                              Id        Age
 ! blocked  input needed    dotfiles      herdr terminal multiplexer eval   2f82c2f8  17h
   working                  web           faq spreadsheet review            e9bde36b  3m
 ✓ done                     org           daily feed collection             ac07a3e4  3h
```

- **Watch.** `switchboard-watch-mode` polls `claude agents --json --all`,
  diffs each snapshot against the previous one and runs
  `switchboard-state-change-functions` only when a session *enters*
  `blocked`, `done` or `failed`. The first snapshot after Emacs starts never
  notifies, so old events are not replayed. A Claude Code hook can also nudge
  Emacs for sub-second updates.
- **Show.** The lamp in the mode line (click it to open the list),
  `M-x switchboard` for the list with the sessions that need you first, and
  `l` for the session's conversation as Markdown: prompts, replies and
  one-line tool-call summaries, read from the transcript Claude Code keeps,
  so it works for finished sessions too and needs no terminal emulation.
- **Plug in.** `RET` opens `claude attach <id>` in a ghostel, vterm or eat
  buffer. A session can be attached from several terminals at once, though
  its screen size follows the client that attached last (see
  Troubleshooting). `Ctrl+Z` detaches and closes the buffer; the session
  keeps running.
- **Operate.** `d` dispatches a new session with `claude --bg`, `s`/`r`/`k`
  run `claude stop`/`respawn`/`rm`. Outside the list every command reads a
  session with completion; with [consult](https://github.com/minad/consult)
  installed, `switchboard-consult` picks one with a preview of its
  conversation, and Embark acts on sessions wherever they appear.

What happens on a transition is yours to decide. The default is the lamp and
a `message`; OS notifications and jumps to your terminal multiplexer belong
in your init file, not in this package.

## Scope

- Background sessions only: the ones `claude agents --json` lists. An
  interactive `claude` session is not tracked until you background it (`←`
  on an empty prompt, or `/background`).
- Only the documented CLI is used (`claude agents --json`, `attach`, `--bg`,
  `stop`, `respawn`, `rm`). The supervisor's private state under
  `~/.claude/jobs/` is never read. Conversations come from the session
  transcripts under `~/.claude/projects/`, the JSON Lines files Claude Code
  also hands to hooks as `transcript_path`; they are only ever read.
- Switchboard relies on Claude Code CLI and hook behaviour as observed in
  2.1.274 to 2.1.278: the JSON fields, the hook events, the transcript file
  layout, several terminals attaching to one session.
  Anthropic may change any of it between releases; only those versions have
  been verified.
- Not a generic agent framework, and not a reimplementation of the agent
  view TUI: peek and reply happen in the attached session.

## Requirements

- Emacs 29.1 or later.
- Claude Code with `claude agents --json` (verified with 2.1.274 to 2.1.278).
- Optional: [ghostel](https://github.com/dakra/ghostel) or
  [vterm](https://github.com/akermu/emacs-libvterm) to attach (preferred: a
  busy session redraws its screen many times a second and replays its
  transcript on attach, which the native emulators handle easily while eat
  can stall Emacs for minutes); [eat](https://codeberg.org/akib/emacs-eat)
  to attach without a native module;
  [markdown-mode](https://github.com/jrblevin/markdown-mode) to read
  transcripts with highlighting and folding (plain `text-mode` otherwise);
  [consult](https://github.com/minad/consult) to pick sessions with a
  preview (`switchboard-consult.el`, loaded on demand);
  [Embark](https://github.com/oantolin/embark) for actions on sessions;
  `bash` (and optionally `jq`) for the instant-refresh hook. None is a hard
  dependency.

## Installation

Not on MELPA yet. From Git:

```elisp
;; use-package with the built-in :vc keyword (Emacs 30+)
(use-package switchboard
  :vc (:url "https://github.com/sumisonic/switchboard.el"))

;; elpaca
(elpaca (switchboard :host github :repo "sumisonic/switchboard.el"
                     :files (:defaults ("bin" "bin/switchboard-hook"))))

;; straight
(straight-use-package
 '(switchboard :type git :host github :repo "sumisonic/switchboard.el"
               :files (:defaults ("bin" "bin/switchboard-hook"))))
```

The `("bin" ...)` element keeps the hook script under `bin/`; a plain
`"bin/switchboard-hook"` would be copied to the package root (the script is
found there too, but the documented location is `bin/`). The intended MELPA
recipe is
`(switchboard :fetcher github :repo "sumisonic/switchboard.el" :files (:defaults ("bin" "bin/switchboard-hook")))`.

## Quick start

```elisp
(switchboard-watch-mode 1)   ; poll, diff, light the lamp
;; M-x switchboard            ; the list
```

Optional pieces:

```elisp
;; Do something on blocked / done / failed. AGENT is a `switchboard-agent'.
(add-hook 'switchboard-state-change-functions
          (lambda (agent old new)
            (message "Claude %s: %s -> %s" (switchboard-agent-name agent) old new)))

;; Pick the terminal, or attach through your own function.
(setq switchboard-terminal-backend 'vterm) ; default: ghostel, else vterm, else eat
(setq switchboard-attach-function
      (lambda (agent)
        (if (display-graphic-p)
            (switchboard-attach-in-terminal agent)
          (my/jump-to-terminal-for agent))))

;; Embark actions on session candidates.
(with-eval-after-load 'embark (switchboard-embark-setup))
```

## Commands and keys

| Command | In the list | Does |
|---|---|---|
| `switchboard` | | Open the list (and refresh) |
| `switchboard-watch-mode` | | Toggle polling and the mode-line lamp |
| `switchboard-refresh` | `g` | Fetch and diff now; safe from `emacsclient -e` |
| `switchboard-attach` | `RET` | `claude attach` via `switchboard-attach-function` |
| `switchboard-transcript` | `SPC`, `l` | The conversation as Markdown, opened at its end; in that buffer `g` re-reads, `+` reads further back (keeping your place), `q` closes |
| `switchboard-acknowledge` | `a` | Turn off the done/failed lamp for the session at point (`C-u`: all) |
| `switchboard-toggle-show-all` | `A` | Show sessions hidden by `switchboard-done-retention` |
| `switchboard-dispatch` | `d` | `claude --bg` in the current project (`C-u`: choose a directory) |
| `switchboard-stop` | `s` | `claude stop` |
| `switchboard-respawn` | `r` | `claude respawn` |
| `switchboard-remove` | `k` | `claude rm`, after confirmation |
| `switchboard-consult` | | Pick a session with consult, previewed, and open it (`C-u`: all sessions) |
| `switchboard-dispatch-here` | | `claude --bg` in the session's own directory |
| `switchboard-dired` | | Dired in the session's directory |
| `switchboard-copy-id` | | Copy the session's id (`C-u`: the full session id) |
| `switchboard-hook-settings` | | Show the JSON for the instant-refresh hook |

Outside the list, every command that takes a session reads one with
completion. Candidates are `<id>  <name>` in the state's face, annotated with
state, directory and age, most urgent first. With consult installed
(`switchboard-completion-backend` at `auto`) the reader is
`switchboard-consult-read-agent`: sessions are grouped as *Needs you*,
*Working* and *Finished*, narrowable with `b`, `w` and `d` after
`consult-narrow-key`, and the highlighted one is previewed. Without consult
it is plain `completing-read`, which vertico and friends enhance on their own.
The completion category is `switchboard-agent` either way.

### consult

`switchboard-consult` is a picker on its own: `RET` attaches to a running
session and shows the transcript of one that is not, in the selected window
like `consult-buffer` does (`switchboard-consult-display-buffer-function`;
elsewhere `switchboard-display-buffer-function` applies and defaults to
another window). The preview shows the session's transcript, scrolled to its
end, or its terminal buffer when one is attached; a preview never attaches.
To have sessions show up in `consult-buffer` too, add the exported source:

```elisp
(with-eval-after-load 'consult
  (require 'switchboard-consult)
  (add-to-list 'consult-buffer-sources 'switchboard-consult-source t))
```

They then narrow with `c`. The sources are ordinary consult sources, so
`consult-customize` applies, for example to debounce the preview:

```elisp
(with-eval-after-load 'switchboard-consult
  (consult-customize switchboard-consult-source
                     :preview-key '("C-p" :debounce 0.3 any)))
```

The sources read the current snapshot only; `switchboard-watch-mode` keeps
it fresh, and `consult-buffer` never waits for a fetch.

### Embark

```elisp
(with-eval-after-load 'embark (switchboard-embark-setup))
```

makes a session an Embark target in three places: a completion candidate
(including the consult picker and `consult-buffer`), the line at point in
the list, and the session a transcript or attached buffer shows (unless a
region is active there, which stays your target). Actions:
`a` attach, `l` transcript, `d` dispatch in its directory, `j` Dired there,
`w` copy its id, `s` stop, `k` remove; `RET` (`embark-dwim`) attaches outside
the minibuffer. Embark's general actions stay available behind them.

The list is ordered: live blocked, failed, blocked whose process exited,
working, done, stopped; newest first within a group. The `Waiting` column
shows what a session waits for when Claude Code reports it (`permission
prompt`, `input needed`, ...), or `exited` for a blocked session whose
process is gone.

### Evil users

`switchboard-mode` derives from `tabulated-list-mode`, which Evil puts in
normal state, so its single-key commands are shadowed by Evil's own (`RET`
becomes `evil-ret`, `l` moves right, ...). Bind them for normal state, for
example:

```elisp
(with-eval-after-load 'evil
  (evil-define-key 'normal switchboard-mode-map
    (kbd "RET") #'switchboard-attach
    "l" #'switchboard-transcript
    "gr" #'switchboard-refresh
    "a" #'switchboard-acknowledge
    "A" #'switchboard-toggle-show-all
    "d" #'switchboard-dispatch
    "s" #'switchboard-stop
    "r" #'switchboard-respawn
    "x" #'switchboard-remove
    "q" #'quit-window))
```

The transcript buffer is a `markdown-mode` buffer, so Evil's normal state
applies there too; bind `switchboard-transcript-mode-map`'s `g`, `+` and `q`
for normal state the same way if you want them.

## Configuration

| Variable | Default | Meaning |
|---|---|---|
| `switchboard-claude-program` | `"claude"` | Executable; set an absolute path if your GUI Emacs has a short `exec-path` |
| `switchboard-poll-interval` | `5` | Seconds between polls; `nil` disables polling (hook only) |
| `switchboard-idle-poll-interval` | `30` | Interval while no session has a live process |
| `switchboard-fetch-timeout` | `30` | Seconds before a hung `claude` call is abandoned |
| `switchboard-notify-states` | `(blocked done failed)` | States whose entry runs the hook |
| `switchboard-state-change-functions` | `nil` | Abnormal hook `(AGENT OLD NEW)` |
| `switchboard-echo-transitions` | `t` | Also `message` each notified transition |
| `switchboard-attach-function` | `switchboard-attach-in-terminal` | What `RET` does |
| `switchboard-terminal-backend` | `auto` | `auto` (the first of ghostel, vterm, eat that is installed), `ghostel`, `vterm`, `eat`, or a function `(NAME COMMAND)` returning a buffer |
| `switchboard-kill-buffer-on-exit` | `t` | Close the terminal buffer when `claude attach` exits |
| `switchboard-attach-hook` | `nil` | Run in each new attached buffer |
| `switchboard-display-buffer-function` | `pop-to-buffer` | How attach and transcript buffers are shown: another window (default) or `pop-to-buffer-same-window`, or your own function |
| `switchboard-newline-sequence` | `"\e[13;2u"` | What `S-<return>` sends in an attached buffer |
| `switchboard-done-retention` | 86400 | Seconds an old finished session stays listed; `nil` keeps all |
| `switchboard-lamp-glyphs` | `! ✓ ✗ ⚠` | Glyphs for blocked, done, failed, fetch error |
| `switchboard-projects-directory` | `~/.claude/projects/` | Where Claude Code keeps transcripts |
| `switchboard-transcript-turns` | `10` | Minimum turns read at first |
| `switchboard-transcript-chunk` | 262144 | Bytes read from the end of a transcript per attempt |
| `switchboard-transcript-max-bytes` | 4194304 | Limit the first read grows up to; `+` still reads further back; `nil` for no limit |
| `switchboard-completion-backend` | `auto` | `auto` (consult when installed, else `completing-read`), `consult`, `completing-read` |
| `switchboard-consult-sources` | the three state groups | Sources of `switchboard-consult` (in `switchboard-consult.el`) |
| `switchboard-consult-display-buffer-function` | `pop-to-buffer-same-window` | How the session chosen in the picker (or in `consult-buffer`) is shown; the selected window by default, like `consult-buffer` |
| `switchboard-buffer-name` | `"*switchboard*"` | Name of the list buffer |

### Instant refresh from a Claude Code hook (optional)

Polling alone works. For updates within a second of the event, let Claude
Code nudge Emacs: run `M-x switchboard-hook-settings` and merge the `hooks`
member it shows (also copied to the kill ring) into the top level of
`~/.claude/settings.json`; if `Stop` or `Notification` already exist there,
append the entry to those arrays rather than replacing them. It registers
[`bin/switchboard-hook`](bin/switchboard-hook) for both events. The script
needs `bash`; with `jq` it passes the session id as a hint, without it Emacs
simply refreshes everything. It runs
`emacsclient -e '(switchboard-refresh ...)'` detached and always exits 0, so
a frozen or absent Emacs never slows a session down; Switchboard re-fetches
the list itself, the hook carries no state. Set `SWITCHBOARD_SOCKET` in the
hook's environment if your Emacs server uses a named socket.

### Keys inside the attached terminal

Attached buffers get `switchboard-attach-mode`, which binds `S-<return>` to
`switchboard-send-newline`: in eat and vterm it writes the CSI u encoding of
Shift+Return (`switchboard-newline-sequence`) to the pty, which Claude Code
reads as a newline in its prompt; in ghostel it goes through ghostel's own
key encoder. `switchboard-attach-hook` runs in every new attached buffer;
use it for buffer-local tweaks your input-method or key-chord packages need
(for example, a package that intercepts `C-c` to switch input methods should
be disabled there so that `C-c C-c` reaches Claude).

With the eat backend the buffer starts in eat's semi-char mode: printable
keys, arrows, `RET`, `TAB` and `ESC` go to Claude Code, while `C-c` and
`C-g` stay Emacs prefixes (`C-c C-c` sends an interrupt; `C-c M-d` switches
to char mode where everything goes through). `Ctrl+Z` detaches. In a
terminal Emacs, what arrives depends on the outer terminal; if keys do not
reach the session, point `switchboard-attach-function` at your own terminal
multiplexer for `(not (display-graphic-p))` frames, as in the example above.

## Troubleshooting

- **`⚠` in the lamp**: the last fetch failed; hover it, or look at
  `*Messages*`. Usually `claude` is not on `exec-path` in a GUI Emacs: set
  `switchboard-claude-program` to the absolute path.
- **"no transcript found"**: the session has not written a transcript yet
  (nothing was sent to it), or `switchboard-projects-directory` is not where
  this Claude Code keeps them.
- **The list is empty but agent view shows sessions**: they are older than
  `switchboard-done-retention`; press `A`.
- **Nothing happens on a transition**: hooks only run for transitions seen
  after the first snapshot. Sessions already blocked at startup light the
  lamp but do not notify.
- **Emacs freezes when attaching to a busy session**: you are on the eat
  backend. eat is pure Emacs Lisp and cannot keep up with a working session's
  redraws and transcript replay (Emacs sits in `eat--t-write` for minutes,
  and `C-g` does not help). Install vterm; `auto` then picks it.
- **Agent view garbles after you attach from Emacs** (or the other way
  round): a session has one pty and its size follows whichever client
  attached last, so the other client keeps drawing output meant for a
  different width. This is how Claude Code's supervisor works; Switchboard
  cannot see other clients. Recover in agent view with `←` and `Enter` on the
  row again (re-attaching resends its size), or resize that terminal window.
  Avoid keeping the same session open in two places.
- **A session never becomes `done`**: `done` is what a background job reports
  when it finishes its task. A session that simply ends its turn with a reply
  stays `blocked` (waiting for your next message), and its `Waiting` column
  is empty unless it is inside a tool prompt such as a question dialog or a
  permission request. Measured with Claude Code 2.1.274; its documentation
  describes a session that is ready for your next prompt as `done`, so newer
  versions may report that instead. Switchboard treats both the same way.

## How it works

`claude agents --json --all` is the only source of truth. Each refresh starts
it as an asynchronous process, joins its stdout and stderr, parses the JSON
into `switchboard-agent` structs and diffs the states by session id. Refreshes
requested while one is in flight coalesce into a single follow-up; a fetch
that hangs, or whose stderr a daemon keeps open, is cut off after a timeout.
Everything else (list, lamp, completion) reads the latest snapshot.

Notifications are derived from differences between snapshots, so a state
that is never sampled is invisible: a `blocked` → `working` → `blocked`
round trip can leave both snapshots at `blocked`, even when the final `Stop`
event triggers an immediate refresh. The lamp then stays lit and
`switchboard-state-change-functions` does not run again. The hook script
cuts the latency of end-state changes to well under a second, but cannot
recover intermediate states that were never observed; a refresh re-fetches
the whole list and does not use the event's type.

## Development

```sh
emacs -Q --batch --eval '(setq byte-compile-error-on-warn t)' -f batch-byte-compile switchboard.el
emacs -Q --batch -L . -l switchboard.el -l test/switchboard-test.el -f ert-run-tests-batch-and-exit
```

The tests use `test/fake-claude.sh` in place of the real CLI, so they run
without Claude Code installed. The consult and Embark tests are skipped
unless those packages are on the load path (`-L`); CI runs the suite both
ways, and also `checkdoc` and `package-lint`.

## License

GPL-3.0-or-later. See [LICENSE](LICENSE).
