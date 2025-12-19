#!/usr/bin/env bats
# Unit tests for lyrebird-common.sh
# Run with: bats tests/test_lyrebird_common.bats
# Install bats: sudo apt-get install bats

# Setup - source the common library
setup() {
    # Get the directory of this test file
    TEST_DIR="$( cd "$( dirname "$BATS_TEST_FILENAME" )" && pwd )"
    PROJECT_ROOT="$( cd "$TEST_DIR/.." && pwd )"

    # Source the common library
    source "$PROJECT_ROOT/lyrebird-common.sh"
}

# ============================================================================
# Version Tests
# ============================================================================

@test "lyrebird_common_version returns version string" {
    run lyrebird_common_version
    [ "$status" -eq 0 ]
    [[ "$output" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]
}

@test "LYREBIRD_COMMON_VERSION is defined" {
    [ -n "$LYREBIRD_COMMON_VERSION" ]
}

# ============================================================================
# Timestamp Tests
# ============================================================================

@test "lyrebird_timestamp returns timestamp with timezone" {
    run lyrebird_timestamp
    [ "$status" -eq 0 ]
    # Should match format: YYYY-MM-DD HH:MM:SS TZ
    [[ "$output" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}\ [0-9]{2}:[0-9]{2}:[0-9]{2}\ [A-Z]+ ]]
}

# ============================================================================
# Command Existence Tests
# ============================================================================

@test "lyrebird_command_exists returns 0 for bash" {
    run lyrebird_command_exists bash
    [ "$status" -eq 0 ]
}

@test "lyrebird_command_exists returns 1 for nonexistent command" {
    run lyrebird_command_exists this_command_does_not_exist_12345
    [ "$status" -eq 1 ]
}

@test "command_exists is alias for lyrebird_command_exists" {
    run command_exists bash
    [ "$status" -eq 0 ]
}

# ============================================================================
# Hash Function Tests
# ============================================================================

@test "lyrebird_compute_hash produces consistent output" {
    hash1=$(echo "test" | lyrebird_compute_hash)
    hash2=$(echo "test" | lyrebird_compute_hash)
    [ "$hash1" = "$hash2" ]
}

@test "lyrebird_compute_hash produces different output for different input" {
    hash1=$(echo "test1" | lyrebird_compute_hash)
    hash2=$(echo "test2" | lyrebird_compute_hash)
    [ "$hash1" != "$hash2" ]
}

@test "get_portable_hash returns specified length" {
    run get_portable_hash "test" 8
    [ "$status" -eq 0 ]
    [ ${#output} -eq 8 ]
}

@test "get_portable_hash handles empty input" {
    run get_portable_hash "" 8
    [ "$status" -eq 0 ]
    [ ${#output} -eq 8 ]
}

# ============================================================================
# Exit Code Tests
# ============================================================================

@test "E_SUCCESS is 0" {
    [ "$E_SUCCESS" -eq 0 ]
}

@test "E_GENERAL is 1" {
    [ "$E_GENERAL" -eq 1 ]
}

@test "E_MISSING_DEPS is 3" {
    [ "$E_MISSING_DEPS" -eq 3 ]
}

@test "E_CONFIG_ERROR is 4" {
    [ "$E_CONFIG_ERROR" -eq 4 ]
}

# ============================================================================
# Color Tests
# ============================================================================

@test "color variables are defined" {
    # Colors should be defined (may be empty if not a terminal)
    [ -v RED ] || [ -v GREEN ] || [ -v NC ]
}

# ============================================================================
# File Size Tests
# ============================================================================

@test "get_file_size returns size for existing file" {
    # Use this test file itself
    run get_file_size "$BATS_TEST_FILENAME"
    [ "$status" -eq 0 ]
    [[ "$output" =~ ^[0-9]+$ ]]
    [ "$output" -gt 0 ]
}

@test "get_file_size returns 0 for nonexistent file" {
    run get_file_size "/nonexistent/file/path/12345"
    [ "$status" -eq 0 ]
    [ "$output" = "0" ]
}

# ============================================================================
# Guard Tests
# ============================================================================

@test "library can be sourced multiple times without error" {
    source "$PROJECT_ROOT/lyrebird-common.sh"
    source "$PROJECT_ROOT/lyrebird-common.sh"
    # Should complete without error
    [ $? -eq 0 ]
}
