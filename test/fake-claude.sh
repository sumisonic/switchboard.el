#!/bin/sh
# Stand-in for the `claude` CLI used by the test suite.
#   FAKE_CLAUDE_JSON    what `agents --json --all` prints to stdout (default: [])
#   FAKE_CLAUDE_STDERR  text written to stderr before exiting
#   FAKE_CLAUDE_EXIT    exit status (default: 0)
#   FAKE_CLAUDE_DELAY   seconds to sleep before answering (default: 0)
#   FAKE_CLAUDE_HOLD_STDERR  seconds a background child keeps stderr open
#                       after this script exits (simulates a daemon)
#   FAKE_CLAUDE_ECHO_CWD  non-empty appends " cwd=$PWD" to non-agents output
# Anything but `agents` prints the arguments back and exits 0.
[ -n "${FAKE_CLAUDE_DELAY:-}" ] && sleep "$FAKE_CLAUDE_DELAY"
[ -n "${FAKE_CLAUDE_HOLD_STDERR:-}" ] && { sleep "$FAKE_CLAUDE_HOLD_STDERR" >&2 & }
[ -n "${FAKE_CLAUDE_STDERR:-}" ] && printf '%s\n' "$FAKE_CLAUDE_STDERR" >&2
case "$1" in
  agents) printf '%s' "${FAKE_CLAUDE_JSON:-[]}" ;;
  *) printf 'fake-claude'
     for arg in "$@"; do printf ' [%s]' "$arg"; done
     [ -n "${FAKE_CLAUDE_ECHO_CWD:-}" ] && printf ' cwd=%s' "$PWD" ;;
esac
exit "${FAKE_CLAUDE_EXIT:-0}"
