#!/usr/bin/env bash
# tmux-claude: process inspection helpers shared by adapters and hooks.

live_agent_pid() {
    local target="$1"
    local tool="$2"
    local shell_pid
    shell_pid=$(tmux display-message -p -t "$target" '#{pane_pid}' 2>/dev/null || true)
    [ -n "$shell_pid" ] || return 1

    ps -axww -o pid=,ppid=,command= 2>/dev/null | awk -v root="$shell_pid" -v tool="$tool" '
        BEGIN { tree[root] = 1; match_pid = "" }
        {
            pid = $1; ppid = $2
            cmd = $0
            sub(/^[ \t]*[0-9]+[ \t]+[0-9]+[ \t]+/, "", cmd)
            if (ppid in tree) tree[pid] = 1
            if (pid in tree && pid != root && index(cmd, tool) > 0) {
                match_pid = pid
            }
        }
        END {
            if (match_pid != "") {
                print match_pid
                exit 0
            }
            exit 1
        }
    '
}

process_command() {
    local pid="$1"
    ps -p "$pid" -o command= 2>/dev/null | head -1
}

extract_uuid() {
    local text="$1"
    printf '%s\n' "$text" \
        | grep -oE '[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}' \
        | head -1 \
        | tr 'A-F' 'a-f'
}
