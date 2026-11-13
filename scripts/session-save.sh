#!/usr/bin/env bash
# tmux-agent-restore: Post-save hook for tmux-resurrect.

set -euo pipefail

CURRENT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# shellcheck source=../lib/snapshot.sh
. "$CURRENT_DIR/lib/snapshot.sh"
# shellcheck source=../lib/restore_readiness.sh
. "$CURRENT_DIR/lib/restore_readiness.sh"

RESURRECT_DIR=$(tmux show-option -gqv @resurrect-dir 2>/dev/null || true)
RESURRECT_DIR="${RESURRECT_DIR:-$HOME/.tmux/resurrect}"
RESURRECT_DIR="${RESURRECT_DIR/#\~/$HOME}"

PANE_MAP="${RESURRECT_DIR}/claude-panes.txt"
MAX_SAVES=${TMUX_AGENT_RESTORE_MAX_SAVES:-20}
LOCK_DIR="${RESURRECT_DIR}/.claude-save.lock"
LOCK_TOKEN=""
tmpfile=""

save_cleanup() {
    [ -n "${tmpfile:-}" ] && rm -f "$tmpfile"
    if [ -n "${LOCK_TOKEN:-}" ] &&
        [ -f "$LOCK_DIR/token" ] &&
        [ "$(cat "$LOCK_DIR/token" 2>/dev/null || true)" = "$LOCK_TOKEN" ]; then
        rm -rf "$LOCK_DIR"
    fi
}

save_lock_mtime() {
    local raw

    raw=$(stat -f %m "$LOCK_DIR" 2>/dev/null || true)
    case "$raw" in
        ''|*[!0-9]*) ;;
        *) printf '%s\n' "$raw"; return 0 ;;
    esac

    raw=$(stat -c %Y "$LOCK_DIR" 2>/dev/null || true)
    case "$raw" in
        ''|*[!0-9]*) return 1 ;;
        *) printf '%s\n' "$raw"; return 0 ;;
    esac
}

save_lock_process_is_save() {
    local pid="$1"
    local command

    command=$(ps -p "$pid" -o command= 2>/dev/null || true)
    case "$command" in
        *session-save.sh*) return 0 ;;
        *) return 1 ;;
    esac
}

save_lock_is_old_enough() {
    local stale_seconds raw_mtime now age

    stale_seconds="${TMUX_AGENT_RESTORE_SAVE_LOCK_STALE_SECONDS:-300}"
    case "$stale_seconds" in
        ''|*[!0-9]*) stale_seconds=300 ;;
    esac

    raw_mtime=$(save_lock_mtime) || return 1

    now=$(date +%s)
    age=$((now - raw_mtime))
    [ "$age" -ge "$stale_seconds" ]
}

save_lock_reclaim_if_stale() {
    local stale_pid

    [ -d "$LOCK_DIR" ] || return 1

    stale_pid=$(cat "$LOCK_DIR/pid" 2>/dev/null || true)
    case "$stale_pid" in
        ''|*[!0-9]*)
            save_lock_is_old_enough || return 1
            ;;
        *)
            if kill -0 "$stale_pid" 2>/dev/null; then
                save_lock_is_old_enough || return 1
                if save_lock_process_is_save "$stale_pid"; then
                    return 1
                fi
            fi
            ;;
    esac

    rm -rf "$LOCK_DIR"
}

save_lock_acquire() {
    local attempts=0 max_attempts

    max_attempts="${TMUX_AGENT_RESTORE_SAVE_LOCK_ATTEMPTS:-10}"
    case "$max_attempts" in
        ''|*[!0-9]*) max_attempts=10 ;;
    esac

    while ! mkdir "$LOCK_DIR" 2>/dev/null; do
        save_lock_reclaim_if_stale || true
        attempts=$((attempts + 1))
        [ "$attempts" -ge "$max_attempts" ] && return 1
        sleep 0.5
    done

    LOCK_TOKEN="$$_$(date +%s)_${RANDOM:-0}_${RANDOM:-0}"
    if ! printf '%s\n' "$$" > "$LOCK_DIR/pid" 2>/dev/null ||
        ! printf '%s\n' "$LOCK_TOKEN" > "$LOCK_DIR/token" 2>/dev/null; then
        rm -rf "$LOCK_DIR"
        LOCK_TOKEN=""
        return 1
    fi
}

mkdir -p "$RESURRECT_DIR"

save_lock_acquire || exit 0
trap save_cleanup EXIT HUP INT TERM

if [ -d "$RESURRECT_DIR" ]; then
    (cd "$RESURRECT_DIR" && ls -t tmux_resurrect_*.txt 2>/dev/null | tail -n +$((MAX_SAVES + 1)) | xargs rm -f 2>/dev/null) || true
fi

adapters_load "$CURRENT_DIR"

tmpfile=$(mktemp "${PANE_MAP}.XXXXXX")
snapshot_write_header > "$tmpfile"

pane_count=0

# SessionStart hooks can briefly overlap their async save. If process
# inspection sees a transient hook helper, validation may degrade a row to
# picker/none; a later save corrects it once the hook subtree is gone.
while IFS= read -r session || [ -n "$session" ]; do
    [ -n "$session" ] || continue

    while IFS= read -r win || [ -n "$win" ]; do
        [ -n "$win" ] || continue

        while IFS= read -r pane || [ -n "$pane" ]; do
            [ -n "$pane" ] || continue

            target="$session:$win.$pane"
            restore_readiness_pane "$target" 2>/dev/null || continue

            snapshot_write_row \
                "$RESTORE_READY_TARGET" \
                "$RESTORE_READY_TOOL" \
                "$RESTORE_READY_SID" \
                "$RESTORE_READY_SID_KIND" \
                "$RESTORE_READY_CWD" \
                "$RESTORE_READY_ORIGINAL_CWD" \
                "$RESTORE_READY_WNAME" \
                "$RESTORE_READY_FLAGS" >> "$tmpfile"
            pane_count=$((pane_count + 1))
        done < <(tmux list-panes -t "$session:$win" -F '#{pane_index}' 2>/dev/null || true)
    done < <(tmux list-windows -t "$session" -F '#{window_index}' 2>/dev/null || true)
done < <(tmux list-sessions -F '#{session_name}' 2>/dev/null || true)

if [ "$pane_count" -eq 0 ]; then
    rm -f "$tmpfile"
    tmpfile=""
    exit 0
fi

mv "$tmpfile" "$PANE_MAP"
tmpfile=""
