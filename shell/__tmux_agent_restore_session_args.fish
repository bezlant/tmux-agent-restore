# tmux-agent-restore:session-name
# Prints --name <tmux-derived name>, or nothing when the caller already chose a session.

function __tmux_agent_restore_session_args
    test -z "$TMUX"; and return
    for arg in $argv
        switch $arg
            case --name '--name=*' --resume '-r' '--resume=*' --continue '-c' '--continue=*' --print '--print=*' '-p'
                return
        end
    end

    set -l wname (tmux display-message -p -t "$TMUX_PANE" '#{window_name}' 2>/dev/null | string collect)
    set -l pane_count (tmux display-message -p -t "$TMUX_PANE" '#{window_panes}' 2>/dev/null | string collect)
    set -l pane (tmux display-message -p -t "$TMUX_PANE" '#{pane_index}' 2>/dev/null | string collect)

    if test -z "$wname"; or string match -qr '^(fish|bash|zsh|sh|dash|tcsh|csh|ksh|nu|nushell|pwsh)$' -- "$wname"
        set -l sess (tmux display-message -p -t "$TMUX_PANE" '#{session_name}' 2>/dev/null | string collect)
        set -l win (tmux display-message -p -t "$TMUX_PANE" '#{window_index}' 2>/dev/null | string collect)
        test -z "$sess" -o -z "$win"; and return
        set wname "$sess:$win"
    end

    test -z "$wname"; and return

    set -l name $wname
    if test -n "$pane_count" -a "$pane_count" -gt 1 -a -n "$pane" 2>/dev/null
        set name "$wname.$pane"
    end
    set name (string replace -ra '[^A-Za-z0-9_.:-]' '-' -- $name)
    printf '%s\n' --name "$name"
end
