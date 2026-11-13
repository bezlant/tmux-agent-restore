#!/usr/bin/env bash
# tmux-agent-restore: process inspection helpers shared by adapters and hooks.

live_agent_pid() {
    local target="$1"
    local tool="$2"
    local shell_pid
    shell_pid=$(tmux display-message -p -t "$target" '#{pane_pid}' 2>/dev/null || true)
    [ -n "$shell_pid" ] || return 1

    ps -axww -o pid=,ppid=,command= 2>/dev/null | awk -v root="$shell_pid" -v tool="$tool" '
        function descendant_depth(pid, d) {
            d = 0
            while (pid != root && (pid in parents)) {
                pid = parents[pid]
                d++
                if (d > count) return -1
            }
            if (pid == root) return d
            return -1
        }

        BEGIN { match_pid = ""; match_depth = -1 }
        {
            pid = $1; ppid = $2
            cmd = $0
            sub(/^[ \t]*[0-9]+[ \t]+[0-9]+[ \t]+/, "", cmd)
            pids[++count] = pid
            parents[pid] = ppid
            commands[pid] = cmd
        }
        END {
            tree[root] = 1
            changed = 1
            while (changed) {
                changed = 0
                for (i = 1; i <= count; i++) {
                    pid = pids[i]
                    if (!(pid in tree) && (parents[pid] in tree)) {
                        tree[pid] = 1
                        changed = 1
                    }
                }
            }

            for (i = 1; i <= count; i++) {
                pid = pids[i]
                if (pid in tree && pid != root && index(commands[pid], tool) > 0) {
                    depth = descendant_depth(pid)
                    if (depth >= match_depth) {
                        match_pid = pid
                        match_depth = depth
                    }
                }
            }

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
    ps -p "$pid" -o command= 2>/dev/null | head -1 || true
}

extract_uuid() {
    local text="$1"
    printf '%s\n' "$text" \
        | grep -oE '[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}' \
        | head -1 \
        | tr 'A-F' 'a-f' \
        || true
}
