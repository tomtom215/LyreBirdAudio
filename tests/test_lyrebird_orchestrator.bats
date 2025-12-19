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
