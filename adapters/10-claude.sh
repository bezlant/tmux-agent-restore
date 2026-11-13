#!/usr/bin/env bash
# tmux-agent-restore adapter: Claude Code.

if ! declare -F adapter_detect_agent >/dev/null 2>&1; then
    _adapter_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
    # shellcheck source=../lib/adapter_helpers.sh
    . "$_adapter_dir/lib/adapter_helpers.sh"
    unset _adapter_dir
fi

claude_detect() {
    adapter_detect_agent "$1" claude @claude_session_id @claude_session_pid @claude_cwd claude_validate
}

claude_validate() {
    local sid="$1"
    local sid_kind="$2"
    local home="${HOME:-}"

    [ "$sid_kind" = "uuid" ] || return 0
    printf '%s' "$sid" | LC_ALL=C grep -Eq '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$' || return 1
    [ -n "$home" ] || return 1

    find "$home/.claude/projects" \
        -type f \
        -name "${sid}.jsonl" \
        -print -quit 2>/dev/null | grep -q .
}

claude_restore_argv() {
    local sid="$1"
    local sid_kind="$2"
    local display_name="$4"
    printf '%s\n' ccy --name "$display_name" --resume
    if [ "$sid_kind" = "uuid" ] && [ -n "$sid" ] && [ "$sid" != "-" ]; then
        printf '%s\n' "$sid"
    fi
}
