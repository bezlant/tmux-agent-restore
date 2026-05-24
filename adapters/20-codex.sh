#!/usr/bin/env bash
# tmux-claude adapter: Codex.

if ! declare -F adapter_detect_agent >/dev/null 2>&1; then
    _adapter_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
    # shellcheck source=../lib/adapter_helpers.sh
    . "$_adapter_dir/lib/adapter_helpers.sh"
    unset _adapter_dir
fi

codex_detect() {
    adapter_detect_agent "$1" codex @codex_session_id @codex_session_pid @codex_cwd
}

codex_validate() {
    return 0
}

codex_restore_argv() {
    local sid="$1"
    local sid_kind="$2"
    local cwd="$3"
    local display_name="$4"
    printf '%s\n' cxy resume
    if [ "$sid_kind" = "uuid" ] && [ -n "$sid" ] && [ "$sid" != "-" ]; then
        printf '%s\n' "$sid"
    fi
}
