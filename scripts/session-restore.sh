#!/usr/bin/env bash
# tmux-claude: Post-restore hook for tmux-resurrect
# Resume Claude/Codex/nvim/just sessions using pane mapping from session-save.sh.
#
# Format: session:window.pane|tool|session_id|cwd|window_name
#
# Claude  → ccy --resume <uuid>   (fish alias for claude --dangerously-skip-permissions)
# Codex   → cxy resume <uuid>     (fish alias for codex --yolo -s workspace-write)
# nvim    → nvim
# just    → just <recipe>
#
# Supports --dry-run to preview commands without executing.

set -euo pipefail

RESURRECT_DIR=$(tmux show-option -gqv @resurrect-dir 2>/dev/null)
RESURRECT_DIR="${RESURRECT_DIR:-$HOME/.tmux/resurrect}"
RESURRECT_DIR="${RESURRECT_DIR/#\~/$HOME}"

PANE_MAP="${RESURRECT_DIR}/claude-panes.txt"
DRY_RUN=false
[ "${1:-}" = "--dry-run" ] && DRY_RUN=true

[ -f "$PANE_MAP" ] || exit 0
[ -s "$PANE_MAP" ] || exit 0

sleep 1

send() {
    local target="$1"
    shift
    if $DRY_RUN; then
        printf "  [dry-run] tmux send-keys -t %-10s '%s'\n" "$target" "$*"
    else
        sleep 0.3
        tmux send-keys -t "$target" "$*" Enter 2>/dev/null || true
    fi
}

picker_count=0

while IFS='|' read -r target tool sid cwd wname; do
    [[ "$target" =~ ^#.*$ ]] && continue
    [ -z "$target" ] && continue

    printf "%-12s %-8s %-6s %s\n" "$target" "($wname)" "$tool" "$sid"

    # Build a stable --name from window name + pane index (if multi-pane)
    pane_idx="${target##*.}"
    pane_count=$(tmux list-panes -t "${target%.*}" -F x 2>/dev/null | wc -l | tr -d ' ') || pane_count=1

    # If saved window name is a default shell name, use pane coordinates instead
    use_wname="$wname"
    case "$wname" in
        fish|bash|zsh|sh|dash|tcsh|csh|ksh|nu|nushell|pwsh|"")
            use_wname="${target%.*}" ;;
    esac

    if [ "${pane_count:-1}" -gt 1 ]; then
        session_name="${use_wname}.${pane_idx}"
    else
        session_name="${use_wname}"
    fi
    # Sanitize: keep only safe chars, replace everything else with hyphens
    session_name=$(printf '%s' "$session_name" | sed 's/[^A-Za-z0-9_.:-]/-/g')

    safe_cwd=$(printf '%q' "$cwd")
    safe_sid=$(printf '%q' "$sid")

    case "$tool" in
        claude)
            if [ "$sid" = "picker" ]; then
                send "$target" "cd $safe_cwd && ccy --name $session_name --resume"
                picker_count=$((picker_count + 1))
            else
                send "$target" "cd $safe_cwd && ccy --name $session_name --resume $safe_sid"
            fi
            ;;
        codex)
            if [ "$sid" = "picker" ]; then
                send "$target" "cd $safe_cwd && cxy resume"
                picker_count=$((picker_count + 1))
            else
                send "$target" "cd $safe_cwd && cxy resume $safe_sid"
            fi
            ;;
        nvim)
            send "$target" "cd $safe_cwd && nvim"
            ;;
        just)
            send "$target" "cd $safe_cwd && just $safe_sid"
            ;;
    esac
done < "$PANE_MAP"

if $DRY_RUN; then
    echo ""
    if [ $picker_count -gt 0 ]; then
        echo "Done! $picker_count session(s) need manual picker selection."
    else
        echo "Done! All sessions resumed directly."
    fi
fi
