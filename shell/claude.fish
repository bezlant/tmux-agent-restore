# tmux-claude:session-name
# Tags Claude Code sessions with tmux pane coordinates for crash recovery.
# By default this names a fresh session; pass --tmux-resume or set
# TMUX_CLAUDE_AUTO_RESUME=1 to resume by matching the tmux-derived name.
# Install both files to ~/.config/fish/functions/:
#   cp shell/claude.fish shell/__tmux_claude_session_args.fish ~/.config/fish/functions/
#
# If you have an existing claude wrapper, just copy __tmux_claude_session_args.fish
# and add this before your `command claude` call:
#   set -l extra_args
#   if functions -q __tmux_claude_session_args
#       set extra_args (__tmux_claude_session_args $argv)
#   end
#   command claude $extra_args $argv

function claude --wraps=claude --description "Claude Code with tmux session tagging"
    set -l extra_args
    if functions -q __tmux_claude_session_args
        set extra_args (__tmux_claude_session_args $argv)
    end
    command claude $extra_args $argv
end
