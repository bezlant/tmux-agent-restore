# tmux-claude Architecture Deepening Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Deepen the tmux-claude save/restore architecture so restore readiness, restore planning, SessionStart hooks, stable naming, tests, and domain decisions have clear Modules with high locality.

**Architecture:** Keep the plugin shell-native and compatible with macOS bash 3.2. Extract behaviour behind small shell interfaces only where at least two callers already need the same rules. Preserve all current user-facing commands and snapshot compatibility while reducing duplicated restore-readiness, hook, and stable-naming logic.

**Tech Stack:** bash, fish, zsh, tmux, tmux-resurrect, tmux-continuum, Python 3 for JSONL lookup, shell integration tests in `tests/run.sh`.

---

## File Structure

- Create `CONTEXT.md`: domain vocabulary for pane map, snapshot, restore readiness, stable naming, SessionStart stamp, restore plan, and `tres`.
- Create `docs/adr/0001-pane-map-restore-readiness.md`: record why pane maps and restore readiness are separate from tmux-resurrect snapshots.
- Create `docs/adr/0002-coexisting-tool-session-vars.md`: record why hooks do not clear the other tool's pane variables.
- Create `docs/adr/0003-fail-closed-target-remap.md`: record why restore remaps only unique window-name matches.
- Create `lib/restore_readiness.sh`: deep Module for live pane enumeration/detection/validation/cwd collapsing used by save and audit.
- Create `lib/session_hook.sh`: shared SessionStart hook Module used by Claude and Codex thin adapters.
- Create `lib/restore_plan.sh`: deep Module that turns decoded snapshot rows into restore actions before execution.
- Create `scripts/claude-session-args.sh`: cross-shell stable naming helper that emits one argv word per line.
- Create `scripts/claude-find-session.py`: shared custom-title lookup implementation.
- Modify `scripts/session-save.sh`: delegate live pane readiness to `lib/restore_readiness.sh`.
- Modify `scripts/session-audit.sh`: delegate audit row generation to `lib/restore_readiness.sh`.
- Modify `scripts/session-restore.sh`: delegate row validation, target resolution, adapter argv creation, and shell command construction to `lib/restore_plan.sh`.
- Modify `scripts/claude-session-hook.sh` and `scripts/codex-session-hook.sh`: become thin adapters over `lib/session_hook.sh`.
- Modify `shell/claude.fish`, `shell/__tmux_claude_session_args.fish`, `shell/claude.bash`, and `shell/claude.zsh`: use consistent opt-in resume semantics and shared lookup.
- Modify `tests/run.sh`: add focused regression tests for new Modules and keep existing full-suite coverage.
- Optional create `tests/lib/assertions.sh` and `tests/lib/fixtures.sh`: extract shared test harness helpers only if the implementation task touches those helpers anyway.
- Modify `README.md`: document architecture terms and stable naming consistency if behaviour changes.

---

### Task 1: Domain Docs and ADRs

**Files:**
- Create: `CONTEXT.md`
- Create: `docs/adr/0001-pane-map-restore-readiness.md`
- Create: `docs/adr/0002-coexisting-tool-session-vars.md`
- Create: `docs/adr/0003-fail-closed-target-remap.md`
- Modify: `README.md`

- [ ] **Step 1: Create domain vocabulary**

Create `CONTEXT.md` with these exact sections:

```markdown
# tmux-claude Context

## Domain Terms

**Stable naming** is the Claude wrapper behaviour that derives a Claude session name from the tmux window name and pane index. Single-pane windows use the window name. Multi-pane windows append `.<pane_index>`.

**SessionStart stamp** is the pane-local tmux state written by Claude/Codex hooks when an agent session starts. A stamp includes the tool session id, the detected live agent pid, and the cwd supplied by the agent hook.

**Pane map** is `claude-panes.txt` in the configured tmux-resurrect directory. It maps tmux pane targets to restorable tools and session identifiers using snapshot v2 TSV rows.

**Snapshot** is the versioned pane map format. Snapshot v2 has eight fields: `target`, `tool`, `sid`, `sid_kind`, `cwd`, `original_cwd`, `wname`, and `flags`.

**Restore readiness** is the live-pane state after adapter detection, UUID validation, cwd collapsing, and flag assignment. Save and audit must use the same restore readiness rules.

**Restore plan** is the per-row decision made during restore: skip, warn, or execute a shell command in a resolved tmux pane. A restore plan must fail closed when the saved target cannot be mapped safely to the live layout.

**Picker** is a degraded Claude/Codex restore mode where the tool is relaunched without a UUID because the exact session id is unavailable or unsafe.

**`tres`** is the fish helper that attaches to the restored tmux session after reboot, using the configured tmux-resurrect directory.

## Invariants

- Save must never clobber an existing pane map with an empty enumeration.
- Restore must never type a command into a pane whose live window name contradicts the saved window name unless exactly one safe remap exists.
- Claude and Codex SessionStart stamps may coexist in one pane; the saver chooses the live foreground tool instead of clearing the other tool's stamp.
- Save, audit, and dry-run restore are verification surfaces for the same restore-readiness behaviour.
- Stable naming starts fresh by default; tmux-name resume is explicit via `--tmux-resume` or `TMUX_CLAUDE_AUTO_RESUME=1`.
```

- [ ] **Step 2: Create ADR 0001**

Create `docs/adr/0001-pane-map-restore-readiness.md`:

```markdown
# ADR 0001: Keep pane map restore readiness separate from tmux-resurrect snapshots

## Status

Accepted

## Context

tmux-resurrect restores pane layout and process shells, but Claude and Codex need tool-specific session ids, cwd repair, and degraded picker behaviour. The plugin stores this as `claude-panes.txt` beside tmux-resurrect state.

## Decision

Keep `claude-panes.txt` as a separate snapshot v2 pane map and treat restore readiness as plugin-owned state derived from live panes.

## Consequences

- The plugin can validate Claude/Codex UUID artifacts before saving.
- The plugin can preserve the previous pane map when live enumeration returns zero panes.
- Restore can report plugin-specific `OK`, `WARN`, and `SKIP` outcomes in `restore.log`.
- Save and audit must share restore-readiness rules to avoid drift.
```

- [ ] **Step 3: Create ADR 0002**

Create `docs/adr/0002-coexisting-tool-session-vars.md`:

```markdown
# ADR 0002: Keep Claude and Codex SessionStart stamps coexisting in a pane

## Status

Accepted

## Context

A pane can host both Claude and Codex over its lifetime, including teammate/subagent workflows where the foreground command flips briefly. Clearing the other tool's pane variables caused valid session ids to disappear and degraded exact restore to picker restore.

## Decision

Claude hooks only write `@claude_*` pane options. Codex hooks only write `@codex_*` pane options. Neither hook clears the other tool's options. Restore readiness chooses the adapter by live foreground command and validates stale PID data before trusting it.

## Consequences

- Stale opposite-tool options are expected and harmless.
- Save must disambiguate by live foreground tool instead of adapter order alone.
- Tests must cover panes with both Claude and Codex stamps.
```

- [ ] **Step 4: Create ADR 0003**

Create `docs/adr/0003-fail-closed-target-remap.md`:

```markdown
# ADR 0003: Fail closed when restore target remap is missing or ambiguous

## Status

Accepted

## Context

After crash/restore, tmux numeric targets can drift. A stale pane map may say `0:3.1` while the restored layout now has the saved window under another index. Typing into the stale numeric target can restore the wrong session into the wrong pane.

## Decision

Restore first checks whether the saved numeric target still has the saved window name. If not, it remaps only when exactly one live window in the same session has the saved window name and the saved pane index. Zero matches or multiple matches are skipped with `window_mismatch`.

## Consequences

- Some panes may be skipped instead of guessed.
- Dry-run restore is the recommended way to inspect remaps before live restore.
- Duplicate window names are intentionally treated as unsafe.
```

- [ ] **Step 5: Add README architecture note**

Add a short `## Architecture Notes` section before `## License`:

```markdown
## Architecture Notes

The main domain terms and invariants live in `CONTEXT.md`. Load-bearing decisions are recorded in `docs/adr/` so future restore changes do not re-litigate coexisting tool stamps, pane map ownership, or fail-closed target remapping.
```

- [ ] **Step 6: Verify docs**

Run:

```bash
test -f CONTEXT.md
test -f docs/adr/0001-pane-map-restore-readiness.md
test -f docs/adr/0002-coexisting-tool-session-vars.md
test -f docs/adr/0003-fail-closed-target-remap.md
rg -n "Architecture Notes|CONTEXT.md|docs/adr" README.md CONTEXT.md docs/adr
```

Expected: all commands exit 0 and show matching lines.

- [ ] **Step 7: Commit**

```bash
git add CONTEXT.md docs/adr README.md
git commit -m "docs: record tmux-claude architecture decisions"
```

---

### Task 2: Restore Readiness Module

**Files:**
- Create: `lib/restore_readiness.sh`
- Modify: `scripts/session-save.sh`
- Modify: `scripts/session-audit.sh`
- Modify: `tests/run.sh`

- [ ] **Step 1: Add failing tests for shared restore readiness**

In `tests/run.sh`, add a new section after `=== lib/adapters: shared detect helper ===`:

```bash
# ============================================================
echo ""
echo "=== lib/restore_readiness: shared save/audit rows ==="
# ============================================================

unset -f tmux live_agent_pid process_command extract_uuid adapter_detect_agent 2>/dev/null || true

# shellcheck source=../lib/restore_readiness.sh
. "$PLUGIN_DIR/lib/restore_readiness.sh"

tmpdir=$(mktemp -d)
mkdir -p "$tmpdir/project" "$tmpdir/bin" "$tmpdir/home/.codex/sessions"
CODEX_READY_UUID="019ea610-ef51-7b51-8a40-6c2b946b6450"
touch "$tmpdir/home/.codex/sessions/rollout-test-$CODEX_READY_UUID.jsonl"

tmux() {
    case "$1" in
        display-message)
            case "$*" in
                *"#{pane_current_command}"*) printf '%s\n' codex-aarch64-a ;;
                *"#{pane_current_path}"*) printf '%s\n' "$tmpdir/project/missing/deeper" ;;
                *"#{window_name}"*) printf '%s\n' hsk ;;
                *) return 1 ;;
            esac
            ;;
        show-options)
            case "$*" in
                *"@codex_session_id"*) printf '%s\n' "$CODEX_READY_UUID" ;;
                *"@codex_session_pid"*) printf '%s\n' 999 ;;
                *"@codex_cwd"*) printf '%s\n' "$tmpdir/project/missing/deeper" ;;
                *) return 1 ;;
            esac
            ;;
        *) return 1 ;;
    esac
}
live_agent_pid() { printf '%s\n' 111; }
process_command() { printf '%s\n' "codex-aarch64-a exec"; }

row=$(HOME="$tmpdir/home" restore_readiness_pane_row "0:4.1")
assert_eq "restore readiness target" "0:4.1" "$(printf '%s' "$row" | cut -f1)"
assert_eq "restore readiness tool" "codex" "$(printf '%s' "$row" | cut -f2)"
assert_eq "restore readiness trusts valid stale pid" "$CODEX_READY_UUID" "$(printf '%s' "$row" | cut -f3)"
assert_eq "restore readiness marks uuid kind" "uuid" "$(printf '%s' "$row" | cut -f4)"
assert_eq "restore readiness collapses cwd" "$tmpdir/project" "$(printf '%s' "$row" | cut -f5)"
assert_eq "restore readiness preserves original cwd" "$tmpdir/project/missing/deeper" "$(printf '%s' "$row" | cut -f6)"
assert_eq "restore readiness window name" "hsk" "$(printf '%s' "$row" | cut -f7)"
assert_contains "restore readiness composes flags" "pid_mismatch_trusted" "$(printf '%s' "$row" | cut -f8)"
assert_contains "restore readiness composes collapsed flag" "cwd_collapsed" "$(printf '%s' "$row" | cut -f8)"

rm -rf "$tmpdir"
unset -f tmux live_agent_pid process_command
```

- [ ] **Step 2: Run failing test**

Run:

```bash
bash tests/run.sh
```

Expected: fails because `lib/restore_readiness.sh` does not exist or `restore_readiness_pane_row` is undefined.

- [ ] **Step 3: Implement `lib/restore_readiness.sh`**

Create `lib/restore_readiness.sh`:

```bash
#!/usr/bin/env bash
# tmux-claude: live pane restore-readiness rules shared by save and audit.

if ! declare -F adapters_list >/dev/null 2>&1; then
    _readiness_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
    # shellcheck source=adapters.sh
    . "$_readiness_dir/lib/adapters.sh"
    unset _readiness_dir
fi

restore_readiness_add_flag() {
    local current="$1"
    local flag="$2"

    case ";$current;" in
        *";$flag;"*) printf '%s\n' "$current"; return ;;
    esac

    if [ -n "$current" ]; then
        printf '%s;%s\n' "$current" "$flag"
    else
        printf '%s\n' "$flag"
    fi
}

restore_readiness_field() {
    local row="$1"
    local field="$2"
    printf '%s\n' "$row" | awk -F '\t' -v field="$field" 'NR == 1 { print $field }'
}

restore_readiness_collapse_cwd() {
    local cwd="$1"
    local parent

    [ -n "$cwd" ] || return 1
    while [ "$cwd" != "/" ] && [ ! -d "$cwd" ]; do
        case "$cwd" in
            */*)
                parent="${cwd%/*}"
                [ "$parent" != "$cwd" ] || parent="/"
                [ -n "$parent" ] || parent="/"
                cwd="$parent"
                ;;
            *)
                cwd="/"
                ;;
        esac
    done
    [ -d "$cwd" ] || return 1
    printf '%s\n' "$cwd"
}

restore_readiness_adapter_exists() {
    local wanted="$1"
    local adapter
    for adapter in $(adapters_list); do
        [ "$adapter" = "$wanted" ] && return 0
    done
    return 1
}

restore_readiness_adapter_hint() {
    local target="$1"
    local cmd adapter
    cmd=$(tmux display-message -p -t "$target" '#{pane_current_command}' 2>/dev/null || true)
    case "$cmd" in
        vim|nvim) adapter="nvim" ;;
        *codex*|*Codex*|*CODEX*) adapter="codex" ;;
        *claude*|*Claude*|*CLAUDE*) adapter="claude" ;;
        *) adapter="$cmd" ;;
    esac
    [ -n "$adapter" ] || return 1
    restore_readiness_adapter_exists "$adapter" || return 1
    printf '%s\n' "$adapter"
}

restore_readiness_detect_row() {
    local target="$1"
    local preferred_adapter detect_fn detect_row adapter

    preferred_adapter=$(restore_readiness_adapter_hint "$target" || true)
    if [ -n "$preferred_adapter" ]; then
        detect_fn="${preferred_adapter}_detect"
        if declare -F "$detect_fn" >/dev/null 2>&1 &&
            detect_row=$("$detect_fn" "$target" 2>/dev/null); then
            [ -n "$detect_row" ] && { printf '%s\n' "$detect_row"; return 0; }
        fi
    fi

    for adapter in $(adapters_list); do
        [ "$adapter" = "$preferred_adapter" ] && continue
        detect_fn="${adapter}_detect"
        if declare -F "$detect_fn" >/dev/null 2>&1 &&
            detect_row=$("$detect_fn" "$target" 2>/dev/null); then
            [ -n "$detect_row" ] && { printf '%s\n' "$detect_row"; return 0; }
        fi
    done

    return 1
}

restore_readiness_pane_row() {
    local target="$1"
    local detect_row tool sid sid_kind cwd detect_flags wname original_cwd flags validate_fn collapsed_cwd

    detect_row=$(restore_readiness_detect_row "$target") || return 1
    tool=$(restore_readiness_field "$detect_row" 1)
    sid=$(restore_readiness_field "$detect_row" 2)
    sid_kind=$(restore_readiness_field "$detect_row" 3)
    cwd=$(restore_readiness_field "$detect_row" 4)
    detect_flags=$(restore_readiness_field "$detect_row" 5)

    if [ -z "$cwd" ]; then
        cwd=$(tmux display-message -p -t "$target" '#{pane_current_path}' 2>/dev/null || true)
    fi
    wname=$(tmux display-message -p -t "$target" '#{window_name}' 2>/dev/null || true)

    original_cwd=""
    flags="$detect_flags"

    if [ "$sid_kind" = "uuid" ]; then
        validate_fn="${tool}_validate"
        if ! declare -F "$validate_fn" >/dev/null 2>&1 ||
            ! "$validate_fn" "$sid" "$sid_kind" >/dev/null 2>&1; then
            sid="-"
            sid_kind="none"
            flags=$(restore_readiness_add_flag "$flags" sid_invalid)
        fi
    fi

    if [ -n "$cwd" ] && [ ! -d "$cwd" ]; then
        original_cwd="$cwd"
        collapsed_cwd=$(restore_readiness_collapse_cwd "$cwd" 2>/dev/null || true)
        if [ -n "$collapsed_cwd" ]; then
            cwd="$collapsed_cwd"
        fi
        flags=$(restore_readiness_add_flag "$flags" cwd_collapsed)
    fi

    printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$target" "$tool" "$sid" "$sid_kind" "$cwd" "$original_cwd" "$wname" "$flags"
}
```

- [ ] **Step 4: Refactor `scripts/session-save.sh`**

Source `lib/restore_readiness.sh`, delete local functions `save_add_flag`, `save_collapse_cwd`, `save_detect_field`, `save_adapter_exists`, and `save_pane_adapter_hint`, and replace the inner pane detection block with:

```bash
target="$session:$win.$pane"
readiness_row=$(restore_readiness_pane_row "$target" 2>/dev/null || true)
[ -n "$readiness_row" ] || continue

tool=$(restore_readiness_field "$readiness_row" 2)
sid=$(restore_readiness_field "$readiness_row" 3)
sid_kind=$(restore_readiness_field "$readiness_row" 4)
cwd=$(restore_readiness_field "$readiness_row" 5)
original_cwd=$(restore_readiness_field "$readiness_row" 6)
wname=$(restore_readiness_field "$readiness_row" 7)
flags=$(restore_readiness_field "$readiness_row" 8)

snapshot_write_row "$target" "$tool" "$sid" "$sid_kind" "$cwd" "$original_cwd" "$wname" "$flags" >> "$tmpfile"
pane_count=$((pane_count + 1))
```

- [ ] **Step 5: Refactor `scripts/session-audit.sh`**

Source `lib/restore_readiness.sh`, delete local `audit_field` and `audit_add_flag`, and replace pane detection/validation with:

```bash
target="$session:$win.$pane"
readiness_row=$(restore_readiness_pane_row "$target" 2>/dev/null || true)
[ -n "$readiness_row" ] || continue

tool=$(restore_readiness_field "$readiness_row" 2)
sid=$(restore_readiness_field "$readiness_row" 3)
sid_kind=$(restore_readiness_field "$readiness_row" 4)
wname=$(restore_readiness_field "$readiness_row" 7)
flags=$(restore_readiness_field "$readiness_row" 8)

case "$tool:$sid_kind:$flags" in
    claude:picker:*|codex:picker:*|claude:none:*|codex:none:*|*:*:*sid_invalid*)
        status=1
        ;;
esac

printf '%-12s %-18s %-8s %-10s %-38s %s\n' "$target" "$wname" "$tool" "$sid_kind" "$sid" "$flags"
```

- [ ] **Step 6: Run tests**

Run:

```bash
bash tests/run.sh
```

Expected: all tests pass.

- [ ] **Step 7: Commit**

```bash
git add lib/restore_readiness.sh scripts/session-save.sh scripts/session-audit.sh tests/run.sh
git commit -m "refactor: share restore readiness between save and audit"
```

---

### Task 3: Shared SessionStart Hook Module

**Files:**
- Create: `lib/session_hook.sh`
- Modify: `scripts/claude-session-hook.sh`
- Modify: `scripts/codex-session-hook.sh`
- Modify: `tests/run.sh`

- [ ] **Step 1: Add module-level hook tests**

Add tests near `=== SessionStart hooks: pid stamping ===` that source `lib/session_hook.sh` with a tmux stub and assert:

```bash
assert_contains "shared hook stamps sid option" "set-option -p -t %1 @codex_session_id codex-hook-session" "$hook_log"
assert_contains "shared hook stamps pid option" "set-option -p -t %1 @codex_session_pid 4242" "$hook_log"
assert_contains "shared hook stamps cwd option" "set-option -p -t %1 @codex_cwd /tmp/project" "$hook_log"
assert_not_contains "shared hook does not clear opposite sid" "set-option -pu -t %1 @claude_session_id" "$hook_log"
```

Use the existing `run_hook_fixture` helper instead of creating a new stub.

- [ ] **Step 2: Run failing test**

Run:

```bash
bash tests/run.sh
```

Expected: fails because `lib/session_hook.sh` does not exist.

- [ ] **Step 3: Implement `lib/session_hook.sh`**

Create `lib/session_hook.sh`:

```bash
#!/usr/bin/env bash
# tmux-claude: shared Claude/Codex SessionStart hook implementation.

session_hook_command_matches_self() {
    local command="$1"
    local hook_path="$2"
    local hook_name="${hook_path##*/}"

    case "$command" in
        *"$hook_path"*|*"/$hook_name"*) return 0 ;;
        *) return 1 ;;
    esac
}

session_hook_non_hook_agent_parent_pid() {
    local pid="$1"
    local tool="$2"
    local hook_path="$3"
    local parent command

    while [ -n "$pid" ]; do
        parent=$(ps -p "$pid" -o ppid= 2>/dev/null | awk 'NR == 1 { print $1 }')
        [ -n "$parent" ] || return 1
        [ "$parent" != "$pid" ] || return 1

        command=$(process_command "$parent" 2>/dev/null || true)
        if [ -n "$command" ] && ! session_hook_command_matches_self "$command" "$hook_path"; then
            case "$command" in
                *"$tool"*) printf '%s\n' "$parent"; return 0 ;;
            esac
        fi
        pid="$parent"
    done

    return 1
}

session_hook_pid_in_hook_subtree() {
    local pid="$1"
    local hook_path="$2"
    local parent command

    while [ -n "$pid" ]; do
        command=$(process_command "$pid" 2>/dev/null || true)
        if [ -n "$command" ] && session_hook_command_matches_self "$command" "$hook_path"; then
            return 0
        fi

        parent=$(ps -p "$pid" -o ppid= 2>/dev/null | awk 'NR == 1 { print $1 }')
        [ -n "$parent" ] || return 1
        [ "$parent" != "$pid" ] || return 1
        pid="$parent"
    done

    return 1
}

session_hook_json_field() {
    local field="$1"
    python3 -c "import sys,json; print(json.load(sys.stdin).get('$field',''))" 2>/dev/null || true
}

session_hook_foreground_is_tool() {
    local pane="$1"
    local tool="$2"
    local pane_cmd
    pane_cmd=$(tmux display-message -p -t "$pane" '#{pane_current_command}' 2>/dev/null || true)
    case "$tool:$pane_cmd" in
        codex:*codex*|codex:*Codex*|codex:*CODEX*) return 0 ;;
        claude:*claude*|claude:*Claude*|claude:*CLAUDE*) return 0 ;;
        *) return 1 ;;
    esac
}

session_hook_run() {
    local tool="$1"
    local opposite_tool="$2"
    local sid_option="$3"
    local pid_option="$4"
    local cwd_option="$5"
    local plugin_dir="$6"
    local hook_path="$7"
    local input session_id cwd agent_pid

    [ -n "${TMUX:-}" ] || exit 0
    [ -n "${TMUX_PANE:-}" ] || exit 0

    input=$(cat)
    session_id=$(printf '%s\n' "$input" | session_hook_json_field session_id)
    [ -n "$session_id" ] || exit 0

    if session_hook_foreground_is_tool "$TMUX_PANE" "$opposite_tool"; then
        exit 0
    fi

    tmux set-option -p -t "$TMUX_PANE" "$sid_option" "$session_id" 2>/dev/null || true

    if declare -F live_agent_pid >/dev/null 2>&1; then
        agent_pid=$(live_agent_pid "$TMUX_PANE" "$tool" 2>/dev/null || true)
        if [ -n "$agent_pid" ] && declare -F process_command >/dev/null 2>&1; then
            if session_hook_pid_in_hook_subtree "$agent_pid" "$hook_path"; then
                agent_pid=$(session_hook_non_hook_agent_parent_pid "$agent_pid" "$tool" "$hook_path" 2>/dev/null || true)
            fi
        fi
        if [ -n "$agent_pid" ]; then
            tmux set-option -p -t "$TMUX_PANE" "$pid_option" "$agent_pid" 2>/dev/null || true
        fi
    fi

    cwd=$(printf '%s\n' "$input" | session_hook_json_field cwd)
    [ -n "$cwd" ] && tmux set-option -p -t "$TMUX_PANE" "$cwd_option" "$cwd" 2>/dev/null || true

    [ -x "$plugin_dir/scripts/session-save.sh" ] && bash "$plugin_dir/scripts/session-save.sh" >> /tmp/tmux-claude-save.log 2>&1 &
}
```

- [ ] **Step 4: Make hook scripts thin adapters**

Replace `scripts/claude-session-hook.sh` body after `set -euo pipefail` with:

```bash
[ -n "${TMUX:-}" ] || exit 0
[ -n "${TMUX_PANE:-}" ] || exit 0

PLUGIN_DIR="${TMUX_CLAUDE_PLUGIN_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"

# shellcheck source=../lib/process.sh
[ -f "$PLUGIN_DIR/lib/process.sh" ] && . "$PLUGIN_DIR/lib/process.sh"
# shellcheck source=../lib/session_hook.sh
. "$PLUGIN_DIR/lib/session_hook.sh"

session_hook_run claude codex @claude_session_id @claude_session_pid @claude_cwd "$PLUGIN_DIR" "$0"
```

Replace `scripts/codex-session-hook.sh` body after `set -euo pipefail` with:

```bash
[ -n "${TMUX:-}" ] || exit 0
[ -n "${TMUX_PANE:-}" ] || exit 0

PLUGIN_DIR="${TMUX_CLAUDE_PLUGIN_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"

# shellcheck source=../lib/process.sh
[ -f "$PLUGIN_DIR/lib/process.sh" ] && . "$PLUGIN_DIR/lib/process.sh"
# shellcheck source=../lib/session_hook.sh
. "$PLUGIN_DIR/lib/session_hook.sh"

session_hook_run codex claude @codex_session_id @codex_session_pid @codex_cwd "$PLUGIN_DIR" "$0"
```

- [ ] **Step 5: Run tests**

Run:

```bash
bash tests/run.sh
```

Expected: all tests pass.

- [ ] **Step 6: Commit**

```bash
git add lib/session_hook.sh scripts/claude-session-hook.sh scripts/codex-session-hook.sh tests/run.sh
git commit -m "refactor: share SessionStart hook implementation"
```

---

### Task 4: Restore Plan Module

**Files:**
- Create: `lib/restore_plan.sh`
- Modify: `scripts/session-restore.sh`
- Modify: `tests/run.sh`

- [ ] **Step 1: Add restore plan tests**

Add a section before `=== session-restore: dry-run adapter dispatch ===`:

```bash
# ============================================================
echo ""
echo "=== lib/restore_plan: build executable restore actions ==="
# ============================================================

unset -f tmux 2>/dev/null || true
# shellcheck source=../lib/restore_log.sh
. "$PLUGIN_DIR/lib/restore_log.sh"
# shellcheck source=../lib/restore_plan.sh
. "$PLUGIN_DIR/lib/restore_plan.sh"

tmpdir=$(mktemp -d)
argv_tmp="$tmpdir/argv"

tmux() {
    case "$1" in
        display-message)
            case "$*" in
                *"#{window_name}"*) printf '%s\n' work ;;
                *"#{pane_current_command}"*) printf '%s\n' fish ;;
                *) return 1 ;;
            esac
            ;;
        list-panes) printf '%s\n' 1 ;;
        *) return 1 ;;
    esac
}

restore_plan_action=$(
    restore_plan_build "0:1.1" "claude" "0cbb1761-1a50-4cc4-8e7d-7b4bbdc788bf" "uuid" "$tmpdir" "" "work" "" "$argv_tmp"
)
assert_eq "restore plan status" "ok" "$(printf '%s' "$restore_plan_action" | cut -f1)"
assert_eq "restore plan target" "0:1.1" "$(printf '%s' "$restore_plan_action" | cut -f2)"
assert_contains "restore plan command includes cd" "cd '$tmpdir'" "$(printf '%s' "$restore_plan_action" | cut -f4)"
assert_contains "restore plan command includes claude resume" "'ccy' '--name' 'work' '--resume' '0cbb1761-1a50-4cc4-8e7d-7b4bbdc788bf'" "$(printf '%s' "$restore_plan_action" | cut -f4)"

rm -rf "$tmpdir"
unset -f tmux
```

- [ ] **Step 2: Run failing test**

Run:

```bash
bash tests/run.sh
```

Expected: fails because `lib/restore_plan.sh` does not exist.

- [ ] **Step 3: Implement `lib/restore_plan.sh`**

Create `lib/restore_plan.sh`:

```bash
#!/usr/bin/env bash
# tmux-claude: convert decoded snapshot rows into executable restore actions.

_restore_plan_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
if ! declare -F restore_resolve_target >/dev/null 2>&1; then
    # shellcheck source=restore_helpers.sh
    . "$_restore_plan_dir/lib/restore_helpers.sh"
fi
if ! declare -F shell_quote_argv_file >/dev/null 2>&1; then
    # shellcheck source=quote.sh
    . "$_restore_plan_dir/lib/quote.sh"
fi
unset _restore_plan_dir

restore_plan_shell_for_target() {
    local target="$1"
    local pane_shell
    pane_shell=$(tmux display-message -p -t "$target" '#{pane_current_command}' 2>/dev/null || true)
    case "$pane_shell" in
        fish|bash|zsh|sh|dash|ksh) printf '%s\n' "$pane_shell" ;;
        *) printf '%s\n' sh ;;
    esac
}

restore_plan_build() {
    local target="$1"
    local tool="$2"
    local sid="$3"
    local sid_kind="$4"
    local cwd="$5"
    local original_cwd="$6"
    local wname="$7"
    local flags="$8"
    local argv_tmp="$9"

    local resolved_target restore_fn display_name pane_shell cmd cwd_q full current_wname

    if ! resolved_target=$(restore_resolve_target "$target" "$wname"); then
        current_wname=$(tmux display-message -p -t "$target" '#{window_name}' 2>/dev/null || true)
        [ -n "$current_wname" ] || current_wname="-"
        printf '%s\t%s\t%s\t%s\t%s\n' skip "$target" "$tool" window_mismatch "$current_wname"
        return 0
    fi

    restore_fn="${tool}_restore_argv"
    if ! declare -F "$restore_fn" >/dev/null 2>&1; then
        printf '%s\t%s\t%s\t%s\n' skip "$resolved_target" "$tool" missing_adapter
        return 0
    fi

    display_name=$(restore_make_display_name "$wname" "$resolved_target")
    : > "$argv_tmp"
    if ! "$restore_fn" "$sid" "$sid_kind" "$cwd" "$display_name" > "$argv_tmp" 2>/dev/null; then
        printf '%s\t%s\t%s\t%s\n' skip "$resolved_target" "$tool" adapter_error
        return 0
    fi

    pane_shell=$(restore_plan_shell_for_target "$resolved_target")
    if ! cmd=$(shell_quote_argv_file "$pane_shell" "$argv_tmp"); then
        printf '%s\t%s\t%s\t%s\n' skip "$resolved_target" "$tool" quote_argv_failed
        return 0
    fi

    cwd_q=$(shell_quote_word "$pane_shell" "$cwd")
    full="cd $cwd_q 2>/dev/null || cd; $cmd"
    printf '%s\t%s\t%s\t%s\n' ok "$resolved_target" "$tool" "$full"
}
```

- [ ] **Step 4: Refactor `scripts/session-restore.sh`**

Source `lib/restore_plan.sh`. Replace the block from target resolution through `full=...` construction with:

```bash
plan_row=$(restore_plan_build "$target" "$tool" "$sid" "$sid_kind" "$cwd" "$original_cwd" "$wname" "$flags" "$argv_tmp")
plan_status=$(printf '%s' "$plan_row" | cut -f1)

case "$plan_status" in
    ok)
        target=$(printf '%s' "$plan_row" | cut -f2)
        tool=$(printf '%s' "$plan_row" | cut -f3)
        full=$(printf '%s' "$plan_row" | cut -f4-)
        log_target=$(restore_log_value "$target")
        log_tool=$(restore_log_value "$tool")
        printf "%-12s %-8s %-8s %s\n" "$log_target" "($log_wname)" "$log_tool" "$log_sid"
        ;;
    skip)
        skip_target=$(printf '%s' "$plan_row" | cut -f2)
        skip_tool=$(printf '%s' "$plan_row" | cut -f3)
        skip_reason=$(printf '%s' "$plan_row" | cut -f4)
        log_target=$(restore_log_value "$skip_target")
        log_tool=$(restore_log_value "$skip_tool")
        skip=$((skip + 1))
        if [ "$skip_reason" = "window_mismatch" ]; then
            current_wname=$(printf '%s' "$plan_row" | cut -f5)
            log_current_wname=$(restore_log_value "$current_wname")
            restore_log SKIP "$log_target $log_tool window_mismatch current=$log_current_wname saved=$log_wname"
        else
            restore_log SKIP "$log_target $log_tool $skip_reason"
        fi
        continue
        ;;
    *)
        skip=$((skip + 1))
        restore_log SKIP "$log_target $log_tool restore_plan_invalid"
        continue
        ;;
esac
```

Keep existing dry-run, prompt wait, send-keys, warning, and OK logging code after this block.

- [ ] **Step 5: Run tests**

Run:

```bash
bash tests/run.sh
```

Expected: all tests pass.

- [ ] **Step 6: Commit**

```bash
git add lib/restore_plan.sh scripts/session-restore.sh tests/run.sh
git commit -m "refactor: build restore actions before execution"
```

---

### Task 5: Stable Naming Helper Consistency

**Files:**
- Create: `scripts/claude-find-session.py`
- Create: `scripts/claude-session-args.sh`
- Modify: `shell/__tmux_claude_find_session.fish`
- Modify: `shell/__tmux_claude_session_args.fish`
- Modify: `shell/claude.bash`
- Modify: `shell/claude.zsh`
- Modify: `tests/run.sh`
- Modify: `README.md` if behaviour text needs tightening

- [ ] **Step 1: Add tests for bash/zsh fresh-by-default**

Add tests near `=== fish wrapper: fresh by default ===`:

```bash
# Bash and zsh wrappers must match fish: fresh by default, resume only with opt-in.
tmpdir=$(mktemp -d)
mkdir -p "$tmpdir/.claude/projects/-repo"
cat > "$tmpdir/.claude/projects/-repo/session-redbot.jsonl" <<'EOF'
{"type":"custom-title","customTitle":"redbot"}
EOF

write_wrapper_tmux_stub() {
    local tmux_path="$1"
    cat > "$tmux_path" <<'EOF'
#!/usr/bin/env bash
case "$*" in
    *"#{window_name}"*) printf '%s\n' redbot ;;
    *"#{window_panes}"*) printf '%s\n' 1 ;;
    *"#{pane_index}"*) printf '%s\n' 1 ;;
    *) exit 1 ;;
esac
EOF
    chmod +x "$tmux_path"
}

mkdir -p "$tmpdir/bin" "$tmpdir/repo"
write_wrapper_tmux_stub "$tmpdir/bin/tmux"
cat > "$tmpdir/bin/claude" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$@"
EOF
chmod +x "$tmpdir/bin/claude"

bash_out=$(HOME="$tmpdir" TMUX=1 TMUX_PANE=%1 PATH="$tmpdir/bin:$PATH" bash -c "cd '$tmpdir/repo' && source '$PLUGIN_DIR/shell/claude.bash' && claude")
assert_eq "bash wrapper fresh by default" "--name
redbot" "$bash_out"

bash_resume_out=$(HOME="$tmpdir" TMUX=1 TMUX_PANE=%1 PATH="$tmpdir/bin:$PATH" bash -c "cd '$tmpdir/repo' && source '$PLUGIN_DIR/shell/claude.bash' && claude --tmux-resume")
assert_eq "bash wrapper opt-in resume" "--resume
session-redbot
--name
redbot" "$bash_resume_out"

if command -v zsh >/dev/null 2>&1; then
    zsh_out=$(HOME="$tmpdir" TMUX=1 TMUX_PANE=%1 PATH="$tmpdir/bin:$PATH" zsh -c "cd '$tmpdir/repo' && source '$PLUGIN_DIR/shell/claude.zsh' && claude")
    assert_eq "zsh wrapper fresh by default" "--name
redbot" "$zsh_out"
fi

rm -rf "$tmpdir"
unset -f write_wrapper_tmux_stub
```

- [ ] **Step 2: Run failing tests**

Run:

```bash
bash tests/run.sh
```

Expected: bash/zsh wrapper tests fail because current wrappers auto-resume without opt-in.

- [ ] **Step 3: Create shared Python lookup**

Create `scripts/claude-find-session.py`:

```python
#!/usr/bin/env python3
import json
import os
import sys


def main() -> int:
    if len(sys.argv) != 3:
        return 2
    project_dir, target = sys.argv[1], sys.argv[2]
    if not os.path.isdir(project_dir):
        return 1

    files = []
    for name in os.listdir(project_dir):
        if not name.endswith(".jsonl"):
            continue
        path = os.path.join(project_dir, name)
        try:
            files.append((os.path.getmtime(path), path, name))
        except OSError:
            continue
    files.sort(reverse=True)

    for _, path, name in files:
        try:
            with open(path) as fh:
                for line in fh:
                    line = line.strip()
                    if not line:
                        continue
                    try:
                        obj = json.loads(line)
                    except (json.JSONDecodeError, ValueError):
                        continue
                    if obj.get("type") == "custom-title":
                        if obj.get("customTitle") == target:
                            print(name[:-6])
                            return 0
                        break
        except OSError:
            continue
    return 1


if __name__ == "__main__":
    raise SystemExit(main())
```

- [ ] **Step 4: Create shared shell argv helper**

Create `scripts/claude-session-args.sh`:

```bash
#!/usr/bin/env bash
set -euo pipefail

[ -n "${TMUX:-}" ] || exit 0
[ -n "${TMUX_PANE:-}" ] || exit 0

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

tmux_resume=0
for arg in "$@"; do
    case "$arg" in
        --tmux-resume)
            tmux_resume=1
            ;;
        --name|--name=*|--resume|-r|--resume=*|--continue|-c|--continue=*|--print|-p)
            exit 0
            ;;
    esac
done

[ "${TMUX_CLAUDE_AUTO_RESUME:-}" = "1" ] && tmux_resume=1

wname=$(tmux display-message -p -t "$TMUX_PANE" '#{window_name}' 2>/dev/null || true)
pane_count=$(tmux display-message -p -t "$TMUX_PANE" '#{window_panes}' 2>/dev/null || true)
pane=$(tmux display-message -p -t "$TMUX_PANE" '#{pane_index}' 2>/dev/null || true)

case "$wname" in
    ""|fish|bash|zsh|sh|dash|tcsh|csh|ksh|nu|nushell|pwsh)
        sess=$(tmux display-message -p -t "$TMUX_PANE" '#{session_name}' 2>/dev/null || true)
        win=$(tmux display-message -p -t "$TMUX_PANE" '#{window_index}' 2>/dev/null || true)
        [ -n "$sess" ] && [ -n "$win" ] || exit 0
        wname="$sess:$win"
        ;;
esac

[ -n "$wname" ] || exit 0
name="$wname"
case "$pane_count" in
    ''|*[!0-9]*) ;;
    *)
        if [ "$pane_count" -gt 1 ] && [ -n "$pane" ]; then
            name="$wname.$pane"
        fi
        ;;
esac

name=$(printf '%s' "$name" | LC_ALL=C tr -c 'A-Za-z0-9_.:-' '-')

if [ "$tmux_resume" -eq 1 ]; then
    project_dir="$HOME/.claude/projects/$(pwd | tr '/.' '--')"
    sid=$(python3 "$SCRIPT_DIR/claude-find-session.py" "$project_dir" "$name" 2>/dev/null || true)
    if [ -n "$sid" ]; then
        printf '%s\n' --resume "$sid" --name "$name"
        exit 0
    fi
fi

printf '%s\n' --name "$name"
```

Run:

```bash
chmod +x scripts/claude-find-session.py scripts/claude-session-args.sh
```

- [ ] **Step 5: Refactor fish helper**

Change `shell/__tmux_claude_find_session.fish` to call the Python helper when available:

```fish
set -l plugin_dir "$TMUX_CLAUDE_PLUGIN_DIR"
test -z "$plugin_dir"; and set plugin_dir "$HOME/.config/tmux/plugins/tmux-claude"
set -l finder "$plugin_dir/scripts/claude-find-session.py"
if test -x "$finder"
    python3 "$finder" "$project_dir" "$target" 2>/dev/null
    return $status
end
```

Keep the existing inline Python fallback after this block.

- [ ] **Step 6: Refactor bash and zsh wrappers**

Update both wrappers so they:

1. Ignore and strip `--tmux-resume` from forwarded args.
2. Call `${TMUX_CLAUDE_PLUGIN_DIR:-$HOME/.config/tmux/plugins/tmux-claude}/scripts/claude-session-args.sh`.
3. Read one output line per argv word into `extra_args`.
4. Start fresh by default unless `--tmux-resume` or `TMUX_CLAUDE_AUTO_RESUME=1`.

Bash implementation inside `claude()`:

```bash
local extra_args=()
local pass_args=()
local plugin_dir="${TMUX_CLAUDE_PLUGIN_DIR:-$HOME/.config/tmux/plugins/tmux-claude}"
local helper="$plugin_dir/scripts/claude-session-args.sh"
local arg line

for arg in "$@"; do
    [ "$arg" = "--tmux-resume" ] && continue
    pass_args+=("$arg")
done

if [ -x "$helper" ]; then
    while IFS= read -r line || [ -n "$line" ]; do
        extra_args+=("$line")
    done < <("$helper" "$@")
fi

command claude "${extra_args[@]}" "${pass_args[@]}"
```

Use the same shape in zsh with zsh-compatible array syntax.

- [ ] **Step 7: Run tests**

Run:

```bash
bash tests/run.sh
```

Expected: all tests pass.

- [ ] **Step 8: Commit**

```bash
git add scripts/claude-find-session.py scripts/claude-session-args.sh shell tests/run.sh README.md
git commit -m "fix(shell): make stable naming resume opt-in across shells"
```

---

### Task 6: Test Harness Locality

**Files:**
- Create: `tests/lib/assertions.sh`
- Create: `tests/lib/fixtures.sh`
- Modify: `tests/run.sh`

- [ ] **Step 1: Extract assertions**

Create `tests/lib/assertions.sh`:

```bash
#!/usr/bin/env bash

red() { printf '\033[31m%s\033[0m\n' "$1"; }
green() { printf '\033[32m%s\033[0m\n' "$1"; }

assert_eq() {
    local name="$1" expected="$2" actual="$3"
    if [ "$expected" = "$actual" ]; then
        green "  PASS: $name"
        pass=$((pass + 1))
    else
        red "  FAIL: $name"
        printf '    expected: %s\n' "$expected"
        printf '    actual:   %s\n' "$actual"
        fail=$((fail + 1))
    fi
}

assert_contains() {
    local name="$1" needle="$2" haystack="$3"
    if printf '%s' "$haystack" | grep -Fq -- "$needle"; then
        green "  PASS: $name"
        pass=$((pass + 1))
    else
        red "  FAIL: $name"
        printf '    missing: %s\n' "$needle"
        printf '    in:      %s\n' "$haystack"
        fail=$((fail + 1))
    fi
}

assert_not_contains() {
    local name="$1" needle="$2" haystack="$3"
    if printf '%s' "$haystack" | grep -Fq -- "$needle"; then
        red "  FAIL: $name"
        printf '    unexpected: %s\n' "$needle"
        printf '    in:         %s\n' "$haystack"
        fail=$((fail + 1))
    else
        green "  PASS: $name"
        pass=$((pass + 1))
    fi
}
```

- [ ] **Step 2: Source assertions in `tests/run.sh`**

At the top of `tests/run.sh`, after `PLUGIN_DIR=...`, add:

```bash
# shellcheck source=tests/lib/assertions.sh
. "$PLUGIN_DIR/tests/lib/assertions.sh"
```

Delete the duplicate `red`, `green`, `assert_eq`, `assert_contains`, and `assert_not_contains` definitions from `tests/run.sh`.

- [ ] **Step 3: Extract fixture helpers only if no behaviour changes**

If Task 2 or Task 3 added more fixture helpers, create `tests/lib/fixtures.sh` and move only helpers that are used by at least two test sections. Do not move single-use stubs. Source it from `tests/run.sh`:

```bash
# shellcheck source=tests/lib/fixtures.sh
[ -f "$PLUGIN_DIR/tests/lib/fixtures.sh" ] && . "$PLUGIN_DIR/tests/lib/fixtures.sh"
```

- [ ] **Step 4: Run tests**

Run:

```bash
bash tests/run.sh
```

Expected: all tests pass.

- [ ] **Step 5: Commit**

```bash
git add tests/run.sh tests/lib
git commit -m "test: extract shared test assertions"
```

---

### Task 7: Final Verification and Dry Runs

**Files:**
- No required code files.
- Update docs only if verification reveals stale instructions.

- [ ] **Step 1: Run full suite**

Run:

```bash
bash tests/run.sh
```

Expected: `ALL TESTS PASSED`.

- [ ] **Step 2: Run shell syntax checks**

Run:

```bash
bash -n scripts/*.sh lib/*.sh adapters/*.sh shell/claude.bash
zsh -n shell/claude.zsh
fish -n shell/*.fish
python3 -m py_compile scripts/claude-find-session.py
```

Expected: all commands exit 0.

- [ ] **Step 3: Simulated save + restore dry-run without mutating real pane map**

Run this exact command from the worktree:

```bash
tmpdir=$(mktemp -d)
mkdir -p "$tmpdir/bin" "$tmpdir/resurrect"
real_tmux=$(command -v tmux)
cat > "$tmpdir/bin/tmux" <<EOF
#!/usr/bin/env bash
if [ "\$1" = "show-option" ] && [ "\${*: -1}" = "@resurrect-dir" ]; then
  printf '%s\n' "$tmpdir/resurrect"
  exit 0
fi
exec "$real_tmux" "\$@"
EOF
chmod +x "$tmpdir/bin/tmux"
PATH="$tmpdir/bin:$PATH" bash scripts/session-save.sh
PATH="$tmpdir/bin:$PATH" TMUX_CLAUDE_RESTORE_BOOT_DELAY=0 bash scripts/session-restore.sh --dry-run
```

Expected: save exits 0, restore exits 0, and dry-run summary has no `window_mismatch`, no invalid SID skips, and no shell quoting errors.

- [ ] **Step 4: Real current snapshot dry-run**

Run:

```bash
TMUX_CLAUDE_RESTORE_BOOT_DELAY=0 bash scripts/session-restore.sh --dry-run
```

Expected: exits 0. Any `picker` rows are acceptable only if `scripts/session-audit.sh` reports them as live panes lacking UUID stamps.

- [ ] **Step 5: Audit live panes**

Run:

```bash
bash scripts/session-audit.sh
```

Expected: exits 0 if all live Claude/Codex panes have UUID restore readiness; exits 1 only for known picker panes.

- [ ] **Step 6: Commit verification-only docs updates if any**

If docs changed:

```bash
git add README.md CONTEXT.md docs/adr
git commit -m "docs: align verification instructions"
```

If no docs changed, do not create an empty commit.

---

## Self-Review

- Spec coverage: all six architecture candidates are covered by tasks: restore readiness, restore plan, SessionStart hook Module, stable naming helper consistency, test harness locality, and architecture docs.
- Placeholder scan: no banned placeholder terms or unspecified test step remains. Task 6 intentionally makes fixture extraction conditional to avoid inventing a shallow Module for single-use stubs.
- Type consistency: new shell function names use `restore_readiness_*`, `session_hook_*`, and `restore_plan_*` consistently.
- Testing: every implementation task starts with failing tests, then full `bash tests/run.sh`, then a commit.

## Execution Choice

Plan complete and saved to `docs/superpowers/plans/2026-06-25-tmux-claude-architecture-deepening.md`. The requested execution mode is Subagent-Driven, so continue with `superpowers:subagent-driven-development` task-by-task.
