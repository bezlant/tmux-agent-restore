# tmux-claude:session-name
# Finds a Claude Code session ID by matching its original customTitle.

function __tmux_claude_find_session
    set -l target $argv[1]
    set -l project_dir "$HOME/.claude/projects/"(pwd | tr '/.' '--')

    test -d "$project_dir"; or return

    set -l plugin_dir "$HOME/.config/tmux/plugins/tmux-claude"
    if set -q TMUX_CLAUDE_PLUGIN_DIR
        set plugin_dir "$TMUX_CLAUDE_PLUGIN_DIR"
    end
    set -l finder "$plugin_dir/scripts/claude-find-session.py"
    if test -x "$finder"
        python3 "$finder" "$project_dir" "$target" 2>/dev/null
        return $status
    end

    python3 -c "
import os, sys, json, re

d, target = sys.argv[1], sys.argv[2]

def is_safe_session_id(session_id):
    return bool(session_id) and not session_id.startswith('-') and re.fullmatch(r'[A-Za-z0-9_.:-]+', session_id)

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
                    session_id = fname[:-6]
                    if is_safe_session_id(session_id):
                        print(session_id)
                        sys.exit(0)
                break
" "$project_dir" "$target" 2>/dev/null
end
