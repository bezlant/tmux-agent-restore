#!/usr/bin/env bash
# tmux-claude: live pane restore-readiness rules shared by save and audit.

if ! declare -F adapters_list >/dev/null 2>&1; then
    _readiness_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
    # shellcheck source=adapters.sh
    . "$_readiness_dir/lib/adapters.sh"
    unset _readiness_dir
fi

if [ -z "${TMUX_CLAUDE_ADAPTERS:-}" ] && declare -F adapters_load >/dev/null 2>&1; then
    _readiness_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
    adapters_load "$_readiness_dir"
    unset _readiness_dir
fi

if ! declare -F tsv_encode >/dev/null 2>&1; then
    _readiness_lib_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    # shellcheck source=tsv.sh
    . "$_readiness_lib_dir/tsv.sh"
    unset _readiness_lib_dir
fi

restore_readiness_clear() {
    RESTORE_READY_TARGET=""
    RESTORE_READY_TOOL=""
    RESTORE_READY_SID=""
    RESTORE_READY_SID_KIND=""
    RESTORE_READY_CWD=""
    RESTORE_READY_ORIGINAL_CWD=""
    RESTORE_READY_WNAME=""
    RESTORE_READY_FLAGS=""
}

restore_readiness_add_flag() {
    local current="$1"
    local flag="$2"

    case ";$current;" in
        *";$flag;"*) printf '%s\n' "$current"; return ;;
    esac

    if [ -n "$current" ]; then
        printf '%s;%s\n' "$current" "$flag"
    else
        printf '%s\n' "$flag"
    fi
}

restore_readiness_flag_has() {
    local flags="$1"
    local flag="$2"

    case ";$flags;" in
        *";$flag;"*) return 0 ;;
        *) return 1 ;;
    esac
}

restore_readiness_field() {
    local row="$1"
    local field="$2"
    printf '%s\n' "$row" | awk -F '\t' -v field="$field" 'NR == 1 { print $field }'
}

restore_readiness_collapse_cwd() {
    local cwd="$1"
    local parent

    [ -n "$cwd" ] || return 1
    while [ "$cwd" != "/" ] && [ ! -d "$cwd" ]; do
        case "$cwd" in
            */*)
                parent="${cwd%/*}"
                [ "$parent" != "$cwd" ] || parent="/"
                [ -n "$parent" ] || parent="/"
                cwd="$parent"
                ;;
            *)
                cwd="/"
                ;;
        esac
    done
    [ -d "$cwd" ] || return 1
    printf '%s\n' "$cwd"
}

restore_readiness_adapter_exists() {
    local wanted="$1"
    local adapter
    for adapter in $(adapters_list); do
        [ "$adapter" = "$wanted" ] && return 0
    done
    return 1
}

restore_readiness_adapter_hint() {
    local target="$1"
    local cmd adapter
    cmd=$(tmux display-message -p -t "$target" '#{pane_current_command}' 2>/dev/null || true)
    case "$cmd" in
        vim|nvim) adapter="nvim" ;;
        *codex*|*Codex*|*CODEX*) adapter="codex" ;;
        *claude*|*Claude*|*CLAUDE*) adapter="claude" ;;
        *) adapter="$cmd" ;;
    esac
    [ -n "$adapter" ] || return 1
    restore_readiness_adapter_exists "$adapter" || return 1
    printf '%s\n' "$adapter"
}

restore_readiness_detect_row() {
    local target="$1"
    local preferred_adapter detect_fn detect_row adapter

    preferred_adapter=$(restore_readiness_adapter_hint "$target" || true)
    if [ -n "$preferred_adapter" ]; then
        detect_fn="${preferred_adapter}_detect"
        if declare -F "$detect_fn" >/dev/null 2>&1 &&
            detect_row=$("$detect_fn" "$target" 2>/dev/null); then
            [ -n "$detect_row" ] && { printf '%s\n' "$detect_row"; return 0; }
        fi
    fi

    for adapter in $(adapters_list); do
        [ "$adapter" = "$preferred_adapter" ] && continue
        detect_fn="${adapter}_detect"
        if declare -F "$detect_fn" >/dev/null 2>&1 &&
            detect_row=$("$detect_fn" "$target" 2>/dev/null); then
            [ -n "$detect_row" ] && { printf '%s\n' "$detect_row"; return 0; }
        fi
    done

    return 1
}

restore_readiness_detect_flags() {
    local row="$1"
    printf '%s\n' "$row" | awk -F '\t' '
        NR == 1 {
            for (i = 5; i <= NF; i++) {
                if ($i ~ /(^|;)(pid_mismatch_trusted|sid_invalid|cwd_collapsed|field_encoded)(;|$)/) {
                    if (flags != "") {
                        flags = flags ";" $i
                    } else {
                        flags = $i
                    }
                }
            }
            print flags
        }'
}

restore_readiness_pane_option() {
    local target="$1"
    local option="$2"
    tmux show-options -p -t "$target" -v "$option" 2>/dev/null || true
}

restore_readiness_detected_cwd() {
    local target="$1"
    local tool="$2"
    local parsed_cwd="$3"
    local option_cwd pane_cwd

    case "$tool" in
        claude)
            option_cwd=$(restore_readiness_pane_option "$target" @claude_cwd)
            ;;
        codex)
            option_cwd=$(restore_readiness_pane_option "$target" @codex_cwd)
            ;;
        *)
            option_cwd=""
            ;;
    esac
    if [ -n "$option_cwd" ]; then
        printf '%s\n' "$option_cwd"
        return
    fi

    pane_cwd=$(tmux display-message -p -t "$target" '#{pane_current_path}' 2>/dev/null || true)
    if [ -n "$pane_cwd" ]; then
        printf '%s\n' "$pane_cwd"
        return
    fi

    printf '%s\n' "$parsed_cwd"
}

restore_readiness_pane() {
    local target="$1"
    local mode="${2:-save}"
    local detect_row tool sid sid_kind parsed_cwd cwd detect_flags wname original_cwd flags validate_fn collapsed_cwd

    restore_readiness_clear
    detect_row=$(restore_readiness_detect_row "$target") || return 1
    tool=$(restore_readiness_field "$detect_row" 1)
    sid=$(restore_readiness_field "$detect_row" 2)
    sid_kind=$(restore_readiness_field "$detect_row" 3)
    parsed_cwd=$(restore_readiness_field "$detect_row" 4)
    detect_flags=$(restore_readiness_detect_flags "$detect_row")

    cwd=$(restore_readiness_detected_cwd "$target" "$tool" "$parsed_cwd")
    wname=$(tmux display-message -p -t "$target" '#{window_name}' 2>/dev/null || true)

    original_cwd=""
    flags="$detect_flags"

    if [ "$sid_kind" = "uuid" ]; then
        validate_fn="${tool}_validate"
        if ! declare -F "$validate_fn" >/dev/null 2>&1 ||
            ! "$validate_fn" "$sid" "$sid_kind" >/dev/null 2>&1; then
            flags=$(restore_readiness_add_flag "$flags" sid_invalid)
            if [ "$mode" != "audit" ]; then
                sid="-"
                sid_kind="none"
            fi
        fi
    fi

    if [ -n "$cwd" ] && [ ! -d "$cwd" ]; then
        original_cwd="$cwd"
        collapsed_cwd=$(restore_readiness_collapse_cwd "$cwd" 2>/dev/null || true)
        if [ -n "$collapsed_cwd" ]; then
            cwd="$collapsed_cwd"
        fi
        flags=$(restore_readiness_add_flag "$flags" cwd_collapsed)
    fi

    RESTORE_READY_TARGET="$target"
    RESTORE_READY_TOOL="$tool"
    RESTORE_READY_SID="$sid"
    RESTORE_READY_SID_KIND="$sid_kind"
    RESTORE_READY_CWD="$cwd"
    RESTORE_READY_ORIGINAL_CWD="$original_cwd"
    RESTORE_READY_WNAME="$wname"
    RESTORE_READY_FLAGS="$flags"
}

restore_readiness_emit_row() {
    printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
        "$(tsv_encode "$RESTORE_READY_TARGET")" \
        "$(tsv_encode "$RESTORE_READY_TOOL")" \
        "$(tsv_encode "$RESTORE_READY_SID")" \
        "$(tsv_encode "$RESTORE_READY_SID_KIND")" \
        "$(tsv_encode "$RESTORE_READY_CWD")" \
        "$(tsv_encode "$RESTORE_READY_ORIGINAL_CWD")" \
        "$(tsv_encode "$RESTORE_READY_WNAME")" \
        "$(tsv_encode "$RESTORE_READY_FLAGS")"
}

restore_readiness_pane_row() {
    local target="$1"
    local mode="${2:-save}"

    restore_readiness_pane "$target" "$mode" || return 1
    restore_readiness_emit_row
}
