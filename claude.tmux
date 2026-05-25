#!/usr/bin/env bash
# tmux-claude: Better tmux integration for Claude Code agent teams
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
install_opt=$(tmux show-option -gqv @tmux-claude-auto-install-wrapper 2>/dev/null)
if [ "$install_opt" != "off" ]; then
    marker="# tmux-claude:session-name"

    fish_dir="$HOME/.config/fish/functions"
    if [ -d "$fish_dir" ]; then
        cp "$SHELL_DIR/__tmux_claude_session_args.fish" "$fish_dir/" 2>/dev/null

        tres_marker="# tmux-claude:tres"
        tres_target="$fish_dir/tres.fish"
        if [ -f "$SHELL_DIR/tres.fish" ] && [ ! -f "$tres_target" ]; then
            cp "$SHELL_DIR/tres.fish" "$tres_target" 2>/dev/null
        elif [ -f "$tres_target" ] && ! grep -q "$tres_marker" "$tres_target" 2>/dev/null; then
            tmux display-message "tmux-claude: tres.fish already exists — see $SHELL_DIR/tres.fish"
        fi

        if [ ! -f "$fish_dir/claude.fish" ]; then
            cp "$SHELL_DIR/claude.fish" "$fish_dir/claude.fish" 2>/dev/null
        elif ! grep -q "$marker" "$fish_dir/claude.fish" 2>/dev/null; then
            tmux display-message "tmux-claude: add session tagging to your claude.fish — see $SHELL_DIR/claude.fish"
        fi
    fi
fi
