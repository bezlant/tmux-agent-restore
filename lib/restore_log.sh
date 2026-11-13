#!/usr/bin/env bash
# tmux-agent-restore: best-effort restore logging.

RESTORE_LOG_FD_OPEN=0
RESTORE_LOG_PATH=""
RESTORE_LOG_MAX_BYTES="${RESTORE_LOG_MAX_BYTES:-1048576}"

restore_log_open() {
    if [ "$RESTORE_LOG_FD_OPEN" -eq 1 ]; then
        exec 9>&- 2>/dev/null || true
    fi
    RESTORE_LOG_PATH="$1"
    RESTORE_LOG_FD_OPEN=0

    local dir size max_bytes
    case "$RESTORE_LOG_PATH" in
        */*) dir="${RESTORE_LOG_PATH%/*}" ;;
        *) dir="." ;;
    esac
    [ -n "$dir" ] || dir="/"
    mkdir -p "$dir" 2>/dev/null || return 0

    if [ -f "$RESTORE_LOG_PATH" ]; then
        size=$(wc -c < "$RESTORE_LOG_PATH" 2>/dev/null | tr -d ' ' || echo 0)
        case "$size" in
            ''|*[!0-9]*) size=0 ;;
        esac
        max_bytes="$RESTORE_LOG_MAX_BYTES"
        case "$max_bytes" in
            ''|*[!0-9]*) max_bytes=1048576 ;;
        esac
        if [ "$size" -gt "$max_bytes" ]; then
            mv "$RESTORE_LOG_PATH" "$RESTORE_LOG_PATH.1" 2>/dev/null || true
        fi
    fi

    { exec 9>>"$RESTORE_LOG_PATH"; } 2>/dev/null || return 0
    RESTORE_LOG_FD_OPEN=1
}

restore_log() {
    local level="$1"
    local message="$2"
    local ts
    [ "$RESTORE_LOG_FD_OPEN" -eq 1 ] || return 0
    ts=$(date '+%Y-%m-%dT%H:%M:%S%z')
    { printf '%s %s %s\n' "$ts" "$level" "$message" >&9; } 2>/dev/null || true
}

restore_log_close() {
    if [ "$RESTORE_LOG_FD_OPEN" -eq 1 ]; then
        exec 9>&- 2>/dev/null || true
    fi
    RESTORE_LOG_FD_OPEN=0
}
