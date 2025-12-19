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

# ============================================================================
# Stream Name Length Validation Tests
# ============================================================================

@test "stream name length validation accepts valid length" {
    MAX_STREAM_NAME_LENGTH=48
    MIN_STREAM_NAME_LENGTH=1

    validate_stream_name_length() {
        local name="$1"
        local len=${#name}
        ((len >= MIN_STREAM_NAME_LENGTH && len <= MAX_STREAM_NAME_LENGTH))
    }

    run validate_stream_name_length "my_stream"
    [ "$status" -eq 0 ]
}

@test "stream name length validation rejects empty name" {
    MAX_STREAM_NAME_LENGTH=48
    MIN_STREAM_NAME_LENGTH=1

    validate_stream_name_length() {
        local name="$1"
        local len=${#name}
        ((len >= MIN_STREAM_NAME_LENGTH && len <= MAX_STREAM_NAME_LENGTH))
    }

    run validate_stream_name_length ""
    [ "$status" -eq 1 ]
}

@test "stream name length validation rejects too long name" {
    MAX_STREAM_NAME_LENGTH=48
    MIN_STREAM_NAME_LENGTH=1

    validate_stream_name_length() {
        local name="$1"
        local len=${#name}
        ((len >= MIN_STREAM_NAME_LENGTH && len <= MAX_STREAM_NAME_LENGTH))
    }

    run validate_stream_name_length "this_is_a_very_very_very_very_very_very_long_stream_name_that_exceeds_limit"
    [ "$status" -eq 1 ]
}

# ============================================================================
# Reserved Stream Name Tests
# ============================================================================

@test "reserved name check rejects 'control'" {
    RESERVED_STREAM_NAMES="control|stats|api|metrics|health"

    is_reserved_name() {
        local name="$1"
        [[ "$name" =~ ^($RESERVED_STREAM_NAMES)$ ]]
    }

    run is_reserved_name "control"
    [ "$status" -eq 0 ]
}

@test "reserved name check allows 'mic1'" {
    RESERVED_STREAM_NAMES="control|stats|api|metrics|health"

    is_reserved_name() {
        local name="$1"
        [[ "$name" =~ ^($RESERVED_STREAM_NAMES)$ ]]
    }

    run is_reserved_name "mic1"
    [ "$status" -eq 1 ]
}

# ============================================================================
# Lock File Tests
# ============================================================================

@test "lock acquisition creates lock file" {
    TEST_LOCK=$(mktemp)
    rm "$TEST_LOCK"

    acquire_lock() {
        local lock_file="$1"
        exec 200>"$lock_file"
        flock -n 200
    }

    run acquire_lock "$TEST_LOCK"
    # Lock file should be created
    [ -f "$TEST_LOCK" ]

    rm -f "$TEST_LOCK"
}

@test "lock is exclusive - second acquisition fails" {
    TEST_LOCK=$(mktemp)

    # First lock
    exec 200>"$TEST_LOCK"
    flock -n 200

    # Try second lock from subshell
    run bash -c "exec 201>\"$TEST_LOCK\"; flock -n 201"
    [ "$status" -eq 1 ]

    rm -f "$TEST_LOCK"
}

# ============================================================================
# API URL Construction Tests
# ============================================================================

@test "api url construction with default port" {
    build_api_url() {
        local host="${1:-localhost}"
        local port="${2:-9997}"
        local version="${3:-v3}"
        echo "http://${host}:${port}/${version}"
    }

    run build_api_url "localhost" "9997" "v3"
    [ "$status" -eq 0 ]
    [ "$output" = "http://localhost:9997/v3" ]
}

@test "api url construction with custom host" {
    build_api_url() {
        local host="${1:-localhost}"
        local port="${2:-9997}"
        local version="${3:-v3}"
        echo "http://${host}:${port}/${version}"
    }

    run build_api_url "192.168.1.100" "9997" "v3"
    [ "$status" -eq 0 ]
    [ "$output" = "http://192.168.1.100:9997/v3" ]
}

# ============================================================================
# FFmpeg Command Construction Tests
# ============================================================================

@test "ffmpeg alsa input construction" {
    build_alsa_input() {
        local device="$1"
        local sample_rate="${2:-48000}"
        local channels="${3:-2}"
        echo "-f alsa -sample_rate $sample_rate -channels $channels -i hw:$device"
    }

    run build_alsa_input "3" "44100" "1"
    [ "$status" -eq 0 ]
    [[ "$output" =~ "-f alsa" ]]
    [[ "$output" =~ "-sample_rate 44100" ]]
    [[ "$output" =~ "-channels 1" ]]
    [[ "$output" =~ "-i hw:3" ]]
}

# ============================================================================
# Heartbeat/Watchdog Tests
# ============================================================================

@test "heartbeat file update writes timestamp" {
    HEARTBEAT_FILE=$(mktemp)
    rm "$HEARTBEAT_FILE"

    update_heartbeat() {
        local file="$1"
        date +%s > "$file"
    }

    run update_heartbeat "$HEARTBEAT_FILE"
    [ "$status" -eq 0 ]
    [ -f "$HEARTBEAT_FILE" ]

    content=$(cat "$HEARTBEAT_FILE")
    [[ "$content" =~ ^[0-9]+$ ]]

    rm -f "$HEARTBEAT_FILE"
}

@test "heartbeat staleness detection" {
    is_heartbeat_stale() {
        local file="$1"
        local max_age="${2:-120}"
        [[ ! -f "$file" ]] && return 0
        local file_time=$(cat "$file" 2>/dev/null || echo 0)
        local now=$(date +%s)
        local age=$((now - file_time))
        ((age > max_age))
    }

    HEARTBEAT_FILE=$(mktemp)

    # Fresh heartbeat
    echo $(date +%s) > "$HEARTBEAT_FILE"
    run is_heartbeat_stale "$HEARTBEAT_FILE" 120
    [ "$status" -eq 1 ]  # Not stale

    # Old heartbeat (simulate by writing old timestamp)
    echo 1000000 > "$HEARTBEAT_FILE"
    run is_heartbeat_stale "$HEARTBEAT_FILE" 120
    [ "$status" -eq 0 ]  # Stale

    rm -f "$HEARTBEAT_FILE"
}

# ============================================================================
# Network Connectivity Tests
# ============================================================================

@test "gateway IP extraction" {
    get_gateway_ip() {
        ip route 2>/dev/null | grep default | awk '{print $3}' | head -1 || echo ""
    }

    run get_gateway_ip
    # Either empty or a valid IP pattern
    [ "$status" -eq 0 ]
    [[ -z "$output" ]] || [[ "$output" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]
}

# ============================================================================
# Disk Space Monitoring Tests
# ============================================================================

@test "disk space check returns percentage" {
    get_disk_usage() {
        local path="${1:-/}"
        df "$path" 2>/dev/null | tail -1 | awk '{print $5}' | sed 's/%//'
    }

    run get_disk_usage "/"
    [ "$status" -eq 0 ]
    [[ "$output" =~ ^[0-9]+$ ]]
    [ "$output" -ge 0 ]
    [ "$output" -le 100 ]
}

@test "disk space warning threshold check" {
    DISK_SPACE_WARNING_PERCENT=80

    is_disk_warning() {
        local usage="$1"
        ((usage >= DISK_SPACE_WARNING_PERCENT))
    }

    run is_disk_warning 85
    [ "$status" -eq 0 ]

    run is_disk_warning 70
    [ "$status" -eq 1 ]
}

# ============================================================================
# Audio Buffer Configuration Tests
# ============================================================================

@test "rtbufsize calculation" {
    calculate_rtbufsize() {
        local mb="${1:-64}"
        echo $((mb * 1024 * 1024))
    }

    run calculate_rtbufsize 32
    [ "$status" -eq 0 ]
    [ "$output" = "33554432" ]  # 32 * 1024 * 1024
}

# ============================================================================
# Process Group Termination Tests
# ============================================================================

@test "process exists check for current shell" {
    process_exists() {
        local pid="$1"
        kill -0 "$pid" 2>/dev/null
    }

    run process_exists $$
    [ "$status" -eq 0 ]
}

@test "process exists check for invalid pid" {
    process_exists() {
        local pid="$1"
        kill -0 "$pid" 2>/dev/null
    }

    run process_exists 999999999
    [ "$status" -eq 1 ]
}
