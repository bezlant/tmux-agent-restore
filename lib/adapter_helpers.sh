#!/usr/bin/env bash
# tmux-claude: shared adapter helpers.

if ! declare -F live_agent_pid >/dev/null 2>&1; then
    _adapter_lib_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    # shellcheck source=process.sh
    . "$_adapter_lib_dir/process.sh"
    unset _adapter_lib_dir
fi

adapter_pane_option() {
    local target="$1"
    local option="$2"
    tmux show-options -p -t "$target" -v "$option" 2>/dev/null || true
}

adapter_pane_cwd() {
    local target="$1"
    local cwd_option="$2"
    local option_cwd pane_cwd
    option_cwd=$(adapter_pane_option "$target" "$cwd_option")
    if [ -n "$option_cwd" ]; then
        printf '%s\n' "$option_cwd"
        return
    fi
    pane_cwd=$(tmux display-message -p -t "$target" '#{pane_current_path}' 2>/dev/null || true)
    printf '%s\n' "$pane_cwd"
}

adapter_sid_kind_for_agent() {
    local sid="$1"
    case "$sid" in
        picker) printf '%s\n' picker ;;
        -|"") printf '%s\n' none ;;
        *) printf '%s\n' uuid ;;
    esac
}

adapter_detect_agent() {
    local target="$1"
    local tool="$2"
    local sid_option="$3"
    local pid_option="$4"
    local cwd_option="$5"

    local live_pid
    live_pid=$(live_agent_pid "$target" "$tool" 2>/dev/null || true)
    [ -n "$live_pid" ] || return 1

    local option_sid option_pid cwd
    option_sid=$(adapter_pane_option "$target" "$sid_option")
    option_pid=$(adapter_pane_option "$target" "$pid_option")
    cwd=$(adapter_pane_cwd "$target" "$cwd_option")

    if [ -n "$option_sid" ] && { [ -z "$option_pid" ] || [ "$option_pid" = "$live_pid" ]; }; then
        local option_kind
        option_kind=$(adapter_sid_kind_for_agent "$option_sid")
        printf '%s\t%s\t%s\t%s\n' "$tool" "$option_sid" "$option_kind" "$cwd"
        return 0
    fi

    local cmd uuid
    cmd=$(process_command "$live_pid")
    uuid=$(extract_uuid "$cmd" || true)
    if [ -n "$uuid" ]; then
        printf '%s\t%s\t%s\t%s\n' "$tool" "$uuid" "uuid" "$cwd"
    else
        printf '%s\t%s\t%s\t%s\n' "$tool" "picker" "picker" "$cwd"
    fi
}
