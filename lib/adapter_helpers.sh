#!/usr/bin/env bash
# tmux-claude: shared adapter helpers.

if ! declare -F live_agent_pid >/dev/null 2>&1; then
    _adapter_lib_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    # shellcheck source=process.sh
    . "$_adapter_lib_dir/process.sh"
    unset _adapter_lib_dir
fi

adapter_pane_option() {
    local target="$1"
    local option="$2"
    tmux show-options -p -t "$target" -v "$option" 2>/dev/null || true
}

adapter_pane_cwd() {
    local target="$1"
    local cwd_option="$2"
    local option_cwd pane_cwd
    option_cwd=$(adapter_pane_option "$target" "$cwd_option")
    if [ -n "$option_cwd" ]; then
        printf '%s\n' "$option_cwd"
        return
    fi
    pane_cwd=$(tmux display-message -p -t "$target" '#{pane_current_path}' 2>/dev/null || true)
    printf '%s\n' "$pane_cwd"
}

adapter_sid_kind_for_agent() {
    local sid="$1"
    case "$sid" in
        picker) printf '%s\n' picker ;;
        -|"") printf '%s\n' none ;;
        *) printf '%s\n' uuid ;;
    esac
}

adapter_claude_title_uuid() {
    local cmd="$1"
    local cwd="$2"
    local home="${HOME:-}"

    [ -n "$cmd" ] || return 1
    [ -n "$cwd" ] || return 1
    [ -n "$home" ] || return 1
    command -v python3 >/dev/null 2>&1 || return 1

    python3 - "$home" "$cwd" "$cmd" <<'PY' 2>/dev/null
import json
import os
import re
import shlex
import sys

home, cwd, cmd = sys.argv[1], sys.argv[2], sys.argv[3]
try:
    argv = shlex.split(cmd)
except ValueError:
    sys.exit(1)

title = None
for i, arg in enumerate(argv):
    if arg == "--name" and i + 1 < len(argv):
        title = argv[i + 1]
        break
    if arg.startswith("--name="):
        title = arg.split("=", 1)[1]
        break

if not title:
    sys.exit(1)

project_dir = os.path.join(home, ".claude", "projects", cwd.replace("/", "-").replace(".", "-"))
if not os.path.isdir(project_dir):
    sys.exit(1)

uuid_re = re.compile(r"^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$", re.I)
matches = []
for name in os.listdir(project_dir):
    if not name.endswith(".jsonl"):
        continue
    sid = name[:-6]
    if not uuid_re.match(sid):
        continue
    path = os.path.join(project_dir, name)
    try:
        with open(path) as fh:
            for line_no, line in enumerate(fh, 1):
                if line_no > 50:
                    break
                line = line.strip()
                if not line:
                    continue
                try:
                    obj = json.loads(line)
                except (json.JSONDecodeError, ValueError):
                    continue
                if obj.get("type") == "custom-title":
                    if obj.get("customTitle") == title:
                        matches.append(sid)
                    break
    except OSError:
        continue

if len(matches) == 1:
    print(matches[0])
    sys.exit(0)
sys.exit(1)
PY
}

adapter_detect_agent() {
    local target="$1"
    local tool="$2"
    local sid_option="$3"
    local pid_option="$4"
    local cwd_option="$5"

    local live_pid
    live_pid=$(live_agent_pid "$target" "$tool" 2>/dev/null || true)
    [ -n "$live_pid" ] || return 1

    local option_sid option_pid cwd
    option_sid=$(adapter_pane_option "$target" "$sid_option")
    option_pid=$(adapter_pane_option "$target" "$pid_option")
    cwd=$(adapter_pane_cwd "$target" "$cwd_option")

    if [ -n "$option_sid" ] && { [ -z "$option_pid" ] || [ "$option_pid" = "$live_pid" ]; }; then
        local option_kind
        option_kind=$(adapter_sid_kind_for_agent "$option_sid")
        printf '%s\t%s\t%s\t%s\n' "$tool" "$option_sid" "$option_kind" "$cwd"
        return 0
    fi

    local cmd uuid
    cmd=$(process_command "$live_pid")
    uuid=$(extract_uuid "$cmd" || true)
    if [ -n "$uuid" ]; then
        printf '%s\t%s\t%s\t%s\n' "$tool" "$uuid" "uuid" "$cwd"
    elif [ "$tool" = "claude" ] && uuid=$(adapter_claude_title_uuid "$cmd" "$cwd"); then
        printf '%s\t%s\t%s\t%s\n' "$tool" "$uuid" "uuid" "$cwd"
    else
        printf '%s\t%s\t%s\t%s\n' "$tool" "picker" "picker" "$cwd"
    fi
}
