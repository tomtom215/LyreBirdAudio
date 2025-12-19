#!/bin/bash
# lyrebird-common.sh - Shared Utility Library for LyreBirdAudio
# Part of LyreBirdAudio - RTSP Audio Streaming Suite
# https://github.com/tomtom215/LyreBirdAudio
#
# Author: Tom F (https://github.com/tomtom215)
# Copyright: Tom F and LyreBirdAudio contributors
# License: Apache 2.0
#
# Version: 1.0.0
#
# DESCRIPTION:
#   This library provides shared utility functions used across all LyreBirdAudio
#   scripts. It consolidates duplicated code for terminal colors, logging,
#   command checking, and other common operations.
#
# USAGE:
#   Source this file at the top of any LyreBirdAudio script:
#
#     # Source shared library if available (backward compatible)
#     _COMMON_LIB="${BASH_SOURCE[0]%/*}/lyrebird-common.sh"
#     if [[ -f "$_COMMON_LIB" ]]; then
#         source "$_COMMON_LIB"
#     fi
#
# BACKWARD COMPATIBILITY:
#   - All functions check if already defined before defining
#   - Scripts work identically whether this library exists or not
#   - Scripts can override any function by defining it before sourcing
#   - No changes required to existing deployments
#
# FUNCTIONS PROVIDED:
#   - Terminal Colors: RED, GREEN, YELLOW, BLUE, CYAN, BOLD, NC
#   - command_exists()      - Check if command is available (cached)
#   - compute_hash()        - Portable SHA256/fallback hash
#   - log_debug()           - Debug logging (requires DEBUG=true)
#   - log_info()            - Informational logging
#   - log_warn()            - Warning logging
#   - log_error()           - Error logging
#   - lyrebird_timestamp()  - Get current timestamp
#
# STANDARD EXIT CODES:
#   - E_SUCCESS=0
#   - E_GENERAL=1
#   - E_PERMISSION=2
#   - E_MISSING_DEPS=3
#   - E_CONFIG_ERROR=4
#   - E_LOCK_FAILED=5
#   - E_NOT_FOUND=6

#=============================================================================
# Guard Against Multiple Inclusion
#=============================================================================

# Version of the common library
readonly LYREBIRD_COMMON_VERSION="1.0.0"

# Prevent multiple sourcing (idempotent)
if [[ -n "${_LYREBIRD_COMMON_LOADED:-}" ]]; then
    return 0 2>/dev/null || exit 0
fi
readonly _LYREBIRD_COMMON_LOADED=true

#=============================================================================
# Bash Version Check
#=============================================================================

# Require Bash 4.0+ for associative arrays
if ((BASH_VERSINFO[0] < 4)); then
    echo "ERROR: lyrebird-common.sh requires Bash 4.0+ (found: ${BASH_VERSION})" >&2
    return 1 2>/dev/null || exit 1
fi

#=============================================================================
# Terminal Color Support
#=============================================================================

# Initialize colors only if not already defined
# This allows scripts to define their own colors before sourcing

_lyrebird_init_colors() {
    # Check if colors already defined
    if declare -p RED &>/dev/null 2>&1; then
        return 0
    fi

    # Check if output is to a terminal
    if [[ -t 1 ]] && [[ -t 2 ]]; then
        # Try tput first (most portable)
        if command -v tput >/dev/null 2>&1; then
            local colors
            colors="$(tput colors 2>/dev/null || echo 0)"
            if [[ "${colors}" -ge 8 ]]; then
                RED="$(tput setaf 1 2>/dev/null)" || RED=""
                GREEN="$(tput setaf 2 2>/dev/null)" || GREEN=""
                YELLOW="$(tput setaf 3 2>/dev/null)" || YELLOW=""
                BLUE="$(tput setaf 4 2>/dev/null)" || BLUE=""
                CYAN="$(tput setaf 6 2>/dev/null)" || CYAN=""
                BOLD="$(tput bold 2>/dev/null)" || BOLD=""
                NC="$(tput sgr0 2>/dev/null)" || NC=""
                return 0
            fi
        fi

        # Fallback to ANSI escape codes
        RED='\033[0;31m'
        GREEN='\033[0;32m'
        YELLOW='\033[1;33m'
        BLUE='\033[0;34m'
        CYAN='\033[0;36m'
        BOLD='\033[1m'
        NC='\033[0m'
    else
        # No terminal - disable colors
        RED=""
        GREEN=""
        YELLOW=""
        BLUE=""
        CYAN=""
        # shellcheck disable=SC2034  # BOLD is used by scripts that source this library
        BOLD=""
        NC=""
    fi
}

# Initialize colors on load
_lyrebird_init_colors

#=============================================================================
# Command Existence Cache
#=============================================================================

# Associative array for caching command existence checks
declare -gA _LYREBIRD_CMD_CACHE=()

# Check if command exists (with caching for performance)
# Usage: lyrebird_command_exists command_name
# Returns: 0 if command exists, 1 otherwise
lyrebird_command_exists() {
    local cmd="$1"

    # Return cached result if available
    if [[ -n "${_LYREBIRD_CMD_CACHE[$cmd]+isset}" ]]; then
        return "${_LYREBIRD_CMD_CACHE[$cmd]}"
    fi

    # Check and cache
    if command -v "$cmd" &>/dev/null; then
        _LYREBIRD_CMD_CACHE[$cmd]=0
        return 0
    else
        _LYREBIRD_CMD_CACHE[$cmd]=1
        return 1
    fi
}

# Alias for backward compatibility with existing scripts
# Only define if not already defined
if ! declare -f command_exists &>/dev/null; then
    command_exists() {
        lyrebird_command_exists "$@"
    }
fi

# Alias using has_command (used in diagnostics)
if ! declare -f has_command &>/dev/null; then
    has_command() {
        lyrebird_command_exists "$@"
    }
fi

#=============================================================================
# Portable Hash Function
#=============================================================================

# Compute hash using best available tool
# Usage: echo "data" | lyrebird_compute_hash
# Returns: Hash string on stdout
lyrebird_compute_hash() {
    if lyrebird_command_exists sha256sum; then
        sha256sum | cut -d' ' -f1
    elif lyrebird_command_exists shasum; then
        shasum -a 256 | cut -d' ' -f1
    elif lyrebird_command_exists openssl; then
        openssl dgst -sha256 | sed 's/^.* //'
    elif lyrebird_command_exists cksum; then
        # Fallback: use cksum for basic change detection
        cksum | cut -d' ' -f1
    else
        # Last resort
        echo "0"
    fi
}

# Alias for backward compatibility
if ! declare -f compute_hash &>/dev/null; then
    compute_hash() {
        lyrebird_compute_hash "$@"
    }
fi

# Portable hash with length parameter (used in usb-audio-mapper)
if ! declare -f get_portable_hash &>/dev/null; then
    get_portable_hash() {
        local input="${1:-}"
        local length="${2:-8}"

        if [[ -z "$input" ]]; then
            printf "%0${length}d" 0
            return 0
        fi

        local hash
        hash="$(printf '%s' "$input" | lyrebird_compute_hash)"
        printf '%s' "${hash:0:$length}"
    }
fi

#=============================================================================
# Standard Exit Codes
#=============================================================================

# Define standard exit codes if not already defined
# Using := ensures we don't override existing definitions
: "${E_SUCCESS:=0}"
: "${E_GENERAL:=1}"
: "${E_PERMISSION:=2}"
: "${E_MISSING_DEPS:=3}"
: "${E_CONFIG_ERROR:=4}"
: "${E_LOCK_FAILED:=5}"
: "${E_NOT_FOUND:=6}"
: "${E_LOCKED:=7}"
: "${E_BAD_STATE:=8}"
: "${E_USER_ABORT:=9}"

#=============================================================================
# Timestamp Function
#=============================================================================

# Get current timestamp in standard format with timezone
# Usage: lyrebird_timestamp
# Returns: Timestamp string (YYYY-MM-DD HH:MM:SS TZ)
# v1.4.2: Added timezone indicator for multi-timezone deployments
lyrebird_timestamp() {
    # Include timezone abbreviation for clarity in logs
    date '+%Y-%m-%d %H:%M:%S %Z' 2>/dev/null || echo "[UNKNOWN]"
}

#=============================================================================
# Logging Functions
#=============================================================================

# Internal: Log to file if LOG_FILE is set and writable
_lyrebird_log_to_file() {
    local level="$1"
    shift
    local message="$*"

    # Only log to file if LOG_FILE is set
    if [[ -z "${LOG_FILE:-}" ]]; then
        return 0
    fi

    # Check if we can write (file exists and writable, or directory is writable)
    local log_dir
    log_dir="$(dirname "${LOG_FILE}" 2>/dev/null)" || return 0

    if [[ -w "${LOG_FILE}" ]] || [[ -w "${log_dir}" ]]; then
        echo "[$(lyrebird_timestamp)] [${level}] ${message}" >>"${LOG_FILE}" 2>/dev/null || true
    fi
}

# Debug logging - only outputs if DEBUG=true
if ! declare -f log_debug &>/dev/null; then
    log_debug() {
        if [[ "${DEBUG:-false}" == "true" ]]; then
            _lyrebird_log_to_file "DEBUG" "$*"
            printf '%b[DEBUG]%b %s\n' "${BLUE:-}" "${NC:-}" "$*" >&2
        fi
    }
fi

# Info logging
if ! declare -f log_info &>/dev/null; then
    log_info() {
        _lyrebird_log_to_file "INFO" "$*"
        printf '%b[INFO]%b %s\n' "${GREEN:-}" "${NC:-}" "$*" >&2
    }
fi

# Warning logging
if ! declare -f log_warn &>/dev/null; then
    log_warn() {
        _lyrebird_log_to_file "WARN" "$*"
        printf '%b[WARN]%b %s\n' "${YELLOW:-}" "${NC:-}" "$*" >&2
    }
fi

# Error logging
if ! declare -f log_error &>/dev/null; then
    log_error() {
        _lyrebird_log_to_file "ERROR" "$*"
        printf '%b[ERROR]%b %s\n' "${RED:-}" "${NC:-}" "$*" >&2
    }
fi

# Success logging (used in orchestrator)
if ! declare -f log_success &>/dev/null; then
    log_success() {
        _lyrebird_log_to_file "SUCCESS" "$*"
        printf '%b[OK]%b %s\n' "${GREEN:-}" "${NC:-}" "$*" >&2
    }
fi

# Error with remediation steps
# Usage: log_error_with_fix "Error message" "How to fix it"
if ! declare -f log_error_with_fix &>/dev/null; then
    log_error_with_fix() {
        local error_msg="${1:-Unknown error}"
        local fix_msg="${2:-}"

        _lyrebird_log_to_file "ERROR" "$error_msg"
        printf '%b[ERROR]%b %s\n' "${RED:-}" "${NC:-}" "$error_msg" >&2

        if [[ -n "$fix_msg" ]]; then
            printf '%b[FIX]%b   %s\n' "${CYAN:-}" "${NC:-}" "$fix_msg" >&2
        fi
    }
fi

# Die with error message and optional fix (exits with code 1)
# Usage: die_with_fix "Error message" "How to fix it"
if ! declare -f die_with_fix &>/dev/null; then
    die_with_fix() {
        local error_msg="${1:-Unknown error}"
        local fix_msg="${2:-}"
        local exit_code="${3:-1}"

        log_error_with_fix "$error_msg" "$fix_msg"
        exit "$exit_code"
    }
fi

# Common error messages with fixes (reusable)
# Usage: lyrebird_error_permission
if ! declare -f lyrebird_error_permission &>/dev/null; then
    lyrebird_error_permission() {
        local resource="${1:-this operation}"
        log_error_with_fix \
            "Permission denied for ${resource}" \
            "Run with sudo: sudo $0 $*"
    }
fi

if ! declare -f lyrebird_error_not_found &>/dev/null; then
    lyrebird_error_not_found() {
        local what="${1:-Resource}"
        local install_hint="${2:-}"
        local fix_msg="Check that ${what} exists and path is correct"
        [[ -n "$install_hint" ]] && fix_msg="$fix_msg. Install with: $install_hint"
        log_error_with_fix "${what} not found" "$fix_msg"
    }
fi

if ! declare -f lyrebird_error_dependency &>/dev/null; then
    lyrebird_error_dependency() {
        local cmd="${1:-command}"
        local package="${2:-$cmd}"
        log_error_with_fix \
            "Required command '${cmd}' not found" \
            "Install with: sudo apt-get install ${package}"
    }
fi

# Generic log function with level parameter (used in stream-manager)
if ! declare -f log &>/dev/null; then
    log() {
        local level="$1"
        shift
        local message="$*"

        case "${level}" in
            DEBUG)
                log_debug "$message"
                ;;
            INFO)
                log_info "$message"
                ;;
            WARN | WARNING)
                log_warn "$message"
                ;;
            ERROR)
                log_error "$message"
                ;;
            SUCCESS)
                log_success "$message"
                ;;
            *)
                # Unknown level, treat as info
                log_info "[$level] $message"
                ;;
        esac
    }
fi

#=============================================================================
# Utility Output Functions
#=============================================================================

# These are used in orchestrator and usb-audio-mapper for user-facing output

if ! declare -f success &>/dev/null; then
    success() {
        printf '%b%s%b %s\n' "${GREEN:-}" "[OK]" "${NC:-}" "$*"
    }
fi

if ! declare -f error &>/dev/null; then
    error() {
        printf '%b%s%b %s\n' "${RED:-}" "[X]" "${NC:-}" "$*" >&2
    }
fi

if ! declare -f warning &>/dev/null; then
    warning() {
        printf '%b%s%b %s\n' "${YELLOW:-}" "[!]" "${NC:-}" "$*" >&2
    }
fi

if ! declare -f info &>/dev/null; then
    info() {
        printf '%b%s%b %s\n' "${CYAN:-}" "[>]" "${NC:-}" "$*"
    }
fi

if ! declare -f debug &>/dev/null; then
    debug() {
        if [[ "${DEBUG:-false}" == "true" ]]; then
            printf '%b%s%b %s\n' "${BLUE:-}" "[D]" "${NC:-}" "$*" >&2
        fi
    }
fi

#=============================================================================
# Numeric Validation
#=============================================================================

# Validate that a value is a positive integer
# Usage: is_positive_integer "123"
# Returns: 0 if valid, 1 otherwise
if ! declare -f is_positive_integer &>/dev/null; then
    is_positive_integer() {
        local val="$1"
        [[ "$val" =~ ^[0-9]+$ ]] && [[ "$val" -gt 0 ]]
    }
fi

# Safe base-10 conversion (prevents octal interpretation)
# Usage: safe_base10 "007"
# Returns: Decimal value or empty on error
if ! declare -f safe_base10 &>/dev/null; then
    safe_base10() {
        local val="${1:-}"

        # Check if empty or not a number
        if [[ -z "$val" ]] || [[ ! "$val" =~ ^[0-9]+$ ]]; then
            return 1
        fi

        # Remove leading zeros and convert
        val="${val#"${val%%[!0]*}"}"
        [[ -z "$val" ]] && val="0"

        printf "%d" "$val"
    }
fi

#=============================================================================
# File Operations
#=============================================================================

# Check if file is readable
# Usage: is_readable "/path/to/file"
if ! declare -f is_readable &>/dev/null; then
    is_readable() {
        [[ -f "$1" ]] && [[ -r "$1" ]]
    }
fi

# Check if directory exists
# Usage: dir_exists "/path/to/dir"
if ! declare -f dir_exists &>/dev/null; then
    dir_exists() {
        [[ -d "$1" ]]
    }
fi

# Get file size (portable across GNU and BSD)
# Usage: get_file_size "/path/to/file"
# Returns: Size in bytes
if ! declare -f get_file_size &>/dev/null; then
    get_file_size() {
        local filepath="$1"

        if [[ ! -f "${filepath}" ]]; then
            echo 0
            return
        fi

        # Try GNU stat first
        if lyrebird_command_exists stat; then
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
        wc -c <"${filepath}" 2>/dev/null | tr -d ' ' || echo 0
    }
fi

#=============================================================================
# Timeout Wrapper
#=============================================================================

# Run command with timeout (portable)
# Usage: run_with_timeout 30 command arg1 arg2
if ! declare -f run_with_timeout &>/dev/null; then
    run_with_timeout() {
        local timeout="$1"
        shift

        if lyrebird_command_exists timeout; then
            timeout "${timeout}" "$@" 2>/dev/null || {
                local exit_code=$?
                [[ "${exit_code}" == 124 ]] && return 1
                return "${exit_code}"
            }
        else
            # No timeout command, run directly
            "$@" 2>/dev/null
        fi
    }
fi

#=============================================================================
# Progress Indicators
#=============================================================================

# Spinner characters for progress indication
readonly LYREBIRD_SPINNER_CHARS='⠋⠙⠹⠸⠼⠴⠦⠧⠇⠏'
readonly LYREBIRD_SPINNER_SIMPLE='|/-\'

# Global variable to track spinner PID
_LYREBIRD_SPINNER_PID=""

# Start a spinner with message
# Usage: lyrebird_spinner_start "Downloading..."
# Note: Call lyrebird_spinner_stop when operation completes
if ! declare -f lyrebird_spinner_start &>/dev/null; then
    lyrebird_spinner_start() {
        local message="${1:-Working...}"

        # Don't show spinner if not a terminal or NO_COLOR is set
        if [[ ! -t 1 ]] || [[ -n "${NO_COLOR:-}" ]]; then
            echo "${message}"
            return 0
        fi

        # Kill any existing spinner
        lyrebird_spinner_stop 2>/dev/null || true

        # Start spinner in background
        (
            local i=0
            local chars="${LYREBIRD_SPINNER_CHARS}"
            local len=${#chars}

            # Hide cursor
            printf '\033[?25l'

            while true; do
                local char="${chars:$i:1}"
                printf '\r%s %s ' "${char}" "${message}"
                i=$(( (i + 1) % len ))
                sleep 0.1
            done
        ) &
        _LYREBIRD_SPINNER_PID=$!
        disown "$_LYREBIRD_SPINNER_PID" 2>/dev/null || true
    }
fi

# Stop the spinner
# Usage: lyrebird_spinner_stop [status_message]
if ! declare -f lyrebird_spinner_stop &>/dev/null; then
    lyrebird_spinner_stop() {
        local status_message="${1:-}"

        if [[ -n "${_LYREBIRD_SPINNER_PID}" ]]; then
            kill "$_LYREBIRD_SPINNER_PID" 2>/dev/null || true
            wait "$_LYREBIRD_SPINNER_PID" 2>/dev/null || true
            _LYREBIRD_SPINNER_PID=""
        fi

        # Show cursor and clear line
        if [[ -t 1 ]] && [[ -z "${NO_COLOR:-}" ]]; then
            printf '\033[?25h'  # Show cursor
            printf '\r\033[K'   # Clear line
        fi

        # Print status message if provided
        if [[ -n "${status_message}" ]]; then
            echo "${status_message}"
        fi
    }
fi

# Show a progress bar
# Usage: lyrebird_progress_bar <current> <total> [message]
# Example: lyrebird_progress_bar 50 100 "Downloading"
if ! declare -f lyrebird_progress_bar &>/dev/null; then
    lyrebird_progress_bar() {
        local current="${1:-0}"
        local total="${2:-100}"
        local message="${3:-Progress}"
        local width=40

        # Don't show progress bar if not a terminal
        if [[ ! -t 1 ]] || [[ -n "${NO_COLOR:-}" ]]; then
            return 0
        fi

        # Calculate percentage and filled width
        local percent=0
        if ((total > 0)); then
            percent=$((current * 100 / total))
        fi
        local filled=$((width * current / total))
        local empty=$((width - filled))

        # Build the bar
        local bar=""
        local i
        for ((i = 0; i < filled; i++)); do
            bar+="█"
        done
        for ((i = 0; i < empty; i++)); do
            bar+="░"
        done

        # Print the progress bar
        printf '\r%s [%s] %3d%% ' "${message}" "${bar}" "${percent}"

        # Newline when complete
        if ((current >= total)); then
            echo ""
        fi
    }
fi

# Run a command with a spinner
# Usage: lyrebird_with_spinner "message" command [args...]
# Returns: Exit code of the command
if ! declare -f lyrebird_with_spinner &>/dev/null; then
    lyrebird_with_spinner() {
        local message="${1:-Working...}"
        shift

        lyrebird_spinner_start "${message}"
        local exit_code=0
        "$@" || exit_code=$?

        if ((exit_code == 0)); then
            lyrebird_spinner_stop "✓ ${message} - Done"
        else
            lyrebird_spinner_stop "✗ ${message} - Failed"
        fi

        return "$exit_code"
    }
fi

# Show countdown timer
# Usage: lyrebird_countdown <seconds> [message]
if ! declare -f lyrebird_countdown &>/dev/null; then
    lyrebird_countdown() {
        local seconds="${1:-5}"
        local message="${2:-Waiting}"

        while ((seconds > 0)); do
            if [[ -t 1 ]] && [[ -z "${NO_COLOR:-}" ]]; then
                printf '\r%s... %d ' "${message}" "${seconds}"
            fi
            sleep 1
            ((seconds--))
        done

        if [[ -t 1 ]] && [[ -z "${NO_COLOR:-}" ]]; then
            printf '\r\033[K'  # Clear line
        fi
    }
fi

# Display step progress (e.g., "Step 3 of 5: Installing...")
# Usage: lyrebird_step <current> <total> <message>
if ! declare -f lyrebird_step &>/dev/null; then
    lyrebird_step() {
        local current="${1:-1}"
        local total="${2:-1}"
        local message="${3:-Working}"

        local prefix
        if [[ -t 1 ]] && [[ -z "${NO_COLOR:-}" ]]; then
            prefix="${BLUE}[${current}/${total}]${NC}"
        else
            prefix="[${current}/${total}]"
        fi

        echo "${prefix} ${message}"
    }
fi

#=============================================================================
# Version Information
#=============================================================================

# Return the version of lyrebird-common.sh
# Used by other scripts for compatibility checking
if ! declare -f lyrebird_common_version &>/dev/null; then
    lyrebird_common_version() {
        echo "${LYREBIRD_COMMON_VERSION}"
    }
fi

#=============================================================================
# Library Load Complete
#=============================================================================

# Log that library was loaded (only in debug mode)
if [[ "${DEBUG:-false}" == "true" ]]; then
    echo "[DEBUG] lyrebird-common.sh v${LYREBIRD_COMMON_VERSION} loaded" >&2
fi
