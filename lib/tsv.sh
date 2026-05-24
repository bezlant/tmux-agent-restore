#!/usr/bin/env bash

# TSV snapshot fields are separated by literal TAB bytes, so field contents
# must escape bytes that would break the row shape or percent escape syntax.
# Decode by mapping %0D, %0A, %09, then %25 back to their literal bytes.
# Encoding must escape percent first so generated escape sequences are not
# encoded again, while existing percent sequences remain literal input data.
tsv_encode() {
    local v="$1"
    v="${v//%/%25}"
    v="${v//	/%09}"
    v="${v//$'\n'/%0A}"
    v="${v//$'\r'/%0D}"
    printf '%s' "$v"
}

tsv_decode() {
    local v="$1"
    v="${v//%09/	}"
    v="${v//%0A/$'\n'}"
    v="${v//%0D/$'\r'}"
    v="${v//%25/%}"
    printf '%s' "$v"
}
