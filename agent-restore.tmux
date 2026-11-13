#!/usr/bin/env bash
# tmux-agent-restore: Better tmux integration for Claude Code agent teams
# TPM-compatible plugin entry point

CURRENT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPTS_DIR="$CURRENT_DIR/scripts"
SHELL_DIR="$CURRENT_DIR/shell"

# --- Session save/restore (requires tmux-resurrect) ---
resurrect_dir=$(tmux show-option -gqv @resurrect-dir 2>/dev/null)
if [ -z "$resurrect_dir" ]; then
    plugin_base=$(tmux show-environment -g TMUX_PLUGIN_MANAGER_PATH 2>/dev/null | cut -d= -f2)
    [ -d "${plugin_base}/tmux-resurrect" ] && resurrect_dir="${plugin_base}/tmux-resurrect"
fi

if [ -n "$resurrect_dir" ]; then
    existing_save=$(tmux show-option -gqv @resurrect-hook-post-save-all 2>/dev/null)
    existing_restore=$(tmux show-option -gqv @resurrect-hook-post-restore-all 2>/dev/null)

    save_cmd="bash $SCRIPTS_DIR/session-save.sh"
    restore_cmd="bash $SCRIPTS_DIR/session-restore.sh"

    if ! echo "$existing_save" | grep -qF "session-save.sh"; then
        if [ -n "$existing_save" ]; then
            tmux set-option -g @resurrect-hook-post-save-all "$existing_save; $save_cmd"
        else
            tmux set-option -g @resurrect-hook-post-save-all "$save_cmd"
        fi
    fi

    if ! echo "$existing_restore" | grep -qF "session-restore.sh"; then
        if [ -n "$existing_restore" ]; then
            tmux set-option -g @resurrect-hook-post-restore-all "$existing_restore; $restore_cmd"
        else
            tmux set-option -g @resurrect-hook-post-restore-all "$restore_cmd"
        fi
    fi
fi

# --- Shell wrapper: auto-install the composable helper ---
install_opt=$(tmux show-option -gqv @tmux-agent-restore-auto-install-wrapper 2>/dev/null)
if [ "$install_opt" != "off" ]; then
    marker="# tmux-agent-restore:session-name"

    fish_dir="$HOME/.config/fish/functions"
    if [ -d "$fish_dir" ]; then
        cp "$SHELL_DIR/__tmux_agent_restore_session_args.fish" "$fish_dir/" 2>/dev/null

        if [ ! -f "$fish_dir/claude.fish" ]; then
            cp "$SHELL_DIR/claude.fish" "$fish_dir/claude.fish" 2>/dev/null
        elif ! grep -q "$marker" "$fish_dir/claude.fish" 2>/dev/null; then
            tmux display-message "tmux-agent-restore: add session tagging to your claude.fish — see $SHELL_DIR/claude.fish"
        fi
    fi
fi
