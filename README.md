# tmux-claude

tmux plugin for [Claude Code](https://docs.anthropic.com/en/docs/claude-code) and [Codex](https://openai.com/index/introducing-codex/) session save/restore.

## Requirements

- tmux >= 3.2
- [TPM](https://github.com/tmux-plugins/tpm)
- [tmux-resurrect](https://github.com/tmux-plugins/tmux-resurrect)
- [Claude Code](https://docs.anthropic.com/en/docs/claude-code) CLI
- SessionStart hooks that write pane variables (see below)

## Install

```tmux
set -g @plugin 'bezlant/tmux-claude'
```

`prefix + I` to install.

### SessionStart hooks (required)

The plugin reads `@claude_session_id` and `@codex_session_id` tmux pane variables to map sessions. These are set by SessionStart hooks.

**Claude Code** (`~/.claude/settings.json`):
```json
{
  "hooks": {
    "SessionStart": [{
      "hooks": [{
        "type": "command",
        "command": "bash ~/.claude/hooks/tmux-session-tracker.sh"
      }]
    }]
  }
}
```

**Codex** (`~/.codex/hooks.json`):
```json
{
  "hooks": {
    "SessionStart": [{
      "hooks": [{
        "type": "command",
        "command": "bash ~/.config/codex/bin/tmux-session-tracker.sh"
      }]
    }]
  }
}
```

Each hook reads `session_id` and `cwd` from the JSON stdin, writes them to tmux pane variables, and clears the other tool's variables (handles pane reuse).

### Shell wrapper (optional)

Tags new Claude sessions with tmux pane coordinates for the session picker:

```sh
# Fish
cp ~/.config/tmux/plugins/tmux-claude/shell/__tmux_claude_session_args.fish ~/.config/fish/functions/
```

## Features

### Session save/restore

Automatically saves which panes run Claude/Codex/nvim/just and restores them after reboot.

**How it works:**

1. `prefix + S` (resurrect save) triggers the post-save hook which records all pane→session mappings
2. `prefix + R` (resurrect restore) triggers the post-restore hook which sends resume commands to each pane

**Mapping format:** `~/.config/tmux/resurrect/claude-panes.txt` uses `snapshot v2`, an eight-column TSV format:

```text
target    tool    sid    sid_kind    cwd    original_cwd    wname    flags
```

Legacy pipe-delimited snapshots are still readable during restore.

Restore writes `restore.log` beside the snapshot with `BEGIN`, `OK`, `WARN`, `SKIP`, and `END` lines so failed or degraded panes can be inspected after restore.

**Tools supported:**
- `claude` → `ccy --resume <uuid>` (direct resume, no picker)
- `codex` → `cxy resume <uuid>` (direct resume when hook has fired)
- `nvim` → `nvim`
- `just` → `just <recipe>`

**Safety:**
- Atomic save (temp file + mv) — partial saves can't corrupt the mapping
- Zero-pane enumeration preserves the previous mapping instead of clobbering it
- Hooks clear stale pane variables when a pane switches between Claude and Codex

**Manual usage:**

```bash
# Save current state
bash ~/.config/tmux/plugins/tmux-claude/scripts/session-save.sh

# Preview restore commands
bash ~/.config/tmux/plugins/tmux-claude/scripts/session-restore.sh --dry-run

# Restore
bash ~/.config/tmux/plugins/tmux-claude/scripts/session-restore.sh
```

### Post-reboot attach helper

For fish users, the plugin can install a `tres` helper:

```fish
tres
```

`tres` starts a temporary bootstrap tmux server when needed, reads the saved tmux-resurrect session name from `~/.config/tmux/resurrect/last`, waits for the restored window count to stabilize, then attaches to that restored session. It falls back to session `0` when no snapshot is available.

If `@resurrect-dir` is set, `tres` reads `last` from that configured directory. If you already have a custom `~/.config/fish/functions/tres.fish`, the plugin will not overwrite it; copy `shell/tres.fish` manually if you want the plugin helper.

**Prunes old resurrect files** — keeps the last 20 saves by default:

```tmux
set-environment -g TMUX_CLAUDE_MAX_SAVES 30
```

## Configuration

| Option | Default | Description |
|--------|---------|-------------|
| `@tmux-claude-auto-install-wrapper` | `on` | Set to `off` to skip shell wrapper install |
| `TMUX_CLAUDE_MAX_SAVES` | `20` | Max resurrect save files to keep |

## License

MIT
