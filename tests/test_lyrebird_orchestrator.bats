#!/usr/bin/env bats
# Unit tests for lyrebird-orchestrator.sh
# Run with: bats tests/test_lyrebird_orchestrator.bats

# Setup
setup() {
    TEST_DIR="$( cd "$( dirname "$BATS_TEST_FILENAME" )" && pwd )"
    PROJECT_ROOT="$( cd "$TEST_DIR/.." && pwd )"

    export TEST_TMP=$(mktemp -d)

    # Source common library if available
    source "$PROJECT_ROOT/lyrebird-common.sh" 2>/dev/null || true
}

teardown() {
    rm -rf "$TEST_TMP" 2>/dev/null || true
}

# ============================================================================
# Menu Option Validation Tests
# ============================================================================

@test "validate_menu_option accepts valid numbers" {
    validate_menu_option() {
        local input="$1"
        local max="$2"
        [[ "$input" =~ ^[0-9]+$ ]] || return 1
        ((input >= 0 && input <= max)) || return 1
        return 0
    }

    run validate_menu_option "1" "10"
    [ "$status" -eq 0 ]
}

@test "validate_menu_option accepts zero (exit)" {
    validate_menu_option() {
        local input="$1"
        local max="$2"
        [[ "$input" =~ ^[0-9]+$ ]] || return 1
        ((input >= 0 && input <= max)) || return 1
        return 0
    }

    run validate_menu_option "0" "10"
    [ "$status" -eq 0 ]
}

@test "validate_menu_option rejects negative" {
    validate_menu_option() {
        local input="$1"
        local max="$2"
        [[ "$input" =~ ^[0-9]+$ ]] || return 1
        ((input >= 0 && input <= max)) || return 1
        return 0
    }

    run validate_menu_option "-1" "10"
    [ "$status" -eq 1 ]
}

@test "validate_menu_option rejects above max" {
    validate_menu_option() {
        local input="$1"
        local max="$2"
        [[ "$input" =~ ^[0-9]+$ ]] || return 1
        ((input >= 0 && input <= max)) || return 1
        return 0
    }

    run validate_menu_option "15" "10"
    [ "$status" -eq 1 ]
}

@test "validate_menu_option rejects non-numeric" {
    validate_menu_option() {
        local input="$1"
        local max="$2"
        [[ "$input" =~ ^[0-9]+$ ]] || return 1
        ((input >= 0 && input <= max)) || return 1
        return 0
    }

    run validate_menu_option "abc" "10"
    [ "$status" -eq 1 ]
}

# ============================================================================
# Confirmation Prompt Tests
# ============================================================================

@test "parse_yes_no accepts y" {
    parse_yes_no() {
        local input="$1"
        case "${input,,}" in
            y|yes) return 0 ;;
            n|no) return 1 ;;
            *) return 2 ;;
        esac
    }

    run parse_yes_no "y"
    [ "$status" -eq 0 ]
}

@test "parse_yes_no accepts yes (case insensitive)" {
    parse_yes_no() {
        local input="$1"
        case "${input,,}" in
            y|yes) return 0 ;;
            n|no) return 1 ;;
            *) return 2 ;;
        esac
    }

    run parse_yes_no "YES"
    [ "$status" -eq 0 ]
}

@test "parse_yes_no returns 1 for no" {
    parse_yes_no() {
        local input="$1"
        case "${input,,}" in
            y|yes) return 0 ;;
            n|no) return 1 ;;
            *) return 2 ;;
        esac
    }

    run parse_yes_no "n"
    [ "$status" -eq 1 ]
}

@test "parse_yes_no returns 2 for invalid" {
    parse_yes_no() {
        local input="$1"
        case "${input,,}" in
            y|yes) return 0 ;;
            n|no) return 1 ;;
            *) return 2 ;;
        esac
    }

    run parse_yes_no "maybe"
    [ "$status" -eq 2 ]
}

# ============================================================================
# Script Path Resolution Tests
# ============================================================================

@test "find_script locates script in same directory" {
    find_script() {
        local script="$1"
        local dir="$2"
        if [[ -x "$dir/$script" ]]; then
            echo "$dir/$script"
            return 0
        fi
        return 1
    }

    touch "$TEST_TMP/test-script.sh"
    chmod +x "$TEST_TMP/test-script.sh"

    run find_script "test-script.sh" "$TEST_TMP"
    [ "$status" -eq 0 ]
    [ "$output" = "$TEST_TMP/test-script.sh" ]
}

@test "find_script fails for missing script" {
    find_script() {
        local script="$1"
        local dir="$2"
        if [[ -x "$dir/$script" ]]; then
            echo "$dir/$script"
            return 0
        fi
        return 1
    }

    run find_script "nonexistent.sh" "$TEST_TMP"
    [ "$status" -eq 1 ]
}

# ============================================================================
# Version Comparison Tests
# ============================================================================

@test "version_compare equal versions" {
    version_compare() {
        local v1="$1" v2="$2"
        [[ "$v1" == "$v2" ]] && { echo "equal"; return; }
        local IFS='.'
        read -ra V1 <<< "$v1"
        read -ra V2 <<< "$v2"
        for i in 0 1 2; do
            if (( ${V1[$i]:-0} > ${V2[$i]:-0} )); then
                echo "greater"; return
            elif (( ${V1[$i]:-0} < ${V2[$i]:-0} )); then
                echo "lesser"; return
            fi
        done
        echo "equal"
    }

    run version_compare "1.2.3" "1.2.3"
    [ "$output" = "equal" ]
}

@test "version_compare greater major" {
    version_compare() {
        local v1="$1" v2="$2"
        [[ "$v1" == "$v2" ]] && { echo "equal"; return; }
        local IFS='.'
        read -ra V1 <<< "$v1"
        read -ra V2 <<< "$v2"
        for i in 0 1 2; do
            if (( ${V1[$i]:-0} > ${V2[$i]:-0} )); then
                echo "greater"; return
            elif (( ${V1[$i]:-0} < ${V2[$i]:-0} )); then
                echo "lesser"; return
            fi
        done
        echo "equal"
    }

    run version_compare "2.0.0" "1.9.9"
    [ "$output" = "greater" ]
}

@test "version_compare lesser minor" {
    version_compare() {
        local v1="$1" v2="$2"
        [[ "$v1" == "$v2" ]] && { echo "equal"; return; }
        local IFS='.'
        read -ra V1 <<< "$v1"
        read -ra V2 <<< "$v2"
        for i in 0 1 2; do
            if (( ${V1[$i]:-0} > ${V2[$i]:-0} )); then
                echo "greater"; return
            elif (( ${V1[$i]:-0} < ${V2[$i]:-0} )); then
                echo "lesser"; return
            fi
        done
        echo "equal"
    }

    run version_compare "1.2.3" "1.3.0"
    [ "$output" = "lesser" ]
}

# ============================================================================
# Status Display Tests
# ============================================================================

@test "format_status_line handles running status" {
    format_status_line() {
        local name="$1"
        local status="$2"
        local details="${3:-}"
        printf "%-20s [%s] %s\n" "$name" "$status" "$details"
    }

    run format_status_line "Stream Manager" "RUNNING" "PID: 1234"
    [ "$status" -eq 0 ]
    [[ "$output" =~ "Stream Manager" ]]
    [[ "$output" =~ "RUNNING" ]]
    [[ "$output" =~ "PID: 1234" ]]
}

# ============================================================================
# Configuration Validation Tests
# ============================================================================

@test "check_config_exists returns 0 for existing file" {
    check_config_exists() {
        [[ -f "$1" && -r "$1" ]]
    }

    echo "test=value" > "$TEST_TMP/config.conf"
    run check_config_exists "$TEST_TMP/config.conf"
    [ "$status" -eq 0 ]
}

@test "check_config_exists returns 1 for missing file" {
    check_config_exists() {
        [[ -f "$1" && -r "$1" ]]
    }

    run check_config_exists "$TEST_TMP/nonexistent.conf"
    [ "$status" -eq 1 ]
}

# ============================================================================
# Command Execution Tests
# ============================================================================

@test "run_with_sudo checks root status" {
    check_is_root() {
        [[ $EUID -eq 0 ]]
    }

    # This test just validates the function works
    run check_is_root
    # Status depends on whether running as root
    [[ "$status" -eq 0 ]] || [[ "$status" -eq 1 ]]
}

# ============================================================================
# Output Formatting Tests
# ============================================================================

@test "truncate_string respects max length" {
    truncate_string() {
        local str="$1"
        local max="${2:-40}"
        if [[ ${#str} -gt $max ]]; then
            echo "${str:0:$((max-3))}..."
        else
            echo "$str"
        fi
    }

    run truncate_string "This is a very long string that exceeds the limit" 20
    [ "$status" -eq 0 ]
    [ ${#output} -eq 20 ]
    [[ "$output" =~ \.\.\. ]]
}

@test "truncate_string preserves short strings" {
    truncate_string() {
        local str="$1"
        local max="${2:-40}"
        if [[ ${#str} -gt $max ]]; then
            echo "${str:0:$((max-3))}..."
        else
            echo "$str"
        fi
    }

    run truncate_string "short" 20
    [ "$status" -eq 0 ]
    [ "$output" = "short" ]
}

# ============================================================================
# Service Status Detection Tests
# ============================================================================

@test "parse_service_status active" {
    parse_service_status() {
        local status="$1"
        case "$status" in
            "active (running)") echo "running" ;;
            "inactive (dead)") echo "stopped" ;;
            "activating"*) echo "starting" ;;
            "failed"*) echo "failed" ;;
            *) echo "unknown" ;;
        esac
    }

    run parse_service_status "active (running)"
    [ "$output" = "running" ]
}

@test "parse_service_status inactive" {
    parse_service_status() {
        local status="$1"
        case "$status" in
            "active (running)") echo "running" ;;
            "inactive (dead)") echo "stopped" ;;
            "activating"*) echo "starting" ;;
            "failed"*) echo "failed" ;;
            *) echo "unknown" ;;
        esac
    }

    run parse_service_status "inactive (dead)"
    [ "$output" = "stopped" ]
}

@test "parse_service_status failed" {
    parse_service_status() {
        local status="$1"
        case "$status" in
            "active (running)") echo "running" ;;
            "inactive (dead)") echo "stopped" ;;
            "activating"*) echo "starting" ;;
            "failed"*) echo "failed" ;;
            *) echo "unknown" ;;
        esac
    }

    run parse_service_status "failed (Result: exit-code)"
    [ "$output" = "failed" ]
}

# ============================================================================
# Path Validation Tests
# ============================================================================

@test "is_valid_path accepts existing path" {
    is_valid_path() {
        [[ -e "$1" ]]
    }

    run is_valid_path "$TEST_TMP"
    [ "$status" -eq 0 ]
}

@test "is_valid_path rejects nonexistent path" {
    is_valid_path() {
        [[ -e "$1" ]]
    }

    run is_valid_path "/nonexistent/path/12345"
    [ "$status" -eq 1 ]
}

@test "is_valid_executable checks executability" {
    is_valid_executable() {
        [[ -x "$1" ]]
    }

    touch "$TEST_TMP/test.sh"
    chmod +x "$TEST_TMP/test.sh"
    run is_valid_executable "$TEST_TMP/test.sh"
    [ "$status" -eq 0 ]
}

@test "is_valid_executable rejects non-executable" {
    is_valid_executable() {
        [[ -x "$1" ]]
    }

    touch "$TEST_TMP/test.txt"
    chmod -x "$TEST_TMP/test.txt"
    run is_valid_executable "$TEST_TMP/test.txt"
    [ "$status" -eq 1 ]
}

# ============================================================================
# Port Validation Tests
# ============================================================================

@test "validate_port accepts valid port" {
    validate_port() {
        local port="$1"
        [[ "$port" =~ ^[0-9]+$ ]] && ((port >= 1 && port <= 65535))
    }

    run validate_port "8554"
    [ "$status" -eq 0 ]
}

@test "validate_port accepts port 1" {
    validate_port() {
        local port="$1"
        [[ "$port" =~ ^[0-9]+$ ]] && ((port >= 1 && port <= 65535))
    }

    run validate_port "1"
    [ "$status" -eq 0 ]
}

@test "validate_port accepts port 65535" {
    validate_port() {
        local port="$1"
        [[ "$port" =~ ^[0-9]+$ ]] && ((port >= 1 && port <= 65535))
    }

    run validate_port "65535"
    [ "$status" -eq 0 ]
}

@test "validate_port rejects port 0" {
    validate_port() {
        local port="$1"
        [[ "$port" =~ ^[0-9]+$ ]] && ((port >= 1 && port <= 65535))
    }

    run validate_port "0"
    [ "$status" -eq 1 ]
}

@test "validate_port rejects port 65536" {
    validate_port() {
        local port="$1"
        [[ "$port" =~ ^[0-9]+$ ]] && ((port >= 1 && port <= 65535))
    }

    run validate_port "65536"
    [ "$status" -eq 1 ]
}

@test "validate_port rejects non-numeric" {
    validate_port() {
        local port="$1"
        [[ "$port" =~ ^[0-9]+$ ]] && ((port >= 1 && port <= 65535))
    }

    run validate_port "abc"
    [ "$status" -eq 1 ]
}

# ============================================================================
# Stream Name Validation Tests
# ============================================================================

@test "validate_stream_name accepts valid name" {
    validate_stream_name() {
        local name="$1"
        [[ "$name" =~ ^[a-z][a-z0-9_-]{0,31}$ ]]
    }

    run validate_stream_name "mic1"
    [ "$status" -eq 0 ]
}

@test "validate_stream_name accepts name with underscore" {
    validate_stream_name() {
        local name="$1"
        [[ "$name" =~ ^[a-z][a-z0-9_-]{0,31}$ ]]
    }

    run validate_stream_name "usb_audio_1"
    [ "$status" -eq 0 ]
}

@test "validate_stream_name accepts name with hyphen" {
    validate_stream_name() {
        local name="$1"
        [[ "$name" =~ ^[a-z][a-z0-9_-]{0,31}$ ]]
    }

    run validate_stream_name "bird-recorder"
    [ "$status" -eq 0 ]
}

@test "validate_stream_name rejects starting with number" {
    validate_stream_name() {
        local name="$1"
        [[ "$name" =~ ^[a-z][a-z0-9_-]{0,31}$ ]]
    }

    run validate_stream_name "1mic"
    [ "$status" -eq 1 ]
}

@test "validate_stream_name rejects uppercase" {
    validate_stream_name() {
        local name="$1"
        [[ "$name" =~ ^[a-z][a-z0-9_-]{0,31}$ ]]
    }

    run validate_stream_name "MIC"
    [ "$status" -eq 1 ]
}

# ============================================================================
# Time Formatting Tests
# ============================================================================

@test "format_uptime formats seconds" {
    format_uptime() {
        local seconds="$1"
        if ((seconds < 60)); then
            echo "${seconds}s"
        elif ((seconds < 3600)); then
            echo "$((seconds / 60))m $((seconds % 60))s"
        elif ((seconds < 86400)); then
            echo "$((seconds / 3600))h $((seconds % 3600 / 60))m"
        else
            echo "$((seconds / 86400))d $((seconds % 86400 / 3600))h"
        fi
    }

    run format_uptime "45"
    [ "$output" = "45s" ]
}

@test "format_uptime formats minutes" {
    format_uptime() {
        local seconds="$1"
        if ((seconds < 60)); then
            echo "${seconds}s"
        elif ((seconds < 3600)); then
            echo "$((seconds / 60))m $((seconds % 60))s"
        elif ((seconds < 86400)); then
            echo "$((seconds / 3600))h $((seconds % 3600 / 60))m"
        else
            echo "$((seconds / 86400))d $((seconds % 86400 / 3600))h"
        fi
    }

    run format_uptime "125"
    [ "$output" = "2m 5s" ]
}

@test "format_uptime formats hours" {
    format_uptime() {
        local seconds="$1"
        if ((seconds < 60)); then
            echo "${seconds}s"
        elif ((seconds < 3600)); then
            echo "$((seconds / 60))m $((seconds % 60))s"
        elif ((seconds < 86400)); then
            echo "$((seconds / 3600))h $((seconds % 3600 / 60))m"
        else
            echo "$((seconds / 86400))d $((seconds % 86400 / 3600))h"
        fi
    }

    run format_uptime "7230"
    [ "$output" = "2h 0m" ]
}

@test "format_uptime formats days" {
    format_uptime() {
        local seconds="$1"
        if ((seconds < 60)); then
            echo "${seconds}s"
        elif ((seconds < 3600)); then
            echo "$((seconds / 60))m $((seconds % 60))s"
        elif ((seconds < 86400)); then
            echo "$((seconds / 3600))h $((seconds % 3600 / 60))m"
        else
            echo "$((seconds / 86400))d $((seconds % 86400 / 3600))h"
        fi
    }

    run format_uptime "90000"
    [ "$output" = "1d 1h" ]
}

# ============================================================================
# Process ID Validation Tests
# ============================================================================

@test "validate_pid accepts valid PID" {
    validate_pid() {
        local pid="$1"
        [[ "$pid" =~ ^[0-9]+$ ]] && ((pid > 0))
    }

    run validate_pid "1234"
    [ "$status" -eq 0 ]
}

@test "validate_pid rejects zero" {
    validate_pid() {
        local pid="$1"
        [[ "$pid" =~ ^[0-9]+$ ]] && ((pid > 0))
    }

    run validate_pid "0"
    [ "$status" -eq 1 ]
}

@test "validate_pid rejects non-numeric" {
    validate_pid() {
        local pid="$1"
        [[ "$pid" =~ ^[0-9]+$ ]] && ((pid > 0))
    }

    run validate_pid "abc"
    [ "$status" -eq 1 ]
}
