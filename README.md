# tmux-agent-restore

Restores [Claude Code](https://docs.anthropic.com/en/docs/claude-code) and [Codex](https://openai.com/index/introducing-codex/) agent sessions after a tmux server restart, on top of [tmux-resurrect](https://github.com/tmux-plugins/tmux-resurrect). Formerly `tmux-claude`.

Two features:

1. **Save/restore** — after a reboot, each pane gets its agent back in the same conversation (`nvim` and `just` panes are relaunched too)
2. **Stable naming** — starting Claude in a pane creates a fresh session named after its tmux window

## Requirements

- tmux >= 3.2
- [TPM](https://github.com/tmux-plugins/tpm)
- [tmux-resurrect](https://github.com/tmux-plugins/tmux-resurrect) (for save/restore)
- python3 (used by the session hooks)

## Install

```tmux
set -g @plugin 'bezlant/tmux-agent-restore'
```

`prefix + I` to install.

## Setup

### 1. SessionStart hooks (required for save/restore)

These hooks write session IDs to tmux pane variables so the plugin can map panes to sessions.

**Claude Code** — add to `~/.claude/settings.json`:

```json
{
  "hooks": {
    "SessionStart": [{
      "hooks": [{
        "type": "command",
        "command": "bash ~/.config/tmux/plugins/tmux-agent-restore/scripts/claude-session-hook.sh"
      }]
    }]
  }
}
```

**Codex** — add to `~/.codex/hooks.json`:

```json
{
  "hooks": {
    "SessionStart": [{
      "hooks": [{
        "type": "command",
        "command": "bash ~/.config/tmux/plugins/tmux-agent-restore/scripts/codex-session-hook.sh"
      }]
    }]
  }
}
```

### 2. Shell wrapper (stable naming)

The plugin auto-installs the fish wrapper on `prefix + I`. Only fish is supported.

To disable fish auto-install:

```tmux
set -g @tmux-agent-restore-auto-install-wrapper off
```

## Features

### Stable Claude Naming

Each pane gets a stable session name derived from its tmux window name:

- Single-pane window `redbot` → session name `redbot`
- Multi-pane window `redbot`, pane 2 → session name `redbot.2`

When you type `claude` in a pane, the wrapper:

1. Computes the session name from `#{window_name}` and `#{pane_index}`
2. Passes `--name <name>`
3. Starts a fresh session with that name

**Bypass**: passing `--resume`, `--continue`, `--name`, or `-p` explicitly skips the wrapper logic.

### Save/restore

Survives tmux server restart (reboot). Requires tmux-resurrect and SessionStart hooks.

**How it works:**

1. `prefix + S` (resurrect save) triggers a post-save hook that records pane→session mappings
2. `prefix + R` (resurrect restore) triggers a post-restore hook that sends resume commands to each pane

**Mapping format:** `claude-panes.txt` lives in the configured `@resurrect-dir` and uses `snapshot v2`, an eight-column TSV format:

```text
target    tool    sid    sid_kind    cwd    original_cwd    wname    flags
```

If `@resurrect-dir` is not set, save/restore use `~/.tmux/resurrect`.

Restore writes `restore.log` beside the snapshot with `BEGIN`, `OK`, `WARN`, `SKIP`, and `END` lines so failed or degraded panes can be inspected after restore. A pane that is already running something is skipped as `pane_busy`; a pane whose shell does not answer within 30 seconds is skipped as `prompt_wait_timeout`.

**Tools restored:**

- `claude` → resumes with session UUID
- `codex` → resumes with session UUID
- `nvim` → reopens nvim
- `just` → re-runs the recipe

**Safety:**

- Atomic save (temp file + mv) — partial saves can't corrupt the mapping
- Zero-pane enumeration preserves the previous mapping instead of clobbering
- Hooks stamp each tool's own session ID and agent PID and never clear the other tool's variables, so a pane that hosts both Claude and Codex keeps both IDs; the saver disambiguates by the pane's foreground command and only uses a variable when a matching live agent exists. (Clearing the other tool's vars used to wipe a live session whenever the foreground briefly flipped, degrading restore to a picker.)
- Stale PIDs are tolerated when the saved UUID still has a valid local Claude/Codex artifact; those rows are marked `pid_mismatch_trusted`
- Concurrent restore runs are skipped with `restore_already_running` in `restore.log`

**Manual usage:**

```bash
# Save current state
bash ~/.config/tmux/plugins/tmux-agent-restore/scripts/session-save.sh

# Preview what restore would do
bash ~/.config/tmux/plugins/tmux-agent-restore/scripts/session-restore.sh --dry-run

# Restore
bash ~/.config/tmux/plugins/tmux-agent-restore/scripts/session-restore.sh
```

## Configuration

| Option | Default | Description |
|--------|---------|-------------|
| `@tmux-agent-restore-auto-install-wrapper` | `on` | Auto-install fish wrapper to `~/.config/fish/functions/` |
| `TMUX_AGENT_RESTORE_MAX_SAVES` | `20` | Max resurrect save files to keep |

Override max saves:

```tmux
set-environment -g TMUX_AGENT_RESTORE_MAX_SAVES 30
```

## Architecture Notes

The main domain terms and invariants live in `CONTEXT.md`. Load-bearing decisions are recorded in `docs/adr/` so future restore changes do not re-litigate coexisting tool stamps, pane map ownership, or fail-closed target remapping.

## License

MIT
