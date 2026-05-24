#!/usr/bin/env bash
# tmux-claude: adapter loading.

TMUX_CLAUDE_ADAPTERS=""

adapters_load() {
    local current_dir="$1"
    local adapter file base name

    # shellcheck source=process.sh
    . "$current_dir/lib/process.sh"
    # shellcheck source=adapter_helpers.sh
    . "$current_dir/lib/adapter_helpers.sh"

    TMUX_CLAUDE_ADAPTERS=""
    for adapter in "$current_dir"/adapters/[0-9][0-9]-*.sh; do
        [ -f "$adapter" ] || continue
        # shellcheck source=/dev/null
        . "$adapter"
        file="${adapter##*/}"
        base="${file#??-}"
        name="${base%.sh}"
        if [ -z "$TMUX_CLAUDE_ADAPTERS" ]; then
            TMUX_CLAUDE_ADAPTERS="$name"
        else
            TMUX_CLAUDE_ADAPTERS="$TMUX_CLAUDE_ADAPTERS $name"
        fi
    done
}

adapters_list() {
    local name
    for name in $TMUX_CLAUDE_ADAPTERS; do
        printf '%s\n' "$name"
    done
}
