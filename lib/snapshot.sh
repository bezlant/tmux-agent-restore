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

snapshot_detect_version() {
    local file="$1"

    [ -f "$file" ] || { echo 0; return; }
    [ -s "$file" ] || { echo 0; return; }

    local line
    while IFS= read -r line || [ -n "$line" ]; do
        if [[ "$line" == "# tmux-claude snapshot v"* ]]; then
            echo "${line##*v}"
            return
        fi
        [[ "$line" == \#* ]] && continue
        case "$line" in
            *[![:space:]]*) ;;
            *) continue ;;
        esac
        if [[ "$line" == *"|"* ]] && [[ "$line" != *$'\t'* ]]; then
            echo 1
            return
        fi
        echo -1
        return
    done < "$file"

    echo 0
}

# promote_v1_row <tool> <sid>
# Emits "<sid> <sid_kind>". Consumers must split on the LAST space:
# sid_kind is the final token, and sid may contain spaces for just recipes.
promote_v1_row() {
    local tool="$1"
    local sid="$2"

    case "$tool" in
        claude|codex)
            if [ "$sid" = "picker" ]; then
                printf '%s %s\n' "picker" "picker"
                return
            fi

            local normalized_sid
            normalized_sid=$(printf '%s' "$sid" | tr 'A-F' 'a-f')
            if [[ "$normalized_sid" =~ ^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$ ]]; then
                printf '%s %s\n' "$normalized_sid" "uuid"
                return
            fi
            ;;
        just)
            if [ -n "$sid" ]; then
                printf '%s %s\n' "$sid" "recipe"
                return
            fi
            ;;
    esac

    printf '%s %s\n' "-" "none"
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

# snapshot_read <file>
# Emits v2 rows on stdout, one per line, EXACTLY 8 TAB-separated
# fields, fields percent-encoded. Auto-detects v1 (legacy pipe format)
# and promotes via promote_v1_row. Logs LEGACY to stderr.
# Aborts with non-zero exit + ERROR log if version is unknown (-1 or >=3).
snapshot_read() {
    local file="$1"
    local version
    version=$(snapshot_detect_version "$file")

    case "$version" in
        0)
            return 0  # empty/missing file = empty snapshot
            ;;
        1)
            _snapshot_read_v1 "$file"
            ;;
        2)
            _snapshot_read_v2 "$file"
            ;;
        -1)
            snapshot_log ERROR "unrecognized snapshot format in $file (refusing to parse)"
            return 1
            ;;
        *)
            snapshot_log ERROR "unknown snapshot version $version in $file"
            return 1
            ;;
    esac
}

# Internal: read v2 rows, skipping comment + blank lines.
# Field counting and truncation are delegated to awk, which preserves
# trailing empty fields with -F'\t' (bash command substitution does
# NOT, hence the use of awk here instead of snapshot_split_row).
# Rows with fewer than 8 fields are SKIPPED with a WARN.
# Forward-compat columns 9+ are silently dropped per spec.
# Fields remain percent-encoded — consumers decode just-in-time.
_snapshot_read_v2() {
    local file="$1" line lineno=0
    while IFS= read -r line || [ -n "$line" ]; do
        lineno=$((lineno + 1))
        [[ "$line" == \#* ]] && continue
        [ -z "$line" ] && continue

        # Count fields directly via awk. `-F'\t'` preserves trailing
        # empty fields in NF.
        local nf
        nf=$(printf '%s' "$line" | awk -F'\t' '{print NF}')

        if [ "$nf" -lt 8 ]; then
            snapshot_log WARN "malformed v2 row at line $lineno of $file (got $nf fields, need 8); skipping"
            continue
        fi

        # Truncate to first 8 fields via awk. `BEGIN{OFS="\t"}` +
        # `print $1,$2,...,$8` preserves empty fields in the output.
        # Embed in printf because awk's output adds an LF.
        printf '%s' "$line" | awk -F'\t' 'BEGIN{OFS="\t"} {print $1,$2,$3,$4,$5,$6,$7,$8}'
    done < "$file"
}

# snapshot_split_row <line>
# Splits a TAB-separated line into fields, ONE PER LINE on stdout.
# PRESERVES empty fields (bash's `IFS=$'\t' read` does NOT — tab is
# IFS-whitespace and consecutive tabs collapse to one delimiter).
# Consumers MUST use this helper instead of `IFS=$'\t' read` to parse
# rows from snapshot_read.
#
# Empirical verification (macOS bash 3.2):
#   $ printf 'a\tb\t\tc\td' | (IFS=$'\t' read -r a b c d e; echo "[$c]")
#   [c]                          ← empty field collapsed; c shifted in
#   $ snapshot_split_row "$(printf 'a\tb\t\tc\td')"
#   a
#   b
#                                ← empty preserved correctly
#   c
#   d
snapshot_split_row() {
    # CRITICAL: keep these on separate `local` statements. Bash
    # evaluates ALL RHS expressions of a single `local` command using
    # the OUTER scope, so writing
    #     local line="$1" len="${#line}"
    # makes `len` read the outer (often empty/unset) `line`, giving
    # len=0 and silently emitting an empty field. Empirically tested.
    local line="$1"
    local field=""
    local len="${#line}"
    local i char
    for ((i = 0; i < len; i++)); do
        char="${line:i:1}"
        if [ "$char" = $'\t' ]; then
            printf '%s\n' "$field"
            field=""
        else
            field+="$char"
        fi
    done
    printf '%s\n' "$field"
}

# WARNING for consumers: do NOT use command substitution to capture
# this function's output, e.g.
#     fields=$(snapshot_split_row "$row")          # WRONG
# Bash command substitution STRIPS trailing newlines, so a row whose
# last field is empty (e.g. trailing flags="") will appear short by
# one. Use process substitution into a `while read` loop instead:
#     while IFS= read -r field; do ...
#     done < <(snapshot_split_row "$row")          # CORRECT
# Process substitution preserves the full byte stream.
