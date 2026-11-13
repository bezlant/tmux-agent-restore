#!/usr/bin/env bash
# tmux-agent-restore: adapter loading.

TMUX_AGENT_RESTORE_ADAPTERS=""

adapters_load() {
    local current_dir="$1"
    local adapter file base name

    # shellcheck source=process.sh
    . "$current_dir/lib/process.sh"
    # shellcheck source=adapter_helpers.sh
    . "$current_dir/lib/adapter_helpers.sh"

    TMUX_AGENT_RESTORE_ADAPTERS=""
    for adapter in "$current_dir"/adapters/[0-9][0-9]-*.sh; do
        [ -f "$adapter" ] || continue
        # shellcheck source=/dev/null
        . "$adapter"
        file="${adapter##*/}"
        base="${file#??-}"
        name="${base%.sh}"
        if [ -z "$TMUX_AGENT_RESTORE_ADAPTERS" ]; then
            TMUX_AGENT_RESTORE_ADAPTERS="$name"
        else
            TMUX_AGENT_RESTORE_ADAPTERS="$TMUX_AGENT_RESTORE_ADAPTERS $name"
        fi
    done
}

adapters_list() {
    local name
    for name in $TMUX_AGENT_RESTORE_ADAPTERS; do
        printf '%s\n' "$name"
    done
}
