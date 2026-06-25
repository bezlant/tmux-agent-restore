#!/usr/bin/env bash
# tmux-claude: Post-restore hook for tmux-resurrect.

set -euo pipefail

CURRENT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# shellcheck source=../lib/restore_log.sh
. "$CURRENT_DIR/lib/restore_log.sh"
# shellcheck source=../lib/tsv.sh
. "$CURRENT_DIR/lib/tsv.sh"

snapshot_log() {
    restore_log "$1" "snapshot $2"
}

# shellcheck source=../lib/snapshot.sh
. "$CURRENT_DIR/lib/snapshot.sh"
# shellcheck source=../lib/adapters.sh
. "$CURRENT_DIR/lib/adapters.sh"
# shellcheck source=../lib/quote.sh
. "$CURRENT_DIR/lib/quote.sh"
# shellcheck source=../lib/restore_helpers.sh
. "$CURRENT_DIR/lib/restore_helpers.sh"
# shellcheck source=../lib/restore_plan.sh
. "$CURRENT_DIR/lib/restore_plan.sh"

RESURRECT_DIR=$(tmux show-option -gqv @resurrect-dir 2>/dev/null || true)
RESURRECT_DIR="${RESURRECT_DIR:-$HOME/.tmux/resurrect}"
RESURRECT_DIR="${RESURRECT_DIR/#\~/$HOME}"

PANE_MAP="${RESURRECT_DIR}/claude-panes.txt"
DRY_RUN=false
[ "${1:-}" = "--dry-run" ] && DRY_RUN=true

[ -f "$PANE_MAP" ] || exit 0
[ -s "$PANE_MAP" ] || exit 0

LOCK_DIR="${RESURRECT_DIR}/.claude-restore.lock"

restore_lock_acquire() {
    local stale_pid

    if mkdir "$LOCK_DIR" 2>/dev/null; then
        printf '%s\n' "$$" > "$LOCK_DIR/pid" 2>/dev/null || true
        return 0
    fi

    stale_pid=$(cat "$LOCK_DIR/pid" 2>/dev/null || true)
    case "$stale_pid" in
        ''|*[!0-9]*)
            return 1
            ;;
    esac

    if kill -0 "$stale_pid" 2>/dev/null; then
        return 1
    fi

    rm -rf "$LOCK_DIR"
    if mkdir "$LOCK_DIR" 2>/dev/null; then
        printf '%s\n' "$$" > "$LOCK_DIR/pid" 2>/dev/null || true
        return 0
    fi

    return 1
}

if ! restore_lock_acquire; then
    restore_log_open "${RESURRECT_DIR}/restore.log"
    restore_log SKIP "restore_already_running lock=$LOCK_DIR"
    restore_log_close
    exit 0
fi

snapshot_tmp=""
argv_tmp=""
cleanup() {
    [ -n "$snapshot_tmp" ] && rm -f "$snapshot_tmp"
    [ -n "$argv_tmp" ] && rm -f "$argv_tmp"
    rm -rf "$LOCK_DIR"
    restore_log_close
}
trap cleanup EXIT HUP INT TERM

snapshot_tmp=$(mktemp "${TMPDIR:-/tmp}/tmux-claude-snapshot.XXXXXX")
argv_tmp=$(mktemp "${TMPDIR:-/tmp}/tmux-claude-argv.XXXXXX")

ok=0
warn=0
skip=0
total=0

restore_log_open "${RESURRECT_DIR}/restore.log"
restore_log BEGIN "pane_map=$PANE_MAP dry_run=$DRY_RUN"

adapters_load "$CURRENT_DIR"

boot_delay="${TMUX_CLAUDE_RESTORE_BOOT_DELAY:-1}"
if [ "$boot_delay" != "0" ]; then
    sleep "$boot_delay"
fi

if ! snapshot_read "$PANE_MAP" > "$snapshot_tmp"; then
    skip=$((skip + 1))
    restore_log SKIP "snapshot snapshot_read_failed pane_map=$PANE_MAP"
    restore_log END "ok=$ok warn=$warn skip=$skip total=$total"
    exit 0
fi

while IFS= read -r row || [ -n "$row" ]; do
    target=
    tool=
    sid=
    sid_kind=
    cwd=
    original_cwd=
    wname=
    flags=

    field_index=0
    while IFS= read -r encoded_field || [ -n "$encoded_field" ]; do
        decoded_field=$(tsv_decode "$encoded_field")
        case "$field_index" in
            0) target="$decoded_field" ;;
            1) tool="$decoded_field" ;;
            2) sid="$decoded_field" ;;
            3) sid_kind="$decoded_field" ;;
            4) cwd="$decoded_field" ;;
            5) original_cwd="$decoded_field" ;;
            6) wname="$decoded_field" ;;
            7) flags="$decoded_field" ;;
        esac
        field_index=$((field_index + 1))
    done < <(snapshot_split_row "$row")

    if [ "$field_index" -lt 8 ]; then
        skip=$((skip + 1))
        restore_log SKIP "malformed_snapshot_row fields=$field_index"
        continue
    fi

    total=$((total + 1))
    log_target=$(restore_log_value "$target")
    log_tool=$(restore_log_value "$tool")
    log_sid=$(restore_log_value "$sid")
    log_cwd=$(restore_log_value "$cwd")
    log_original_cwd=$(restore_log_value "$original_cwd")
    log_wname=$(restore_log_value "$wname")

    if restore_flag_has "$flags" sid_invalid; then
        skip=$((skip + 1))
        restore_log SKIP "$log_target $log_tool sid_invalid"
        continue
    fi
    if ! restore_sid_valid "$sid" "$sid_kind"; then
        skip=$((skip + 1))
        restore_log SKIP "$log_target $log_tool invalid_sid"
        continue
    fi

    restore_plan_build "$target" "$tool" "$sid" "$sid_kind" "$cwd" "$original_cwd" "$wname" "$flags" "$argv_tmp"

    case "$RESTORE_PLAN_STATUS" in
        ok)
            target="$RESTORE_PLAN_TARGET"
            tool="$RESTORE_PLAN_TOOL"
            full="$RESTORE_PLAN_FULL"
            log_target=$(restore_log_value "$target")
            log_tool=$(restore_log_value "$tool")
            printf "%-12s %-8s %-8s %s\n" "$log_target" "($log_wname)" "$log_tool" "$log_sid"
            ;;
        skip)
            skip_target="$RESTORE_PLAN_TARGET"
            skip_tool="$RESTORE_PLAN_TOOL"
            skip_reason="$RESTORE_PLAN_REASON"
            log_target=$(restore_log_value "$skip_target")
            log_tool=$(restore_log_value "$skip_tool")

            case "$skip_reason" in
                missing_adapter|adapter_error|quote_argv_failed)
                    printf "%-12s %-8s %-8s %s\n" "$log_target" "($log_wname)" "$log_tool" "$log_sid"
                    ;;
            esac

            skip=$((skip + 1))
            case "$skip_reason" in
                window_mismatch)
                    log_current_wname=$(restore_log_value "$RESTORE_PLAN_CURRENT_WNAME")
                    restore_log SKIP "$log_target $log_tool window_mismatch current=$log_current_wname saved=$log_wname"
                    ;;
                missing_adapter)
                    restore_log SKIP "target=$log_target tool=$log_tool missing_adapter"
                    ;;
                quote_argv_failed)
                    restore_log SKIP "target=$log_target tool=$log_tool quote_argv_failed"
                    ;;
                *)
                    restore_log SKIP "$log_target $log_tool $skip_reason"
                    ;;
            esac
            continue
            ;;
        *)
            skip=$((skip + 1))
            restore_log SKIP "$log_target $log_tool restore_plan_invalid"
            continue
            ;;
    esac

    if $DRY_RUN; then
        display_full=$(restore_log_value "$full")
        printf "  [dry-run] %s: %s\n" "$log_target" "$display_full"
        if restore_flag_has "$flags" cwd_collapsed; then
            warn=$((warn + 1))
            restore_log WARN "$log_target $log_tool cwd_collapsed orig=$log_original_cwd new=$log_cwd"
        else
            ok=$((ok + 1))
            restore_log OK "target=$log_target tool=$log_tool dry_run=1"
        fi
        continue
    fi

    if ! wait_for_prompt "$target"; then
        skip=$((skip + 1))
        restore_log SKIP "$log_target $log_tool prompt_wait_timeout"
        continue
    fi

    if ! restore_send_keys "$target" "$full"; then
        warn=$((warn + 1))
        restore_log WARN "$log_target $log_tool send_keys_failed"
        continue
    fi

    if restore_flag_has "$flags" cwd_collapsed; then
        warn=$((warn + 1))
        restore_log WARN "$log_target $log_tool cwd_collapsed orig=$log_original_cwd new=$log_cwd"
    else
        ok=$((ok + 1))
        restore_log OK "$log_target $log_tool $log_sid"
    fi
done < "$snapshot_tmp"

restore_log END "ok=$ok warn=$warn skip=$skip total=$total"

if $DRY_RUN; then
    echo ""
    echo "Done! ok=$ok warn=$warn skip=$skip total=$total"
fi
