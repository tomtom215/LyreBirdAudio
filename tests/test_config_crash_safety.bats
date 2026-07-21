#!/usr/bin/env bats
# Config-integrity / cold-start tests: a corrupt device config must degrade to
# defaults, never abort `start`.
#
# load_device_config used to `source` the device config directly. A file
# truncated by a power loss mid-write, corrupted by SD-card bit-rot, or
# mis-edited by an operator then aborts the whole run under set -euo pipefail:
# `start` fails and NO streams come up on the next unattended boot -- a total
# outage from one bad line. The manager must ignore a corrupt config and use
# built-in defaults, and must still honor a valid one.

setup() {
    TEST_DIR="$( cd "$( dirname "$BATS_TEST_FILENAME" )" && pwd )"
    PROJECT_ROOT="$( cd "$TEST_DIR/.." && pwd )"
    CC_TMP="$(mktemp -d)"
}

teardown() {
    rm -rf "$CC_TMP" 2>/dev/null || true
}

@test "a truncated device config (unterminated array) does not abort start [cold-start]" {
    # Simulates power loss mid-write: last line cut off.
    cat > "$CC_TMP/audio-devices.conf" <<'EOF'
DEVICE_YETI_SAMPLE_RATE=96000
DEVICE_YETI_CHANNELS=(unterminated
EOF
    run env PROJECT_ROOT="$PROJECT_ROOT" MEDIAMTX_DEVICE_CONFIG="$CC_TMP/audio-devices.conf" bash -c '
        set -euo pipefail
        source "$PROJECT_ROOT/lyrebird-stream-manager.sh" >/dev/null 2>&1
        log() { :; }
        load_device_config
        echo "START-CONTINUES"
    '
    [ "$status" -eq 0 ]
    [[ "$output" == *"START-CONTINUES"* ]]
}

@test "a config with a stray command that fails does not abort start" {
    cat > "$CC_TMP/audio-devices.conf" <<'EOF'
DEVICE_YETI_SAMPLE_RATE=96000
false
DEVICE_YETI_CHANNELS=2
EOF
    run env PROJECT_ROOT="$PROJECT_ROOT" MEDIAMTX_DEVICE_CONFIG="$CC_TMP/audio-devices.conf" bash -c '
        set -euo pipefail
        source "$PROJECT_ROOT/lyrebird-stream-manager.sh" >/dev/null 2>&1
        log() { :; }
        load_device_config
        echo "START-CONTINUES rate=${DEVICE_YETI_SAMPLE_RATE:-unset}"
    '
    [ "$status" -eq 0 ]
    [[ "$output" == *"START-CONTINUES"* ]]
}

@test "errexit is restored after loading a config that touched set -e" {
    printf 'DEVICE_X_SAMPLE_RATE=48000\n' > "$CC_TMP/audio-devices.conf"
    run env PROJECT_ROOT="$PROJECT_ROOT" MEDIAMTX_DEVICE_CONFIG="$CC_TMP/audio-devices.conf" bash -c '
        set -euo pipefail
        source "$PROJECT_ROOT/lyrebird-stream-manager.sh" >/dev/null 2>&1
        log() { :; }
        load_device_config
        case "$-" in *e*) echo "ERREXIT-ON" ;; *) echo "ERREXIT-OFF" ;; esac
    '
    [ "$status" -eq 0 ]
    [[ "$output" == *"ERREXIT-ON"* ]]
}

@test "a valid device config is still honored (defaults not forced) [regression]" {
    printf 'DEVICE_YETI_SAMPLE_RATE=192000\n' > "$CC_TMP/audio-devices.conf"
    run env PROJECT_ROOT="$PROJECT_ROOT" MEDIAMTX_DEVICE_CONFIG="$CC_TMP/audio-devices.conf" bash -c '
        set -euo pipefail
        source "$PROJECT_ROOT/lyrebird-stream-manager.sh" >/dev/null 2>&1
        log() { :; }
        load_device_config
        get_device_config "Yeti" "SAMPLE_RATE" "48000"
    '
    [ "$status" -eq 0 ]
    [ "$output" = "192000" ]
}
