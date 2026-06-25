#!/usr/bin/env bash
# tmux-claude: restore orchestrator helpers.

restore_make_display_name() {
    local wname="$1"
    local target="$2"
    local pane_idx pane_count use_wname session_name

    pane_idx="${target##*.}"
    pane_count=$(tmux list-panes -t "${target%.*}" -F x 2>/dev/null | wc -l | tr -d ' ' || echo 1)
    case "$pane_count" in
        ''|*[!0-9]*) pane_count=1 ;;
    esac

    use_wname="$wname"
    case "$use_wname" in
        fish|bash|zsh|sh|dash|ksh|"")
            use_wname="${target%.*}" ;;
    esac

    if [ "$pane_count" -gt 1 ]; then
        session_name="${use_wname}.${pane_idx}"
    else
        session_name="$use_wname"
    fi

    session_name=$(printf '%s' "$session_name" | LC_ALL=C tr -c 'A-Za-z0-9_.:-' '-')
    printf '%s\n' "$session_name"
}

restore_resolve_target() {
    local target="$1"
    local wname="$2"
    local current_wname session pane_idx win_idx win_name candidate resolved_candidate matches

    [ -n "$wname" ] || { printf '%s\n' "$target"; return 0; }

    current_wname=$(tmux display-message -p -t "$target" '#{window_name}' 2>/dev/null || true)
    if [ "$current_wname" = "$wname" ]; then
        printf '%s\n' "$target"
        return 0
    fi

    session="${target%%:*}"
    pane_idx="${target##*.}"
    matches=0
    resolved_candidate=

    while IFS="$(printf '\t')" read -r win_idx win_name || [ -n "$win_idx$win_name" ]; do
        [ -n "$win_idx" ] || continue
        [ "$win_name" = "$wname" ] || continue
        candidate="$session:$win_idx.$pane_idx"
        if tmux list-panes -t "$session:$win_idx" -F '#{pane_index}' 2>/dev/null | grep -Fxq "$pane_idx"; then
            matches=$((matches + 1))
            resolved_candidate="$candidate"
        fi
    done < <(tmux list-windows -t "$session" -F '#{window_index}	#{window_name}' 2>/dev/null || true)

    if [ "$matches" -eq 1 ]; then
        printf '%s\n' "$resolved_candidate"
        return 0
    fi

    return 1
}

restore_flag_has() {
    local flags="$1"
    local wanted="$2"
    local part rest

    rest="$flags"
    while [ -n "$rest" ]; do
        case "$rest" in
            *";"*)
                part="${rest%%;*}"
                rest="${rest#*;}"
                ;;
            *)
                part="$rest"
                rest=""
                ;;
        esac
        [ "$part" = "$wanted" ] && return 0
    done
    return 1
}

restore_value_has_control() {
    local value="$1"
    case "$value" in
        *$'\n'*|*$'\r'*|*$'\t'*) return 0 ;;
    esac
    printf '%s' "$value" | LC_ALL=C grep -q '[[:cntrl:]]'
}

restore_sid_valid() {
    local sid="$1"
    local sid_kind="$2"

    if restore_value_has_control "$sid"; then
        return 1
    fi

    case "$sid_kind" in
        uuid)
            printf '%s' "$sid" | LC_ALL=C grep -Eq '^[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}$'
            ;;
        picker)
            [ "$sid" = "picker" ]
            ;;
        none)
            [ "$sid" = "-" ]
            ;;
        recipe)
            [ -n "$sid" ]
            ;;
        *)
            return 1
            ;;
    esac
}

restore_log_value() {
    local value="$1"
    value="${value//\\/\\\\}"
    value="${value//$'\t'/\\t}"
    value="${value//$'\r'/\\r}"
    value="${value//$'\n'/\\n}"
    printf '%s' "$value"
}

restore_marker_printf_format() {
    local marker="$1"
    local byte fmt=""

    while IFS= read -r byte; do
        [ -n "$byte" ] || continue
        fmt="$fmt\\$(printf '%03o' "$byte")"
    done <<EOF
$(printf '%s' "$marker" | od -An -v -t u1 | tr ' ' '\n')
EOF

    [ -n "$fmt" ] || return 1
    printf '%s\\n' "$fmt"
}

wait_for_prompt() {
    local target="$1"
    local fg_cmd marker marker_format attempts max_attempts sleep_seconds

    fg_cmd=$(tmux display-message -p -t "$target" '#{pane_current_command}' 2>/dev/null || true)
    case "$fg_cmd" in
        fish|bash|zsh|sh|dash|ksh) ;;
        *) return 1 ;;
    esac

    if [ -n "${TMUX_CLAUDE_READY_MARKER:-}" ]; then
        marker="$TMUX_CLAUDE_READY_MARKER"
    elif command -v uuidgen >/dev/null 2>&1; then
        marker="__tcready_$(uuidgen | tr '[:upper:]' '[:lower:]')__"
    else
        marker="__tcready_$$_${RANDOM}_${RANDOM}_$(date +%s)__"
    fi
    case "$marker" in
        ""|*[!A-Za-z0-9_:-]*) return 1 ;;
    esac

    if tmux capture-pane -J -p -t "$target" -S - -E - 2>/dev/null | grep -Fxq -- "$marker"; then
        return 1
    fi
    marker_format=$(restore_marker_printf_format "$marker") || return 1
    tmux send-keys -t "$target" "printf '$marker_format'" Enter 2>/dev/null || return 1

    max_attempts="${TMUX_CLAUDE_PROMPT_ATTEMPTS:-20}"
    sleep_seconds="${TMUX_CLAUDE_PROMPT_SLEEP:-0.1}"
    attempts=0
    while [ "$attempts" -lt "$max_attempts" ]; do
        if tmux capture-pane -J -p -t "$target" -S - -E - 2>/dev/null | grep -Fxq -- "$marker"; then
            return 0
        fi
        sleep "$sleep_seconds"
        attempts=$((attempts + 1))
    done
    return 1
}

restore_send_keys() {
    local target="$1"
    local command="$2"
    tmux send-keys -t "$target" "$command" Enter 2>/dev/null
}
