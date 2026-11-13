# tmux-claude

tmux plugin for [Claude Code](https://docs.anthropic.com/en/docs/claude-code) and [Codex](https://openai.com/index/introducing-codex/) session management.

Two features:

1. **Stable naming** — starting Claude in a pane creates a fresh session with a tmux-derived name, with explicit opt-in resume
2. **Save/restore** — survives tmux server restart (reboot) via tmux-resurrect integration

## Requirements

- tmux >= 3.2
- [TPM](https://github.com/tmux-plugins/tpm)
- [tmux-resurrect](https://github.com/tmux-plugins/tmux-resurrect) (for save/restore)
- python3 (for session lookup)

## Install

```tmux
set -g @plugin 'bezlant/tmux-claude'
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
        "command": "bash ~/.config/tmux/plugins/tmux-claude/scripts/claude-session-hook.sh"
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
        "command": "bash ~/.config/tmux/plugins/tmux-claude/scripts/codex-session-hook.sh"
      }]
    }]
  }
}
```

### 2. Shell wrapper (stable naming)

The plugin auto-installs the fish wrapper on `prefix + I`. For other shells:

```sh
# Bash (add to ~/.bashrc)
source ~/.config/tmux/plugins/tmux-claude/shell/claude.bash

# Zsh (add to ~/.zshrc)
source ~/.config/tmux/plugins/tmux-claude/shell/claude.zsh
```

To disable fish auto-install:

```tmux
set -g @tmux-claude-auto-install-wrapper off
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

To opt into tmux-name based resume, run `claude --tmux-resume` or set `TMUX_CLAUDE_AUTO_RESUME=1`. In that mode, the wrapper scans `~/.claude/projects/<encoded-path>/*.jsonl` for a session whose `customTitle` matches and passes `--resume <uuid> --name <name>` when it finds one.

**Bypass**: passing `--resume`, `--continue`, `--name`, or `-p` explicitly skips the wrapper logic.

**`/clear` behavior**: `/clear` keeps the same session ID, but a plain `claude` launch is fresh by default. Use `claude --tmux-resume` only when you intentionally want the named cleared session back.

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

Restore writes `restore.log` beside the snapshot with `BEGIN`, `OK`, `WARN`, `SKIP`, and `END` lines so failed or degraded panes can be inspected after restore.

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
bash ~/.config/tmux/plugins/tmux-claude/scripts/session-save.sh

# Preview what restore would do
bash ~/.config/tmux/plugins/tmux-claude/scripts/session-restore.sh --dry-run

# Audit every live tmux pane for restore readiness
bash ~/.config/tmux/plugins/tmux-claude/scripts/session-audit.sh

# Restore
bash ~/.config/tmux/plugins/tmux-claude/scripts/session-restore.sh
```

`session-audit.sh` exits non-zero when a live Claude/Codex pane would only restore as a picker or has an invalid UUID artifact.

### Post-reboot attach helper

For fish users, the plugin can install a `tres` helper:

```fish
tres
```

`tres` starts a temporary bootstrap tmux server when needed, reads the saved tmux-resurrect session name from `~/.config/tmux/resurrect/last`, waits for the restored window count to stabilize, then attaches to that restored session. It falls back to session `0` when no snapshot is available.

If `@resurrect-dir` is set, `tres` reads `last` from that configured directory. If you already have a custom `~/.config/fish/functions/tres.fish`, the plugin will not overwrite it; copy `shell/tres.fish` manually if you want the plugin helper.

## Configuration

| Option | Default | Description |
|--------|---------|-------------|
| `@tmux-claude-auto-install-wrapper` | `on` | Auto-install fish wrapper to `~/.config/fish/functions/` |
| `TMUX_CLAUDE_MAX_SAVES` | `20` | Max resurrect save files to keep |

Override max saves:

```tmux
set-environment -g TMUX_CLAUDE_MAX_SAVES 30
```

## How it works (internals)

Claude Code stores sessions as JSONL files in `~/.claude/projects/<encoded-path>/`. The path is encoded by replacing `/` and `.` with `-` (e.g., `/Users/foo/my.project` → `-Users-foo-my-project`).

Each JSONL file starts with a `{"type":"custom-title","customTitle":"..."}` entry set at creation time. The optional `--tmux-resume` lookup scans these files (sorted newest-first by mtime) and returns the first UUID whose `customTitle` matches the computed pane name.

This avoids:

- `--continue` (resumes most recent session in the directory regardless of name — causes cross-pane hijacking)
- Matching on `agentName` (can be overwritten by previous `--name` flags, leaving contaminated metadata)

## Architecture Notes

The main domain terms and invariants live in `CONTEXT.md`. Load-bearing decisions are recorded in `docs/adr/` so future restore changes do not re-litigate coexisting tool stamps, pane map ownership, or fail-closed target remapping.

## License

MIT
