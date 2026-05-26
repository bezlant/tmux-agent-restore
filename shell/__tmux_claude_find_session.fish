# tmux-claude:session-name
# Finds a Claude Code session ID by matching its original customTitle.

function __tmux_claude_find_session
    set -l target $argv[1]
    set -l project_dir "$HOME/.claude/projects/"(pwd | tr '/.' '--')

    test -d "$project_dir"; or return

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
end
