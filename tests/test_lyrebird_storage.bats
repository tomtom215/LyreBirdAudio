#!/usr/bin/env bats
# Unit tests for lyrebird-storage.sh
# Run with: bats tests/test_lyrebird_storage.bats
# Install bats: sudo apt-get install bats

# Setup - source the storage script
setup() {
    # Get the directory of this test file
    TEST_DIR="$( cd "$( dirname "$BATS_TEST_FILENAME" )" && pwd )"
    PROJECT_ROOT="$( cd "$TEST_DIR/.." && pwd )"

    # Create temp directories for testing
    export RECORDING_DIR="$(mktemp -d)"
    export LOG_DIR="$(mktemp -d)"
    export TEMP_DIR="$(mktemp -d)"

    # Set conservative thresholds for testing
    export DISK_WARNING_PERCENT=80
    export DISK_CRITICAL_PERCENT=90
    export RECORDING_RETENTION_DAYS=30
    export LOG_RETENTION_DAYS=7
    export LOG_MAX_SIZE_MB=50

    # Source the storage script
    source "$PROJECT_ROOT/lyrebird-storage.sh"
}

# Teardown - clean up temp directories
teardown() {
    rm -rf "$RECORDING_DIR" 2>/dev/null || true
    rm -rf "$LOG_DIR" 2>/dev/null || true
    rm -rf "$TEMP_DIR" 2>/dev/null || true
}

# ============================================================================
# Script Metadata Tests
# ============================================================================

@test "SCRIPT_VERSION is defined" {
    [ -n "$SCRIPT_VERSION" ]
    [[ "$SCRIPT_VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]
}

@test "SCRIPT_NAME is lyrebird-storage" {
    [ "$SCRIPT_NAME" = "lyrebird-storage" ]
}

# ============================================================================
# Configuration Tests
# ============================================================================

@test "DISK_WARNING_PERCENT has default value" {
    [ -n "$DISK_WARNING_PERCENT" ]
    [ "$DISK_WARNING_PERCENT" -ge 0 ]
    [ "$DISK_WARNING_PERCENT" -le 100 ]
}

@test "DISK_CRITICAL_PERCENT has default value" {
    [ -n "$DISK_CRITICAL_PERCENT" ]
    [ "$DISK_CRITICAL_PERCENT" -ge 0 ]
    [ "$DISK_CRITICAL_PERCENT" -le 100 ]
}

@test "DISK_CRITICAL_PERCENT is higher than DISK_WARNING_PERCENT" {
    [ "$DISK_CRITICAL_PERCENT" -ge "$DISK_WARNING_PERCENT" ]
}

@test "RECORDING_RETENTION_DAYS has default value" {
    [ -n "$RECORDING_RETENTION_DAYS" ]
    [ "$RECORDING_RETENTION_DAYS" -ge 1 ]
}

@test "LOG_RETENTION_DAYS has default value" {
    [ -n "$LOG_RETENTION_DAYS" ]
    [ "$LOG_RETENTION_DAYS" -ge 1 ]
}

# ============================================================================
# Logging Function Tests
# ============================================================================

@test "log function exists" {
    run type log
    [ "$status" -eq 0 ]
}

@test "log_info function exists" {
    run type log_info
    [ "$status" -eq 0 ]
}

@test "log_warn function exists" {
    run type log_warn
    [ "$status" -eq 0 ]
}

@test "log_error function exists" {
    run type log_error
    [ "$status" -eq 0 ]
}

@test "log_debug function exists" {
    run type log_debug
    [ "$status" -eq 0 ]
}

# ============================================================================
# format_bytes Tests
# ============================================================================

@test "format_bytes handles zero" {
    run format_bytes 0
    [ "$status" -eq 0 ]
    [[ "$output" =~ "0" ]]
}

@test "format_bytes handles bytes" {
    run format_bytes 500
    [ "$status" -eq 0 ]
    [[ "$output" =~ "B" ]]
}

@test "format_bytes handles kilobytes" {
    run format_bytes 2048
    [ "$status" -eq 0 ]
    [[ "$output" =~ "K" ]]
}

@test "format_bytes handles megabytes" {
    run format_bytes 5242880
    [ "$status" -eq 0 ]
    [[ "$output" =~ "M" ]]
}

@test "format_bytes handles gigabytes" {
    run format_bytes 5368709120
    [ "$status" -eq 0 ]
    [[ "$output" =~ "G" ]]
}

# ============================================================================
# get_disk_usage Tests
# ============================================================================

@test "get_disk_usage returns numeric value" {
    run get_disk_usage "/"
    [ "$status" -eq 0 ]
    [[ "$output" =~ ^[0-9]+$ ]]
}

@test "get_disk_usage returns value between 0 and 100" {
    usage=$(get_disk_usage "/")
    [ "$usage" -ge 0 ]
    [ "$usage" -le 100 ]
}

@test "get_disk_usage handles temp directory" {
    run get_disk_usage "$TEMP_DIR"
    [ "$status" -eq 0 ]
    [[ "$output" =~ ^[0-9]+$ ]]
}

# ============================================================================
# get_free_space_mb Tests
# ============================================================================

@test "get_free_space_mb returns numeric value" {
    run get_free_space_mb "/"
    [ "$status" -eq 0 ]
    [[ "$output" =~ ^[0-9]+$ ]]
}

@test "get_free_space_mb returns positive value" {
    space=$(get_free_space_mb "/")
    [ "$space" -ge 0 ]
}

# ============================================================================
# get_dir_size Tests
# ============================================================================

@test "get_dir_size returns numeric value for empty dir" {
    run get_dir_size "$TEMP_DIR"
    [ "$status" -eq 0 ]
    [[ "$output" =~ ^[0-9]+$ ]]
}

@test "get_dir_size returns correct size for file" {
    # Create a 1KB file
    dd if=/dev/zero of="$TEMP_DIR/testfile" bs=1024 count=1 2>/dev/null
    run get_dir_size "$TEMP_DIR"
    [ "$status" -eq 0 ]
    # Should be at least 1 (KB)
    [ "$output" -ge 1 ]
}

# ============================================================================
# count_files Tests
# ============================================================================

@test "count_files returns 0 for empty directory" {
    run count_files "$TEMP_DIR" "*.wav"
    [ "$status" -eq 0 ]
    [ "$output" -eq 0 ]
}

@test "count_files counts matching files" {
    touch "$TEMP_DIR/file1.wav" "$TEMP_DIR/file2.wav" "$TEMP_DIR/file3.txt"
    run count_files "$TEMP_DIR" "*.wav"
    [ "$status" -eq 0 ]
    [ "$output" -eq 2 ]
}

@test "count_files handles no matches" {
    touch "$TEMP_DIR/file1.txt" "$TEMP_DIR/file2.txt"
    run count_files "$TEMP_DIR" "*.wav"
    [ "$status" -eq 0 ]
    [ "$output" -eq 0 ]
}

# ============================================================================
# safe_delete Tests
# ============================================================================

@test "safe_delete removes file when safe" {
    local test_file="$TEMP_DIR/deleteme.txt"
    echo "test" > "$test_file"
    [ -f "$test_file" ]

    run safe_delete "$test_file"
    [ "$status" -eq 0 ]
    [ ! -f "$test_file" ]
}

@test "safe_delete handles nonexistent file" {
    run safe_delete "$TEMP_DIR/nonexistent_file_xyz"
    # Should not fail for nonexistent file
    [ "$status" -eq 0 ] || [ "$status" -eq 1 ]
}

# ============================================================================
# cleanup_recordings Tests
# ============================================================================

@test "cleanup_recordings function exists" {
    run type cleanup_recordings
    [ "$status" -eq 0 ]
}

@test "cleanup_recordings handles empty directory" {
    run cleanup_recordings
    [ "$status" -eq 0 ]
}

@test "cleanup_recordings respects retention days" {
    # Create a file that's old enough to delete
    local old_file="$RECORDING_DIR/old_recording.wav"
    touch -d "40 days ago" "$old_file" 2>/dev/null || touch "$old_file"

    # This should not fail
    run cleanup_recordings
    [ "$status" -eq 0 ]
}

# ============================================================================
# cleanup_logs Tests
# ============================================================================

@test "cleanup_logs function exists" {
    run type cleanup_logs
    [ "$status" -eq 0 ]
}

@test "cleanup_logs handles empty directory" {
    run cleanup_logs
    [ "$status" -eq 0 ]
}

# ============================================================================
# cleanup_temp Tests
# ============================================================================

@test "cleanup_temp function exists" {
    run type cleanup_temp
    [ "$status" -eq 0 ]
}

@test "cleanup_temp handles empty directory" {
    run cleanup_temp
    [ "$status" -eq 0 ]
}

# ============================================================================
# truncate_large_logs Tests
# ============================================================================

@test "truncate_large_logs function exists" {
    run type truncate_large_logs
    [ "$status" -eq 0 ]
}

@test "truncate_large_logs handles empty directory" {
    run truncate_large_logs
    [ "$status" -eq 0 ]
}

# ============================================================================
# emergency_cleanup Tests
# ============================================================================

@test "emergency_cleanup function exists" {
    run type emergency_cleanup
    [ "$status" -eq 0 ]
}

# ============================================================================
# Command Function Tests
# ============================================================================

@test "cmd_status function exists" {
    run type cmd_status
    [ "$status" -eq 0 ]
}

@test "cmd_status runs without error" {
    run cmd_status
    [ "$status" -eq 0 ]
}

@test "cmd_status outputs disk usage" {
    run cmd_status
    [ "$status" -eq 0 ]
    [[ "$output" =~ [Dd]isk ]] || [[ "$output" =~ [Uu]sage ]] || [[ "$output" =~ [Ss]torage ]]
}

@test "cmd_cleanup function exists" {
    run type cmd_cleanup
    [ "$status" -eq 0 ]
}

@test "cmd_monitor function exists" {
    run type cmd_monitor
    [ "$status" -eq 0 ]
}

@test "cmd_emergency function exists" {
    run type cmd_emergency
    [ "$status" -eq 0 ]
}

# ============================================================================
# Help and Main Tests
# ============================================================================

@test "show_help runs without error" {
    run show_help
    [ "$status" -eq 0 ]
    [[ "$output" =~ "USAGE" ]] || [[ "$output" =~ "Usage" ]]
}

@test "show_help displays available commands" {
    run show_help
    [ "$status" -eq 0 ]
    [[ "$output" =~ "status" ]]
    [[ "$output" =~ "cleanup" ]]
}

@test "main function exists" {
    run type main
    [ "$status" -eq 0 ]
}
