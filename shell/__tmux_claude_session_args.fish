# tmux-claude:session-name
# Returns --resume/--name args for pane-aware session resume.

function __tmux_claude_session_args
    test -z "$TMUX"; and return
    set -l tmux_resume 0
    for arg in $argv
        switch $arg
            case --tmux-resume
                set tmux_resume 1
                continue
            case --name '--name=*' --resume '-r' '--resume=*' --continue '-c' '--continue=*' --print '-p'
                return
        end
    end
    if test "$TMUX_CLAUDE_AUTO_RESUME" = "1"
        set tmux_resume 1
    end
    set -l wname (tmux display-message -p -t "$TMUX_PANE" '#{window_name}' 2>/dev/null)
    set -l pane_count (tmux display-message -p -t "$TMUX_PANE" '#{window_panes}' 2>/dev/null)
    set -l pane (tmux display-message -p -t "$TMUX_PANE" '#{pane_index}' 2>/dev/null)

    if test -z "$wname"; or string match -qr '^(fish|bash|zsh|sh|dash|tcsh|csh|ksh|nu|nushell|pwsh)$' -- "$wname"
        set -l sess (tmux display-message -p -t "$TMUX_PANE" '#{session_name}' 2>/dev/null)
        set -l win (tmux display-message -p -t "$TMUX_PANE" '#{window_index}' 2>/dev/null)
        test -z "$sess" -o -z "$win"; and return
        set wname "$sess:$win"
    end

    test -z "$wname"; and return

    set -l name $wname
    if test -n "$pane_count" -a "$pane_count" -gt 1 -a -n "$pane" 2>/dev/null
        set name "$wname.$pane"
    end
    set name (string replace -ra '[^A-Za-z0-9_.:-]' '-' -- $name)
    if test "$tmux_resume" = "1"
        set -l sid (__tmux_claude_find_session "$name" 2>/dev/null)
        if test -n "$sid"
            printf '%s\n' --resume "$sid" --name "$name"
            return
        end
    end
    printf '%s\n' --name "$name"
end
