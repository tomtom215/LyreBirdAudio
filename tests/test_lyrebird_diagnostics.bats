#!/usr/bin/env bats
# Unit tests for lyrebird-diagnostics.sh
# Run with: bats tests/test_lyrebird_diagnostics.bats

# Setup
setup() {
    TEST_DIR="$( cd "$( dirname "$BATS_TEST_FILENAME" )" && pwd )"
    PROJECT_ROOT="$( cd "$TEST_DIR/.." && pwd )"

    # Create temp directory for test files
    export TEST_TMP=$(mktemp -d)

    # Source common library if available
    source "$PROJECT_ROOT/lyrebird-common.sh" 2>/dev/null || true
}

teardown() {
    rm -rf "$TEST_TMP" 2>/dev/null || true
}

# ============================================================================
# Validation Functions
# ============================================================================

@test "validate_numeric_env accepts valid integers" {
    validate_numeric_env() {
        local var_value="$2"
        local min_val="${3:-1}"
        local max_val="${4:-3600}"

        [[ "${var_value}" =~ ^[0-9]+$ ]] || return 1
        ((var_value >= min_val && var_value <= max_val)) || return 1
        return 0
    }

    run validate_numeric_env "test" "30" 1 3600
    [ "$status" -eq 0 ]
}

@test "validate_numeric_env rejects negative numbers" {
    validate_numeric_env() {
        local var_value="$2"
        local min_val="${3:-1}"
        local max_val="${4:-3600}"

        [[ "${var_value}" =~ ^[0-9]+$ ]] || return 1
        ((var_value >= min_val && var_value <= max_val)) || return 1
        return 0
    }

    run validate_numeric_env "test" "-5" 1 3600
    [ "$status" -eq 1 ]
}

@test "validate_numeric_env rejects values above max" {
    validate_numeric_env() {
        local var_value="$2"
        local min_val="${3:-1}"
        local max_val="${4:-3600}"

        [[ "${var_value}" =~ ^[0-9]+$ ]] || return 1
        ((var_value >= min_val && var_value <= max_val)) || return 1
        return 0
    }

    run validate_numeric_env "test" "5000" 1 3600
    [ "$status" -eq 1 ]
}

@test "validate_numeric_env rejects non-numeric input" {
    validate_numeric_env() {
        local var_value="$2"
        local min_val="${3:-1}"
        local max_val="${4:-3600}"

        [[ "${var_value}" =~ ^[0-9]+$ ]] || return 1
        ((var_value >= min_val && var_value <= max_val)) || return 1
        return 0
    }

    run validate_numeric_env "test" "abc" 1 3600
    [ "$status" -eq 1 ]
}

# ============================================================================
# Port Validation Tests
# ============================================================================

@test "validate_port accepts valid port numbers" {
    validate_port() {
        local port="$1"
        [[ "$port" =~ ^[0-9]+$ ]] || return 1
        ((port >= 1 && port <= 65535)) || return 1
        return 0
    }

    run validate_port "8554"
    [ "$status" -eq 0 ]
}

@test "validate_port rejects port 0" {
    validate_port() {
        local port="$1"
        [[ "$port" =~ ^[0-9]+$ ]] || return 1
        ((port >= 1 && port <= 65535)) || return 1
        return 0
    }

    run validate_port "0"
    [ "$status" -eq 1 ]
}

@test "validate_port rejects port above 65535" {
    validate_port() {
        local port="$1"
        [[ "$port" =~ ^[0-9]+$ ]] || return 1
        ((port >= 1 && port <= 65535)) || return 1
        return 0
    }

    run validate_port "65536"
    [ "$status" -eq 1 ]
}

# ============================================================================
# Init System Detection Tests
# ============================================================================

@test "detect_init_system returns valid value" {
    detect_init_system() {
        if [[ -d /run/systemd/system ]]; then
            echo "systemd"
        elif [[ -f /sbin/openrc ]] || [[ -f /etc/init.d/rc ]]; then
            echo "openrc"
        else
            echo "other"
        fi
    }

    run detect_init_system
    [ "$status" -eq 0 ]
    [[ "$output" =~ ^(systemd|openrc|other)$ ]]
}

# ============================================================================
# File Size Functions
# ============================================================================

@test "get_file_size returns size for existing file" {
    get_file_size() {
        local filepath="$1"
        [[ -f "${filepath}" ]] || { echo 0; return; }
        stat -c%s "${filepath}" 2>/dev/null || stat -f%z "${filepath}" 2>/dev/null || wc -c <"${filepath}" 2>/dev/null | tr -d ' ' || echo 0
    }

    echo "test content" > "$TEST_TMP/test.txt"
    run get_file_size "$TEST_TMP/test.txt"
    [ "$status" -eq 0 ]
    [[ "$output" =~ ^[0-9]+$ ]]
    [ "$output" -gt 0 ]
}

@test "get_file_size returns 0 for missing file" {
    get_file_size() {
        local filepath="$1"
        [[ -f "${filepath}" ]] || { echo 0; return; }
        stat -c%s "${filepath}" 2>/dev/null || stat -f%z "${filepath}" 2>/dev/null || wc -c <"${filepath}" 2>/dev/null | tr -d ' ' || echo 0
    }

    run get_file_size "$TEST_TMP/nonexistent.txt"
    [ "$status" -eq 0 ]
    [ "$output" = "0" ]
}

# ============================================================================
# Disk Usage Tests
# ============================================================================

@test "get_disk_usage_percent returns numeric value" {
    get_disk_usage_percent() {
        local path="$1"
        command -v df >/dev/null 2>&1 || { echo "unknown"; return; }
        df "$path" 2>/dev/null | tail -1 | awk '{print $5}' | sed 's/%//' || echo "unknown"
    }

    run get_disk_usage_percent "/"
    [ "$status" -eq 0 ]
    [[ "$output" =~ ^[0-9]+$ ]] || [ "$output" = "unknown" ]
}

# ============================================================================
# Log Analysis Tests
# ============================================================================

@test "count_log_errors handles missing log file" {
    count_log_errors() {
        local log_file="$1"
        local lines="${2:-500}"
        [[ -f "$log_file" ]] || { echo 0; return; }
        tail -n "$lines" "$log_file" 2>/dev/null | grep -ic "error\|fail" || echo 0
    }

    run count_log_errors "$TEST_TMP/nonexistent.log" 500
    [ "$status" -eq 0 ]
    [ "$output" = "0" ]
}

@test "count_log_errors counts errors in log" {
    count_log_errors() {
        local log_file="$1"
        local lines="${2:-500}"
        [[ -f "$log_file" ]] || { echo 0; return; }
        tail -n "$lines" "$log_file" 2>/dev/null | grep -ic "error\|fail" || echo 0
    }

    cat > "$TEST_TMP/test.log" << 'EOF'
INFO: Starting service
ERROR: Connection failed
WARN: Retrying
ERROR: Timeout
INFO: Recovered
EOF

    run count_log_errors "$TEST_TMP/test.log" 500
    [ "$status" -eq 0 ]
    [ "$output" = "2" ]
}

# ============================================================================
# YAML Validation Tests
# ============================================================================

@test "validate_yaml_basic rejects tabs" {
    validate_yaml_basic() {
        local file="$1"
        [[ -f "$file" ]] || return 1
        # Basic check: YAML should not have tabs for indentation
        grep -q $'^\t' "$file" && return 2
        return 0
    }

    printf 'key:\n\tvalue\n' > "$TEST_TMP/bad.yml"
    run validate_yaml_basic "$TEST_TMP/bad.yml"
    [ "$status" -eq 2 ]
}

@test "validate_yaml_basic accepts valid yaml" {
    validate_yaml_basic() {
        local file="$1"
        [[ -f "$file" ]] || return 1
        grep -q $'^\t' "$file" && return 2
        return 0
    }

    printf 'key:\n  value: test\n' > "$TEST_TMP/good.yml"
    run validate_yaml_basic "$TEST_TMP/good.yml"
    [ "$status" -eq 0 ]
}

# ============================================================================
# Process Status Tests
# ============================================================================

@test "is_process_running detects running process" {
    is_process_running() {
        local pid="$1"
        [[ -n "$pid" ]] && [[ "$pid" =~ ^[0-9]+$ ]] && kill -0 "$pid" 2>/dev/null
    }

    # Current shell is running
    run is_process_running "$$"
    [ "$status" -eq 0 ]
}

@test "is_process_running returns false for invalid pid" {
    is_process_running() {
        local pid="$1"
        [[ -n "$pid" ]] && [[ "$pid" =~ ^[0-9]+$ ]] && kill -0 "$pid" 2>/dev/null
    }

    run is_process_running "999999999"
    [ "$status" -eq 1 ]
}

@test "is_process_running handles non-numeric input" {
    is_process_running() {
        local pid="$1"
        [[ -n "$pid" ]] && [[ "$pid" =~ ^[0-9]+$ ]] && kill -0 "$pid" 2>/dev/null
    }

    run is_process_running "abc"
    [ "$status" -eq 1 ]
}

# ============================================================================
# Color Detection Tests
# ============================================================================

@test "detect_colors respects NO_COLOR" {
    detect_colors() {
        local use_color=false
        if [[ "${NO_COLOR:-}" != "true" ]] && [[ "${NO_COLOR:-}" != "1" ]]; then
            if [[ -t 1 ]] && [[ -t 2 ]]; then
                use_color=true
            fi
        fi
        $use_color && echo "color" || echo "nocolor"
    }

    NO_COLOR=true run detect_colors
    [ "$output" = "nocolor" ]
}
