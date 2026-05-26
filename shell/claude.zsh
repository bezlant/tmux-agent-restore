# tmux-claude:session-name
# Claude Code wrapper with pane-aware session resume.
# Install: source this file from ~/.zshrc

__tmux_claude_find_session() {
    local target="$1"
    local project_dir="$HOME/.claude/projects/$(pwd | tr '/.' '-')"
    [[ -d "$project_dir" ]] || return

    python3 -c "
import os, sys, json

d, target = sys.argv[1], sys.argv[2]
files = []
for f in os.listdir(d):
    if f.endswith('.jsonl'):
        fp = os.path.join(d, f)
        files.append((os.path.getmtime(fp), fp, f))
files.sort(reverse=True)

for _, fp, fname in files:
    with open(fp) as fh:
        for line in fh:
            line = line.strip()
            if not line:
                continue
            try:
                obj = json.loads(line)
            except (json.JSONDecodeError, ValueError):
                continue
            if obj.get('type') == 'custom-title':
                if obj.get('customTitle') == target:
                    print(fname[:-6])
                    sys.exit(0)
                break
" "$project_dir" "$target" 2>/dev/null
}

claude() {
    local extra_args=()
    if [[ -n "$TMUX" ]]; then
        local skip=0
        for arg in "$@"; do
            case "$arg" in
                --name|--name=*|--resume|-r|--resume=*|--continue|-c|--continue=*|--print|-p)
                    skip=1; break ;;
            esac
        done
        if (( skip == 0 )); then
            local wname pane_count pane name sid
            wname=$(tmux display-message -p -t "$TMUX_PANE" '#{window_name}' 2>/dev/null)
            pane_count=$(tmux display-message -p -t "$TMUX_PANE" '#{window_panes}' 2>/dev/null)
            pane=$(tmux display-message -p -t "$TMUX_PANE" '#{pane_index}' 2>/dev/null)
            if [[ -n "$wname" ]]; then
                name="$wname"
                if [[ -n "$pane_count" ]] && (( pane_count > 1 )) && [[ -n "$pane" ]]; then
                    name="$wname.$pane"
                fi
                sid=$(__tmux_claude_find_session "$name")
                if [[ -n "$sid" ]]; then
                    extra_args=(--resume "$sid" --name "$name")
                else
                    extra_args=(--name "$name")
                fi
            fi
        fi
    fi
    command claude "${extra_args[@]}" "$@"
}
