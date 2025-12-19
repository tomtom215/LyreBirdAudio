#!/usr/bin/env bats
# Unit tests for install_mediamtx.sh
# Run with: bats tests/test_install_mediamtx.bats
# Install bats: sudo apt-get install bats

# Setup - source the installer script
setup() {
    # Get the directory of this test file
    TEST_DIR="$( cd "$( dirname "$BATS_TEST_FILENAME" )" && pwd )"
    PROJECT_ROOT="$( cd "$TEST_DIR/.." && pwd )"

    # Create temp directories for testing
    export TEMP_DIR="$(mktemp -d)"
    export LOCK_FILE="$(mktemp)"
    export CONFIG_FILE="$(mktemp)"

    # Set dry-run mode to avoid actual system changes
    export DRY_RUN=true

    # Source the installer script
    source "$PROJECT_ROOT/install_mediamtx.sh"
}

# Teardown - clean up temp files
teardown() {
    rm -rf "$TEMP_DIR" 2>/dev/null || true
    rm -f "$LOCK_FILE" 2>/dev/null || true
    rm -f "$CONFIG_FILE" 2>/dev/null || true
}

# ============================================================================
# Script Metadata Tests
# ============================================================================

@test "VERSION is defined" {
    [ -n "$VERSION" ]
    [[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]
}

@test "SCRIPT_NAME is defined" {
    [ -n "$SCRIPT_NAME" ]
}

# ============================================================================
# Logging Function Tests
# ============================================================================

@test "log_debug function exists" {
    run type log_debug
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

@test "fatal function exists" {
    run type fatal
    [ "$status" -eq 0 ]
}

# ============================================================================
# Initialization Tests
# ============================================================================

@test "initialize_runtime_vars function exists" {
    run type initialize_runtime_vars
    [ "$status" -eq 0 ]
}

@test "error_handler function exists" {
    run type error_handler
    [ "$status" -eq 0 ]
}

@test "cleanup function exists" {
    run type cleanup
    [ "$status" -eq 0 ]
}

# ============================================================================
# Lock Function Tests
# ============================================================================

@test "acquire_lock function exists" {
    run type acquire_lock
    [ "$status" -eq 0 ]
}

@test "release_lock function exists" {
    run type release_lock
    [ "$status" -eq 0 ]
}

# ============================================================================
# Temp Directory Tests
# ============================================================================

@test "create_temp_dir function exists" {
    run type create_temp_dir
    [ "$status" -eq 0 ]
}

# ============================================================================
# Config Tests
# ============================================================================

@test "load_config function exists" {
    run type load_config
    [ "$status" -eq 0 ]
}

# ============================================================================
# Rollback Tests
# ============================================================================

@test "execute_rollback function exists" {
    run type execute_rollback
    [ "$status" -eq 0 ]
}

# ============================================================================
# Validation Tests
# ============================================================================

@test "validate_input function exists" {
    run type validate_input
    [ "$status" -eq 0 ]
}

@test "check_requirements function exists" {
    run type check_requirements
    [ "$status" -eq 0 ]
}

@test "validate_version function exists" {
    run type validate_version
    [ "$status" -eq 0 ]
}

@test "validate_version accepts valid semver" {
    run validate_version "v1.0.0"
    [ "$status" -eq 0 ]
}

@test "validate_version accepts version without v prefix" {
    run validate_version "1.15.0"
    [ "$status" -eq 0 ]
}

@test "validate_url function exists" {
    run type validate_url
    [ "$status" -eq 0 ]
}

@test "validate_url accepts https URL" {
    run validate_url "https://example.com/file.tar.gz"
    [ "$status" -eq 0 ]
}

@test "validate_url accepts http URL" {
    run validate_url "http://example.com/file.tar.gz"
    [ "$status" -eq 0 ]
}

# ============================================================================
# Version Comparison Tests
# ============================================================================

@test "version_compare function exists" {
    run type version_compare
    [ "$status" -eq 0 ]
}

@test "version_compare: 1.0.0 < 2.0.0" {
    run version_compare "1.0.0" "2.0.0"
    [ "$status" -eq 0 ]
    [ "$output" = "-1" ]
}

@test "version_compare: 2.0.0 > 1.0.0" {
    run version_compare "2.0.0" "1.0.0"
    [ "$status" -eq 0 ]
    [ "$output" = "1" ]
}

@test "version_compare: 1.0.0 = 1.0.0" {
    run version_compare "1.0.0" "1.0.0"
    [ "$status" -eq 0 ]
    [ "$output" = "0" ]
}

@test "version_compare: 1.10.0 > 1.9.0" {
    run version_compare "1.10.0" "1.9.0"
    [ "$status" -eq 0 ]
    [ "$output" = "1" ]
}

@test "version_compare: 1.0.10 > 1.0.9" {
    run version_compare "1.0.10" "1.0.9"
    [ "$status" -eq 0 ]
    [ "$output" = "1" ]
}

# ============================================================================
# Checksum Tests
# ============================================================================

@test "verify_checksum function exists" {
    run type verify_checksum
    [ "$status" -eq 0 ]
}

# ============================================================================
# Platform Detection Tests
# ============================================================================

@test "detect_platform function exists" {
    run type detect_platform
    [ "$status" -eq 0 ]
}

@test "detect_platform runs without error" {
    run detect_platform
    [ "$status" -eq 0 ]
}

@test "detect_platform sets PLATFORM variable" {
    detect_platform
    [ -n "$PLATFORM" ]
}

@test "detect_platform sets ARCH variable" {
    detect_platform
    [ -n "$ARCH" ]
}

# ============================================================================
# Download Tests
# ============================================================================

@test "download_file function exists" {
    run type download_file
    [ "$status" -eq 0 ]
}

# ============================================================================
# GitHub Release Tests
# ============================================================================

@test "parse_github_release function exists" {
    run type parse_github_release
    [ "$status" -eq 0 ]
}

@test "get_release_info function exists" {
    run type get_release_info
    [ "$status" -eq 0 ]
}

# ============================================================================
# Management Mode Tests
# ============================================================================

@test "detect_management_mode function exists" {
    run type detect_management_mode
    [ "$status" -eq 0 ]
}

@test "find_stream_manager function exists" {
    run type find_stream_manager
    [ "$status" -eq 0 ]
}

# ============================================================================
# Asset URL Tests
# ============================================================================

@test "build_asset_url function exists" {
    run type build_asset_url
    [ "$status" -eq 0 ]
}

# ============================================================================
# Download MediaMTX Tests
# ============================================================================

@test "download_mediamtx function exists" {
    run type download_mediamtx
    [ "$status" -eq 0 ]
}

# ============================================================================
# Config Creation Tests
# ============================================================================

@test "create_config function exists" {
    run type create_config
    [ "$status" -eq 0 ]
}

# ============================================================================
# Service Creation Tests
# ============================================================================

@test "create_service function exists" {
    run type create_service
    [ "$status" -eq 0 ]
}

@test "create_user function exists" {
    run type create_user
    [ "$status" -eq 0 ]
}

# ============================================================================
# Install/Update/Uninstall Tests
# ============================================================================

@test "install_mediamtx function exists" {
    run type install_mediamtx
    [ "$status" -eq 0 ]
}

@test "update_mediamtx function exists" {
    run type update_mediamtx
    [ "$status" -eq 0 ]
}

@test "uninstall_mediamtx function exists" {
    run type uninstall_mediamtx
    [ "$status" -eq 0 ]
}

# ============================================================================
# Service Control Tests
# ============================================================================

@test "stop_mediamtx function exists" {
    run type stop_mediamtx
    [ "$status" -eq 0 ]
}

@test "start_mediamtx function exists" {
    run type start_mediamtx
    [ "$status" -eq 0 ]
}

# ============================================================================
# Status and Verification Tests
# ============================================================================

@test "show_status function exists" {
    run type show_status
    [ "$status" -eq 0 ]
}

@test "verify_installation function exists" {
    run type verify_installation
    [ "$status" -eq 0 ]
}

# ============================================================================
# Guidance Tests
# ============================================================================

@test "show_post_install_guidance function exists" {
    run type show_post_install_guidance
    [ "$status" -eq 0 ]
}

@test "show_post_update_guidance function exists" {
    run type show_post_update_guidance
    [ "$status" -eq 0 ]
}

# ============================================================================
# Help and Parse Tests
# ============================================================================

@test "show_help function exists" {
    run type show_help
    [ "$status" -eq 0 ]
}

@test "show_help outputs usage" {
    run show_help
    [ "$status" -eq 0 ]
    [[ "$output" =~ "install" ]] || [[ "$output" =~ "INSTALL" ]]
}

@test "parse_arguments function exists" {
    run type parse_arguments
    [ "$status" -eq 0 ]
}

@test "main function exists" {
    run type main
    [ "$status" -eq 0 ]
}

# ============================================================================
# Default Configuration Tests
# ============================================================================

@test "DEFAULT_INSTALL_PREFIX is defined" {
    [ -n "$DEFAULT_INSTALL_PREFIX" ]
}

@test "MEDIAMTX_USER is defined" {
    [ -n "$MEDIAMTX_USER" ]
}

@test "MEDIAMTX_GROUP is defined" {
    [ -n "$MEDIAMTX_GROUP" ]
}
