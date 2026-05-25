#!/usr/bin/env bash
# tmux-claude: shell quoting helpers for restore.

shell_quote_word() {
    local shell="$1"
    local word="$2"
    local rest="$word"

    case "$shell" in
        fish|bash|zsh|sh|dash|ksh) ;;
        *) shell="sh" ;;
    esac

    printf "'"
    while [ -n "$rest" ]; do
        case "$rest" in
            *"'"*)
                printf "%s'\\\\''" "${rest%%\'*}"
                rest="${rest#*\'}"
                ;;
            *)
                printf "%s" "$rest"
                rest=""
                ;;
        esac
    done
    printf "'"
}

shell_quote_argv() {
    local shell="$1"
    local argv="$2"
    local word first=1 out=""

    [ -n "$argv" ] || return 1

    while IFS= read -r word || [ -n "$word" ]; do
        if [ "$first" -eq 1 ]; then
            out="$(shell_quote_word "$shell" "$word")"
            first=0
        else
            out="$out $(shell_quote_word "$shell" "$word")"
        fi
    done <<EOF
$argv
EOF

    [ "$first" -eq 0 ] || return 1
    printf '%s' "$out"
}
