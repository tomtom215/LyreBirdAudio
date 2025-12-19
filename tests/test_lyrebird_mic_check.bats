#!/usr/bin/env bats
# Unit tests for lyrebird-mic-check.sh
# Run with: bats tests/test_lyrebird_mic_check.bats
# Install bats: sudo apt-get install bats

# Setup - source the mic check script
setup() {
    # Get the directory of this test file
    TEST_DIR="$( cd "$( dirname "$BATS_TEST_FILENAME" )" && pwd )"
    PROJECT_ROOT="$( cd "$TEST_DIR/.." && pwd )"

    # Create temp directories for testing
    export TEMP_DIR="$(mktemp -d)"
    export OUTPUT_DIR="$(mktemp -d)"
    export CONFIG_BACKUP_DIR="$(mktemp -d)"

    # Source the mic check script
    source "$PROJECT_ROOT/lyrebird-mic-check.sh"
}

# Teardown - clean up temp files
teardown() {
    rm -rf "$TEMP_DIR" 2>/dev/null || true
    rm -rf "$OUTPUT_DIR" 2>/dev/null || true
    rm -rf "$CONFIG_BACKUP_DIR" 2>/dev/null || true
}

# ============================================================================
# Script Metadata Tests
# ============================================================================

@test "SCRIPT_VERSION is defined" {
    [ -n "$SCRIPT_VERSION" ]
    [[ "$SCRIPT_VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]
}

@test "SCRIPT_NAME is defined" {
    [ -n "$SCRIPT_NAME" ]
}

# ============================================================================
# Logging Function Tests
# ============================================================================

@test "log_info function exists" {
    run type log_info
    [ "$status" -eq 0 ]
}

@test "log_error function exists" {
    run type log_error
    [ "$status" -eq 0 ]
}

@test "log_warn function exists" {
    run type log_warn
    [ "$status" -eq 0 ]
}

# ============================================================================
# Usage and Help Tests
# ============================================================================

@test "show_usage function exists" {
    run type show_usage
    [ "$status" -eq 0 ]
}

@test "show_usage outputs help" {
    run show_usage
    [ "$status" -eq 0 ]
    [[ "$output" =~ "Usage" ]] || [[ "$output" =~ "USAGE" ]] || [[ "$output" =~ "Options" ]]
}

@test "show_version function exists" {
    run type show_version
    [ "$status" -eq 0 ]
}

@test "show_version outputs version" {
    run show_version
    [ "$status" -eq 0 ]
    [[ "$output" =~ [0-9]+\.[0-9]+\.[0-9]+ ]]
}

# ============================================================================
# Sanitization Tests
# ============================================================================

@test "sanitize_device_name function exists" {
    run type sanitize_device_name
    [ "$status" -eq 0 ]
}

@test "sanitize_device_name removes spaces" {
    run sanitize_device_name "USB Audio Device"
    [ "$status" -eq 0 ]
    [[ ! "$output" =~ " " ]]
}

@test "sanitize_device_name converts to lowercase" {
    run sanitize_device_name "USB_DEVICE"
    [ "$status" -eq 0 ]
    [[ "$output" =~ ^[a-z0-9_-]+$ ]]
}

@test "sanitize_device_name handles special characters" {
    run sanitize_device_name "Device (USB) v2.0"
    [ "$status" -eq 0 ]
    # Should only contain safe characters
    [[ "$output" =~ ^[a-z0-9_-]+$ ]]
}

# ============================================================================
# Device Detection Tests
# ============================================================================

@test "check_usb_audio_adapter function exists" {
    run type check_usb_audio_adapter
    [ "$status" -eq 0 ]
}

@test "is_device_busy function exists" {
    run type is_device_busy
    [ "$status" -eq 0 ]
}

@test "get_device_info function exists" {
    run type get_device_info
    [ "$status" -eq 0 ]
}

# ============================================================================
# Stream File Parsing Tests
# ============================================================================

@test "parse_stream_file function exists" {
    run type parse_stream_file
    [ "$status" -eq 0 ]
}

# ============================================================================
# Capability Detection Tests
# ============================================================================

@test "detect_device_capabilities function exists" {
    run type detect_device_capabilities
    [ "$status" -eq 0 ]
}

@test "parse_capabilities function exists" {
    run type parse_capabilities
    [ "$status" -eq 0 ]
}

@test "determine_optimal_settings function exists" {
    run type determine_optimal_settings
    [ "$status" -eq 0 ]
}

# ============================================================================
# Bitrate Calculation Tests
# ============================================================================

@test "calculate_encoder_bitrate function exists" {
    run type calculate_encoder_bitrate
    [ "$status" -eq 0 ]
}

@test "calculate_encoder_bitrate returns numeric value" {
    # Provide sample rate and channels
    run calculate_encoder_bitrate 48000 2
    [ "$status" -eq 0 ]
    [[ "$output" =~ ^[0-9]+$ ]]
}

@test "calculate_encoder_bitrate higher for stereo" {
    mono=$(calculate_encoder_bitrate 44100 1)
    stereo=$(calculate_encoder_bitrate 44100 2)
    [ "$stereo" -ge "$mono" ]
}

# ============================================================================
# USB Device Listing Tests
# ============================================================================

@test "list_all_usb_devices function exists" {
    run type list_all_usb_devices
    [ "$status" -eq 0 ]
}

# ============================================================================
# Config Backup Tests
# ============================================================================

@test "create_config_backup function exists" {
    run type create_config_backup
    [ "$status" -eq 0 ]
}

@test "list_config_backups function exists" {
    run type list_config_backups
    [ "$status" -eq 0 ]
}

@test "restore_config_backup function exists" {
    run type restore_config_backup
    [ "$status" -eq 0 ]
}

# ============================================================================
# Validation Tests
# ============================================================================

@test "check_root_access function exists" {
    run type check_root_access
    [ "$status" -eq 0 ]
}

@test "check_disk_space function exists" {
    run type check_disk_space
    [ "$status" -eq 0 ]
}

@test "validate_generated_config function exists" {
    run type validate_generated_config
    [ "$status" -eq 0 ]
}

# ============================================================================
# Config Generation Tests
# ============================================================================

@test "generate_config function exists" {
    run type generate_config
    [ "$status" -eq 0 ]
}

@test "get_config_value function exists" {
    run type get_config_value
    [ "$status" -eq 0 ]
}

@test "validate_config function exists" {
    run type validate_config
    [ "$status" -eq 0 ]
}

# ============================================================================
# Output Tests
# ============================================================================

@test "output_json function exists" {
    run type output_json
    [ "$status" -eq 0 ]
}

# ============================================================================
# Argument Parsing Tests
# ============================================================================

@test "parse_arguments function exists" {
    run type parse_arguments
    [ "$status" -eq 0 ]
}

@test "main function exists" {
    run type main
    [ "$status" -eq 0 ]
}

# ============================================================================
# Cleanup Tests
# ============================================================================

@test "cleanup function exists" {
    run type cleanup
    [ "$status" -eq 0 ]
}

# ============================================================================
# Default Values Tests
# ============================================================================

@test "DEFAULT_SAMPLE_RATE is defined" {
    [ -n "$DEFAULT_SAMPLE_RATE" ]
    [ "$DEFAULT_SAMPLE_RATE" -gt 0 ]
}

@test "DEFAULT_CHANNELS is defined" {
    [ -n "$DEFAULT_CHANNELS" ]
    [ "$DEFAULT_CHANNELS" -gt 0 ]
}

@test "PROC_ASOUND_CARDS path is defined" {
    [ -n "$PROC_ASOUND_CARDS" ]
}
