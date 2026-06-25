#!/usr/bin/env bash
set -euo pipefail

if [ -z "${TMUX:-}" ] || [ -z "${TMUX_PANE:-}" ]; then
    exit 0
fi

tmux_resume=0
script_dir=$(CDPATH= cd -- "$(dirname "${BASH_SOURCE[0]}")" && pwd)
for arg in "$@"; do
    case "$arg" in
        --tmux-resume)
            tmux_resume=1
            ;;
        --name|--name=*|--resume|-r|--resume=*|--continue|-c|--continue=*|--print|-p|--print=*)
            exit 0
            ;;
    esac
done

if [ "${TMUX_CLAUDE_AUTO_RESUME:-}" = "1" ]; then
    tmux_resume=1
fi

wname=$(tmux display-message -p -t "$TMUX_PANE" '#{window_name}' 2>/dev/null || true)
pane_count=$(tmux display-message -p -t "$TMUX_PANE" '#{window_panes}' 2>/dev/null || true)
pane=$(tmux display-message -p -t "$TMUX_PANE" '#{pane_index}' 2>/dev/null || true)

case "$wname" in
    ""|fish|bash|zsh|sh|dash|tcsh|csh|ksh|nu|nushell|pwsh)
        sess=$(tmux display-message -p -t "$TMUX_PANE" '#{session_name}' 2>/dev/null || true)
        win=$(tmux display-message -p -t "$TMUX_PANE" '#{window_index}' 2>/dev/null || true)
        if [ -z "$sess" ] || [ -z "$win" ]; then
            exit 0
        fi
        wname="$sess:$win"
        ;;
esac

if [ -z "$wname" ]; then
    exit 0
fi

name="$wname"
if [ -n "$pane_count" ] && [ "$pane_count" -gt 1 ] 2>/dev/null && [ -n "$pane" ]; then
    name="$wname.$pane"
fi
name=$(printf '%s' "$name" | LC_ALL=C tr -c 'A-Za-z0-9_.:-' '-')

if [ "$tmux_resume" -eq 1 ] && [ -n "${HOME:-}" ]; then
    finder="$script_dir/claude-find-session.py"
    project_dir="$HOME/.claude/projects/$(pwd | tr '/.' '--')"
    if [ -x "$finder" ]; then
        if sid=$(python3 "$finder" "$project_dir" "$name" 2>/dev/null); then
            if [ -n "$sid" ]; then
                printf '%s\n' --resume "$sid" --name "$name"
                exit 0
            fi
        fi
    fi
fi

printf '%s\n' --name "$name"
