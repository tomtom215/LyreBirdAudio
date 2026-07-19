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

    # The script enables `set -euo pipefail`, which leaks into the bats shell and
    # turns failing assertions / unset-var reads into silent aborts. Restore
    # bats' own error handling so failures report as "not ok".
    set +euo pipefail
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

# ============================================================================
# Regression tests for the device-config key contract (C4)
# ============================================================================

@test "generate_config emits UPPERCASE device keys [C4 regression]" {
    # The stream manager reads DEVICE_${name^^}_${param^^}; the generator must
    # emit the same uppercase names or every per-device setting is ignored.
    grep -qE 'DEVICE_\$\{safe_name\^\^\}_SAMPLE_RATE=' "$PROJECT_ROOT/lyrebird-mic-check.sh"
    run grep -cE 'DEVICE_\$\{safe_name\}_(SAMPLE_RATE|CHANNELS|BITRATE)=' "$PROJECT_ROOT/lyrebird-mic-check.sh"
    [ "$output" -eq 0 ]
}

@test "device key for a normal device matches stream-manager's lookup [C4 contract]" {
    # sanitize_device_name is sourced from mic-check in setup(). The uppercased
    # key must equal what stream-manager's get_device_config looks up.
    local name; name="$(sanitize_device_name "Blue Yeti")"
    [ "DEVICE_${name^^}_SAMPLE_RATE" = "DEVICE_BLUE_YETI_SAMPLE_RATE" ]
}

@test "get_config_value reads UPPERCASE keys so --validate stays consistent [C4 regression]" {
    # A config written by generate_config must be readable by mic-check itself.
    DEVICE_BLUE_YETI_SAMPLE_RATE=96000
    run get_config_value "Blue_Yeti" "" "SAMPLE_RATE"
    [ "$status" -eq 0 ]
    [ "$output" = "96000" ]
}

# ============================================================================
# Regression tests (MIC-6 JSON, MIC-8 channels, MIC-10 disk check)
# ============================================================================

@test "output_json emits the devices, not an empty list, and valid JSON [MIC-6 regression]" {
    local infile; infile="$(mktemp)"
    printf '=== Card 0: Blue Yeti ===\nDEVICE_NAME=Blue_Yeti\nSAMPLE_RATE=48000\nCHANNELS=2\n=== Card 1: Rode ===\nDEVICE_NAME=Rode\n' > "$infile"
    run output_json < "$infile"
    rm -f "$infile"
    [ "$status" -eq 0 ]
    # The old `IFS='=' read` skipped the "=== Card ===" header, so devices was
    # ALWAYS []. Must now be valid JSON with two devices.
    printf '%s\n' "$output" | python3 -c 'import json,sys; d=json.load(sys.stdin); assert len(d["devices"])==2, d; print("OK")'
}

@test "determine_optimal_settings low tier picks a SUPPORTED channel count (stereo-only mic) [MIC-8 regression]" {
    PARSED_CAPS[sample_rates]="48000"
    PARSED_CAPS[channels]="2"
    local out; out=$(determine_optimal_settings low 2>/dev/null)
    # output: "<rate> <channels> <bitrate>"; must be 2 (supported), not mono.
    [ "$(printf '%s' "$out" | awk '{print $2}')" = "2" ]
}

@test "determine_optimal_settings normal tier falls back to a supported count (4ch-only mic) [MIC-8 regression]" {
    PARSED_CAPS[sample_rates]="48000"
    PARSED_CAPS[channels]="4"
    local out; out=$(determine_optimal_settings normal 2>/dev/null)
    # 2 is unsupported here -> must pick a supported value (max=4), not 2.
    [ "$(printf '%s' "$out" | awk '{print $2}')" = "4" ]
}

@test "check_disk_space does not abort on a non-GNU df lacking --output [MIC-10 regression]" {
    local bin; bin="$(mktemp -d)"
    cat > "$bin/df" <<'DFEOF'
#!/bin/bash
for a in "$@"; do case "$a" in --output*) echo "df: unrecognized option: $a" >&2; exit 1;; esac; done
echo "Filesystem 1K-blocks Used Available Use% Mounted on"
echo "/dev/sda1 1000000 200000 800000 20% /"
DFEOF
    chmod +x "$bin/df"
    run env PROJECT_ROOT="$PROJECT_ROOT" PATH="$bin:$PATH" bash -c '
        set -euo pipefail
        source "$PROJECT_ROOT/lyrebird-mic-check.sh" >/dev/null 2>&1
        check_disk_space 1000    # ~1MB needed, 800MB free
    '
    rm -rf "$bin"
    [ "$status" -eq 0 ]     # old --output df would abort under set -euo pipefail
}
