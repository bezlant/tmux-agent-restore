#!/usr/bin/env bash
# tmux-agent-restore: convert decoded snapshot rows into executable restore actions.
#
# shellcheck disable=SC2034
# RESTORE_PLAN_* globals are the module's caller-read output API.

_restore_plan_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
if ! declare -F restore_resolve_target >/dev/null 2>&1; then
    # shellcheck source=restore_helpers.sh
    . "$_restore_plan_dir/lib/restore_helpers.sh"
fi
if ! declare -F shell_quote_argv_file >/dev/null 2>&1; then
    # shellcheck source=quote.sh
    . "$_restore_plan_dir/lib/quote.sh"
fi
unset _restore_plan_dir

restore_plan_reset() {
    RESTORE_PLAN_STATUS=
    RESTORE_PLAN_TARGET=
    RESTORE_PLAN_TOOL=
    RESTORE_PLAN_FULL=
    RESTORE_PLAN_REASON=
    RESTORE_PLAN_CURRENT_WNAME=
}

restore_plan_skip() {
    RESTORE_PLAN_STATUS=skip
    RESTORE_PLAN_TARGET="$1"
    RESTORE_PLAN_TOOL="$2"
    RESTORE_PLAN_REASON="$3"
    RESTORE_PLAN_FULL=
    RESTORE_PLAN_CURRENT_WNAME="${4:-}"
}

restore_plan_shell_for_target() {
    local target="$1"
    local pane_shell

    pane_shell=$(tmux display-message -p -t "$target" '#{pane_current_command}' 2>/dev/null || true)
    case "$pane_shell" in
        fish|bash|zsh|sh|dash|ksh) printf '%s\n' "$pane_shell" ;;
        *) printf '%s\n' sh ;;
    esac
}

restore_plan_build() {
    local target="$1"
    local tool="$2"
    local sid="$3"
    local sid_kind="$4"
    local cwd="$5"
    local original_cwd="$6"
    local wname="$7"
    local flags="$8"
    local argv_tmp="$9"
    local resolved_target restore_fn display_name pane_shell cmd cwd_q current_wname

    restore_plan_reset
    : "$original_cwd" "$flags"

    if ! resolved_target=$(restore_resolve_target "$target" "$wname"); then
        current_wname=$(tmux display-message -p -t "$target" '#{window_name}' 2>/dev/null || true)
        [ -n "$current_wname" ] || current_wname="-"
        restore_plan_skip "$target" "$tool" window_mismatch "$current_wname"
        return 0
    fi

    restore_fn="${tool}_restore_argv"
    if ! declare -F "$restore_fn" >/dev/null 2>&1; then
        restore_plan_skip "$resolved_target" "$tool" missing_adapter
        return 0
    fi

    display_name=$(restore_make_display_name "$wname" "$resolved_target")
    : > "$argv_tmp"
    if ! "$restore_fn" "$sid" "$sid_kind" "$cwd" "$display_name" > "$argv_tmp" 2>/dev/null; then
        restore_plan_skip "$resolved_target" "$tool" adapter_error
        return 0
    fi

    pane_shell=$(restore_plan_shell_for_target "$resolved_target")
    if ! cmd=$(shell_quote_argv_file "$pane_shell" "$argv_tmp"); then
        restore_plan_skip "$resolved_target" "$tool" quote_argv_failed
        return 0
    fi

    cwd_q=$(shell_quote_word "$pane_shell" "$cwd")
    RESTORE_PLAN_STATUS=ok
    RESTORE_PLAN_TARGET="$resolved_target"
    RESTORE_PLAN_TOOL="$tool"
    RESTORE_PLAN_FULL="cd $cwd_q 2>/dev/null || cd; $cmd"
    RESTORE_PLAN_REASON=
    RESTORE_PLAN_CURRENT_WNAME=
}
