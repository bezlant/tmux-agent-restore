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
    if ! echo "$haystack" | grep -qF "$needle"; then
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
echo "=== stale pane option clearing ==="
# ============================================================

if [ -n "$TMUX" ]; then
    test_pane=$(tmux display-message -p '#{pane_id}')

    tmux set-option -p -t "$test_pane" @claude_session_id "old-claude-id" 2>/dev/null
    tmux set-option -p -t "$test_pane" @claude_cwd "/old/claude" 2>/dev/null
    tmux set-option -p -t "$test_pane" @codex_session_id "old-codex-id" 2>/dev/null
    tmux set-option -p -t "$test_pane" @codex_cwd "/old/codex" 2>/dev/null

    # Simulate Claude hook: sets claude, clears codex
    tmux set-option -p -t "$test_pane" @claude_session_id "new-claude-id" 2>/dev/null
    tmux set-option -pu -t "$test_pane" @codex_session_id 2>/dev/null
    tmux set-option -pu -t "$test_pane" @codex_cwd 2>/dev/null

    claude_val=$(tmux show-options -p -t "$test_pane" -v @claude_session_id 2>/dev/null || true)
    codex_val=$(tmux show-options -p -t "$test_pane" -v @codex_session_id 2>/dev/null || true)

    assert_eq "claude hook sets claude_session_id" "new-claude-id" "$claude_val"
    assert_eq "claude hook clears codex_session_id" "" "$codex_val"

    # Simulate Codex hook: sets codex, clears claude
    tmux set-option -p -t "$test_pane" @codex_session_id "new-codex-id" 2>/dev/null
    tmux set-option -pu -t "$test_pane" @claude_session_id 2>/dev/null
    tmux set-option -pu -t "$test_pane" @claude_cwd 2>/dev/null

    claude_val=$(tmux show-options -p -t "$test_pane" -v @claude_session_id 2>/dev/null || true)
    codex_val=$(tmux show-options -p -t "$test_pane" -v @codex_session_id 2>/dev/null || true)

    assert_eq "codex hook clears claude_session_id" "" "$claude_val"
    assert_eq "codex hook sets codex_session_id" "new-codex-id" "$codex_val"

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
echo "=== Results ==="
echo "  Passed: $PASS"
echo "  Failed: $FAIL"
[ "$FAIL" -eq 0 ] && green "  ALL TESTS PASSED" || red "  SOME TESTS FAILED"
exit "$FAIL"
