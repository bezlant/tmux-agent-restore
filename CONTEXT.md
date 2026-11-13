# tmux-agent-restore Context

## Domain Terms

**Stable naming** is the Claude wrapper behaviour that derives a Claude session name from the tmux window name and pane index. Single-pane windows use the window name. Multi-pane windows append `.<pane_index>`.

**SessionStart stamp** is the pane-local tmux state written by Claude/Codex hooks when an agent session starts. A stamp includes the tool session id and cwd supplied by the agent hook, and may include the detected live agent pid when detection succeeds.

**Pane map** is `claude-panes.txt` in the configured tmux-resurrect directory. It maps tmux pane targets to restorable tools and session identifiers using snapshot v2 TSV rows.

**Snapshot** is the versioned pane map format. Snapshot v2 has eight fields: `target`, `tool`, `sid`, `sid_kind`, `cwd`, `original_cwd`, `wname`, and `flags`.

**Restore readiness** is the live-pane state after adapter detection, UUID validation, cwd collapsing, and flag assignment.

**Restore plan** is the per-row decision made during restore: skip, warn, or execute a shell command in a resolved tmux pane. A restore plan must fail closed when the saved target cannot be mapped safely to the live layout.

**Picker** is a degraded Claude/Codex restore mode where the tool is relaunched without a UUID because the exact session id is unavailable or unsafe.

## Invariants

- Save must never clobber an existing pane map with an empty enumeration.
- Restore must never type a command into a pane whose live window name contradicts the saved window name unless exactly one safe remap exists.
- Claude and Codex SessionStart stamps may coexist in one pane; the saver chooses the live foreground tool instead of clearing the other tool's stamp.
- Save and dry-run restore are the verification surfaces for restore-readiness behaviour.
- Stable naming always starts a fresh session; resuming is done by restore or by passing `--resume` explicitly.
