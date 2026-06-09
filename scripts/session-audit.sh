#!/usr/bin/env bash
# tmux-claude: Audit live panes for restore readiness.

set -euo pipefail

CURRENT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# shellcheck source=../lib/adapters.sh
. "$CURRENT_DIR/lib/adapters.sh"

audit_field() {
    local row="$1"
    local field="$2"
    printf '%s\n' "$row" | awk -F '\t' -v field="$field" 'NR == 1 { print $field }'
}

audit_add_flag() {
    local current="$1"
    local flag="$2"

    if [ -n "$current" ]; then
        printf '%s;%s\n' "$current" "$flag"
    else
        printf '%s\n' "$flag"
    fi
}

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
            detect_row=""
            for adapter in $(adapters_list); do
                detect_fn="${adapter}_detect"
                if declare -F "$detect_fn" >/dev/null 2>&1 &&
                    detect_row=$("$detect_fn" "$target" 2>/dev/null); then
                    [ -n "$detect_row" ] && break
                fi
                detect_row=""
            done
            [ -n "$detect_row" ] || continue

            tool=$(audit_field "$detect_row" 1)
            sid=$(audit_field "$detect_row" 2)
            sid_kind=$(audit_field "$detect_row" 3)
            flags=$(audit_field "$detect_row" 5)
            wname=$(tmux display-message -p -t "$target" '#{window_name}' 2>/dev/null || true)

            if [ "$sid_kind" = "uuid" ]; then
                validate_fn="${tool}_validate"
                if ! declare -F "$validate_fn" >/dev/null 2>&1 ||
                    ! "$validate_fn" "$sid" "$sid_kind" >/dev/null 2>&1; then
                    flags=$(audit_add_flag "$flags" sid_invalid)
                    status=1
                fi
            fi

            case "$tool:$sid_kind" in
                claude:picker|codex:picker|claude:none|codex:none)
                    status=1
                    ;;
            esac

            printf '%-12s %-18s %-8s %-10s %-38s %s\n' "$target" "$wname" "$tool" "$sid_kind" "$sid" "$flags"
        done < <(tmux list-panes -t "$session:$win" -F '#{pane_index}' 2>/dev/null || true)
    done < <(tmux list-windows -t "$session" -F '#{window_index}' 2>/dev/null || true)
done < <(tmux list-sessions -F '#{session_name}' 2>/dev/null || true)

exit "$status"
