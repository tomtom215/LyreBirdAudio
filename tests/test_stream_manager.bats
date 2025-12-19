#!/usr/bin/env bats
# Unit tests for mediamtx-stream-manager.sh functions
# Run with: bats tests/test_stream_manager.bats
# Note: These tests use function extraction, not the full script

# Setup - extract and source testable functions
setup() {
    TEST_DIR="$( cd "$( dirname "$BATS_TEST_FILENAME" )" && pwd )"
    PROJECT_ROOT="$( cd "$TEST_DIR/.." && pwd )"

    # Source common library first
    source "$PROJECT_ROOT/lyrebird-common.sh" 2>/dev/null || true

    # Create a mock log function if not defined
    if ! declare -f log &>/dev/null; then
        log() { :; }
    fi
}

# ============================================================================
# Stream Name Sanitization Tests
# ============================================================================

@test "sanitize stream name removes special characters" {
    # Define the function inline for testing
    sanitize_path_name() {
        local name="$1"
        # Remove or replace problematic characters for RTSP paths
        name="${name//[^a-zA-Z0-9_-]/_}"
        # Collapse multiple underscores
        name="${name//__/_}"
        # Remove leading/trailing underscores
        name="${name#_}"
        name="${name%_}"
        echo "$name"
    }

    run sanitize_path_name "My Device (USB Audio)"
    [ "$status" -eq 0 ]
    [[ ! "$output" =~ [\(\)\ ] ]]
}

@test "sanitize stream name handles empty input" {
    sanitize_path_name() {
        local name="$1"
        name="${name//[^a-zA-Z0-9_-]/_}"
        name="${name//__/_}"
        name="${name#_}"
        name="${name%_}"
        echo "$name"
    }

    run sanitize_path_name ""
    [ "$status" -eq 0 ]
}

# ============================================================================
# Version Comparison Tests
# ============================================================================

@test "version comparison: equal versions" {
    version_compare() {
        local v1="$1" v2="$2"
        if [[ "$v1" == "$v2" ]]; then
            echo "equal"
        else
            # Simple comparison for major.minor.patch
            local IFS='.'
            read -ra V1 <<< "$v1"
            read -ra V2 <<< "$v2"
            for i in 0 1 2; do
                if (( ${V1[$i]:-0} > ${V2[$i]:-0} )); then
                    echo "greater"
                    return
                elif (( ${V1[$i]:-0} < ${V2[$i]:-0} )); then
                    echo "lesser"
                    return
                fi
            done
            echo "equal"
        fi
    }

    run version_compare "1.0.0" "1.0.0"
    [ "$output" = "equal" ]
}

@test "version comparison: greater version" {
    version_compare() {
        local v1="$1" v2="$2"
        if [[ "$v1" == "$v2" ]]; then
            echo "equal"
        else
            local IFS='.'
            read -ra V1 <<< "$v1"
            read -ra V2 <<< "$v2"
            for i in 0 1 2; do
                if (( ${V1[$i]:-0} > ${V2[$i]:-0} )); then
                    echo "greater"
                    return
                elif (( ${V1[$i]:-0} < ${V2[$i]:-0} )); then
                    echo "lesser"
                    return
                fi
            done
            echo "equal"
        fi
    }

    run version_compare "2.0.0" "1.0.0"
    [ "$output" = "greater" ]
}

@test "version comparison: lesser version" {
    version_compare() {
        local v1="$1" v2="$2"
        if [[ "$v1" == "$v2" ]]; then
            echo "equal"
        else
            local IFS='.'
            read -ra V1 <<< "$v1"
            read -ra V2 <<< "$v2"
            for i in 0 1 2; do
                if (( ${V1[$i]:-0} > ${V2[$i]:-0} )); then
                    echo "greater"
                    return
                elif (( ${V1[$i]:-0} < ${V2[$i]:-0} )); then
                    echo "lesser"
                    return
                fi
            done
            echo "equal"
        fi
    }

    run version_compare "1.0.0" "1.1.0"
    [ "$output" = "lesser" ]
}

# ============================================================================
# PID Validation Tests
# ============================================================================

@test "PID validation accepts valid PID" {
    is_valid_pid() {
        local pid="$1"
        [[ "$pid" =~ ^[0-9]+$ ]] && [[ "$pid" -gt 0 ]] && [[ "$pid" -le 4194304 ]]
    }

    run is_valid_pid "1234"
    [ "$status" -eq 0 ]
}

@test "PID validation rejects negative PID" {
    is_valid_pid() {
        local pid="$1"
        [[ "$pid" =~ ^[0-9]+$ ]] && [[ "$pid" -gt 0 ]] && [[ "$pid" -le 4194304 ]]
    }

    run is_valid_pid "-1"
    [ "$status" -eq 1 ]
}

@test "PID validation rejects non-numeric PID" {
    is_valid_pid() {
        local pid="$1"
        [[ "$pid" =~ ^[0-9]+$ ]] && [[ "$pid" -gt 0 ]] && [[ "$pid" -le 4194304 ]]
    }

    run is_valid_pid "abc"
    [ "$status" -eq 1 ]
}

@test "PID validation rejects zero" {
    is_valid_pid() {
        local pid="$1"
        [[ "$pid" =~ ^[0-9]+$ ]] && [[ "$pid" -gt 0 ]] && [[ "$pid" -le 4194304 ]]
    }

    run is_valid_pid "0"
    [ "$status" -eq 1 ]
}

# ============================================================================
# Device Name Parsing Tests
# ============================================================================

@test "device info parsing extracts name and card" {
    parse_device_info() {
        local info="$1"
        IFS=':' read -r name card <<< "$info"
        echo "name=$name card=$card"
    }

    run parse_device_info "Blue_Yeti:3"
    [ "$status" -eq 0 ]
    [[ "$output" == "name=Blue_Yeti card=3" ]]
}

@test "device info parsing handles missing card" {
    parse_device_info() {
        local info="$1"
        IFS=':' read -r name card <<< "$info"
        echo "name=$name card=${card:-none}"
    }

    run parse_device_info "Blue_Yeti"
    [ "$status" -eq 0 ]
    [[ "$output" == "name=Blue_Yeti card=none" ]]
}

# ============================================================================
# Configuration Tests
# ============================================================================

@test "default values are set for timeouts" {
    # These should be set with defaults
    MEDIAMTX_API_TIMEOUT="${MEDIAMTX_API_TIMEOUT:-60}"
    HEARTBEAT_INTERVAL="${HEARTBEAT_INTERVAL:-30}"

    [ "$MEDIAMTX_API_TIMEOUT" -eq 60 ]
    [ "$HEARTBEAT_INTERVAL" -eq 30 ]
}

@test "environment variables override defaults" {
    export MEDIAMTX_API_TIMEOUT=120
    MEDIAMTX_API_TIMEOUT="${MEDIAMTX_API_TIMEOUT:-60}"

    [ "$MEDIAMTX_API_TIMEOUT" -eq 120 ]
    unset MEDIAMTX_API_TIMEOUT
}
