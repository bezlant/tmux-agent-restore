#!/usr/bin/env bash

red() { printf '\033[31m%s\033[0m\n' "$1"; }
green() { printf '\033[32m%s\033[0m\n' "$1"; }

assert_eq() {
    local name="$1" expected="$2" actual="$3"
    if [ "$expected" = "$actual" ]; then
        green "  PASS: $name"
        pass=$((pass + 1))
    else
        red "  FAIL: $name"
        printf '    expected: %s\n' "$expected"
        printf '    actual:   %s\n' "$actual"
        fail=$((fail + 1))
    fi
}

assert_contains() {
    local name="$1" needle="$2" haystack="$3"
    if printf '%s' "$haystack" | grep -Fq -- "$needle"; then
        green "  PASS: $name"
        pass=$((pass + 1))
    else
        red "  FAIL: $name"
        printf '    missing: %s\n' "$needle"
        printf '    in:      %s\n' "$haystack"
        fail=$((fail + 1))
    fi
}

assert_not_contains() {
    local name="$1" needle="$2" haystack="$3"
    if printf '%s' "$haystack" | grep -Fq -- "$needle"; then
        red "  FAIL: $name"
        printf '    unexpected: %s\n' "$needle"
        printf '    in:         %s\n' "$haystack"
        fail=$((fail + 1))
    else
        green "  PASS: $name"
        pass=$((pass + 1))
    fi
}
