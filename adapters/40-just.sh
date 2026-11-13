#!/usr/bin/env bash
# tmux-agent-restore adapter: just.

if ! declare -F live_agent_pid >/dev/null 2>&1; then
    _adapter_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
    # shellcheck source=../lib/process.sh
    . "$_adapter_dir/lib/process.sh"
    unset _adapter_dir
fi

just_detect() {
    local target="$1"
    local pid cmd recipe cwd
    pid=$(live_agent_pid "$target" just 2>/dev/null || true)
    [ -n "$pid" ] || return 1
    cmd=$(process_command "$pid")
    recipe=$(printf '%s\n' "$cmd" | awk '
        {
            for (i = 1; i <= NF; i++) {
                if ($i == "just" && i < NF) {
                    print $(i + 1)
                    exit
                }
            }
        }')
    [ -n "$recipe" ] || return 1
    cwd=$(tmux display-message -p -t "$target" '#{pane_current_path}' 2>/dev/null || true)
    printf '%s\t%s\t%s\t%s\n' just "$recipe" recipe "$cwd"
}

just_validate() {
    return 0
}

just_restore_argv() {
    local sid="$1"
    local sid_kind="$2"
    local cwd="$3"
    local display_name="$4"
    [ "$sid_kind" = "recipe" ] && [ -n "$sid" ] && [ "$sid" != "-" ] || return 1
    printf '%s\n' just "$sid"
}
