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
row_count=$(printf '%s\n' "$out" | grep -c '^' || true)

assert_eq "malformed v2: 1 good row survives, 1 short row skipped" \
    "1" "$row_count"
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
row_count=$(printf '%s\n' "$out" | grep -c '^' || true)

assert_eq "malformed v1: 1 good row promoted, 1 short row skipped" \
    "1" "$row_count"
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
row_count=$(printf '%s\n' "$out" | grep -c '^' || true)

assert_eq "v1 with extra pipe: extra-field row skipped, clean row promoted" \
    "1" "$row_count"
assert_contains "extra-pipe row logs WARN" "WARN" "$err"

rm -rf "$tmpdir"

# ============================================================
echo ""
echo "=== Results ==="
echo "  Passed: $PASS"
echo "  Failed: $FAIL"
[ "$FAIL" -eq 0 ] && green "  ALL TESTS PASSED" || red "  SOME TESTS FAILED"
exit "$FAIL"
