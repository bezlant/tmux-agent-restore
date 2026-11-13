#!/usr/bin/env bash
# tmux-agent-restore: shared Claude/Codex SessionStart hook implementation.

session_hook_command_matches_self() {
    local command="$1"
    local hook_path="$2"
    local hook_name="${hook_path##*/}"

    case "$command" in
        *"$hook_path"*|*"/$hook_name"*) return 0 ;;
        *) return 1 ;;
    esac
}

session_hook_non_hook_agent_parent_pid() {
    local pid="$1"
    local tool="$2"
    local hook_path="$3"
    local parent command

    while [ -n "$pid" ]; do
        parent=$(ps -p "$pid" -o ppid= 2>/dev/null | awk 'NR == 1 { print $1 }')
        [ -n "$parent" ] || return 1
        [ "$parent" != "$pid" ] || return 1

        command=$(process_command "$parent" 2>/dev/null || true)
        if [ -n "$command" ] && ! session_hook_command_matches_self "$command" "$hook_path"; then
            case "$command" in
                *"$tool"*) printf '%s\n' "$parent"; return 0 ;;
            esac
        fi
        pid="$parent"
    done

    return 1
}

session_hook_pid_in_hook_subtree() {
    local pid="$1"
    local hook_path="$2"
    local parent command

    while [ -n "$pid" ]; do
        command=$(process_command "$pid" 2>/dev/null || true)
        if [ -n "$command" ] && session_hook_command_matches_self "$command" "$hook_path"; then
            return 0
        fi

        parent=$(ps -p "$pid" -o ppid= 2>/dev/null | awk 'NR == 1 { print $1 }')
        [ -n "$parent" ] || return 1
        [ "$parent" != "$pid" ] || return 1
        pid="$parent"
    done

    return 1
}

session_hook_json_field() {
    local field="$1"
    python3 -c 'import sys,json; v=json.load(sys.stdin).get(sys.argv[1], ""); print(v if isinstance(v, str) else "")' "$field" 2>/dev/null || true
}

session_hook_foreground_is_tool() {
    local pane="$1"
    local tool="$2"
    local pane_cmd
    pane_cmd=$(tmux display-message -p -t "$pane" '#{pane_current_command}' 2>/dev/null || true)
    case "$tool:$pane_cmd" in
        codex:*codex*|codex:*Codex*|codex:*CODEX*) return 0 ;;
        claude:*claude*|claude:*Claude*|claude:*CLAUDE*) return 0 ;;
        *) return 1 ;;
    esac
}

session_hook_run() {
    local tool="$1"
    local opposite_tool="$2"
    local sid_option="$3"
    local pid_option="$4"
    local cwd_option="$5"
    local plugin_dir="$6"
    local hook_path="$7"
    local input session_id cwd agent_pid

    [ -n "${TMUX:-}" ] || exit 0
    [ -n "${TMUX_PANE:-}" ] || exit 0

    input=$(cat)
    session_id=$(printf '%s\n' "$input" | session_hook_json_field session_id)
    [ -n "$session_id" ] || exit 0

    if session_hook_foreground_is_tool "$TMUX_PANE" "$opposite_tool"; then
        exit 0
    fi

    tmux set-option -p -t "$TMUX_PANE" "$sid_option" "$session_id" 2>/dev/null || true

    if declare -F live_agent_pid >/dev/null 2>&1; then
        agent_pid=$(live_agent_pid "$TMUX_PANE" "$tool" 2>/dev/null || true)
        if [ -n "$agent_pid" ] && declare -F process_command >/dev/null 2>&1; then
            if session_hook_pid_in_hook_subtree "$agent_pid" "$hook_path"; then
                agent_pid=$(session_hook_non_hook_agent_parent_pid "$agent_pid" "$tool" "$hook_path" 2>/dev/null || true)
            fi
        fi
        if [ -n "$agent_pid" ]; then
            tmux set-option -p -t "$TMUX_PANE" "$pid_option" "$agent_pid" 2>/dev/null || true
        fi
    fi

    cwd=$(printf '%s\n' "$input" | session_hook_json_field cwd)
    [ -n "$cwd" ] && tmux set-option -p -t "$TMUX_PANE" "$cwd_option" "$cwd" 2>/dev/null || true

    if [ -x "$plugin_dir/scripts/session-save.sh" ]; then
        bash "$plugin_dir/scripts/session-save.sh" >> /tmp/tmux-agent-restore-save.log 2>&1 &
    fi

    return 0
}
