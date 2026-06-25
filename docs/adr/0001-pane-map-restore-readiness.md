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
- This branch must make save and audit share restore-readiness rules to avoid drift.
