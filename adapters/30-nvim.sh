#!/usr/bin/env bash
# tmux-claude adapter: nvim.

if ! declare -F live_agent_pid >/dev/null 2>&1; then
    _adapter_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
    # shellcheck source=../lib/process.sh
    . "$_adapter_dir/lib/process.sh"
    unset _adapter_dir
fi

nvim_detect() {
    local target="$1"
    local pid cwd
    pid=$(live_agent_pid "$target" nvim 2>/dev/null || true)
    [ -n "$pid" ] || pid=$(live_agent_pid "$target" vim 2>/dev/null || true)
    [ -n "$pid" ] || return 1
    cwd=$(tmux display-message -p -t "$target" '#{pane_current_path}' 2>/dev/null || true)
    printf '%s\t%s\t%s\t%s\n' nvim - none "$cwd"
}

nvim_validate() {
    return 0
}

nvim_restore_argv() {
    printf '%s\n' nvim
}
