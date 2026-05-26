#!/usr/bin/env bash
# Codex SessionStart hook: writes session ID to tmux pane variable.
# Used by session-save.sh to map panes to sessions for restore after reboot.

set -euo pipefail

[ -n "${TMUX:-}" ] || exit 0
[ -n "${TMUX_PANE:-}" ] || exit 0

input=$(cat)
session_id=$(echo "$input" | python3 -c "import sys,json; print(json.load(sys.stdin).get('session_id',''))" 2>/dev/null || true)

[ -n "$session_id" ] || exit 0

pane_cmd=$(tmux display-message -p -t "$TMUX_PANE" '#{pane_current_command}' 2>/dev/null || true)
if echo "$pane_cmd" | grep -qi 'claude'; then
    exit 0
fi

tmux set-option -p -t "$TMUX_PANE" @codex_session_id "$session_id" 2>/dev/null || true
tmux set-option -pu -t "$TMUX_PANE" @claude_session_id 2>/dev/null || true
tmux set-option -pu -t "$TMUX_PANE" @claude_cwd 2>/dev/null || true

cwd=$(echo "$input" | python3 -c "import sys,json; print(json.load(sys.stdin).get('cwd',''))" 2>/dev/null || true)
[ -n "$cwd" ] && tmux set-option -p -t "$TMUX_PANE" @codex_cwd "$cwd" 2>/dev/null || true

PLUGIN_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
[ -x "$PLUGIN_DIR/scripts/session-save.sh" ] && bash "$PLUGIN_DIR/scripts/session-save.sh" >> /tmp/tmux-claude-save.log 2>&1 &

exit 0
