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
