#!/usr/bin/env bats
# Unit tests for lyrebird-alerts.sh
# Run with: bats tests/test_lyrebird_alerts.bats
# Install bats: sudo apt-get install bats

# Setup - source the alerts script
setup() {
    # Get the directory of this test file
    TEST_DIR="$( cd "$( dirname "$BATS_TEST_FILENAME" )" && pwd )"
    PROJECT_ROOT="$( cd "$TEST_DIR/.." && pwd )"

    # Create temp directory for test state
    export LYREBIRD_ALERT_STATE_DIR="$(mktemp -d)"
    export LYREBIRD_ALERT_LOG="$(mktemp)"
    export LYREBIRD_ALERT_CONFIG="$(mktemp)"

    # Disable actual webhook sending for tests
    export LYREBIRD_ALERT_ENABLED="false"
    export LYREBIRD_WEBHOOK_URL=""

    # Source the alerts script (functions only, don't run main)
    source "$PROJECT_ROOT/lyrebird-alerts.sh"
}

# Teardown - clean up temp files
teardown() {
    rm -rf "$LYREBIRD_ALERT_STATE_DIR" 2>/dev/null || true
    rm -f "$LYREBIRD_ALERT_LOG" 2>/dev/null || true
    rm -f "$LYREBIRD_ALERT_CONFIG" 2>/dev/null || true
}

# ============================================================================
# Script Metadata Tests
# ============================================================================

@test "SCRIPT_VERSION is defined" {
    [ -n "$SCRIPT_VERSION" ]
    [[ "$SCRIPT_VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]
}

@test "SCRIPT_NAME is lyrebird-alerts" {
    [ "$SCRIPT_NAME" = "lyrebird-alerts" ]
}

# ============================================================================
# Alert Level Tests
# ============================================================================

@test "ALERT_LEVEL_INFO is defined" {
    [ "$ALERT_LEVEL_INFO" = "info" ]
}

@test "ALERT_LEVEL_WARNING is defined" {
    [ "$ALERT_LEVEL_WARNING" = "warning" ]
}

@test "ALERT_LEVEL_ERROR is defined" {
    [ "$ALERT_LEVEL_ERROR" = "error" ]
}

@test "ALERT_LEVEL_CRITICAL is defined" {
    [ "$ALERT_LEVEL_CRITICAL" = "critical" ]
}

# ============================================================================
# Alert Type Tests
# ============================================================================

@test "ALERT_TYPE_STREAM_DOWN is defined" {
    [ "$ALERT_TYPE_STREAM_DOWN" = "stream_down" ]
}

@test "ALERT_TYPE_DEVICE_DISCONNECT is defined" {
    [ "$ALERT_TYPE_DEVICE_DISCONNECT" = "device_disconnect" ]
}

@test "ALERT_TYPE_DISK_WARNING is defined" {
    [ "$ALERT_TYPE_DISK_WARNING" = "disk_warning" ]
}

@test "ALERT_TYPE_MEDIAMTX_DOWN is defined" {
    [ "$ALERT_TYPE_MEDIAMTX_DOWN" = "mediamtx_down" ]
}

# ============================================================================
# Alert Color Tests
# ============================================================================

@test "ALERT_COLORS array has info color" {
    [ -n "${ALERT_COLORS[info]}" ]
}

@test "ALERT_COLORS array has critical color" {
    [ -n "${ALERT_COLORS[critical]}" ]
}

@test "ALERT_EMOJI array has warning emoji" {
    [ -n "${ALERT_EMOJI[warning]}" ]
}

# ============================================================================
# Hash Generation Tests
# ============================================================================

@test "generate_alert_hash returns non-empty hash" {
    run generate_alert_hash "test_type" "test message"
    [ "$status" -eq 0 ]
    [ -n "$output" ]
}

@test "generate_alert_hash returns consistent hash for same input" {
    hash1=$(generate_alert_hash "type1" "message1")
    hash2=$(generate_alert_hash "type1" "message1")
    [ "$hash1" = "$hash2" ]
}

@test "generate_alert_hash returns different hash for different input" {
    hash1=$(generate_alert_hash "type1" "message1")
    hash2=$(generate_alert_hash "type2" "message2")
    [ "$hash1" != "$hash2" ]
}

# ============================================================================
# Rate Limiting Tests
# ============================================================================

@test "is_rate_limited returns 1 for new alert (not limited)" {
    run is_rate_limited "new_hash_12345"
    [ "$status" -eq 1 ]
}

@test "update_rate_limit creates state file" {
    update_rate_limit "test_hash_update"
    [ -f "${LYREBIRD_ALERT_STATE_DIR}/test_hash_update.last" ]
}

@test "is_rate_limited returns 0 after update_rate_limit" {
    export LYREBIRD_ALERT_RATE_LIMIT=3600  # 1 hour
    update_rate_limit "test_hash_ratelimit"
    run is_rate_limited "test_hash_ratelimit"
    [ "$status" -eq 0 ]
}

# ============================================================================
# State Directory Tests
# ============================================================================

@test "ensure_state_dir creates directory if missing" {
    local new_dir="${LYREBIRD_ALERT_STATE_DIR}/subdir"
    export LYREBIRD_ALERT_STATE_DIR="$new_dir"
    run ensure_state_dir
    [ "$status" -eq 0 ]
    [ -d "$new_dir" ]
}

# ============================================================================
# Formatter Tests - Generic
# ============================================================================

@test "format_generic returns valid JSON" {
    run format_generic "info" "Test Title" "Test message" "test_type"
    [ "$status" -eq 0 ]
    [[ "$output" =~ \"level\":\ *\"info\" ]]
    [[ "$output" =~ \"title\":\ *\"Test\ Title\" ]]
    [[ "$output" =~ \"message\":\ *\"Test\ message\" ]]
}

@test "format_generic includes timestamp" {
    run format_generic "warning" "Title" "Message" "type"
    [ "$status" -eq 0 ]
    [[ "$output" =~ \"timestamp\":\ *\"[0-9]{4}-[0-9]{2}-[0-9]{2}T ]]
}

@test "format_generic includes source field" {
    run format_generic "error" "Title" "Message" "type"
    [ "$status" -eq 0 ]
    [[ "$output" =~ \"source\":\ *\"lyrebird-alerts\" ]]
}

# ============================================================================
# Formatter Tests - Discord
# ============================================================================

@test "format_discord returns embeds array" {
    run format_discord "info" "Test Title" "Test message" "test_type"
    [ "$status" -eq 0 ]
    [[ "$output" =~ \"embeds\":\ *\[ ]]
}

@test "format_discord includes color field" {
    run format_discord "critical" "Alert" "Urgent" "type"
    [ "$status" -eq 0 ]
    [[ "$output" =~ \"color\":\ *[0-9]+ ]]
}

@test "format_discord includes title with emoji" {
    run format_discord "warning" "Warning Title" "Message" "type"
    [ "$status" -eq 0 ]
    # Should have emoji prefix in title
    [[ "$output" =~ \"title\":\ *\".+Warning\ Title\" ]]
}

# ============================================================================
# Formatter Tests - Slack
# ============================================================================

@test "format_slack returns attachments array" {
    run format_slack "info" "Test Title" "Test message" "test_type"
    [ "$status" -eq 0 ]
    [[ "$output" =~ \"attachments\":\ *\[ ]]
}

@test "format_slack includes color hex" {
    run format_slack "error" "Error" "Message" "type"
    [ "$status" -eq 0 ]
    [[ "$output" =~ \"color\":\ *\"#[0-9a-f]+\" ]]
}

# ============================================================================
# Formatter Tests - ntfy
# ============================================================================

@test "format_ntfy returns NTFY prefix format" {
    run format_ntfy "warning" "Title" "Message" "type"
    [ "$status" -eq 0 ]
    [[ "$output" =~ ^NTFY: ]]
}

@test "format_ntfy includes priority" {
    run format_ntfy "critical" "Urgent" "Help!" "type"
    [ "$status" -eq 0 ]
    [[ "$output" =~ NTFY:urgent: ]]
}

# ============================================================================
# Send Alert Tests (with alerts disabled)
# ============================================================================

@test "send_alert returns 0 when alerts disabled" {
    export LYREBIRD_ALERT_ENABLED="false"
    run send_alert "info" "Test" "Message"
    [ "$status" -eq 0 ]
}

@test "send_alert returns 0 when no webhook configured" {
    export LYREBIRD_ALERT_ENABLED="true"
    export LYREBIRD_WEBHOOK_URL=""
    export LYREBIRD_WEBHOOK_URLS=""
    run send_alert "info" "Test" "Message"
    [ "$status" -eq 0 ]
}

# ============================================================================
# Convenience Function Tests
# ============================================================================

@test "alert_stream_down function exists" {
    run type alert_stream_down
    [ "$status" -eq 0 ]
}

@test "alert_stream_up function exists" {
    run type alert_stream_up
    [ "$status" -eq 0 ]
}

@test "alert_device_disconnect function exists" {
    run type alert_device_disconnect
    [ "$status" -eq 0 ]
}

@test "alert_disk_warning function exists" {
    run type alert_disk_warning
    [ "$status" -eq 0 ]
}

@test "alert_disk_critical function exists" {
    run type alert_disk_critical
    [ "$status" -eq 0 ]
}

@test "alert_mediamtx_down function exists" {
    run type alert_mediamtx_down
    [ "$status" -eq 0 ]
}

@test "alert_network_down function exists" {
    run type alert_network_down
    [ "$status" -eq 0 ]
}

# ============================================================================
# Log Alert Tests
# ============================================================================

@test "log_alert writes to log file" {
    log_alert "info" "Test log message"
    [ -f "$LYREBIRD_ALERT_LOG" ]
    grep -q "Test log message" "$LYREBIRD_ALERT_LOG"
}

@test "log_alert includes level in log" {
    log_alert "warning" "Warning message"
    grep -q "\[warning\]" "$LYREBIRD_ALERT_LOG"
}

@test "log_alert includes timestamp" {
    log_alert "error" "Error message"
    # Should have timestamp format [YYYY-MM-DD HH:MM:SS]
    grep -qE "\[[0-9]{4}-[0-9]{2}-[0-9]{2} [0-9]{2}:[0-9]{2}:[0-9]{2}\]" "$LYREBIRD_ALERT_LOG"
}

# ============================================================================
# CLI Tests
# ============================================================================

@test "show_help runs without error" {
    run show_help
    [ "$status" -eq 0 ]
    [[ "$output" =~ "USAGE:" ]]
}

@test "show_status runs without error" {
    run show_status
    [ "$status" -eq 0 ]
    [[ "$output" =~ "Configuration:" ]]
}

@test "show_config runs without error" {
    run show_config
    [ "$status" -eq 0 ]
    [[ "$output" =~ "LYREBIRD_ALERT_ENABLED" ]]
}
