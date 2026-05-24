#!/usr/bin/env bash
# tmux-claude: versioned snapshot reader/writer.
#
# Snapshot format v2 — see
# docs/superpowers/specs/2026-05-22-tmux-claude-restore-architecture.md
# (Layer 2).
#
# 8 TAB-separated columns per row, fields percent-encoded for
# \t \n \r %. Header is two lines starting with `#`.
#
# This library is intentionally side-effect-free at source time.
# Sourcing scripts should call snapshot_* functions explicitly.

SNAPSHOT_VERSION=2

# Internal: source tsv.sh from the same directory if not already loaded.
if ! declare -F tsv_encode >/dev/null 2>&1; then
    _snapshot_lib_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    # shellcheck source=tsv.sh
    . "$_snapshot_lib_dir/tsv.sh"
    unset _snapshot_lib_dir
fi

# snapshot_log <level> <message>
# Default: write to stderr. Chunks 3+ will override by sourcing a
# logger lib BEFORE snapshot.sh.
if ! declare -F snapshot_log >/dev/null 2>&1; then
    snapshot_log() {
        printf '%s [snapshot] %s\n' "$1" "$2" >&2
    }
fi

snapshot_write_header() {
    printf '# tmux-claude snapshot v%s\n' "$SNAPSHOT_VERSION"
    printf '# fields: target\ttool\tsid\tsid_kind\tcwd\toriginal_cwd\twname\tflags\n'
}
