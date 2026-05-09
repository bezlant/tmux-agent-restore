#!/usr/bin/env bash
# tmux-claude: Post-save hook for tmux-resurrect
# 1. Prune old resurrect files (keep last N)
# 2. Record pane→session mapping using tmux pane options set by SessionStart hooks
#    Falls back to process inspection for sessions started before hooks were installed.
#
# Requires SessionStart hooks in Claude Code and Codex that write:
#   @claude_session_id / @claude_cwd  (Claude)
#   @codex_session_id  / @codex_cwd   (Codex)
#
# Format: session:window.pane|tool|session_id|cwd|window_name

set -euo pipefail

RESURRECT_DIR=$(tmux show-option -gqv @resurrect-dir 2>/dev/null)
RESURRECT_DIR="${RESURRECT_DIR:-$HOME/.tmux/resurrect}"
RESURRECT_DIR="${RESURRECT_DIR/#\~/$HOME}"

PANE_MAP="${RESURRECT_DIR}/claude-panes.txt"
MAX_SAVES=${TMUX_CLAUDE_MAX_SAVES:-20}

# Serialize concurrent saves (hooks fire in parallel after /clear in multiple panes)
LOCK_DIR="${RESURRECT_DIR}/.claude-save.lock"
_attempts=0
while ! mkdir "$LOCK_DIR" 2>/dev/null; do
    _attempts=$((_attempts + 1))
    [ $_attempts -ge 10 ] && exit 0
    sleep 0.5
done
# --- Prune old saves ---
if [ -d "$RESURRECT_DIR" ]; then
    (cd "$RESURRECT_DIR" && ls -t tmux_resurrect_*.txt 2>/dev/null | tail -n +$((MAX_SAVES + 1)) | xargs rm -f 2>/dev/null) || true
fi

# --- Build mapping (atomic: write temp, mv on success) ---
tmpfile=$(mktemp "${PANE_MAP}.XXXXXX")
trap 'rm -rf "$LOCK_DIR"; rm -f "$tmpfile"' EXIT

echo "# Claude/Codex session mapping — $(date)" > "$tmpfile"
echo "# Format: session:window.pane|tool|session_id|cwd|window_name" >> "$tmpfile"

pane_count=0

while IFS= read -r session; do
    for win in $(tmux list-windows -t "$session" -F '#{window_index}' 2>/dev/null); do
        wname=$(tmux display-message -p -t "$session:$win" '#{window_name}')
        for pane in $(tmux list-panes -t "$session:$win" -F '#{pane_index}' 2>/dev/null); do
            target="$session:$win.$pane"
            cmd=$(tmux display-message -p -t "$target" '#{pane_current_command}')
            dir=$(tmux display-message -p -t "$target" '#{pane_current_path}')

            claude_sid=$(tmux show-options -p -t "$target" -v @claude_session_id 2>/dev/null || true)
            claude_cwd=$(tmux show-options -p -t "$target" -v @claude_cwd 2>/dev/null || true)
            codex_sid=$(tmux show-options -p -t "$target" -v @codex_session_id 2>/dev/null || true)
            codex_cwd=$(tmux show-options -p -t "$target" -v @codex_cwd 2>/dev/null || true)

            tool=""
            sid=""

            if [ -n "$claude_sid" ]; then
                tool="claude"
                sid="$claude_sid"
            elif [ -n "$codex_sid" ]; then
                tool="codex"
                sid="$codex_sid"
            elif echo "$cmd" | grep -q 'codex'; then
                tool="codex"
                sid="picker"
            elif echo "$cmd" | grep -q 'nvim\|vim'; then
                tool="nvim"
                sid=""
            elif echo "$cmd" | grep -q 'just'; then
                pid=$(tmux display-message -p -t "$target" '#{pane_pid}')
                child_cmd=$(ps -o command= -p $(pgrep -P "$pid" 2>/dev/null | head -1) 2>/dev/null | head -1 || true)
                if echo "$child_cmd" | grep -q 'just'; then
                    tool="just"
                    sid=$(echo "$child_cmd" | sed 's/.*just //' | head -c 50)
                fi
            else
                pid=$(tmux display-message -p -t "$target" '#{pane_pid}')
                child_cmd=$(ps -o command= -p $(pgrep -P "$pid" 2>/dev/null | head -1) 2>/dev/null || true)
                if echo "$child_cmd" | grep -q 'claude'; then
                    tool="claude"
                    sid=$(echo "$child_cmd" | grep -oE '[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}' | head -1 || true)
                    [ -z "$sid" ] && sid="picker"
                fi
            fi

            [ -z "$tool" ] && continue

            case "$tool" in
                claude) use_dir="${claude_cwd:-$dir}" ;;
                codex)  use_dir="${codex_cwd:-$dir}" ;;
                *)      use_dir="$dir" ;;
            esac
            echo "$target|$tool|${sid:-picker}|$use_dir|$wname" >> "$tmpfile"
            pane_count=$((pane_count + 1))
        done
    done
done < <(tmux list-sessions -F '#{session_name}' 2>/dev/null)

if [ "$pane_count" -eq 0 ] && [ -f "$PANE_MAP" ]; then
    rm -f "$tmpfile"
    rm -rf "$LOCK_DIR"
    trap - EXIT
    exit 0
fi

mv "$tmpfile" "$PANE_MAP"
rm -rf "$LOCK_DIR"
trap - EXIT
