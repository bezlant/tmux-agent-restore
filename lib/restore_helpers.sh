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

    session_name=$(printf '%s' "$session_name" | sed 's/[^A-Za-z0-9_.:-]/-/g')
    printf '%s\n' "$session_name"
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

wait_for_prompt() {
    local target="$1"
    local fg_cmd marker attempts max_attempts sleep_seconds

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
    if tmux capture-pane -p -t "$target" -S - -E - 2>/dev/null | grep -qF "$marker"; then
        return 1
    fi
    tmux send-keys -t "$target" "printf '%s\n' $marker" Enter 2>/dev/null || return 1

    max_attempts="${TMUX_CLAUDE_PROMPT_ATTEMPTS:-20}"
    sleep_seconds="${TMUX_CLAUDE_PROMPT_SLEEP:-0.1}"
    attempts=0
    while [ "$attempts" -lt "$max_attempts" ]; do
        if tmux capture-pane -p -t "$target" -S - -E - 2>/dev/null | grep -qF "$marker"; then
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
