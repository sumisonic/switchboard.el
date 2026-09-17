# Changelog

All notable changes to this project are documented here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/).

## [Unreleased]

## [0.1.0] - 2026-09-17

### Added

- `switchboard-watch-mode`: polls `claude agents --json --all`, diffs
  snapshots, runs `switchboard-state-change-functions` on transitions into
  `blocked`, `done` or `failed`, and shows a mode-line lamp.
- `switchboard`: a `tabulated-list-mode` buffer of background sessions, most
  urgent first, with acknowledge and show-all.
- `switchboard-transcript`: the session's conversation as Markdown, read
  from the tail of the transcript Claude Code keeps (works for finished
  sessions, no terminal emulation), shown scrolled to its end; the first
  read grows up to `switchboard-transcript-max-bytes`.
- `switchboard-attach`: `claude attach <id>` in a ghostel, vterm or eat
  buffer, or through a user-supplied function; buffers are reused per
  session.
- `switchboard-dispatch`, `switchboard-stop`, `switchboard-respawn`,
  `switchboard-remove`.
- Session selection with `completing-read` (category `switchboard-agent`)
  and `switchboard-embark-setup` for Embark actions.
- `switchboard-consult.el`: `switchboard-consult`, a picker grouped by state
  (Needs you / Working / Finished, narrow `b` `w` `d`) that previews the
  highlighted session's transcript, or its attached terminal buffer;
  `switchboard-consult-source` for `consult-buffer-sources`;
  `switchboard-completion-backend` (`auto`: consult when installed) so that
  every command reading a session gets the preview.
- Embark: a target finder makes the session at point in the list, in a
  transcript buffer or in an attached buffer a target; `d` dispatch in the
  session's directory (`switchboard-dispatch-here`), `j` Dired there
  (`switchboard-dired`), `w` copy its id (`switchboard-copy-id`); `RET` as
  the default action; `embark-general-map` behind the session map. The
  `r` respawn action was dropped from the map (the list keeps it).
- Completion candidates carry the face of the session's state.
- `switchboard-display-buffer-function` (default `pop-to-buffer`) decides how
  attach and transcript buffers are shown; the consult picker uses
  `switchboard-consult-display-buffer-function` (default
  `pop-to-buffer-same-window`, as `consult-buffer` does).
- `bin/switchboard-hook` and `switchboard-hook-settings` for instant
  refreshes from Claude Code hooks.
- `switchboard-terminal-backend` defaults to `auto`: the first of ghostel,
  vterm and eat that is installed (eat stalls on busy sessions).
- ghostel backend (`ghostel-exec`; Shift+Return through `ghostel-send-key`).
- `switchboard-attach-mode` in attached buffers: `S-<return>` inserts a
  newline in the Claude prompt; `switchboard-attach-hook` for buffer-local
  setup.
