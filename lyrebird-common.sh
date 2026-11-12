#!/bin/bash
# lyrebird-common.sh - Shared Utility Library for LyreBirdAudio
# Part of LyreBirdAudio - RTSP Audio Streaming Suite
# https://github.com/tomtom215/LyreBirdAudio
#
# Author: Tom F (https://github.com/tomtom215)
# Copyright: Tom F and LyreBirdAudio contributors
# License: Apache 2.0
#
# Version: 1.2.0
#
# DESCRIPTION:
#   This library provides shared utility functions used across all LyreBirdAudio
#   scripts. It consolidates duplicated code for terminal colors, logging,
#   command checking, and other common operations.
#
# USAGE:
#   Source this file at the top of any LyreBirdAudio script:
#
#     # Source shared library if available (backward compatible). A script run by
#     # bare name (bash script.sh, in its own directory) has no slash in
#     # BASH_SOURCE[0], so "${BASH_SOURCE[0]%/*}" would be the script's own name:
#     # use "." then. The scripts in this repository also look beside the target
#     # of a symlink; copy the block from lyrebird-diagnostics.sh.
#     _COMMON_LIB="${BASH_SOURCE[0]}"
#     if [[ "$_COMMON_LIB" == */* ]]; then
#         _COMMON_LIB="${_COMMON_LIB%/*}/lyrebird-common.sh"
#     else
#         _COMMON_LIB="./lyrebird-common.sh"
#     fi
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

# Prevent multiple sourcing (idempotent)
if [[ -n "${_LYREBIRD_COMMON_LOADED:-}" ]]; then
    return 0 2>/dev/null || exit 0
fi

# Version of the common library (declared after guard to avoid readonly error on re-source)
readonly LYREBIRD_COMMON_VERSION="1.2.0"
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
    if declare -p RED &>/dev/null; then
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

#=============================================================================
# Durable Atomic File Replacement
#=============================================================================

# Flush one file or directory to stable storage. coreutils >= 8.24 syncs only
# the named path; older and minimal systems fall back to a global sync.
# Usage: lyrebird_fsync_path PATH
lyrebird_fsync_path() {
    sync -- "$1" 2>/dev/null || sync
}

# Replace DEST with the content of stdin, atomically and durably: write a
# hidden temp file in DEST's own directory, fsync it, rename it over DEST, then
# fsync the directory. A reader or a crash sees either the complete old content
# or the complete new content; once this returns 0 both the data and the rename
# have been requested from stable storage. Whether the medium honours that
# request is up to the storage stack (flash media included). If DEST is a
# symbolic link, the link itself is replaced.
# If a third argument names an existing file, the new file also takes that
# file's owner and group (best effort: only root can give a file away, and a
# failed chown leaves the invoking user as the owner).
# Usage: lyrebird_atomic_write DEST [MODE [OWNER_REFERENCE_FILE]] < content
# Returns: 0 on success; 1 on any failure, with DEST untouched and the temp
#          file removed (a SIGKILL can still leave a ".<name>.XXXXXX" temp file
#          behind, which is never read as DEST).
lyrebird_atomic_write() {
    local dest="${1:?lyrebird_atomic_write: destination required}"
    local mode="${2:-0644}"
    local owner_ref="${3:-}"
    local dir base tmp
    dir="$(dirname -- "$dest")"
    base="$(basename -- "$dest")"
    tmp="$(mktemp "${dir}/.${base}.XXXXXX")" || return 1
    if [[ -n "$owner_ref" && -e "$owner_ref" ]]; then
        chown --reference="$owner_ref" -- "$tmp" 2>/dev/null || true
    fi
    if ! cat >"$tmp" \
        || ! chmod "$mode" -- "$tmp" \
        || ! lyrebird_fsync_path "$tmp" \
        || ! mv -f -- "$tmp" "$dest"; then
        rm -f -- "$tmp"
        return 1
    fi
    lyrebird_fsync_path "$dir"
    return 0
}

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
# Process Identity (decision D11, X-54)
#=============================================================================
# This installation's processes are told apart by what they are, never by what they
# are called: a name or command-line pattern (`pgrep -x mediamtx`, `pgrep -f ...`)
# also matches an editor on mediamtx.yml, a decoy, another installation's MediaMTX
# and every other FFmpeg on the host. The display code (diagnostics, orchestrator)
# uses these two scans; the stream manager and the metrics exporter keep their own
# checks, which also use the start times they recorded.
#
# A process is identified by its executable (/proc/PID/exe, an upgrade's " (deleted)"
# suffix ignored) and its first argument (argv[1]; /proc/PID/cmdline is readable by
# every user). Where the executable of another user's process cannot be read (no
# root), argv[1], which is this installation's own configuration file or wrapper
# script, is the evidence.

# Set _LYREBIRD_ARGV1 to the first argument of process $1. Fails when the process is
# gone, a zombie or unreadable (nothing to read).
_lyrebird_proc_argv1() {
    _LYREBIRD_ARGV1=""
    local argv0=""
    {
        IFS= read -r -d '' argv0 || true
        IFS= read -r -d '' _LYREBIRD_ARGV1 || true
    } 2>/dev/null <"/proc/$1/cmdline" || return 1
    [[ -n "$argv0" ]]
}

# Print the PIDs of this installation's MediaMTX, one per line: the program at BIN
# running the configuration file CONFIG (how the stream manager and mediamtx.service
# both start it). Status 0 when there is one, 1 when there is none.
# Usage: lyrebird_mediamtx_pids BIN CONFIG
lyrebird_mediamtx_pids() {
    local bin="${1:?lyrebird_mediamtx_pids: program required}" config="${2:?lyrebird_mediamtx_pids: configuration file required}"
    local want dir pid exe found=1 deleted_suffix=" (deleted)"
    want="$(readlink -f -- "$bin" 2>/dev/null)" || want=""
    [[ -n "$want" ]] || want="$bin"
    for dir in /proc/[0-9]*; do
        pid="${dir#/proc/}"
        _lyrebird_proc_argv1 "$pid" || continue
        [[ "$_LYREBIRD_ARGV1" == "$config" ]] || continue
        if exe="$(readlink "/proc/${pid}/exe" 2>/dev/null)" && [[ -n "$exe" ]]; then
            [[ "${exe%"${deleted_suffix}"}" == "$want" ]] || continue
        fi
        printf '%s\n' "$pid"
        found=0
    done
    return "$found"
}

# Print the PIDs of the stream manager's wrapper processes, one per line: a bash whose
# first argument is a generated stream script, DIR/<stream>.sh (directly in DIR, the
# manager's FFmpeg directory, MEDIAMTX_FFMPEG_DIR). One per stream: the FFmpeg it runs
# is its child, and an FFmpeg that is not a child of one is none of ours. Status 0 when
# there is one, 1 when there is none.
# Usage: lyrebird_stream_wrapper_pids DIR
lyrebird_stream_wrapper_pids() {
    local dir="${1:?lyrebird_stream_wrapper_pids: wrapper directory required}"
    local script pid exe found=1 dirpath
    dir="${dir%/}"
    for dirpath in /proc/[0-9]*; do
        pid="${dirpath#/proc/}"
        _lyrebird_proc_argv1 "$pid" || continue
        script="$_LYREBIRD_ARGV1"
        [[ "$script" == "${dir}/"*.sh ]] || continue
        [[ "${script#"${dir}/"}" != */* ]] || continue
        if exe="$(readlink "/proc/${pid}/exe" 2>/dev/null)" && [[ -n "$exe" ]]; then
            [[ "${exe##*/}" == bash ]] || continue
        fi
        printf '%s\n' "$pid"
        found=0
    done
    return "$found"
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
            # Do NOT swallow the command's stderr — callers that need quiet
            # operation can redirect it themselves; hiding it here masked real
            # errors. 124 (timed out) is normalized to 1.
            local exit_code=0
            timeout "${timeout}" "$@" || exit_code=$?
            [[ "${exit_code}" == 124 ]] && return 1
            return "${exit_code}"
        else
            # No `timeout` binary (minimal/BusyBox userland): emulate it with a
            # background watchdog so a hung child cannot block forever on an
            # unattended box (the old fallback ran with no time limit at all).
            "$@" &
            local cmd_pid=$!
            (
                sleep "${timeout}" 2>/dev/null
                kill "${cmd_pid}" 2>/dev/null
            ) &
            local watch_pid=$!
            local exit_code=0
            wait "${cmd_pid}" 2>/dev/null || exit_code=$?
            # Command returned (or was killed by the watchdog); cancel the watchdog.
            kill "${watch_pid}" 2>/dev/null || true
            wait "${watch_pid}" 2>/dev/null || true
            return "${exit_code}"
        fi
    }
fi

#=============================================================================
# Progress Indicators
#=============================================================================

# Spinner characters for progress indication
readonly LYREBIRD_SPINNER_CHARS='⠋⠙⠹⠸⠼⠴⠦⠧⠇⠏'
# shellcheck disable=SC2034  # Alternative spinner for non-Unicode terminals
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

            # Restore the cursor if this subshell is killed/exits for ANY reason
            # (e.g. the parent dies before calling spinner_stop) so the terminal
            # is never left with a hidden cursor.
            trap 'printf "\033[?25h"' EXIT INT TERM

            # Hide cursor
            printf '\033[?25l'

            while true; do
                local char="${chars:$i:1}"
                printf '\r%s %s ' "${char}" "${message}"
                i=$(((i + 1) % len))
                sleep 0.1
            done
        ) &
        _LYREBIRD_SPINNER_PID=$!
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
            printf '\033[?25h' # Show cursor
            printf '\r\033[K'  # Clear line
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

        # Guard against division by zero
        if ((total <= 0)); then
            printf '\r%s [%*s] %3d%% ' "${message}" "${width}" "" 0
            return 0
        fi

        # Calculate percentage and filled width
        local percent=$((current * 100 / total))
        local filled=$((width * current / total))
        # Clamp filled to width to prevent overflow when current > total
        ((filled > width)) && filled=$width
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
            lyrebird_spinner_stop "[OK] ${message} - Done"
        else
            lyrebird_spinner_stop "[FAIL] ${message} - Failed"
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
            seconds=$((seconds - 1))
        done

        if [[ -t 1 ]] && [[ -z "${NO_COLOR:-}" ]]; then
            printf '\r\033[K' # Clear line
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
# MediaMTX Configuration Renderer (decisions D9, D10)
#=============================================================================

# First line of every configuration this library renders. The stream manager
# rewrites a configuration file only while its first line is exactly this; a
# file without it belongs to the operator and is never overwritten.
readonly LYREBIRD_MEDIAMTX_CONFIG_MARKER='# Managed by LyreBirdAudio'

# Is $1 a TCP/UDP port: decimal digits only, 1-65535 (leading zeros allowed)?
# Usage: lyrebird_is_valid_port VALUE
lyrebird_is_valid_port() {
    local value="${1-}"
    [[ "$value" =~ ^[0-9]{1,5}$ ]] && ((10#$value >= 1 && 10#$value <= 65535))
}

# Is $1 usable as the host part of a MediaMTX listen address: empty (every
# interface), an IPv4 literal or an IPv6 literal (without brackets)? A shape
# check (characters and layout, so a value can never carry anything else into a
# configuration file); MediaMTX itself refuses an address that does not parse.
# Usage: lyrebird_is_valid_bind_address VALUE
lyrebird_is_valid_bind_address() {
    local value="${1-}" octet
    [[ -z "$value" ]] && return 0
    if [[ "$value" =~ ^([0-9]{1,3})\.([0-9]{1,3})\.([0-9]{1,3})\.([0-9]{1,3})$ ]]; then
        for octet in "${BASH_REMATCH[@]:1:4}"; do
            ((10#$octet <= 255)) || return 1
        done
        return 0
    fi
    [[ "$value" =~ ^[0-9A-Fa-f]{0,4}(:[0-9A-Fa-f]{0,4}){2,7}$ ]]
}

# Print "MAJOR MINOR PATCH" for a MediaMTX version string such as "v1.21.1"
# (the first line of `mediamtx --version`). Fails for anything else.
# Usage: lyrebird_mediamtx_version_parts VERSION
lyrebird_mediamtx_version_parts() {
    [[ "${1-}" =~ ^v?([0-9]+)\.([0-9]+)\.([0-9]+) ]] || return 1
    printf '%s %s %s\n' "$((10#${BASH_REMATCH[1]}))" "$((10#${BASH_REMATCH[2]}))" "$((10#${BASH_REMATCH[3]}))"
}

# Quote $1 as a YAML single-quoted scalar ('' stands for a quote). Only
# printable ASCII is accepted: a control character, a newline or a byte above
# 0x7e fails (status 1, nothing printed), so a value can never end the scalar,
# start a new key or smuggle in a line break.
# Usage: lyrebird_yaml_quote VALUE
lyrebird_yaml_quote() {
    local value="${1-}"
    local LC_ALL=C
    [[ "$value" == *[^[:print:]]* ]] && return 1
    printf "'%s'" "${value//\'/\'\'}"
}

# Print a MediaMTX listen address: ":PORT", "1.2.3.4:PORT" or "[::1]:PORT".
# Usage: _lyrebird_mediamtx_address BIND PORT
_lyrebird_mediamtx_address() {
    local bind="$1" port="$2"
    if [[ "$bind" == *:* ]]; then
        printf '[%s]:%s' "$bind" "$port"
    else
        printf '%s:%s' "$bind" "$port"
    fi
}

# Print the "any" user and one read-only user per line of a users file, as
# MediaMTX authInternalUsers entries. The file holds "user:sha256:<base64>"
# lines (blank lines and lines starting with '#' are ignored); the base64 is
# that of the raw SHA-256 digest of the password:
#   printf '%s' 'the password' | openssl dgst -sha256 -binary | base64
# Anything else, a plaintext password included, is refused without echoing the
# line.
# Usage: _lyrebird_mediamtx_auth_block USERS_FILE   (USERS_FILE may be empty)
_lyrebird_mediamtx_auth_block() {
    local users_file="$1" line lineno=0 name hash quoted_name quoted_hash
    local -A seen=()
    printf 'authMethod: internal\n'
    printf 'authInternalUsers:\n'
    printf '  # This machine: publishers, health checks, API and metrics. No password; loopback only.\n'
    printf '  - user: any\n'
    printf '    pass:\n'
    printf "    ips: ['127.0.0.1', '::1']\n"
    printf '    permissions:\n'
    printf '      - action: publish\n'
    printf '      - action: read\n'
    printf '      - action: playback\n'
    printf '      - action: api\n'
    printf '      - action: metrics\n'
    printf '      - action: pprof\n'
    [[ -n "$users_file" ]] || return 0
    if ! [[ -r "$users_file" && -f "$users_file" ]]; then
        printf 'lyrebird_render_mediamtx_config: users file %s is not a readable file\n' "$users_file" >&2
        return 1
    fi
    while IFS= read -r line || [[ -n "$line" ]]; do
        lineno=$((lineno + 1))
        line="${line%$'\r'}"
        line="${line#"${line%%[![:space:]]*}"}"
        [[ -z "$line" || "$line" == '#'* ]] && continue
        if ! [[ "$line" =~ ^([A-Za-z0-9._@-]{1,64}):(sha256:[A-Za-z0-9+/]{43}=)$ ]]; then
            printf 'lyrebird_render_mediamtx_config: %s line %d is not "user:sha256:<base64 of the SHA-256 digest>" (plaintext passwords are refused)\n' "$users_file" "$lineno" >&2
            return 1
        fi
        name="${BASH_REMATCH[1]}"
        hash="${BASH_REMATCH[2]}"
        if [[ "$name" == any ]]; then
            printf 'lyrebird_render_mediamtx_config: %s line %d: the user name "any" is reserved for this machine\n' "$users_file" "$lineno" >&2
            return 1
        fi
        if [[ -n "${seen[$name]:-}" ]]; then
            printf 'lyrebird_render_mediamtx_config: %s line %d: user "%s" is listed twice\n' "$users_file" "$lineno" "$name" >&2
            return 1
        fi
        seen[$name]=1
        quoted_name="$(lyrebird_yaml_quote "$name")" || return 1
        quoted_hash="$(lyrebird_yaml_quote "$hash")" || return 1
        printf '  # Remote listener, read only.\n'
        printf '  - user: %s\n' "$quoted_name"
        printf '    pass: %s\n' "$quoted_hash"
        printf '    permissions:\n'
        printf '      - action: read\n'
        printf '      - action: playback\n'
    done <"$users_file"
}

# Render a complete MediaMTX configuration on stdout. Nothing is written
# anywhere and nothing is printed unless the whole file could be rendered.
#
# Every listener MediaMTX would start by default and this project does not use
# is switched off (RTMP, HLS, WebRTC, SRT and, from 1.19.0, MoQ); the control
# API and the metrics endpoint listen on the loopback address unless told
# otherwise; RTSP listens on every interface.
#
# Options (all optional; defaults in brackets):
#   --rtsp-port N / --api-port N / --metrics-port N   [8554 / 9997 / 9998]
#   --rtsp-bind ADDR   [every interface]   ADDR is empty, an IPv4 or an IPv6
#   --api-bind ADDR    [127.0.0.1]         literal; "" means every interface
#   --metrics-bind ADDR [127.0.0.1]
#   --api yes|no  --metrics yes|no   [yes / yes]
#   --log-level error|warn|info|debug   [info]
#   --read-timeout DUR / --write-timeout DUR   [30s]  (Go duration: 30s, 2m)
#   --mediamtx-version VERSION   [unknown]  e.g. v1.21.1; keys that older
#                                MediaMTX rejects (moq: 1.19.0) are written
#                                only for a version known to accept them
#   --stream-name NAME   [one catch-all path]  accept exactly this publisher
#                        path (multiplex mode); quoted as a YAML scalar, any
#                        control character or non-ASCII byte is refused
#   --auth-mode open|local-only-publish   [open]  local-only-publish turns on
#                        internal authentication: this machine (127.0.0.1, ::1)
#                        may publish, read and call the API without a password;
#                        everyone else needs a user from --users-file
#   --users-file FILE    remote read-only users, "user:sha256:<base64>" lines
# The first line of the output is $LYREBIRD_MEDIAMTX_CONFIG_MARKER.
# Returns: 0, or 1 with a message on stderr (invalid option or value).
lyrebird_render_mediamtx_config() {
    local rtsp_port=8554 api_port=9997 metrics_port=9998
    local rtsp_bind="" api_bind="127.0.0.1" metrics_bind="127.0.0.1"
    local api=yes metrics=yes log_level=info version="" stream_name=""
    local read_timeout=30s write_timeout=30s auth_mode=open users_file=""
    local opt="" parts="" major=0 minor=0 quoted_name="" auth_block="" out=""

    while (($#)); do
        opt="$1"
        if (($# < 2)); then
            printf 'lyrebird_render_mediamtx_config: option %s needs a value\n' "$opt" >&2
            return 1
        fi
        case "$opt" in
            --rtsp-port) rtsp_port="$2" ;;
            --api-port) api_port="$2" ;;
            --metrics-port) metrics_port="$2" ;;
            --rtsp-bind) rtsp_bind="$2" ;;
            --api-bind) api_bind="$2" ;;
            --metrics-bind) metrics_bind="$2" ;;
            --api) api="$2" ;;
            --metrics) metrics="$2" ;;
            --log-level) log_level="$2" ;;
            --read-timeout) read_timeout="$2" ;;
            --write-timeout) write_timeout="$2" ;;
            --mediamtx-version) version="$2" ;;
            --stream-name) stream_name="$2" ;;
            --auth-mode) auth_mode="$2" ;;
            --users-file) users_file="$2" ;;
            *)
                printf 'lyrebird_render_mediamtx_config: unknown option %s\n' "$opt" >&2
                return 1
                ;;
        esac
        shift 2
    done

    local name value
    for name in rtsp_port api_port metrics_port; do
        value="${!name}"
        if ! lyrebird_is_valid_port "$value"; then
            printf 'lyrebird_render_mediamtx_config: --%s must be an integer from 1 to 65535 (got: %q)\n' "${name//_/-}" "$value" >&2
            return 1
        fi
        printf -v "$name" '%s' "$((10#$value))"
    done
    if [[ "$rtsp_port" == "$api_port" || "$rtsp_port" == "$metrics_port" || "$api_port" == "$metrics_port" ]]; then
        printf 'lyrebird_render_mediamtx_config: the RTSP, API and metrics ports must differ (got %s, %s, %s)\n' "$rtsp_port" "$api_port" "$metrics_port" >&2
        return 1
    fi
    for name in rtsp_bind api_bind metrics_bind; do
        value="${!name}"
        if ! lyrebird_is_valid_bind_address "$value"; then
            printf 'lyrebird_render_mediamtx_config: --%s must be empty or an IPv4/IPv6 address (got: %q)\n' "${name//_/-}" "$value" >&2
            return 1
        fi
    done
    for name in api metrics; do
        value="${!name}"
        if [[ "$value" != yes && "$value" != no ]]; then
            printf 'lyrebird_render_mediamtx_config: --%s must be yes or no (got: %q)\n' "$name" "$value" >&2
            return 1
        fi
    done
    case "$log_level" in
        error | warn | info | debug) ;;
        *)
            printf 'lyrebird_render_mediamtx_config: --log-level must be error, warn, info or debug (got: %q)\n' "$log_level" >&2
            return 1
            ;;
    esac
    for name in read_timeout write_timeout; do
        value="${!name}"
        if ! [[ "$value" =~ ^[0-9]+(ms|s|m|h)$ ]]; then
            printf 'lyrebird_render_mediamtx_config: --%s must be a duration such as 30s or 2m (got: %q)\n' "${name//_/-}" "$value" >&2
            return 1
        fi
    done
    case "$auth_mode" in
        open | local-only-publish) ;;
        *)
            printf 'lyrebird_render_mediamtx_config: --auth-mode must be open or local-only-publish (got: %q)\n' "$auth_mode" >&2
            return 1
            ;;
    esac
    if [[ "$auth_mode" == open && -n "$users_file" ]]; then
        printf 'lyrebird_render_mediamtx_config: --users-file only applies to --auth-mode local-only-publish\n' >&2
        return 1
    fi
    if [[ -n "$stream_name" ]]; then
        if ! quoted_name="$(lyrebird_yaml_quote "$stream_name")"; then
            printf 'lyrebird_render_mediamtx_config: --stream-name contains a control character or a non-ASCII byte\n' >&2
            return 1
        fi
    else
        quoted_name="'~^[a-zA-Z0-9_-]+\$'"
    fi
    if [[ "$auth_mode" == local-only-publish ]]; then
        # The trailing "x" keeps $(...) from stripping the final newline
        auth_block="$(_lyrebird_mediamtx_auth_block "$users_file" && printf x)" || return 1
        auth_block="${auth_block%x}"
    fi

    out="${LYREBIRD_MEDIAMTX_CONFIG_MARKER}"$'\n'
    out+="# Rendered by lyrebird_render_mediamtx_config (lyrebird-common.sh). The stream manager"$'\n'
    out+="# rewrites this file only while the first line above is present. To keep hand edits,"$'\n'
    out+="# delete that line: the file is then yours and is never overwritten."$'\n'
    out+="logLevel: ${log_level}"$'\n'
    out+="readTimeout: ${read_timeout}"$'\n'
    out+="writeTimeout: ${write_timeout}"$'\n'
    out+=$'\n'
    out+="api: ${api}"$'\n'
    out+="apiAddress: $(_lyrebird_mediamtx_address "$api_bind" "$api_port")"$'\n'
    out+=$'\n'
    out+="metrics: ${metrics}"$'\n'
    out+="metricsAddress: $(_lyrebird_mediamtx_address "$metrics_bind" "$metrics_port")"$'\n'
    out+=$'\n'
    out+="rtsp: yes"$'\n'
    out+="rtspAddress: $(_lyrebird_mediamtx_address "$rtsp_bind" "$rtsp_port")"$'\n'
    out+="rtspTransports: [tcp, udp]"$'\n'
    out+=$'\n'
    out+="rtmp: no"$'\n'
    out+="hls: no"$'\n'
    out+="webrtc: no"$'\n'
    out+="srt: no"$'\n'
    # MediaMTX >= 1.19.0 starts a MoQ (Media over QUIC) server by default
    # (:8892/tcp+udp and :8893/udp on every interface), so it is switched off
    # there; 1.15-1.18 reject the key and refuse to start, and a version that
    # cannot be read leaves the key out.
    if parts="$(lyrebird_mediamtx_version_parts "$version")"; then
        read -r major minor _ <<<"$parts"
        if ((major > 1 || (major == 1 && minor >= 19))); then
            out+="moq: no"$'\n'
        fi
    fi
    if [[ -n "$auth_block" ]]; then
        out+=$'\n'"${auth_block}"
    fi
    out+=$'\n'
    out+="paths:"$'\n'
    out+="  ${quoted_name}:"$'\n'
    out+="    source: publisher"$'\n'
    out+="    sourceProtocol: automatic"$'\n'
    out+="    sourceOnDemand: no"$'\n'
    printf '%s' "$out"
}

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
