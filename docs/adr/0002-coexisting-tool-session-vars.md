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
