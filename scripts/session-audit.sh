#!/usr/bin/env bash
# tmux-claude: Audit live panes for restore readiness.

set -euo pipefail

CURRENT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# shellcheck source=../lib/restore_readiness.sh
. "$CURRENT_DIR/lib/restore_readiness.sh"

adapters_load "$CURRENT_DIR"

status=0
printf '%-12s %-18s %-8s %-10s %-38s %s\n' "TARGET" "WINDOW" "TOOL" "KIND" "SID" "FLAGS"

while IFS= read -r session || [ -n "$session" ]; do
    [ -n "$session" ] || continue

    while IFS= read -r win || [ -n "$win" ]; do
        [ -n "$win" ] || continue

        while IFS= read -r pane || [ -n "$pane" ]; do
            [ -n "$pane" ] || continue

            target="$session:$win.$pane"
            restore_readiness_pane "$target" audit 2>/dev/null || continue

            case "$RESTORE_READY_TOOL:$RESTORE_READY_SID_KIND" in
                claude:picker|codex:picker|claude:none|codex:none)
                    status=1
                    ;;
            esac
            if restore_readiness_flag_has "$RESTORE_READY_FLAGS" sid_invalid; then
                status=1
            fi

            printf '%-12s %-18s %-8s %-10s %-38s %s\n' \
                "$RESTORE_READY_TARGET" \
                "$RESTORE_READY_WNAME" \
                "$RESTORE_READY_TOOL" \
                "$RESTORE_READY_SID_KIND" \
                "$RESTORE_READY_SID" \
                "$RESTORE_READY_FLAGS"
        done < <(tmux list-panes -t "$session:$win" -F '#{pane_index}' 2>/dev/null || true)
    done < <(tmux list-windows -t "$session" -F '#{window_index}' 2>/dev/null || true)
done < <(tmux list-sessions -F '#{session_name}' 2>/dev/null || true)

exit "$status"
