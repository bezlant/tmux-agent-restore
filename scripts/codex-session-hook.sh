#!/usr/bin/env bash
# Codex SessionStart hook: writes session ID and agent PID to tmux pane variables.
# Used by session-save.sh to map panes to sessions for restore after reboot.

set -euo pipefail

[ -n "${TMUX:-}" ] || exit 0
[ -n "${TMUX_PANE:-}" ] || exit 0

PLUGIN_DIR="${TMUX_AGENT_RESTORE_PLUGIN_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"

# shellcheck source=../lib/process.sh
[ -f "$PLUGIN_DIR/lib/process.sh" ] && . "$PLUGIN_DIR/lib/process.sh"
# shellcheck source=../lib/session_hook.sh
. "$PLUGIN_DIR/lib/session_hook.sh"

session_hook_run codex claude @codex_session_id @codex_session_pid @codex_cwd "$PLUGIN_DIR" "$0"
