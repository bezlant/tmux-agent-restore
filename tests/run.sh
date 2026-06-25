#!/usr/bin/env bash
# tmux-claude test runner
# Usage: bash tests/run.sh

set -uo pipefail

TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_DIR="$(dirname "$TESTS_DIR")"
PASS=0
FAIL=0

red() { printf '\033[31m%s\033[0m\n' "$1"; }
green() { printf '\033[32m%s\033[0m\n' "$1"; }

assert_eq() {
    local desc="$1" expected="$2" actual="$3"
    if [ "$expected" = "$actual" ]; then
        green "  PASS: $desc"
        PASS=$((PASS + 1))
    else
        red "  FAIL: $desc"
        red "    expected: $expected"
        red "    actual:   $actual"
        FAIL=$((FAIL + 1))
    fi
}

assert_contains() {
    local desc="$1" needle="$2" haystack="$3"
    if echo "$haystack" | grep -qF -- "$needle"; then
        green "  PASS: $desc"
        PASS=$((PASS + 1))
    else
        red "  FAIL: $desc"
        red "    expected to contain: $needle"
        red "    actual: $haystack"
        FAIL=$((FAIL + 1))
    fi
}

assert_not_contains() {
    local desc="$1" needle="$2" haystack="$3"
    if ! echo "$haystack" | grep -qF -- "$needle"; then
        green "  PASS: $desc"
        PASS=$((PASS + 1))
    else
        red "  FAIL: $desc"
        red "    expected NOT to contain: $needle"
        red "    actual: $haystack"
        FAIL=$((FAIL + 1))
    fi
}

# ============================================================
echo "=== session-restore: 5-field format parsing ==="
# ============================================================

tmpdir=$(mktemp -d)
cat > "$tmpdir/claude-panes.txt" <<'EOF'
# Claude/Codex session mapping — test
# Format: session:window.pane|tool|session_id|cwd|window_name
0:1.1|claude|aaaaaaaa-1111-2222-3333-444444444444|/Users/test/project|my-window
0:2.1|codex|bbbbbbbb-5555-6666-7777-888888888888|/Users/test/other|codex-win
0:3.1|claude|picker|/Users/test/project|picker-win
0:4.1|codex|picker|/Users/test/project|codex-picker
0:5.1|nvim|picker|/Users/test/project|editor
0:6.1|just|dev|/Users/test/project|server
EOF

cmds=""
while IFS='|' read -r target tool sid cwd wname; do
    [[ "$target" =~ ^#.*$ ]] && continue
    [ -z "$target" ] && continue
    case "$tool" in
        claude)
            if [ "$sid" = "picker" ]; then
                cmds="${cmds}cd \"$cwd\" && ccy --resume\n"
            else
                cmds="${cmds}cd \"$cwd\" && ccy --resume $sid\n"
            fi
            ;;
        codex)
            if [ "$sid" = "picker" ]; then
                cmds="${cmds}cd \"$cwd\" && cxy resume\n"
            else
                cmds="${cmds}cd \"$cwd\" && cxy resume $sid\n"
            fi
            ;;
        nvim)
            cmds="${cmds}cd \"$cwd\" && nvim\n"
            ;;
        just)
            cmds="${cmds}cd \"$cwd\" && just $sid\n"
            ;;
    esac
done < "$tmpdir/claude-panes.txt"

assert_contains "claude UUID gets ccy --resume UUID" "ccy --resume aaaaaaaa-1111-2222-3333-444444444444" "$cmds"
assert_contains "codex UUID gets cxy resume UUID" "cxy resume bbbbbbbb-5555-6666-7777-888888888888" "$cmds"
assert_contains "claude picker gets ccy --resume" "ccy --resume" "$cmds"
assert_contains "codex picker gets cxy resume" "cxy resume" "$cmds"
assert_contains "nvim pane opens nvim" "nvim" "$cmds"
assert_contains "just pane runs recipe" "just dev" "$cmds"
assert_eq "6 commands total" "6" "$(echo -e "$cmds" | grep -c '.')"

rm -rf "$tmpdir"

# ============================================================
echo ""
echo "=== session-restore: empty/missing mapping file ==="
# ============================================================

tmpdir=$(mktemp -d)

result=$(bash -c "
    PANE_MAP='$tmpdir/claude-panes.txt'
    [ -f \"\$PANE_MAP\" ] || { echo 'skipped'; exit 0; }
    echo 'ran'
")
assert_eq "missing file -> skip" "skipped" "$result"

touch "$tmpdir/claude-panes.txt"
result=$(bash -c "
    PANE_MAP='$tmpdir/claude-panes.txt'
    [ -f \"\$PANE_MAP\" ] || { echo 'skipped'; exit 0; }
    [ -s \"\$PANE_MAP\" ] || { echo 'skipped-empty'; exit 0; }
    echo 'ran'
")
assert_eq "empty file -> skip" "skipped-empty" "$result"

rm -rf "$tmpdir"

# ============================================================
echo ""
echo "=== session-save: atomic write ==="
# ============================================================

tmpdir=$(mktemp -d)
echo "old-mapping" > "$tmpdir/claude-panes.txt"

tmpfile=$(mktemp "$tmpdir/claude-panes.txt.XXXXXX")
echo "new-mapping" > "$tmpfile"
mv "$tmpfile" "$tmpdir/claude-panes.txt"

content=$(cat "$tmpdir/claude-panes.txt")
assert_eq "atomic mv overwrites cleanly" "new-mapping" "$content"
assert_eq "no temp files left" "1" "$(ls "$tmpdir" | wc -l | tr -d ' ')"

rm -rf "$tmpdir"

# ============================================================
echo ""
echo "=== session-save: no-clobber on empty enumeration ==="
# ============================================================

tmpdir=$(mktemp -d)
echo "precious-mapping" > "$tmpdir/claude-panes.txt"

# Simulate: save found 0 panes but mapping exists → should not overwrite
pane_count=0
if [ "$pane_count" -eq 0 ] && [ -f "$tmpdir/claude-panes.txt" ]; then
    preserved=true
else
    preserved=false
fi
assert_eq "zero-pane save preserves existing mapping" "true" "$preserved"

content=$(cat "$tmpdir/claude-panes.txt")
assert_eq "mapping content unchanged" "precious-mapping" "$content"

rm -rf "$tmpdir"

# ============================================================
echo ""
echo "=== session-save: autoprune ==="
# ============================================================

tmpdir=$(mktemp -d)
for i in $(seq -w 1 25); do
    touch "$tmpdir/tmux_resurrect_202604${i}T120000.txt"
done
assert_eq "25 files before prune" "25" "$(ls "$tmpdir"/tmux_resurrect_*.txt | wc -l | tr -d ' ')"

(cd "$tmpdir" && ls -t tmux_resurrect_*.txt 2>/dev/null | tail -n +21 | xargs rm -f 2>/dev/null)
assert_eq "20 files after prune" "20" "$(ls "$tmpdir"/tmux_resurrect_*.txt | wc -l | tr -d ' ')"

rm -rf "$tmpdir"

# ============================================================
echo ""
echo "=== session-save: adapter-driven v2 snapshot ==="
# ============================================================

unset -f tmux live_agent_pid process_command extract_uuid adapter_detect_agent 2>/dev/null || true

# shellcheck source=../lib/snapshot.sh
. "$PLUGIN_DIR/lib/snapshot.sh"

write_save_tmux_stub() {
    local tmux_path="$1"
    local fixture_dir="$2"

    cat > "$tmux_path" <<EOF
#!/usr/bin/env bash
fixture_dir='$fixture_dir'
read_file() {
    [ -f "\$fixture_dir/\$1" ] || return 1
    cat "\$fixture_dir/\$1"
}

case "\$1" in
    show-option)
        case "\$*" in
            *"@resurrect-dir"*) read_file resurrect_dir; exit 0 ;;
            *) exit 1 ;;
        esac
        ;;
    list-sessions)
        read_file sessions || true
        ;;
    list-windows)
        read_file windows || true
        ;;
    list-panes)
        read_file panes || true
        ;;
    display-message)
        case "\$*" in
            *"#{window_name}"*) read_file window_name || true ;;
            *"#{pane_current_path}"*) read_file pane_current_path || true ;;
            *"#{pane_pid}"*) read_file pane_pid || true ;;
            *"#{pane_current_command}"*) read_file pane_current_command || printf '%s\n' fish ;;
            *) exit 1 ;;
        esac
        ;;
    show-options)
        option=""
        while [ "\$#" -gt 0 ]; do
            if [ "\$1" = "-v" ]; then
                shift
                option="\${1:-}"
                break
            fi
            shift
        done
        case "\$option" in
            @claude_session_id) read_file claude_session_id || true ;;
            @claude_session_pid) read_file claude_session_pid || true ;;
            @claude_cwd) read_file claude_cwd || true ;;
            @codex_session_id) read_file codex_session_id || true ;;
            @codex_session_pid) read_file codex_session_pid || true ;;
            @codex_cwd) read_file codex_cwd || true ;;
            *) exit 1 ;;
        esac
        ;;
    send-keys)
        printf '%s\n' "\$*" >> "\$fixture_dir/send-keys.log"
        ;;
    *)
        exit 1
        ;;
esac
EOF
    chmod +x "$tmux_path"
}

write_save_ps_stub() {
    local ps_path="$1"
    local fixture_dir="$2"

    cat > "$ps_path" <<EOF
#!/usr/bin/env bash
fixture_dir='$fixture_dir'
if [ "\$1" = "-axww" ] && [ "\$2" = "-o" ] && [ "\$3" = "pid=,ppid=,command=" ]; then
    cat "\$fixture_dir/ps_tree"
elif [ "\$1" = "-p" ] && [ "\$3" = "-o" ] && [ "\$4" = "command=" ]; then
    case "\$2" in
        200) cat "\$fixture_dir/ps_command" ;;
        *) exit 1 ;;
    esac
else
    exit 1
fi
EOF
    chmod +x "$ps_path"
}

setup_save_fixture() {
    local fixture_dir="$1"
    local tool="$2"
    local sid="$3"
    local cwd="$4"

    mkdir -p "$fixture_dir/bin" "$fixture_dir/resurrect" "$fixture_dir/home"
    printf '%s\n' "$fixture_dir/resurrect" > "$fixture_dir/resurrect_dir"
    printf '%s\n' "0" > "$fixture_dir/sessions"
    printf '%s\n' "1" > "$fixture_dir/windows"
    printf '%s\n' "1" > "$fixture_dir/panes"
    printf '%s\n' "work-win" > "$fixture_dir/window_name"
    printf '%s\n' "100" > "$fixture_dir/pane_pid"
    printf '%s\n' "$cwd" > "$fixture_dir/pane_current_path"
    printf '%s\n' fish > "$fixture_dir/pane_current_command"
    printf ' 100     1 fish\n 200   100 %s --resume %s\n' "$tool" "$sid" > "$fixture_dir/ps_tree"
    printf '%s --resume %s\n' "$tool" "$sid" > "$fixture_dir/ps_command"
    case "$tool" in
        claude)
            printf '%s\n' "$sid" > "$fixture_dir/claude_session_id"
            : > "$fixture_dir/claude_session_pid"
            printf '%s\n' "$cwd" > "$fixture_dir/claude_cwd"
            ;;
        codex)
            printf '%s\n' "$sid" > "$fixture_dir/codex_session_id"
            : > "$fixture_dir/codex_session_pid"
            printf '%s\n' "$cwd" > "$fixture_dir/codex_cwd"
            ;;
    esac
    write_save_tmux_stub "$fixture_dir/bin/tmux" "$fixture_dir"
    write_save_ps_stub "$fixture_dir/bin/ps" "$fixture_dir"
}

setup_save_just_recipe_fixture() {
    local fixture_dir="$1"
    local recipe="$2"
    local cwd="$3"

    mkdir -p "$fixture_dir/bin" "$fixture_dir/resurrect" "$fixture_dir/home"
    printf '%s\n' "$fixture_dir/resurrect" > "$fixture_dir/resurrect_dir"
    printf '%s\n' "0" > "$fixture_dir/sessions"
    printf '%s\n' "1" > "$fixture_dir/windows"
    printf '%s\n' "1" > "$fixture_dir/panes"
    printf '%s\n' "work-win" > "$fixture_dir/window_name"
    printf '%s\n' "100" > "$fixture_dir/pane_pid"
    printf '%s\n' "$cwd" > "$fixture_dir/pane_current_path"
    printf '%s\n' just > "$fixture_dir/pane_current_command"
    printf ' 100     1 fish\n 200   100 just %s\n' "$recipe" > "$fixture_dir/ps_tree"
    printf 'just %s\n' "$recipe" > "$fixture_dir/ps_command"
    write_save_tmux_stub "$fixture_dir/bin/tmux" "$fixture_dir"
    write_save_ps_stub "$fixture_dir/bin/ps" "$fixture_dir"
}

run_save_fixture() {
    local fixture_dir="$1"
    local old_path="$PATH"
    local old_home_set="${HOME+x}"
    local old_home="${HOME-}"
    PATH="$fixture_dir/bin:$PATH"
    HOME="$fixture_dir/home"
    bash "$PLUGIN_DIR/scripts/session-save.sh" >/dev/null 2>"$fixture_dir/save.err"
    local rc=$?
    PATH="$old_path"
    if [ -n "$old_home_set" ]; then
        HOME="$old_home"
    else
        unset HOME
    fi
    return "$rc"
}

run_restore_fixture() {
    local fixture_dir="$1"
    local old_path="$PATH"
    PATH="$fixture_dir/bin:$PATH"
    TMUX_CLAUDE_RESTORE_BOOT_DELAY=0 bash "$PLUGIN_DIR/scripts/session-restore.sh" --dry-run > "$fixture_dir/restore.out" 2>"$fixture_dir/restore.err"
    local rc=$?
    PATH="$old_path"
    return "$rc"
}

CLAUDE_UUID_SAVE=0cbb1761-1a50-4cc4-8e7d-7b4bbdc788bf
CODEX_UUID_SAVE=019dd3be-9166-7750-8039-a1f9ecdad1f3

tmpdir=$(mktemp -d)
setup_save_fixture "$tmpdir" claude "$CLAUDE_UUID_SAVE" "$tmpdir/project"
mkdir -p "$tmpdir/project" "$tmpdir/home/.claude/projects/work"
: > "$tmpdir/home/.claude/projects/work/$CLAUDE_UUID_SAVE.jsonl"
run_save_fixture "$tmpdir"
save_rc=$?
assert_eq "save writes v2 fixture exits 0" "0" "$save_rc"
assert_eq "save writes v2 header" \
    "# tmux-claude snapshot v2" \
    "$(sed -n '1p' "$tmpdir/resurrect/claude-panes.txt" 2>/dev/null)"
rows=$(snapshot_read "$tmpdir/resurrect/claude-panes.txt" 2>/dev/null)
bad_field_count=$(printf '%s\n' "$rows" | awk -F'\t' 'NF != 8 { print NF; exit }')
assert_eq "save writes eight fields" "" "$bad_field_count"
rm -rf "$tmpdir"

tmpdir=$(mktemp -d)
setup_save_fixture "$tmpdir" claude "$CLAUDE_UUID_SAVE" "$tmpdir/project"
mkdir -p "$tmpdir/project" "$tmpdir/home/.claude/projects/work" "$tmpdir/resurrect/.claude-save.lock"
: > "$tmpdir/home/.claude/projects/work/$CLAUDE_UUID_SAVE.jsonl"
TMUX_CLAUDE_SAVE_LOCK_STALE_SECONDS=0 run_save_fixture "$tmpdir"
save_rc=$?
assert_eq "save recovers stale empty lock exits 0" "0" "$save_rc"
assert_eq "save recovers stale empty lock writes snapshot" \
    "# tmux-claude snapshot v2" \
    "$(sed -n '1p' "$tmpdir/resurrect/claude-panes.txt" 2>/dev/null)"
rm -rf "$tmpdir"

tmpdir=$(mktemp -d)
setup_save_fixture "$tmpdir" claude "$CLAUDE_UUID_SAVE" "$tmpdir/project"
mkdir -p "$tmpdir/project" "$tmpdir/home/.claude/projects/work" "$tmpdir/resurrect/.claude-save.lock"
: > "$tmpdir/home/.claude/projects/work/$CLAUDE_UUID_SAVE.jsonl"
cat > "$tmpdir/bin/stat" <<'EOF'
#!/usr/bin/env bash
if [ "$1" = "-f" ] && [ "$2" = "%m" ]; then
    printf '%s\n' "not-a-bsd-mtime"
    exit 0
fi
if [ "$1" = "-c" ] && [ "$2" = "%Y" ]; then
    printf '%s\n' 0
    exit 0
fi
exit 1
EOF
chmod +x "$tmpdir/bin/stat"
run_save_fixture "$tmpdir"
assert_eq "save recovers stale lock with GNU stat fallback" \
    "# tmux-claude snapshot v2" \
    "$(sed -n '1p' "$tmpdir/resurrect/claude-panes.txt" 2>/dev/null)"
rm -rf "$tmpdir"

tmpdir=$(mktemp -d)
setup_save_fixture "$tmpdir" claude "$CLAUDE_UUID_SAVE" "$tmpdir/project"
mkdir -p "$tmpdir/project" "$tmpdir/home/.claude/projects/work" "$tmpdir/resurrect/.claude-save.lock"
: > "$tmpdir/home/.claude/projects/work/$CLAUDE_UUID_SAVE.jsonl"
printf '%s\n' 999999 > "$tmpdir/resurrect/.claude-save.lock/pid"
run_save_fixture "$tmpdir"
assert_eq "save recovers stale dead-pid lock" \
    "# tmux-claude snapshot v2" \
    "$(sed -n '1p' "$tmpdir/resurrect/claude-panes.txt" 2>/dev/null)"
rm -rf "$tmpdir"

tmpdir=$(mktemp -d)
setup_save_fixture "$tmpdir" claude "$CLAUDE_UUID_SAVE" "$tmpdir/project"
mkdir -p "$tmpdir/project" "$tmpdir/home/.claude/projects/work" "$tmpdir/resurrect/.claude-save.lock"
: > "$tmpdir/home/.claude/projects/work/$CLAUDE_UUID_SAVE.jsonl"
sleep 10 &
sleep_pid=$!
printf '%s\n' "$sleep_pid" > "$tmpdir/resurrect/.claude-save.lock/pid"
TMUX_CLAUDE_SAVE_LOCK_STALE_SECONDS=0 run_save_fixture "$tmpdir"
kill "$sleep_pid" 2>/dev/null || true
wait "$sleep_pid" 2>/dev/null || true
assert_eq "save recovers stale unrelated-live-pid lock" \
    "# tmux-claude snapshot v2" \
    "$(sed -n '1p' "$tmpdir/resurrect/claude-panes.txt" 2>/dev/null)"
rm -rf "$tmpdir"

tmpdir=$(mktemp -d)
mkdir -p "$tmpdir/bin" "$tmpdir/resurrect" "$tmpdir/home" "$tmpdir/resurrect/.claude-save.lock"
printf '%s\n' "$tmpdir/resurrect" > "$tmpdir/resurrect_dir"
printf '%s\n' "precious snapshot" > "$tmpdir/resurrect/claude-panes.txt"
write_save_tmux_stub "$tmpdir/bin/tmux" "$tmpdir"
bash -c 'sleep 10' session-save.sh &
save_like_pid=$!
cat > "$tmpdir/bin/ps" <<EOF
#!/usr/bin/env bash
if [ "\$1" = "-p" ] && [ "\$2" = "$save_like_pid" ] && [ "\$3" = "-o" ] && [ "\$4" = "command=" ]; then
    printf '%s\n' "bash /tmp/session-save.sh"
    exit 0
fi
exit 1
EOF
chmod +x "$tmpdir/bin/ps"
printf '%s\n' "$save_like_pid" > "$tmpdir/resurrect/.claude-save.lock/pid"
printf '%s\n' "other-token" > "$tmpdir/resurrect/.claude-save.lock/token"
TMUX_CLAUDE_SAVE_LOCK_STALE_SECONDS=0 TMUX_CLAUDE_SAVE_LOCK_ATTEMPTS=1 run_save_fixture "$tmpdir"
kill "$save_like_pid" 2>/dev/null || true
wait "$save_like_pid" 2>/dev/null || true
assert_eq "save preserves active session-save lock snapshot" \
    "precious snapshot" \
    "$(cat "$tmpdir/resurrect/claude-panes.txt")"
assert_eq "save preserves active session-save lock directory" \
    "present" \
    "$([ -d "$tmpdir/resurrect/.claude-save.lock" ] && echo present || echo absent)"
rm -rf "$tmpdir"

tmpdir=$(mktemp -d)
setup_save_fixture "$tmpdir" claude "$CLAUDE_UUID_SAVE" "$tmpdir/project"
mkdir -p "$tmpdir/project"
run_save_fixture "$tmpdir"
row=$(snapshot_read "$tmpdir/resurrect/claude-panes.txt" 2>/dev/null)
assert_eq "save_flags_sid_invalid sid cleared" "-" "$(printf '%s' "$row" | cut -f3)"
assert_eq "save_flags_sid_invalid sid_kind none" "none" "$(printf '%s' "$row" | cut -f4)"
assert_eq "save_flags_sid_invalid flag set" "sid_invalid" "$(printf '%s' "$row" | cut -f8)"
rm -rf "$tmpdir"

tmpdir=$(mktemp -d)
existing_cwd="$tmpdir/project"
missing_cwd="$existing_cwd/missing/deep"
setup_save_fixture "$tmpdir" claude "$CLAUDE_UUID_SAVE" "$missing_cwd"
mkdir -p "$existing_cwd" "$tmpdir/home/.claude/projects/work"
: > "$tmpdir/home/.claude/projects/work/$CLAUDE_UUID_SAVE.jsonl"
run_save_fixture "$tmpdir"
row=$(snapshot_read "$tmpdir/resurrect/claude-panes.txt" 2>/dev/null)
assert_eq "save_flags_cwd_collapsed cwd uses nearest existing parent" "$existing_cwd" "$(printf '%s' "$row" | cut -f5)"
assert_eq "save_flags_cwd_collapsed original_cwd preserves missing path" "$missing_cwd" "$(printf '%s' "$row" | cut -f6)"
assert_eq "save_flags_cwd_collapsed flag set" "cwd_collapsed" "$(printf '%s' "$row" | cut -f8)"
rm -rf "$tmpdir"

tmpdir=$(mktemp -d)
existing_cwd="$tmpdir/project"
missing_cwd="$existing_cwd/missing/deep"
setup_save_fixture "$tmpdir" claude "$CLAUDE_UUID_SAVE" "$missing_cwd"
mkdir -p "$existing_cwd"
run_save_fixture "$tmpdir"
row=$(snapshot_read "$tmpdir/resurrect/claude-panes.txt" 2>/dev/null)
assert_eq "save_flags_both_semicolon_separated sid cleared" "-" "$(printf '%s' "$row" | cut -f3)"
assert_eq "save_flags_both_semicolon_separated flags ordered" "sid_invalid;cwd_collapsed" "$(printf '%s' "$row" | cut -f8)"
rm -rf "$tmpdir"

tmpdir=$(mktemp -d)
mkdir -p "$tmpdir/bin" "$tmpdir/resurrect"
printf '%s\n' "$tmpdir/resurrect" > "$tmpdir/resurrect_dir"
: > "$tmpdir/sessions"
printf '%s\n' "precious snapshot" > "$tmpdir/resurrect/claude-panes.txt"
write_save_tmux_stub "$tmpdir/bin/tmux" "$tmpdir"
write_save_ps_stub "$tmpdir/bin/ps" "$tmpdir"
run_save_fixture "$tmpdir"
assert_eq "save_no_clobber_on_empty_preserved" \
    "precious snapshot" \
    "$(cat "$tmpdir/resurrect/claude-panes.txt")"
rm -rf "$tmpdir"

tmpdir=$(mktemp -d)
mkdir -p "$tmpdir/bin" "$tmpdir/resurrect"
printf '%s\n' "$tmpdir/resurrect" > "$tmpdir/resurrect_dir"
: > "$tmpdir/sessions"
write_save_tmux_stub "$tmpdir/bin/tmux" "$tmpdir"
write_save_ps_stub "$tmpdir/bin/ps" "$tmpdir"
run_save_fixture "$tmpdir"
assert_eq "save_no_empty_clobber_without_existing leaves no snapshot" \
    "absent" \
    "$([ -f "$tmpdir/resurrect/claude-panes.txt" ] && echo present || echo absent)"
partial_count=$(find "$tmpdir/resurrect" -name 'claude-panes.txt.*' -type f | wc -l | tr -d ' ')
assert_eq "save_no_empty_clobber_without_existing leaves no partial temp" "0" "$partial_count"
rm -rf "$tmpdir"

tmpdir=$(mktemp -d)
setup_save_fixture "$tmpdir" claude "$CLAUDE_UUID_SAVE" "$tmpdir/project"
mkdir -p "$tmpdir/project"
run_save_fixture "$tmpdir"
run_restore_fixture "$tmpdir"
restore_out=$(cat "$tmpdir/restore.out" 2>/dev/null || true)
restore_log_content=$(cat "$tmpdir/resurrect/restore.log" 2>/dev/null || true)
assert_not_contains "save_to_restore_e2e_sid_invalid emits no dry-run command" \
    "[dry-run] 0:1.1:" "$restore_out"
assert_contains "save_to_restore_e2e_sid_invalid logs skip" \
    "SKIP 0:1.1 claude sid_invalid" "$restore_log_content"
rm -rf "$tmpdir"

tmpdir=$(mktemp -d)
existing_cwd="$tmpdir/project"
missing_cwd="$existing_cwd/pruned/worktree"
setup_save_fixture "$tmpdir" codex "$CODEX_UUID_SAVE" "$missing_cwd"
mkdir -p "$existing_cwd" "$tmpdir/home/.codex/sessions/2026/05/25"
: > "$tmpdir/home/.codex/sessions/2026/05/25/rollout-2026-05-25T000000-$CODEX_UUID_SAVE.jsonl"
run_save_fixture "$tmpdir"
run_restore_fixture "$tmpdir"
restore_out=$(cat "$tmpdir/restore.out" 2>/dev/null || true)
restore_log_content=$(cat "$tmpdir/resurrect/restore.log" 2>/dev/null || true)
assert_contains "save_to_restore_e2e_cwd_collapsed uses collapsed cwd" \
    "cd '$existing_cwd' 2>/dev/null || cd;" "$restore_out"
assert_contains "save_to_restore_e2e_cwd_collapsed logs warning" \
    "WARN 0:1.1 codex cwd_collapsed orig=$missing_cwd new=$existing_cwd" "$restore_log_content"
rm -rf "$tmpdir"

for recipe in claude codex nvim; do
    tmpdir=$(mktemp -d)
    setup_save_just_recipe_fixture "$tmpdir" "$recipe" "$tmpdir/project"
    mkdir -p "$tmpdir/project"
    run_save_fixture "$tmpdir"
    row=$(snapshot_read "$tmpdir/resurrect/claude-panes.txt" 2>/dev/null)
    assert_eq "save_just_${recipe}_not_misclassified tool" "just" "$(printf '%s' "$row" | cut -f2)"
    assert_eq "save_just_${recipe}_recipe_sid" "$recipe" "$(printf '%s' "$row" | cut -f3)"
    assert_eq "save_just_${recipe}_sid_kind_recipe" "recipe" "$(printf '%s' "$row" | cut -f4)"
    rm -rf "$tmpdir"
done

# Regression: a codex pane whose foreground command is the real suffixed binary
# name ("codex-aarch64-a") AND has a live claude subagent in its process tree
# must still be saved as codex (via its valid @codex_session_id), not degraded
# to "claude picker". Before save_pane_adapter_hint matched suffixed names, the
# hint was dropped and adapter order (claude first) misclassified the pane.
tmpdir=$(mktemp -d)
mkdir -p "$tmpdir/bin" "$tmpdir/resurrect" "$tmpdir/home" "$tmpdir/project"
mkdir -p "$tmpdir/home/.codex/sessions/2026/06/15"
: > "$tmpdir/home/.codex/sessions/2026/06/15/rollout-2026-06-15T000000-$CODEX_UUID_SAVE.jsonl"
printf '%s\n' "$tmpdir/resurrect" > "$tmpdir/resurrect_dir"
printf '%s\n' "0" > "$tmpdir/sessions"
printf '%s\n' "1" > "$tmpdir/windows"
printf '%s\n' "1" > "$tmpdir/panes"
printf '%s\n' "work-win" > "$tmpdir/window_name"
printf '%s\n' "100" > "$tmpdir/pane_pid"
printf '%s\n' "$tmpdir/project" > "$tmpdir/pane_current_path"
printf '%s\n' "codex-aarch64-a" > "$tmpdir/pane_current_command"
printf '%s\n' "$CODEX_UUID_SAVE" > "$tmpdir/codex_session_id"
: > "$tmpdir/codex_session_pid"
printf '%s\n' "$tmpdir/project" > "$tmpdir/codex_cwd"
# Two live agents under the same pane shell: codex primary + claude subagent.
{
    printf ' 100     1 fish\n'
    printf ' 200   100 codex-aarch64-a --yolo -s workspace-write\n'
    printf ' 300   100 claude --dangerously-skip-permissions\n'
} > "$tmpdir/ps_tree"
write_save_tmux_stub "$tmpdir/bin/tmux" "$tmpdir"
cat > "$tmpdir/bin/ps" <<EOF
#!/usr/bin/env bash
fixture_dir='$tmpdir'
if [ "\$1" = "-axww" ] && [ "\$2" = "-o" ] && [ "\$3" = "pid=,ppid=,command=" ]; then
    cat "\$fixture_dir/ps_tree"
elif [ "\$1" = "-p" ] && [ "\$3" = "-o" ] && [ "\$4" = "command=" ]; then
    case "\$2" in
        200) printf '%s\n' "codex-aarch64-a --yolo -s workspace-write" ;;
        300) printf '%s\n' "claude --dangerously-skip-permissions" ;;
        *) exit 1 ;;
    esac
else
    exit 1
fi
EOF
chmod +x "$tmpdir/bin/ps"
run_save_fixture "$tmpdir"
row=$(snapshot_read "$tmpdir/resurrect/claude-panes.txt" 2>/dev/null)
assert_eq "save_suffixed_codex_with_claude_subagent tool" "codex" "$(printf '%s' "$row" | cut -f2)"
assert_eq "save_suffixed_codex_with_claude_subagent sid" "$CODEX_UUID_SAVE" "$(printf '%s' "$row" | cut -f3)"
rm -rf "$tmpdir"

# Coexistence safety: a pane may carry BOTH @claude_session_id and
# @codex_session_id (hooks no longer clear the other tool's vars). With only a
# live claude in the pane, save must use the claude session and ignore the stale
# codex var — the invariant that makes not-clearing safe.
tmpdir=$(mktemp -d)
mkdir -p "$tmpdir/bin" "$tmpdir/resurrect" "$tmpdir/home" "$tmpdir/project"
mkdir -p "$tmpdir/home/.claude/projects/work" "$tmpdir/home/.codex/sessions/2026/06/15"
: > "$tmpdir/home/.claude/projects/work/$CLAUDE_UUID_SAVE.jsonl"
: > "$tmpdir/home/.codex/sessions/2026/06/15/rollout-2026-06-15T000000-$CODEX_UUID_SAVE.jsonl"
printf '%s\n' "$tmpdir/resurrect" > "$tmpdir/resurrect_dir"
printf '%s\n' "0" > "$tmpdir/sessions"
printf '%s\n' "1" > "$tmpdir/windows"
printf '%s\n' "1" > "$tmpdir/panes"
printf '%s\n' "work-win" > "$tmpdir/window_name"
printf '%s\n' "100" > "$tmpdir/pane_pid"
printf '%s\n' "$tmpdir/project" > "$tmpdir/pane_current_path"
printf '%s\n' "claude.exe" > "$tmpdir/pane_current_command"
# Both tools' vars present; only claude is live in the process tree.
printf '%s\n' "$CLAUDE_UUID_SAVE" > "$tmpdir/claude_session_id"
: > "$tmpdir/claude_session_pid"
printf '%s\n' "$tmpdir/project" > "$tmpdir/claude_cwd"
printf '%s\n' "$CODEX_UUID_SAVE" > "$tmpdir/codex_session_id"
: > "$tmpdir/codex_session_pid"
printf '%s\n' "$tmpdir/project" > "$tmpdir/codex_cwd"
printf ' 100     1 fish\n 200   100 claude.exe --resume %s\n' "$CLAUDE_UUID_SAVE" > "$tmpdir/ps_tree"
write_save_tmux_stub "$tmpdir/bin/tmux" "$tmpdir"
cat > "$tmpdir/bin/ps" <<EOF
#!/usr/bin/env bash
fixture_dir='$tmpdir'
if [ "\$1" = "-axww" ] && [ "\$2" = "-o" ] && [ "\$3" = "pid=,ppid=,command=" ]; then
    cat "\$fixture_dir/ps_tree"
elif [ "\$1" = "-p" ] && [ "\$3" = "-o" ] && [ "\$4" = "command=" ]; then
    case "\$2" in
        200) printf '%s\n' "claude.exe --resume $CLAUDE_UUID_SAVE" ;;
        *) exit 1 ;;
    esac
else
    exit 1
fi
EOF
chmod +x "$tmpdir/bin/ps"
run_save_fixture "$tmpdir"
row=$(snapshot_read "$tmpdir/resurrect/claude-panes.txt" 2>/dev/null)
assert_eq "save_coexisting_vars_uses_live_tool tool" "claude" "$(printf '%s' "$row" | cut -f2)"
assert_eq "save_coexisting_vars_uses_live_tool sid" "$CLAUDE_UUID_SAVE" "$(printf '%s' "$row" | cut -f3)"
assert_eq "save_coexisting_vars_one_row_only" "1" "$(printf '%s\n' "$row" | grep -c .)"
rm -rf "$tmpdir"

unset -f write_save_tmux_stub write_save_ps_stub setup_save_fixture setup_save_just_recipe_fixture run_save_fixture run_restore_fixture

# ============================================================
echo ""
echo "=== SessionStart hooks: pid stamping ==="
# ============================================================

CLAUDE_HOOK="$PLUGIN_DIR/scripts/claude-session-hook.sh"
CODEX_HOOK="$PLUGIN_DIR/scripts/codex-session-hook.sh"

write_hook_tmux_stub() {
    local tmux_path="$1"

    cat > "$tmux_path" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "${TMUX_HOOK_LOG:?}"

case "${1:-}" in
    display-message)
        case "$*" in
            *"#{pane_current_command}"*)
                printf '%s\n' "${TMUX_STUB_PANE_COMMAND:-fish}"
                ;;
            *"#{pane_pid}"*)
                printf '%s\n' "${TMUX_STUB_PANE_PID:-100}"
                ;;
            *)
                exit 1
                ;;
        esac
        ;;
esac
EOF
    chmod +x "$tmux_path"
}

setup_hook_fixture() {
    local tmpdir="$1"

    mkdir -p "$tmpdir/home" "$tmpdir/bin" "$tmpdir/plugin/lib"
    write_hook_tmux_stub "$tmpdir/bin/tmux"
    cat > "$tmpdir/plugin/lib/process.sh" <<'EOF'
live_agent_pid() { printf '%s\n' 4242; }
EOF
    cat > "$tmpdir/bin/ps" <<'EOF'
#!/usr/bin/env bash
if [ "$1" = "-axww" ] && [ "$2" = "-o" ] && [ "$3" = "pid=,ppid=,command=" ]; then
    printf '%s\n' "100 1 fish" "4242 100 claude codex agent"
elif [ "$1" = "-p" ] && [ "$3" = "-o" ] && [ "$4" = "ppid=" ]; then
    case "$2" in
        4242) printf '%s\n' 100 ;;
        100) printf '%s\n' 1 ;;
        *) exit 1 ;;
    esac
elif [ "$1" = "-p" ] && [ "$3" = "-o" ] && [ "$4" = "command=" ]; then
    case "$2" in
        4242) printf '%s\n' "claude codex agent" ;;
        100) printf '%s\n' fish ;;
        *) exit 1 ;;
    esac
else
    exit 1
fi
EOF
    chmod +x "$tmpdir/bin/ps"
}

run_hook_fixture() {
    local hook_script="$1"
    local tmpdir="$2"
    local session_id="$3"
    local cwd="$4"
    local pane_command="${5:-fish}"
    local hook_pid_file="$tmpdir/hook.pid"
    local json

    json="{\"session_id\":\"$session_id\",\"cwd\":\"$cwd\"}"
    TMUX=1 \
    TMUX_PANE="%1" \
    TMUX_CLAUDE_PLUGIN_DIR="$tmpdir/plugin" \
    TMUX_HOOK_LOG="$tmpdir/tmux.log" \
    TMUX_STUB_PANE_COMMAND="$pane_command" \
    HOME="$tmpdir/home" \
    PATH="$tmpdir/bin:$PATH" \
    HOOK_SCRIPT="$hook_script" \
    HOOK_PID_FILE="$hook_pid_file" \
        bash -c 'printf "%s\n" "$$" > "$HOOK_PID_FILE"; exec bash "$HOOK_SCRIPT"' <<<"$json"
}

if [ ! -f "$CLAUDE_HOOK" ]; then
    echo "  WARN: Claude SessionStart hook missing at $CLAUDE_HOOK; skipping hook integration test"
else
    tmpdir=$(mktemp -d)
    setup_hook_fixture "$tmpdir"
    claude_cwd="$tmpdir/claude-cwd"
    run_hook_fixture "$CLAUDE_HOOK" "$tmpdir" "claude-hook-session" "$claude_cwd"
    hook_rc=$?
    hook_log=$(cat "$tmpdir/tmux.log" 2>/dev/null || true)
    hook_pid=$(cat "$tmpdir/hook.pid" 2>/dev/null || true)

    assert_eq "Claude hook exits 0" "0" "$hook_rc"
    assert_contains "Claude hook sets @claude_session_id" \
        "set-option -p -t %1 @claude_session_id claude-hook-session" "$hook_log"
    assert_contains "Claude hook sets @claude_session_pid 4242" \
        "set-option -p -t %1 @claude_session_pid 4242" "$hook_log"
    assert_contains "Claude hook sets @claude_cwd" \
        "set-option -p -t %1 @claude_cwd $claude_cwd" "$hook_log"
    # Coexistence: the hook must NOT clear the other tool's vars. A pane can host
    # both tools; clearing would wipe a live session id and degrade restore to a
    # picker. The saver disambiguates by foreground + live process instead.
    assert_not_contains "Claude hook does not clear @codex_session_id" \
        "set-option -pu -t %1 @codex_session_id" "$hook_log"
    assert_not_contains "Claude hook does not clear @codex_cwd" \
        "set-option -pu -t %1 @codex_cwd" "$hook_log"
    assert_not_contains "Claude hook does not clear @codex_session_pid" \
        "set-option -pu -t %1 @codex_session_pid" "$hook_log"
    assert_not_contains "Claude hook does not write test runner pid as session pid" \
        "@claude_session_pid $$" "$hook_log"
    assert_not_contains "Claude hook does not write hook process pid as session pid" \
        "@claude_session_pid $hook_pid" "$hook_log"

    rm -rf "$tmpdir"
fi

if [ -f "$CLAUDE_HOOK" ]; then
    tmpdir=$(mktemp -d)
    setup_hook_fixture "$tmpdir"
    run_hook_fixture "$CLAUDE_HOOK" "$tmpdir" "claude-subagent-session" "$tmpdir/cwd" "codex-aarch64-a"
    hook_rc=$?
    hook_log=$(cat "$tmpdir/tmux.log" 2>/dev/null || true)

    assert_eq "Claude hook exits 0 inside suffixed codex pane" "0" "$hook_rc"
    assert_not_contains "Claude hook skips suffixed codex pane" \
        "set-option -p -t %1 @claude_session_id" "$hook_log"

    rm -rf "$tmpdir"
fi

if [ ! -f "$CODEX_HOOK" ]; then
    echo "  WARN: Codex SessionStart hook missing at $CODEX_HOOK; skipping hook integration test"
else
    tmpdir=$(mktemp -d)
    setup_hook_fixture "$tmpdir"
    codex_cwd="$tmpdir/codex-cwd"
    run_hook_fixture "$CODEX_HOOK" "$tmpdir" "codex-hook-session" "$codex_cwd"
    hook_rc=$?
    hook_log=$(cat "$tmpdir/tmux.log" 2>/dev/null || true)
    hook_pid=$(cat "$tmpdir/hook.pid" 2>/dev/null || true)

    assert_eq "Codex hook exits 0" "0" "$hook_rc"
    assert_contains "Codex hook sets @codex_session_id" \
        "set-option -p -t %1 @codex_session_id codex-hook-session" "$hook_log"
    assert_contains "Codex hook sets @codex_session_pid 4242" \
        "set-option -p -t %1 @codex_session_pid 4242" "$hook_log"
    assert_contains "Codex hook sets @codex_cwd" \
        "set-option -p -t %1 @codex_cwd $codex_cwd" "$hook_log"
    # Coexistence: the hook must NOT clear the other tool's vars (see Claude case).
    assert_not_contains "Codex hook does not clear @claude_session_id" \
        "set-option -pu -t %1 @claude_session_id" "$hook_log"
    assert_not_contains "Codex hook does not clear @claude_cwd" \
        "set-option -pu -t %1 @claude_cwd" "$hook_log"
    assert_not_contains "Codex hook does not clear @claude_session_pid" \
        "set-option -pu -t %1 @claude_session_pid" "$hook_log"
    assert_not_contains "Codex hook does not write test runner pid as session pid" \
        "@codex_session_pid $$" "$hook_log"
    assert_not_contains "Codex hook does not write hook process pid as session pid" \
        "@codex_session_pid $hook_pid" "$hook_log"

    rm -rf "$tmpdir"
fi

if [ -f "$CODEX_HOOK" ]; then
    tmpdir=$(mktemp -d)
    setup_hook_fixture "$tmpdir"
    run_hook_fixture "$CODEX_HOOK" "$tmpdir" "codex-subagent-session" "$tmpdir/cwd" "claude-code"
    hook_rc=$?
    hook_log=$(cat "$tmpdir/tmux.log" 2>/dev/null || true)

    assert_eq "Codex hook exits 0 inside suffixed claude pane" "0" "$hook_rc"
    assert_not_contains "Codex hook skips suffixed claude pane" \
        "set-option -p -t %1 @codex_session_id" "$hook_log"

    rm -rf "$tmpdir"
fi

write_real_hook_ps_stub() {
    local ps_path="$1"
    local fixture_dir="$2"

    cat > "$ps_path" <<EOF
#!/usr/bin/env bash
fixture_dir='$fixture_dir'
if [ "\$1" = "-axww" ] && [ "\$2" = "-o" ] && [ "\$3" = "pid=,ppid=,command=" ]; then
    cat "\$fixture_dir/ps_tree"
elif [ "\$1" = "-p" ] && [ "\$3" = "-o" ] && [ "\$4" = "ppid=" ]; then
    case "\$2" in
        100) printf '%s\n' 1 ;;
        200) printf '%s\n' 100 ;;
        300) printf '%s\n' 200 ;;
        400) printf '%s\n' 300 ;;
        *) exit 1 ;;
    esac
elif [ "\$1" = "-p" ] && [ "\$3" = "-o" ] && [ "\$4" = "command=" ]; then
    case "\$2" in
        100) printf '%s\n' fish ;;
        200) cat "\$fixture_dir/ps_command_200" ;;
        300) cat "\$fixture_dir/ps_command_300" ;;
        400) cat "\$fixture_dir/ps_command_400" ;;
        *) exit 1 ;;
    esac
else
    exit 1
fi
EOF
    chmod +x "$ps_path"
}

setup_real_hook_fixture() {
    local tmpdir="$1"
    local tool="$2"
    local hook_script="$3"

    mkdir -p "$tmpdir/home" "$tmpdir/bin" "$tmpdir/plugin/lib"
    write_hook_tmux_stub "$tmpdir/bin/tmux"
    cp "$PLUGIN_DIR/lib/process.sh" "$tmpdir/plugin/lib/process.sh"
    printf '%s\n' " 100     1 fish" > "$tmpdir/ps_tree"
    printf ' 200   100 %s --resume real-session\n' "$tool" >> "$tmpdir/ps_tree"
    printf ' 300   200 bash %s\n' "$hook_script" >> "$tmpdir/ps_tree"
    printf ' 400   300 awk -v root=100 -v tool=%s ...\n' "$tool" >> "$tmpdir/ps_tree"
    printf '%s --resume real-session\n' "$tool" > "$tmpdir/ps_command_200"
    printf 'bash %s\n' "$hook_script" > "$tmpdir/ps_command_300"
    printf 'awk -v root=100 -v tool=%s ...\n' "$tool" > "$tmpdir/ps_command_400"
    write_real_hook_ps_stub "$tmpdir/bin/ps" "$tmpdir"
}

if [ ! -f "$CLAUDE_HOOK" ]; then
    echo "  WARN: Claude SessionStart hook missing at $CLAUDE_HOOK; skipping real helper hook integration test"
else
    tmpdir=$(mktemp -d)
    setup_real_hook_fixture "$tmpdir" claude "$CLAUDE_HOOK"
    claude_cwd="$tmpdir/claude-real-cwd"
    run_hook_fixture "$CLAUDE_HOOK" "$tmpdir" "claude-real-session" "$claude_cwd"
    hook_rc=$?
    hook_log=$(cat "$tmpdir/tmux.log" 2>/dev/null || true)

    assert_eq "Claude real helper hook process test exits 0" "0" "$hook_rc"
    assert_contains "Claude real helper stamps real agent pid 200" \
        "set-option -p -t %1 @claude_session_pid 200" "$hook_log"
    assert_not_contains "Claude real helper rejects hook process pid 300" \
        "@claude_session_pid 300" "$hook_log"
    assert_not_contains "Claude real helper rejects hook helper child pid 400" \
        "@claude_session_pid 400" "$hook_log"

    rm -rf "$tmpdir"
fi

if [ ! -f "$CODEX_HOOK" ]; then
    echo "  WARN: Codex SessionStart hook missing at $CODEX_HOOK; skipping real helper hook integration test"
else
    tmpdir=$(mktemp -d)
    setup_real_hook_fixture "$tmpdir" codex "$CODEX_HOOK"
    codex_cwd="$tmpdir/codex-real-cwd"
    run_hook_fixture "$CODEX_HOOK" "$tmpdir" "codex-real-session" "$codex_cwd"
    hook_rc=$?
    hook_log=$(cat "$tmpdir/tmux.log" 2>/dev/null || true)

    assert_eq "Codex real helper hook process test exits 0" "0" "$hook_rc"
    assert_contains "Codex real helper stamps real agent pid 200" \
        "set-option -p -t %1 @codex_session_pid 200" "$hook_log"
    assert_not_contains "Codex real helper rejects hook process pid 300" \
        "@codex_session_pid 300" "$hook_log"
    assert_not_contains "Codex real helper rejects hook helper child pid 400" \
        "@codex_session_pid 400" "$hook_log"

    rm -rf "$tmpdir"
fi

unset -f write_hook_tmux_stub setup_hook_fixture run_hook_fixture
unset -f write_real_hook_ps_stub setup_real_hook_fixture

# ============================================================
echo ""
echo "=== session-restore: paths with spaces ==="
# ============================================================

tmpdir=$(mktemp -d)
cat > "$tmpdir/claude-panes.txt" <<'EOF'
0:1.1|claude|abc-123|/Users/test/my project/src|spaced-path
EOF

cmds=""
while IFS='|' read -r target tool sid cwd wname; do
    [[ "$target" =~ ^#.*$ ]] && continue
    [ -z "$target" ] && continue
    if [ "$tool" = "claude" ]; then
        cmds="cd \"$cwd\" && ccy --resume $sid"
    fi
done < "$tmpdir/claude-panes.txt"

assert_contains "path with space is quoted" 'cd "/Users/test/my project/src"' "$cmds"

rm -rf "$tmpdir"

# ============================================================
echo ""
echo "=== session-restore: comment and blank line handling ==="
# ============================================================

tmpdir=$(mktemp -d)
cat > "$tmpdir/claude-panes.txt" <<'EOF'
# This is a comment
# Another comment

0:1.1|claude|abc-123|/tmp|win1

EOF

count=0
while IFS='|' read -r target tool sid cwd wname; do
    [[ "$target" =~ ^#.*$ ]] && continue
    [ -z "$target" ] && continue
    count=$((count + 1))
done < "$tmpdir/claude-panes.txt"

assert_eq "skips comments and blanks, finds 1 entry" "1" "$count"

rm -rf "$tmpdir"

# ============================================================
echo ""
echo "=== fish wrapper: skip flag detection ==="
# ============================================================

if command -v fish &>/dev/null; then
    test_skip() {
        local flags="$1" expected="$2"
        local result
        result=$(fish -c "
            source $PLUGIN_DIR/shell/__tmux_claude_find_session.fish
            source $PLUGIN_DIR/shell/__tmux_claude_session_args.fish
            set -gx TMUX '/tmp/test,1,0'
            set -gx TMUX_PANE '%0'
            function tmux
                switch \$argv[5]
                    case '#{window_name}'; echo my-window
                    case '#{window_panes}'; echo 1
                    case '#{pane_index}'; echo 1
                end
            end
            set result (__tmux_claude_session_args $flags)
            test -n \"\$result\"; and echo 'injected'; or echo 'skipped'
        " 2>/dev/null)
        assert_eq "flags '$flags' -> $expected" "$expected" "$result"
    }

    test_skip "" "injected"
    test_skip "--dangerously-skip-permissions" "injected"
    test_skip "--teammate-mode tmux" "injected"
    test_skip "--resume abc" "skipped"
    test_skip "-r abc" "skipped"
    test_skip "--continue" "skipped"
    test_skip "-c" "skipped"
    test_skip "--print" "skipped"
    test_skip "-p" "skipped"
    test_skip "--name custom" "skipped"
else
    echo "  SKIP: fish not installed"
fi

# ============================================================
echo ""
echo "=== session lookup: JSONL customTitle matching ==="
# ============================================================

if command -v fish &>/dev/null && command -v python3 &>/dev/null; then
    fixture_dir=$(mktemp -d)

    # Create test JSONL files with proper customTitle entries
    echo '{"type":"custom-title","customTitle":"redbot.2"}' > "$fixture_dir/aaaa-1111.jsonl"
    echo '{"type":"custom-title","customTitle":"other-session"}' > "$fixture_dir/bbbb-2222.jsonl"
    # False positive test: target appears in a non-customTitle field
    echo '{"type":"custom-title","customTitle":"unrelated","notes":"redbot.2"}' > "$fixture_dir/cccc-3333.jsonl"
    # Ensure mtime ordering: touch aaaa last so it's "newest"
    sleep 0.1
    touch "$fixture_dir/aaaa-1111.jsonl"

    # Test: exact match returns correct UUID
    result=$(fish -c "
        source $PLUGIN_DIR/shell/__tmux_claude_find_session.fish
        function pwd; echo /test/dir; end
        set -l HOME_backup \$HOME
        python3 -c \"
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
            if not line: continue
            try: obj = json.loads(line)
            except: continue
            if obj.get('type') == 'custom-title':
                if obj.get('customTitle') == target:
                    print(fname[:-6])
                    sys.exit(0)
                break
\" '$fixture_dir' 'redbot.2'
    " 2>/dev/null)
    assert_eq "exact match finds correct session" "aaaa-1111" "$result"

    # Test: no match returns empty
    result=$(fish -c "
        python3 -c \"
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
            if not line: continue
            try: obj = json.loads(line)
            except: continue
            if obj.get('type') == 'custom-title':
                if obj.get('customTitle') == target:
                    print(fname[:-6])
                    sys.exit(0)
                break
\" '$fixture_dir' 'nonexistent'
    " 2>/dev/null)
    assert_eq "no match returns empty" "" "$result"

    # Test: does NOT false-positive on target in other fields
    result=$(fish -c "
        python3 -c \"
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
            if not line: continue
            try: obj = json.loads(line)
            except: continue
            if obj.get('type') == 'custom-title':
                if obj.get('customTitle') == target:
                    print(fname[:-6])
                    sys.exit(0)
                break
\" '$fixture_dir' 'unrelated'
    " 2>/dev/null)
    assert_eq "does not false-positive on notes field" "cccc-3333" "$result"

    # Test: substring of target does NOT match (redbot vs redbot.2)
    result=$(fish -c "
        python3 -c \"
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
            if not line: continue
            try: obj = json.loads(line)
            except: continue
            if obj.get('type') == 'custom-title':
                if obj.get('customTitle') == target:
                    print(fname[:-6])
                    sys.exit(0)
                break
\" '$fixture_dir' 'redbot'
    " 2>/dev/null)
    assert_eq "substring does not match (redbot vs redbot.2)" "" "$result"

    rm -rf "$fixture_dir"
else
    echo "  SKIP: fish or python3 not installed"
fi

# ============================================================
echo ""
echo "=== fish wrapper: graceful degradation ==="
# ============================================================

if command -v fish &>/dev/null; then
    tmpbin=$(mktemp -d)
    printf '#!/bin/sh\necho "MOCK_ARGS: $@"\n' > "$tmpbin/claude"
    chmod +x "$tmpbin/claude"
    result=$(fish -c "
        set -gx PATH $tmpbin \$PATH
        set -gx TMUX '/tmp/test,1,0'
        functions -e __tmux_claude_session_args 2>/dev/null
        source $PLUGIN_DIR/shell/claude.fish
        claude --version
    " 2>/dev/null)
    rm -rf "$tmpbin"
    assert_contains "runs without helper" "MOCK_ARGS:" "$result"
    assert_not_contains "no --name when helper missing" "MOCK_ARGS: --name" "$result"

    result=$(fish -c "
        source $PLUGIN_DIR/shell/__tmux_claude_session_args.fish
        set -e TMUX 2>/dev/null
        set result (__tmux_claude_session_args --version)
        test -n \"\$result\"; and echo 'injected'; or echo 'skipped'
    " 2>/dev/null)
    assert_eq "no injection outside tmux" "skipped" "$result"
else
    echo "  SKIP: fish not installed"
fi

# ============================================================
echo ""
echo "=== claude.tmux: hook chaining ==="
# ============================================================

if [ -n "$TMUX" ]; then
    orig_save=$(tmux show-option -gqv @resurrect-hook-post-save-all 2>/dev/null)
    orig_restore=$(tmux show-option -gqv @resurrect-hook-post-restore-all 2>/dev/null)

    tmux set-option -g @resurrect-hook-post-save-all "echo existing-save" 2>/dev/null
    tmux set-option -g @resurrect-hook-post-restore-all "echo existing-restore" 2>/dev/null

    bash "$PLUGIN_DIR/claude.tmux" 2>/dev/null

    save_hook=$(tmux show-option -gqv @resurrect-hook-post-save-all 2>/dev/null)
    restore_hook=$(tmux show-option -gqv @resurrect-hook-post-restore-all 2>/dev/null)

    assert_contains "save hook chains existing" "echo existing-save" "$save_hook"
    assert_contains "save hook adds session-save" "session-save.sh" "$save_hook"
    assert_contains "restore hook chains existing" "echo existing-restore" "$restore_hook"
    assert_contains "restore hook adds session-restore" "session-restore.sh" "$restore_hook"

    if [ -n "$orig_save" ]; then
        tmux set-option -g @resurrect-hook-post-save-all "$orig_save" 2>/dev/null
    else
        tmux set-option -gu @resurrect-hook-post-save-all 2>/dev/null
    fi
    if [ -n "$orig_restore" ]; then
        tmux set-option -g @resurrect-hook-post-restore-all "$orig_restore" 2>/dev/null
    else
        tmux set-option -gu @resurrect-hook-post-restore-all 2>/dev/null
    fi

    bash "$PLUGIN_DIR/claude.tmux" 2>/dev/null
else
    echo "  SKIP: not in tmux"
fi

# ============================================================
echo ""
echo "=== claude.tmux: idempotent reload ==="
# ============================================================

if [ -n "$TMUX" ]; then
    orig_save=$(tmux show-option -gqv @resurrect-hook-post-save-all 2>/dev/null)
    orig_restore=$(tmux show-option -gqv @resurrect-hook-post-restore-all 2>/dev/null)

    tmux set-option -gu @resurrect-hook-post-save-all 2>/dev/null
    tmux set-option -gu @resurrect-hook-post-restore-all 2>/dev/null

    bash "$PLUGIN_DIR/claude.tmux" 2>/dev/null
    bash "$PLUGIN_DIR/claude.tmux" 2>/dev/null

    save_hook=$(tmux show-option -gqv @resurrect-hook-post-save-all 2>/dev/null)
    restore_hook=$(tmux show-option -gqv @resurrect-hook-post-restore-all 2>/dev/null)

    save_count=$(echo "$save_hook" | grep -o 'session-save\.sh' | wc -l | tr -d ' ')
    restore_count=$(echo "$restore_hook" | grep -o 'session-restore\.sh' | wc -l | tr -d ' ')

    assert_eq "save hook appears exactly once after double load" "1" "$save_count"
    assert_eq "restore hook appears exactly once after double load" "1" "$restore_count"

    tmux set-option -gu @resurrect-hook-post-save-all 2>/dev/null
    tmux set-option -g @resurrect-hook-post-save-all "echo user-hook" 2>/dev/null
    bash "$PLUGIN_DIR/claude.tmux" 2>/dev/null
    bash "$PLUGIN_DIR/claude.tmux" 2>/dev/null
    save_hook=$(tmux show-option -gqv @resurrect-hook-post-save-all 2>/dev/null)
    save_count=$(echo "$save_hook" | grep -o 'session-save\.sh' | wc -l | tr -d ' ')
    assert_contains "user hook preserved after double load" "echo user-hook" "$save_hook"
    assert_eq "save hook once even with user hook + double load" "1" "$save_count"

    if [ -n "$orig_save" ]; then
        tmux set-option -g @resurrect-hook-post-save-all "$orig_save" 2>/dev/null
    else
        tmux set-option -gu @resurrect-hook-post-save-all 2>/dev/null
    fi
    if [ -n "$orig_restore" ]; then
        tmux set-option -g @resurrect-hook-post-restore-all "$orig_restore" 2>/dev/null
    else
        tmux set-option -gu @resurrect-hook-post-restore-all 2>/dev/null
    fi

    bash "$PLUGIN_DIR/claude.tmux" 2>/dev/null
else
    echo "  SKIP: not in tmux"
fi

# ============================================================
echo ""
echo "=== claude.tmux: tres auto-install ==="
# ============================================================

tmpdir=$(mktemp -d)
tmpbin="$tmpdir/bin"
tmux_home="$tmpdir/home"
mkdir -p "$tmpbin" "$tmux_home/.config/fish/functions"

cat > "$tmpbin/tmux" <<'EOF'
#!/usr/bin/env bash
case "$1" in
    show-option)
        case "$*" in
            *"@tmux-claude-auto-install-wrapper"*) exit 1 ;;
            *"@resurrect-dir"*) exit 1 ;;
            *) exit 1 ;;
        esac
        ;;
    show-environment)
        exit 1
        ;;
    display-message)
        printf '%s\n' "$*" >> "$TMUX_STUB_LOG"
        exit 0
        ;;
    *)
        exit 1
        ;;
esac
EOF
chmod +x "$tmpbin/tmux"

old_path="$PATH"
PATH="$tmpbin:$PATH"
HOME="$tmux_home" TMUX_STUB_LOG="$tmpdir/tmux.log" bash "$PLUGIN_DIR/claude.tmux"
rc=$?
PATH="$old_path"

assert_eq "claude.tmux auto-install exits 0" "0" "$rc"
assert_eq "claude.tmux installs tres fish function" \
    "present" \
    "$([ -f "$tmux_home/.config/fish/functions/tres.fish" ] && echo present || echo absent)"
assert_contains "installed tres contains function" \
    "function tres" \
    "$(cat "$tmux_home/.config/fish/functions/tres.fish" 2>/dev/null || true)"
assert_eq "claude.tmux still installs session args helper" \
    "present" \
    "$([ -f "$tmux_home/.config/fish/functions/__tmux_claude_session_args.fish" ] && echo present || echo absent)"

rm -rf "$tmpdir"

tmpdir=$(mktemp -d)
tmpbin="$tmpdir/bin"
tmux_home="$tmpdir/home"
mkdir -p "$tmpbin" "$tmux_home/.config/fish/functions"
printf '%s\n' "function tres; echo user; end" > "$tmux_home/.config/fish/functions/tres.fish"

cat > "$tmpbin/tmux" <<'EOF'
#!/usr/bin/env bash
case "$1" in
    show-option) exit 1 ;;
    show-environment) exit 1 ;;
    display-message)
        printf '%s\n' "$*" >> "$TMUX_STUB_LOG"
        exit 0
        ;;
    *) exit 1 ;;
esac
EOF
chmod +x "$tmpbin/tmux"

old_path="$PATH"
PATH="$tmpbin:$PATH"
HOME="$tmux_home" TMUX_STUB_LOG="$tmpdir/tmux.log" bash "$PLUGIN_DIR/claude.tmux"
rc=$?
PATH="$old_path"

installed_tres=$(cat "$tmux_home/.config/fish/functions/tres.fish")
display_log=$(cat "$tmpdir/tmux.log" 2>/dev/null || true)
assert_eq "claude.tmux existing tres exits 0" "0" "$rc"
assert_eq "claude.tmux does not overwrite existing tres" \
    "function tres; echo user; end" \
    "$installed_tres"
assert_contains "claude.tmux warns when existing tres is not plugin managed" \
    "tmux-claude: tres.fish already exists" "$display_log"

rm -rf "$tmpdir"

tmpdir=$(mktemp -d)
tmpbin="$tmpdir/bin"
tmux_home="$tmpdir/home"
mkdir -p "$tmpbin" "$tmux_home/.config/fish/functions"

cat > "$tmpbin/tmux" <<'EOF'
#!/usr/bin/env bash
case "$1" in
    show-option)
        case "$*" in
            *"@tmux-claude-auto-install-wrapper"*) printf '%s\n' off; exit 0 ;;
            *"@resurrect-dir"*) exit 1 ;;
            *) exit 1 ;;
        esac
        ;;
    show-environment) exit 1 ;;
    *) exit 1 ;;
esac
EOF
chmod +x "$tmpbin/tmux"

old_path="$PATH"
PATH="$tmpbin:$PATH"
HOME="$tmux_home" bash "$PLUGIN_DIR/claude.tmux"
rc=$?
PATH="$old_path"

assert_eq "claude.tmux auto-install off exits 0" "0" "$rc"
assert_eq "claude.tmux skips tres install when auto-install off" \
    "absent" \
    "$([ -f "$tmux_home/.config/fish/functions/tres.fish" ] && echo present || echo absent)"

rm -rf "$tmpdir"

# ============================================================
echo ""
echo "=== pane option coexistence (no cross-tool clearing) ==="
# ============================================================

if [ -n "$TMUX" ]; then
    test_pane=$(tmux display-message -p '#{pane_id}')

    # New design: each tracker sets only its own vars and never clears the other
    # tool's. A pane that hosted both tools must keep both ids so the saver can
    # pick by foreground; clearing was the source of the churn/picker bug.
    tmux set-option -p -t "$test_pane" @claude_session_id "claude-id" 2>/dev/null
    tmux set-option -p -t "$test_pane" @codex_session_id "codex-id" 2>/dev/null

    # Claude restarts in the pane: it restamps only its own id.
    tmux set-option -p -t "$test_pane" @claude_session_id "claude-id-2" 2>/dev/null
    claude_val=$(tmux show-options -p -t "$test_pane" -v @claude_session_id 2>/dev/null || true)
    codex_val=$(tmux show-options -p -t "$test_pane" -v @codex_session_id 2>/dev/null || true)
    assert_eq "claude restamp updates own id" "claude-id-2" "$claude_val"
    assert_eq "claude restamp leaves codex id intact" "codex-id" "$codex_val"

    # Codex restarts in the same pane: it restamps only its own id.
    tmux set-option -p -t "$test_pane" @codex_session_id "codex-id-2" 2>/dev/null
    claude_val=$(tmux show-options -p -t "$test_pane" -v @claude_session_id 2>/dev/null || true)
    codex_val=$(tmux show-options -p -t "$test_pane" -v @codex_session_id 2>/dev/null || true)
    assert_eq "codex restamp leaves claude id intact" "claude-id-2" "$claude_val"
    assert_eq "codex restamp updates own id" "codex-id-2" "$codex_val"

    # Cleanup
    tmux set-option -pu -t "$test_pane" @claude_session_id 2>/dev/null
    tmux set-option -pu -t "$test_pane" @claude_cwd 2>/dev/null
    tmux set-option -pu -t "$test_pane" @codex_session_id 2>/dev/null
    tmux set-option -pu -t "$test_pane" @codex_cwd 2>/dev/null
else
    echo "  SKIP: not in tmux"
fi

# ============================================================
echo ""
echo "=== fish wrapper: window-name based naming ==="
# ============================================================

if command -v fish &>/dev/null; then
    # Single pane: should produce --name <window_name> (no suffix)
    result=$(fish -c "
        source $PLUGIN_DIR/shell/__tmux_claude_session_args.fish
        set -gx TMUX '/tmp/test,1,0'
        set -gx TMUX_PANE '%0'
        function tmux
            switch \$argv[5]
                case '#{window_name}'; echo hypothesis-testing
                case '#{window_panes}'; echo 1
                case '#{pane_index}'; echo 1
            end
        end
        __tmux_claude_session_args
    " 2>/dev/null | tr '\n' ' ' | sed 's/ $//')
    assert_eq "single pane: name without suffix" "--name hypothesis-testing" "$result"

    # Multi pane: should produce --name <window_name>.<pane>
    result=$(fish -c "
        source $PLUGIN_DIR/shell/__tmux_claude_session_args.fish
        set -gx TMUX '/tmp/test,1,0'
        set -gx TMUX_PANE '%5'
        function tmux
            switch \$argv[5]
                case '#{window_name}'; echo my-editor
                case '#{window_panes}'; echo 3
                case '#{pane_index}'; echo 2
            end
        end
        __tmux_claude_session_args
    " 2>/dev/null | tr '\n' ' ' | sed 's/ $//')
    assert_eq "multi pane: name with pane suffix" "--name my-editor.2" "$result"

    # Edge case: empty window_panes (graceful fallback)
    result=$(fish -c "
        source $PLUGIN_DIR/shell/__tmux_claude_session_args.fish
        set -gx TMUX '/tmp/test,1,0'
        set -gx TMUX_PANE '%0'
        function tmux
            switch \$argv[5]
                case '#{window_name}'; echo solo
                case '#{window_panes}'; echo ''
                case '#{pane_index}'; echo 1
            end
        end
        __tmux_claude_session_args
    " 2>/dev/null | tr '\n' ' ' | sed 's/ $//')
    assert_eq "empty pane_count: no suffix" "--name solo" "$result"
else
    echo "  SKIP: fish not installed"
fi

# ============================================================
echo ""
echo "=== fish wrapper: fresh by default ==="
# ============================================================

if command -v fish &>/dev/null; then
    tmpdir=$(mktemp -d)
    project_dir="$tmpdir/.claude/projects/-repo"
    mkdir -p "$project_dir"
    echo '{"type":"custom-title","customTitle":"redbot"}' > "$project_dir/session-redbot.jsonl"

    run_fresh_default_args() {
        local extra="$1"
        local env_auto_resume="$2"
        HOME="$tmpdir" TMUX_CLAUDE_AUTO_RESUME="$env_auto_resume" fish -c "
            source $PLUGIN_DIR/shell/__tmux_claude_find_session.fish
            source $PLUGIN_DIR/shell/__tmux_claude_session_args.fish
            function pwd; echo /repo; end
            set -gx TMUX '/tmp/test,1,0'
            set -gx TMUX_PANE '%0'
            function tmux
                switch \$argv[5]
                    case '#{window_name}'; echo redbot
                    case '#{window_panes}'; echo 1
                    case '#{pane_index}'; echo 1
                end
            end
            __tmux_claude_session_args $extra
        " 2>/dev/null | tr '\n' ' ' | sed 's/ $//'
    }

    result=$(run_fresh_default_args "" "")
    assert_eq "fresh default names without resume" "--name redbot" "$result"

    result=$(run_fresh_default_args "" "1")
    assert_eq "auto-resume env resumes matching title" "--resume session-redbot --name redbot" "$result"

    result=$(run_fresh_default_args "--tmux-resume" "")
    assert_eq "auto-resume flag resumes matching title" "--resume session-redbot --name redbot" "$result"
    assert_not_contains "internal auto-resume flag is not forwarded" "--tmux-resume" "$result"

    tmpbin="$tmpdir/bin"
    mkdir -p "$tmpbin"
    cat > "$tmpbin/claude" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$@"
EOF
    chmod +x "$tmpbin/claude"
    wrapper_forwarded=$(PATH="$tmpbin:$PATH" fish -c "
        set -gx PATH $tmpbin \$PATH
        function __tmux_claude_session_args
            echo --resume session-redbot
            echo --name redbot
        end
        source $PLUGIN_DIR/shell/claude.fish
        claude --tmux-resume --dangerously-skip-permissions
    " 2>/dev/null | tr '\n' ' ' | sed 's/ $//')
    assert_eq "claude wrapper filters internal resume flag before exec" \
        "--resume session-redbot --name redbot --dangerously-skip-permissions" \
        "$wrapper_forwarded"

    unset -f run_fresh_default_args
    rm -rf "$tmpdir"
else
    echo "  SKIP: fish not installed"
fi

# ============================================================
echo ""
echo "=== session-restore: --name injection and sanitization ==="
# ============================================================

tmpdir=$(mktemp -d)

# Normal single-pane window
cat > "$tmpdir/claude-panes.txt" <<'EOF'
0:1.1|claude|aaa-111|/tmp|fine-tuning
EOF

# Simulate what session-restore does (inline parse + sanitize)
while IFS='|' read -r target tool sid cwd wname; do
    [[ "$target" =~ ^#.*$ ]] && continue
    [ -z "$target" ] && continue
    pane_idx="${target##*.}"
    # single pane (only 1 entry for this window)
    session_name="${wname}"
    session_name=$(printf '%s' "$session_name" | sed 's/[^A-Za-z0-9_.:-]/-/g')
    cmd="cd \"$cwd\" && ccy --name $session_name --resume $sid"
done < "$tmpdir/claude-panes.txt"
assert_contains "restore passes --name" "--name fine-tuning" "$cmd"
assert_contains "restore passes --resume UUID" "--resume aaa-111" "$cmd"

# Window name with shell metacharacters
cat > "$tmpdir/claude-panes.txt" <<'EOF'
0:1.1|claude|bbb-222|/tmp|bad;rm -rf /
EOF
while IFS='|' read -r target tool sid cwd wname; do
    [[ "$target" =~ ^#.*$ ]] && continue
    [ -z "$target" ] && continue
    session_name="${wname}"
    session_name=$(printf '%s' "$session_name" | sed 's/[^A-Za-z0-9_.:-]/-/g')
    cmd="cd \"$cwd\" && ccy --name $session_name --resume $sid"
done < "$tmpdir/claude-panes.txt"
assert_contains "metachar sanitized" "--name bad-rm--rf--" "$cmd"
assert_not_contains "no semicolons in cmd" ";" "$cmd"

# Window name with spaces
cat > "$tmpdir/claude-panes.txt" <<'EOF'
0:1.1|claude|ccc-333|/tmp|my window name
EOF
while IFS='|' read -r target tool sid cwd wname; do
    [[ "$target" =~ ^#.*$ ]] && continue
    [ -z "$target" ] && continue
    session_name="${wname}"
    session_name=$(printf '%s' "$session_name" | sed 's/[^A-Za-z0-9_.:-]/-/g')
    cmd="ccy --name $session_name --resume $sid"
done < "$tmpdir/claude-panes.txt"
assert_eq "spaces become hyphens" "ccy --name my-window-name --resume ccc-333" "$cmd"

# Window name with slash (like comfyui/automation)
cat > "$tmpdir/claude-panes.txt" <<'EOF'
0:1.1|claude|ddd-444|/tmp|comfyui/automation
EOF
while IFS='|' read -r target tool sid cwd wname; do
    [[ "$target" =~ ^#.*$ ]] && continue
    [ -z "$target" ] && continue
    session_name="${wname}"
    session_name=$(printf '%s' "$session_name" | sed 's/[^A-Za-z0-9_.:-]/-/g')
    cmd="ccy --name $session_name"
done < "$tmpdir/claude-panes.txt"
assert_eq "slash sanitized to hyphen" "ccy --name comfyui-automation" "$cmd"

rm -rf "$tmpdir"

# ============================================================
echo ""
echo "=== session-save: mkdir lock serialization ==="
# ============================================================

tmpdir=$(mktemp -d)
LOCK_DIR="$tmpdir/.claude-save.lock"

mkdir "$LOCK_DIR"
_attempts=0
while ! mkdir "$LOCK_DIR" 2>/dev/null; do
    _attempts=$((_attempts + 1))
    [ $_attempts -ge 3 ] && break
    sleep 0.1
done
assert_eq "lock blocks concurrent entry" "3" "$_attempts"

rmdir "$LOCK_DIR"
mkdir "$LOCK_DIR" 2>/dev/null
lock_result=$?
assert_eq "lock acquired after release" "0" "$lock_result"

rm -rf "$tmpdir"

# ============================================================
echo ""
echo "=== lib/tsv: tsv_encode ==="
# ============================================================
# shellcheck source=../lib/tsv.sh
. "$PLUGIN_DIR/lib/tsv.sh"

assert_eq "encode plain ascii unchanged" \
    "hello world" \
    "$(tsv_encode 'hello world')"

assert_eq "encode escapes percent FIRST" \
    "100%25" \
    "$(tsv_encode '100%')"

assert_eq "encode escapes tab" \
    "a%09b" \
    "$(tsv_encode "$(printf 'a\tb')")"

assert_eq "encode escapes newline" \
    "a%0Ab" \
    "$(tsv_encode "$(printf 'a\nb')")"

assert_eq "encode escapes carriage return" \
    "a%0Db" \
    "$(tsv_encode "$(printf 'a\rb')")"

assert_eq "encode escapes empty string" \
    "" \
    "$(tsv_encode '')"

assert_eq "encode does not double-encode existing %09" \
    "lit%2509" \
    "$(tsv_encode 'lit%09')"

# ============================================================
echo ""
echo "=== lib/tsv: tsv_decode ==="
# ============================================================

assert_eq "decode plain ascii unchanged" \
    "hello world" \
    "$(tsv_decode 'hello world')"

assert_eq "decode %25 to percent (LAST)" \
    "100%" \
    "$(tsv_decode '100%25')"

assert_eq "decode %09 to tab" \
    "$(printf 'a\tb')" \
    "$(tsv_decode 'a%09b')"

assert_eq "decode %0A to newline" \
    "$(printf 'a\nb')" \
    "$(tsv_decode 'a%0Ab')"

assert_eq "decode %0D to carriage return" \
    "$(printf 'a\rb')" \
    "$(tsv_decode 'a%0Db')"

assert_eq "decode empty string" \
    "" \
    "$(tsv_decode '')"

assert_eq "decode does not over-eat: %2509 stays literal % then 09" \
    "%09" \
    "$(tsv_decode '%2509')"

# Round-trip property: every special-byte string survives encode→decode.
i=0
for s in '' 'plain' 'pct%' "tab$(printf '\t')end" "nl$(printf '\n')end" \
         "cr$(printf '\r')end" '%%%' "$(printf 'all\t%%\n\rend')"; do
    i=$((i + 1))
    enc=$(tsv_encode "$s")
    dec=$(tsv_decode "$enc")
    assert_eq "round-trip case #$i" "$s" "$dec"
done

# ============================================================
echo ""
echo "=== lib/snapshot: write_header ==="
# ============================================================
# shellcheck source=../lib/snapshot.sh
. "$PLUGIN_DIR/lib/snapshot.sh"

header=$(snapshot_write_header)

assert_contains "header includes version marker v2" \
    "# tmux-claude snapshot v2" \
    "$header"

assert_contains "header lists all 8 field names" \
    "target	tool	sid	sid_kind	cwd	original_cwd	wname	flags" \
    "$header"

assert_eq "SNAPSHOT_VERSION constant is set" \
    "2" \
    "$SNAPSHOT_VERSION"

# ============================================================
echo ""
echo "=== lib/snapshot: write_row ==="
# ============================================================

row=$(snapshot_write_row "0:1.1" "codex" "019dd3be-9166-7750-8039-a1f9ecdad1f3" \
        "uuid" "/Users/me/proj" "" "fine-tuning" "")

assert_eq "row has 8 tab-separated fields" \
    "0:1.1	codex	019dd3be-9166-7750-8039-a1f9ecdad1f3	uuid	/Users/me/proj		fine-tuning	" \
    "$row"

row=$(snapshot_write_row "0:7.1" "codex" "abc" "uuid" \
        "$(printf '/tmp/weird\tdir')" "" "$(printf 'name\nbreak')" "")

assert_contains "encodes embedded tab in cwd as %09" \
    "/tmp/weird%09dir" \
    "$row"

assert_contains "encodes embedded newline in wname as %0A" \
    "name%0Abreak" \
    "$row"

assert_contains "writer auto-adds field_encoded when any field is encoded" \
    "field_encoded" \
    "$row"

row=$(snapshot_write_row "0:7.1" "codex" "abc" "uuid" \
        "$(printf '/tmp/weird\tdir')" "" "wname" "cwd_collapsed")

assert_contains "caller-provided flag preserved" \
    "cwd_collapsed" \
    "$row"

assert_contains "auto-added field_encoded composed with caller flag" \
    "field_encoded" \
    "$row"

row=$(snapshot_write_row "0:7.1" "codex" "abc" "uuid" \
        "$(printf '/tmp/weird\tdir')" "" "wname" "field_encoded")
field_encoded_count=$(printf '%s' "$row" | awk '{ print gsub(/field_encoded/, "") }')
assert_eq "caller-provided field_encoded is deduplicated" \
    "1" \
    "$field_encoded_count"
assert_eq "field_encoded remains the only flag when already supplied" \
    "field_encoded" \
    "$(printf '%s' "$row" | cut -f8)"

row=$(snapshot_write_row "0:9.1" "codex" "abc" "uuid" "/plain/path" "" "win" "")
assert_not_contains "no field_encoded for plain rows" \
    "field_encoded" \
    "$row"

row=$(snapshot_write_row "0:3.1" "nvim" "-" "none" "/cwd" "" "win" "")
assert_eq "all-empty trailing fields render as bare tabs" \
    "0:3.1	nvim	-	none	/cwd		win	" \
    "$row"

# ============================================================
echo ""
echo "=== lib/snapshot: detect_version ==="
# ============================================================

tmpdir=$(mktemp -d)

: > "$tmpdir/empty.txt"
assert_eq "empty file → version 0" \
    "0" \
    "$(snapshot_detect_version "$tmpdir/empty.txt")"

printf '# tmux-claude snapshot v2\n# fields: target\n0:1.1\tcodex\n' > "$tmpdir/v2.txt"
assert_eq "v2 header → version 2" \
    "2" \
    "$(snapshot_detect_version "$tmpdir/v2.txt")"

printf '0:1.1|codex|abc|/cwd|fine-tuning\n' > "$tmpdir/v1.txt"
assert_eq "pipe-delimited no-header → version 1" \
    "1" \
    "$(snapshot_detect_version "$tmpdir/v1.txt")"

printf '# Claude/Codex session mapping — Sat\n# Format: a|b\n0:1.1|codex|abc|/cwd|x\n' > "$tmpdir/v1-commented.txt"
assert_eq "pipe rows after comments → version 1" \
    "1" \
    "$(snapshot_detect_version "$tmpdir/v1-commented.txt")"

printf '# tmux-claude snapshot v9\n' > "$tmpdir/v9.txt"
assert_eq "v9 header → version 9 (caller decides what to do)" \
    "9" \
    "$(snapshot_detect_version "$tmpdir/v9.txt")"

assert_eq "missing file → version 0" \
    "0" \
    "$(snapshot_detect_version "$tmpdir/does-not-exist.txt")"

printf 'just some random text\n' > "$tmpdir/garbage.txt"
assert_eq "non-empty unrecognized → version -1 (unknown)" \
    "-1" \
    "$(snapshot_detect_version "$tmpdir/garbage.txt")"

printf '# only a comment\n\n# another\n' > "$tmpdir/comments-only.txt"
assert_eq "comments-only file → version 0" \
    "0" \
    "$(snapshot_detect_version "$tmpdir/comments-only.txt")"

printf '# only a comment\n  \n\t\n# another\n' > "$tmpdir/comments-whitespace-only.txt"
assert_eq "comments plus whitespace-only lines → version 0" \
    "0" \
    "$(snapshot_detect_version "$tmpdir/comments-whitespace-only.txt")"

printf '  \n\t\n0:1.1|codex|abc|/cwd|x\n' > "$tmpdir/v1-after-whitespace.txt"
assert_eq "whitespace-only lines before pipe row → version 1" \
    "1" \
    "$(snapshot_detect_version "$tmpdir/v1-after-whitespace.txt")"

rm -rf "$tmpdir"

# ============================================================
echo ""
echo "=== lib/snapshot: promote_v1_row ==="
# ============================================================

assert_eq "claude+UUID → uuid kind" \
    "0cbb1761-1a50-4cc4-8e7d-7b4bbdc788bf uuid" \
    "$(promote_v1_row claude 0cbb1761-1a50-4cc4-8e7d-7b4bbdc788bf)"

assert_eq "claude+picker → picker kind" \
    "picker picker" \
    "$(promote_v1_row claude picker)"

assert_eq "claude+nonsense → none kind, sid=-" \
    "- none" \
    "$(promote_v1_row claude not-a-uuid)"

assert_eq "codex+UUID → uuid kind" \
    "019dd3be-9166-7750-8039-a1f9ecdad1f3 uuid" \
    "$(promote_v1_row codex 019dd3be-9166-7750-8039-a1f9ecdad1f3)"

assert_eq "codex+picker → picker kind" \
    "picker picker" \
    "$(promote_v1_row codex picker)"

assert_eq "nvim+picker → none kind (sid discarded — historical sentinel)" \
    "- none" \
    "$(promote_v1_row nvim picker)"

assert_eq "nvim+empty → none kind" \
    "- none" \
    "$(promote_v1_row nvim '')"

assert_eq "just+dev → recipe kind, sid preserved" \
    "dev recipe" \
    "$(promote_v1_row just dev)"

assert_eq "just+empty → none kind" \
    "- none" \
    "$(promote_v1_row just '')"

assert_eq "just+spaced-recipe → recipe kind, sid preserved" \
    "dev server recipe" \
    "$(promote_v1_row just "dev server")"

assert_eq "just+complex-recipe-name → recipe kind" \
    "test:unit recipe" \
    "$(promote_v1_row just test:unit)"

assert_eq "unknown tool → none kind" \
    "- none" \
    "$(promote_v1_row xargs foo)"

assert_eq "claude+UPPERCASE UUID → normalized lowercase, uuid kind" \
    "0cbb1761-1a50-4cc4-8e7d-7b4bbdc788bf uuid" \
    "$(promote_v1_row claude 0CBB1761-1A50-4CC4-8E7D-7B4BBDC788BF)"

assert_eq "claude+mixed-case UUID → normalized lowercase" \
    "0cbb1761-1a50-4cc4-8e7d-7b4bbdc788bf uuid" \
    "$(promote_v1_row claude 0cbb1761-1A50-4cc4-8E7D-7b4bbdc788bf)"

# ============================================================
echo ""
echo "=== lib/snapshot: read v2 happy path ==="
# ============================================================

rows=$(snapshot_read "$PLUGIN_DIR/tests/fixtures/v2-snapshot.txt")

assert_eq "5 rows read" \
    "5" \
    "$(printf '%s\n' "$rows" | wc -l | tr -d ' ')"

# Each row should be TAB-separated and start with the target.
first=$(printf '%s\n' "$rows" | head -1)
assert_eq "first row target" \
    "0:1.1" \
    "$(printf '%s' "$first" | cut -f1)"

assert_eq "first row tool" \
    "codex" \
    "$(printf '%s' "$first" | cut -f2)"

assert_eq "first row sid_kind" \
    "uuid" \
    "$(printf '%s' "$first" | cut -f4)"

# nvim row (line 2 of output) has sid_kind=none
nvim_row=$(printf '%s\n' "$rows" | sed -n '2p')
assert_eq "nvim row sid_kind" \
    "none" \
    "$(printf '%s' "$nvim_row" | cut -f4)"

# cwd_collapsed row preserves original_cwd in column 6
collapsed=$(printf '%s\n' "$rows" | sed -n '3p')
assert_eq "collapsed row original_cwd" \
    "/Users/me/proj/.worktrees/pruned" \
    "$(printf '%s' "$collapsed" | cut -f6)"

assert_eq "collapsed row flags" \
    "cwd_collapsed" \
    "$(printf '%s' "$collapsed" | cut -f8)"

# Comment lines are NOT in the output.
assert_not_contains "output excludes header comment" \
    "# tmux-claude snapshot" \
    "$rows"

assert_not_contains "output excludes field-name comment" \
    "# fields:" \
    "$rows"

# Each row has exactly 8 fields (count TABs + 1 per line).
while IFS= read -r row_line; do
    nf=$(printf '%s' "$row_line" | awk -F'\t' '{print NF}')
    assert_eq "row has exactly 8 fields" "8" "$nf"
done <<<"$rows"

# CRITICAL: a row whose last field (flags) is empty must NOT be
# misidentified as a 7-field malformed row. The fixture row 1 has
# empty flags (trailing TAB followed by LF). Verify it survived.
first_flags=$(printf '%s\n' "$rows" | head -1 | awk -F'\t' '{print $8}')
assert_eq "row 1 flags is empty (not skipped as malformed)" \
    "" \
    "$first_flags"

# Row 5 (the 'just dev' sb row) also has empty original_cwd and empty
# flags — both trailing/embedded empties survive.
sb_row=$(printf '%s\n' "$rows" | sed -n '5p')
sb_field_count=$(printf '%s' "$sb_row" | awk -F'\t' '{print NF}')
assert_eq "sb row has 8 fields (trailing empties preserved)" \
    "8" \
    "$sb_field_count"
assert_eq "sb row original_cwd is empty" \
    "" \
    "$(printf '%s' "$sb_row" | cut -f6)"
assert_eq "sb row flags is empty" \
    "" \
    "$(printf '%s' "$sb_row" | cut -f8)"

# ============================================================
echo ""
echo "=== lib/snapshot: split_row preserves empty fields ==="
# ============================================================
# CRITICAL contract: this is the consumer-side helper that consumers
# (chunk 3 restore loop) MUST use instead of `IFS=$'\t' read`, because
# bash's tab-as-IFS-whitespace collapses consecutive tabs.

# Empirically verify the bash bug we're working around:
bash_native=$(printf 'a\tb\t\tc' | (IFS=$'\t' read -r f1 f2 f3 f4; printf '%s|%s|%s|%s' "$f1" "$f2" "$f3" "$f4"))
assert_eq "bash IFS=\$'\\t' read DOES collapse empty fields (proves the bug)" \
    "a|b|c|" \
    "$bash_native"

# Now verify our helper preserves empties:
split_output=$(snapshot_split_row "$(printf 'a\tb\t\tc')")
assert_eq "split_row preserves empty field 3" \
    "$(printf 'a\nb\n\nc')" \
    "$split_output"

# 8-field row with empty original_cwd and empty flags (mimics nvim row).
# CRITICAL: must NOT use `fields=$(snapshot_split_row "$row")` here —
# command substitution strips trailing newlines, dropping the 8th
# empty field. Collect into an indexed array via process substitution.
row=$(printf '0:6.1\tnvim\t-\tnone\t/cwd\t\tanalytics\t')
fields=()
while IFS= read -r field; do
    fields+=("$field")
done < <(snapshot_split_row "$row")

assert_eq "8-field row with empties splits to 8 entries" \
    "8" \
    "${#fields[@]}"

# The 6th field (original_cwd) is empty.
assert_eq "original_cwd field is empty (not collapsed)" \
    "" \
    "${fields[5]}"

# The 7th field (wname) is "analytics" — proves no shifting happened.
assert_eq "wname field still 'analytics' (no shift)" \
    "analytics" \
    "${fields[6]}"

# The 8th field (flags) is empty — proves trailing empty preserved.
assert_eq "flags field is empty (trailing empty preserved)" \
    "" \
    "${fields[7]}"

# Also assert: doing it WRONG (command sub) is actually broken, so
# the warning comment in snapshot_split_row stays warranted.
wrong=$(snapshot_split_row "$row")
wrong_count=$(printf '%s\n' "$wrong" | grep -c '^' || true)
assert_eq "command-sub of split_row DOES drop trailing empty (proves the trap)" \
    "7" \
    "$wrong_count"

# Recipe for consumers: how to use split_row to get individual fields.
# This pattern is what chunk 3's restore loop will use.
read_row_into_vars() {
    local row="$1"
    local i=0
    while IFS= read -r field; do
        i=$((i + 1))
        case "$i" in
            1) target="$field" ;;
            2) tool="$field" ;;
            3) sid="$field" ;;
            4) sid_kind="$field" ;;
            5) cwd="$field" ;;
            6) original_cwd="$field" ;;
            7) wname="$field" ;;
            8) flags="$field" ;;
        esac
    done < <(snapshot_split_row "$row")
}
target=; tool=; sid=; sid_kind=; cwd=; original_cwd=; wname=; flags=
read_row_into_vars "$row"
assert_eq "consumer pattern: original_cwd correctly empty" "" "$original_cwd"
assert_eq "consumer pattern: wname correctly 'analytics'" "analytics" "$wname"
assert_eq "consumer pattern: flags correctly empty" "" "$flags"

# ============================================================
echo ""
echo "=== lib/snapshot: read v1 legacy fallback ==="
# ============================================================

tmpdir=$(mktemp -d)
stdout="$tmpdir/stdout.txt"
stderr="$tmpdir/stderr.txt"
snapshot_read "$PLUGIN_DIR/tests/fixtures/v1-snapshot.txt" >"$stdout" 2>"$stderr"
read_status=$?
rows=$(cat "$stdout")
logs=$(cat "$stderr")

assert_eq "snapshot_read v1 fixture exits 0" \
    "0" \
    "$read_status"

assert_eq "v1 fixture promotes 5 rows" \
    "5" \
    "$(printf '%s\n' "$rows" | wc -l | tr -d ' ')"

while IFS= read -r row_line; do
    nf=$(printf '%s' "$row_line" | awk -F'\t' '{print NF}')
    assert_eq "v1 promoted row has exactly 8 fields" "8" "$nf"
done < "$stdout"

codex_row=$(printf '%s\n' "$rows" | sed -n '1p')
assert_eq "v1 codex UUID sid preserved" \
    "019dd3be-9166-7750-8039-a1f9ecdad1f3" \
    "$(printf '%s' "$codex_row" | cut -f3)"
assert_eq "v1 codex UUID sid_kind uuid" \
    "uuid" \
    "$(printf '%s' "$codex_row" | cut -f4)"

nvim_row=$(printf '%s\n' "$rows" | sed -n '2p')
assert_eq "v1 nvim picker sid discarded" \
    "-" \
    "$(printf '%s' "$nvim_row" | cut -f3)"
assert_eq "v1 nvim picker sid_kind none" \
    "none" \
    "$(printf '%s' "$nvim_row" | cut -f4)"

claude_invalid_row=$(printf '%s\n' "$rows" | sed -n '3p')
assert_eq "v1 claude non-uuid sid discarded" \
    "-" \
    "$(printf '%s' "$claude_invalid_row" | cut -f3)"
assert_eq "v1 claude non-uuid sid_kind none" \
    "none" \
    "$(printf '%s' "$claude_invalid_row" | cut -f4)"

just_row=$(printf '%s\n' "$rows" | sed -n '5p')
assert_eq "v1 just recipe preserved" \
    "dev" \
    "$(printf '%s' "$just_row" | cut -f3)"
assert_eq "v1 just recipe sid_kind recipe" \
    "recipe" \
    "$(printf '%s' "$just_row" | cut -f4)"

while IFS= read -r row_line; do
    assert_eq "v1 promoted row original_cwd empty" \
        "" \
        "$(printf '%s' "$row_line" | cut -f6)"
    assert_eq "v1 promoted row flags empty" \
        "" \
        "$(printf '%s' "$row_line" | cut -f8)"
done < "$stdout"

assert_contains "v1 read logs LEGACY warning" \
    "LEGACY v1 snapshot read" \
    "$logs"
assert_contains "v1 read log mentions row count" \
    "5 rows" \
    "$logs"

rm -rf "$tmpdir"

# ============================================================
echo ""
echo "=== lib/snapshot: read v1 spaced just recipe ==="
# ============================================================

tmpdir=$(mktemp -d)
cat > "$tmpdir/v1-spaced-just.txt" <<'EOF'
0:19.1|just|dev server|/cwd|win
EOF

spaced_row=$(snapshot_read "$tmpdir/v1-spaced-just.txt" 2>/dev/null)
assert_eq "v1 spaced just recipe preserves full sid" \
    "dev server" \
    "$(printf '%s' "$spaced_row" | cut -f3)"
assert_eq "v1 spaced just recipe kind" \
    "recipe" \
    "$(printf '%s' "$spaced_row" | cut -f4)"

rm -rf "$tmpdir"

# ============================================================
echo ""
echo "=== lib/snapshot: read v2 whitespace-only lines ==="
# ============================================================

tmpdir=$(mktemp -d)
stdout="$tmpdir/stdout.txt"
stderr="$tmpdir/stderr.txt"
printf '# tmux-claude snapshot v2\n# fields: target\ttool\tsid\tsid_kind\tcwd\toriginal_cwd\twname\tflags\n  \n0:1.1\tcodex\tabc\tuuid\t/cwd\t\twin\t\n' > "$tmpdir/v2-whitespace.txt"

snapshot_read "$tmpdir/v2-whitespace.txt" >"$stdout" 2>"$stderr"
rows=$(cat "$stdout")
logs=$(cat "$stderr")

assert_eq "v2 whitespace-only line is skipped, one row emitted" \
    "1" \
    "$(printf '%s\n' "$rows" | wc -l | tr -d ' ')"
assert_not_contains "v2 whitespace-only line does not warn" \
    "WARN" \
    "$logs"

rm -rf "$tmpdir"

# ============================================================
echo ""
echo "=== lib/snapshot: read error paths ==="
# ============================================================

tmpdir=$(mktemp -d)

# --- Unknown future version (v9) ---
printf '# tmux-claude snapshot v9\nignored\n' > "$tmpdir/v9.txt"

out=$(snapshot_read "$tmpdir/v9.txt" 2>"$tmpdir/v9.err"); rc=$?
err=$(cat "$tmpdir/v9.err")

assert_eq "v9 returns non-zero exit code" "1" "$rc"
assert_eq "v9 emits NO rows" "" "$out"
assert_contains "v9 logs ERROR to stderr" "ERROR" "$err"
assert_contains "v9 stderr mentions version" "9" "$err"

# --- Non-empty unrecognized file (version -1) ---
printf 'just garbage text with no header and no pipes\n' > "$tmpdir/garbage.txt"
out=$(snapshot_read "$tmpdir/garbage.txt" 2>"$tmpdir/garbage.err"); rc=$?
err=$(cat "$tmpdir/garbage.err")

assert_eq "unrecognized non-empty returns non-zero" "1" "$rc"
assert_eq "unrecognized emits NO rows" "" "$out"
assert_contains "unrecognized logs ERROR" "ERROR" "$err"
assert_contains "unrecognized stderr says 'refusing to parse'" \
    "refusing to parse" "$err"

# --- Malformed v2 row (7 fields, not 8) ---
{
    printf '# tmux-claude snapshot v2\n'
    printf '# fields: target\ttool\tsid\tsid_kind\tcwd\toriginal_cwd\twname\tflags\n'
    printf '0:1.1\tcodex\tabc\tuuid\t/cwd\t\tfine-tuning\n'        # 7 fields — short!
    printf '0:2.1\tclaude\tdef\tuuid\t/cwd\t\twin\t\n'            # 8 fields — ok
} > "$tmpdir/malformed-v2.txt"

out=$(snapshot_read "$tmpdir/malformed-v2.txt" 2>"$tmpdir/mv2.err")
err=$(cat "$tmpdir/mv2.err")
row_count=$(printf '%s\n' "$out" | grep -c $'^[^\t]' || true)

assert_eq "malformed v2: 1 good row survives, 1 short row skipped" \
    "1" "$row_count"
assert_contains "malformed v2 survivor is target 0:2.1" \
    $'0:2.1\tclaude' "$out"
assert_contains "malformed v2 logs WARN" "WARN" "$err"
assert_contains "malformed v2 stderr says 'malformed v2 row'" \
    "malformed v2 row" "$err"

# --- Malformed v1 row (3 pipes, not 4) ---
{
    printf '0:1.1|codex|abc|/cwd|fine-tuning\n'                    # 5 fields ok
    printf '0:2.1|claude|missing-fields\n'                         # 3 fields — short!
} > "$tmpdir/malformed-v1.txt"

out=$(snapshot_read "$tmpdir/malformed-v1.txt" 2>"$tmpdir/mv1.err")
err=$(cat "$tmpdir/mv1.err")
row_count=$(printf '%s\n' "$out" | grep -c $'^[^\t]' || true)

assert_eq "malformed v1: 1 good row promoted, 1 short row skipped" \
    "1" "$row_count"
assert_contains "malformed v1 survivor is target 0:1.1" \
    $'0:1.1\tcodex' "$out"
assert_contains "malformed v1 survivor sid kind is none" \
    $'\t-\tnone\t' "$out"
assert_contains "malformed v1 logs WARN" "WARN" "$err"
assert_contains "malformed v1 stderr says 'malformed v1 row'" \
    "malformed v1 row" "$err"

# --- Malformed v1 row (6 pipes — extra | in cwd) ---
{
    printf '0:3.1|codex|def|/cwd/with|pipe|win\n'                  # 6 fields — extra!
    printf '0:4.1|claude|ghi|/clean|win\n'                         # 5 fields ok
} > "$tmpdir/malformed-v1-extra.txt"

out=$(snapshot_read "$tmpdir/malformed-v1-extra.txt" 2>"$tmpdir/mv1e.err")
err=$(cat "$tmpdir/mv1e.err")
row_count=$(printf '%s\n' "$out" | grep -c $'^[^\t]' || true)

assert_eq "v1 with extra pipe: extra-field row skipped, clean row promoted" \
    "1" "$row_count"
assert_contains "extra-pipe survivor is target 0:4.1" \
    $'0:4.1\tclaude' "$out"
assert_not_contains "extra-pipe malformed target is skipped" \
    "0:3.1" "$out"
assert_contains "extra-pipe row logs WARN" "WARN" "$err"

rm -rf "$tmpdir"

# ============================================================
echo ""
echo "=== lib/snapshot: read v2 drops extra future columns ==="
# ============================================================

tmpdir=$(mktemp -d)
{
    printf '# tmux-claude snapshot v2\n'
    printf '# fields: target\ttool\tsid\tsid_kind\tcwd\toriginal_cwd\twname\tflags\textra_future_col\n'
    printf '0:1.1\tcodex\tabc\tuuid\t/cwd\t\twname\t\tfuture_value_dropped\n'
} > "$tmpdir/v2plus.txt"

row=$(snapshot_read "$tmpdir/v2plus.txt" 2>"$tmpdir/v2plus.err"); rc=$?; err=$(cat "$tmpdir/v2plus.err")

assert_eq "extra future column is accepted" "0" "$rc"
assert_not_contains "extra future column does not warn" "WARN" "$err"
assert_not_contains "extra future column does not error" "ERROR" "$err"

# Reader truncates to exactly 8 fields.
field_count=$(printf '%s' "$row" | awk -F'\t' '{print NF}')
assert_eq "reader truncates to exactly 8 fields" \
    "8" \
    "$field_count"

# The future column value must NOT appear anywhere in the emitted row.
assert_not_contains "extra column value is dropped" \
    "future_value_dropped" \
    "$row"

# Fields 1-8 are intact.
assert_eq "target field intact" "0:1.1" "$(printf '%s' "$row" | cut -f1)"
assert_eq "sid_kind field intact" "uuid" "$(printf '%s' "$row" | cut -f4)"
assert_eq "wname field intact" "wname" "$(printf '%s' "$row" | cut -f7)"
assert_eq "flags field intact (empty)" "" "$(printf '%s' "$row" | cut -f8)"

# Row with MANY extra columns also gets truncated.
{
    printf '# tmux-claude snapshot v2\n'
    printf '0:2.1\tclaude\txyz\tuuid\t/c\t\twin\tflag\tA\tB\tC\tD\n'
} > "$tmpdir/v2-many-extras.txt"

row=$(snapshot_read "$tmpdir/v2-many-extras.txt" 2>"$tmpdir/v2-many-extras.err"); rc=$?; err=$(cat "$tmpdir/v2-many-extras.err")

assert_eq "many extra future columns are accepted" "0" "$rc"
assert_not_contains "many extra future columns do not warn" "WARN" "$err"
assert_not_contains "many extra future columns do not error" "ERROR" "$err"

field_count=$(printf '%s' "$row" | awk -F'\t' '{print NF}')
assert_eq "12-field input truncates to 8" "8" "$field_count"
assert_not_contains "trailing extras dropped" "A	B	C	D" "$row"

rm -rf "$tmpdir"

# ============================================================
echo ""
echo "=== lib/snapshot: smoke test against live claude-panes.txt ==="
# ============================================================

if [ -z "${HOME+x}" ]; then
    echo "  (smoke: HOME unset, skipping live snapshot)"
elif [ ! -f "$HOME/.config/tmux/resurrect/claude-panes.txt" ]; then
    real_snapshot="$HOME/.config/tmux/resurrect/claude-panes.txt"
    echo "  (smoke: no live snapshot at $real_snapshot, skipping)"
elif [ ! -s "$HOME/.config/tmux/resurrect/claude-panes.txt" ]; then
    real_snapshot="$HOME/.config/tmux/resurrect/claude-panes.txt"
    echo "  (smoke: live snapshot is zero-byte, skipping)"
else
    real_snapshot="$HOME/.config/tmux/resurrect/claude-panes.txt"
    tmpdir=$(mktemp -d)
    snapshot_version=$(snapshot_detect_version "$real_snapshot")
    rows=$(snapshot_read "$real_snapshot" 2>"$tmpdir/smoke.err"); rc=$?
    err=$(cat "$tmpdir/smoke.err")

    if [ "$rc" -ne 0 ]; then
        # Reader refused to parse — that itself is an actionable finding.
        # Don't silently skip; fail the test with the reason.
        red "  FAIL: snapshot_read returned $rc for live snapshot"
        red "    stderr: $err"
        FAIL=$((FAIL + 1))
    else
        if [ -z "$rows" ]; then
            row_count=0
        else
            row_count=$(printf '%s\n' "$rows" | wc -l | tr -d ' ')
        fi

        unexpected_logs=$(printf '%s\n' "$err" | grep -E 'WARN|ERROR' || true)
        if [ "$snapshot_version" = "1" ]; then
            unexpected_logs=$(printf '%s\n' "$unexpected_logs" \
                              | grep -vF 'LEGACY v1 snapshot read' || true)
        fi
        if [ -n "$unexpected_logs" ]; then
            red "  FAIL: snapshot_read logged unexpected WARN/ERROR for live snapshot"
            red "    stderr: $err"
            FAIL=$((FAIL + 1))
        fi

        # LEGACY warning expected for v1 input (current live format).
        if [ "$snapshot_version" = "1" ]; then
            assert_contains "LEGACY warning logged for v1 input" \
                "LEGACY" "$err"
        fi

        if [ "$row_count" -eq 0 ]; then
            echo "  (smoke: live snapshot has no rows, skipping field assertions)"
        else
            # Every emitted row must have exactly 8 tab-separated fields.
            bad=$(printf '%s\n' "$rows" \
                  | awk -F'\t' 'NF != 8 { print NR; exit }')
            assert_eq "every emitted row has exactly 8 fields" \
                "" \
                "$bad"

            # No row should have an empty target (column 1).
            no_target=$(printf '%s\n' "$rows" \
                        | awk -F'\t' '$1 == "" { print NR; exit }')
            assert_eq "no row has empty target" \
                "" \
                "$no_target"
        fi

        echo "  (smoke: parsed $row_count rows from live snapshot)"
    fi
    rm -rf "$tmpdir"
fi

# ============================================================
echo ""
echo "=== lib/process: live_agent_pid ==="
# ============================================================
# shellcheck source=../lib/process.sh
. "$PLUGIN_DIR/lib/process.sh"

ORIG_PATH="$PATH"
tmpdir=$(mktemp -d)
tmpbin="$tmpdir/bin"
mkdir -p "$tmpbin"
PATH="$tmpbin:$PATH"

cat > "$tmpbin/tmux" <<'EOF'
#!/usr/bin/env bash
if [ "$1" = "display-message" ]; then
    case "$*" in
        *"#{pane_pid}"*) printf '%s\n' "100" ;;
        *) exit 1 ;;
    esac
else
    exit 1
fi
EOF
chmod +x "$tmpbin/tmux"

cat > "$tmpbin/ps" <<'EOF'
#!/usr/bin/env bash
if [ "$1" = "-axww" ] && [ "$2" = "-o" ] && [ "$3" = "pid=,ppid=,command=" ]; then
    cat <<'PSOUT'
 100     1 fish
 110   100 /Users/me/bin/claude wrapper
 120   110 /opt/homebrew/bin/node /opt/claude cli --resume 0cbb1761-1a50-4cc4-8e7d-7b4bbdc788bf
 130   100 codex idle
PSOUT
elif [ "$1" = "-p" ] && [ "$3" = "-o" ] && [ "$4" = "command=" ]; then
    case "$2" in
        120) printf '%s\n' "/opt/homebrew/bin/node /opt/claude cli --resume 0cbb1761-1a50-4cc4-8e7d-7b4bbdc788bf" ;;
        130) printf '%s\n' "codex idle" ;;
        *) exit 1 ;;
    esac
else
    exit 1
fi
EOF
chmod +x "$tmpbin/ps"

assert_eq "live_agent_pid finds deepest claude descendant by argv" \
    "120" \
    "$(live_agent_pid "%1" claude)"

assert_eq "live_agent_pid finds direct codex descendant" \
    "130" \
    "$(live_agent_pid "%1" codex)"

miss_output=$(live_agent_pid "%1" gemini)
miss_status=$?
assert_eq "live_agent_pid misses absent tool" \
    "" \
    "$miss_output"

assert_eq "live_agent_pid miss returns nonzero" \
    "1" \
    "$miss_status"

cat > "$tmpbin/ps" <<'EOF'
#!/usr/bin/env bash
if [ "$1" = "-axww" ] && [ "$2" = "-o" ] && [ "$3" = "pid=,ppid=,command=" ]; then
    cat <<'PSOUT'
 120   110 /opt/homebrew/bin/node /opt/claude cli --resume 0cbb1761-1a50-4cc4-8e7d-7b4bbdc788bf
 100     1 fish
 130   100 codex idle
 110   100 /Users/me/bin/claude wrapper
PSOUT
elif [ "$1" = "-p" ] && [ "$3" = "-o" ] && [ "$4" = "command=" ]; then
    case "$2" in
        120) printf '%s\n' "/opt/homebrew/bin/node /opt/claude cli --resume 0cbb1761-1a50-4cc4-8e7d-7b4bbdc788bf" ;;
        130) printf '%s\n' "codex idle" ;;
        *) exit 1 ;;
    esac
else
    exit 1
fi
EOF
chmod +x "$tmpbin/ps"

assert_eq "live_agent_pid finds grandchild before parent in ps output" \
    "120" \
    "$(live_agent_pid "%1" claude)"

assert_contains "process_command reads command for pid" \
    "--resume 0cbb1761-1a50-4cc4-8e7d-7b4bbdc788bf" \
    "$(process_command 120)"

missing_command=$(process_command 999)
missing_command_status=$?
assert_eq "process_command missing pid prints empty" \
    "" \
    "$missing_command"

assert_eq "process_command missing pid returns zero" \
    "0" \
    "$missing_command_status"

assert_eq "extract_uuid finds UUID and normalizes uppercase hex" \
    "0cbb1761-1a50-4cc4-8e7d-7b4bbdc788bf" \
    "$(extract_uuid "abc 0CBB1761-1A50-4CC4-8E7D-7B4BBDC788BF def")"

assert_eq "extract_uuid misses invalid text" \
    "" \
    "$(extract_uuid "not-a-uuid" || true)"

uuid_miss_output=$(extract_uuid "not-a-uuid")
uuid_miss_status=$?
assert_eq "extract_uuid no match prints empty" \
    "" \
    "$uuid_miss_output"

assert_eq "extract_uuid no match returns zero" \
    "0" \
    "$uuid_miss_status"

PATH="$ORIG_PATH"
rm -rf "$tmpdir"

# ============================================================
echo ""
echo "=== lib/adapters: shared detect helper ==="
# ============================================================
# shellcheck source=../lib/adapter_helpers.sh
. "$PLUGIN_DIR/lib/adapter_helpers.sh"

tmpdir=$(mktemp -d)
tmux() {
    if [ "$1" = "show-options" ]; then
        local option
        option=""
        while [ "$#" -gt 0 ]; do
            if [ "$1" = "-v" ]; then
                shift
                option="${1:-}"
                break
            fi
            shift
        done
        case "$option" in
            @claude_session_id) printf '%s\n' sid >> "$tmpdir/options-seen"; printf '%s\n' "$MOCK_OPTION_SID" ;;
            @claude_session_pid) printf '%s\n' pid >> "$tmpdir/options-seen"; printf '%s\n' "$MOCK_OPTION_PID" ;;
            @claude_cwd) printf '%s\n' cwd >> "$tmpdir/options-seen"; printf '%s\n' "$MOCK_OPTION_CWD" ;;
            *) return 1 ;;
        esac
    elif [ "$1" = "display-message" ]; then
        case "$*" in
            *"#{pane_current_path}"*) printf '%s\n' "/pane/cwd" ;;
            *"#{pane_pid}"*) printf '%s\n' "100" ;;
            *) return 1 ;;
        esac
    else
        return 1
    fi
}

live_agent_pid() { printf '%s\n' "$MOCK_LIVE_PID"; }
process_command() { printf '%s\n' "$MOCK_COMMAND"; }
extract_uuid() { printf '%s\n' "$MOCK_EXTRACT_UUID"; }

: > "$tmpdir/options-seen"
MOCK_LIVE_PID=222
MOCK_OPTION_PID=222
MOCK_OPTION_SID=0cbb1761-1a50-4cc4-8e7d-7b4bbdc788bf
MOCK_OPTION_CWD=/option/cwd
MOCK_COMMAND="ignored"
MOCK_EXTRACT_UUID=""
assert_eq "agent_detect_from_options uses matching pid option uuid" \
    "$(printf 'claude\t0cbb1761-1a50-4cc4-8e7d-7b4bbdc788bf\tuuid\t/option/cwd')" \
    "$(adapter_detect_agent "%1" claude @claude_session_id @claude_session_pid @claude_cwd)"
seen_options=$(cat "$tmpdir/options-seen")
assert_contains "shared detector reads sid option by exact name" "sid" "$seen_options"
assert_contains "shared detector reads pid option by exact name" "pid" "$seen_options"
assert_contains "shared detector reads cwd option by exact name" "cwd" "$seen_options"

MOCK_OPTION_PID=999
MOCK_OPTION_SID=stale
MOCK_EXTRACT_UUID=64d862e0-29de-44a2-a854-8aecfe22dac4
assert_eq "agent_detect_from_options falls back to argv on stale pid" \
    "$(printf 'claude\t64d862e0-29de-44a2-a854-8aecfe22dac4\tuuid\t/option/cwd')" \
    "$(adapter_detect_agent "%1" claude @claude_session_id @claude_session_pid @claude_cwd)"

adapter_test_validate_ok() { return 0; }
adapter_test_validate_fail() { return 1; }

MOCK_OPTION_PID=999
MOCK_OPTION_SID=019ea610-ef51-7b51-8a40-6c2b946b6450
MOCK_COMMAND="codex --yolo -s workspace-write resume"
MOCK_EXTRACT_UUID=
assert_eq "agent_detect_from_options trusts valid sid on stale pid when artifact exists" \
    "$(printf 'codex\t019ea610-ef51-7b51-8a40-6c2b946b6450\tuuid\t/option/cwd\tpid_mismatch_trusted')" \
    "$(adapter_detect_agent "%1" codex @claude_session_id @claude_session_pid @claude_cwd adapter_test_validate_ok)"

assert_eq "agent_detect_from_options rejects stale pid sid when artifact is missing" \
    "$(printf 'codex\tpicker\tpicker\t/option/cwd')" \
    "$(adapter_detect_agent "%1" codex @claude_session_id @claude_session_pid @claude_cwd adapter_test_validate_fail)"

unset -f adapter_test_validate_ok adapter_test_validate_fail

MOCK_OPTION_PID=
MOCK_OPTION_SID=0cbb1761-1a50-4cc4-8e7d-7b4bbdc788bf
MOCK_EXTRACT_UUID=
assert_eq "agent_detect_from_options trusts sid when pid option absent and live agent exists" \
    "$(printf 'claude\t0cbb1761-1a50-4cc4-8e7d-7b4bbdc788bf\tuuid\t/option/cwd')" \
    "$(adapter_detect_agent "%1" claude @claude_session_id @claude_session_pid @claude_cwd)"

MOCK_OPTION_PID=
MOCK_OPTION_SID=
MOCK_EXTRACT_UUID=
assert_eq "agent_detect_from_options returns picker when live agent has no UUID" \
    "$(printf 'claude\tpicker\tpicker\t/option/cwd')" \
    "$(adapter_detect_agent "%1" claude @claude_session_id @claude_session_pid @claude_cwd)"

title_tmp=$(mktemp -d)
old_home="${HOME-}"
had_home=0
[ "${HOME+x}" = x ] && had_home=1
HOME="$title_tmp/home"
mkdir -p "$HOME/.claude/projects/-option-cwd"
cat > "$HOME/.claude/projects/-option-cwd/11111111-1111-4111-8111-111111111111.jsonl" <<'EOF'
{"type":"custom-title","customTitle":"unique-title"}
EOF
cat > "$HOME/.claude/projects/-option-cwd/22222222-2222-4222-8222-222222222222.jsonl" <<'EOF'
{"type":"custom-title","customTitle":"duplicate-title"}
EOF
cat > "$HOME/.claude/projects/-option-cwd/33333333-3333-4333-8333-333333333333.jsonl" <<'EOF'
{"type":"custom-title","customTitle":"duplicate-title"}
EOF
cat > "$HOME/.claude/projects/-option-cwd/not-a-uuid.jsonl" <<'EOF'
{"type":"custom-title","customTitle":"non-uuid-title"}
EOF
{
    for _i in $(seq 1 60); do
        printf '{"type":"user","message":"filler"}\n'
    done
    printf '{"type":"custom-title","customTitle":"late-title"}\n'
} > "$HOME/.claude/projects/-option-cwd/44444444-4444-4444-8444-444444444444.jsonl"
MOCK_COMMAND="claude --name unique-title --dangerously-skip-permissions"
assert_eq "agent_detect_from_options backfills unique claude title UUID" \
    "$(printf 'claude\t11111111-1111-4111-8111-111111111111\tuuid\t/option/cwd')" \
    "$(adapter_detect_agent "%1" claude @claude_session_id @claude_session_pid @claude_cwd)"

MOCK_COMMAND="claude --name=unique-title --dangerously-skip-permissions"
assert_eq "agent_detect_from_options backfills --name=value claude title UUID" \
    "$(printf 'claude\t11111111-1111-4111-8111-111111111111\tuuid\t/option/cwd')" \
    "$(adapter_detect_agent "%1" claude @claude_session_id @claude_session_pid @claude_cwd)"

MOCK_COMMAND="claude --name duplicate-title --dangerously-skip-permissions"
assert_eq "agent_detect_from_options keeps picker for duplicate claude title" \
    "$(printf 'claude\tpicker\tpicker\t/option/cwd')" \
    "$(adapter_detect_agent "%1" claude @claude_session_id @claude_session_pid @claude_cwd)"

MOCK_COMMAND="claude --name missing-title --dangerously-skip-permissions"
assert_eq "agent_detect_from_options keeps picker for missing claude title" \
    "$(printf 'claude\tpicker\tpicker\t/option/cwd')" \
    "$(adapter_detect_agent "%1" claude @claude_session_id @claude_session_pid @claude_cwd)"

MOCK_COMMAND="claude --name non-uuid-title --dangerously-skip-permissions"
assert_eq "agent_detect_from_options ignores non-uuid claude title files" \
    "$(printf 'claude\tpicker\tpicker\t/option/cwd')" \
    "$(adapter_detect_agent "%1" claude @claude_session_id @claude_session_pid @claude_cwd)"

MOCK_COMMAND="claude --name late-title --dangerously-skip-permissions"
assert_eq "agent_detect_from_options stops scanning titleless claude files" \
    "$(printf 'claude\tpicker\tpicker\t/option/cwd')" \
    "$(adapter_detect_agent "%1" claude @claude_session_id @claude_session_pid @claude_cwd)"

MOCK_COMMAND="codex --name unique-title"
assert_eq "agent_detect_from_options does not backfill non-claude titles" \
    "$(printf 'codex\tpicker\tpicker\t/option/cwd')" \
    "$(adapter_detect_agent "%1" codex @claude_session_id @claude_session_pid @claude_cwd)"
if [ "$had_home" -eq 1 ]; then
    HOME="$old_home"
else
    unset HOME
fi
rm -rf "$title_tmp"

MOCK_LIVE_PID=222
MOCK_OPTION_PID=222
MOCK_OPTION_SID=0cbb1761-1a50-4cc4-8e7d-7b4bbdc788bf
MOCK_OPTION_CWD=
MOCK_EXTRACT_UUID=
assert_eq "agent_detect_from_options falls back to pane cwd when cwd option missing" \
    "$(printf 'claude\t0cbb1761-1a50-4cc4-8e7d-7b4bbdc788bf\tuuid\t/pane/cwd')" \
    "$(adapter_detect_agent "%1" claude @claude_session_id @claude_session_pid @claude_cwd)"

MOCK_LIVE_PID=
no_live_output=$(adapter_detect_agent "%1" claude @claude_session_id @claude_session_pid @claude_cwd)
no_live_status=$?
assert_eq "agent_detect_from_options misses when no live agent" \
    "" \
    "$no_live_output"
assert_eq "agent_detect_from_options no live agent returns nonzero" \
    "1" \
    "$no_live_status"

unset -f tmux live_agent_pid process_command extract_uuid
rm -rf "$tmpdir"

# ============================================================
echo ""
echo "=== adapters: claude ==="
# ============================================================
# shellcheck source=../adapters/10-claude.sh
. "$PLUGIN_DIR/adapters/10-claude.sh"

tmpdir=$(mktemp -d)
adapter_detect_agent() {
    printf '%s\n' "$*" > "$tmpdir/claude-detect-args"
    printf 'claude\t%s\t%s\t%s\n' "$MOCK_SID" "$MOCK_KIND" "$MOCK_CWD"
}

MOCK_SID=0cbb1761-1a50-4cc4-8e7d-7b4bbdc788bf
MOCK_KIND=uuid
MOCK_CWD=/repo
assert_eq "claude_detect delegates to shared detector" \
    "$(printf 'claude\t0cbb1761-1a50-4cc4-8e7d-7b4bbdc788bf\tuuid\t/repo')" \
    "$(claude_detect "%1")"
claude_detect "%1" >/dev/null
claude_detect_args=$(cat "$tmpdir/claude-detect-args")
assert_contains "claude_detect passes claude sid option" "@claude_session_id" "$claude_detect_args"
assert_contains "claude_detect passes claude pid option" "@claude_session_pid" "$claude_detect_args"
assert_contains "claude_detect passes claude cwd option" "@claude_cwd" "$claude_detect_args"
assert_not_contains "claude_detect does not pass codex sid option" "@codex_session_id" "$claude_detect_args"

assert_eq "claude_validate picker requires no artifact" \
    "0" \
    "$(claude_validate picker picker; echo $?)"

assert_eq "claude_restore_argv uuid includes name and resume uuid" \
    "$(printf 'ccy\n--name\nwork\n--resume\n0cbb1761-1a50-4cc4-8e7d-7b4bbdc788bf')" \
    "$(claude_restore_argv "$MOCK_SID" uuid /repo work)"

assert_eq "claude_restore_argv picker omits uuid" \
    "$(printf 'ccy\n--name\nwork\n--resume')" \
    "$(claude_restore_argv picker picker /repo work)"

unset -f adapter_detect_agent
rm -rf "$tmpdir"

# ============================================================
echo ""
echo "=== adapters: codex ==="
# ============================================================
# shellcheck source=../adapters/20-codex.sh
. "$PLUGIN_DIR/adapters/20-codex.sh"

tmpdir=$(mktemp -d)
adapter_detect_agent() {
    printf '%s\n' "$*" > "$tmpdir/codex-detect-args"
    printf 'codex\t%s\t%s\t%s\n' "$MOCK_SID" "$MOCK_KIND" "$MOCK_CWD"
}

MOCK_SID=019dd3be-9166-7750-8039-a1f9ecdad1f3
MOCK_KIND=uuid
MOCK_CWD=/repo
assert_eq "codex_detect delegates to shared detector" \
    "$(printf 'codex\t019dd3be-9166-7750-8039-a1f9ecdad1f3\tuuid\t/repo')" \
    "$(codex_detect "%1")"
codex_detect "%1" >/dev/null
codex_detect_args=$(cat "$tmpdir/codex-detect-args")
assert_contains "codex_detect passes codex sid option" "@codex_session_id" "$codex_detect_args"
assert_contains "codex_detect passes codex pid option" "@codex_session_pid" "$codex_detect_args"
assert_contains "codex_detect passes codex cwd option" "@codex_cwd" "$codex_detect_args"
assert_not_contains "codex_detect does not pass claude sid option" "@claude_session_id" "$codex_detect_args"

assert_eq "codex_validate picker requires no artifact" \
    "0" \
    "$(codex_validate picker picker; echo $?)"

assert_eq "codex_restore_argv uuid includes resume uuid" \
    "$(printf 'cxy\nresume\n019dd3be-9166-7750-8039-a1f9ecdad1f3')" \
    "$(codex_restore_argv "$MOCK_SID" uuid /repo work)"

assert_eq "codex_restore_argv picker omits uuid" \
    "$(printf 'cxy\nresume')" \
    "$(codex_restore_argv picker picker /repo work)"

unset -f adapter_detect_agent
rm -rf "$tmpdir"

# ============================================================
echo ""
echo "=== adapters: nvim and just ==="
# ============================================================
# shellcheck source=../adapters/30-nvim.sh
. "$PLUGIN_DIR/adapters/30-nvim.sh"
# shellcheck source=../adapters/40-just.sh
. "$PLUGIN_DIR/adapters/40-just.sh"

tmux() {
    if [ "$1" = "display-message" ]; then
        case "$*" in
            *"#{pane_current_path}"*) printf '%s\n' "/pane/cwd" ;;
            *) return 1 ;;
        esac
    fi
}
live_agent_pid() {
    case "$2" in
        nvim) printf '%s\n' 301 ;;
        vim) printf '%s\n' "" ;;
        just) printf '%s\n' 401 ;;
        *) return 1 ;;
    esac
}
process_command() {
    case "$1" in
        401) printf '%s\n' "just dev" ;;
        *) return 1 ;;
    esac
}

assert_eq "nvim_detect emits none kind and cwd" \
    "$(printf 'nvim\t-\tnone\t/pane/cwd')" \
    "$(nvim_detect "%1")"

live_agent_pid() {
    case "$2" in
        nvim) printf '%s\n' "" ;;
        vim) printf '%s\n' 302 ;;
        just) printf '%s\n' 401 ;;
        *) return 1 ;;
    esac
}
assert_eq "nvim_detect falls back from nvim to vim" \
    "$(printf 'nvim\t-\tnone\t/pane/cwd')" \
    "$(nvim_detect "%1")"

assert_eq "nvim_restore_argv emits nvim" \
    "nvim" \
    "$(nvim_restore_argv - none /pane/cwd editor)"

assert_eq "just_detect emits recipe kind and cwd" \
    "$(printf 'just\tdev\trecipe\t/pane/cwd')" \
    "$(just_detect "%1")"

assert_eq "just_restore_argv emits just recipe" \
    "$(printf 'just\ndev')" \
    "$(just_restore_argv dev recipe /pane/cwd server)"

process_command() { printf '%s\n' "just"; }
assert_eq "just_detect without recipe misses" \
    "" \
    "$(just_detect "%1" || true)"

unset -f tmux live_agent_pid process_command

# ============================================================
echo ""
echo "=== lib/adapters: loader order ==="
# ============================================================
unset -f claude_detect codex_detect nvim_detect just_detect
unset -f claude_restore_argv codex_restore_argv nvim_restore_argv just_restore_argv

# shellcheck source=../lib/adapters.sh
. "$PLUGIN_DIR/lib/adapters.sh"

adapters_load "$PLUGIN_DIR"
adapter_names=$(adapters_list | tr '\n' ' ' | sed 's/ $//')
assert_eq "adapters load in NN filename order" \
    "claude codex nvim just" \
    "$adapter_names"

for fn in claude_detect codex_detect nvim_detect just_detect \
          claude_restore_argv codex_restore_argv nvim_restore_argv just_restore_argv; do
    if declare -F "$fn" >/dev/null 2>&1; then
        result=defined
    else
        result=missing
    fi
    assert_eq "adapter function $fn is loaded" "defined" "$result"
done

# ============================================================
echo ""
echo "=== adapters: contract smoke ==="
# ============================================================

tmpdir=$(mktemp -d)
tmpbin="$tmpdir/bin"
mkdir -p "$tmpbin"
PATH="$tmpbin:$ORIG_PATH"

cat > "$tmpbin/tmux" <<'EOF'
#!/usr/bin/env bash
if [ "$1" = "display-message" ]; then
    case "$*" in
        *"#{pane_pid}"*) printf '%s\n' "100" ;;
        *"#{pane_current_path}"*) printf '%s\n' "/contract/cwd" ;;
        *) exit 1 ;;
    esac
elif [ "$1" = "show-options" ]; then
    exit 1
else
    exit 1
fi
EOF
chmod +x "$tmpbin/tmux"

cat > "$tmpbin/ps" <<'EOF'
#!/usr/bin/env bash
if [ "$1" = "-axww" ]; then
    cat <<'PSOUT'
 100     1 fish
 200   100 claude --resume 0cbb1761-1a50-4cc4-8e7d-7b4bbdc788bf
 300   100 codex resume 019dd3be-9166-7750-8039-a1f9ecdad1f3
 400   100 nvim
 500   100 just dev
PSOUT
elif [ "$1" = "-p" ]; then
    case "$2" in
        200) printf '%s\n' "claude --resume 0cbb1761-1a50-4cc4-8e7d-7b4bbdc788bf" ;;
        300) printf '%s\n' "codex resume 019dd3be-9166-7750-8039-a1f9ecdad1f3" ;;
        400) printf '%s\n' "nvim" ;;
        500) printf '%s\n' "just dev" ;;
        *) exit 1 ;;
    esac
else
    exit 1
fi
EOF
chmod +x "$tmpbin/ps"

adapters_load "$PLUGIN_DIR"

for name in $(adapters_list); do
    detect_fn="${name}_detect"
    row=$("$detect_fn" "%1" || true)
    field_count=$(printf '%s' "$row" | awk -F'\t' '{print NF}')
    assert_eq "$name detect emits 4 TSV fields" "4" "$field_count"
done

assert_eq "claude detect sid_kind uuid from argv" \
    "uuid" \
    "$(claude_detect "%1" | cut -f3)"
assert_eq "codex detect sid_kind uuid from argv" \
    "uuid" \
    "$(codex_detect "%1" | cut -f3)"
assert_eq "nvim detect sid_kind none" \
    "none" \
    "$(nvim_detect "%1" | cut -f3)"
assert_eq "just detect sid_kind recipe" \
    "recipe" \
    "$(just_detect "%1" | cut -f3)"

for name in claude codex nvim just; do
    restore_fn="${name}_restore_argv"
    case "$name" in
        claude) argv=$("$restore_fn" 0cbb1761-1a50-4cc4-8e7d-7b4bbdc788bf uuid /contract/cwd name) ;;
        codex) argv=$("$restore_fn" 019dd3be-9166-7750-8039-a1f9ecdad1f3 uuid /contract/cwd name) ;;
        nvim) argv=$("$restore_fn" - none /contract/cwd name) ;;
        just) argv=$("$restore_fn" dev recipe /contract/cwd name) ;;
    esac
    assert_not_contains "$name restore_argv emits no shell control &&" "&&" "$argv"
    assert_not_contains "$name restore_argv emits no shell control ;" ";" "$argv"
done

PATH="$ORIG_PATH"
rm -rf "$tmpdir"

# ============================================================
echo ""
echo "=== adapters: uuid artifact validation ==="
# ============================================================

tmpdir=$(mktemp -d)
old_home_set="${HOME+x}"
old_home="${HOME-}"
restore_home() {
    if [ -n "$old_home_set" ]; then
        HOME="$old_home"
    else
        unset HOME
    fi
}

CLAUDE_UUID=0cbb1761-1a50-4cc4-8e7d-7b4bbdc788bf
claude_unset_home_output=$(env -u HOME bash -uo pipefail -c '
    plugin_dir="$1"
    sid="$2"
    . "$plugin_dir/adapters/10-claude.sh"
    claude_validate "$sid" uuid
' _ "$PLUGIN_DIR" "$CLAUDE_UUID" 2>&1)
claude_unset_home_status=$?
assert_eq "claude_validate uuid with HOME unset returns nonzero" \
    "nonzero" \
    "$([ "$claude_unset_home_status" -ne 0 ] && printf nonzero || printf zero)"
assert_not_contains "claude_validate uuid with HOME unset does not crash on unbound HOME" \
    "unbound variable" \
    "$claude_unset_home_output"

tmp_home="$tmpdir/claude-home"
mkdir -p "$tmp_home"
HOME="$tmp_home"
claude_validate "$CLAUDE_UUID" uuid
claude_missing_status=$?
assert_eq "claude_validate uuid missing jsonl returns nonzero" \
    "1" \
    "$claude_missing_status"
mkdir -p "$HOME/.claude/projects/my-project"
: > "$HOME/.claude/projects/my-project/$CLAUDE_UUID.jsonl"
claude_validate "$CLAUDE_UUID" uuid
claude_present_status=$?
assert_eq "claude_validate uuid present jsonl returns zero" \
    "0" \
    "$claude_present_status"
claude_validate not-a-uuid uuid
claude_invalid_status=$?
assert_eq "claude_validate invalid uuid string returns nonzero" \
    "1" \
    "$claude_invalid_status"
restore_home

CODEX_UUID=019dd3be-9166-7750-8039-a1f9ecdad1f3
codex_unset_home_output=$(env -u HOME bash -uo pipefail -c '
    plugin_dir="$1"
    sid="$2"
    . "$plugin_dir/adapters/20-codex.sh"
    codex_validate "$sid" uuid
' _ "$PLUGIN_DIR" "$CODEX_UUID" 2>&1)
codex_unset_home_status=$?
assert_eq "codex_validate uuid with HOME unset returns nonzero" \
    "nonzero" \
    "$([ "$codex_unset_home_status" -ne 0 ] && printf nonzero || printf zero)"
assert_not_contains "codex_validate uuid with HOME unset does not crash on unbound HOME" \
    "unbound variable" \
    "$codex_unset_home_output"

tmp_home="$tmpdir/codex-home"
mkdir -p "$tmp_home"
HOME="$tmp_home"
codex_validate "$CODEX_UUID" uuid
codex_missing_status=$?
assert_eq "codex_validate uuid missing rollout jsonl returns nonzero" \
    "1" \
    "$codex_missing_status"
mkdir -p "$HOME/.codex/sessions/2026/05/25"
: > "$HOME/.codex/sessions/2026/05/25/rollout-2026-05-25T000000-$CODEX_UUID.jsonl"
codex_validate "$CODEX_UUID" uuid
codex_present_status=$?
assert_eq "codex_validate uuid present rollout jsonl returns zero" \
    "0" \
    "$codex_present_status"
codex_validate not-a-uuid uuid
codex_invalid_status=$?
assert_eq "codex_validate invalid uuid string returns nonzero" \
    "1" \
    "$codex_invalid_status"
restore_home

tmp_home="$tmpdir/non-uuid-home"
mkdir -p "$tmp_home"
HOME="$tmp_home"
assert_eq "claude_validate picker returns zero without artifacts" \
    "0" \
    "$(claude_validate picker picker; echo $?)"
assert_eq "claude_validate none returns zero without artifacts" \
    "0" \
    "$(claude_validate - none; echo $?)"
assert_eq "codex_validate picker returns zero without artifacts" \
    "0" \
    "$(codex_validate picker picker; echo $?)"
assert_eq "codex_validate none returns zero without artifacts" \
    "0" \
    "$(codex_validate - none; echo $?)"
restore_home

rm -rf "$tmpdir"
unset -f restore_home

# ============================================================
echo ""
echo "=== lib/quote: shell_quote_word and shell_quote_argv ==="
# ============================================================
# shellcheck source=../lib/quote.sh
. "$PLUGIN_DIR/lib/quote.sh"

assert_eq "quote_word sh wraps plain word" \
    "'hello'" \
    "$(shell_quote_word sh hello)"

assert_eq "quote_word fish preserves spaces" \
    "'two words'" \
    "$(shell_quote_word fish "two words")"

assert_eq "quote_word escapes single quote for sh-compatible shells" \
    "'it'\''s'" \
    "$(shell_quote_word sh "it's")"

assert_eq "quote_word escapes single quote for fish" \
    "'it'\''s'" \
    "$(shell_quote_word fish "it's")"

assert_eq "quote_word empty word is quoted empty string" \
    "''" \
    "$(shell_quote_word sh "")"

danger_dir="${TMPDIR:-/tmp}/tmux-claude-quote-danger"
rm -rf "$danger_dir"
danger_word="x'; mkdir -p '$danger_dir'; echo '"
quoted=$(shell_quote_word sh "$danger_word")
eval "set -- $quoted"
assert_eq "quote_word round-trips shell metacharacters without executing" \
    "$danger_word" \
    "$1"
assert_eq "quote_word did not execute injected mkdir" \
    "absent" \
    "$([ -d "$danger_dir" ] && echo present || echo absent)"

argv=$(printf 'ccy\n--name\nwork name\n--resume\n0cbb1761-1a50-4cc4-8e7d-7b4bbdc788bf')
assert_eq "quote_argv joins newline words safely" \
    "'ccy' '--name' 'work name' '--resume' '0cbb1761-1a50-4cc4-8e7d-7b4bbdc788bf'" \
    "$(shell_quote_argv fish "$argv")"

danger_argv=$(printf 'cmd\n%s' "$danger_word")
quoted_argv=$(shell_quote_argv sh "$danger_argv")
eval "set -- $quoted_argv"
assert_eq "quote_argv preserves dangerous second word" \
    "$danger_word" \
    "$2"
assert_eq "quote_argv did not execute injected mkdir" \
    "absent" \
    "$([ -d "$danger_dir" ] && echo present || echo absent)"

for shell_path in /bin/sh /bin/bash /bin/zsh /bin/dash /bin/ksh; do
    [ -x "$shell_path" ] || continue
    shell_name="${shell_path##*/}"
    rm -rf "$danger_dir"
    out=$("$shell_path" -c "set -- $quoted_argv; printf '<%s><%s>\n' \"\$1\" \"\$2\"")
    assert_eq "quote_argv round-trips under $shell_name" \
        "<cmd><$danger_word>" \
        "$out"
    assert_eq "quote_argv under $shell_name did not execute injected mkdir" \
        "absent" \
        "$([ -d "$danger_dir" ] && echo present || echo absent)"
done

fish_path="$(command -v fish 2>/dev/null || true)"
if [ -n "$fish_path" ]; then
    rm -rf "$danger_dir"
    out=$("$fish_path" -c "set -l words $quoted_argv; printf '<%s><%s>\n' \$words[1] \$words[2]")
    assert_eq "quote_argv round-trips under fish" \
        "<cmd><$danger_word>" \
        "$out"
    assert_eq "quote_argv under fish did not execute injected mkdir" \
        "absent" \
        "$([ -d "$danger_dir" ] && echo present || echo absent)"
fi

assert_eq "quote_argv empty argv fails" \
    "1" \
    "$(shell_quote_argv sh "" >/dev/null; echo $?)"

quote_file_tmp=$(mktemp "${TMPDIR:-/tmp}/tmux-claude-argv-file.XXXXXX")
printf 'cmd\n\n' > "$quote_file_tmp"
assert_eq "quote_argv_file preserves final empty word" \
    "'cmd' ''" \
    "$(shell_quote_argv_file sh "$quote_file_tmp")"
rm -f "$quote_file_tmp"

rm -rf "$danger_dir"

# ============================================================
echo ""
echo "=== lib/restore_log: best-effort logging ==="
# ============================================================
# shellcheck source=../lib/restore_log.sh
. "$PLUGIN_DIR/lib/restore_log.sh"

tmpdir=$(mktemp -d)
logfile="$tmpdir/restore.log"

restore_log_open "$logfile"
restore_log BEGIN "snapshot=claude-panes.txt dry_run=true"
restore_log OK "0:1.1 claude abc"
restore_log_close

assert_contains "restore_log writes BEGIN line" \
    "BEGIN snapshot=claude-panes.txt dry_run=true" \
    "$(cat "$logfile")"
assert_contains "restore_log writes OK line" \
    "OK 0:1.1 claude abc" \
    "$(cat "$logfile")"

fd_log="$tmpdir/fd-leak.log"
fd_bad="$tmpdir/fd-bad-dir"
mkdir "$fd_bad"
restore_log_open "$fd_log"
restore_log OK "before failed reopen"
restore_log_open "$fd_bad"
restore_log_close
fd_log_size_before_probe=$(wc -c < "$fd_log" | tr -d ' ')
fd9_write_rc=$((printf x >&9) 2>/dev/null; echo $?)
fd_log_size_after_probe=$(wc -c < "$fd_log" | tr -d ' ')
assert_eq "restore_log failed reopen closes fd 9" \
    "1" \
    "$fd9_write_rc"
assert_eq "restore_log failed reopen does not write to old log" \
    "$fd_log_size_before_probe" \
    "$fd_log_size_after_probe"

bad_fd_stderr="$tmpdir/bad-fd-stderr"
bad_fd_rc_file="$tmpdir/bad-fd-rc"
exec 9>&- 2>/dev/null || true
{
    RESTORE_LOG_FD_OPEN=1
    restore_log WARN "bad fd"
    bad_fd_rc=$?
    RESTORE_LOG_FD_OPEN=0
    printf '%s' "$bad_fd_rc" > "$bad_fd_rc_file"
} 2> "$bad_fd_stderr"
assert_eq "restore_log bad fd returns zero" \
    "0" \
    "$(cat "$bad_fd_rc_file")"
assert_eq "restore_log bad fd is silent on stderr" \
    "" \
    "$(cat "$bad_fd_stderr")"

rel_tmpdir="$tmpdir/relative"
mkdir -p "$rel_tmpdir"
(
    cd "$rel_tmpdir" || exit 1
    restore_log_open "restore.log"
    restore_log OK "relative path"
    restore_log_close
) 2> "$tmpdir/relative-stderr"
assert_eq "restore_log relative path creates file not directory" \
    "file" \
    "$([ -f "$rel_tmpdir/restore.log" ] && echo file || ([ -d "$rel_tmpdir/restore.log" ] && echo dir || echo missing))"
assert_contains "restore_log relative path writes line" \
    "OK relative path" \
    "$(cat "$rel_tmpdir/restore.log" 2>/dev/null || true)"

big_payload=$(printf 'x%.0s' $(seq 1 1100000))
printf '%s' "$big_payload" > "$logfile"
restore_log_open "$logfile"
restore_log BEGIN "rotated"
restore_log_close
assert_eq "restore_log rotates existing large log" \
    "yes" \
    "$([ -f "$logfile.1" ] && echo yes || echo no)"
assert_contains "restore_log writes new log after rotation" \
    "BEGIN rotated" \
    "$(cat "$logfile")"

bad_parent="$tmpdir/not-a-dir"
printf 'file' > "$bad_parent"
restore_log_open "$bad_parent/restore.log"
restore_log WARN "unwritable path does not abort"
restore_log_close
assert_eq "restore_log ignores open failure" \
    "0" \
    "$?"

dir_log="$tmpdir/log-as-dir"
mkdir "$dir_log"
stderr_file="$tmpdir/stderr"
rcs_file="$tmpdir/rcs"
{
    restore_log_open "$dir_log"
    open_rc=$?
    restore_log WARN "directory target does not abort"
    log_rc=$?
    restore_log_close
    close_rc=$?
    printf '%s:%s:%s' "$open_rc" "$log_rc" "$close_rc" > "$rcs_file"
} 2> "$stderr_file"
assert_eq "restore_log impossible path returns zero" \
    "0:0:0" \
    "$(cat "$rcs_file")"
assert_eq "restore_log impossible path is silent on stderr" \
    "" \
    "$(cat "$stderr_file")"

invalid_max_log="$tmpdir/invalid-max.log"
printf 'data' > "$invalid_max_log"
invalid_max_stderr="$tmpdir/invalid-max-stderr"
old_restore_log_max_bytes="$RESTORE_LOG_MAX_BYTES"
{
    RESTORE_LOG_MAX_BYTES=bogus
    restore_log_open "$invalid_max_log"
    invalid_max_open_rc=$?
    restore_log WARN "invalid max bytes does not abort"
    invalid_max_log_rc=$?
    restore_log_close
    invalid_max_close_rc=$?
    RESTORE_LOG_MAX_BYTES="$old_restore_log_max_bytes"
    printf '%s:%s:%s' "$invalid_max_open_rc" "$invalid_max_log_rc" "$invalid_max_close_rc" > "$tmpdir/invalid-max-rcs"
} 2> "$invalid_max_stderr"
assert_eq "restore_log invalid max bytes returns zero" \
    "0:0:0" \
    "$(cat "$tmpdir/invalid-max-rcs")"
assert_eq "restore_log invalid max bytes is silent on stderr" \
    "" \
    "$(cat "$invalid_max_stderr")"

rm -rf "$tmpdir"

# ============================================================
echo ""
echo "=== lib/restore_helpers: names, flags, prompt wait ==="
# ============================================================
# shellcheck source=../lib/restore_helpers.sh
. "$PLUGIN_DIR/lib/restore_helpers.sh"

tmux() {
    case "$1" in
        list-panes)
            printf '%s\n%s\n' x x
            ;;
        display-message)
            case "$*" in
                *"#{pane_current_command}"*) printf '%s\n' "${MOCK_PANE_COMMAND:-fish}" ;;
                *) return 1 ;;
            esac
            ;;
        send-keys)
            printf '%s\n' "$*" >> "$MOCK_TMUX_LOG"
            ;;
        capture-pane)
            if [ "${MOCK_CAPTURE_AFTER_SEND:-}" = "1" ] && \
                [ -f "$MOCK_TMUX_LOG" ] && \
                grep -qF "send-keys -t %1 printf '" "$MOCK_TMUX_LOG"; then
                printf '%s\n' "__tcready_forced__"
                return 0
            fi
            if [ "${MOCK_CAPTURE_AFTER_SEND:-}" = "wrapped" ] && \
                [ -f "$MOCK_TMUX_LOG" ] && \
                grep -qF "send-keys -t %1 printf '" "$MOCK_TMUX_LOG"; then
                case " $* " in
                    *" -J "*) printf '%s\n' "__tcready_wrapped__" ;;
                    *) printf '%s\n%s\n' "__tcready_" "wrapped__" ;;
                esac
                return 0
            fi
            if [ "${MOCK_CAPTURE_AFTER_SEND:-}" = "continuation" ] && \
                [ -f "$MOCK_TMUX_LOG" ] && \
                grep -qF "send-keys -t %1 printf '" "$MOCK_TMUX_LOG"; then
                printf 'CONT> printf %%s\\\\n %s\n' "${TMUX_CLAUDE_READY_MARKER:-}"
                return 0
            fi
            printf '%s\n' "$MOCK_CAPTURE"
            ;;
        *) return 1 ;;
    esac
}

tmpdir=$(mktemp -d)
MOCK_TMUX_LOG="$tmpdir/tmux.log"
MOCK_CAPTURE=""

assert_eq "restore_make_display_name appends pane index for multi-pane window" \
    "work.2" \
    "$(restore_make_display_name "work" "0:3.2")"

assert_eq "restore_make_display_name falls back from shell window name" \
    "0:3.2" \
    "$(restore_make_display_name "fish" "0:3.2")"

assert_eq "restore_make_display_name sanitizes metacharacters" \
    "bad-rm--rf--.2" \
    "$(restore_make_display_name "bad;rm -rf /" "0:3.2")"

newline_wname=$(printf 'good\n--resume\nevil')
assert_eq "restore_make_display_name sanitizes embedded newlines" \
    "good---resume-evil.2" \
    "$(restore_make_display_name "$newline_wname" "0:3.2")"

assert_eq "restore_flag_has finds exact semicolon-separated flag" \
    "0" \
    "$(restore_flag_has "sid_invalid;cwd_collapsed" "cwd_collapsed"; echo $?)"

assert_eq "restore_flag_has rejects substring flag match" \
    "1" \
    "$(restore_flag_has "not_sid_invalid" "sid_invalid"; echo $?)"

assert_eq "restore_sid_valid accepts uuid" \
    "0" \
    "$(restore_sid_valid "0cbb1761-1a50-4cc4-8e7d-7b4bbdc788bf" uuid; echo $?)"

sid_with_newline=$(printf '0cbb1761-1a50-4cc4-8e7d-7b4bbdc788bf\n--dangerously-skip-permissions')
assert_eq "restore_sid_valid rejects uuid with newline" \
    "1" \
    "$(restore_sid_valid "$sid_with_newline" uuid; echo $?)"

assert_eq "restore_sid_valid accepts picker sentinel" \
    "0" \
    "$(restore_sid_valid picker picker; echo $?)"

assert_eq "restore_sid_valid rejects picker with extra text" \
    "1" \
    "$(restore_sid_valid "picker --danger" picker; echo $?)"

assert_eq "restore_sid_valid accepts spaced recipe" \
    "0" \
    "$(restore_sid_valid "dev server" recipe; echo $?)"

recipe_with_newline=$(printf 'dev\n--danger')
assert_eq "restore_sid_valid rejects recipe with newline" \
    "1" \
    "$(restore_sid_valid "$recipe_with_newline" recipe; echo $?)"

assert_eq "restore_sid_valid accepts none sentinel" \
    "0" \
    "$(restore_sid_valid "-" none; echo $?)"

MOCK_PANE_COMMAND=claude
assert_eq "wait_for_prompt returns nonzero for non-shell foreground" \
    "1" \
    "$(wait_for_prompt "%1"; echo $?)"

MOCK_PANE_COMMAND=fish
MOCK_CAPTURE=""
MOCK_CAPTURE_AFTER_SEND=1
TMUX_CLAUDE_READY_MARKER="__tcready_forced__"
assert_eq "wait_for_prompt succeeds when marker appears" \
    "0" \
    "$(wait_for_prompt "%1"; echo $?)"
assert_contains "wait_for_prompt sends encoded printf marker" \
    "send-keys -t %1 printf '" \
    "$(cat "$MOCK_TMUX_LOG")"
assert_not_contains "wait_for_prompt probe does not type literal marker" \
    "__tcready_forced__" \
    "$(cat "$MOCK_TMUX_LOG")"

unset TMUX_CLAUDE_READY_MARKER
unset MOCK_CAPTURE_AFTER_SEND

MOCK_CAPTURE="old __tcready_stale__"
TMUX_CLAUDE_READY_MARKER="__tcready_fresh__"
TMUX_CLAUDE_PROMPT_ATTEMPTS=1
TMUX_CLAUDE_PROMPT_SLEEP=0
assert_eq "wait_for_prompt ignores stale marker with different fresh marker" \
    "1" \
    "$(wait_for_prompt "%1"; echo $?)"
unset TMUX_CLAUDE_READY_MARKER
unset TMUX_CLAUDE_PROMPT_ATTEMPTS
unset TMUX_CLAUDE_PROMPT_SLEEP

MOCK_PANE_COMMAND=fish
MOCK_CAPTURE="old __tcready_same__"
TMUX_CLAUDE_READY_MARKER="__tcready_same__"
TMUX_CLAUDE_PROMPT_ATTEMPTS=1
TMUX_CLAUDE_PROMPT_SLEEP=0
assert_eq "wait_for_prompt rejects same-marker stale scrollback" \
    "1" \
    "$(wait_for_prompt "%1"; echo $?)"
unset TMUX_CLAUDE_READY_MARKER
unset TMUX_CLAUDE_PROMPT_ATTEMPTS
unset TMUX_CLAUDE_PROMPT_SLEEP

rm -f "$MOCK_TMUX_LOG"
MOCK_CAPTURE=""
MOCK_CAPTURE_AFTER_SEND=wrapped
TMUX_CLAUDE_READY_MARKER="__tcready_wrapped__"
TMUX_CLAUDE_PROMPT_ATTEMPTS=1
TMUX_CLAUDE_PROMPT_SLEEP=0
assert_eq "wait_for_prompt succeeds when marker wraps visually" \
    "0" \
    "$(wait_for_prompt "%1"; echo $?)"
unset MOCK_CAPTURE_AFTER_SEND
unset TMUX_CLAUDE_READY_MARKER
unset TMUX_CLAUDE_PROMPT_ATTEMPTS
unset TMUX_CLAUDE_PROMPT_SLEEP

MOCK_CAPTURE=""
MOCK_CAPTURE_AFTER_SEND=continuation
TMUX_CLAUDE_READY_MARKER="__tcready_cont__"
TMUX_CLAUDE_PROMPT_ATTEMPTS=1
TMUX_CLAUDE_PROMPT_SLEEP=0
assert_eq "wait_for_prompt rejects continuation prompt echoed marker" \
    "1" \
    "$(wait_for_prompt "%1"; echo $?)"
unset MOCK_CAPTURE_AFTER_SEND
unset TMUX_CLAUDE_READY_MARKER
unset TMUX_CLAUDE_PROMPT_ATTEMPTS
unset TMUX_CLAUDE_PROMPT_SLEEP

rm -f "$MOCK_TMUX_LOG"
MOCK_CAPTURE=""
TMUX_CLAUDE_READY_MARKER="bad;touch"
TMUX_CLAUDE_PROMPT_ATTEMPTS=1
TMUX_CLAUDE_PROMPT_SLEEP=0
assert_eq "wait_for_prompt rejects unsafe marker override" \
    "1" \
    "$(wait_for_prompt "%1"; echo $?)"
assert_eq "wait_for_prompt does not send unsafe marker override" \
    "absent" \
    "$([ -f "$MOCK_TMUX_LOG" ] && echo present || echo absent)"
unset TMUX_CLAUDE_READY_MARKER
unset TMUX_CLAUDE_PROMPT_ATTEMPTS
unset TMUX_CLAUDE_PROMPT_SLEEP

unset -f tmux
rm -rf "$tmpdir"

# ============================================================
echo ""
echo "=== session-restore: dry-run adapter dispatch ==="
# ============================================================

tmpdir=$(mktemp -d)
tmpbin="$tmpdir/bin"
resurrect_dir="$tmpdir/resurrect"
pwned="${TMPDIR:-/tmp}/tmux-claude-restore-pwned"
mkdir -p "$tmpbin" "$resurrect_dir"
rm -f "$pwned"

cat > "$resurrect_dir/claude-panes.txt" <<'EOF'
# Claude/Codex session mapping — v1 fixture for Chunk 3 restore
0:1.1|claude|0cbb1761-1a50-4cc4-8e7d-7b4bbdc788bf|/repo/claude|fine tuning
0:2.1|codex|019dd3be-9166-7750-8039-a1f9ecdad1f3|/repo/codex|codex-win
0:3.1|claude|picker|/repo/picker|picker-win
0:4.1|nvim|picker|/repo/edit|editor
0:5.1|just|dev|/repo/app|server
EOF
printf "0:6.1|claude|0cbb1761-1a50-4cc4-8e7d-7b4bbdc788bf|/repo/evil'; touch '%s'; echo '|bad;name\n" "$pwned" >> "$resurrect_dir/claude-panes.txt"

cat > "$tmpbin/tmux" <<EOF
#!/usr/bin/env bash
case "\$1" in
    show-option)
        if [ "\$4" = "@resurrect-dir" ] || [ "\$3" = "@resurrect-dir" ]; then
            printf '%s\n' "$resurrect_dir"
            exit 0
        fi
        exit 1
        ;;
    display-message)
        case "\$*" in
            *"#{pane_current_command}"*) printf '%s\n' fish ;;
            *) exit 1 ;;
        esac
        ;;
    list-panes)
        printf '%s\n' x
        ;;
    send-keys)
        printf '%s\n' "\$*" >> "$tmpdir/send-keys.log"
        ;;
    *)
        exit 1
        ;;
esac
EOF
chmod +x "$tmpbin/tmux"

ORIG_PATH="$PATH"
PATH="$tmpbin:$PATH"
out=$(TMUX_CLAUDE_RESTORE_BOOT_DELAY=0 bash "$PLUGIN_DIR/scripts/session-restore.sh" --dry-run)
rc=$?
PATH="$ORIG_PATH"

assert_eq "restore dry-run exits 0" "0" "$rc"
assert_contains "restore dry-run dispatches claude adapter" \
    "'ccy' '--name' 'fine-tuning' '--resume' '0cbb1761-1a50-4cc4-8e7d-7b4bbdc788bf'" "$out"
assert_contains "restore dry-run dispatches codex adapter" \
    "'cxy' 'resume' '019dd3be-9166-7750-8039-a1f9ecdad1f3'" "$out"
assert_contains "restore dry-run handles claude picker" \
    "'ccy' '--name' 'picker-win' '--resume'" "$out"
assert_contains "restore dry-run dispatches nvim adapter" \
    "'nvim'" "$out"
assert_contains "restore dry-run dispatches just adapter" \
    "'just' 'dev'" "$out"
assert_contains "restore dry-run uses cd fallback" \
    "cd '/repo/claude' 2>/dev/null || cd;" "$out"
assert_contains "restore dry-run includes malicious fixture pane" \
    "[dry-run] 0:6.1:" "$out"
assert_eq "restore dry-run does not execute malicious cwd while building command" \
    "absent" \
    "$([ -f "$pwned" ] && echo present || echo absent)"
assert_eq "restore dry-run does not send keys" \
    "absent" \
    "$([ -f "$tmpdir/send-keys.log" ] && echo present || echo absent)"

rm -f "$pwned"
rm -rf "$tmpdir"

# ============================================================
echo ""
echo "=== session-restore: failure isolation ==="
# ============================================================

write_restore_tmux_stub() {
    local tmux_path="$1"
    local restore_dir="$2"
    local send_keys_log="$3"

    cat > "$tmux_path" <<EOF
#!/usr/bin/env bash
case "\$1" in
    show-option)
        if [ "\$4" = "@resurrect-dir" ] || [ "\$3" = "@resurrect-dir" ]; then
            printf '%s\n' "$restore_dir"
            exit 0
        fi
        exit 1
        ;;
    display-message)
        case "\$*" in
            *"#{pane_current_command}"*) printf '%s\n' fish ;;
            *) exit 1 ;;
        esac
        ;;
    list-panes)
        printf '%s\n' x
        ;;
    send-keys)
        printf '%s\n' "\$*" >> "$send_keys_log"
        ;;
    *)
        exit 1
        ;;
esac
EOF
    chmod +x "$tmux_path"
}

tmpdir=$(mktemp -d)
tmpbin="$tmpdir/bin"
resurrect_dir="$tmpdir/resurrect"
send_keys_log="$tmpdir/send-keys.log"
mkdir -p "$tmpbin" "$resurrect_dir/.claude-restore.lock"
{
    printf '# tmux-claude snapshot v2\n'
    printf '# fields: target\ttool\tsid\tsid_kind\tcwd\toriginal_cwd\twname\tflags\n'
    printf '0:1.1\tclaude\t0cbb1761-1a50-4cc4-8e7d-7b4bbdc788bf\tuuid\t/repo/locked\t\tlocked\t\n'
} > "$resurrect_dir/claude-panes.txt"
write_restore_tmux_stub "$tmpbin/tmux" "$resurrect_dir" "$send_keys_log"

ORIG_PATH="$PATH"
PATH="$tmpbin:$PATH"
out=$(TMUX_CLAUDE_RESTORE_BOOT_DELAY=0 bash "$PLUGIN_DIR/scripts/session-restore.sh")
rc=$?
PATH="$ORIG_PATH"
restore_log_content=$(cat "$resurrect_dir/restore.log" 2>/dev/null || true)

assert_eq "restore lock exits 0" "0" "$rc"
assert_eq "restore lock does not send keys" \
    "absent" \
    "$([ -f "$send_keys_log" ] && echo present || echo absent)"
assert_contains "restore lock logs skip" \
    "SKIP restore_already_running" \
    "$restore_log_content"

rm -rf "$tmpdir"

tmpdir=$(mktemp -d)
tmpbin="$tmpdir/bin"
resurrect_dir="$tmpdir/resurrect"
send_keys_log="$tmpdir/send-keys.log"
mkdir -p "$tmpbin" "$resurrect_dir/.claude-restore.lock"
printf '%s\n' 999999 > "$resurrect_dir/.claude-restore.lock/pid"
{
    printf '# tmux-claude snapshot v2\n'
    printf '# fields: target\ttool\tsid\tsid_kind\tcwd\toriginal_cwd\twname\tflags\n'
    printf '0:1.1\tclaude\t0cbb1761-1a50-4cc4-8e7d-7b4bbdc788bf\tuuid\t/repo/stale-lock\t\tstale-lock\t\n'
} > "$resurrect_dir/claude-panes.txt"
write_restore_tmux_stub "$tmpbin/tmux" "$resurrect_dir" "$send_keys_log"

ORIG_PATH="$PATH"
PATH="$tmpbin:$PATH"
out=$(TMUX_CLAUDE_RESTORE_BOOT_DELAY=0 bash "$PLUGIN_DIR/scripts/session-restore.sh" --dry-run)
rc=$?
PATH="$ORIG_PATH"
restore_log_content=$(cat "$resurrect_dir/restore.log" 2>/dev/null || true)

assert_eq "restore stale lock exits 0" "0" "$rc"
assert_contains "restore stale lock proceeds after reclaim" \
    "[dry-run] 0:1.1" "$out"
assert_not_contains "restore stale lock does not log already running" \
    "restore_already_running" "$restore_log_content"
assert_eq "restore stale lock cleanup removes lock" \
    "absent" \
    "$([ -d "$resurrect_dir/.claude-restore.lock" ] && echo present || echo absent)"

rm -rf "$tmpdir"

tmpdir=$(mktemp -d)
tmpbin="$tmpdir/bin"
resurrect_dir="$tmpdir/resurrect"
send_keys_log="$tmpdir/send-keys.log"
mkdir -p "$tmpbin" "$resurrect_dir"
{
    printf '# tmux-claude snapshot v9\n'
    printf '# fields: target\ttool\tsid\tsid_kind\tcwd\toriginal_cwd\twname\tflags\n'
    printf '0:9.1\tclaude\t0cbb1761-1a50-4cc4-8e7d-7b4bbdc788bf\tuuid\t/repo/v9\t\tv9-win\t\n'
} > "$resurrect_dir/claude-panes.txt"
write_restore_tmux_stub "$tmpbin/tmux" "$resurrect_dir" "$send_keys_log"

ORIG_PATH="$PATH"
PATH="$tmpbin:$PATH"
out=$(TMUX_CLAUDE_RESTORE_BOOT_DELAY=0 bash "$PLUGIN_DIR/scripts/session-restore.sh" --dry-run)
rc=$?
PATH="$ORIG_PATH"
restore_log_content=$(cat "$resurrect_dir/restore.log" 2>/dev/null || true)

assert_eq "restore snapshot_read failure exits 0" "0" "$rc"
assert_eq "restore snapshot_read failure does not send keys" \
    "absent" \
    "$([ -f "$send_keys_log" ] && echo present || echo absent)"
assert_contains "restore snapshot_read failure logs skip" \
    "SKIP snapshot snapshot_read_failed" \
    "$restore_log_content"
assert_contains "restore snapshot_read failure logs final counts" \
    "END ok=0 warn=0 skip=1 total=0" \
    "$restore_log_content"

rm -rf "$tmpdir"

tmpdir=$(mktemp -d)
tmpbin="$tmpdir/bin"
resurrect_dir="$tmpdir/resurrect"
send_keys_log="$tmpdir/send-keys.log"
mkdir -p "$tmpbin" "$resurrect_dir"
{
    printf '# tmux-claude snapshot v2\n'
    printf '# fields: target\ttool\tsid\tsid_kind\tcwd\toriginal_cwd\twname\tflags\n'
    printf '0:7.1\tclaude\t0cbb1761-1a50-4cc4-8e7d-7b4bbdc788bf\tuuid\t/repo/v2\t\tv2 win\t\n'
} > "$resurrect_dir/claude-panes.txt"
write_restore_tmux_stub "$tmpbin/tmux" "$resurrect_dir" "$send_keys_log"

ORIG_PATH="$PATH"
PATH="$tmpbin:$PATH"
out=$(TMUX_CLAUDE_RESTORE_BOOT_DELAY=0 bash "$PLUGIN_DIR/scripts/session-restore.sh" --dry-run)
rc=$?
PATH="$ORIG_PATH"

assert_eq "restore v2 empty fields exits 0" "0" "$rc"
assert_contains "restore v2 empty fields preserves cwd column" \
    "cd '/repo/v2' 2>/dev/null || cd;" \
    "$out"
assert_contains "restore v2 empty fields preserves wname after empty original_cwd" \
    "'--name' 'v2-win'" \
    "$out"

rm -rf "$tmpdir"

tmpdir=$(mktemp -d)
tmpbin="$tmpdir/bin"
resurrect_dir="$tmpdir/resurrect"
send_keys_log="$tmpdir/send-keys.log"
mkdir -p "$tmpbin" "$resurrect_dir"
{
    printf '# tmux-claude snapshot v2\n'
    printf '# fields: target\ttool\tsid\tsid_kind\tcwd\toriginal_cwd\twname\tflags\n'
    printf '0:7.1\tclaude\t0cbb1761-1a50-4cc4-8e7d-7b4bbdc788bf%%0A--dangerously-skip-permissions\tuuid\t/repo/v2\t\twin\t\n'
} > "$resurrect_dir/claude-panes.txt"
write_restore_tmux_stub "$tmpbin/tmux" "$resurrect_dir" "$send_keys_log"

ORIG_PATH="$PATH"
PATH="$tmpbin:$PATH"
out=$(TMUX_CLAUDE_RESTORE_BOOT_DELAY=0 bash "$PLUGIN_DIR/scripts/session-restore.sh" --dry-run)
rc=$?
PATH="$ORIG_PATH"
restore_log_content=$(cat "$resurrect_dir/restore.log" 2>/dev/null || true)

assert_eq "restore v2 newline sid exits 0" "0" "$rc"
assert_not_contains "restore v2 newline sid does not emit injected argv" \
    "--dangerously-skip-permissions" \
    "$out"
assert_contains "restore v2 newline sid logs invalid sid skip" \
    "SKIP 0:7.1 claude invalid_sid" \
    "$restore_log_content"

rm -rf "$tmpdir"

tmpdir=$(mktemp -d)
tmpbin="$tmpdir/bin"
resurrect_dir="$tmpdir/resurrect"
send_keys_log="$tmpdir/send-keys.log"
mkdir -p "$tmpbin" "$resurrect_dir"
{
    printf '# tmux-claude snapshot v2\n'
    printf '# fields: target\ttool\tsid\tsid_kind\tcwd\toriginal_cwd\twname\tflags\n'
    printf '0:7.1\tclaude\t0cbb1761-1a50-4cc4-8e7d-7b4bbdc788bf\tuuid\t/repo/v2\t\tgood%%0A--resume%%0Aevil\t\n'
} > "$resurrect_dir/claude-panes.txt"
write_restore_tmux_stub "$tmpbin/tmux" "$resurrect_dir" "$send_keys_log"

ORIG_PATH="$PATH"
PATH="$tmpbin:$PATH"
out=$(TMUX_CLAUDE_RESTORE_BOOT_DELAY=0 bash "$PLUGIN_DIR/scripts/session-restore.sh" --dry-run)
rc=$?
PATH="$ORIG_PATH"

assert_eq "restore v2 newline wname exits 0" "0" "$rc"
assert_contains "restore v2 newline wname stays single name argv" \
    "'--name' 'good---resume-evil' '--resume' '0cbb1761-1a50-4cc4-8e7d-7b4bbdc788bf'" \
    "$out"
assert_not_contains "restore v2 newline wname does not inject resume argv" \
    "'--name' 'good' '--resume' 'evil'" \
    "$out"

rm -rf "$tmpdir"

tmpdir=$(mktemp -d)
tmpbin="$tmpdir/bin"
resurrect_dir="$tmpdir/resurrect"
send_keys_log="$tmpdir/send-keys.log"
mkdir -p "$tmpbin" "$resurrect_dir"
{
    printf '# tmux-claude snapshot v2\n'
    printf '# fields: target\ttool\tsid\tsid_kind\tcwd\toriginal_cwd\twname\tflags\n'
    printf '0:8.1\tjust\t-\tnone\t/repo/bad\t\tbad-just\t\n'
    printf '0:9.1\tclaude\t0cbb1761-1a50-4cc4-8e7d-7b4bbdc788bf\tuuid\t/repo/good\t\tgood claude\t\n'
} > "$resurrect_dir/claude-panes.txt"
write_restore_tmux_stub "$tmpbin/tmux" "$resurrect_dir" "$send_keys_log"

ORIG_PATH="$PATH"
PATH="$tmpbin:$PATH"
out=$(TMUX_CLAUDE_RESTORE_BOOT_DELAY=0 bash "$PLUGIN_DIR/scripts/session-restore.sh" --dry-run)
rc=$?
PATH="$ORIG_PATH"
restore_log_content=$(cat "$resurrect_dir/restore.log" 2>/dev/null || true)

assert_eq "restore adapter error isolation exits 0" "0" "$rc"
assert_contains "restore adapter error logs bad row skip" \
    "SKIP 0:8.1 just adapter_error" \
    "$restore_log_content"
assert_contains "restore adapter error continues to good claude row" \
    "'ccy' '--name' 'good-claude' '--resume' '0cbb1761-1a50-4cc4-8e7d-7b4bbdc788bf'" \
    "$out"
assert_contains "restore adapter error logs final counts" \
    "END ok=1 warn=0 skip=1 total=2" \
    "$restore_log_content"

rm -rf "$tmpdir"
unset -f write_restore_tmux_stub

# ============================================================
echo ""
echo "=== session-restore: target window mismatch ==="
# ============================================================

write_restore_window_tmux_stub() {
    local tmux_path="$1"
    local restore_dir="$2"

    cat > "$tmux_path" <<EOF
#!/usr/bin/env bash
restore_dir='$restore_dir'
case "\$1" in
    show-option)
        if [ "\$4" = "@resurrect-dir" ] || [ "\$3" = "@resurrect-dir" ]; then
            printf '%s\n' "\$restore_dir"
            exit 0
        fi
        exit 1
        ;;
    display-message)
        case "\$*" in
            *"#{pane_current_command}"*) printf '%s\n' fish ;;
            *"#{window_name}"*)
                case "\$*" in
                    *"0:3.1"*) printf '%s\n' ci ;;
                    *"0:6.1"*) printf '%s\n' reminders ;;
                    *) printf '%s\n' unknown ;;
                esac
                ;;
            *) exit 1 ;;
        esac
        ;;
    list-windows)
        if [ -f "\$restore_dir/windows" ]; then
            cat "\$restore_dir/windows"
        fi
        ;;
    list-panes)
        case "\$*" in
            *"0:4"*) printf '%s\n' 1 ;;
            *"0:6"*) printf '%s\n' 1 ;;
            *) printf '%s\n' x ;;
        esac
        ;;
    send-keys)
        printf '%s\n' "\$*" >> "\$restore_dir/send-keys.log"
        ;;
    *)
        exit 1
        ;;
esac
EOF
    chmod +x "$tmux_path"
}

tmpdir=$(mktemp -d)
tmpbin="$tmpdir/bin"
resurrect_dir="$tmpdir/resurrect"
mkdir -p "$tmpbin" "$resurrect_dir"
{
    printf '# tmux-claude snapshot v2\n'
    printf '# fields: target\ttool\tsid\tsid_kind\tcwd\toriginal_cwd\twname\tflags\n'
    printf '0:3.1\tclaude\t0cbb1761-1a50-4cc4-8e7d-7b4bbdc788bf\tuuid\t/repo/reminders\t\treminders\t\n'
} > "$resurrect_dir/claude-panes.txt"
{
    printf '3\tci\n'
    printf '6\treminders\n'
} > "$resurrect_dir/windows"
write_restore_window_tmux_stub "$tmpbin/tmux" "$resurrect_dir"

ORIG_PATH="$PATH"
PATH="$tmpbin:$PATH"
out=$(TMUX_CLAUDE_RESTORE_BOOT_DELAY=0 bash "$PLUGIN_DIR/scripts/session-restore.sh" --dry-run)
rc=$?
PATH="$ORIG_PATH"

assert_eq "restore remap exits 0" "0" "$rc"
assert_contains "restore remaps mismatched numeric target by window name" \
    "[dry-run] 0:6.1:" "$out"
assert_not_contains "restore does not type into stale numeric target" \
    "[dry-run] 0:3.1:" "$out"

rm -rf "$tmpdir"

tmpdir=$(mktemp -d)
tmpbin="$tmpdir/bin"
resurrect_dir="$tmpdir/resurrect"
mkdir -p "$tmpbin" "$resurrect_dir"
{
    printf '# tmux-claude snapshot v2\n'
    printf '# fields: target\ttool\tsid\tsid_kind\tcwd\toriginal_cwd\twname\tflags\n'
    printf '0:3.1\tclaude\t0cbb1761-1a50-4cc4-8e7d-7b4bbdc788bf\tuuid\t/repo/reminders\t\treminders\t\n'
} > "$resurrect_dir/claude-panes.txt"
printf '3\tci\n' > "$resurrect_dir/windows"
write_restore_window_tmux_stub "$tmpbin/tmux" "$resurrect_dir"

ORIG_PATH="$PATH"
PATH="$tmpbin:$PATH"
out=$(TMUX_CLAUDE_RESTORE_BOOT_DELAY=0 bash "$PLUGIN_DIR/scripts/session-restore.sh" --dry-run)
rc=$?
PATH="$ORIG_PATH"
restore_log_content=$(cat "$resurrect_dir/restore.log" 2>/dev/null || true)

assert_eq "restore missing remap exits 0" "0" "$rc"
assert_not_contains "restore skips mismatched target without matching window" \
    "[dry-run]" "$out"
assert_contains "restore logs target window mismatch" \
    "SKIP 0:3.1 claude window_mismatch current=ci saved=reminders" "$restore_log_content"

rm -rf "$tmpdir"

tmpdir=$(mktemp -d)
tmpbin="$tmpdir/bin"
resurrect_dir="$tmpdir/resurrect"
mkdir -p "$tmpbin" "$resurrect_dir"
{
    printf '# tmux-claude snapshot v2\n'
    printf '# fields: target\ttool\tsid\tsid_kind\tcwd\toriginal_cwd\twname\tflags\n'
    printf '0:3.1\tclaude\t0cbb1761-1a50-4cc4-8e7d-7b4bbdc788bf\tuuid\t/repo/reminders\t\treminders\t\n'
} > "$resurrect_dir/claude-panes.txt"
{
    printf '3\tci\n'
    printf '4\treminders\n'
    printf '6\treminders\n'
} > "$resurrect_dir/windows"
write_restore_window_tmux_stub "$tmpbin/tmux" "$resurrect_dir"

ORIG_PATH="$PATH"
PATH="$tmpbin:$PATH"
out=$(TMUX_CLAUDE_RESTORE_BOOT_DELAY=0 bash "$PLUGIN_DIR/scripts/session-restore.sh" --dry-run)
rc=$?
PATH="$ORIG_PATH"
restore_log_content=$(cat "$resurrect_dir/restore.log" 2>/dev/null || true)

assert_eq "restore ambiguous remap exits 0" "0" "$rc"
assert_not_contains "restore skips ambiguous matching windows" \
    "[dry-run]" "$out"
assert_contains "restore logs ambiguous remap as mismatch" \
    "SKIP 0:3.1 claude window_mismatch current=ci saved=reminders" "$restore_log_content"

rm -rf "$tmpdir"
unset -f write_restore_window_tmux_stub

# ============================================================
echo ""
echo "=== session-restore: v2 flags and restore log ==="
# ============================================================

tmpdir=$(mktemp -d)
tmpbin="$tmpdir/bin"
resurrect_dir="$tmpdir/resurrect"
mkdir -p "$tmpbin" "$resurrect_dir"

cat > "$resurrect_dir/claude-panes.txt" <<'EOF'
# tmux-claude snapshot v2
# fields: target	tool	sid	sid_kind	cwd	original_cwd	wname	flags
0:1.1	claude	-	none	/repo/bad		bad-pane	sid_invalid
0:2.1	codex	019dd3be-9166-7750-8039-a1f9ecdad1f3	uuid	/repo	/repo/pruned	codex-win	cwd_collapsed
EOF

cat > "$tmpbin/tmux" <<EOF
#!/usr/bin/env bash
case "\$1" in
    show-option)
        if [ "\$4" = "@resurrect-dir" ] || [ "\$3" = "@resurrect-dir" ]; then
            printf '%s\n' "$resurrect_dir"
            exit 0
        fi
        exit 1
        ;;
    display-message)
        case "\$*" in
            *"#{pane_current_command}"*) printf '%s\n' fish ;;
            *) exit 1 ;;
        esac
        ;;
    list-panes)
        printf '%s\n' x
        ;;
    send-keys)
        printf '%s\n' "\$*" >> "$tmpdir/send-keys.log"
        ;;
    *)
        exit 1
        ;;
esac
EOF
chmod +x "$tmpbin/tmux"

ORIG_PATH="$PATH"
PATH="$tmpbin:$PATH"
out=$(TMUX_CLAUDE_RESTORE_BOOT_DELAY=0 bash "$PLUGIN_DIR/scripts/session-restore.sh" --dry-run)
rc=$?
PATH="$ORIG_PATH"
log_content=$(cat "$resurrect_dir/restore.log")

assert_eq "restore v2 flags dry-run exits 0" "0" "$rc"
assert_not_contains "restore skips sid_invalid dry-run command" "[dry-run] 0:1.1:" "$out"
assert_contains "restore logs sid_invalid skip" \
    "SKIP 0:1.1 claude sid_invalid" "$log_content"
assert_contains "restore dry-run includes cwd_collapsed pane" \
    "'cxy' 'resume' '019dd3be-9166-7750-8039-a1f9ecdad1f3'" "$out"
assert_contains "restore logs cwd_collapsed warning" \
    "WARN 0:2.1 codex cwd_collapsed orig=/repo/pruned new=/repo" "$log_content"
assert_contains "restore logs END counts" \
    "END ok=0 warn=1 skip=1 total=2" "$log_content"

rm -rf "$tmpdir"

tmpdir=$(mktemp -d)
tmpbin="$tmpdir/bin"
resurrect_dir="$tmpdir/resurrect"
mkdir -p "$tmpbin" "$resurrect_dir"

cat > "$resurrect_dir/claude-panes.txt" <<'EOF'
# tmux-claude snapshot v2
# fields: target	tool	sid	sid_kind	cwd	original_cwd	wname	flags
0:2.1	codex	019dd3be-9166-7750-8039-a1f9ecdad1f3	uuid	/repo%0AOK forged	/repo/pruned%0AWARN forged	codex-win	cwd_collapsed
EOF

cat > "$tmpbin/tmux" <<EOF
#!/usr/bin/env bash
case "\$1" in
    show-option)
        if [ "\$4" = "@resurrect-dir" ] || [ "\$3" = "@resurrect-dir" ]; then
            printf '%s\n' "$resurrect_dir"
            exit 0
        fi
        exit 1
        ;;
    display-message)
        case "\$*" in
            *"#{pane_current_command}"*) printf '%s\n' fish ;;
            *) exit 1 ;;
        esac
        ;;
    list-panes)
        printf '%s\n' x
        ;;
    send-keys)
        printf '%s\n' "\$*" >> "$tmpdir/send-keys.log"
        ;;
    *)
        exit 1
        ;;
esac
EOF
chmod +x "$tmpbin/tmux"

ORIG_PATH="$PATH"
PATH="$tmpbin:$PATH"
out=$(TMUX_CLAUDE_RESTORE_BOOT_DELAY=0 bash "$PLUGIN_DIR/scripts/session-restore.sh" --dry-run)
rc=$?
PATH="$ORIG_PATH"
log_content=$(cat "$resurrect_dir/restore.log")
forged_log_lines=$(printf '%s\n' "$log_content" | grep -E '^(OK|WARN) forged' || true)
forged_dry_run_lines=$(printf '%s\n' "$out" | grep -E '^(OK|WARN) forged' || true)

assert_eq "restore escaped log fields dry-run exits 0" "0" "$rc"
assert_eq "restore log does not include forged standalone lines" \
    "" "$forged_log_lines"
assert_contains "restore log escapes cwd newline" \
    "new=/repo\\nOK forged" "$log_content"
assert_contains "restore log escapes original cwd newline" \
    "orig=/repo/pruned\\nWARN forged" "$log_content"
assert_eq "restore dry-run does not include forged standalone lines" \
    "" "$forged_dry_run_lines"
assert_contains "restore dry-run escapes cwd newline" \
    "cd '/repo\\nOK forged'" "$out"

rm -rf "$tmpdir"

# ============================================================
echo ""
echo "=== session-restore: live prompt wait and error isolation ==="
# ============================================================

tmpdir=$(mktemp -d)
tmpbin="$tmpdir/bin"
resurrect_dir="$tmpdir/resurrect"
mkdir -p "$tmpbin" "$resurrect_dir"

cat > "$resurrect_dir/claude-panes.txt" <<'EOF'
# tmux-claude snapshot v2
# fields: target	tool	sid	sid_kind	cwd	original_cwd	wname	flags
0:1.1	claude	0cbb1761-1a50-4cc4-8e7d-7b4bbdc788bf	uuid	/repo/one		one	-
0:2.1	codex	019dd3be-9166-7750-8039-a1f9ecdad1f3	uuid	/repo/two		two	-
EOF

cat > "$tmpbin/tmux" <<EOF
#!/usr/bin/env bash
case "\$1" in
    show-option)
        if [ "\$4" = "@resurrect-dir" ] || [ "\$3" = "@resurrect-dir" ]; then
            printf '%s\n' "$resurrect_dir"
            exit 0
        fi
        exit 1
        ;;
    display-message)
        case "\$*" in
            *"#{pane_current_command}"*)
                case "\$*" in
                    *"0:1.1"*) printf '%s\n' claude ;;
                    *) printf '%s\n' fish ;;
                esac
                ;;
            *) exit 1 ;;
        esac
        ;;
    list-panes)
        printf '%s\n' x
        ;;
    send-keys)
        printf '%s\n' "\$*" >> "$tmpdir/send-keys.log"
        ;;
    capture-pane)
        if [ -f "$tmpdir/send-keys.log" ] && \
            grep -qF "printf '" "$tmpdir/send-keys.log"; then
            printf '%s\n' "__tcready_forced__"
        fi
        ;;
    *)
        exit 1
        ;;
esac
EOF
chmod +x "$tmpbin/tmux"

ORIG_PATH="$PATH"
PATH="$tmpbin:$PATH"
TMUX_CLAUDE_RESTORE_BOOT_DELAY=0 \
TMUX_CLAUDE_READY_MARKER="__tcready_forced__" \
TMUX_CLAUDE_PROMPT_ATTEMPTS=1 \
TMUX_CLAUDE_PROMPT_SLEEP=0 \
bash "$PLUGIN_DIR/scripts/session-restore.sh"
rc=$?
PATH="$ORIG_PATH"

send_log=$(cat "$tmpdir/send-keys.log")
restore_log_content=$(cat "$resurrect_dir/restore.log")
assert_eq "restore live exits 0 despite one busy pane" "0" "$rc"
assert_contains "restore live logs prompt wait skip for busy pane" \
    "SKIP 0:1.1 claude prompt_wait_timeout" "$restore_log_content"
assert_contains "restore live waits with encoded marker before sending restore command" \
    "printf '" "$send_log"
assert_not_contains "restore live wait probe does not type literal marker" \
    "__tcready_forced__" "$send_log"
assert_not_contains "restore live does not send busy pane restore command" \
    "'ccy' '--name' 'one' '--resume' '0cbb1761-1a50-4cc4-8e7d-7b4bbdc788bf'" "$send_log"
assert_contains "restore live sends second pane command after marker" \
    "'cxy' 'resume' '019dd3be-9166-7750-8039-a1f9ecdad1f3'" "$send_log"
marker_line=$(printf '%s\n' "$send_log" | grep -nF "printf '" | sed -n '1p' | cut -d: -f1)
restore_line=$(printf '%s\n' "$send_log" | grep -nF "'cxy' 'resume' '019dd3be-9166-7750-8039-a1f9ecdad1f3'" | sed -n '1p' | cut -d: -f1)
marker_order="marker_order_failed marker=$marker_line restore=$restore_line"
if [ -n "$marker_line" ] && [ -n "$restore_line" ] && [ "$marker_line" -lt "$restore_line" ]; then
    marker_order="marker_before_restore"
fi
assert_eq "restore live marker send precedes second pane command" \
    "marker_before_restore" "$marker_order"
assert_contains "restore live continues after skipped pane" \
    "OK 0:2.1 codex 019dd3be-9166-7750-8039-a1f9ecdad1f3" "$restore_log_content"

rm -rf "$tmpdir"

# ============================================================
echo ""
echo "=== shell/tres.fish: restored session discovery ==="
# ============================================================

tmpdir=$(mktemp -d)
tmpbin="$tmpdir/bin"
tmphome="$tmpdir/home"
mkdir -p "$tmpbin" "$tmphome/.config/tmux/resurrect"

cat > "$tmpbin/tmux" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$TMUX_STUB_LOG"
case "$1" in
    show-option)
        exit 1
        ;;
    has-session)
        if [ "${TMUX_HAS_SESSION:-0}" = "1" ]; then
            exit 0
        fi
        exit 1
        ;;
    new-session)
        exit 0
        ;;
    list-windows)
        target=""
        while [ "$#" -gt 0 ]; do
            if [ "$1" = "-t" ]; then
                shift
                target="${1:-}"
                break
            fi
            shift
        done
        case "$target" in
            work) printf '%s\n' "1: fine-tuning" "2: seo" ;;
            0) printf '%s\n' "1: fallback" "2: other" ;;
            *) exit 1 ;;
        esac
        ;;
    kill-session)
        exit 0
        ;;
    attach)
        exit 0
        ;;
    *)
        exit 1
        ;;
esac
EOF
chmod +x "$tmpbin/tmux"
cat > "$tmpbin/sleep" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
chmod +x "$tmpbin/sleep"

cat > "$tmphome/.config/tmux/resurrect/last" <<'EOF'
pane	work	1	0	:	1	editor	:/repo	1	fish	:
window	work	1	:fine-tuning	0	:	layout	off
EOF

old_path="$PATH"
PATH="$tmpbin:$PATH"
TMUX_STUB_LOG="$tmpdir/tmux.log" \
HOME="$tmphome" \
XDG_CONFIG_HOME="$tmphome/.config" \
TMUX_HAS_SESSION=0 \
fish -c 'source "$argv[1]"; tres' "$PLUGIN_DIR/shell/tres.fish"
rc=$?
PATH="$old_path"

log=$(cat "$tmpdir/tmux.log")
assert_eq "tres exits 0 with discovered session" "0" "$rc"
assert_contains "tres creates bootstrap when no tmux server exists" \
    "new-session -d -s _tres_bootstrap" "$log"
assert_contains "tres waits on discovered session work" \
    "list-windows -t work" "$log"
assert_contains "tres kills bootstrap session" \
    "kill-session -t _tres_bootstrap" "$log"
assert_contains "tres attaches to discovered session work" \
    "attach -t work" "$log"
assert_not_contains "tres does not attach to hardcoded zero when snapshot has work" \
    "attach -t 0" "$log"

rm -rf "$tmpdir"

tmpdir=$(mktemp -d)
tmpbin="$tmpdir/bin"
tmphome="$tmpdir/home"
mkdir -p "$tmpbin" "$tmphome/.config/tmux/resurrect"

cat > "$tmpbin/tmux" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$TMUX_STUB_LOG"
case "$1" in
    show-option) exit 1 ;;
    has-session) exit 0 ;;
    list-windows)
        target=""
        while [ "$#" -gt 0 ]; do
            if [ "$1" = "-t" ]; then
                shift
                target="${1:-}"
                break
            fi
            shift
        done
        [ "$target" = "0" ] || exit 1
        printf '%s\n' "1: fallback" "2: restored"
        ;;
    kill-session) exit 0 ;;
    attach) exit 0 ;;
    *) exit 1 ;;
esac
EOF
chmod +x "$tmpbin/tmux"
cat > "$tmpbin/sleep" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
chmod +x "$tmpbin/sleep"

old_path="$PATH"
PATH="$tmpbin:$PATH"
TMUX_STUB_LOG="$tmpdir/tmux.log" HOME="$tmphome" XDG_CONFIG_HOME="$tmphome/.config" fish -c 'source "$argv[1]"; tres' "$PLUGIN_DIR/shell/tres.fish"
rc=$?
PATH="$old_path"

log=$(cat "$tmpdir/tmux.log")
assert_eq "tres exits 0 without snapshot" "0" "$rc"
assert_contains "tres defaults to session zero without snapshot" "attach -t 0" "$log"
assert_not_contains "tres does not create bootstrap when tmux server exists" "new-session -d -s _tres_bootstrap" "$log"

rm -rf "$tmpdir"

tmpdir=$(mktemp -d)
tmpbin="$tmpdir/bin"
tmphome="$tmpdir/home"
custom_resurrect="$tmpdir/custom-resurrect"
mkdir -p "$tmpbin" "$tmphome/.config/tmux/resurrect" "$custom_resurrect"

cat > "$tmpbin/tmux" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$TMUX_STUB_LOG"
case "$1" in
    show-option)
        case "$*" in
            *"@resurrect-dir"*) printf '%s\n' "$CUSTOM_RESURRECT_DIR"; exit 0 ;;
            *) exit 1 ;;
        esac
        ;;
    has-session) exit 0 ;;
    list-windows)
        target=""
        while [ "$#" -gt 0 ]; do
            if [ "$1" = "-t" ]; then
                shift
                target="${1:-}"
                break
            fi
            shift
        done
        [ "$target" = "work" ] || exit 1
        printf '%s\n' "1: fine-tuning" "2: seo"
        ;;
    kill-session) exit 0 ;;
    attach) exit 0 ;;
    *) exit 1 ;;
esac
EOF
chmod +x "$tmpbin/tmux"
cat > "$tmpbin/sleep" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
chmod +x "$tmpbin/sleep"

cat > "$custom_resurrect/last" <<'EOF'
pane	work	1	0	:	1	editor	:/repo	1	fish	:
EOF

old_path="$PATH"
PATH="$tmpbin:$PATH"
TMUX_STUB_LOG="$tmpdir/tmux.log" \
HOME="$tmphome" \
XDG_CONFIG_HOME="$tmphome/.config" \
CUSTOM_RESURRECT_DIR="$custom_resurrect" \
fish -c 'source "$argv[1]"; tres' "$PLUGIN_DIR/shell/tres.fish"
rc=$?
PATH="$old_path"

log=$(cat "$tmpdir/tmux.log")
assert_eq "tres exits 0 with custom resurrect dir" "0" "$rc"
assert_contains "tres reads target from custom resurrect dir" "attach -t work" "$log"
assert_not_contains "tres does not fall back when custom resurrect snapshot exists" "attach -t 0" "$log"

rm -rf "$tmpdir"

tmpdir=$(mktemp -d)
tmpbin="$tmpdir/bin"
tmphome="$tmpdir/home"
custom_resurrect="$tmpdir/custom-resurrect"
server_started="$tmpdir/server-started"
mkdir -p "$tmpbin" "$tmphome/.config/tmux/resurrect" "$custom_resurrect"

cat > "$tmpbin/tmux" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$TMUX_STUB_LOG"
case "$1" in
    show-option)
        if [ -f "$TMUX_SERVER_STARTED" ]; then
            case "$*" in
                *"@resurrect-dir"*) printf '%s\n' "$CUSTOM_RESURRECT_DIR"; exit 0 ;;
            esac
        fi
        exit 1
        ;;
    has-session)
        [ -f "$TMUX_SERVER_STARTED" ] && exit 0
        exit 1
        ;;
    new-session)
        touch "$TMUX_SERVER_STARTED"
        exit 0
        ;;
    list-windows)
        target=""
        while [ "$#" -gt 0 ]; do
            if [ "$1" = "-t" ]; then
                shift
                target="${1:-}"
                break
            fi
            shift
        done
        [ "$target" = "work" ] || exit 1
        printf '%s\n' "1: fine-tuning" "2: seo"
        ;;
    kill-session) exit 0 ;;
    attach) exit 0 ;;
    *) exit 1 ;;
esac
EOF
chmod +x "$tmpbin/tmux"
cat > "$tmpbin/sleep" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
chmod +x "$tmpbin/sleep"

cat > "$custom_resurrect/last" <<'EOF'
pane	work	1	0	:	1	editor	:/repo	1	fish	:
EOF

old_path="$PATH"
PATH="$tmpbin:$PATH"
TMUX_STUB_LOG="$tmpdir/tmux.log" \
HOME="$tmphome" \
XDG_CONFIG_HOME="$tmphome/.config" \
CUSTOM_RESURRECT_DIR="$custom_resurrect" \
TMUX_SERVER_STARTED="$server_started" \
fish -c 'source "$argv[1]"; tres' "$PLUGIN_DIR/shell/tres.fish"
rc=$?
PATH="$old_path"

log=$(cat "$tmpdir/tmux.log")
assert_eq "tres exits 0 with custom resurrect dir after bootstrap" "0" "$rc"
assert_contains "tres creates bootstrap before reading custom resurrect dir" \
    "new-session -d -s _tres_bootstrap" "$log"
assert_contains "tres attaches to custom resurrect session after bootstrap" "attach -t work" "$log"
assert_not_contains "tres does not fall back after bootstrap reveals custom resurrect dir" "attach -t 0" "$log"

rm -rf "$tmpdir"

tmpdir=$(mktemp -d)
tmpbin="$tmpdir/bin"
tmphome="$tmpdir/home"
mkdir -p "$tmpbin" "$tmphome/.config/tmux/resurrect"

cat > "$tmpbin/tmux" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$TMUX_STUB_LOG"
case "$1" in
    show-option) exit 1 ;;
    has-session) exit 0 ;;
    list-windows)
        target=""
        while [ "$#" -gt 0 ]; do
            if [ "$1" = "-t" ]; then
                shift
                target="${1:-}"
                break
            fi
            shift
        done
        [ "$target" = "work" ] || exit 1
        printf '%s\n' "1: fine-tuning"
        ;;
    attach) exit 0 ;;
    *) exit 1 ;;
esac
EOF
chmod +x "$tmpbin/tmux"
cat > "$tmpbin/sleep" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$SLEEP_STUB_LOG"
exit 0
EOF
chmod +x "$tmpbin/sleep"

cat > "$tmphome/.config/tmux/resurrect/last" <<'EOF'
pane	work	1	0	:	1	editor	:/repo	1	fish	:
EOF

old_path="$PATH"
PATH="$tmpbin:$PATH"
TMUX_STUB_LOG="$tmpdir/tmux.log" \
SLEEP_STUB_LOG="$tmpdir/sleep.log" \
HOME="$tmphome" \
XDG_CONFIG_HOME="$tmphome/.config" \
fish -c 'source "$argv[1]"; tres' "$PLUGIN_DIR/shell/tres.fish"
rc=$?
PATH="$old_path"

sleep_count=$(wc -l < "$tmpdir/sleep.log" | tr -d ' ')
assert_eq "tres exits 0 with one-window restored session" "0" "$rc"
assert_eq "tres does not wait full timeout for one-window session" "2" "$sleep_count"

rm -rf "$tmpdir"

if command -v fish >/dev/null 2>&1; then
    fish -n "$PLUGIN_DIR/shell/tres.fish"
    assert_eq "tres fish syntax is valid" "0" "$?"
else
    echo "  WARN: fish not installed; skipping tres syntax check"
fi

# ============================================================
echo ""
echo "=== session-audit: live pane report ==="
# ============================================================

tmpdir=$(mktemp -d)
tmpbin="$tmpdir/bin"
tmphome="$tmpdir/home"
mkdir -p "$tmpbin" "$tmphome/.codex/sessions"

audit_sid="019ea610-ef51-7b51-8a40-6c2b946b6450"
touch "$tmphome/.codex/sessions/rollout-test-${audit_sid}.jsonl"

cat > "$tmpbin/tmux" <<EOF
#!/usr/bin/env bash
case "\$1" in
    list-sessions)
        printf '%s\n' 0
        ;;
    list-windows)
        printf '%s\n' 1
        ;;
    list-panes)
        printf '%s\n' 1
        ;;
    display-message)
        case "\$*" in
            *"#{window_name}"*) printf '%s\n' audit ;;
            *"#{pane_current_command}"*) printf '%s\n' codex-aarch64-a ;;
            *"#{pane_current_path}"*) printf '%s\n' /repo ;;
            *"#{pane_pid}"*) printf '%s\n' 100 ;;
            *) exit 1 ;;
        esac
        ;;
    show-options)
        option=""
        while [ "\$#" -gt 0 ]; do
            if [ "\$1" = "-v" ]; then
                shift
                option="\${1:-}"
                break
            fi
            shift
        done
        case "\$option" in
            @codex_session_id) printf '%s\n' "$audit_sid" ;;
            @codex_session_pid) printf '%s\n' 999 ;;
            @codex_cwd) printf '%s\n' /repo ;;
            *) exit 1 ;;
        esac
        ;;
    *)
        exit 1
        ;;
esac
EOF
chmod +x "$tmpbin/tmux"

cat > "$tmpbin/ps" <<'EOF'
#!/usr/bin/env bash
if [ "$1" = "-axww" ] && [ "$2" = "-o" ] && [ "$3" = "pid=,ppid=,command=" ]; then
    printf '%s\n' "100 1 fish" "200 100 codex --yolo -s workspace-write resume"
elif [ "$1" = "-p" ] && [ "$3" = "-o" ] && [ "$4" = "command=" ]; then
    printf '%s\n' "codex --yolo -s workspace-write resume"
else
    exit 1
fi
EOF
chmod +x "$tmpbin/ps"

old_path="$PATH"
PATH="$tmpbin:$PATH"
audit_output=$(HOME="$tmphome" bash "$PLUGIN_DIR/scripts/session-audit.sh" 2>&1)
audit_rc=$?
PATH="$old_path"

assert_eq "audit exits 0 for UUID-restorable pane" "0" "$audit_rc"
assert_contains "audit reports target" "0:1.1" "$audit_output"
assert_contains "audit reports codex tool" "codex" "$audit_output"
assert_contains "audit reports codex uuid" "$audit_sid" "$audit_output"
assert_contains "audit reports pid mismatch trusted" "pid_mismatch_trusted" "$audit_output"

rm -rf "$tmpdir"

# ============================================================
echo ""
echo "=== README: tres and v2 snapshot docs ==="
# ============================================================

readme_content=$(cat "$PLUGIN_DIR/README.md")
assert_contains "README documents tres helper" "tres" "$readme_content"
assert_contains "README documents v2 snapshot format" "snapshot v2" "$readme_content"
assert_contains "README documents restore.log observability" "restore.log" "$readme_content"
assert_contains "README documents configured resurrect dir mapping location" "configured `@resurrect-dir`" "$readme_content"
assert_contains "README documents save/restore fallback mapping location" "~/.tmux/resurrect" "$readme_content"
assert_contains "README documents session audit command" "session-audit.sh" "$readme_content"
assert_contains "README documents fresh Claude default" "creates a fresh session" "$readme_content"
assert_contains "README documents explicit tmux resume opt-in" "--tmux-resume" "$readme_content"
assert_contains "README documents stale pid trust flag" "pid_mismatch_trusted" "$readme_content"
assert_contains "README documents restore lock" "restore_already_running" "$readme_content"
assert_contains "README documents audit nonzero behavior" "exits non-zero" "$readme_content"

# ============================================================
echo ""
echo "=== Results ==="
echo "  Passed: $PASS"
echo "  Failed: $FAIL"
[ "$FAIL" -eq 0 ] && green "  ALL TESTS PASSED" || red "  SOME TESTS FAILED"
exit "$FAIL"
