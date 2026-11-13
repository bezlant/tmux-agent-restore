# tmux-agent-restore:session-name
# Names Claude Code sessions after their tmux window (and pane, when the window is split).
# Install both files to ~/.config/fish/functions/:
#   cp shell/claude.fish shell/__tmux_agent_restore_session_args.fish ~/.config/fish/functions/
#
# If you have an existing claude wrapper, just copy __tmux_agent_restore_session_args.fish
# and pass its output to your `command claude` call:
#   command claude (__tmux_agent_restore_session_args $argv) $argv

function claude --wraps=claude --description "Claude Code with tmux session tagging"
    set -l extra_args
    if functions -q __tmux_agent_restore_session_args
        set extra_args (__tmux_agent_restore_session_args $argv)
    end
    command claude $extra_args $argv
end
