#!/usr/bin/env bash
# lyrebird-diagnostics.sh - Comprehensive system diagnostics for LyreBirdAudio
# Part of LyreBirdAudio - RTSP Audio Streaming Suite
# https://github.com/tomtom215/LyreBirdAudio
#
# Author: Tom F (https://github.com/tomtom215)
# Copyright: Tom F and LyreBirdAudio contributors
# License: Apache 2.0
#
# This script performs comprehensive diagnostic checks on LyreBirdAudio
# system components, USB audio devices, MediaMTX service, and streaming health.
# Generates production-ready diagnostic bundles for GitHub issue submission.
#
# Version: 1.0.2
# Requires: bash 4.4+, standard GNU/Linux utilities (no external dependencies)
# Compatible: Ubuntu 20.04+, Debian 11+, Raspberry Pi OS
# Note: Limited support for Alpine Linux (OpenRC) and macOS/BSD systems
#
# v1.0.2 Production Release:
#   - FIXED: YAML validation now uses proper parser (python/yq/perl fallback)
#   - FIXED: Race condition in log directory creation removed
#   - FIXED: BSD/macOS stat format strings corrected
#   - FIXED: Division by zero guards added to all arithmetic operations
#   - FIXED: mktemp usage now POSIX-compliant
#   - IMPROVED: Init system detection (systemd vs OpenRC vs other)
#   - IMPROVED: Portable date handling for BSD/macOS/BusyBox
#   - IMPROVED: Process cleanup now tracks child PIDs explicitly
#   - CLARIFIED: Alpine/macOS compatibility notes (OpenRC not fully supported)

set -euo pipefail

# Script metadata
readonly SCRIPT_VERSION="1.0.2"
declare SCRIPT_NAME
SCRIPT_NAME="$(basename "${BASH_SOURCE[0]}")"
readonly SCRIPT_NAME
declare SCRIPT_DIR
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly SCRIPT_DIR

# Exit codes
readonly E_SUCCESS=0
readonly E_WARN=1
readonly E_FAIL=2
readonly E_ERROR=127

# Detect init system early for adaptive behavior
detect_init_system() {
    if [[ -d /run/systemd/system ]]; then
        echo "systemd"
    elif [[ -f /sbin/openrc ]] || [[ -f /etc/init.d/rc ]]; then
        echo "openrc"
    else
        echo "other"
    fi
}

# Declare and assign separately to avoid masking return values (SC2155)
declare INIT_SYSTEM
INIT_SYSTEM="$(detect_init_system)"
readonly INIT_SYSTEM

# Helper: Get safe fallback log directory
get_safe_fallback_log() {
    local fallback_dir
    if [[ -n "${HOME:-}" ]] && [[ -w "${HOME}" ]]; then
        fallback_dir="${HOME}"
    elif [[ -n "${SUDO_USER:-}" ]] && [[ -d "/home/${SUDO_USER}" ]]; then
        fallback_dir="/home/${SUDO_USER}"
    elif [[ -w "/tmp" ]]; then
        fallback_dir="/tmp"
    elif [[ -w "/var/tmp" ]]; then
        fallback_dir="/var/tmp"
    else
        fallback_dir="."
    fi
    echo "${fallback_dir}/.lyrebird-diagnostics.log"
}

# Validate numeric environment variables
validate_numeric_env() {
    local var_value="$2"
    local min_val="${3:-1}"
    local max_val="${4:-3600}"
    
    if [[ ! "${var_value}" =~ ^[0-9]+$ ]]; then
        return 1
    fi
    
    if (( var_value < min_val || var_value > max_val )); then
        return 1
    fi
    
    return 0
}

# Configuration paths with environment variable defaults
readonly MEDIAMTX_CONFIG_DIR="${MEDIAMTX_CONFIG_DIR:-/etc/mediamtx}"
readonly MEDIAMTX_CONFIG_FILE="${MEDIAMTX_CONFIG_FILE:-${MEDIAMTX_CONFIG_DIR}/mediamtx.yml}"
readonly MEDIAMTX_DEVICE_CONFIG="${MEDIAMTX_DEVICE_CONFIG:-${MEDIAMTX_CONFIG_DIR}/audio-devices.conf}"
readonly MEDIAMTX_LOG_FILE="${MEDIAMTX_LOG_FILE:-/var/log/mediamtx.out}"
readonly FFMPEG_LOG_DIR="${FFMPEG_LOG_DIR:-/var/log/lyrebird}"
readonly MEDIAMTX_BINARY="${MEDIAMTX_BINARY:-/usr/local/bin/mediamtx}"
readonly MEDIAMTX_HOST="${MEDIAMTX_HOST:-localhost}"
readonly MEDIAMTX_PORT="${MEDIAMTX_PORT:-8554}"

# Diagnostic configuration with validation
readonly DIAGNOSTIC_LOG_FILE="${DIAGNOSTIC_LOG_FILE:-/var/log/lyrebird-diagnostics.log}"
declare DIAGNOSTIC_LOG_DIR
DIAGNOSTIC_LOG_DIR="$(dirname "${DIAGNOSTIC_LOG_FILE}")"
readonly DIAGNOSTIC_LOG_DIR

# Validate DIAGNOSTIC_TIMEOUT from environment
declare DIAGNOSTIC_TIMEOUT_RAW="${DIAGNOSTIC_TIMEOUT:-30}"
if validate_numeric_env "DIAGNOSTIC_TIMEOUT" "${DIAGNOSTIC_TIMEOUT_RAW}" 1 3600; then
    readonly DIAGNOSTIC_TIMEOUT="${DIAGNOSTIC_TIMEOUT_RAW}"
else
    echo "Warning: Invalid DIAGNOSTIC_TIMEOUT='${DIAGNOSTIC_TIMEOUT_RAW}', using default 30s" >&2
    readonly DIAGNOSTIC_TIMEOUT=30
fi

# Determine if log directory is writable
declare -g LOG_DIR_WRITABLE=false
if [[ -d "${DIAGNOSTIC_LOG_DIR}" ]] && [[ -w "${DIAGNOSTIC_LOG_DIR}" ]]; then
    LOG_DIR_WRITABLE=true
fi

declare FALLBACK_LOG_FILE
FALLBACK_LOG_FILE="$(get_safe_fallback_log)"
readonly FALLBACK_LOG_FILE
readonly DIAGNOSTIC_OUTPUT_DIR="${DIAGNOSTIC_OUTPUT_DIR:-/tmp}"
readonly DIAGNOSTIC_MAX_LOG_SIZE="${DIAGNOSTIC_MAX_LOG_SIZE:-10485760}"
readonly DIAGNOSTIC_LOG_TAIL_LINES="${DIAGNOSTIC_LOG_TAIL_LINES:-500}"

# Resource thresholds
readonly WARN_CPU_PERCENT="${WARN_CPU_PERCENT:-20}"
readonly CRIT_CPU_PERCENT="${CRIT_CPU_PERCENT:-40}"
readonly WARN_MEMORY_MB="${WARN_MEMORY_MB:-500}"
readonly CRIT_MEMORY_MB="${CRIT_MEMORY_MB:-1000}"
readonly WARN_FD_COUNT="${WARN_FD_COUNT:-500}"
readonly CRIT_FD_COUNT="${CRIT_FD_COUNT:-1000}"

# System health thresholds
readonly WARN_DISK_PERCENT="${WARN_DISK_PERCENT:-80}"
readonly CRIT_DISK_PERCENT="${CRIT_DISK_PERCENT:-95}"
readonly MIN_FD_LIMIT="${MIN_FD_LIMIT:-4096}"

# File permission/ownership thresholds
readonly MEDIAMTX_BINARY_MODE="${MEDIAMTX_BINARY_MODE:-0755}"
readonly MEDIAMTX_CONFIG_MODE="${MEDIAMTX_CONFIG_MODE:-0644}"
readonly EXPECTED_BINARY_OWNER="${EXPECTED_BINARY_OWNER:-root}"

# Process stability thresholds
readonly RESTART_THRESHOLD_CRITICAL="${RESTART_THRESHOLD_CRITICAL:-5}"
readonly RESTART_THRESHOLD_WARN="${RESTART_THRESHOLD_WARN:-3}"

# File descriptor thresholds (% of limit)
readonly WARN_FD_PERCENT="${WARN_FD_PERCENT:-70}"
readonly CRIT_FD_PERCENT="${CRIT_FD_PERCENT:-85}"

# inotify/entropy thresholds
readonly MIN_INOTIFY_LIMIT="${MIN_INOTIFY_LIMIT:-8192}"
readonly WARN_INOTIFY_PERCENT="${WARN_INOTIFY_PERCENT:-80}"
readonly CRIT_INOTIFY_PERCENT="${CRIT_INOTIFY_PERCENT:-95}"
readonly MIN_ENTROPY_AVAIL="${MIN_ENTROPY_AVAIL:-1000}"

# Network resource thresholds
readonly WARN_TCP_TIMEWAIT_PERCENT="${WARN_TCP_TIMEWAIT_PERCENT:-60}"
readonly CRIT_TCP_TIMEWAIT_PERCENT="${CRIT_TCP_TIMEWAIT_PERCENT:-80}"

# Clock health thresholds
readonly MAX_CLOCK_DRIFT_MS="${MAX_CLOCK_DRIFT_MS:-5}"

# Global variables
declare -g DEBUG="${DEBUG:-false}"
declare -g QUIET="${QUIET:-false}"
declare -g NO_COLOR="${NO_COLOR:-false}"
declare -g USE_COLOR=false
declare -g COMMAND="${COMMAND:-full}"
declare -g TIMEOUT_SECONDS="${DIAGNOSTIC_TIMEOUT}"
declare -g CUSTOM_CONFIG_FILE=""

# Cache for performance optimization
declare -g MEDIAMTX_PID=""
declare -g STREAM_MANAGER_PATH=""

# Result tracking
declare -g PASS_COUNT=0
declare -g WARN_COUNT=0
declare -g FAIL_COUNT=0
declare -g INFO_COUNT=0
declare -g EXIT_CODE="${E_SUCCESS}"

# Child process tracking for reliable cleanup
declare -ga CHILD_PIDS=()

# Temporary files tracking
declare -ga TEMP_FILES=()

# Color codes
declare -g RED=""
declare -g GREEN=""
declare -g YELLOW=""
declare -g CYAN=""
declare -g NC=""

# Detect terminal color support
detect_colors() {
    if [[ "${NO_COLOR}" == "true" ]] || [[ "${NO_COLOR}" == "1" ]]; then
        return
    fi
    
    if [[ -t 1 ]] && [[ -t 2 ]]; then
        if command -v tput >/dev/null 2>&1; then
            local colors
            colors="$(tput colors 2>/dev/null || echo 0)"
            if [[ "${colors}" -ge 8 ]]; then
                RED="$(tput setaf 1)"
                GREEN="$(tput setaf 2)"
                YELLOW="$(tput setaf 3)"
                CYAN="$(tput setaf 6)"
                NC="$(tput sgr0)"
                USE_COLOR=true
            fi
        fi
    fi
}

# Ensure log directory exists (FIXED: removed race condition)
ensure_log_directory() {
    # mkdir -p is atomic and idempotent - no need for existence check
    if mkdir -p "${DIAGNOSTIC_LOG_DIR}" 2>/dev/null; then
        if [[ -w "${DIAGNOSTIC_LOG_DIR}" ]]; then
            LOG_DIR_WRITABLE=true
            return 0
        fi
    fi
    
    LOG_DIR_WRITABLE=false
    return 1
}

# Signal handler and cleanup (IMPROVED: explicit child PID tracking)
cleanup() {
    local exit_code=$?
    local temp_file
    local pid
    
    log DEBUG "Cleanup started by ${SCRIPT_NAME} (exit code: ${exit_code})"
    
    # Clean up temporary files
    for temp_file in "${TEMP_FILES[@]}"; do
        if [[ -f "${temp_file}" ]]; then
            rm -f "${temp_file}" 2>/dev/null || true
        fi
    done
    
    # Terminate tracked child processes
    for pid in "${CHILD_PIDS[@]}"; do
        if kill -0 "${pid}" 2>/dev/null; then
            kill -TERM "${pid}" 2>/dev/null || true
            sleep 0.1
            if kill -0 "${pid}" 2>/dev/null; then
                kill -KILL "${pid}" 2>/dev/null || true
            fi
        fi
    done
    
    # Fallback: check for stray backgrounded jobs
    if jobs -p >/dev/null 2>&1; then
        jobs -p | xargs -r kill -TERM 2>/dev/null || true
    fi
    
    exit "${exit_code}"
}

trap cleanup EXIT INT TERM HUP QUIT

# Logging function
log() {
    local level="$1"
    shift
    local message="$*"
    local timestamp
    
    if command -v date >/dev/null 2>&1; then
        timestamp="$(date '+%Y-%m-%d %H:%M:%S' 2>/dev/null || echo '[UNKNOWN]')"
    else
        timestamp="[NO-DATE]"
    fi
    
    local log_file="${DIAGNOSTIC_LOG_FILE}"
    if [[ "${LOG_DIR_WRITABLE}" != "true" ]]; then
        log_file="${FALLBACK_LOG_FILE}"
    fi
    
    echo "[${timestamp}] [${level}] ${message}" >> "${log_file}" 2>/dev/null || true
    
    if [[ "${QUIET}" == "true" ]]; then
        return
    fi
    
    case "${level}" in
        ERROR)
            if [[ "${USE_COLOR}" == "true" ]]; then
                printf '%s[ERROR]%s %s\n' "${RED}" "${NC}" "${message}" >&2
            else
                printf '[ERROR] %s\n' "${message}" >&2
            fi
            ;;
        WARN)
            if [[ "${USE_COLOR}" == "true" ]]; then
                printf '%s[WARN]%s %s\n' "${YELLOW}" "${NC}" "${message}" >&2
            else
                printf '[WARN] %s\n' "${message}" >&2
            fi
            ;;
        INFO)
            if [[ "${USE_COLOR}" == "true" ]]; then
                printf '%s[INFO]%s %s\n' "${CYAN}" "${NC}" "${message}" >&2
            else
                printf '[INFO] %s\n' "${message}" >&2
            fi
            ;;
        DEBUG)
            if [[ "${DEBUG}" == "true" ]]; then
                if [[ "${USE_COLOR}" == "true" ]]; then
                    printf '%s[DEBUG]%s %s\n' "${CYAN}" "${NC}" "${message}" >&2
                else
                    printf '[DEBUG] %s\n' "${message}" >&2
                fi
            fi
            ;;
    esac
}

# Output formatting for text mode
print_section() {
    local section="$1"
    if [[ "${QUIET}" == "true" ]]; then
        return
    fi
    if [[ "${USE_COLOR}" == "true" ]]; then
        printf '\n%s%s%s\n' "${CYAN}" "${section}" "${NC}"
    else
        printf '\n%s\n' "${section}"
    fi
}

print_status() {
    local check="$1"
    local status="$2"
    local message="$3"
    
    if [[ "${QUIET}" == "true" ]]; then
        return
    fi
    
    case "${status}" in
        PASS)
            ((++PASS_COUNT))
            if [[ "${USE_COLOR}" == "true" ]]; then
                printf '  %s[+]%s %s: %s\n' "${GREEN}" "${NC}" "${check}" "${message}"
            else
                printf '  [PASS] %s: %s\n' "${check}" "${message}"
            fi
            ;;
        WARN)
            ((++WARN_COUNT))
            if [[ "${EXIT_CODE}" == "${E_SUCCESS}" ]]; then
                EXIT_CODE="${E_WARN}"
            fi
            if [[ "${USE_COLOR}" == "true" ]]; then
                printf '  %s[!]%s %s: %s\n' "${YELLOW}" "${NC}" "${check}" "${message}"
            else
                printf '  [WARN] %s: %s\n' "${check}" "${message}"
            fi
            ;;
        FAIL)
            ((++FAIL_COUNT))
            EXIT_CODE="${E_FAIL}"
            if [[ "${USE_COLOR}" == "true" ]]; then
                printf '  %s[x]%s %s: %s\n' "${RED}" "${NC}" "${check}" "${message}"
            else
                printf '  [FAIL] %s: %s\n' "${check}" "${message}"
            fi
            ;;
        INFO)
            ((++INFO_COUNT))
            if [[ "${USE_COLOR}" == "true" ]]; then
                printf '  %s[i]%s %s: %s\n' "${CYAN}" "${NC}" "${check}" "${message}"
            else
                printf '  [INFO] %s: %s\n' "${check}" "${message}"
            fi
            ;;
    esac
}

# Helper functions
has_command() {
    command -v "$1" >/dev/null 2>&1
}

# FIXED: Portable mktemp usage
make_temp() {
    local temp_file
    # Use TMPDIR if set, otherwise mktemp will use /tmp
    if temp_file="$(mktemp 2>/dev/null)"; then
        TEMP_FILES+=("${temp_file}")
        echo "${temp_file}"
        return 0
    fi
    
    # Fallback for systems without mktemp
    temp_file="${TMPDIR:-/tmp}/lyrebird-diag.$$.$RANDOM"
    if touch "${temp_file}" 2>/dev/null; then
        TEMP_FILES+=("${temp_file}")
        echo "${temp_file}"
        return 0
    fi
    
    log ERROR "Failed to create temporary file"
    return 1
}

run_with_timeout() {
    local timeout="$1"
    shift
    
    if has_command timeout; then
        timeout "${timeout}" "$@" 2>/dev/null || {
            local exit_code=$?
            [[ "${exit_code}" == 124 ]] && return 1
            return "${exit_code}"
        }
    else
        "$@" 2>/dev/null
    fi
}

is_readable() {
    [[ -f "$1" ]] && [[ -r "$1" ]]
}

dir_exists() {
    [[ -d "$1" ]]
}

# FIXED: Simplified and portable get_file_size
get_file_size() {
    local filepath="$1"
    
    if [[ ! -f "${filepath}" ]]; then
        echo 0
        return
    fi
    
    # Try GNU stat first
    if command -v stat >/dev/null 2>&1; then
        local size
        if size=$(stat -c%s "${filepath}" 2>/dev/null); then
            echo "${size}"
            return
        fi
        # Try BSD stat
        if size=$(stat -f%z "${filepath}" 2>/dev/null); then
            echo "${size}"
            return
        fi
    fi
    
    # Fallback: wc (always works)
    wc -c < "${filepath}" 2>/dev/null | tr -d ' ' || echo 0
}

# Check RTSP server reachability with /dev/tcp feature detection
check_rtsp_reachable() {
    local host="$1"
    local port="$2"
    local timeout_sec="$3"
    
    if [[ ! "${port}" =~ ^[0-9]+$ ]] || (( port < 1 || port > 65535 )); then
        return 2
    fi
    
    # Try nc first (most reliable)
    if command -v nc >/dev/null 2>&1; then
        if timeout "${timeout_sec}" nc -zv "${host}" "${port}" >/dev/null 2>&1; then
            return 0
        fi
        return 1
    fi
    
    # Check if /dev/tcp is available before using it
    if command -v timeout >/dev/null 2>&1 && [[ -n "${BASH_VERSION}" ]]; then
        # Test /dev/tcp availability
        if (exec 3<>/dev/tcp/127.0.0.1/1) 2>/dev/null; then
            exec 3>&-
            if timeout "${timeout_sec}" bash -c "exec 3<>/dev/tcp/${host}/${port}" 2>/dev/null; then
                return 0
            fi
            return 1
        fi
    fi
    
    return 3
}

# Validate TCP port number
validate_port() {
    local port="$1"
    
    if [[ ! "${port}" =~ ^[0-9]+$ ]]; then
        return 1
    fi
    
    if (( port >= 1 && port <= 65535 )); then
        return 0
    fi
    
    return 1
}

# Get MediaMTX config file
get_mediamtx_config_file() {
    if [[ -n "${CUSTOM_CONFIG_FILE}" ]]; then
        echo "${CUSTOM_CONFIG_FILE}"
    else
        echo "${MEDIAMTX_CONFIG_FILE}"
    fi
}

# Find Stream Manager script (cached for performance)
find_stream_manager() {
    # Return cached value if available
    if [[ -n "${STREAM_MANAGER_PATH}" ]]; then
        echo "${STREAM_MANAGER_PATH}"
        return 0
    fi
    
    # Check in current script directory first
    if [[ -x "${SCRIPT_DIR}/mediamtx-stream-manager.sh" ]]; then
        STREAM_MANAGER_PATH="${SCRIPT_DIR}/mediamtx-stream-manager.sh"
        echo "${STREAM_MANAGER_PATH}"
        return 0
    fi
    
    # Check common installation paths
    local common_paths=(
        "/usr/local/bin/mediamtx-stream-manager"
        "/opt/lyrebird/mediamtx-stream-manager.sh"
    )
    
    local path
    for path in "${common_paths[@]}"; do
        if [[ -x "${path}" ]]; then
            STREAM_MANAGER_PATH="${path}"
            echo "${STREAM_MANAGER_PATH}"
            return 0
        fi
    done
    
    # Check for user home directories
    if [[ -d "/home" ]]; then
        while IFS= read -r -d '' home_dir; do
            local user_manager="${home_dir}/LyreBirdAudio/mediamtx-stream-manager.sh"
            if [[ -x "${user_manager}" ]]; then
                STREAM_MANAGER_PATH="${user_manager}"
                echo "${STREAM_MANAGER_PATH}"
                return 0
            fi
        done < <(find /home -maxdepth 1 -type d -print0 2>/dev/null)
    fi
    
    # Try to find via PATH
    if command -v mediamtx-stream-manager.sh >/dev/null 2>&1; then
        STREAM_MANAGER_PATH="$(command -v mediamtx-stream-manager.sh)"
        echo "${STREAM_MANAGER_PATH}"
        return 0
    fi
    
    return 1
}

# Parse version from script file
get_script_version() {
    local script_path="$1"
    local version=""
    
    if [[ ! -f "${script_path}" ]]; then
        echo "not_found"
        return
    fi
    
    version=$(grep -m1 "^readonly SCRIPT_VERSION=" "${script_path}" 2>/dev/null | cut -d'"' -f2)
    if [[ -z "${version}" ]]; then
        version=$(grep -m1 "^SCRIPT_VERSION=" "${script_path}" 2>/dev/null | cut -d'"' -f2)
    fi
    if [[ -z "${version}" ]]; then
        version=$(grep -m1 "# Version:" "${script_path}" 2>/dev/null | awk '{print $3}')
    fi
    
    echo "${version:-unknown}"
}

# Get MediaMTX version from running process or binary
get_mediamtx_version() {
    local version=""
    
    if [[ -x "${MEDIAMTX_BINARY}" ]]; then
        version=$("${MEDIAMTX_BINARY}" --version 2>/dev/null | head -1 | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' || echo "")
    fi
    
    if [[ -z "${version}" ]] && command -v pgrep >/dev/null 2>&1; then
        if pgrep -f "${MEDIAMTX_BINARY}" >/dev/null 2>&1; then
            version=$(pgrep -af "${MEDIAMTX_BINARY}" | head -1 | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' || echo "")
        fi
    fi
    
    echo "${version:-unknown}"
}

# Get stream manager status (adapted for init system)
get_stream_manager_status() {
    local stream_manager_log="${FFMPEG_LOG_DIR}/stream-manager.log"
    
    # Check based on init system
    if [[ "${INIT_SYSTEM}" == "systemd" ]]; then
        if systemctl is-active --quiet mediamtx-audio 2>/dev/null; then
            echo "running"
            return
        fi
        
        if systemctl list-unit-files mediamtx-audio.service 2>/dev/null | grep -q "mediamtx-audio"; then
            echo "stopped"
            return
        fi
    fi
    
    # Fallback: check if process is running (works for all init systems)
    if command -v pgrep >/dev/null 2>&1; then
        if pgrep -f "mediamtx-stream-manager.sh" >/dev/null 2>&1; then
            echo "running"
            return
        fi
    fi
    
    # Check for log file as indicator of previous installation
    if [[ -f "${stream_manager_log}" ]]; then
        echo "stopped"
        return
    fi
    
    echo "not_configured"
}

# Check file ownership and permissions
check_file_permissions() {
    local filepath="$1"
    local expected_mode="$2"
    
    if [[ ! -e "${filepath}" ]]; then
        return 1
    fi
    
    if [[ ! -r "${filepath}" ]]; then
        return 2
    fi
    
    if [[ -n "${expected_mode}" ]]; then
        local actual_mode
        actual_mode=$(stat -c '%a' "${filepath}" 2>/dev/null || stat -f '%OLp' "${filepath}" 2>/dev/null || echo "unknown")
        if [[ "${actual_mode}" != "${expected_mode}" ]]; then
            return 3
        fi
    fi
    
    return 0
}

# Get process crash count from systemd journal (systemd-only)
get_process_restart_count() {
    local service_name="$1"
    local restart_count
    
    if [[ "${INIT_SYSTEM}" != "systemd" ]]; then
        echo "unsupported"
        return
    fi
    
    if ! command -v systemctl >/dev/null 2>&1; then
        echo "unknown"
        return
    fi
    
    restart_count=$(systemctl show "${service_name}" -p NRestarts --value 2>/dev/null)
    if [[ -n "${restart_count}" ]] && [[ "${restart_count}" =~ ^[0-9]+$ ]]; then
        echo "${restart_count}"
    else
        echo "unknown"
    fi
}

# Check inotify resource limits
get_inotify_limits() {
    if [[ ! -f "/proc/sys/fs/inotify/max_user_watches" ]]; then
        echo "unknown"
        return
    fi
    cat /proc/sys/fs/inotify/max_user_watches 2>/dev/null || echo "unknown"
}

# Get configured stream source count
get_stream_source_count() {
    if [[ ! -f "${MEDIAMTX_DEVICE_CONFIG}" ]]; then
        echo "0"
        return
    fi
    
    if ! is_readable "${MEDIAMTX_DEVICE_CONFIG}"; then
        echo "0"
        return
    fi
    
    local count
    count=$(grep -c "source:" "${MEDIAMTX_DEVICE_CONFIG}" 2>/dev/null || true)
    count=${count:-0}
    if [[ ! "${count}" =~ ^[0-9]+$ ]]; then
        count=0
    fi
    echo "${count}"
}

# Count RTSP paths configured in mediamtx.yml
get_configured_devices() {
    local stream_manager_path stream_count
    
    stream_manager_path="$(find_stream_manager)"
    
    if [[ -z "${stream_manager_path}" ]] || [[ ! -x "${stream_manager_path}" ]]; then
        echo "0"
        return
    fi
    
    stream_count=$(timeout "${TIMEOUT_SECONDS}" "${stream_manager_path}" status 2>/dev/null | grep -c "Stream: rtsp://" || echo "0")
    echo "${stream_count}"
}

get_device_names() {
    local stream_manager_path device_names
    
    stream_manager_path="$(find_stream_manager)"
    
    if [[ -z "${stream_manager_path}" ]] || [[ ! -x "${stream_manager_path}" ]]; then
        echo "none"
        return
    fi
    
    device_names=$(timeout "${TIMEOUT_SECONDS}" "${stream_manager_path}" status 2>/dev/null | \
        grep "Stream: rtsp://" | \
        sed 's|.*rtsp://[^/]*/||' | \
        tr '\n' ',' | sed 's/,$//')
    
    if [[ -n "${device_names}" ]]; then
        echo "${device_names}"
    else
        echo "none"
    fi
}

# FIXED: Portable date parsing with BSD/macOS/Alpine support
parse_date_to_seconds() {
    local date_str="$1"
    local result
    
    # Try GNU date format first
    if result=$(date -d "${date_str}" +%s 2>/dev/null); then
        echo "${result}"
        return 0
    fi
    
    # Try BSD/macOS date format
    if result=$(date -j -f "%a %b %d %H:%M:%S %Z %Y" "${date_str}" +%s 2>/dev/null); then
        echo "${result}"
        return 0
    fi
    
    return 1
}

# FIXED: Complete fallback handling with BSD date support
get_relative_date() {
    local offset="$1"
    local result
    
    if ! [[ "${offset}" =~ ^-[0-9]+(H|D|M|S)$ ]]; then
        log DEBUG "Invalid offset format: ${offset} (use -24H, -7D, -30M, -3600S, etc.)"
        return 1
    fi
    
    # Try GNU date format first
    if result=$(date -d "${offset}" '+%Y-%m-%d %H:%M:%S' 2>/dev/null); then
        echo "${result}"
        return 0
    fi
    
    # Try BSD/macOS format
    if result=$(date -j -v"${offset}" '+%Y-%m-%d %H:%M:%S' 2>/dev/null); then
        echo "${result}"
        return 0
    fi
    
    # Fallback: manual calculation for BusyBox/Alpine
    local current_epoch
    if ! current_epoch=$(date +%s 2>/dev/null); then
        return 1
    fi
    
    local number="${offset#-}"
    local unit="${number##*[0-9]}"
    number="${number%"${unit}"}"
    
    local seconds_offset=0
    case "${unit}" in
        H) seconds_offset=$((number * 3600)) ;;
        D) seconds_offset=$((number * 86400)) ;;
        M) seconds_offset=$((number * 2592000)) ;;
        S) seconds_offset=$((number)) ;;
        *) return 1 ;;
    esac
    
    if (( seconds_offset > 0 )); then
        local target_epoch=$((current_epoch - seconds_offset))
        
        # Try GNU date format for epoch
        if date -d "@${target_epoch}" '+%Y-%m-%d %H:%M:%S' 2>/dev/null; then
            return 0
        fi
        
        # Try BSD date format for epoch
        if date -r "${target_epoch}" '+%Y-%m-%d %H:%M:%S' 2>/dev/null; then
            return 0
        fi
    fi
    
    return 1
}

# Search for recent log warnings
get_recent_log_warnings() {
    local warning_count=0
    local since_time
    
    since_time=$(get_relative_date "-24H" 2>/dev/null || echo "")
    
    if [[ -z "${since_time}" ]]; then
        warning_count=$(tail -n 2000 "${MEDIAMTX_LOG_FILE}" 2>/dev/null | grep -ic "warn\|error" || echo 0)
    else
        warning_count=$(grep "${since_time%% *}" "${MEDIAMTX_LOG_FILE}" 2>/dev/null | grep -ic "warn\|error" || echo 0)
    fi
    
    echo "${warning_count}"
}

# Get service uptime duration (systemd-only)
get_service_uptime() {
    local service_name="$1"
    
    if [[ "${INIT_SYSTEM}" != "systemd" ]]; then
        echo ""
        return
    fi
    
    if ! command -v systemctl >/dev/null 2>&1; then
        echo ""
        return
    fi
    
    local start_time_str
    start_time_str=$(systemctl show "${service_name}" -p ActiveEnterTimestamp --value 2>/dev/null)
    
    if [[ -z "${start_time_str}" ]] || [[ "${start_time_str}" == "n/a" ]]; then
        echo ""
        return
    fi
    
    local start_time_sec
    start_time_sec=$(parse_date_to_seconds "${start_time_str}" 2>/dev/null)
    
    if [[ -z "${start_time_sec}" ]] || [[ ! "${start_time_sec}" =~ ^[0-9]+$ ]]; then
        echo ""
        return
    fi
    
    local current_time_sec
    current_time_sec=$(date +%s 2>/dev/null)
    
    if [[ -z "${current_time_sec}" ]] || [[ ! "${current_time_sec}" =~ ^[0-9]+$ ]]; then
        echo ""
        return
    fi
    
    local uptime_sec=$((current_time_sec - start_time_sec))
    
    if (( uptime_sec < 0 )); then
        echo ""
        return
    fi
    
    local days=$((uptime_sec / 86400))
    local hours=$(((uptime_sec % 86400) / 3600))
    local minutes=$(((uptime_sec % 3600) / 60))
    
    if (( days > 0 )); then
        echo "${days}d ${hours}h"
    elif (( hours > 0 )); then
        echo "${hours}h ${minutes}m"
    else
        echo "${minutes}m"
    fi
}

# Get systemd service status (systemd-only)
get_service_status() {
    local service_name="$1"
    
    if [[ "${INIT_SYSTEM}" != "systemd" ]]; then
        echo "unsupported"
        return
    fi
    
    if ! command -v systemctl >/dev/null 2>&1; then
        echo "unknown"
        return
    fi
    
    if systemctl is-active --quiet "${service_name}"; then
        echo "active"
    elif systemctl is-enabled --quiet "${service_name}" 2>/dev/null; then
        echo "enabled"
    else
        echo "inactive"
    fi
}

# FIXED: Real YAML validation using proper parsers
validate_yaml_syntax() {
    local yaml_file="$1"
    
    if [[ ! -f "${yaml_file}" ]]; then
        return 1
    fi
    
    if [[ ! -r "${yaml_file}" ]]; then
        return 1
    fi
    
    # Try Python YAML parser (most common)
    if command -v python3 >/dev/null 2>&1; then
        if python3 -c "import yaml; yaml.safe_load(open('${yaml_file}'))" 2>/dev/null; then
            return 0
        else
            return 2
        fi
    fi
    
    # Try yq YAML parser (if installed)
    if command -v yq >/dev/null 2>&1; then
        if yq eval '.' "${yaml_file}" >/dev/null 2>&1; then
            return 0
        else
            return 2
        fi
    fi
    
    # Try Perl YAML parser (fallback)
    if command -v perl >/dev/null 2>&1; then
        if perl -MYAML -e "YAML::LoadFile('${yaml_file}')" 2>/dev/null; then
            return 0
        else
            return 2
        fi
    fi
    
    # No YAML parser available - warn user
    log DEBUG "No YAML parser available (python3, yq, or perl). Basic syntax check only."
    
    # Basic sanity checks as absolute fallback
    if grep -q $'^\t' "${yaml_file}" 2>/dev/null; then
        return 2
    fi
    
    # If we reach here, we cannot validate properly
    return 3
}

# Get disk usage for a path
get_disk_usage_percent() {
    local path="$1"
    local usage
    
    if ! command -v df >/dev/null 2>&1; then
        echo "unknown"
        return
    fi
    
    usage=$(df "${path}" 2>/dev/null | tail -1 | awk '{if (NF >= 5) print $5; else print ""}' | sed 's/%//')
    
    if [[ -z "${usage}" ]]; then
        echo "unknown"
        return
    fi
    
    if [[ ! "${usage}" =~ ^[0-9]+$ ]]; then
        echo "unknown"
        return
    fi
    
    if (( usage < 0 || usage > 100 )); then
        echo "unknown"
        return
    fi
    
    echo "${usage}"
}

# Consolidated filesystem usage checker
check_filesystem_usage() {
    local mount_point="$1"
    local label="${2:-${mount_point}}"
    
    local usage
    usage=$(get_disk_usage_percent "${mount_point}")
    
    if [[ "${usage}" != "unknown" ]]; then
        if [[ "${usage}" =~ ^[0-9]+$ ]] && (( usage < WARN_DISK_PERCENT )); then
            print_status "${label}" "PASS" "Usage: ${usage}%"
        elif [[ "${usage}" =~ ^[0-9]+$ ]] && (( usage < CRIT_DISK_PERCENT )); then
            print_status "${label}" "WARN" "Usage elevated: ${usage}%"
        elif [[ "${usage}" =~ ^[0-9]+$ ]]; then
            print_status "${label}" "FAIL" "Usage critical: ${usage}%"
        else
            print_status "${label}" "WARN" "Cannot parse usage data"
        fi
    fi
}

# Get system file descriptor limits
get_fd_limits() {
    if [[ ! -f "/proc/sys/fs/file-max" ]]; then
        echo "unknown"
        return
    fi
    cat /proc/sys/fs/file-max 2>/dev/null || echo "unknown"
}

# Get current fd usage system-wide
get_fd_system_usage() {
    if [[ ! -f "/proc/sys/fs/file-nr" ]]; then
        echo "unknown"
        return
    fi
    awk '{print $1}' /proc/sys/fs/file-nr 2>/dev/null || echo "unknown"
}

# Check NTP/time sync status
check_time_sync_status() {
    if command -v timedatectl >/dev/null 2>&1; then
        if timedatectl status 2>/dev/null | grep -q "synchronized: yes\|NTP synchronized: yes"; then
            echo "synchronized"
        else
            echo "unsynchronized"
        fi
    elif [[ -f "/var/lib/systemd/timesync/clock" ]]; then
        echo "systemd-timesyncd"
    else
        echo "unknown"
    fi
}

# Get loaded ALSA kernel modules
get_alsa_modules() {
    if ! command -v lsmod >/dev/null 2>&1; then
        echo "unavailable"
        return
    fi
    
    local count
    count=$(lsmod 2>/dev/null | grep -cE "^snd|^soundcore" || true)
    count=${count:-0}
    if [[ ! "${count}" =~ ^[0-9]+$ ]]; then
        count=0
    fi
    echo "${count}"
}

# Validate MediaMTX config is valid YAML
validate_mediamtx_config() {
    local config_file="$1"
    
    if [[ ! -f "${config_file}" ]]; then
        return 2
    fi
    
    if ! is_readable "${config_file}"; then
        return 1
    fi
    
    validate_yaml_syntax "${config_file}"
}

# FIXED: Portable file ownership with BSD/BusyBox support
get_file_ownership() {
    local file="$1"
    
    if [[ ! -e "${file}" ]]; then
        echo "unknown"
        return
    fi
    
    if ! command -v stat >/dev/null 2>&1; then
        # Fallback: use ls parsing for BusyBox (with proper quoting)
        if command -v ls >/dev/null 2>&1; then
            # Use -n for numeric IDs to avoid spaces in usernames breaking parsing
            local ls_output
            ls_output=$(ls -ldn "${file}" 2>/dev/null)
            if [[ -n "${ls_output}" ]]; then
                # Extract 3rd and 4th fields (owner and group, numeric or names)
                local owner group
                owner=$(echo "${ls_output}" | awk '{print $3}')
                group=$(echo "${ls_output}" | awk '{print $4}')
                if [[ -n "${owner}" ]] && [[ -n "${group}" ]]; then
                    echo "${owner}:${group}"
                    return
                fi
            fi
        fi
        echo "unknown"
        return
    fi
    
    # Try GNU stat
    local result
    if result=$(stat -c '%U:%G' "${file}" 2>/dev/null); then
        echo "${result}"
        return
    fi
    
    # Try BSD/macOS stat (FIXED: use correct format)
    if result=$(stat -f '%Su:%Sg' "${file}" 2>/dev/null); then
        echo "${result}"
        return
    fi
    
    echo "unknown"
}

# FIXED: Portable file permissions with BSD support
get_file_permissions() {
    local file="$1"
    
    if [[ ! -e "${file}" ]]; then
        echo "unknown"
        return
    fi
    
    if ! command -v stat >/dev/null 2>&1; then
        # Fallback: use ls parsing for BusyBox (with proper quoting)
        if command -v ls >/dev/null 2>&1; then
            local ls_output perms
            ls_output=$(ls -ld "${file}" 2>/dev/null)
            if [[ -n "${ls_output}" ]]; then
                # Extract first field (permissions string)
                perms=$(echo "${ls_output}" | awk '{print $1}')
                if [[ -n "${perms}" ]]; then
                    # Return symbolic format instead of converting to octal
                    echo "${perms}"
                    return
                fi
            fi
        fi
        echo "unknown"
        return
    fi
    
    # Try GNU stat
    local result
    if result=$(stat -c '%a' "${file}" 2>/dev/null); then
        echo "${result}"
        return
    fi
    
    # Try BSD/macOS stat
    if result=$(stat -f '%OLp' "${file}" 2>/dev/null); then
        echo "${result}"
        return
    fi
    
    echo "unknown"
}

# Get process uptime from creation time
get_process_uptime_seconds() {
    local pid="$1"
    
    if [[ ! -f "/proc/${pid}/stat" ]] || [[ -z "${pid}" ]]; then
        echo "unknown"
        return
    fi
    
    local starttime
    starttime=$(awk '{print $22}' "/proc/${pid}/stat" 2>/dev/null)
    
    if [[ -z "${starttime}" ]] || [[ ! "${starttime}" =~ ^[0-9]+$ ]]; then
        echo "unknown"
        return
    fi
    
    if [[ ! -f "/proc/uptime" ]]; then
        echo "unknown"
        return
    fi
    
    local system_uptime
    system_uptime=$(awk '{print $1}' "/proc/uptime" 2>/dev/null)
    
    if [[ -z "${system_uptime}" ]]; then
        echo "unknown"
        return
    fi
    
    local tick_rate=100
    if [[ -f "/proc/sys/kernel/CONFIG_HZ" ]]; then
        tick_rate=$(cat /proc/sys/kernel/CONFIG_HZ 2>/dev/null || echo 100)
    fi
    
    local process_uptime
    process_uptime=$(awk -v tick="${tick_rate}" -v sys_up="${system_uptime}" -v start="${starttime}" \
        'BEGIN {printf "%.0f", (sys_up - (start / tick))}')
    
    if [[ -z "${process_uptime}" ]] || [[ ! "${process_uptime}" =~ ^[0-9]+$ ]] || (( process_uptime < 0 )); then
        echo "unknown"
        return
    fi
    
    echo "${process_uptime}"
}

# Check ALSA lock files for staleness
check_alsa_locks() {
    local stale_locks=0
    
    if [[ ! -d "/var/run" ]]; then
        echo "0"
        return
    fi
    
    if ! command -v find >/dev/null 2>&1; then
        echo "unknown"
        return
    fi
    
    local lock_count
    lock_count=$(find /var/run -name 'asound.*' -type f 2>/dev/null | wc -l)
    
    if [[ "${lock_count}" -gt 0 ]]; then
        stale_locks=$(find /var/run -name 'asound.*' -type f -mmin +60 2>/dev/null | wc -l)
    fi
    
    echo "${stale_locks}"
}

# FIXED: Explicit zero-check before division
get_fd_usage_percent() {
    local pid="$1"
    
    if [[ -z "${pid}" ]] || [[ ! -d "/proc/${pid}/fd" ]]; then
        echo "unknown"
        return
    fi
    
    local current_fds
    current_fds=$(find "/proc/${pid}/fd" -maxdepth 1 -type l 2>/dev/null | wc -l)
    
    if [[ -z "${current_fds}" ]] || [[ ! "${current_fds}" =~ ^[0-9]+$ ]]; then
        echo "unknown"
        return
    fi
    
    local fd_limit
    if [[ -f "/proc/${pid}/limits" ]]; then
        fd_limit=$(grep "Max open files" "/proc/${pid}/limits" 2>/dev/null | awk '{print $4}')
    fi
    
    # FIXED: Explicit zero-check guard
    if [[ -z "${fd_limit}" ]] || [[ ! "${fd_limit}" =~ ^[0-9]+$ ]] || (( fd_limit == 0 )); then
        echo "unknown"
        return
    fi
    
    local percent=$((current_fds * 100 / fd_limit))
    echo "${percent}"
}

# FIXED: Consolidated validation with explicit zero-check
get_inotify_usage() {
    local proc_inotify="/proc/sys/fs/inotify/max_user_watches"
    
    if [[ ! -f "${proc_inotify}" ]]; then
        echo "0 0"
        return
    fi
    
    local max_watches
    max_watches=$(cat "${proc_inotify}" 2>/dev/null)
    
    # FIXED: Single comprehensive validation including zero-check
    if [[ -z "${max_watches}" ]] || [[ ! "${max_watches}" =~ ^[0-9]+$ ]] || (( max_watches == 0 )); then
        echo "unknown unknown"
        return
    fi
    
    local current_watches=0
    if [[ -d "/proc" ]]; then
        current_watches=$(find /proc/*/fd -lname 'anon_inode:inotify' 2>/dev/null | wc -l)
    fi
    
    local percent=$((current_watches * 100 / max_watches))
    echo "${current_watches} ${percent}"
}

# Get entropy pool availability
get_entropy_available() {
    local entropy_file="/proc/sys/kernel/random/entropy_avail"
    
    if [[ ! -f "${entropy_file}" ]]; then
        echo "unknown"
        return
    fi
    
    cat "${entropy_file}" 2>/dev/null || echo "unknown"
}

# Check TCP time-wait connection count
get_tcp_timewait_connections() {
    if ! command -v ss >/dev/null 2>&1; then
        if command -v netstat >/dev/null 2>&1; then
            netstat -tan 2>/dev/null | grep -c "TIME_WAIT" || echo "0"
        else
            echo "unknown"
        fi
    else
        ss -tan 2>/dev/null | grep -c "TIME-WAIT" || echo "0"
    fi
}

# Get TCP ephemeral port range status
get_tcp_ephemeral_status() {
    local port_file="/proc/sys/net/ipv4/ip_local_port_range"
    
    if [[ ! -f "${port_file}" ]]; then
        echo "unavailable"
        return
    fi
    
    local range
    range=$(cat "${port_file}" 2>/dev/null)
    
    [[ -z "${range}" ]] && range="unavailable"
    echo "${range}"
}

# Check NTP offset if available
get_ntp_offset_ms() {
    if command -v ntpq >/dev/null 2>&1; then
        local offset
        offset=$(ntpq -p 2>/dev/null | grep -E '^\*|^o' | head -1 | awk '{print $(NF-2)}')
        
        if [[ -n "${offset}" ]] && [[ "${offset}" =~ ^-?[0-9]+\. ]]; then
            echo "${offset}"
        else
            echo "unknown"
        fi
    elif command -v chronyc >/dev/null 2>&1; then
        local offset
        offset=$(chronyc tracking 2>/dev/null | grep "Frequency offset" | awk '{print $(NF-1)}')
        
        [[ -n "${offset}" ]] && echo "${offset}" || echo "unknown"
    else
        echo "unavailable"
    fi
}

# Check for PulseAudio daemon
is_pulseaudio_running() {
    if command -v pgrep >/dev/null 2>&1; then
        pgrep -f "pulseaudio.*-D" >/dev/null 2>&1 && echo "true" || echo "false"
    else
        echo "unknown"
    fi
}

# Get ALSA device compatibility status
check_alsa_devices() {
    if [[ ! -d "/proc/asound" ]]; then
        echo "unavailable"
        return
    fi
    
    local cards_count
    cards_count=$(find /proc/asound -maxdepth 1 -name 'card*' -type d 2>/dev/null | wc -l)
    
    local devices_count
    devices_count=$(find /dev/snd -maxdepth 1 -name 'pcm*' -type c 2>/dev/null | wc -l)
    
    if (( cards_count > 0 && devices_count > 0 )); then
        echo "compatible"
    elif (( cards_count > 0 )); then
        echo "partial"
    else
        echo "unavailable"
    fi
}

# Check for configuration consistency
validate_device_config_consistency() {
    local config_file="$1"
    
    if [[ ! -f "${config_file}" ]]; then
        echo "unknown"
        return
    fi
    
    if ! command -v grep >/dev/null 2>&1; then
        echo "unknown"
        return
    fi
    
    local referenced_devices=0
    
    if is_readable "${config_file}"; then
        referenced_devices=$(grep -c "source:\|input:" "${config_file}" 2>/dev/null || echo 0)
        
        if [[ ! -f "${MEDIAMTX_DEVICE_CONFIG}" ]] || ! is_readable "${MEDIAMTX_DEVICE_CONFIG}"; then
            echo "config_unreadable"
            return
        fi
        
        local available_devices
        available_devices=$(grep -c "^[^ ].*:" "${MEDIAMTX_DEVICE_CONFIG}" 2>/dev/null || echo 0)
        
        if (( referenced_devices > available_devices )); then
            echo "mismatch"
        else
            echo "consistent"
        fi
    else
        echo "unreadable"
    fi
}

# Diagnostic Check 1: Prerequisites
check_prerequisites() {
    print_section "1. PREREQUISITES & DEPENDENCIES"
    
    if [[ "${BASH_VERSINFO[0]}" -lt 4 ]] || \
       { [[ "${BASH_VERSINFO[0]}" -eq 4 ]] && [[ "${BASH_VERSINFO[1]}" -lt 4 ]]; }; then
        print_status "Bash Version" "FAIL" "bash 4.4+ required (current: ${BASH_VERSION})"
        return
    fi
    print_status "Bash Version" "PASS" "bash ${BASH_VERSION}"
    
    local required_tools=("grep" "sed" "awk" "ps" "sort" "uniq" "cut" "date" "mkdir" "rm" "chmod")
    local missing_tools=()
    
    for tool in "${required_tools[@]}"; do
        if ! has_command "${tool}"; then
            missing_tools+=("${tool}")
        fi
    done
    
    if [[ ${#missing_tools[@]} -gt 0 ]]; then
        print_status "Required Utilities" "FAIL" "Missing: ${missing_tools[*]}"
        return
    fi
    print_status "Required Utilities" "PASS" "All standard utilities available"
    
    local optional_tools=("timeout" "lsof" "alsamixer" "ffmpeg")
    local missing_optional=()
    
    for tool in "${optional_tools[@]}"; do
        if ! has_command "${tool}"; then
            missing_optional+=("${tool}")
        fi
    done
    
    if [[ ${#missing_optional[@]} -gt 0 ]]; then
        print_status "Optional Tools" "WARN" "Some tools unavailable: ${missing_optional[*]}"
    else
        print_status "Optional Tools" "PASS" "All optional tools available"
    fi
    
    # Init system detection
    case "${INIT_SYSTEM}" in
        systemd)
            print_status "Init System" "PASS" "systemd detected - full diagnostics available"
            ;;
        openrc)
            print_status "Init System" "WARN" "OpenRC detected - limited systemd diagnostics"
            ;;
        *)
            print_status "Init System" "WARN" "Unknown init system - some diagnostics unavailable"
            ;;
    esac
    
    local current_user
    current_user="${USER:-${LOGNAME:-$(whoami 2>/dev/null || echo 'unknown')}}"
    if [[ "${current_user}" == "unknown" ]]; then
        print_status "User Context" "WARN" "Cannot determine user context"
    else
        print_status "User Context" "PASS" "Running as ${current_user}"
    fi
    
    if [[ ! -d "${DIAGNOSTIC_LOG_DIR}" ]]; then
        if mkdir -p "${DIAGNOSTIC_LOG_DIR}" 2>/dev/null; then
            print_status "Log Directory" "PASS" "Created: ${DIAGNOSTIC_LOG_DIR}"
        else
            print_status "Log Directory" "WARN" "Cannot create: ${DIAGNOSTIC_LOG_DIR}"
        fi
    elif [[ -w "${DIAGNOSTIC_LOG_DIR}" ]]; then
        print_status "Log Directory" "PASS" "Writable: ${DIAGNOSTIC_LOG_DIR}"
    else
        print_status "Log Directory" "WARN" "Not writable: ${DIAGNOSTIC_LOG_DIR}"
    fi
}

# Diagnostic Check 2: Project Information and Versions
check_project_info() {
    print_section "2. PROJECT INFORMATION & VERSIONS"
    
    local diag_version="${SCRIPT_VERSION}"
    print_status "Diagnostics Script" "INFO" "v${diag_version}"
    
    local orch_path
    orch_path=$(command -v lyrebird-orchestrator.sh 2>/dev/null || echo "${SCRIPT_DIR}/lyrebird-orchestrator.sh")
    if [[ -f "${orch_path}" ]]; then
        local orch_version
        orch_version=$(get_script_version "${orch_path}")
        print_status "Orchestrator" "INFO" "v${orch_version}"
    else
        print_status "Orchestrator" "WARN" "Script not found"
    fi
    
    local updater_path
    updater_path=$(command -v lyrebird-updater.sh 2>/dev/null || echo "${SCRIPT_DIR}/lyrebird-updater.sh")
    if [[ -f "${updater_path}" ]]; then
        local updater_version
        updater_version=$(get_script_version "${updater_path}")
        print_status "Updater" "INFO" "v${updater_version}"
    else
        print_status "Updater" "WARN" "Script not found"
    fi
    
    local stream_mgr_path
    stream_mgr_path=$(find_stream_manager)
    if [[ -n "${stream_mgr_path}" ]] && [[ -f "${stream_mgr_path}" ]]; then
        local stream_mgr_version
        stream_mgr_version=$(get_script_version "${stream_mgr_path}")
        print_status "Stream Manager" "INFO" "v${stream_mgr_version}"
    else
        print_status "Stream Manager" "WARN" "Script not found"
    fi
    
    local usb_mapper_path
    usb_mapper_path=$(command -v usb-audio-mapper.sh 2>/dev/null || echo "${SCRIPT_DIR}/usb-audio-mapper.sh")
    if [[ -f "${usb_mapper_path}" ]]; then
        local usb_mapper_version
        usb_mapper_version=$(get_script_version "${usb_mapper_path}")
        print_status "USB Audio Mapper" "INFO" "v${usb_mapper_version}"
    else
        print_status "USB Audio Mapper" "WARN" "Script not found"
    fi
    
    local mediamtx_version
    mediamtx_version=$(get_mediamtx_version)
    if [[ "${mediamtx_version}" != "unknown" ]]; then
        print_status "MediaMTX" "INFO" "v${mediamtx_version}"
    else
        print_status "MediaMTX" "WARN" "Cannot determine version"
    fi
    
    local stream_mgr_status
    stream_mgr_status=$(get_stream_manager_status)
    case "${stream_mgr_status}" in
        running)
            local uptime
            uptime=$(get_service_uptime "mediamtx-audio")
            if [[ -n "${uptime}" ]]; then
                print_status "Stream Manager Status" "PASS" "Running (${uptime})"
            else
                print_status "Stream Manager Status" "PASS" "Running"
            fi
            ;;
        stopped)
            print_status "Stream Manager Status" "WARN" "Stopped"
            ;;
        *)
            print_status "Stream Manager Status" "INFO" "Not configured"
            ;;
    esac
    
    local device_count
    device_count=$(get_configured_devices)
    if [[ "${device_count}" -gt 0 ]]; then
        local device_names
        device_names=$(get_device_names)
        print_status "Configured Devices" "PASS" "${device_count} device(s): ${device_names}"
    else
        print_status "Configured Devices" "WARN" "No devices configured"
    fi
}

# Diagnostic Check 2b: Project Scripts Permissions & Git Status
check_project_files() {
    print_section "2b. PROJECT FILES & GIT STATUS"
    
    local scripts=("lyrebird-orchestrator.sh" "lyrebird-updater.sh" "mediamtx-stream-manager.sh" "usb-audio-mapper.sh")
    for script in "${scripts[@]}"; do
        local script_path
        script_path=$(command -v "${script}" 2>/dev/null || echo "${SCRIPT_DIR}/${script}")
        
        if [[ -f "${script_path}" ]]; then
            local perms
            perms=$(get_file_permissions "${script_path}")
            local owner
            owner=$(get_file_ownership "${script_path}")
            
            if [[ "${perms}" != "unknown" ]]; then
                print_status "${script}" "INFO" "Owner: ${owner}, Perms: ${perms}"
            else
                print_status "${script}" "WARN" "Found but unable to read permissions"
            fi
        else
            print_status "${script}" "WARN" "Not found"
        fi
    done
    
    if [[ -d "${SCRIPT_DIR}/.git" ]]; then
        print_status "Git Repository" "INFO" "Present at ${SCRIPT_DIR}"
        
        if has_command git; then
            local git_branch
            git_branch=$(cd "${SCRIPT_DIR}" && git rev-parse --abbrev-ref HEAD 2>/dev/null || echo "unknown")
            print_status "Git Branch" "INFO" "${git_branch}"
            
            local git_commit
            git_commit=$(cd "${SCRIPT_DIR}" && git rev-parse --short HEAD 2>/dev/null || echo "unknown")
            print_status "Git Commit" "INFO" "${git_commit}"
            
            local git_status
            git_status=$(cd "${SCRIPT_DIR}" && git status --short 2>/dev/null || echo "unknown")
            if [[ -z "${git_status}" ]]; then
                print_status "Git Status" "PASS" "Clean (no uncommitted changes)"
            else
                print_status "Git Status" "WARN" "Uncommitted changes present"
            fi
        else
            print_status "Git Tools" "WARN" "git not available"
        fi
    else
        print_status "Git Repository" "INFO" "Not a git repository"
    fi
}

# Diagnostic Check 2c: Log Locations & Accessibility
check_log_locations() {
    print_section "2c. LOG FILES & ACCESSIBILITY"
    
    if [[ -f "${DIAGNOSTIC_LOG_FILE}" ]]; then
        local log_size
        log_size=$(get_file_size "${DIAGNOSTIC_LOG_FILE}")
        local log_owner
        log_owner=$(get_file_ownership "${DIAGNOSTIC_LOG_FILE}")
        local log_perms
        log_perms=$(get_file_permissions "${DIAGNOSTIC_LOG_FILE}")
        
        if is_readable "${DIAGNOSTIC_LOG_FILE}"; then
            print_status "Diagnostics Log" "PASS" "${DIAGNOSTIC_LOG_FILE} (${log_size} bytes, ${log_owner}, ${log_perms})"
        else
            print_status "Diagnostics Log" "WARN" "Not readable (${log_owner}, ${log_perms})"
        fi
    else
        if [[ -w "${DIAGNOSTIC_LOG_DIR}" ]]; then
            print_status "Diagnostics Log" "INFO" "Log directory writable, file not yet created"
        else
            print_status "Diagnostics Log" "WARN" "Log directory not writable: ${DIAGNOSTIC_LOG_DIR}"
        fi
    fi
    
    if [[ -f "${MEDIAMTX_LOG_FILE}" ]]; then
        local mtx_log_size
        mtx_log_size=$(get_file_size "${MEDIAMTX_LOG_FILE}")
        local mtx_log_owner
        mtx_log_owner=$(get_file_ownership "${MEDIAMTX_LOG_FILE}")
        local mtx_log_perms
        mtx_log_perms=$(get_file_permissions "${MEDIAMTX_LOG_FILE}")
        
        if is_readable "${MEDIAMTX_LOG_FILE}"; then
            print_status "MediaMTX Log" "PASS" "${MEDIAMTX_LOG_FILE} (${mtx_log_size} bytes, ${mtx_log_owner}, ${mtx_log_perms})"
        else
            print_status "MediaMTX Log" "WARN" "Not readable (${mtx_log_owner}, ${mtx_log_perms})"
        fi
    else
        print_status "MediaMTX Log" "WARN" "Not found: ${MEDIAMTX_LOG_FILE}"
    fi
    
    if [[ -d "${FFMPEG_LOG_DIR}" ]]; then
        local ffmpeg_log_owner
        ffmpeg_log_owner=$(get_file_ownership "${FFMPEG_LOG_DIR}")
        local ffmpeg_log_perms
        ffmpeg_log_perms=$(get_file_permissions "${FFMPEG_LOG_DIR}")
        
        if [[ -w "${FFMPEG_LOG_DIR}" ]]; then
            print_status "FFmpeg Log Dir" "PASS" "${FFMPEG_LOG_DIR} (${ffmpeg_log_owner}, ${ffmpeg_log_perms})"
        else
            print_status "FFmpeg Log Dir" "WARN" "Not writable (${ffmpeg_log_owner}, ${ffmpeg_log_perms})"
        fi
    else
        print_status "FFmpeg Log Dir" "INFO" "Not found: ${FFMPEG_LOG_DIR}"
    fi
}

check_system_info() {
    print_section "3. SYSTEM INFORMATION"
    
    if [[ -f "/etc/os-release" ]]; then
        local os_name
        os_name="$(grep '^PRETTY_NAME=' /etc/os-release 2>/dev/null | cut -d'=' -f2 | tr -d '"')"
        if [[ -n "${os_name}" ]]; then
            print_status "Operating System" "INFO" "${os_name}"
        fi
    fi
    
    local kernel_release
    kernel_release="$(uname -r 2>/dev/null || echo 'unknown')"
    print_status "Kernel Version" "INFO" "${kernel_release}"
    
    local arch
    arch="$(uname -m 2>/dev/null || echo 'unknown')"
    print_status "Architecture" "INFO" "${arch}"
    
    if [[ -f "/proc/cpuinfo" ]]; then
        local cpu_count
        cpu_count=$(grep -c "^processor" /proc/cpuinfo 2>/dev/null || true)
        cpu_count=${cpu_count:-0}
        if [[ "${cpu_count}" =~ ^[0-9]+$ ]] && (( cpu_count > 0 )); then
            print_status "CPU Count" "INFO" "${cpu_count} core(s)"
        fi
    fi
    
    if [[ -f "/proc/meminfo" ]]; then
        local memtotal
        memtotal="$(grep "^MemTotal:" /proc/meminfo 2>/dev/null | awk '{print $2}' || echo 0)"
        if [[ "${memtotal}" =~ ^[0-9]+$ ]] && (( memtotal > 0 )); then
            local memtotal_mb=$((memtotal / 1024))
            print_status "Total Memory" "INFO" "${memtotal_mb}MB"
        fi
    fi
    
    local uptime
    if [[ -f "/proc/uptime" ]]; then
        uptime="$(awk '{printf "%.0f", $1 / 86400}' /proc/uptime 2>/dev/null || echo 'unknown')"
        print_status "System Uptime" "INFO" "${uptime} days"
    fi
}

# Diagnostic Check 3: USB Devices
check_usb_devices() {
    print_section "4. USB AUDIO DEVICES"
    
    if [[ ! -d "/proc/asound" ]]; then
        print_status "ALSA Status" "FAIL" "/proc/asound not found (ALSA not loaded)"
        return
    fi
    print_status "ALSA Status" "PASS" "ALSA subsystem available"
    
    if [[ -f "/proc/asound/cards" ]]; then
        local card_count=0
        local usb_count=0
        local hdmi_count=0
        local other_count=0
        
        while IFS= read -r line; do
            if [[ "${line}" =~ ^\ ([0-9]+)\ \[([^\]]+)\] ]]; then
                local card_num="${BASH_REMATCH[1]}"
                local card_name="${BASH_REMATCH[2]}"
                ((++card_count))
                
                local card_dir="/proc/asound/card${card_num}"
                if [[ -f "${card_dir}/usbid" ]]; then
                    ((++usb_count))
                    log DEBUG "Card ${card_num} (${card_name}): USB device"
                elif [[ "${card_name}" =~ HDMI ]] || [[ "${card_name}" =~ vc4-hdmi ]]; then
                    ((++hdmi_count))
                    log DEBUG "Card ${card_num} (${card_name}): HDMI device"
                else
                    ((++other_count))
                    log DEBUG "Card ${card_num} (${card_name}): Other device"
                fi
            fi
        done < /proc/asound/cards
        
        if [[ "${card_count}" -eq 0 ]]; then
            print_status "Audio Devices" "WARN" "No audio devices found"
        else
            if [[ "${usb_count}" -gt 0 ]]; then
                print_status "USB Audio Devices" "PASS" "${usb_count} device(s)"
            else
                print_status "USB Audio Devices" "WARN" "No USB audio devices detected"
            fi
            
            if [[ "${hdmi_count}" -gt 0 ]] || [[ "${other_count}" -gt 0 ]]; then
                local system_detail="Total system: ${card_count} card(s) ("
                
                [[ "${usb_count}" -gt 0 ]] && system_detail="${system_detail}USB: ${usb_count}, "
                [[ "${hdmi_count}" -gt 0 ]] && system_detail="${system_detail}HDMI: ${hdmi_count}, "
                [[ "${other_count}" -gt 0 ]] && system_detail="${system_detail}Other: ${other_count}, "
                
                system_detail="${system_detail%, })"
                
                print_status "System Audio Cards" "INFO" "${system_detail}"
            fi
        fi
    else
        print_status "Audio Devices" "WARN" "Cannot read /proc/asound/cards"
    fi
    
    if [[ -d "/sys/bus/usb/devices" ]]; then
        local usb_audio_count=0
        local usb_device
        
        for usb_device in /sys/bus/usb/devices/*/; do
            if [[ -f "${usb_device}/bDeviceClass" ]]; then
                ((++usb_audio_count))
            fi
        done
        
        if [[ "${usb_audio_count}" -gt 0 ]]; then
            print_status "USB Devices" "PASS" "Found ${usb_audio_count} USB device(s)"
        else
            print_status "USB Devices" "WARN" "No USB devices detected"
        fi
    else
        print_status "USB Devices" "WARN" "Cannot check USB devices"
    fi
    
    local udev_rules_file="/etc/udev/rules.d/99-usb-soundcards.rules"
    if [[ -f "${udev_rules_file}" ]]; then
        local rule_count
        rule_count=$(grep -cvE '^\s*(#|$)' "${udev_rules_file}" 2>/dev/null || true)
        rule_count=${rule_count:-0}
        if [[ ! "${rule_count}" =~ ^[0-9]+$ ]]; then
            rule_count=0
        fi
        
        if [[ "${rule_count}" -gt 0 ]]; then
            print_status "USB Persistence" "PASS" "Found ${rule_count} udev rule(s)"
        else
            print_status "USB Persistence" "WARN" "Udev rules file exists but appears empty"
        fi
    else
        print_status "USB Persistence" "WARN" "No USB persistence rules configured"
    fi
}

# Diagnostic Check 4: Audio Capabilities
check_audio_capabilities() {
    print_section "5. AUDIO CAPABILITIES"
    
    if has_command alsamixer; then
        if run_with_timeout "${TIMEOUT_SECONDS}" alsamixer -h >/dev/null 2>&1; then
            print_status "ALSA Mixer" "PASS" "alsamixer available"
        else
            print_status "ALSA Mixer" "WARN" "alsamixer not responsive"
        fi
    else
        print_status "ALSA Mixer" "WARN" "alsamixer not installed"
    fi
    
    if [[ -d "/proc/asound" ]]; then
        local format_count=0
        if [[ -f "/proc/asound/card0/pcm0p/info" ]]; then
            ((++format_count))
        fi
        
        if [[ "${format_count}" -gt 0 ]]; then
            print_status "Audio Formats" "PASS" "Standard audio formats available"
        else
            print_status "Audio Formats" "INFO" "No PCM device info available"
        fi
    fi
    
    if has_command ffmpeg; then
        local encoders
        encoders=$(ffmpeg -encoders 2>/dev/null | grep -c "aac\|opus\|mp3" || true)
        encoders=${encoders:-0}
        if [[ ! "${encoders}" =~ ^[0-9]+$ ]]; then
            encoders=0
        fi
        
        if [[ "${encoders}" -gt 0 ]]; then
            print_status "Codecs" "PASS" "Audio codecs available (ffmpeg)"
        else
            print_status "Codecs" "WARN" "ffmpeg available but limited codecs"
        fi
    else
        print_status "Codecs" "WARN" "ffmpeg not available for encoding support"
    fi
}

# Diagnostic Check 5: MediaMTX Service
check_mediamtx_service() {
    print_section "6. MEDIAMTX SERVICE"
    
    if ! validate_port "${MEDIAMTX_PORT}"; then
        print_status "RTSP Port" "FAIL" "Invalid port number: ${MEDIAMTX_PORT}"
        return
    fi
    
    if [[ ! -f "${MEDIAMTX_BINARY}" ]]; then
        print_status "MediaMTX Binary" "FAIL" "Not found: ${MEDIAMTX_BINARY}"
        return
    fi
    print_status "MediaMTX Binary" "PASS" "Found: ${MEDIAMTX_BINARY}"
    
    if [[ ! -x "${MEDIAMTX_BINARY}" ]]; then
        print_status "Binary Executable" "WARN" "Binary not executable"
    else
        print_status "Binary Executable" "PASS" "Binary is executable"
    fi
    
    local config_file
    config_file="$(get_mediamtx_config_file)"
    
    if [[ ! -f "${config_file}" ]]; then
        print_status "Config File" "WARN" "Not found: ${config_file}"
    elif ! is_readable "${config_file}"; then
        print_status "Config File" "WARN" "Not readable: ${config_file}"
    else
        print_status "Config File" "PASS" "Found: ${config_file}"
    fi
    
    if is_readable "${config_file}"; then
        local path_count
        path_count=$(grep -cE "^[[:space:]]+[a-zA-Z0-9_-]+:" "${config_file}" 2>/dev/null || true)
        path_count=${path_count:-0}
        if [[ ! "${path_count}" =~ ^[0-9]+$ ]]; then
            path_count=0
        fi
        
        if [[ ${path_count} -gt 0 ]]; then
            print_status "Device Config" "PASS" "Found with ${path_count} RTSP path(s) configured"
        else
            print_status "Device Config" "WARN" "MediaMTX config readable but no paths configured"
        fi
    elif [[ -f "${config_file}" ]]; then
        print_status "Device Config" "WARN" "MediaMTX config file not readable"
    else
        print_status "Device Config" "WARN" "MediaMTX config file not found"
    fi
    
    if [[ -n "${MEDIAMTX_PID}" ]]; then
        print_status "Service Running" "PASS" "MediaMTX running (PID: ${MEDIAMTX_PID})"
    else
        print_status "Service Running" "WARN" "MediaMTX not currently running"
    fi
    
    if has_command netstat || has_command ss; then
        local listening=false
        if has_command ss; then
            if ss -tlnp 2>/dev/null | grep -qE ":${MEDIAMTX_PORT}[[:space:]]"; then
                listening=true
            fi
        elif has_command netstat; then
            if netstat -tlnp 2>/dev/null | grep -qE ":${MEDIAMTX_PORT}[[:space:]]"; then
                listening=true
            fi
        fi
        
        if [[ "${listening}" == "true" ]]; then
            print_status "RTSP Port" "PASS" "Listening on port ${MEDIAMTX_PORT}"
        else
            print_status "RTSP Port" "WARN" "Not listening on port ${MEDIAMTX_PORT}"
        fi
    else
        print_status "RTSP Port" "INFO" "Cannot check port status (netstat/ss not available)"
    fi
}

# Diagnostic Check 6: Stream Health
check_stream_health() {
    print_section "7. STREAM HEALTH & STATUS"
    
    if [[ -f "${MEDIAMTX_LOG_FILE}" ]]; then
        if is_readable "${MEDIAMTX_LOG_FILE}"; then
            local log_size
            log_size=$(get_file_size "${MEDIAMTX_LOG_FILE}")
            log_size=$((log_size + 0))
            
            if [[ "${log_size}" -lt "${DIAGNOSTIC_MAX_LOG_SIZE}" ]]; then
                print_status "Log File" "PASS" "MediaMTX log file: ${log_size} bytes"
            else
                print_status "Log File" "WARN" "Log file large: ${log_size} bytes (may need rotation)"
            fi
        else
            print_status "Log File" "WARN" "Log file not readable"
        fi
    else
        print_status "Log File" "WARN" "Log file not found: ${MEDIAMTX_LOG_FILE}"
    fi
    
    if [[ -f "${MEDIAMTX_LOG_FILE}" ]] && is_readable "${MEDIAMTX_LOG_FILE}"; then
        local error_count
        error_count=$(($(tail -n "${DIAGNOSTIC_LOG_TAIL_LINES}" "${MEDIAMTX_LOG_FILE}" 2>/dev/null | grep -ic "error\|fail") + 0))
        
        if [[ "${error_count}" -gt 10 ]]; then
            print_status "Recent Errors" "WARN" "Found ${error_count} errors in recent logs"
        elif [[ "${error_count}" -gt 0 ]]; then
            print_status "Recent Errors" "INFO" "Found ${error_count} errors in recent logs"
        else
            print_status "Recent Errors" "PASS" "No recent errors detected"
        fi
    fi
}

# Diagnostic Check 7: RTSP Connectivity
check_rtsp_connectivity() {
    print_section "8. RTSP CONNECTIVITY"
    
    local host="${MEDIAMTX_HOST}"
    local port="${MEDIAMTX_PORT}"
    
    if ! validate_port "${port}"; then
        print_status "RTSP Port" "FAIL" "Invalid port configuration: ${port}"
        return
    fi
    
    if check_rtsp_reachable "${host}" "${port}" "${TIMEOUT_SECONDS}"; then
        print_status "RTSP Server" "PASS" "Reachable at ${host}:${port}"
    elif has_command nc || [[ -n "${BASH_VERSION}" ]]; then
        print_status "RTSP Server" "WARN" "Cannot reach ${host}:${port}"
    else
        print_status "RTSP Server" "INFO" "Cannot test connectivity (nc/bash not available)"
    fi
    
    if [[ -d "/proc/net/igmp" ]]; then
        print_status "Multicast" "PASS" "Kernel multicast support available"
    else
        print_status "Multicast" "INFO" "Cannot verify multicast support"
    fi
}

# Diagnostic Check 8: Resource Usage
check_resource_usage() {
    print_section "9. RESOURCE USAGE"
    
    if [[ -z "${MEDIAMTX_PID}" ]]; then
        print_status "Memory Usage" "INFO" "MediaMTX not running - cannot check"
        print_status "CPU Usage" "INFO" "MediaMTX not running - cannot check"
        print_status "File Descriptors" "INFO" "MediaMTX not running - cannot check"
        return
    fi
    
    if [[ -f "/proc/${MEDIAMTX_PID}/status" ]]; then
        local vm_rss
        vm_rss="$(grep "^VmRSS:" "/proc/${MEDIAMTX_PID}/status" 2>/dev/null | awk '{print $2}' || echo 0)"
        if [[ "${vm_rss}" =~ ^[0-9]+$ ]]; then
            local vm_rss_mb=$((vm_rss / 1024))
            
            if [[ "${vm_rss_mb}" -lt "${WARN_MEMORY_MB}" ]]; then
                print_status "Memory Usage" "PASS" "MediaMTX using ${vm_rss_mb}MB"
            elif [[ "${vm_rss_mb}" -lt "${CRIT_MEMORY_MB}" ]]; then
                print_status "Memory Usage" "WARN" "Memory usage elevated: ${vm_rss_mb}MB"
            else
                print_status "Memory Usage" "FAIL" "Memory usage critical: ${vm_rss_mb}MB"
            fi
        else
            print_status "Memory Usage" "WARN" "Cannot read memory status"
        fi
    else
        print_status "Memory Usage" "WARN" "Cannot read process status"
    fi
    
    if has_command ps; then
        local cpu_usage
        cpu_usage="$(ps -p "${MEDIAMTX_PID}" -o %cpu= 2>/dev/null | tr -d ' ' || echo 0)"
        
        if [[ -z "${cpu_usage}" ]] || [[ "${cpu_usage}" == "0" ]]; then
            print_status "CPU Usage" "PASS" "CPU usage normal"
        else
            local cpu_int
            cpu_int="${cpu_usage%.*}"
            
            if [[ "${cpu_int}" -lt "${WARN_CPU_PERCENT}" ]]; then
                print_status "CPU Usage" "PASS" "CPU: ${cpu_usage}%"
            elif [[ "${cpu_int}" -lt "${CRIT_CPU_PERCENT}" ]]; then
                print_status "CPU Usage" "WARN" "CPU elevated: ${cpu_usage}%"
            else
                print_status "CPU Usage" "FAIL" "CPU critical: ${cpu_usage}%"
            fi
        fi
    fi
    
    if [[ -d "/proc/${MEDIAMTX_PID}/fd" ]]; then
        local fd_count
        fd_count="$(find "/proc/${MEDIAMTX_PID}/fd" -maxdepth 1 -type l 2>/dev/null | wc -l)"
        
        if [[ "${fd_count}" -lt "${WARN_FD_COUNT}" ]]; then
            print_status "File Descriptors" "PASS" "Using ${fd_count} FDs"
        elif [[ "${fd_count}" -lt "${CRIT_FD_COUNT}" ]]; then
            print_status "File Descriptors" "WARN" "FD usage elevated: ${fd_count}"
        else
            print_status "File Descriptors" "FAIL" "FD usage critical: ${fd_count}"
        fi
    else
        print_status "File Descriptors" "INFO" "Cannot check FD usage"
    fi
}

# Diagnostic Check 9: Log Analysis
check_log_analysis() {
    print_section "10. LOG ANALYSIS"
    
    if [[ ! -f "${MEDIAMTX_LOG_FILE}" ]] || ! is_readable "${MEDIAMTX_LOG_FILE}"; then
        print_status "Log File Access" "WARN" "Cannot read log file: ${MEDIAMTX_LOG_FILE}"
        return
    fi
    
    print_status "Log File Access" "PASS" "Log file readable"
    
    local total_lines
    total_lines=$(wc -l < "${MEDIAMTX_LOG_FILE}" 2>/dev/null || echo 0)
    print_status "Log Size" "INFO" "Total lines: ${total_lines}"
    
    local error_lines
    error_lines=$(($(tail -n "${DIAGNOSTIC_LOG_TAIL_LINES}" "${MEDIAMTX_LOG_FILE}" 2>/dev/null | grep -ic "error" || echo 0)))
    local warn_lines
    warn_lines=$(($(tail -n "${DIAGNOSTIC_LOG_TAIL_LINES}" "${MEDIAMTX_LOG_FILE}" 2>/dev/null | grep -ic "warn" || echo 0)))
    
    if [[ "${error_lines}" -gt 0 ]]; then
        print_status "Error Patterns" "WARN" "Found ${error_lines} error line(s)"
    else
        print_status "Error Patterns" "PASS" "No error patterns detected"
    fi
    
    if [[ "${warn_lines}" -gt 0 ]]; then
        print_status "Warning Patterns" "INFO" "Found ${warn_lines} warning line(s)"
    fi
    
    local recent_warnings
    recent_warnings=$(get_recent_log_warnings)
    if [[ "${recent_warnings}" -gt 0 ]]; then
        print_status "Last 24 Hours" "INFO" "Found ${recent_warnings} warn/error event(s)"
    else
        print_status "Last 24 Hours" "PASS" "No issues in last 24 hours"
    fi
}

# Diagnostic Check 10: System Limits
check_system_limits() {
    print_section "11. SYSTEM LIMITS & CONFIGURATION"
    
    local fd_limit
    fd_limit=$(get_fd_limits)
    if [[ "${fd_limit}" != "unknown" ]] && [[ "${fd_limit}" =~ ^[0-9]+$ ]]; then
        if (( fd_limit >= MIN_FD_LIMIT )); then
            print_status "System FD Limit" "PASS" "Max: ${fd_limit} FDs"
        else
            print_status "System FD Limit" "WARN" "Low limit: ${fd_limit} FDs (min: ${MIN_FD_LIMIT})"
        fi
    else
        print_status "System FD Limit" "INFO" "Cannot determine"
    fi
    
    local fd_usage
    fd_usage=$(get_fd_system_usage)
    if [[ "${fd_usage}" != "unknown" ]]; then
        print_status "System FD Usage" "INFO" "Currently: ${fd_usage} open"
    fi
    
    if [[ -n "${MEDIAMTX_PID}" ]]; then
        if [[ -f "/proc/${MEDIAMTX_PID}/limits" ]]; then
            local max_fds
            max_fds=$(grep "Max open files" "/proc/${MEDIAMTX_PID}/limits" 2>/dev/null | awk '{print $4}' | head -1)
            if [[ -n "${max_fds}" ]] && [[ "${max_fds}" =~ ^[0-9]+$ ]]; then
                print_status "MediaMTX FD Soft Limit" "INFO" "${max_fds} FDs"
            fi
        fi
    fi
    
    if [[ -f "/proc/sys/net/ipv4/ip_local_port_range" ]]; then
        local port_range
        port_range=$(cat /proc/sys/net/ipv4/ip_local_port_range 2>/dev/null)
        if [[ -n "${port_range}" ]]; then
            print_status "Ephemeral Port Range" "INFO" "${port_range}"
        fi
    fi
}

# Diagnostic Check 11: Disk Health
check_disk_health() {
    print_section "12. DISK & STORAGE"
    
    if ! command -v df >/dev/null 2>&1; then
        print_status "Disk Check" "INFO" "df command not available"
        return
    fi
    
    check_filesystem_usage "/" "Root Filesystem"
    check_filesystem_usage "/var" "/var Filesystem"
    check_filesystem_usage "/tmp" "/tmp Filesystem"
}

# Diagnostic Check 12: Configuration Validity
check_configuration_validity() {
    print_section "13. CONFIGURATION VALIDATION"
    
    local config_file
    config_file="$(get_mediamtx_config_file)"
    
    if [[ ! -f "${config_file}" ]]; then
        print_status "MediaMTX Config" "WARN" "Config file not found: ${config_file}"
        return
    fi
    
    if ! is_readable "${config_file}"; then
        print_status "MediaMTX Config" "WARN" "Config file not readable"
        return
    fi
    
    print_status "MediaMTX Config" "PASS" "Config file accessible"
    
    local validation_result
    validate_mediamtx_config "${config_file}"
    validation_result=$?
    
    case "${validation_result}" in
        0)
            print_status "YAML Syntax" "PASS" "Valid YAML format"
            ;;
        1)
            print_status "YAML Syntax" "WARN" "Cannot read file"
            ;;
        2)
            print_status "YAML Syntax" "FAIL" "Invalid YAML syntax detected"
            ;;
        3)
            print_status "YAML Syntax" "WARN" "No YAML parser available - install python3/yq/perl for validation"
            ;;
        *)
            print_status "YAML Syntax" "WARN" "YAML validation failed"
            ;;
    esac
    
    if [[ -f "${MEDIAMTX_DEVICE_CONFIG}" ]] && is_readable "${MEDIAMTX_DEVICE_CONFIG}"; then
        local stream_count
        stream_count=$(get_stream_source_count)
        if [[ "${stream_count}" -gt 0 ]]; then
            print_status "Configured Streams" "PASS" "Found ${stream_count} stream source(s)"
        else
            print_status "Configured Streams" "INFO" "No stream sources configured"
        fi
    else
        print_status "Configured Streams" "WARN" "Cannot read stream configuration"
    fi
}

# Diagnostic Check 13: Time Synchronization
check_time_synchronization() {
    print_section "14. TIME & CLOCK SYNCHRONIZATION"
    
    local time_sync
    time_sync=$(check_time_sync_status)
    case "${time_sync}" in
        synchronized)
            print_status "NTP Status" "PASS" "System time synchronized"
            ;;
        systemd-timesyncd)
            print_status "NTP Status" "PASS" "Using systemd-timesyncd"
            ;;
        unsynchronized)
            print_status "NTP Status" "WARN" "System time not synchronized"
            ;;
        *)
            print_status "NTP Status" "INFO" "Cannot determine synchronization status"
            ;;
    esac
    
    if [[ -f "/etc/timezone" ]]; then
        local tz
        tz=$(cat /etc/timezone 2>/dev/null)
        if [[ -n "${tz}" ]]; then
            print_status "Timezone" "INFO" "${tz}"
        fi
    fi
    
    if command -v date >/dev/null 2>&1; then
        local system_time
        system_time=$(date '+%Y-%m-%d %H:%M:%S %Z' 2>/dev/null)
        if [[ -n "${system_time}" ]]; then
            print_status "System Time" "INFO" "${system_time}"
        fi
    fi
}

# Diagnostic Check 15: Service Configuration
check_service_configuration() {
    print_section "15. SERVICE & ${INIT_SYSTEM^^} STATUS"
    
    if [[ "${INIT_SYSTEM}" != "systemd" ]]; then
        print_status "Init System" "INFO" "${INIT_SYSTEM} detected - systemd-specific checks skipped"
        return
    fi
    
    if ! command -v systemctl >/dev/null 2>&1; then
        print_status "systemd" "INFO" "systemctl not available"
        return
    fi
    
    local mediamtx_service_status
    mediamtx_service_status=$(get_service_status "mediamtx" 2>/dev/null)
    case "${mediamtx_service_status}" in
        active)
            print_status "MediaMTX Service" "PASS" "Active"
            ;;
        enabled)
            print_status "MediaMTX Service" "INFO" "Enabled but not running"
            ;;
        inactive|unknown)
            print_status "MediaMTX Service" "INFO" "Not configured as systemd service"
            ;;
    esac
    
    local audio_service_status
    audio_service_status=$(get_service_status "mediamtx-audio" 2>/dev/null)
    case "${audio_service_status}" in
        active)
            print_status "Stream Manager Service" "PASS" "Active"
            ;;
        enabled)
            print_status "Stream Manager Service" "INFO" "Enabled but not running"
            ;;
        inactive|unknown)
            print_status "Stream Manager Service" "INFO" "Not configured as systemd service"
            ;;
    esac
    
    if systemctl list-unit-files "mediamtx*" 2>/dev/null | grep -q mediamtx; then
        local service_count
        service_count=$(systemctl list-unit-files "mediamtx*" 2>/dev/null | grep -c mediamtx || true)
        service_count=${service_count:-0}
        if [[ ! "${service_count}" =~ ^[0-9]+$ ]]; then
            service_count=0
        fi
        print_status "Registered Services" "INFO" "Found ${service_count} service(s)"
    fi
}

# Diagnostic Check 16: File Permissions and Ownership
check_file_permissions_validity() {
    print_section "16. FILE PERMISSIONS & OWNERSHIP"
    
    if [[ ! -f "${MEDIAMTX_BINARY}" ]]; then
        print_status "MediaMTX Binary" "WARN" "Not found: ${MEDIAMTX_BINARY}"
        return
    fi
    
    if ! is_readable "${MEDIAMTX_BINARY}"; then
        print_status "Binary Readable" "FAIL" "Binary not readable: ${MEDIAMTX_BINARY}"
        print_status "Remediation" "INFO" "Try: sudo chmod +r ${MEDIAMTX_BINARY}"
    else
        print_status "Binary Readable" "PASS" "Binary readable"
    fi
    
    if [[ ! -x "${MEDIAMTX_BINARY}" ]]; then
        print_status "Binary Executable" "FAIL" "Binary not executable: ${MEDIAMTX_BINARY}"
        print_status "Remediation" "INFO" "Try: sudo chmod +x ${MEDIAMTX_BINARY}"
    else
        print_status "Binary Executable" "PASS" "Binary executable"
    fi
    
    local binary_perms
    binary_perms=$(get_file_permissions "${MEDIAMTX_BINARY}")
    if [[ "${binary_perms}" != "unknown" ]]; then
        if [[ "${binary_perms}" =~ ^[0-7]{3}$ ]]; then
            if [[ "${binary_perms}" == "${MEDIAMTX_BINARY_MODE}" ]]; then
                print_status "Binary Permissions" "PASS" "Set to: ${binary_perms}"
            else
                print_status "Binary Permissions" "INFO" "Mode: ${binary_perms} (expected: ${MEDIAMTX_BINARY_MODE})"
            fi
        else
            print_status "Binary Permissions" "INFO" "Mode: ${binary_perms}"
        fi
    fi
    
    local binary_owner
    binary_owner=$(get_file_ownership "${MEDIAMTX_BINARY}")
    if [[ "${binary_owner}" != "unknown" ]]; then
        if [[ "${binary_owner}" == "${EXPECTED_BINARY_OWNER}":* ]] || [[ "${binary_owner}" == "${EXPECTED_BINARY_OWNER}" ]]; then
            print_status "Binary Owner" "PASS" "Owner: ${binary_owner}"
        else
            print_status "Binary Owner" "WARN" "Unexpected owner: ${binary_owner} (expected: ${EXPECTED_BINARY_OWNER})"
            print_status "Remediation" "INFO" "Try: sudo chown ${EXPECTED_BINARY_OWNER} ${MEDIAMTX_BINARY}"
        fi
    fi
    
    local config_file
    config_file="$(get_mediamtx_config_file)"
    
    if [[ -f "${config_file}" ]]; then
        if ! is_readable "${config_file}"; then
            print_status "Config Readable" "FAIL" "Config not readable: ${config_file}"
            print_status "Remediation" "INFO" "Try: sudo chmod +r ${config_file}"
        else
            print_status "Config Readable" "PASS" "Config readable"
        fi
        
        local config_perms
        config_perms=$(get_file_permissions "${config_file}")
        if [[ "${config_perms}" != "unknown" ]] && [[ "${config_perms}" =~ ^[0-7]{3}$ ]]; then
            if [[ "${config_perms}" =~ ^64 ]]; then
                print_status "Config Permissions" "PASS" "Mode: ${config_perms}"
            else
                print_status "Config Permissions" "WARN" "Permissive: ${config_perms} (expected: ${MEDIAMTX_CONFIG_MODE}+)"
                print_status "Remediation" "INFO" "Try: sudo chmod ${MEDIAMTX_CONFIG_MODE} ${config_file}"
            fi
        fi
        
        local config_owner
        config_owner=$(get_file_ownership "${config_file}")
        if [[ "${config_owner}" != "unknown" ]]; then
            print_status "Config Owner" "INFO" "Owner: ${config_owner}"
        fi
    else
        print_status "Config File" "WARN" "Not found: ${config_file}"
    fi
    
    if [[ -d "${FFMPEG_LOG_DIR}" ]]; then
        if [[ ! -w "${FFMPEG_LOG_DIR}" ]]; then
            print_status "Log Dir Writable" "WARN" "Directory not writable: ${FFMPEG_LOG_DIR}"
            print_status "Remediation" "INFO" "Try: sudo chmod +w ${FFMPEG_LOG_DIR}"
        else
            print_status "Log Dir Writable" "PASS" "Log directory writable"
        fi
        
        local log_perms
        log_perms=$(get_file_permissions "${FFMPEG_LOG_DIR}")
        if [[ "${log_perms}" != "unknown" ]]; then
            print_status "Log Dir Permissions" "INFO" "Mode: ${log_perms}"
        fi
    else
        print_status "Log Dir" "WARN" "Directory not found: ${FFMPEG_LOG_DIR}"
        print_status "Remediation" "INFO" "Try: sudo mkdir -p ${FFMPEG_LOG_DIR}"
    fi
    
    local udev_rules_file="/etc/udev/rules.d/99-usb-soundcards.rules"
    if [[ -f "${udev_rules_file}" ]]; then
        if ! is_readable "${udev_rules_file}"; then
            print_status "udev Rules Readable" "WARN" "udev rules not readable"
        else
            print_status "udev Rules Readable" "PASS" "udev rules readable"
        fi
    fi
}

# Diagnostic Check 17: Process Stability & Crash Detection
check_process_stability() {
    print_section "17. PROCESS STABILITY & CRASH DETECTION"
    
    if [[ "${INIT_SYSTEM}" != "systemd" ]]; then
        print_status "Process Restarts" "INFO" "${INIT_SYSTEM} - systemd restart tracking unavailable"
        return
    fi
    
    if ! command -v systemctl >/dev/null 2>&1; then
        print_status "Process Restarts" "INFO" "systemd not available - cannot check restart count"
        return
    fi
    
    local mediamtx_restarts
    mediamtx_restarts=$(get_process_restart_count "mediamtx")
    if [[ "${mediamtx_restarts}" == "unsupported" ]]; then
        print_status "MediaMTX Restarts" "INFO" "Restart tracking unavailable (init system: ${INIT_SYSTEM})"
    elif [[ "${mediamtx_restarts}" != "unknown" ]] && [[ "${mediamtx_restarts}" =~ ^[0-9]+$ ]]; then
        if [[ "${mediamtx_restarts}" -eq 0 ]]; then
            print_status "MediaMTX Restarts" "PASS" "No automatic restarts detected"
        elif (( mediamtx_restarts >= RESTART_THRESHOLD_CRITICAL )); then
            print_status "MediaMTX Restarts" "FAIL" "Critical: ${mediamtx_restarts} restarts (threshold: ${RESTART_THRESHOLD_CRITICAL})"
            print_status "Remediation" "INFO" "Check logs: sudo journalctl -u mediamtx -n 50"
        elif (( mediamtx_restarts >= RESTART_THRESHOLD_WARN )); then
            print_status "MediaMTX Restarts" "WARN" "Multiple restarts: ${mediamtx_restarts}"
            print_status "Analysis" "INFO" "Review recent service state changes in systemd journal"
        else
            print_status "MediaMTX Restarts" "INFO" "Restarted ${mediamtx_restarts} time(s)"
        fi
    fi
    
    local stream_restarts
    stream_restarts=$(get_process_restart_count "mediamtx-audio")
    if [[ "${stream_restarts}" != "unknown" ]] && [[ "${stream_restarts}" != "unsupported" ]] && [[ "${stream_restarts}" =~ ^[0-9]+$ ]]; then
        if [[ "${stream_restarts}" -eq 0 ]]; then
            print_status "Stream Manager Restarts" "PASS" "No automatic restarts detected"
        elif (( stream_restarts >= RESTART_THRESHOLD_CRITICAL )); then
            print_status "Stream Manager Restarts" "FAIL" "Critical: ${stream_restarts} restarts"
            print_status "Remediation" "INFO" "Check logs: sudo journalctl -u mediamtx-audio -n 50"
        elif (( stream_restarts >= RESTART_THRESHOLD_WARN )); then
            print_status "Stream Manager Restarts" "WARN" "Multiple restarts: ${stream_restarts}"
        else
            print_status "Stream Manager Restarts" "INFO" "Restarted ${stream_restarts} time(s)"
        fi
    fi
    
    if [[ -n "${MEDIAMTX_PID}" ]]; then
        local process_uptime_sec
        process_uptime_sec=$(get_process_uptime_seconds "${MEDIAMTX_PID}")
        
        if [[ "${process_uptime_sec}" != "unknown" ]] && [[ "${process_uptime_sec}" =~ ^[0-9]+$ ]]; then
            local proc_days=$((process_uptime_sec / 86400))
            local proc_hours=$(((process_uptime_sec % 86400) / 3600))
            local proc_mins=$(((process_uptime_sec % 3600) / 60))
            
            local uptime_str
            if (( proc_days > 0 )); then
                uptime_str="${proc_days}d ${proc_hours}h"
            elif (( proc_hours > 0 )); then
                uptime_str="${proc_hours}h ${proc_mins}m"
            else
                uptime_str="${proc_mins}m"
            fi
            
            if [[ -f "/proc/uptime" ]]; then
                local sys_uptime_sec
                sys_uptime_sec=$(awk '{print int($1)}' "/proc/uptime" 2>/dev/null)
                
                if [[ -n "${sys_uptime_sec}" ]] && [[ "${sys_uptime_sec}" =~ ^[0-9]+$ ]]; then
                    if (( process_uptime_sec < sys_uptime_sec / 2 )); then
                        print_status "Recent Crash Detection" "WARN" "Process uptime (${uptime_str}) << system uptime - recent restart detected"
                        print_status "Analysis" "INFO" "Process may have crashed/restarted. Check: sudo journalctl -u mediamtx --since '15 min ago'"
                    else
                        print_status "Process Uptime" "PASS" "Stable uptime: ${uptime_str}"
                    fi
                else
                    print_status "Process Uptime" "INFO" "Uptime: ${uptime_str}"
                fi
            else
                print_status "Process Uptime" "INFO" "Uptime: ${uptime_str}"
            fi
        fi
    else
        print_status "Process Status" "INFO" "MediaMTX not currently running"
    fi
}

# Diagnostic Check 18: System Resource Constraints
check_resource_constraints() {
    print_section "18. SYSTEM RESOURCE CONSTRAINTS"
    
    local inotify_limit
    inotify_limit=$(get_inotify_limits)
    if [[ "${inotify_limit}" != "unknown" ]] && [[ "${inotify_limit}" =~ ^[0-9]+$ ]]; then
        if (( inotify_limit >= MIN_INOTIFY_LIMIT )); then
            print_status "inotify Limit" "PASS" "Configured: ${inotify_limit}"
        else
            print_status "inotify Limit" "WARN" "Low limit: ${inotify_limit} (recommended: ${MIN_INOTIFY_LIMIT}+)"
        fi
    fi
    
    if [[ -f "/proc/sys/net/ipv4/tcp_max_syn_backlog" ]]; then
        local tcp_backlog
        tcp_backlog=$(cat /proc/sys/net/ipv4/tcp_max_syn_backlog 2>/dev/null)
        if [[ -n "${tcp_backlog}" ]] && [[ "${tcp_backlog}" =~ ^[0-9]+$ ]] && (( tcp_backlog >= 512 )); then
            print_status "TCP Backlog" "PASS" "Size: ${tcp_backlog}"
        elif [[ -n "${tcp_backlog}" ]]; then
            print_status "TCP Backlog" "INFO" "Size: ${tcp_backlog}"
        fi
    fi
    
    if [[ "${INIT_SYSTEM}" == "systemd" ]] && command -v systemctl >/dev/null 2>&1; then
        if [[ -n "${MEDIAMTX_PID}" ]] && [[ -f "/proc/${MEDIAMTX_PID}/cgroup" ]]; then
            if grep -q "memory" "/proc/${MEDIAMTX_PID}/cgroup" 2>/dev/null; then
                local mem_limit
                mem_limit=$(systemctl show mediamtx -p MemoryLimit --value 2>/dev/null)
                if [[ -n "${mem_limit}" ]] && [[ "${mem_limit}" != "max" ]]; then
                    print_status "Memory Limit" "INFO" "Set to: ${mem_limit}"
                fi
            fi
        fi
    fi
}

# Diagnostic Check 19: File Descriptor Leak Detection
check_fd_leak_detection() {
    print_section "19. FILE DESCRIPTOR LEAK DETECTION"
    
    local fd_limit
    fd_limit=$(get_fd_limits)
    if [[ "${fd_limit}" != "unknown" ]] && [[ "${fd_limit}" =~ ^[0-9]+$ ]]; then
        print_status "System FD Limit" "INFO" "Maximum: ${fd_limit} FDs"
    fi
    
    local fd_usage
    fd_usage=$(get_fd_system_usage)
    if [[ "${fd_usage}" != "unknown" ]] && [[ "${fd_usage}" =~ ^[0-9]+$ ]]; then
        if [[ "${fd_limit}" != "unknown" ]] && [[ "${fd_limit}" =~ ^[0-9]+$ ]] && (( fd_limit > 0 )); then
            local fd_percent=$((fd_usage * 100 / fd_limit))
            if (( fd_percent < WARN_FD_PERCENT )); then
                print_status "System FD Usage" "PASS" "${fd_usage}/${fd_limit} FDs (${fd_percent}%)"
            elif (( fd_percent < CRIT_FD_PERCENT )); then
                print_status "System FD Usage" "WARN" "${fd_usage}/${fd_limit} FDs (${fd_percent}%) - approaching limit"
                print_status "Remediation" "INFO" "Monitor FD usage and check for fd leaks: lsof | wc -l"
            else
                print_status "System FD Usage" "FAIL" "${fd_usage}/${fd_limit} FDs (${fd_percent}%) - critical"
                print_status "Remediation" "INFO" "Immediate action required: check running processes with: lsof | grep -v 'mem\|cwd\|txt'"
            fi
        else
            print_status "System FD Usage" "INFO" "Currently: ${fd_usage} open"
        fi
    fi
    
    if [[ -n "${MEDIAMTX_PID}" ]]; then
        local proc_fd_percent
        proc_fd_percent=$(get_fd_usage_percent "${MEDIAMTX_PID}")
        
        if [[ "${proc_fd_percent}" != "unknown" ]] && [[ "${proc_fd_percent}" =~ ^[0-9]+$ ]]; then
            if (( proc_fd_percent < WARN_FD_PERCENT )); then
                print_status "MediaMTX FD Usage" "PASS" "${proc_fd_percent}% of process limit"
            elif (( proc_fd_percent < CRIT_FD_PERCENT )); then
                print_status "MediaMTX FD Usage" "WARN" "${proc_fd_percent}% of limit - approaching exhaustion"
                print_status "Remediation" "INFO" "Inspect MediaMTX FDs: lsof -p ${MEDIAMTX_PID}"
            else
                print_status "MediaMTX FD Usage" "FAIL" "${proc_fd_percent}% of limit - critical exhaustion"
                print_status "Remediation" "INFO" "Increase process limit or restart: sudo systemctl restart mediamtx"
            fi
        fi
        
        local proc_fds
        if [[ -d "/proc/${MEDIAMTX_PID}/fd" ]]; then
            proc_fds=$(find "/proc/${MEDIAMTX_PID}/fd" -maxdepth 1 -type l 2>/dev/null | wc -l)
            if [[ -n "${proc_fds}" ]]; then
                print_status "MediaMTX Open FDs" "INFO" "Currently: ${proc_fds} FDs"
            fi
        fi
    fi
}

# Diagnostic Check 20: Audio Subsystem Conflicts
check_audio_subsystem_conflicts() {
    print_section "20. AUDIO SUBSYSTEM CONFLICTS"
    
    local stale_locks
    stale_locks=$(check_alsa_locks)
    if [[ "${stale_locks}" != "unknown" ]] && [[ "${stale_locks}" =~ ^[0-9]+$ ]]; then
        if (( stale_locks > 0 )); then
            print_status "ALSA Lock Files" "WARN" "Found ${stale_locks} stale lock file(s) - may cause capture failures"
            print_status "Remediation" "INFO" "Remove: sudo rm -f /var/run/asound.* && sudo systemctl restart mediamtx"
        else
            print_status "ALSA Lock Files" "PASS" "No stale ALSA locks detected"
        fi
    else
        print_status "ALSA Lock Files" "INFO" "Cannot determine lock status"
    fi
    
    local alsa_status
    alsa_status=$(check_alsa_devices)
    case "${alsa_status}" in
        compatible)
            print_status "ALSA Device Compatibility" "PASS" "ALSA devices and proc interface aligned"
            ;;
        partial)
            print_status "ALSA Device Compatibility" "WARN" "ALSA devices detected but proc interface incomplete"
            print_status "Analysis" "INFO" "Some ALSA devices may be unavailable for capture"
            ;;
        unavailable)
            print_status "ALSA Device Compatibility" "WARN" "ALSA devices not detected"
            print_status "Remediation" "INFO" "Check: sudo arecord -l && sudo speaker-test -t sine"
            ;;
        *)
            print_status "ALSA Device Compatibility" "INFO" "Cannot determine"
            ;;
    esac
    
    local pulseaudio_running
    pulseaudio_running=$(is_pulseaudio_running)
    case "${pulseaudio_running}" in
        true)
            print_status "PulseAudio Presence" "WARN" "PulseAudio daemon running - verify exclusive mode or bridge configuration"
            print_status "Analysis" "INFO" "If PulseAudio conflicts: systemctl --user stop pulseaudio or enable module-udev-detect"
            ;;
        false)
            print_status "PulseAudio Presence" "PASS" "PulseAudio not running - no conflicts expected"
            ;;
        *)
            print_status "PulseAudio Presence" "INFO" "Cannot determine PulseAudio status"
            ;;
    esac
    
    if command -v lsmod >/dev/null 2>&1; then
        local alsa_modules
        alsa_modules=$(get_alsa_modules)
        if [[ "${alsa_modules}" != "unavailable" ]] && [[ "${alsa_modules}" =~ ^[0-9]+$ ]]; then
            if (( alsa_modules > 0 )); then
                print_status "ALSA Kernel Modules" "PASS" "Loaded: ${alsa_modules} snd_* module(s)"
            else
                print_status "ALSA Kernel Modules" "WARN" "No ALSA kernel modules loaded"
                print_status "Remediation" "INFO" "Load ALSA: sudo modprobe snd_usb_audio"
            fi
        fi
    fi
}

# Diagnostic Check 21: inotify & Entropy Limits
check_inotify_and_entropy() {
    print_section "21. INOTIFY & ENTROPY POOL"
    
    local inotify_limit
    inotify_limit=$(get_inotify_limits)
    if [[ "${inotify_limit}" != "unknown" ]] && [[ "${inotify_limit}" =~ ^[0-9]+$ ]]; then
        if (( inotify_limit >= MIN_INOTIFY_LIMIT )); then
            print_status "inotify Max Watches" "PASS" "Limit: ${inotify_limit} watches"
        else
            print_status "inotify Max Watches" "WARN" "Low: ${inotify_limit} (recommended: ${MIN_INOTIFY_LIMIT}+)"
            print_status "Remediation" "INFO" "Increase: echo ${MIN_INOTIFY_LIMIT} | sudo tee /proc/sys/fs/inotify/max_user_watches"
        fi
    fi
    
    local inotify_usage
    inotify_usage=$(get_inotify_usage)
    
    if [[ -z "${inotify_usage}" ]] || [[ "${inotify_usage}" != *" "* ]]; then
        print_status "inotify Current Usage" "WARN" "Cannot determine usage"
    else
        local inotify_current
        local inotify_percent
        read -r inotify_current inotify_percent <<< "${inotify_usage}"
        
        if [[ "${inotify_current}" == "unknown" ]] || [[ "${inotify_percent}" == "unknown" ]]; then
            print_status "inotify Current Usage" "WARN" "Cannot determine usage"
        elif [[ ! "${inotify_percent}" =~ ^[0-9]+$ ]]; then
            print_status "inotify Current Usage" "WARN" "Invalid percent value: ${inotify_percent}"
        else
            if (( inotify_percent < WARN_INOTIFY_PERCENT )); then
                print_status "inotify Current Usage" "PASS" "${inotify_current} watches (${inotify_percent}%)"
            elif (( inotify_percent < CRIT_INOTIFY_PERCENT )); then
                print_status "inotify Current Usage" "WARN" "${inotify_current} watches (${inotify_percent}%) - approaching limit"
                print_status "Analysis" "INFO" "Stream setup may experience delays if limit reached"
            else
                print_status "inotify Current Usage" "FAIL" "${inotify_current} watches (${inotify_percent}%) - critical"
                print_status "Remediation" "INFO" "Investigate heavy watchers: find /proc/*/fd -lname 'anon_inode:inotify' 2>/dev/null | head -5"
            fi
        fi
    fi
    
    local entropy_available
    entropy_available=$(get_entropy_available)
    if [[ "${entropy_available}" != "unknown" ]] && [[ "${entropy_available}" =~ ^[0-9]+$ ]]; then
        if (( entropy_available >= MIN_ENTROPY_AVAIL )); then
            print_status "Entropy Pool" "PASS" "Available: ${entropy_available} bytes"
        else
            print_status "Entropy Pool" "WARN" "Low entropy (${entropy_available} bytes) - may cause stream setup delays"
            print_status "Impact" "INFO" "Randomness generation stalling - TLS/crypto operations affected"
            print_status "Remediation" "INFO" "Install haveged or rng-tools for entropy generation"
        fi
    fi
}

# Diagnostic Check 22: Network Resource Exhaustion
check_network_resources() {
    print_section "22. NETWORK RESOURCES"
    
    local port_range
    port_range=$(get_tcp_ephemeral_status)
    if [[ "${port_range}" != "unavailable" ]]; then
        print_status "TCP Ephemeral Ports" "INFO" "Range: ${port_range}"
        
        if [[ "${port_range}" =~ ^[0-9]+ ]]; then
            local port_start="${port_range%% *}"
            local port_end="${port_range##* }"
            
            # FIXED: Validate both values before arithmetic
            if [[ "${port_start}" =~ ^[0-9]+$ ]] && [[ "${port_end}" =~ ^[0-9]+$ ]]; then
                local port_count=$((port_end - port_start))
                if (( port_count < 1000 )); then
                    print_status "Port Count" "WARN" "Only ${port_count} available - may limit concurrent connections"
                fi
            fi
        fi
    fi
    
    local timewait_connections
    timewait_connections=$(get_tcp_timewait_connections)
    if [[ "${timewait_connections}" != "unknown" ]] && [[ "${timewait_connections}" =~ ^[0-9]+$ ]]; then
        print_status "TCP TIME-WAIT Backlog" "INFO" "Current connections: ${timewait_connections}"
        
        if command -v ss >/dev/null 2>&1; then
            local total_connections
            total_connections=$(ss -tan 2>/dev/null | tail -n +2 | wc -l)
            if [[ -n "${total_connections}" ]] && [[ "${total_connections}" =~ ^[0-9]+$ ]] && (( total_connections > 0 )); then
                local tw_percent=$((timewait_connections * 100 / total_connections))
                if (( tw_percent > CRIT_TCP_TIMEWAIT_PERCENT )); then
                    print_status "TIME-WAIT Saturation" "WARN" "${tw_percent}% of connections in TIME-WAIT state"
                    print_status "Impact" "INFO" "New connections may be delayed or rejected"
                    print_status "Mitigation" "INFO" "Consider: net.ipv4.tcp_tw_reuse=1"
                elif (( tw_percent > WARN_TCP_TIMEWAIT_PERCENT )); then
                    print_status "TIME-WAIT Saturation" "INFO" "${tw_percent}% of connections in TIME-WAIT state"
                fi
            fi
        fi
    fi
}

# Diagnostic Check 23: Time & Clock Health
check_time_and_clock_health() {
    print_section "23. TIME & CLOCK HEALTH"
    
    local ntp_offset
    ntp_offset=$(get_ntp_offset_ms)
    
    case "${ntp_offset}" in
        unavailable)
            print_status "NTP Offset" "INFO" "ntpq/chronyc not available - cannot check offset"
            ;;
        unknown)
            print_status "NTP Offset" "INFO" "No synchronized NTP server detected"
            print_status "Recommendation" "INFO" "Install NTP: sudo apt install chrony ntp"
            ;;
        *)
            if [[ "${ntp_offset}" =~ ^-?[0-9]+\.?[0-9]*$ ]]; then
                local offset_int
                offset_int=$(printf "%.0f" "${ntp_offset}" 2>/dev/null || echo "invalid")
                
                # FIXED: Explicit validation after conversion
                if [[ -z "${offset_int}" ]] || [[ ! "${offset_int}" =~ ^-?[0-9]+$ ]]; then
                    print_status "Clock Offset" "WARN" "Invalid NTP offset value: ${ntp_offset}"
                elif (( offset_int < -MAX_CLOCK_DRIFT_MS || offset_int > MAX_CLOCK_DRIFT_MS )); then
                    print_status "Clock Offset" "WARN" "Offset: ${ntp_offset}ms (drift > ${MAX_CLOCK_DRIFT_MS}ms may affect streaming)"
                    print_status "Impact" "INFO" "RTSP timestamps and stream synchronization may be affected"
                    print_status "Remediation" "INFO" "Check NTP status: timedatectl or ntpq -p"
                else
                    print_status "Clock Offset" "PASS" "Offset: ${ntp_offset}ms"
                fi
            fi
            ;;
    esac
    
    if command -v date >/dev/null 2>&1; then
        local system_time
        system_time=$(date '+%Y-%m-%d %H:%M:%S %Z' 2>/dev/null)
        if [[ -n "${system_time}" ]]; then
            print_status "System Time" "INFO" "${system_time}"
        fi
    fi
    
    if [[ -f "/proc/uptime" ]]; then
        local uptime
        uptime=$(awk '{print int($1)}' "/proc/uptime" 2>/dev/null)
        if [[ -n "${uptime}" ]]; then
            print_status "System Uptime" "INFO" "Running for ${uptime} seconds"
        fi
    fi
}

# Diagnostic Check 24: Service Dependencies
check_service_dependencies() {
    print_section "24. SERVICE DEPENDENCIES"
    
    if [[ "${INIT_SYSTEM}" != "systemd" ]]; then
        print_status "Service Dependencies" "INFO" "${INIT_SYSTEM} - systemd dependency checks skipped"
        return
    fi
    
    if ! command -v systemctl >/dev/null 2>&1; then
        print_status "Service Dependencies" "INFO" "systemd not available"
        return
    fi
    
    local required_services=("mediamtx")
    local optional_services=("pulseaudio" "udev")
    
    for service in "${required_services[@]}"; do
        if systemctl list-unit-files "${service}*" 2>/dev/null | grep -q "${service}"; then
            local svc_status
            svc_status=$(get_service_status "${service}")
            case "${svc_status}" in
                active)
                    print_status "Service: ${service}" "PASS" "Active and running"
                    ;;
                enabled)
                    print_status "Service: ${service}" "INFO" "Enabled but not running"
                    ;;
                *)
                    print_status "Service: ${service}" "INFO" "Status: ${svc_status}"
                    ;;
            esac
        else
            print_status "Service: ${service}" "INFO" "Not registered as systemd service"
        fi
    done
    
    for service in "${optional_services[@]}"; do
        if systemctl list-unit-files "${service}*" 2>/dev/null | grep -q "${service}"; then
            local svc_status
            svc_status=$(get_service_status "${service}")
            if [[ "${svc_status}" == "active" ]]; then
                case "${service}" in
                    pulseaudio)
                        print_status "Optional: ${service}" "WARN" "Active - verify exclusive audio mode or bridge configuration"
                        ;;
                    udev)
                        print_status "Optional: ${service}" "PASS" "Active (required for USB persistence)"
                        ;;
                    *)
                        print_status "Optional: ${service}" "INFO" "Active"
                        ;;
                esac
            fi
        fi
    done
}

# Print summary
print_summary() {
    if [[ "${QUIET}" == "true" ]]; then
        return
    fi
    
    printf '\n'
    if [[ "${USE_COLOR}" == "true" ]]; then
        printf '%s%s%s\n' "${CYAN}" "=== DIAGNOSTIC SUMMARY ===" "${NC}"
    else
        printf '%s\n' "=== DIAGNOSTIC SUMMARY ==="
    fi
    
    printf 'Passed:  %d\n' "${PASS_COUNT}"
    printf 'Warned:  %d\n' "${WARN_COUNT}"
    printf 'Failed:  %d\n' "${FAIL_COUNT}"
    printf 'Info:    %d\n' "${INFO_COUNT}"
    
    printf '\n'
    
    case "${EXIT_CODE}" in
        "${E_SUCCESS}")
            if [[ "${USE_COLOR}" == "true" ]]; then
                printf '%sStatus: ALL CHECKS PASSED%s\n' "${GREEN}" "${NC}"
            else
                printf '%s\n' "Status: ALL CHECKS PASSED"
            fi
            ;;
        "${E_WARN}")
            if [[ "${USE_COLOR}" == "true" ]]; then
                printf '%sStatus: WARNINGS DETECTED%s\n' "${YELLOW}" "${NC}"
            else
                printf '%s\n' "Status: WARNINGS DETECTED"
            fi
            ;;
        "${E_FAIL}")
            if [[ "${USE_COLOR}" == "true" ]]; then
                printf '%sStatus: FAILURES DETECTED%s\n' "${RED}" "${NC}"
            else
                printf '%s\n' "Status: FAILURES DETECTED"
            fi
            ;;
    esac
    
    printf '\n'
}

# Display help
show_help() {
    cat << 'EOF'
lyrebird-diagnostics.sh - LyreBirdAudio System Diagnostics

USAGE:
  lyrebird-diagnostics.sh [OPTIONS] [COMMAND]

COMMANDS:
  quick       Run essential checks only (Prerequisites, USB, Service, RTSP)
  full        Run complete diagnostics (all checks) [default]
  debug       Run comprehensive debug mode with all checks and verbose output
  help        Display this help message

OPTIONS:
  -h, --help              Display this help message
  -v, --version           Display version information
  -d, --debug             Enable debug output
  -q, --quiet             Suppress non-error output
  -c, --config FILE       Use alternate config file
  --timeout SECONDS       Set operation timeout (default: 30s, range: 1-3600)
  --no-color              Disable colored output

EXIT CODES:
  0   All checks PASSED
  1   Some checks WARNED
  2   Some checks FAILED
  127 Script error (missing dependencies, permissions)

EXAMPLES:
  lyrebird-diagnostics.sh quick
  lyrebird-diagnostics.sh full --debug
  lyrebird-diagnostics.sh debug
  lyrebird-diagnostics.sh --no-color --timeout 60

ENVIRONMENT VARIABLES:
  MEDIAMTX_CONFIG_DIR     Config directory (default: /etc/mediamtx)
  MEDIAMTX_BINARY         MediaMTX binary path (default: /usr/local/bin/mediamtx)
  DIAGNOSTIC_TIMEOUT      Operation timeout in seconds (default: 30, validated 1-3600)
  DEBUG                   Enable debug logging (set to true)
  NO_COLOR                Disable colored output (set to true)

INIT SYSTEM SUPPORT:
  - systemd:   Full diagnostic support
  - OpenRC:    Limited support (process/service checks unavailable)
  - Other:     Basic checks only

For more information, visit: https://github.com/tomtom215/LyreBirdAudio
EOF
}

# Display version
show_version() {
    cat << EOF
lyrebird-diagnostics.sh v${SCRIPT_VERSION}
Part of LyreBirdAudio - RTSP Audio Streaming Suite
https://github.com/tomtom215/LyreBirdAudio

Init System: ${INIT_SYSTEM}
Compatible with: bash 4.4+, Ubuntu 20.04+, Debian 11+, Raspberry Pi OS
Limited support: Alpine Linux (OpenRC), macOS/BSD systems

YAML Validation: Requires python3, yq, or perl for proper validation
EOF
}

# Parse command-line arguments
parse_arguments() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            -h|--help)
                show_help
                exit 0
                ;;
            -v|--version)
                show_version
                exit 0
                ;;
            -d|--debug)
                DEBUG="true"
                shift
                ;;
            -q|--quiet)
                QUIET="true"
                shift
                ;;
            --no-color)
                NO_COLOR="true"
                shift
                ;;
            --timeout)
                if [[ -z "$2" ]]; then
                    log ERROR "Timeout value required"
                    exit "${E_ERROR}"
                fi
                if ! validate_numeric_env "timeout" "$2" 1 3600; then
                    log ERROR "Invalid timeout value: $2 (must be 1-3600 seconds)"
                    exit "${E_ERROR}"
                fi
                TIMEOUT_SECONDS="$2"
                shift 2
                ;;
            -c|--config)
                if [[ -z "$2" ]]; then
                    log ERROR "Config file path required"
                    exit "${E_ERROR}"
                fi
                CUSTOM_CONFIG_FILE="$2"
                if [[ -n "${CUSTOM_CONFIG_FILE}" ]] && [[ ! -r "${CUSTOM_CONFIG_FILE}" ]]; then
                    log ERROR "Config file not readable: ${CUSTOM_CONFIG_FILE}"
                    exit "${E_ERROR}"
                fi
                shift 2
                ;;
            quick)
                COMMAND="quick"
                shift
                ;;
            full)
                COMMAND="full"
                shift
                ;;
            debug)
                COMMAND="debug"
                DEBUG="true"
                shift
                ;;
            help)
                show_help
                exit 0
                ;;
            *)
                log ERROR "Unknown option: $1"
                exit "${E_ERROR}"
                ;;
        esac
    done
}

# Main execution
main() {
    detect_colors
    ensure_log_directory
    parse_arguments "$@"
    
    log INFO "Diagnostic started from ${SCRIPT_DIR} (version ${SCRIPT_VERSION}, mode: ${COMMAND}, init: ${INIT_SYSTEM})"
    
    # Cache MediaMTX PID once at startup
    if command -v pgrep >/dev/null 2>&1; then
        MEDIAMTX_PID="$(pgrep -f "${MEDIAMTX_BINARY}" | head -1 || echo "")"
    fi
    log DEBUG "Cached MediaMTX PID: ${MEDIAMTX_PID}"
    
    if [[ "${QUIET}" != "true" ]]; then
        if [[ "${USE_COLOR}" == "true" ]]; then
            printf '\n%s%s%s\n' "${CYAN}" "LyreBirdAudio Diagnostics v${SCRIPT_VERSION}" "${NC}"
        else
            printf '\n%s\n' "LyreBirdAudio Diagnostics v${SCRIPT_VERSION}"
        fi
        printf 'Mode: %s | Init System: %s | Timeout: %ds\n' "${COMMAND}" "${INIT_SYSTEM}" "${TIMEOUT_SECONDS}"
        
        # Single non-root warning (FIXED: removed duplicate)
        local current_user
        current_user="${USER:-${LOGNAME:-$(whoami 2>/dev/null || echo 'unknown')}}"
        if [[ "${current_user}" != "root" ]] && [[ "${current_user}" != "unknown" ]]; then
            printf '\n%s\n' "WARNING: Running as '${current_user}' (non-root user)"
            printf '%s\n' "-----------------------------------------------------------"
            printf '%s\n' "Some diagnostic checks are limited without root privileges."
            printf '%s\n' "You may see FALSE POSITIVES for:"
            printf '%s\n' "  - File permissions and ownership checks"
            printf '%s\n' "  - Log file accessibility"
            printf '%s\n' "  - System resource limits"
            printf '%s\n' "  - Service status (systemd checks)"
            printf '%s\n\n' "For complete and accurate results, run with sudo."
        fi
        printf '\n'
    fi
    
    case "${COMMAND}" in
        quick)
            check_prerequisites
            check_project_info
            check_project_files
            check_log_locations
            check_usb_devices
            check_mediamtx_service
            check_rtsp_connectivity
            ;;
        debug)
            check_prerequisites
            check_project_info
            check_system_info
            check_usb_devices
            check_audio_capabilities
            check_mediamtx_service
            check_stream_health
            check_rtsp_connectivity
            check_resource_usage
            check_log_analysis
            check_system_limits
            check_disk_health
            check_configuration_validity
            check_time_synchronization
            check_service_configuration
            check_file_permissions_validity
            check_process_stability
            check_resource_constraints
            check_fd_leak_detection
            check_audio_subsystem_conflicts
            check_inotify_and_entropy
            check_network_resources
            check_time_and_clock_health
            check_service_dependencies
            ;;
        full|*)
            check_prerequisites
            check_project_info
            check_project_files
            check_log_locations
            check_system_info
            check_usb_devices
            check_audio_capabilities
            check_mediamtx_service
            check_stream_health
            check_rtsp_connectivity
            check_resource_usage
            check_system_limits
            check_disk_health
            check_configuration_validity
            check_time_synchronization
            check_service_configuration
            check_file_permissions_validity
            check_process_stability
            check_resource_constraints
            check_fd_leak_detection
            check_audio_subsystem_conflicts
            check_inotify_and_entropy
            check_network_resources
            check_time_and_clock_health
            check_service_dependencies
            ;;
    esac
    
    print_summary
    
    log INFO "Diagnostic completed (exit code: ${EXIT_CODE})"
    
    return "${EXIT_CODE}"
}

main "$@"
