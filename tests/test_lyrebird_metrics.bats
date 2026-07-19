#!/usr/bin/env bats
# Unit tests for lyrebird-metrics.sh
# Run with: bats tests/test_lyrebird_metrics.bats
# Install bats: sudo apt-get install bats

# Setup - source the metrics script
setup() {
    # Get the directory of this test file
    TEST_DIR="$( cd "$( dirname "$BATS_TEST_FILENAME" )" && pwd )"
    PROJECT_ROOT="$( cd "$TEST_DIR/.." && pwd )"

    # Create temp directories for testing
    export FFMPEG_PID_DIR="$(mktemp -d)"
    export HEARTBEAT_FILE="$(mktemp)"
    export PID_FILE="$(mktemp)"

    # Source the metrics script
    source "$PROJECT_ROOT/lyrebird-metrics.sh"

    # The script enables `set -euo pipefail`, which leaks into the bats shell and
    # turns failing assertions / unset-var reads into silent aborts. Restore
    # bats' own error handling so failures report as "not ok".
    set +euo pipefail
}

# Teardown - clean up temp files
teardown() {
    rm -rf "$FFMPEG_PID_DIR" 2>/dev/null || true
    rm -f "$HEARTBEAT_FILE" 2>/dev/null || true
    rm -f "$PID_FILE" 2>/dev/null || true
}

# ============================================================================
# Script Metadata Tests
# ============================================================================

@test "VERSION is defined" {
    [ -n "$VERSION" ]
    [[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]
}

@test "METRIC_PREFIX is lyrebird" {
    [ "$METRIC_PREFIX" = "lyrebird" ]
}

@test "SCRIPT_NAME is defined" {
    [ -n "$SCRIPT_NAME" ]
}

# ============================================================================
# Helper Function Tests
# ============================================================================

@test "has_command returns 0 for bash" {
    run has_command bash
    [ "$status" -eq 0 ]
}

@test "has_command returns 1 for nonexistent command" {
    run has_command this_command_does_not_exist_xyz
    [ "$status" -eq 1 ]
}

@test "get_timestamp_ms returns numeric value" {
    run get_timestamp_ms
    [ "$status" -eq 0 ]
    [[ "$output" =~ ^[0-9]+$ ]]
}

@test "get_timestamp_ms returns milliseconds (13+ digits)" {
    run get_timestamp_ms
    [ "$status" -eq 0 ]
    [ ${#output} -ge 13 ]
}

# ============================================================================
# emit_metric Tests
# ============================================================================

@test "emit_metric outputs metric name with prefix" {
    run emit_metric "test_metric" "42"
    [ "$status" -eq 0 ]
    [[ "$output" =~ lyrebird_test_metric ]]
}

@test "emit_metric includes value" {
    run emit_metric "test_metric" "123"
    [ "$status" -eq 0 ]
    [[ "$output" =~ "123" ]]
}

@test "emit_metric with help outputs HELP comment" {
    run emit_metric "test_metric" "1" "This is help text"
    [ "$status" -eq 0 ]
    [[ "$output" =~ "# HELP" ]]
    [[ "$output" =~ "This is help text" ]]
}

@test "emit_metric with type outputs TYPE comment" {
    run emit_metric "test_metric" "1" "Help" "counter"
    [ "$status" -eq 0 ]
    [[ "$output" =~ "# TYPE" ]]
    [[ "$output" =~ "counter" ]]
}

@test "emit_metric with labels includes labels" {
    run emit_metric "test_metric" "1" "" "gauge" 'name="test",type="unit"'
    [ "$status" -eq 0 ]
    [[ "$output" =~ 'name="test"' ]]
    [[ "$output" =~ 'type="unit"' ]]
}

@test "emit_metric default type is gauge" {
    run emit_metric "test_metric" "1" "Help"
    [ "$status" -eq 0 ]
    [[ "$output" =~ "gauge" ]]
}

# ============================================================================
# Collect Function Tests
# ============================================================================

@test "collect_mediamtx_metrics function exists" {
    run type collect_mediamtx_metrics
    [ "$status" -eq 0 ]
}

@test "collect_mediamtx_metrics outputs mediamtx_up metric" {
    run collect_mediamtx_metrics
    [ "$status" -eq 0 ]
    [[ "$output" =~ lyrebird_mediamtx_up ]]
}

@test "collect_stream_manager_metrics function exists" {
    run type collect_stream_manager_metrics
    [ "$status" -eq 0 ]
}

@test "collect_stream_manager_metrics outputs manager_running metric" {
    run collect_stream_manager_metrics
    [ "$status" -eq 0 ]
    [[ "$output" =~ lyrebird_stream_manager ]]
}

@test "collect_usb_audio_metrics function exists" {
    run type collect_usb_audio_metrics
    [ "$status" -eq 0 ]
}

@test "collect_usb_audio_metrics outputs usb_audio metric" {
    run collect_usb_audio_metrics
    [ "$status" -eq 0 ]
    [[ "$output" =~ lyrebird_usb_audio ]]
}

@test "collect_system_metrics function exists" {
    run type collect_system_metrics
    [ "$status" -eq 0 ]
}

@test "collect_system_metrics outputs cpu_usage metric" {
    run collect_system_metrics
    [ "$status" -eq 0 ]
    [[ "$output" =~ lyrebird_.*cpu ]] || [[ "$output" =~ lyrebird_.*load ]] || [[ "$output" =~ lyrebird_.*memory ]]
}

@test "collect_api_metrics function exists" {
    run type collect_api_metrics
    [ "$status" -eq 0 ]
}

@test "collect_stream_metrics function exists" {
    run type collect_stream_metrics
    [ "$status" -eq 0 ]
}

# ============================================================================
# Metric Format Tests
# ============================================================================

@test "metrics output is valid Prometheus format" {
    # Valid format: metric_name{labels} value
    run emit_metric "test" "1.5"
    [ "$status" -eq 0 ]
    # Should match: prefix_name value
    [[ "$output" =~ ^[a-z_]+\ [0-9.]+ ]]
}

@test "metric names use underscores not hyphens" {
    run emit_metric "test_metric_name" "1"
    [ "$status" -eq 0 ]
    # Should not contain hyphens in metric name
    [[ ! "$output" =~ lyrebird-test ]]
}

@test "metric values can be integers" {
    run emit_metric "int_metric" "42"
    [ "$status" -eq 0 ]
    [[ "$output" =~ "42" ]]
}

@test "metric values can be floats" {
    run emit_metric "float_metric" "3.14"
    [ "$status" -eq 0 ]
    [[ "$output" =~ "3.14" ]]
}

# ============================================================================
# Configuration Tests
# ============================================================================

@test "MEDIAMTX_API_HOST has default value" {
    [ -n "$MEDIAMTX_API_HOST" ]
}

@test "MEDIAMTX_API_PORT has default value" {
    [ -n "$MEDIAMTX_API_PORT" ]
}

@test "MEDIAMTX_RTSP_PORT has default value" {
    [ -n "$MEDIAMTX_RTSP_PORT" ]
}

# ============================================================================
# Integration Tests
# ============================================================================

@test "log function outputs to stderr" {
    run log "test message"
    [ "$status" -eq 0 ]
}

@test "full metrics collection runs without error" {
    # Run all collectors (may produce warnings but should not fail)
    run bash -c "source $PROJECT_ROOT/lyrebird-metrics.sh && collect_mediamtx_metrics && collect_system_metrics"
    [ "$status" -eq 0 ]
}

# ============================================================================
# Regression tests for Prometheus exposition-format validity (C6, M2)
# ============================================================================

@test "no metric family emits duplicate HELP/TYPE with multiple streams [C6 regression]" {
    # >=2 streams and 3 disk mounts previously produced repeated HELP/TYPE lines,
    # which makes the Prometheus text parser reject the ENTIRE scrape.
    # FFMPEG_PID_DIR is created (and made readonly) by setup(); populate it.
    echo $$ > "$FFMPEG_PID_DIR/mic1.pid"
    echo $$ > "$FFMPEG_PID_DIR/mic2.pid"
    output="$( { collect_system_metrics; collect_stream_metrics; } 2>/dev/null )"

    # Each metric name may appear in at most one '# HELP' and one '# TYPE' line.
    dup_help="$(printf '%s\n' "$output" | awk '/^# HELP /{c[$3]++} END{for(n in c) if(c[n]>1) print n}')"
    [ -z "$dup_help" ]
    dup_type="$(printf '%s\n' "$output" | awk '/^# TYPE /{c[$3]++} END{for(n in c) if(c[n]>1) print n}')"
    [ -z "$dup_type" ]
}

@test "no sample line is emitted with an empty value [C6/M2 regression]" {
    echo $$ > "$FFMPEG_PID_DIR/mic1.pid"
    output="$( { collect_system_metrics; collect_stream_metrics; } 2>/dev/null )"
    # A metric/sample line must end with a value; reject a name (optionally with
    # labels) followed by only whitespace/EOL.
    run bash -c 'printf "%s\n" "$1" | grep -nE "^[a-zA-Z_][a-zA-Z0-9_:]*(\{[^}]*\})?[[:space:]]*$"' _ "$output"
    [ "$status" -ne 0 ]
}

# --- MET-1: collectors must not abort the whole scrape (the normal state) -----

@test "collect_api_metrics completes with empty API lists (no publishers/listeners) [MET-1 regression]" {
    local bin; bin="$(mktemp -d)"
    cat > "$bin/curl" <<'CURLEOF'
#!/bin/bash
# Valid /v3/info so api_up=1; empty item lists for every other endpoint.
for a in "$@"; do
    case "$a" in *"/v3/info") echo '{"version":"1.19.2","upTime":100}'; exit 0;; esac
done
echo '{"itemCount":0,"items":[]}'
exit 0
CURLEOF
    chmod +x "$bin/curl"
    run env PROJECT_ROOT="$PROJECT_ROOT" PATH="$bin:$PATH" \
        bash -c 'set -euo pipefail; source "$PROJECT_ROOT/lyrebird-metrics.sh"; collect_api_metrics'
    rm -rf "$bin"
    [ "$status" -eq 0 ]
    # Reaching the LAST metric proves it did not abort on an empty grep|wc-l pipe
    # partway through (the pre-fix code stopped at the first empty list).
    [[ "$output" =~ lyrebird_api_total_connections ]]
    [[ "$output" =~ lyrebird_api_up[[:space:]]+1 ]]
}

# --- MET-2: grep -c must not emit "0\n0" and break the scrape ------------------

@test "configured_devices emits a single valid 0, never '0\\n0' [MET-2 regression]" {
    local cfgdir; cfgdir="$(mktemp -d)"
    printf '# a config with no DEVICE_ lines\n# just comments\n' > "$cfgdir/audio-devices.conf"
    # NOTE: the device-config path derives from MEDIAMTX_CONFIG_DIR; a file that
    # EXISTS but has zero DEVICE_ lines is what triggers `grep -c` to print 0 and
    # exit 1 (the "0\n0" bug). A missing file takes a different branch.
    run env PROJECT_ROOT="$PROJECT_ROOT" MEDIAMTX_CONFIG_DIR="$cfgdir" \
        PID_FILE="$(mktemp)" FFMPEG_PID_DIR="$(mktemp -d)" HEARTBEAT_FILE="$(mktemp)" \
        bash -c 'set -euo pipefail; source "$PROJECT_ROOT/lyrebird-metrics.sh"; collect_stream_manager_metrics'
    rm -rf "$cfgdir"
    [ "$status" -eq 0 ]
    [ "$(printf '%s\n' "$output" | grep -c '^lyrebird_configured_devices ')" -eq 1 ]
    printf '%s\n' "$output" | grep -qx 'lyrebird_configured_devices 0'
    # No stray bare "0" line (the "0\n0" bug) anywhere in the output
    run bash -c 'printf "%s\n" "$1" | grep -qx 0' _ "$output"
    [ "$status" -ne 0 ]
}

# --- MET-6: label values must be escaped so one bad name can't reject a scrape -

@test "prom_escape_label escapes backslash, then quote, then newline [MET-6 regression]" {
    run prom_escape_label 'a"b\c'
    [ "$status" -eq 0 ]
    [ "$output" = 'a\"b\\c' ]
}

@test "emit_metric keeps a quoted device name on one valid line [MET-6 regression]" {
    run emit_metric "stream_up" "1" "" "gauge" "stream=\"$(prom_escape_label 'AKG "C414"')\""
    [ "$status" -eq 0 ]
    [ "$(printf '%s\n' "$output" | grep -c .)" -eq 1 ]     # exactly one line
    [[ "$output" == *'stream="AKG \"C414\""'* ]]
}
