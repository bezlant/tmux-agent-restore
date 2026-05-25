# tmux-claude:tres
function tres --description "Attach to restored tmux session, waiting for restore to complete"
    set -l bootstrap_name "_tres_bootstrap"
    set -l resurrect_dir (tmux show-option -gqv @resurrect-dir 2>/dev/null)
    if test -z "$resurrect_dir"
        set resurrect_dir "$HOME/.config/tmux/resurrect"
    end
    set resurrect_dir (string replace -r '^~' "$HOME" -- "$resurrect_dir")

    set -l snapshot "$resurrect_dir/last"
    set -l target_session ""
    if test -f "$snapshot"
        set target_session (awk '
            /^pane\t/ {
                print $2
                exit
            }
        ' "$snapshot")
    end

    if test -z "$target_session"
        set target_session "0"
    end

    set -l created_bootstrap 0
    if not tmux has-session >/dev/null 2>&1
        tmux new-session -d -s "$bootstrap_name"
        set created_bootstrap 1
    end

    set -l prev_count 0
    set -l stable 0
    for _i in (seq 75)
        set -l count (tmux list-windows -t "$target_session" 2>/dev/null | wc -l | string trim)
        if test "$count" -ge 2; and test "$count" = "$prev_count"
            set stable (math "$stable" + 1)
            if test "$stable" -ge 2
                break
            end
        else
            set stable 0
        end
        set prev_count "$count"
        sleep 0.2
    end

    if test "$created_bootstrap" -eq 1
        tmux kill-session -t "$bootstrap_name" 2>/dev/null
    end

    tmux attach -t "$target_session"
end
