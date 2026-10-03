#!/usr/bin/env bats
# generate_mediamtx_config across MediaMTX versions.
#
# MediaMTX >= 1.19.0 starts a MoQ server (:8892/tcp+udp, :8893/udp) unless the
# config says `moq: no`; 1.15-1.18 reject that key and refuse to start. The
# generated config must therefore carry the key exactly when the installed
# binary is >= 1.19.0. Verified against the real binaries (1.15.0 ... 1.21.1)
# in test_mediamtx_live.bats; these tests use stub binaries that only answer
# --version.

load scratch_tmpdir

setup() {
    scratch_setup
    PROJECT_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
    mkdir -p "$TEST_SCRATCH/bin" "$TEST_SCRATCH/etc"
}

teardown() {
    scratch_teardown
}

# stub_mediamtx <--version output> : fake binary that prints it
stub_mediamtx() {
    printf '#!/bin/sh\n[ "$1" = --version ] && printf "%%s\\n" "%s"\n' "$1" >"$TEST_SCRATCH/bin/mediamtx"
    chmod +x "$TEST_SCRATCH/bin/mediamtx"
}

# Print the config generate_mediamtx_config writes.
generated_config() {
    env MEDIAMTX_BINARY="$TEST_SCRATCH/bin/mediamtx" \
        MEDIAMTX_CONFIG_DIR="$TEST_SCRATCH/etc" \
        bash -c 'source "$1" >/dev/null 2>&1; log() { :; }; generate_mediamtx_config >/dev/null 2>&1 || exit 1; cat "$CONFIG_FILE"' \
        _ "$PROJECT_ROOT/lyrebird-stream-manager.sh"
}

@test "moq: no is written for MediaMTX 1.19.0 and later" {
    local v
    for v in v1.19.0 v1.21.1 v1.100.0 v2.0.0; do
        stub_mediamtx "$v"
        run generated_config
        [ "$status" -eq 0 ]
        [[ "$output" == *$'\nmoq: no\n'* ]] || { echo "missing for $v"; false; }
    done
}

@test "moq key is left out for MediaMTX 1.15-1.18, which reject it" {
    local v
    for v in v1.15.0 v1.18.2; do
        stub_mediamtx "$v"
        run generated_config
        [ "$status" -eq 0 ]
        [[ "$output" != *moq* ]] || { echo "present for $v"; false; }
    done
}

@test "moq key is left out when the version cannot be determined" {
    stub_mediamtx "garbage"
    run generated_config
    [ "$status" -eq 0 ]
    [[ "$output" != *moq* ]]
    rm -f "$TEST_SCRATCH/bin/mediamtx"
    run generated_config
    [ "$status" -eq 0 ]
    [[ "$output" != *moq* ]]
}

@test "paths: stays a top-level block after the optional moq key" {
    stub_mediamtx v1.21.1
    run generated_config
    [ "$status" -eq 0 ]
    # moq must come before paths:, and paths: must be followed by its entries.
    [[ "$output" == *$'moq: no\n\npaths:\n  '* ]]
    command -v python3 >/dev/null || skip "python3 not installed"
    printf '%s\n' "$output" | python3 -c '
import sys
lines = sys.stdin.read().splitlines()
top = [l.split(":")[0] for l in lines if l and not l.startswith((" ", "#"))]
assert top[-1] == "paths", top
assert top.count("moq") == 1, top
'
}
