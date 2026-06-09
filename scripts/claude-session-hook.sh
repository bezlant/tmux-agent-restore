#!/usr/bin/env bash
# Claude Code SessionStart hook: writes session ID and agent PID to tmux pane variables.
# Used by session-save.sh to map panes to sessions for restore after reboot.

set -euo pipefail

[ -n "${TMUX:-}" ] || exit 0
[ -n "${TMUX_PANE:-}" ] || exit 0

PLUGIN_DIR="${TMUX_CLAUDE_PLUGIN_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
if [ -f "$PLUGIN_DIR/lib/process.sh" ]; then
    # shellcheck source=../lib/process.sh
    . "$PLUGIN_DIR/lib/process.sh"
fi

hook_command_matches_self() {
    local command="$1"
    local hook_path="$0"
    local hook_name="${hook_path##*/}"

    case "$command" in
        *"$hook_path"*|*"/$hook_name"*) return 0 ;;
        *) return 1 ;;
    esac
}

non_hook_agent_parent_pid() {
    local pid="$1"
    local tool="$2"
    local parent command

    while [ -n "$pid" ]; do
        parent=$(ps -p "$pid" -o ppid= 2>/dev/null | awk 'NR == 1 { print $1 }')
        [ -n "$parent" ] || return 1
        [ "$parent" != "$pid" ] || return 1

        command=$(process_command "$parent" 2>/dev/null || true)
        if [ -n "$command" ] && ! hook_command_matches_self "$command"; then
            case "$command" in
                *"$tool"*) printf '%s\n' "$parent"; return 0 ;;
            esac
        fi
        pid="$parent"
    done

    return 1
}

pid_in_hook_subtree() {
    local pid="$1"
    local parent command

    while [ -n "$pid" ]; do
        command=$(process_command "$pid" 2>/dev/null || true)
        if [ -n "$command" ] && hook_command_matches_self "$command"; then
            return 0
        fi

        parent=$(ps -p "$pid" -o ppid= 2>/dev/null | awk 'NR == 1 { print $1 }')
        [ -n "$parent" ] || return 1
        [ "$parent" != "$pid" ] || return 1
        pid="$parent"
    done

    return 1
}

input=$(cat)
session_id=$(printf '%s\n' "$input" | python3 -c "import sys,json; print(json.load(sys.stdin).get('session_id',''))" 2>/dev/null || true)

[ -n "$session_id" ] || exit 0

pane_cmd=$(tmux display-message -p -t "$TMUX_PANE" '#{pane_current_command}' 2>/dev/null || true)
case "$pane_cmd" in
    codex|Codex) exit 0 ;;
esac

tmux set-option -p -t "$TMUX_PANE" @claude_session_id "$session_id" 2>/dev/null || true
if declare -F live_agent_pid >/dev/null 2>&1; then
    agent_pid=$(live_agent_pid "$TMUX_PANE" claude 2>/dev/null || true)
    if [ -n "$agent_pid" ] && declare -F process_command >/dev/null 2>&1; then
        if pid_in_hook_subtree "$agent_pid"; then
            agent_pid=$(non_hook_agent_parent_pid "$agent_pid" claude 2>/dev/null || true)
        fi
    fi
    if [ -n "$agent_pid" ]; then
        tmux set-option -p -t "$TMUX_PANE" @claude_session_pid "$agent_pid" 2>/dev/null || true
    fi
fi
tmux set-option -pu -t "$TMUX_PANE" @codex_session_id 2>/dev/null || true
tmux set-option -pu -t "$TMUX_PANE" @codex_cwd 2>/dev/null || true
tmux set-option -pu -t "$TMUX_PANE" @codex_session_pid 2>/dev/null || true

cwd=$(printf '%s\n' "$input" | python3 -c "import sys,json; print(json.load(sys.stdin).get('cwd',''))" 2>/dev/null || true)
[ -n "$cwd" ] && tmux set-option -p -t "$TMUX_PANE" @claude_cwd "$cwd" 2>/dev/null || true

[ -x "$PLUGIN_DIR/scripts/session-save.sh" ] && bash "$PLUGIN_DIR/scripts/session-save.sh" >> /tmp/tmux-claude-save.log 2>&1 &

exit 0
