# tmux-claude:session-name
# Claude Code wrapper with pane-aware stable naming.
# Install: source this file from ~/.bashrc

__tmux_claude_wrapper_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd -P)"
__tmux_claude_sourced_plugin_dir="$(dirname -- "$__tmux_claude_wrapper_dir")"
unset __tmux_claude_wrapper_dir

claude() {
    local extra_args=()
    local pass_args=()
    local arg
    for arg in "$@"; do
        [ "$arg" = "--tmux-resume" ] && continue
        pass_args+=("$arg")
    done

    local plugin_dir="${TMUX_CLAUDE_PLUGIN_DIR:-}"
    if [ -z "$plugin_dir" ]; then
        if [ -n "${__tmux_claude_sourced_plugin_dir:-}" ] && [ -x "$__tmux_claude_sourced_plugin_dir/scripts/claude-session-args.sh" ]; then
            plugin_dir="$__tmux_claude_sourced_plugin_dir"
        else
            plugin_dir="${HOME:-}/.config/tmux/plugins/tmux-claude"
        fi
    fi
    local helper="$plugin_dir/scripts/claude-session-args.sh"
    if [ -x "$helper" ]; then
        local line
        while IFS= read -r line; do
            extra_args+=("$line")
        done < <("$helper" "$@")
    fi

    command claude "${extra_args[@]}" "${pass_args[@]}"
}
