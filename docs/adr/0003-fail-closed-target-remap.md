# ADR 0003: Fail closed when restore target remap is missing or ambiguous

## Status

Accepted

## Context

After crash/restore, tmux numeric targets can drift. A stale pane map may say `0:3.1` while the restored layout now has the saved window under another index. Typing into the stale numeric target can restore the wrong session into the wrong pane.

## Decision

Restore first checks whether an inspectable saved numeric target still has the saved window name. If the inspectable target contradicts the saved window name, restore remaps only when exactly one live window in the same session has the saved window name and the saved pane index. The intended restore-plan invariant is that contradictory inspectable targets with zero matches or multiple matches are skipped with `window_mismatch` rather than guessed.

## Consequences

- Some panes may be skipped instead of guessed.
- Dry-run restore is the recommended way to inspect remaps before live restore.
- Duplicate window names are intentionally treated as unsafe.
