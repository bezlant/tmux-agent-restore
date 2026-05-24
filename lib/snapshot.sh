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

snapshot_write_row() {
    local target="$1"
    local tool="$2"
    local sid="$3"
    local sid_kind="$4"
    local cwd="$5"
    local original_cwd="$6"
    local wname="$7"
    local flags="$8"

    local enc_target enc_tool enc_sid enc_sid_kind
    local enc_cwd enc_original_cwd enc_wname enc_flags
    enc_target=$(tsv_encode "$target")
    enc_tool=$(tsv_encode "$tool")
    enc_sid=$(tsv_encode "$sid")
    enc_sid_kind=$(tsv_encode "$sid_kind")
    enc_cwd=$(tsv_encode "$cwd")
    enc_original_cwd=$(tsv_encode "$original_cwd")
    enc_wname=$(tsv_encode "$wname")

    local field_was_encoded=0
    if [ "$enc_target" != "$target" ] ||
        [ "$enc_tool" != "$tool" ] ||
        [ "$enc_sid" != "$sid" ] ||
        [ "$enc_sid_kind" != "$sid_kind" ] ||
        [ "$enc_cwd" != "$cwd" ] ||
        [ "$enc_original_cwd" != "$original_cwd" ] ||
        [ "$enc_wname" != "$wname" ]; then
        field_was_encoded=1
    fi

    local composed_flags=""
    local has_field_encoded=0
    local part
    local remaining_flags="$flags"
    while [ -n "$remaining_flags" ]; do
        if [[ "$remaining_flags" == *";"* ]]; then
            part="${remaining_flags%%;*}"
            remaining_flags="${remaining_flags#*;}"
        else
            part="$remaining_flags"
            remaining_flags=""
        fi

        if [ "$part" = "field_encoded" ]; then
            [ "$has_field_encoded" -eq 1 ] && continue
            has_field_encoded=1
        fi

        if [ -n "$composed_flags" ]; then
            composed_flags="${composed_flags};${part}"
        else
            composed_flags="$part"
        fi
    done

    if [ "$field_was_encoded" -eq 1 ] && [ "$has_field_encoded" -eq 0 ]; then
        if [ -n "$composed_flags" ]; then
            composed_flags="${composed_flags};field_encoded"
        else
            composed_flags="field_encoded"
        fi
    fi

    enc_flags=$(tsv_encode "$composed_flags")

    printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
        "$enc_target" \
        "$enc_tool" \
        "$enc_sid" \
        "$enc_sid_kind" \
        "$enc_cwd" \
        "$enc_original_cwd" \
        "$enc_wname" \
        "$enc_flags"
}
