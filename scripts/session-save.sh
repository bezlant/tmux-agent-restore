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
tmpfile=""

save_cleanup() {
    [ -n "${tmpfile:-}" ] && rm -f "$tmpfile"
    rm -rf "$LOCK_DIR"
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

mkdir -p "$RESURRECT_DIR"

_attempts=0
while ! mkdir "$LOCK_DIR" 2>/dev/null; do
    _attempts=$((_attempts + 1))
    [ "$_attempts" -ge 10 ] && exit 0
    sleep 0.5
done
trap save_cleanup EXIT HUP INT TERM

if [ -d "$RESURRECT_DIR" ]; then
    (cd "$RESURRECT_DIR" && ls -t tmux_resurrect_*.txt 2>/dev/null | tail -n +$((MAX_SAVES + 1)) | xargs rm -f 2>/dev/null) || true
fi

adapters_load "$CURRENT_DIR"

tmpfile=$(mktemp "${PANE_MAP}.XXXXXX")
snapshot_write_header > "$tmpfile"

pane_count=0

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

            tool=$(save_detect_field "$detect_row" 1)
            sid=$(save_detect_field "$detect_row" 2)
            sid_kind=$(save_detect_field "$detect_row" 3)
            cwd=$(save_detect_field "$detect_row" 4)
            if [ -z "$cwd" ]; then
                cwd=$(tmux display-message -p -t "$target" '#{pane_current_path}' 2>/dev/null || true)
            fi
            wname=$(tmux display-message -p -t "$target" '#{window_name}' 2>/dev/null || true)

            original_cwd=""
            flags=""

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
