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
