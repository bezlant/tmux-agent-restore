#!/usr/bin/env bash
# tmux-claude: Post-save hook for tmux-resurrect.

set -euo pipefail

CURRENT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# shellcheck source=../lib/snapshot.sh
. "$CURRENT_DIR/lib/snapshot.sh"
# shellcheck source=../lib/adapters.sh
. "$CURRENT_DIR/lib/adapters.sh"

RESURRECT_DIR=$(tmux show-option -gqv @resurrect-dir 2>/dev/null || true)
RESURRECT_DIR="${RESURRECT_DIR:-$HOME/.tmux/resurrect}"
RESURRECT_DIR="${RESURRECT_DIR/#\~/$HOME}"

PANE_MAP="${RESURRECT_DIR}/claude-panes.txt"
MAX_SAVES=${TMUX_CLAUDE_MAX_SAVES:-20}
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

    stale_seconds="${TMUX_CLAUDE_SAVE_LOCK_STALE_SECONDS:-300}"
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

    max_attempts="${TMUX_CLAUDE_SAVE_LOCK_ATTEMPTS:-10}"
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

save_add_flag() {
    local current="$1"
    local flag="$2"

    if [ -n "$current" ]; then
        printf '%s;%s\n' "$current" "$flag"
    else
        printf '%s\n' "$flag"
    fi
}

save_collapse_cwd() {
    local cwd="$1"
    local parent

    [ -n "$cwd" ] || return 1
    while [ "$cwd" != "/" ] && [ ! -d "$cwd" ]; do
        case "$cwd" in
            */*)
                parent="${cwd%/*}"
                [ "$parent" != "$cwd" ] || parent="/"
                [ -n "$parent" ] || parent="/"
                cwd="$parent"
                ;;
            *)
                cwd="/"
                ;;
        esac
    done
    [ -d "$cwd" ] || return 1
    printf '%s\n' "$cwd"
}

save_detect_field() {
    local row="$1"
    local field="$2"
    printf '%s\n' "$row" | awk -F '\t' -v field="$field" 'NR == 1 { print $field }'
}

save_adapter_exists() {
    local wanted="$1"
    local adapter
    for adapter in $(adapters_list); do
        [ "$adapter" = "$wanted" ] && return 0
    done
    return 1
}

save_pane_adapter_hint() {
    local target="$1"
    local cmd adapter
    cmd=$(tmux display-message -p -t "$target" '#{pane_current_command}' 2>/dev/null || true)
    # The foreground command is the real binary name, e.g. "codex-aarch64-a" or
    # "claude.exe", never a bare "codex"/"claude". Match substrings so the hint
    # picks the adapter for the pane's actual foreground tool; otherwise the
    # hint is dropped and detection falls back to adapter order (claude first),
    # which can misclassify a codex pane that has a live claude subagent.
    case "$cmd" in
        vim|nvim)
            adapter="nvim"
            ;;
        *codex*|*Codex*|*CODEX*)
            adapter="codex"
            ;;
        *claude*|*Claude*|*CLAUDE*)
            adapter="claude"
            ;;
        *)
            adapter="$cmd"
            ;;
    esac
    [ -n "$adapter" ] || return 1
    save_adapter_exists "$adapter" || return 1
    printf '%s\n' "$adapter"
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
            detect_row=""
            preferred_adapter=$(save_pane_adapter_hint "$target" || true)
            if [ -n "$preferred_adapter" ]; then
                detect_fn="${preferred_adapter}_detect"
                if declare -F "$detect_fn" >/dev/null 2>&1 &&
                    detect_row=$("$detect_fn" "$target" 2>/dev/null); then
                    [ -n "$detect_row" ] || detect_row=""
                else
                    detect_row=""
                fi
            fi
            for adapter in $(adapters_list); do
                [ -n "$detect_row" ] && break
                [ "$adapter" = "$preferred_adapter" ] && continue
                detect_fn="${adapter}_detect"
                if declare -F "$detect_fn" >/dev/null 2>&1 &&
                    detect_row=$("$detect_fn" "$target" 2>/dev/null); then
                    [ -n "$detect_row" ] && break
                fi
                detect_row=""
            done
            [ -n "$detect_row" ] || continue

            tool=$(save_detect_field "$detect_row" 1)
            sid=$(save_detect_field "$detect_row" 2)
            sid_kind=$(save_detect_field "$detect_row" 3)
            cwd=$(save_detect_field "$detect_row" 4)
            detect_flags=$(save_detect_field "$detect_row" 5)
            if [ -z "$cwd" ]; then
                cwd=$(tmux display-message -p -t "$target" '#{pane_current_path}' 2>/dev/null || true)
            fi
            wname=$(tmux display-message -p -t "$target" '#{window_name}' 2>/dev/null || true)

            original_cwd=""
            flags="$detect_flags"

            if [ "$sid_kind" = "uuid" ]; then
                validate_fn="${tool}_validate"
                if ! declare -F "$validate_fn" >/dev/null 2>&1 ||
                    ! "$validate_fn" "$sid" "$sid_kind" >/dev/null 2>&1; then
                    sid="-"
                    sid_kind="none"
                    flags=$(save_add_flag "$flags" sid_invalid)
                fi
            fi

            if [ -n "$cwd" ] && [ ! -d "$cwd" ]; then
                original_cwd="$cwd"
                collapsed_cwd=$(save_collapse_cwd "$cwd" 2>/dev/null || true)
                if [ -n "$collapsed_cwd" ]; then
                    cwd="$collapsed_cwd"
                fi
                flags=$(save_add_flag "$flags" cwd_collapsed)
            fi

            snapshot_write_row "$target" "$tool" "$sid" "$sid_kind" "$cwd" "$original_cwd" "$wname" "$flags" >> "$tmpfile"
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
