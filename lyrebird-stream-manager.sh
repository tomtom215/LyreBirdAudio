#!/bin/bash
# lyrebird-stream-manager.sh - Automatic MediaMTX audio stream configuration
# Part of LyreBirdAudio - RTSP Audio Streaming Suite
# https://github.com/tomtom215/LyreBirdAudio
#
# Author: Tom F (https://github.com/tomtom215)
# Copyright: Tom F and LyreBirdAudio contributors
# License: Apache 2.0
#
# This script automatically detects USB microphones and creates MediaMTX
# configurations for continuous 24/7 RTSP audio streams.
#
# Version: 1.5.1
# Compatible with MediaMTX v1.15.0 through at least v1.21.1. The generated
# mediamtx.yml, stream start-up and readiness probing are tested against the
# real 1.15.0, 1.18.0, 1.19.0 and 1.21.1 binaries (tests/test_mediamtx_live.bats;
# 1.16.0, 1.17.0, 1.20.0 and 1.21.0 were also run once). NOTE: the path status
# fields parsed below ("ready", "bytesReceived", "tracks") are DEPRECATED as of
# v1.16/v1.17 in favour of "available"/"online"/"inboundBytes"/"tracks2" -- they
# are still returned today, but a JSON-field migration (with real-hardware
# validation) is advisable before a future MediaMTX major release removes them.
#
# Version History:
# v1.5.1 - Generated mediamtx.yml disables the MoQ server that MediaMTX
#          >= 1.19.0 starts by default (key written only for >= 1.19.0, which
#          older versions reject)
#
# v1.5.0 - Reliability audit, third pass (see CHANGELOG.md, "Reliability Audit
#          (2026-07, third pass)")
#
# v1.4.4 - Robustness improvements
#   - Restructured API validation to preserve curl exit status for better error detection
#   - curl|grep pattern replaced with explicit exit code checking
#
# v1.4.3 - Complete MediaMTX v1.15.5 API integration
#   API INTEGRATION:
#   - Full REST API coverage for all MediaMTX v1.15.5 endpoints
#   - Instance info endpoint (/v3/info) for version and uptime
#   - Global and path defaults configuration management
#   - Dynamic path CRUD (add/delete/patch/replace) without restart
#   - RTSP/RTSPS connection and session management with kick support
#   - RTMP/RTMPS connection management with disconnect capability
#   - SRT connection management
#   - WebRTC session management
#   - HLS muxer monitoring
#   - Recording management and segment deletion
#   - JWT JWKS credential refresh
#   - Utility functions for connection counting and health checks
#   - Generic API call wrapper with proper HTTP status handling
#
# v1.4.2 - Production reliability enhancements for 24/7 field deployment
#   MONITORING ENHANCEMENTS:
#   - Watchdog/heartbeat mechanism with optional hardware watchdog support
#   - Disk space monitoring with configurable thresholds
#   - Memory usage trending and leak detection
#   - Network connectivity monitoring with gateway check
#   - MediaMTX API version auto-detection with fallback
#   - USB device ALSA availability checking before restart
#   - Configuration validation on startup
#
#   BUFFERING IMPROVEMENTS:
#   - Optional memory-based audio ring buffer (reduces data loss on restart)
#   - Configurable buffer size per stream
#   - Optional disk persistence for buffers (SD card wear consideration)
#
#   RELIABILITY FIXES:
#   - Enhanced signal handling (SIGPIPE, SIGHUP, SIGQUIT)
#   - Lock directory validation before file creation
#   - Process group termination improvements
#   - Version compatibility checking between scripts
#
# v1.4.1 - Friendly name support for audio device configuration
#   CONFIGURATION ENHANCEMENT:
#   - Added dual-lookup config system supporting both friendly and full device names
#   - Users can now use friendly stream names (e.g., DEVICE_BLUE_YETI_SAMPLE_RATE=44100)
#   - Friendly names match RTSP stream paths for easier configuration
#   - Maintains 100% backward compatibility with existing full device name configs
#   - Updated config file template with friendly name documentation and examples
#
# v1.4.0 - Production stability and monitoring enhancements
#   RELIABILITY IMPROVEMENTS:
#   - Separate monitoring lock eliminates service/cron contention
#   - Conservative cron restart policy (exit 2 only) for stable 24/7 operation
#   - Increased systemd restart tolerance (10 restarts/20min) for USB hotplug
#   - Recursive process tree termination ensures complete cleanup
#   - Enhanced lock file mutual exclusion prevents concurrent execution
#
#   MONITORING ENHANCEMENTS:
#   - Multiplex stream health monitoring with automatic restart
#   - Real-time progress messages during stream initialization
#   - FFmpeg log rotation prevents unbounded disk usage
#   - Resource monitoring (CPU, file descriptors) with threshold alerts
#
#   STABILITY FIXES:
#   - Stream name validation prevents RTSP parsing failures
#   - Cron installation handles special characters in paths
#   - Wrapper PID validation detects stale processes
#   - Config file permission race condition eliminated
#
#   API COMPATIBILITY:
#   - Error codes maintained for backward compatibility
#   - Best-effort return behavior for partial stream failures
#
# v1.3.4 - Production fix for stream persistence after device events
#   CRITICAL FIXES:
#   - Removed stream-specific lock that caused restart failures after device events
#   - Added stream health monitoring with automatic restart to monitor command
#   - Fixed wrapper PID validation to detect truly stale processes
#   - Added stream reconciliation without touching device discovery logic
#   VERIFIED: Maintains v1.3.2 stability while adding v1.3.3 quality fixes
#   VERIFIED: Zero changes to device detection - proven logic preserved
#
# v1.3.3 and earlier - Production hardening and feature development
#   - Multiplex streaming mode for combining multiple microphones
#   - Comprehensive code review fixes (FD leaks, unicode, validation)
#   - systemd integration and signal handling improvements
#   - Resource monitoring and atomic file operations
#
# Requirements:
# - MediaMTX installed (use install_mediamtx.sh)
# - USB audio devices
# - ffmpeg installed for audio encoding

#   - Added multiplex mode for combining multiple microphones into single stream
#   - Added filter support (amix for mixing, amerge for channel separation)
#   - Preserved all v1.2.0 critical fixes and functionality
#
# v1.2.0 - Major production reliability overhaul
#   - Fixed CONFIG_LOCK_FILE subshell isolation for proper config updates
#   - Fixed PID file permission race condition for systemd compatibility
#   - Made cleanup marker creation atomic to prevent partial states
#   - Added resource monitoring with 'monitor' command
#   - Added deferred cleanup handler for interrupted terminations
#   - Enhanced all atomic file operations (PID, config, markers)
#   - Improved process group termination and signal propagation
#   - Stabilized device detection with single scan approach
#
# Requirements:
# - MediaMTX installed (use install_mediamtx.sh)
# - USB audio devices
# - ffmpeg installed for audio encoding

# Ensure we're running with bash
if [ -z "$BASH_VERSION" ]; then
    echo "Error: This script requires bash. Please run with: bash $0 $*" >&2
    exit 1
fi

set -euo pipefail

# Enable error tracing in debug mode
if [[ "${DEBUG:-false}" == "true" ]]; then
    set -x
fi

# Source shared library if available (backward compatible)
# Provides: colors, logging, command_exists, compute_hash, exit codes
# Falls back gracefully if library not present - all functions defined locally below
_LYREBIRD_COMMON="${BASH_SOURCE[0]%/*}/lyrebird-common.sh"

# v1.4.2: Verify library integrity before sourcing (security hardening)
# Set LYREBIRD_COMMON_EXPECTED_HASH to enable verification
# To generate: sha256sum lyrebird-common.sh | cut -d' ' -f1
_LYREBIRD_COMMON_EXPECTED_HASH="${LYREBIRD_COMMON_EXPECTED_HASH:-}"

_verify_common_library() {
    local lib_path="$1"
    local expected_hash="$2"

    # Skip verification if no expected hash provided (backward compatible)
    [[ -z "$expected_hash" ]] && return 0

    # Compute actual hash
    local actual_hash=""
    if command -v sha256sum >/dev/null 2>&1; then
        actual_hash=$(sha256sum "$lib_path" 2>/dev/null | cut -d' ' -f1)
    elif command -v shasum >/dev/null 2>&1; then
        actual_hash=$(shasum -a 256 "$lib_path" 2>/dev/null | cut -d' ' -f1)
    else
        # No hash tool available, skip verification with warning
        echo "[WARN] Cannot verify lyrebird-common.sh integrity (no sha256sum/shasum)" >&2
        return 0
    fi

    if [[ "$actual_hash" != "$expected_hash" ]]; then
        echo "[ERROR] lyrebird-common.sh integrity check failed!" >&2
        echo "[ERROR] Expected: $expected_hash" >&2
        echo "[ERROR] Actual:   $actual_hash" >&2
        echo "[ERROR] The library may have been tampered with. Aborting." >&2
        return 1
    fi

    return 0
}

# shellcheck source=lyrebird-common.sh
if [[ -f "$_LYREBIRD_COMMON" ]]; then
    if _verify_common_library "$_LYREBIRD_COMMON" "$_LYREBIRD_COMMON_EXPECTED_HASH"; then
        source "$_LYREBIRD_COMMON"
    else
        # Integrity check failed - exit for security
        exit 1
    fi
fi
unset _LYREBIRD_COMMON _LYREBIRD_COMMON_EXPECTED_HASH
unset -f _verify_common_library

# Constants
readonly VERSION="1.5.1"

# Script identification
SCRIPT_NAME="$(basename "${BASH_SOURCE[0]}")"
readonly SCRIPT_NAME
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly SCRIPT_DIR

# Error codes
readonly E_GENERAL=1
readonly E_CRITICAL_RESOURCE=2
readonly E_MISSING_DEPS=3
readonly E_CONFIG_ERROR=4
readonly E_LOCK_FAILED=5
readonly E_USB_NO_DEVICES=6
readonly E_MEDIAMTX_DOWN=7
readonly E_OWNERSHIP=8
readonly E_MONITOR_DEGRADED=10

# Configurable paths with environment variable defaults
readonly CONFIG_DIR="${MEDIAMTX_CONFIG_DIR:-/etc/mediamtx}"
readonly CONFIG_FILE="${MEDIAMTX_CONFIG_FILE:-${CONFIG_DIR}/mediamtx.yml}"
readonly DEVICE_CONFIG_FILE="${MEDIAMTX_DEVICE_CONFIG:-${CONFIG_DIR}/audio-devices.conf}"
readonly PID_FILE="${MEDIAMTX_PID_FILE:-/run/mediamtx-audio.pid}"
readonly FFMPEG_PID_DIR="${MEDIAMTX_FFMPEG_DIR:-/var/lib/mediamtx-ffmpeg}"
readonly LOCK_FILE="${MEDIAMTX_LOCK_FILE:-/run/mediamtx-audio.lock}"
# Lock file strategy (see the "Locking" section below for the details):
# - Uses flock() for exclusive access (kernel-enforced); the kernel drops the
#   lock when the holder exits, however it exits
# - File descriptor stored in MAIN_LOCK_FD global variable
# - The lock file is NEVER removed and NEVER truncated, and there is no
#   age- or process-name-based staleness (LOCK_STALE_THRESHOLD is ignored)
# - Separate monitor lock (/run/mediamtx-monitor.lock) used by cron
#   to avoid contention with service lock during start/stop operations
readonly LOG_FILE="${MEDIAMTX_LOG_FILE:-/var/log/lyrebird-stream-manager.log}"
readonly MEDIAMTX_LOG_FILE="${MEDIAMTX_LOG_FILE:-/var/log/mediamtx.out}"
readonly MEDIAMTX_BIN="${MEDIAMTX_BINARY:-/usr/local/bin/mediamtx}"
readonly MEDIAMTX_HOST="${MEDIAMTX_HOST:-localhost}"
# Note: These are NOT readonly to allow command-line option overrides
STREAM_MODE="${STREAM_MODE:-individual}"
MULTIPLEX_STREAM_NAME="${MULTIPLEX_STREAM_NAME:-all_mics}"
MULTIPLEX_FILTER_TYPE="${MULTIPLEX_FILTER_TYPE:-amix}"
readonly RESTART_MARKER="${MEDIAMTX_RESTART_MARKER:-/run/mediamtx-audio.restart}"
readonly CLEANUP_MARKER="${MEDIAMTX_CLEANUP_MARKER:-/run/mediamtx-audio.cleanup}"
readonly CONFIG_LOCK_FILE="${CONFIG_DIR}/.config.lock"

# System limits
SYSTEM_PID_MAX="$(cat /proc/sys/kernel/pid_max 2>/dev/null || echo 32768)"
readonly SYSTEM_PID_MAX

# Timeouts
readonly PID_TERMINATION_TIMEOUT="${PID_TERMINATION_TIMEOUT:-10}"
readonly MEDIAMTX_API_TIMEOUT="${MEDIAMTX_API_TIMEOUT:-60}"
readonly LOCK_ACQUISITION_TIMEOUT="${LOCK_ACQUISITION_TIMEOUT:-30}"

# Audio settings
readonly DEFAULT_SAMPLE_RATE="${DEFAULT_SAMPLE_RATE:-48000}"
readonly DEFAULT_CHANNELS="${DEFAULT_CHANNELS:-2}"
readonly DEFAULT_CODEC="${DEFAULT_CODEC:-opus}"
readonly DEFAULT_BITRATE="${DEFAULT_BITRATE:-128k}"
readonly DEFAULT_THREAD_QUEUE="${DEFAULT_THREAD_QUEUE:-8192}"
readonly DEFAULT_ANALYZEDURATION="${DEFAULT_ANALYZEDURATION:-5000000}"
readonly DEFAULT_PROBESIZE="${DEFAULT_PROBESIZE:-5000000}"

# Stream name validation
readonly MAX_STREAM_NAME_LENGTH=48
readonly MIN_STREAM_NAME_LENGTH=1
readonly RESERVED_STREAM_NAMES="control|stats|api|metrics|health"

# Coerce an env override to a non-negative base-10 integer, falling back to
# the default when the value is not all digits. A non-numeric value (e.g.
# CRON_RESTART_MAX_PER_HOUR=unlimited) otherwise reaches arithmetic evaluation
# later and ABORTS the whole run under set -e -- silently killing every cron
# monitor pass. Base-10 also stops 08/09 being misread as invalid octal.
_uint_or() {
    local value="${1:-}" default="$2"
    if [[ "$value" =~ ^[0-9]+$ ]]; then
        printf '%s' "$((10#$value))"
    else
        printf '%s' "$default"
    fi
}

# Same, for integers that may carry a leading minus sign (dB thresholds).
_int_or() {
    local value="${1:-}" default="$2"
    if [[ "$value" =~ ^-?[0-9]+$ ]]; then
        printf '%s' "$value"
    else
        printf '%s' "$default"
    fi
}

# Timing settings
STREAM_STARTUP_DELAY=$(_uint_or "${STREAM_STARTUP_DELAY:-}" 10)
readonly STREAM_STARTUP_DELAY
STREAM_VALIDATION_ATTEMPTS=$(_uint_or "${STREAM_VALIDATION_ATTEMPTS:-}" 3)
readonly STREAM_VALIDATION_ATTEMPTS
STREAM_VALIDATION_DELAY=$(_uint_or "${STREAM_VALIDATION_DELAY:-}" 5)
readonly STREAM_VALIDATION_DELAY
USB_STABILIZATION_DELAY=$(_uint_or "${USB_STABILIZATION_DELAY:-}" 5)
readonly USB_STABILIZATION_DELAY
RESTART_STABILIZATION_DELAY=$(_uint_or "${RESTART_STABILIZATION_DELAY:-}" 15)
readonly RESTART_STABILIZATION_DELAY
# How long stop and force-stop wait for the lifecycle lock before refusing
STOP_LOCK_TIMEOUT=$(_uint_or "${STOP_LOCK_TIMEOUT:-}" 5)
readonly STOP_LOCK_TIMEOUT

# Resource monitoring thresholds
MAX_FD_WARNING=$(_uint_or "${MAX_FD_WARNING:-}" 500)
readonly MAX_FD_WARNING
MAX_FD_CRITICAL=$(_uint_or "${MAX_FD_CRITICAL:-}" 1000)
readonly MAX_FD_CRITICAL
MAX_CPU_WARNING=$(_uint_or "${MAX_CPU_WARNING:-}" 20)
readonly MAX_CPU_WARNING
MAX_CPU_CRITICAL=$(_uint_or "${MAX_CPU_CRITICAL:-}" 40)
readonly MAX_CPU_CRITICAL
MAX_WRAPPER_RESTARTS=$(_uint_or "${MAX_WRAPPER_RESTARTS:-}" 50)
readonly MAX_WRAPPER_RESTARTS
WRAPPER_SUCCESS_DURATION=$(_uint_or "${WRAPPER_SUCCESS_DURATION:-}" 300)
readonly WRAPPER_SUCCESS_DURATION

# Wrapper restart behavior (extracted from hardcoded values)
MAX_CONSECUTIVE_FAILURES=$(_uint_or "${MAX_CONSECUTIVE_FAILURES:-}" 5)
readonly MAX_CONSECUTIVE_FAILURES
INITIAL_RESTART_DELAY=$(_uint_or "${INITIAL_RESTART_DELAY:-}" 10)
readonly INITIAL_RESTART_DELAY
MAX_RESTART_DELAY=$(_uint_or "${MAX_RESTART_DELAY:-}" 300)
readonly MAX_RESTART_DELAY

# Log rotation settings
MAIN_LOG_MAX_SIZE=$(_uint_or "${MAIN_LOG_MAX_SIZE:-}" 104857600) # 100MB
readonly MAIN_LOG_MAX_SIZE
FFMPEG_LOG_MAX_SIZE=$(_uint_or "${FFMPEG_LOG_MAX_SIZE:-}" 10485760) # 10MB
readonly FFMPEG_LOG_MAX_SIZE
MEDIAMTX_LOG_MAX_SIZE=$(_uint_or "${MEDIAMTX_LOG_MAX_SIZE:-}" 52428800) # 50MB
readonly MEDIAMTX_LOG_MAX_SIZE
# Runs of each stream's FFmpeg log kept besides the live one (0-20)
FFMPEG_LOG_KEEP=$(_uint_or "${FFMPEG_LOG_KEEP:-}" 3)
((FFMPEG_LOG_KEEP <= 20)) || FFMPEG_LOG_KEEP=20
readonly FFMPEG_LOG_KEEP

# ============================================================================
# Production Reliability Settings (v1.4.2 additions)
# ============================================================================

# Bounded cron resurrection: how many times per rolling hour the cron monitor
# may restart a single dead stream. A stream whose wrapper has given up (after
# repeated failures) MUST be brought back under cron, or it stays down forever on
# an unattended box (H8). The cap prevents a persistently-failing stream from
# being restarted every 5 minutes indefinitely (a restart storm).
CRON_RESTART_MAX_PER_HOUR=$(_uint_or "${CRON_RESTART_MAX_PER_HOUR:-}" 6)
readonly CRON_RESTART_MAX_PER_HOUR
readonly CRON_RESTART_STATE_DIR="${CRON_RESTART_STATE_DIR:-/run/lyrebird/cron-restarts}"

# Deep health probe (H9): a live wrapper PID does not prove audio is flowing --
# the wrapper may sit in endless backoff, or FFmpeg may hang with the path
# never publishing. When the MediaMTX control API is reachable, monitor also
# asks it whether each path is actually ready; a stream that stays not-ready
# for DEEP_HEALTH_MAX_STRIKES consecutive monitor runs is restarted. Strikes
# live in /run (reset at boot). API-unreachable never strikes a stream.
readonly DEEP_HEALTH_CHECK_ENABLED="${DEEP_HEALTH_CHECK_ENABLED:-true}"
DEEP_HEALTH_MAX_STRIKES=$(_uint_or "${DEEP_HEALTH_MAX_STRIKES:-}" 3)
readonly DEEP_HEALTH_MAX_STRIKES
readonly DEEP_HEALTH_STATE_DIR="${DEEP_HEALTH_STATE_DIR:-/run/lyrebird/deep-health}"

# Heartbeat: the Unix time of the last monitor run (update_heartbeat, written
# once per run of the cron `monitor`). It proves that the monitor ran, nothing
# else: it is written while MediaMTX is down too. There is no software watchdog in
# this script; a hardware watchdog is systemd's RuntimeWatchdogSec= or a watchdog
# daemon (the settings of the removed implementation: warn_removed_settings).
readonly HEARTBEAT_FILE="${HEARTBEAT_FILE:-/run/mediamtx-audio.heartbeat}"

# Disk space monitoring thresholds
DISK_SPACE_WARNING_PERCENT=$(_uint_or "${DISK_SPACE_WARNING_PERCENT:-}" 80)
readonly DISK_SPACE_WARNING_PERCENT
DISK_SPACE_CRITICAL_PERCENT=$(_uint_or "${DISK_SPACE_CRITICAL_PERCENT:-}" 95)
readonly DISK_SPACE_CRITICAL_PERCENT
DISK_SPACE_MIN_FREE_MB=$(_uint_or "${DISK_SPACE_MIN_FREE_MB:-}" 100) # Minimum free MB
readonly DISK_SPACE_MIN_FREE_MB

# Memory monitoring and leak detection
MEM_WARNING_PERCENT=$(_uint_or "${MEM_WARNING_PERCENT:-}" 80)
readonly MEM_WARNING_PERCENT
MEM_CRITICAL_PERCENT=$(_uint_or "${MEM_CRITICAL_PERCENT:-}" 95)
readonly MEM_CRITICAL_PERCENT
MEM_GROWTH_THRESHOLD_MB=$(_uint_or "${MEM_GROWTH_THRESHOLD_MB:-}" 100) # MB growth triggers restart
readonly MEM_GROWTH_THRESHOLD_MB
readonly MEM_SAMPLE_FILE="${MEM_SAMPLE_FILE:-/var/lib/mediamtx-ffmpeg/.mem_samples}"

# Network connectivity monitoring
readonly NETWORK_CHECK_ENABLED="${NETWORK_CHECK_ENABLED:-true}"
readonly NETWORK_CHECK_TARGET="${NETWORK_CHECK_TARGET:-gateway}" # gateway, specific IP, or hostname
NETWORK_CHECK_TIMEOUT=$(_uint_or "${NETWORK_CHECK_TIMEOUT:-}" 5) # Seconds
readonly NETWORK_CHECK_TIMEOUT
NETWORK_FAIL_THRESHOLD=$(_uint_or "${NETWORK_FAIL_THRESHOLD:-}" 3) # Consecutive failures before alert
readonly NETWORK_FAIL_THRESHOLD

# Audio buffering (memory only)
# Memory buffering is done via FFmpeg's rtbufsize option (no SD card wear)
readonly AUDIO_BUFFER_ENABLED="${AUDIO_BUFFER_ENABLED:-true}"   # Enable enhanced memory buffering
AUDIO_BUFFER_SIZE_MB=$(_uint_or "${AUDIO_BUFFER_SIZE_MB:-}" 64) # Memory buffer size per stream (MB)
readonly AUDIO_BUFFER_SIZE_MB
AUDIO_RTBUFSIZE=$(_uint_or "${AUDIO_RTBUFSIZE:-}" 33554432) # Real-time buffer size in bytes (32MB default)
readonly AUDIO_RTBUFSIZE
# Local recording (ring buffer): FFmpeg writes the last AUDIO_RECORDING_SEGMENTS
# segments of each stream to AUDIO_RECORDING_PATH alongside streaming. The default
# is tmpfs (RAM): it does not survive a reboot or power loss. Recording that must
# survive means pointing AUDIO_RECORDING_PATH at persistent storage; there is no
# separate disk-persistence switch (AUDIO_DISK_PERSIST / AUDIO_DISK_PATH were
# removed: they only created a directory nothing wrote to).
readonly AUDIO_LOCAL_RECORDING="${AUDIO_LOCAL_RECORDING:-false}"                  # Enable local recording backup
readonly AUDIO_RECORDING_PATH="${AUDIO_RECORDING_PATH:-/dev/shm/lyrebird-buffer}" # Default to tmpfs (RAM)
AUDIO_RECORDING_SEGMENT_TIME=$(_uint_or "${AUDIO_RECORDING_SEGMENT_TIME:-}" 300)  # 5 min segments
readonly AUDIO_RECORDING_SEGMENT_TIME
AUDIO_RECORDING_SEGMENTS=$(_uint_or "${AUDIO_RECORDING_SEGMENTS:-}" 12) # Keep last 12 segments (1 hour)
readonly AUDIO_RECORDING_SEGMENTS

# Audio level monitoring (detect dead/silent microphones). The monitor reads a
# few seconds of each published stream back from MediaMTX over RTSP and measures
# its level (probe_stream_level, monitor_signals); it never opens an ALSA device.
readonly AUDIO_LEVEL_CHECK_ENABLED="${AUDIO_LEVEL_CHECK_ENABLED:-true}"      # Enable silence detection
AUDIO_LEVEL_SAMPLE_DURATION=$(_uint_or "${AUDIO_LEVEL_SAMPLE_DURATION:-}" 3) # Seconds of the stream to measure
readonly AUDIO_LEVEL_SAMPLE_DURATION
# Seconds the probe may spend connecting and finishing beyond the sample itself
# before it is killed (the whole probe is bounded by sample + this)
AUDIO_LEVEL_PROBE_GRACE=$(_uint_or "${AUDIO_LEVEL_PROBE_GRACE:-}" 10)
readonly AUDIO_LEVEL_PROBE_GRACE
# Least seconds between two probes of one stream: a monitor run that comes
# sooner (a manual run, cron every minute) leaves the stream alone
AUDIO_LEVEL_CHECK_INTERVAL=$(_uint_or "${AUDIO_LEVEL_CHECK_INTERVAL:-}" 240)
readonly AUDIO_LEVEL_CHECK_INTERVAL
AUDIO_SILENCE_THRESHOLD_DB=$(_int_or "${AUDIO_SILENCE_THRESHOLD_DB:-}" -60) # dB (max_volume) at or below which is "silence"
readonly AUDIO_SILENCE_THRESHOLD_DB
AUDIO_SILENCE_WARN_DURATION=$(_uint_or "${AUDIO_SILENCE_WARN_DURATION:-}" 60) # Seconds of silence before the DEAD MIC error
readonly AUDIO_SILENCE_WARN_DURATION
# Silence episodes and probe times per stream (under /run: cleared at boot)
readonly SILENCE_STATE_DIR="${SILENCE_STATE_DIR:-/run/lyrebird/silence}"

# MediaMTX API version compatibility
readonly MEDIAMTX_API_VERSION="${MEDIAMTX_API_VERSION:-auto}"   # auto, v3, v2, v1
readonly MEDIAMTX_API_FALLBACK="${MEDIAMTX_API_FALLBACK:-true}" # Try older API versions

# USB device health checks
readonly USB_ALSA_CHECK_ENABLED="${USB_ALSA_CHECK_ENABLED:-true}"             # Check ALSA availability before restart
USB_DISCONNECT_GRACE_PERIOD=$(_uint_or "${USB_DISCONNECT_GRACE_PERIOD:-}" 10) # Seconds to wait after disconnect
readonly USB_DISCONNECT_GRACE_PERIOD

# Version compatibility
readonly MIN_COMPATIBLE_COMMON_VERSION="1.0.0"
# shellcheck disable=SC2034 # SCRIPT_COMPAT_VERSION exported for external version checking tools
readonly SCRIPT_COMPAT_VERSION="1.5.0"

# Standard timing constants
readonly QUICK_SLEEP=0.1
# shellcheck disable=SC2034 # timing constant; its only user, the old SIGINT wait loop, is gone
readonly SHORT_SLEEP=1
readonly MEDIUM_SLEEP=2

# Global lock file descriptor
declare -gi MAIN_LOCK_FD=-1

# Global config lock file descriptor
declare -gi CONFIG_LOCK_FD=-1

# Descriptor handed back by lock_open_and_acquire (-1 when it failed)
declare -gi LOCK_OPENED_FD=-1

# Set once the LOCK_STALE_THRESHOLD deprecation line has been logged
declare -g LOCK_DEPRECATION_LOGGED=false

# Skip cleanup flag
declare -g SKIP_CLEANUP=false

# Command being executed (COMMAND used by cleanup trap, must be initialized early)
declare -g COMMAND=""

# Arguments that follow the command (force-stop --kill-all --yes)
declare -ga COMMAND_ARGS=()

# Flag to indicate if we're in a stop/force-stop operation
declare -g STOPPING_SERVICE=false

# Color codes (only use if terminal supports them)
if [[ -t 2 ]] && command -v tput >/dev/null 2>&1; then
    RED="$(tput setaf 1)"
    GREEN="$(tput setaf 2)"
    YELLOW="$(tput setaf 3)"
    BLUE="$(tput setaf 4)"
    CYAN="$(tput setaf 6)"
    NC="$(tput sgr0)"
    readonly RED GREEN YELLOW BLUE CYAN NC
else
    readonly RED=""
    readonly GREEN=""
    readonly YELLOW=""
    readonly BLUE=""
    readonly CYAN=""
    readonly NC=""
fi

# Command existence cache
declare -gA COMMAND_CACHE=()

# Cache command existence check
command_exists() {
    local cmd="$1"
    if [[ -z "${COMMAND_CACHE[$cmd]+isset}" ]]; then
        if command -v "$cmd" &>/dev/null; then
            COMMAND_CACHE[$cmd]=1
        else
            COMMAND_CACHE[$cmd]=0
        fi
    fi
    [[ "${COMMAND_CACHE[$cmd]}" -eq 1 ]]
}

# Portable hash function
compute_hash() {
    if command_exists sha256sum; then
        sha256sum | cut -d' ' -f1
    elif command_exists shasum; then
        shasum -a 256 | cut -d' ' -f1
    elif command_exists openssl; then
        openssl dgst -sha256 | sed 's/^.* //'
    else
        # Fallback: use cksum for basic change detection
        cksum | cut -d' ' -f1
    fi
}

# Enhanced atomic cleanup with better marker creation
cleanup() {
    local exit_code=$?

    # Skip cleanup if requested or if we're stopping the service
    if [[ "${SKIP_CLEANUP}" == "true" ]] || [[ "${STOPPING_SERVICE}" == "true" ]]; then
        release_lock_unsafe
        release_config_lock_unsafe
        exit "${exit_code}"
    fi

    # Only perform cleanup on unexpected exit (non-zero exit code)
    # Skip marker creation for read-only commands to prevent race conditions
    if [[ $exit_code -ne 0 ]] && [[ "${COMMAND}" != "monitor" ]] && [[ "${COMMAND}" != "status" ]] && [[ "${COMMAND}" != "config" ]]; then
        # Use atomic marker creation
        local marker_tmp
        marker_tmp="$(mktemp "${CLEANUP_MARKER}.XXXXXX" 2>/dev/null)" \
            && mv -f "$marker_tmp" "${CLEANUP_MARKER}" 2>/dev/null \
            || touch "${CLEANUP_MARKER}" 2>/dev/null || true
    fi

    # Always release locks on exit
    release_lock_unsafe
    release_config_lock_unsafe

    exit "${exit_code}"
}

# Set trap for cleanup only in main script
if [[ "${BASH_SOURCE[0]}" == "${0}" ]] && [[ $$ -eq $BASHPID ]]; then
    # Comprehensive signal handling for production reliability
    trap cleanup EXIT INT TERM QUIT

    # Ignore SIGPIPE to prevent crashes on broken pipe (common in API calls)
    trap '' PIPE

    # Enhanced signal handlers
    # Only set custom handlers when NOT running under systemd
    if [[ -z "${INVOCATION_ID:-}" ]]; then
        # Not running under systemd - safe to use custom handlers
        # SIGHUP: Reload configuration without full restart
        trap 'log INFO "Received SIGHUP, reloading configuration"; restart_mediamtx' HUP
        # SIGUSR1: Dump status for debugging
        trap 'log INFO "Received SIGUSR1, dumping status"; show_status >/dev/null 2>&1 || log INFO "Status dump completed"' USR1
    fi
    # Note: When running under systemd (INVOCATION_ID is set), default signal handlers are used
fi

# Critical section protection - prevents signal handlers from interrupting
# atomic operations like lock acquisition and PID file writes
CRITICAL_SECTION_ACTIVE=false

# Enter critical section - block HUP and USR1 signals to prevent corruption
# Call this before lock acquisition, PID file writes, or config file operations
enter_critical_section() {
    if [[ "$CRITICAL_SECTION_ACTIVE" == "true" ]]; then
        return 0 # Already in critical section
    fi
    CRITICAL_SECTION_ACTIVE=true
    # Block signals that could interrupt critical operations
    trap '' HUP USR1
}

# Exit critical section - restore signal handlers
# Always call this after critical operations complete
exit_critical_section() {
    if [[ "$CRITICAL_SECTION_ACTIVE" != "true" ]]; then
        return 0 # Not in critical section
    fi
    CRITICAL_SECTION_ACTIVE=false
    # Restore signal handlers (only when not running under systemd)
    if [[ -z "${INVOCATION_ID:-}" ]]; then
        trap 'log INFO "Received SIGHUP, reloading configuration"; restart_mediamtx' HUP
        trap 'log INFO "Received SIGUSR1, dumping status"; show_status >/dev/null 2>&1 || log INFO "Status dump completed"' USR1
    fi
}

# Enhanced deferred cleanup handler with staleness check
handle_deferred_cleanup() {
    if [[ -f "${CLEANUP_MARKER}" ]]; then
        log INFO "Handling deferred cleanup from previous termination"

        # Check if marker is stale (>300 seconds old)
        local marker_age
        marker_age="$(($(date +%s) - $(stat -c %Y "${CLEANUP_MARKER}" 2>/dev/null || echo 0)))"

        if [[ $marker_age -gt 300 ]]; then
            log WARN "Cleanup marker is ${marker_age}s old, might be stale"
        fi

        # The marker says an earlier run did not finish; it is no proof that
        # anything is stale. A MediaMTX that is running and provably this
        # manager's is kept (start then starts whatever stream is missing);
        # anything else is cleaned up by identity.
        if owned_mediamtx_pid >/dev/null; then
            log INFO "MediaMTX is running and owned by this manager; keeping it"
        else
            cleanup_stale_processes

            # Verify cleanup completeness
            verify_cleanup_complete
        fi

        rm -f "${CLEANUP_MARKER}"
    fi
}

# Verify cleanup completeness
verify_cleanup_complete() {
    local issues_found=0

    # Check for orphaned wrapper and FFmpeg processes: what is left of this
    # installation's, by what it runs and writes (not by name)
    local wrapper_count=0 ffmpeg_count=0 kind=""
    while read -r _ _ kind _; do
        case "$kind" in
            wrapper) ((wrapper_count++)) || true ;;
            ffmpeg) ((ffmpeg_count++)) || true ;;
            *) ;;
        esac
    done < <(scan_instance_processes)
    if [[ $wrapper_count -gt 0 ]]; then
        log WARN "Found $wrapper_count orphaned wrapper processes"
        ((issues_found++)) || true
    fi
    if [[ $ffmpeg_count -gt 0 ]]; then
        log WARN "Found $ffmpeg_count orphaned FFmpeg processes"
        ((issues_found++)) || true
    fi

    # Check for stale PID files
    local stale_pids=0
    local nullglob_state
    shopt -q nullglob && nullglob_state=on || nullglob_state=off
    shopt -s nullglob
    for pid_file in "${FFMPEG_PID_DIR}"/*.pid; do
        if [[ -f "$pid_file" ]]; then
            local pid
            pid="$(cat "$pid_file" 2>/dev/null || true)"
            if [[ -n "$pid" ]] && ! kill -0 "$pid" 2>/dev/null; then
                ((stale_pids++)) || true
                rm -f "$pid_file"
            fi
        fi
    done
    # Restore nullglob only if it was originally off (avoids redundant shopt -s)
    [[ "$nullglob_state" == "off" ]] && shopt -u nullglob

    if [[ $stale_pids -gt 0 ]]; then
        log WARN "Cleaned $stale_pids stale PID files"
        ((issues_found++)) || true
    fi

    if [[ $issues_found -eq 0 ]]; then
        log DEBUG "Cleanup verification passed - no issues found"
        return 0
    else
        log WARN "Cleanup verification found $issues_found issues"
        return 1
    fi
}

# Release config lock safely. No "2>/dev/null" on the exec: an exec with only
# redirections applies them to the shell itself, which would silence stderr for
# the rest of the process.
release_config_lock_unsafe() {
    if [[ "${CONFIG_LOCK_FD}" -gt 2 ]]; then
        exec {CONFIG_LOCK_FD}>&- || true
    fi
    CONFIG_LOCK_FD=-1
}

# Enhanced logging without in-script rotation
log() {
    local level="$1"
    shift
    local message="$*"
    local timestamp
    timestamp="$(date '+%Y-%m-%d %H:%M:%S')"

    # Create log directory if it doesn't exist
    local log_dir
    log_dir="$(dirname "${LOG_FILE}")"
    if [[ ! -d "$log_dir" ]]; then
        mkdir -p "$log_dir" 2>/dev/null || true
    fi

    # Handle writing atomically without rotation
    (
        local lock_fd=-1
        local lock_file="${LOG_FILE}.lock"

        # Try to acquire lock with proper FD management (">>": like every lock
        # in this script, never truncate the lock file)
        {
            exec {lock_fd}>>"${lock_file}" 2>/dev/null
        } || {
            # Can't create lock, output to stderr only
            case "${level}" in
                ERROR) echo -e "${RED}[ERROR]${NC} ${message}" >&2 ;;
                WARN) echo -e "${YELLOW}[WARN]${NC} ${message}" >&2 ;;
                INFO) echo -e "${GREEN}[INFO]${NC} ${message}" >&2 ;;
                DEBUG) [[ "${DEBUG:-false}" == "true" ]] && echo -e "${BLUE}[DEBUG]${NC} ${message}" >&2 ;;
            esac
            return
        }

        # Validate FD
        if [[ ${lock_fd} -le 2 ]]; then
            case "${level}" in
                ERROR) echo -e "${RED}[ERROR]${NC} ${message}" >&2 ;;
                WARN) echo -e "${YELLOW}[WARN]${NC} ${message}" >&2 ;;
                INFO) echo -e "${GREEN}[INFO]${NC} ${message}" >&2 ;;
                DEBUG) [[ "${DEBUG:-false}" == "true" ]] && echo -e "${BLUE}[DEBUG]${NC} ${message}" >&2 ;;
            esac
            exec {lock_fd}>&- 2>/dev/null || true
            return
        fi

        if ! flock -x -w 5 ${lock_fd}; then
            # Can't get lock, just write to stderr
            case "${level}" in
                ERROR) echo -e "${RED}[ERROR]${NC} ${message}" >&2 ;;
                WARN) echo -e "${YELLOW}[WARN]${NC} ${message}" >&2 ;;
                INFO) echo -e "${GREEN}[INFO]${NC} ${message}" >&2 ;;
                DEBUG) [[ "${DEBUG:-false}" == "true" ]] && echo -e "${BLUE}[DEBUG]${NC} ${message}" >&2 ;;
            esac
            exec {lock_fd}>&- 2>/dev/null || true
            return
        fi

        # Simply append (creates file if needed)
        echo "[${timestamp}] [${level}] ${message}" >>"${LOG_FILE}" 2>/dev/null || true

        # Ensure FD is closed
        exec {lock_fd}>&- 2>/dev/null || true
    )

    # Also output to stderr with colors
    case "${level}" in
        ERROR)
            echo -e "${RED}[ERROR]${NC} ${message}" >&2
            ;;
        WARN)
            echo -e "${YELLOW}[WARN]${NC} ${message}" >&2
            ;;
        INFO)
            echo -e "${GREEN}[INFO]${NC} ${message}" >&2
            ;;
        DEBUG)
            if [[ "${DEBUG:-false}" == "true" ]]; then
                echo -e "${BLUE}[DEBUG]${NC} ${message}" >&2
            fi
            ;;
    esac
}

# Error handling with proper exit codes
error_exit() {
    local message="$1"
    local exit_code="${2:-${E_GENERAL}}"
    log ERROR "$message"
    exit "${exit_code}"
}

# ============================================================================
# Process ownership (D11)
# ============================================================================
# This script signals a process only when it can prove that it started it:
#
#   - the PID is recorded in one of the script's own PID files, and the start
#     time recorded next to it ("<pid file>.id", written by write_pid_atomic)
#     is still the one /proc/<pid>/stat reports, so a recycled PID is never
#     mistaken for the recorded process;
#   - the running image is what this script launches: MediaMTX is the
#     configured binary with the configuration file as argv[1]; a stream
#     wrapper is a shell whose argv[1] is that stream's generated script.
#
# No process is ever chosen by a name or command-line pattern (pkill, pgrep -f,
# pgrep -x): such a pattern also matches another installation's processes and
# the operator's own tools (an FFmpeg that reads a stream, an editor open on a
# wrapper). The one broad kill is `force-stop --kill-all --yes`, which prints
# exactly what it would signal first.
#
# The identity predicates return 0 = yes, 1 = no (or no such process) and
# 2 = cannot be told, because /proc/<pid> is not readable (another user's
# process seen by a run without root). "Cannot be told" is never "dead": the
# record is kept and nothing is signalled.

# Set REPLY to the fields of /proc/<pid>/stat after the command name's closing
# parenthesis ("<state> <ppid> <pgrp> <session> ... <starttime> ..."). The name
# may contain spaces and parentheses, so the fields are counted from the last
# ")". Returns 1 when the file is absent or unreadable.
_proc_stat_rest() {
    local pid="$1" stat=""
    [[ "$pid" =~ ^[0-9]+$ ]] || return 1
    { IFS= read -r -d '' stat <"/proc/${pid}/stat"; } 2>/dev/null || [[ -n "$stat" ]] || return 1
    [[ "$stat" == *") "* ]] || return 1
    REPLY="${stat##*) }"
}

# Print one field of /proc/<pid>/stat: 0 = state, 1 = ppid, 2 = process group
_proc_stat_field() {
    local REPLY
    local -a fields
    _proc_stat_rest "$1" || return 1
    read -ra fields <<<"$REPLY"
    printf '%s' "${fields[$2]:-}"
}

proc_pgrp() {
    _proc_stat_field "$1" 2
}

# Succeeds while process $1 is alive (not a zombie, which has exited and only
# waits to be reaped) and is the process that started at time $2
_proc_is_same_live() {
    local REPLY
    local -a fields
    _proc_stat_rest "$1" || return 1
    read -ra fields <<<"$REPLY"
    [[ "${fields[0]}" != "Z" && "${fields[0]}" != "X" && "${fields[19]:-}" == "$2" ]]
}

# Print the resolved path of a process's executable. The image of a binary that
# an upgrade has since replaced is reported as "<path> (deleted)"; it is still
# the same program, so the suffix is dropped.
proc_exe() {
    local exe="" deleted_suffix=" (deleted)"
    exe="$(readlink "/proc/${1}/exe" 2>/dev/null)" || return 1
    [[ -n "$exe" ]] || return 1
    printf '%s' "${exe%"${deleted_suffix}"}"
}

# Fill the array PROC_ARGV with the arguments of process $1
# (/proc/<pid>/cmdline is NUL-separated). Returns 1 when it cannot be read.
proc_load_argv() {
    local arg=""
    PROC_ARGV=()
    {
        while IFS= read -r -d '' arg || [[ -n "$arg" ]]; do
            PROC_ARGV+=("$arg")
            arg=""
        done
    } 2>/dev/null <"/proc/${1}/cmdline" || return 1
}

# Print a path with symlinks resolved, or the path itself if that fails
_canon_path() {
    local resolved=""
    if resolved="$(readlink -f -- "$1" 2>/dev/null)" && [[ -n "$resolved" ]]; then
        printf '%s' "$resolved"
    else
        printf '%s' "$1"
    fi
}

# Is $1 this installation's MediaMTX: the executable is the configured binary
# and argv[1] is the configuration file (that is how this script starts it)?
is_managed_mediamtx_pid() {
    local pid="$1" exe=""
    [[ "$pid" =~ ^[1-9][0-9]*$ ]] || return 1
    [[ -d "/proc/${pid}" ]] || return 1
    if ! proc_load_argv "$pid"; then
        [[ -d "/proc/${pid}" ]] && return 2
        return 1
    fi
    # argv[1] first: it is read without forking and rules out almost everything
    [[ "${PROC_ARGV[1]:-}" == "${CONFIG_FILE}" ]] || return 1
    if ! exe="$(proc_exe "$pid")"; then
        [[ -d "/proc/${pid}" ]] && return 2
        return 1
    fi
    [[ "$exe" == "$(_canon_path "${MEDIAMTX_BIN}")" ]]
}

# Is $1 a wrapper of this installation: a bash whose argv[1] is a generated
# stream script, "<wrapper dir>/<stream>.sh"? With a stream name, that stream's
# script; without one, any script directly in the wrapper directory.
is_managed_wrapper_pid() {
    local pid="$1" stream="${2:-}" script="" exe=""
    [[ "$pid" =~ ^[1-9][0-9]*$ ]] || return 1
    [[ -d "/proc/${pid}" ]] || return 1
    if ! proc_load_argv "$pid"; then
        [[ -d "/proc/${pid}" ]] && return 2
        return 1
    fi
    script="${PROC_ARGV[1]:-}"
    if [[ -n "$stream" ]]; then
        [[ "$script" == "${FFMPEG_PID_DIR}/${stream}.sh" ]] || return 1
    else
        [[ "$script" == "${FFMPEG_PID_DIR}/"*.sh ]] || return 1
        [[ "${script#"${FFMPEG_PID_DIR}/"}" != */* ]] || return 1
    fi
    if ! exe="$(proc_exe "$pid")"; then
        [[ -d "/proc/${pid}" ]] && return 2
        return 1
    fi
    [[ "${exe##*/}" == "bash" ]]
}

# Succeeds when PID $1 is provably not the wrapper of stream $2 (a recycled
# PID, or another program that happens to have the script open). A process
# that cannot be identified is not "foreign": it is left alone.
pid_is_foreign_wrapper() {
    local rc=0
    is_managed_wrapper_pid "$1" "$2" || rc=$?
    [[ $rc -eq 1 ]]
}

# Print the start time recorded next to PID file $1 for process $2. Prints
# nothing when there is no record, or the record is about another PID.
pid_file_recorded_start() {
    local rec_pid="" rec_start=""
    { IFS=' ' read -r rec_pid rec_start _ <"${1}.id"; } 2>/dev/null || true
    if [[ "$rec_pid" == "$2" && "$rec_start" =~ ^[0-9]+$ ]]; then
        printf '%s' "$rec_start"
    fi
}

# Remove PID file $1 and the start time recorded next to it
pid_file_remove() {
    rm -f -- "$1" "${1}.id"
}

# Print "<pid> <starttime>" for every descendant of process $1 (children,
# grandchildren, ...), one per line, found with a single scan of /proc. A
# wrapper's FFmpeg runs in a session of its own, so a process-group signal does
# not reach it; it is found through the parent links instead.
proc_descendants() {
    local root="$1" entry pid item head=0
    local REPLY
    local -a fields queue
    local -A kids=()
    for entry in /proc/[0-9]*/stat; do
        pid="${entry#/proc/}"
        pid="${pid%%/*}"
        _proc_stat_rest "$pid" || continue
        read -ra fields <<<"$REPLY"
        [[ "${fields[0]}" != "Z" && "${fields[0]}" != "X" ]] || continue
        kids[${fields[1]}]+="${pid}:${fields[19]:-0} "
    done
    queue=("$root")
    while ((head < ${#queue[@]})); do
        pid="${queue[head]}"
        ((head++)) || true
        for item in ${kids[$pid]:-}; do
            printf '%s %s\n' "${item%%:*}" "${item#*:}"
            queue+=("${item%%:*}")
        done
    done
}

# Send signal $1 to process $2 while it is still the process that started at
# time $3 (a PID that has been reused has another start time). There is a
# window of microseconds between the check and the signal that bash, which has
# no pidfd, cannot close.
_signal_if_same() {
    _proc_is_same_live "$2" "$3" || return 1
    kill "-${1}" "$2" 2>/dev/null
}

# Send signal $1 to process $2 (start time $3), to its process group when $4 is
# "true", and to every "pid:starttime" that follows
_signal_tree() {
    local sig="$1" pid="$2" start="$3" group="$4" victim
    shift 4
    if [[ "$group" == "true" ]] && _proc_is_same_live "$pid" "$start"; then
        kill "-${sig}" -- "-${pid}" 2>/dev/null || true
    fi
    _signal_if_same "$sig" "$pid" "$start" || true
    for victim in "$@"; do
        _signal_if_same "$sig" "${victim%%:*}" "${victim#*:}" || true
    done
}

# Succeeds while process $1 (start time $2) or any "pid:starttime" that
# follows is still running
_tree_alive() {
    local pid="$1" start="$2" victim
    shift 2
    _proc_is_same_live "$pid" "$start" && return 0
    for victim in "$@"; do
        _proc_is_same_live "${victim%%:*}" "${victim#*:}" && return 0
    done
    return 1
}

# Terminate a process and everything below it: SIGTERM to its process group (if
# it leads one) and to every descendant, then, after the timeout, SIGKILL. A
# timeout of 0 sends SIGKILL at once.
#
# SIGTERM, not SIGINT, as the first signal. A process started as a background
# job by a non-interactive shell that has no SIGINT trap inherits "ignore
# SIGINT" (bash setup_async_signals; reproduced: SigIgn 7). The script run
# directly sets a trap, so its wrappers keep SIGINT (SigIgn 5, measured), but
# when these functions are used from a sourced script (the tests, any wrapper
# started that way) a wrapper could be stopped only by the SIGKILL after the
# whole timeout, having restarted the FFmpeg it had just interrupted, which the
# SIGKILL then orphaned. The wrapper traps SIGTERM and stops its FFmpeg itself;
# MediaMTX and FFmpeg treat SIGTERM like SIGINT, so nothing is lost.
#
# The descendants are listed before anything is signalled and each is signalled
# only while its start time still matches, so nothing that appears or reuses a
# PID in between is touched.
#
# Parameters:
#   $1 = PID
#   $2 = timeout in seconds before SIGKILL (default 10)
#   $3 = start time the PID must have (optional). With it, a PID that has been
#        reused since the start time was recorded is left alone.
#
# Returns: 0 = nothing of it is left (or it was not the recorded process),
#          1 = something survived SIGKILL
terminate_process_group() {
    local pid="$1" timeout="${2:-10}" expect_start="${3:-}"
    local root_start="" line group=false sig="TERM" waited=0
    local -a victims=()

    [[ -n "$pid" ]] || return 0
    root_start="$(proc_starttime "$pid")" || return 0
    if [[ -n "$expect_start" && "$expect_start" != "$root_start" ]]; then
        log WARN "PID $pid is not the process that was started (start time $root_start, recorded $expect_start); not signalling it"
        return 0
    fi
    _proc_is_same_live "$pid" "$root_start" || return 0

    while read -r line; do
        [[ -n "$line" ]] && victims+=("${line% *}:${line#* }")
    done < <(proc_descendants "$pid")

    # A process group is signalled only when the process leads one: otherwise
    # "-PID" would name a group that is not its own
    if [[ "$(proc_pgrp "$pid")" == "$pid" ]]; then
        group=true
    fi

    ((timeout > 0)) || sig="KILL"
    log DEBUG "Sending SIG${sig} to PID $pid and ${#victims[@]} descendants"
    _signal_tree "$sig" "$pid" "$root_start" "$group" ${victims[@]+"${victims[@]}"}

    if [[ "$sig" == "TERM" ]]; then
        while ((waited < timeout * 10)) && _tree_alive "$pid" "$root_start" ${victims[@]+"${victims[@]}"}; do
            sleep "$QUICK_SLEEP"
            ((waited++)) || true
        done
        if _tree_alive "$pid" "$root_start" ${victims[@]+"${victims[@]}"}; then
            log WARN "PID $pid did not terminate within ${timeout}s; sending SIGKILL"
            _signal_tree KILL "$pid" "$root_start" "$group" ${victims[@]+"${victims[@]}"}
        fi
    fi

    waited=0
    while ((waited < 20)) && _tree_alive "$pid" "$root_start" ${victims[@]+"${victims[@]}"}; do
        sleep "$QUICK_SLEEP"
        ((waited++)) || true
    done
    if _tree_alive "$pid" "$root_start" ${victims[@]+"${victims[@]}"}; then
        log WARN "PID $pid (or one of its children) is still running after SIGKILL"
        return 1
    fi
    log DEBUG "PID $pid terminated successfully"
    return 0
}

# Stop the process recorded in PID file $1 and drop the record, but only while
# that process is provably the one this script started.
#
# Parameters:
#   $1 = PID file
#   $2 = kind of process: "mediamtx" or "wrapper"
#   $3 = timeout in seconds before SIGKILL (0 = SIGKILL at once)
#   $4 = stream name (wrapper only)
#
# Returns: 0 = nothing of it is left, or the recorded process was not ours (the
#              stale record is dropped, the other process is not touched)
#          1 = the process would not die (the record is kept)
#          2 = the process cannot be identified (unreadable /proc entry): not
#              signalled, record kept
stop_recorded_process() {
    local pid_file="$1" kind="$2" timeout="$3" stream="${4:-}"
    local pid="" start="" rc=0 cmdline=""

    pid="$(read_pid_safe "$pid_file")"
    if [[ -z "$pid" ]]; then
        pid_file_remove "$pid_file"
        return 0
    fi

    case "$kind" in
        mediamtx) is_managed_mediamtx_pid "$pid" || rc=$? ;;
        *) is_managed_wrapper_pid "$pid" "$stream" || rc=$? ;;
    esac
    if [[ $rc -eq 2 ]]; then
        log WARN "Cannot identify PID $pid recorded in $pid_file (is /proc readable? run as root); not signalling it"
        return 2
    fi
    if [[ $rc -ne 0 ]]; then
        cmdline="$(tr '\0' ' ' 2>/dev/null <"/proc/${pid}/cmdline")" || cmdline=""
        log WARN "PID $pid recorded in $pid_file is not the ${kind} this script started (it runs: ${cmdline:0:120}); not signalling it, dropping the stale record"
        pid_file_remove "$pid_file"
        return 0
    fi

    start="$(pid_file_recorded_start "$pid_file" "$pid")"
    if [[ -z "$start" ]]; then
        # A record from before start times were kept: the image check above is
        # all there is to go by
        start="$(proc_starttime "$pid")" || start=""
    fi
    if ! terminate_process_group "$pid" "$timeout" "$start"; then
        log ERROR "PID $pid ($kind) would not terminate"
        return 1
    fi
    pid_file_remove "$pid_file"
    return 0
}

# The PID of the MediaMTX recorded in PID_FILE, if (and only if) it is running
# and provably the one this script started. Prints it; fails otherwise.
owned_mediamtx_pid() {
    local pid="" rc=0
    pid="$(read_pid_safe "${PID_FILE}")"
    [[ -n "$pid" ]] || return 1
    is_managed_mediamtx_pid "$pid" || rc=$?
    [[ $rc -eq 0 ]] || return 1
    printf '%s' "$pid"
}

# Print the systemd service a process runs in (from its cgroup), if any
proc_systemd_unit() {
    local line="" unit=""
    while IFS= read -r line; do
        if [[ "$line" =~ /([^/]+\.service)(/|$) ]]; then
            unit="${BASH_REMATCH[1]}"
        fi
    done 2>/dev/null <"/proc/${1}/cgroup" || true
    printf '%s' "$unit"
}

# Succeeds, printing why, when a MediaMTX that this script did not start owns
# (or is about to clash with) the one it is about to start: the standalone
# mediamtx.service (D1), or any process that runs the configured binary on the
# configured configuration file without being the process recorded in
# PID_FILE. The caller refuses to start (E_OWNERSHIP) and touches nothing.
foreign_mediamtx_owner() {
    local owned="" dir pid unit=""
    owned="$(owned_mediamtx_pid)" || owned=""

    if command -v systemctl >/dev/null 2>&1 && systemctl is-active --quiet mediamtx.service 2>/dev/null; then
        printf 'mediamtx.service is active and owns MediaMTX (stop it first, for example: systemctl stop mediamtx.service)'
        return 0
    fi

    for dir in /proc/[0-9]*; do
        pid="${dir#/proc/}"
        [[ "$pid" == "$owned" ]] && continue
        is_managed_mediamtx_pid "$pid" || continue
        unit="$(proc_systemd_unit "$pid")"
        if [[ -n "$unit" ]] && command -v systemctl >/dev/null 2>&1 && systemctl is-active --quiet "$unit" 2>/dev/null; then
            printf 'unit %s is active and runs MediaMTX (PID %s) on %s' "$unit" "$pid" "${CONFIG_FILE}"
        else
            printf 'MediaMTX (PID %s) is already running on %s but was not started by this script' "$pid" "${CONFIG_FILE}"
        fi
        return 0
    done
    return 1
}

# Number of running stream wrappers of this installation
count_wrapper_processes() {
    local dir rc count=0
    for dir in /proc/[0-9]*; do
        rc=0
        is_managed_wrapper_pid "${dir#/proc/}" || rc=$?
        if ((rc == 0)); then
            ((count++)) || true
        fi
    done
    printf '%s' "$count"
}

# Print the PID of every process below this installation's recorded wrappers
# (their FFmpeg), one per line
wrapper_descendant_pids() {
    local pid_file pid line
    for pid_file in "${FFMPEG_PID_DIR}"/*.pid; do
        [[ -f "$pid_file" ]] || continue
        pid="$(read_pid_safe "$pid_file")"
        [[ -n "$pid" ]] || continue
        if pid_is_foreign_wrapper "$pid" "$(basename "$pid_file" .pid)"; then
            continue
        fi
        while read -r line; do
            [[ -z "$line" ]] || printf '%s\n' "${line% *}"
        done < <(proc_descendants "$pid")
    done
}

# Succeeds when a child of process $1 was started as ffmpeg
wrapper_has_ffmpeg_child() {
    local dir pid
    local REPLY
    local -a fields
    for dir in /proc/[0-9]*; do
        pid="${dir#/proc/}"
        _proc_stat_rest "$pid" || continue
        read -ra fields <<<"$REPLY"
        [[ "${fields[1]}" == "$1" ]] || continue
        proc_load_argv "$pid" || continue
        if [[ "${PROC_ARGV[0]##*/}" == "ffmpeg" ]]; then
            return 0
        fi
    done
    return 1
}

# PID file operations with permissions set before atomic move
write_pid_atomic() {
    local pid="$1"
    local pid_file="$2"
    local pid_dir
    pid_dir="$(dirname "$pid_file")"

    # Validate PID format
    if ! [[ "$pid" =~ ^[0-9]+$ ]]; then
        log ERROR "Invalid PID format: $pid"
        return 1
    fi

    # Remove leading zeros to prevent octal interpretation
    pid="$((10#$pid))"

    # Validate PID range
    if [[ $pid -lt 1 ]] || [[ $pid -gt $SYSTEM_PID_MAX ]]; then
        log ERROR "PID out of range: $pid (max: $SYSTEM_PID_MAX)"
        return 1
    fi

    # Verify process exists before writing
    if ! kill -0 "$pid" 2>/dev/null; then
        log ERROR "Process $pid does not exist"
        return 1
    fi

    # Ensure directory exists
    if [[ ! -d "$pid_dir" ]]; then
        mkdir -p "$pid_dir" 2>/dev/null || {
            log ERROR "Failed to create PID directory: $pid_dir"
            return 1
        }
    fi

    # Create temp file for atomic write
    local temp_pid
    temp_pid="$(mktemp -p "$pid_dir" "$(basename "$pid_file").XXXXXX" 2>/dev/null)" || {
        log ERROR "Failed to create temp PID file in $pid_dir"
        return 1
    }

    # Write PID with verification
    echo "${pid}" >"$temp_pid" || {
        rm -f "$temp_pid"
        log ERROR "Failed to write PID to temp file"
        return 1
    }

    # Set permissions BEFORE atomic move
    chmod 644 "$temp_pid" 2>/dev/null || {
        rm -f "$temp_pid"
        log ERROR "Failed to set permissions on temp PID file"
        return 1
    }

    # Verify written content
    local written_pid
    written_pid="$(cat "$temp_pid" 2>/dev/null)" || {
        rm -f "$temp_pid"
        log ERROR "Failed to verify written PID"
        return 1
    }

    if [[ "$written_pid" != "$pid" ]]; then
        rm -f "$temp_pid"
        log ERROR "PID verification failed: wrote $pid, read $written_pid"
        return 1
    fi

    # Double-check process still exists before final move
    if ! kill -0 "$pid" 2>/dev/null; then
        rm -f "$temp_pid"
        log ERROR "Process $pid died during PID file creation"
        return 1
    fi

    # Record the process's start time next to the PID file ("<pid> <starttime>"
    # in "<pid file>.id"). The PID file stays a plain PID, which systemd's
    # PIDFile= and other readers parse; the start time is what tells this
    # process from a later one that reuses the number. It is moved into place
    # first, so a PID file never exists without its record.
    local start_time=""
    if ! start_time="$(proc_starttime "$pid")"; then
        rm -f "$temp_pid"
        log ERROR "Cannot read the start time of PID $pid"
        return 1
    fi
    if ! { printf '%s %s\n' "$pid" "$start_time" >"${temp_pid}.id" \
        && chmod 644 "${temp_pid}.id" \
        && mv -f "${temp_pid}.id" "${pid_file}.id"; }; then
        rm -f "$temp_pid" "${temp_pid}.id"
        log ERROR "Failed to record the start time of PID $pid"
        return 1
    fi

    # Atomically move into place (permissions already set)
    if ! mv -f "$temp_pid" "$pid_file"; then
        rm -f "$temp_pid" "${pid_file}.id"
        log ERROR "Failed to atomically move PID file"
        return 1
    fi

    log DEBUG "Wrote PID $pid to $pid_file"
    return 0
}

# Read and validate PID from file
#
# Performs comprehensive validation:
# 1. Checks if file exists
# 2. Reads content (ignoring errors)
# 3. Strips all whitespace
# 4. Validates format: digits only via regex
# 5. Removes leading zeros: 10#$pid (prevents octal interpretation)
# 6. Validates range: 1 to SYSTEM_PID_MAX
# 7. Verifies the process exists (a zombie has exited, so it does not count)
# 8. Compares the process's start time with the one recorded next to the PID
#    file, which tells a recycled PID from the recorded process. It does NOT
#    judge by the program's name: a live process of another binary that is the
#    recorded one keeps its PID file (the old comm allowlist deleted it).
#
# This says "the recorded process is running", nothing more. Before anything is
# signalled, the callers prove that it is also the right program
# (is_managed_mediamtx_pid, is_managed_wrapper_pid; see "Process ownership").
#
# Parameters:
#   $1 = Path to PID file
#
# Returns:
#   stdout: Validated PID (numeric string) or empty string
#   exit: Always 0 (errors return empty string, not error code)
#
# Side Effects:
#   - Deletes the PID file (and its start-time record) if its content is invalid,
#     the process does not exist, or the PID has been reused
#   - A process whose /proc entry cannot be read (run without root) is
#     "unknown", not "dead": its PID file is kept
#   - Logs ERROR for invalid format or out-of-range PID
#   - Logs DEBUG if the process is not running or the PID was reused
read_pid_safe() {
    local pid_file="$1"

    if [[ ! -f "$pid_file" ]]; then
        echo ""
        return 0
    fi

    local pid
    pid="$(cat "$pid_file" 2>/dev/null || echo "")"

    if [[ -z "$pid" ]]; then
        echo ""
        return 0
    fi

    # Remove any whitespace
    pid="$(echo -n "$pid" | tr -d '[:space:]')"

    # Validate PID format
    if ! [[ "$pid" =~ ^[0-9]+$ ]]; then
        log ERROR "PID file $pid_file contains invalid data: '$pid'"
        pid_file_remove "$pid_file"
        echo ""
        return 0
    fi

    # Remove leading zeros to prevent octal interpretation
    pid="$((10#$pid))"

    # Validate PID range
    if [[ $pid -lt 1 ]] || [[ $pid -gt $SYSTEM_PID_MAX ]]; then
        log ERROR "PID file $pid_file contains out-of-range PID: $pid"
        pid_file_remove "$pid_file"
        echo ""
        return 0
    fi

    # Check if the process exists. /proc is asked, not kill -0: kill -0 also
    # fails (EPERM) for another user's live process, which is not "dead".
    if [[ ! -d "/proc/${pid}" ]]; then
        log DEBUG "PID $pid from $pid_file is not running"
        pid_file_remove "$pid_file"
        echo ""
        return 0
    fi

    local live_start="" recorded_start=""
    if live_start="$(proc_starttime "$pid")"; then
        if ! _proc_is_same_live "$pid" "$live_start"; then
            log DEBUG "PID $pid from $pid_file has exited (zombie)"
            pid_file_remove "$pid_file"
            echo ""
            return 0
        fi
        recorded_start="$(pid_file_recorded_start "$pid_file" "$pid")"
        if [[ -n "$recorded_start" && "$recorded_start" != "$live_start" ]]; then
            log DEBUG "PID $pid from $pid_file was reused (start time $live_start, recorded $recorded_start)"
            pid_file_remove "$pid_file"
            echo ""
            return 0
        fi
    fi
    # else: /proc/<pid>/stat cannot be read; the process exists, so it is
    # reported as running and left alone

    echo "$pid"
}

# ============================================================================
# Locking
# ============================================================================
# Every lock in this script is a plain flock(2) lock on a file that is never
# removed and never truncated:
#
#   - The file is opened read-write WITHOUT O_TRUNC ("<>"). A process that is
#     only waiting for the lock cannot disturb the owner's record, and the path
#     keeps one inode for the life of the node: a removed-and-recreated path is
#     a different lock, so two processes could both "hold" it.
#   - The kernel drops the flock when its holder dies, however it dies, so no
#     lock is ever "stale": there is no lock-age test and no process-name test
#     (a script run directly has the 15-character comm "lyrebird-stream", which
#     such a test would never match).
#   - After winning the lock the owner overwrites the first line of the file in
#     place with "<pid> <starttime>" (starttime = field 22 of /proc/<pid>/stat).
#     The record is informational: it is what a refused process shows the
#     operator. It is never used to decide whether the lock is held.
#   - A flock belongs to an open file description, which a child inherits. A
#     long-lived child that inherits the descriptor would keep the lock held
#     after this process exits, so every such child is started through
#     spawn_detached.

# Print the start time (clock ticks since boot, field 22 of /proc/<pid>/stat)
# of a process. PID plus start time identify one process for the life of the
# machine; a recycled PID has a different start time.
# Returns 1 when the process does not exist or the value cannot be read.
proc_starttime() {
    local pid="$1" stat="" rest
    local -a fields
    [[ "$pid" =~ ^[0-9]+$ ]] || return 1
    # Read the whole file: the command name (field 2) may contain spaces,
    # parentheses and even a newline, so the fields are counted from the last ")".
    { IFS= read -r -d '' stat <"/proc/${pid}/stat"; } 2>/dev/null || [[ -n "$stat" ]] || return 1
    [[ "$stat" == *") "* ]] || return 1
    rest="${stat##*) }"
    read -ra fields <<<"$rest"
    [[ "${fields[19]:-}" =~ ^[0-9]+$ ]] || return 1
    printf '%s\n' "${fields[19]}"
}

# Record this process as the owner of the lock held on descriptor $1: overwrite
# the first line in place (the descriptor is at offset 0 and the line has a
# fixed width, so the file never shrinks and is never empty while it is read).
lock_record_owner() {
    # BASHPID is this process; inside $(...) it would be the command
    # substitution's own subshell, so capture it first.
    local fd="$1" start self="${BASHPID}"
    start="$(proc_starttime "$self")" || start=0
    { printf '%-64s\n' "${self} ${start}" >&"${fd}"; } 2>/dev/null || true
}

# Print a one-line description of the lock owner recorded in lock file $1. The
# recorded PID is only believed when its start time still matches, so a PID
# that has been recycled by an unrelated process is never blamed.
lock_describe_holder() {
    local path="$1" rec_pid="" rec_start="" now_start="" cmdline=""
    { IFS=' ' read -r rec_pid rec_start _ <"$path"; } 2>/dev/null || true
    if ! [[ "$rec_pid" =~ ^[0-9]+$ ]] || ! [[ "$rec_start" =~ ^[0-9]+$ ]]; then
        printf 'no owner recorded'
        return 0
    fi
    now_start="$(proc_starttime "$rec_pid")" || now_start=""
    if [[ "$now_start" != "$rec_start" ]]; then
        printf 'last recorded owner PID %s (start time %s) is not running' "$rec_pid" "$rec_start"
        return 0
    fi
    cmdline="$(tr '\0' ' ' 2>/dev/null <"/proc/${rec_pid}/cmdline")" || cmdline=""
    printf 'PID %s (start time %s): %s' "$rec_pid" "$rec_start" "${cmdline:0:200}"
}

# Print "PID(comm)" for every other process that has lock file $1 open. After
# an upgrade from a release that let children inherit the lock descriptor this
# is how a lock held by an old MediaMTX or wrapper shows up.
lock_list_open_holders() {
    local path="$1" entry pid comm out=""
    [[ -e "$path" ]] || return 0
    for entry in /proc/[0-9]*/fd/*; do
        [[ "$entry" -ef "$path" ]] || continue
        pid="${entry#/proc/}"
        pid="${pid%%/*}"
        [[ "$pid" == "$$" || "$pid" == "${BASHPID}" ]] && continue
        [[ " $out " == *" ${pid}("* ]] && continue
        comm="$(tr -d '\n' 2>/dev/null <"/proc/${pid}/comm")" || comm="?"
        out+="${out:+ }${pid}(${comm})"
    done
    printf '%s' "$out"
}

# Open lock file $1 (created if absent; never truncated or removed), take an
# exclusive flock on it waiting at most $2 seconds and record this process as
# the owner. On success the descriptor number is left in LOCK_OPENED_FD.
# Returns: 0 = acquired, 1 = timed out, 2 = the lock file cannot be opened.
# Nothing is redirected persistently: stderr of this shell is left alone.
lock_open_and_acquire() {
    local path="$1" timeout="$2" fd=-1
    LOCK_OPENED_FD=-1
    if ! { exec {fd}<>"${path}"; } 2>/dev/null; then
        return 2
    fi
    if ! flock -w "${timeout}" "${fd}"; then
        exec {fd}>&- || true
        return 1
    fi
    lock_record_owner "${fd}"
    LOCK_OPENED_FD=${fd}
    return 0
}

# The LOCK_STALE_THRESHOLD setting no longer does anything: say so once.
lock_warn_deprecated_settings() {
    [[ -n "${LOCK_STALE_THRESHOLD:-}" ]] || return 0
    [[ "${LOCK_DEPRECATION_LOGGED}" == "true" ]] && return 0
    LOCK_DEPRECATION_LOGGED=true
    log WARN "LOCK_STALE_THRESHOLD is deprecated and ignored: locks are released by the kernel when the holder exits, so a lock is never considered stale"
}

# Acquire the exclusive lifecycle lock (LOCK_FILE) with timeout.
#
# Acquisition sequence:
# 1. If this process already holds the lock, keep it (restart runs stop and
#    start in one process; releasing in between would let another command in)
# 2. Creates lock directory if needed
# 3. Opens LOCK_FILE without truncating it and calls flock -w with the timeout
# 4. Records "<pid> <starttime>" as the owner
#
# The lock file is never removed or truncated and is never judged stale: a
# held flock is held, and a released one is free.
#
# Parameters:
#   $1 = Timeout in seconds (default: LOCK_ACQUISITION_TIMEOUT)
#   $2 = Force flag: "true" or "false" (default: "false")
#        If "true": returns 0 even if lock acquisition fails
#
# Returns:
#   0 = Lock acquired (or already held) OR force="true"
#   1 = Lock acquisition failed AND force="false"
#
# Side Effects:
#   - Sets global MAIN_LOCK_FD to file descriptor number (or -1 on failure)
#   - Creates LOCK_FILE if doesn't exist
#   - Overwrites the owner record in LOCK_FILE
#   - Logs DEBUG on success; ERROR/WARN, with the recorded owner, on failure
acquire_lock() {
    local timeout="${1:-${LOCK_ACQUISITION_TIMEOUT}}"
    local force="${2:-false}"

    lock_warn_deprecated_settings

    # Already held by this process? (the descriptor must still be open on the
    # file the path names now)
    if [[ ${MAIN_LOCK_FD} -gt 2 ]] && [[ "/proc/self/fd/${MAIN_LOCK_FD}" -ef "${LOCK_FILE}" ]]; then
        log DEBUG "Lock already held (PID: ${BASHPID}, FD: ${MAIN_LOCK_FD})"
        return 0
    fi

    # Enter critical section to prevent signal handlers from interrupting lock operations
    enter_critical_section

    # A descriptor left over from an earlier acquisition that no longer matches
    # the lock file is closed before taking a new one
    if [[ ${MAIN_LOCK_FD} -gt 2 ]]; then
        exec {MAIN_LOCK_FD}>&- || true
    fi
    MAIN_LOCK_FD=-1

    # Create lock directory if it doesn't exist
    local lock_dir
    lock_dir="$(dirname "${LOCK_FILE}")"
    if [[ ! -d "$lock_dir" ]]; then
        mkdir -p "$lock_dir" 2>/dev/null || {
            log ERROR "Cannot create lock directory: $lock_dir"
            exit_critical_section
            return 1
        }
    fi

    local rc=0
    lock_open_and_acquire "${LOCK_FILE}" "$timeout" || rc=$?

    # Lock is acquired or given up on: safe to allow signals again
    exit_critical_section

    if [[ $rc -eq 2 ]]; then
        log ERROR "Cannot create lock file ${LOCK_FILE}"
        return 1
    fi

    if [[ $rc -ne 0 ]]; then
        local holder
        holder="$(lock_describe_holder "${LOCK_FILE}")"
        local open_by
        open_by="$(lock_list_open_holders "${LOCK_FILE}")"
        if [[ "$force" == "true" ]]; then
            log WARN "Failed to acquire lock, forcing due to force flag"
            log WARN "Lock ${LOCK_FILE} is held; ${holder}"
            return 0 # Continue anyway
        fi
        log ERROR "Failed to acquire lock after ${timeout} seconds"
        log ERROR "Lock ${LOCK_FILE} is held; ${holder}"
        if [[ -n "$open_by" ]]; then
            log ERROR "Processes with the lock file open: ${open_by}"
        fi
        return 1
    fi

    MAIN_LOCK_FD=${LOCK_OPENED_FD}
    log DEBUG "Acquired lock (PID: ${BASHPID}, FD: ${MAIN_LOCK_FD})"
    return 0
}

release_lock() {
    if [[ "${MAIN_LOCK_FD}" -gt 2 ]]; then
        log DEBUG "Releasing lock (FD: ${MAIN_LOCK_FD})"
        exec {MAIN_LOCK_FD}>&- || true
    fi
    MAIN_LOCK_FD=-1
    # Never remove the lock file: its inode is the lock
}

# Unsafe lock release for cleanup trap
release_lock_unsafe() {
    if [[ "${MAIN_LOCK_FD}" -gt 2 ]]; then
        exec {MAIN_LOCK_FD}>&- || true
    fi
    MAIN_LOCK_FD=-1
}

# Acquire the configuration lock (CONFIG_LOCK_FILE) with the same primitive as
# the lifecycle lock. A descriptor still open from an earlier call is closed
# first, as before. Sets CONFIG_LOCK_FD.
# Parameters:
#   $1 = Timeout in seconds (default: 10)
# Returns: 0 = acquired, 1 = could not create or acquire the lock
acquire_config_lock() {
    local timeout="${1:-10}"
    local rc=0
    release_config_lock_unsafe
    lock_open_and_acquire "${CONFIG_LOCK_FILE}" "$timeout" || rc=$?
    if [[ $rc -eq 2 ]]; then
        log ERROR "Failed to create config lock file"
        return 1
    fi
    if [[ $rc -ne 0 ]]; then
        log ERROR "Failed to acquire config lock"
        log ERROR "Config lock ${CONFIG_LOCK_FILE} is held; $(lock_describe_holder "${CONFIG_LOCK_FILE}")"
        return 1
    fi
    CONFIG_LOCK_FD=${LOCK_OPENED_FD}
    return 0
}

# Run a long-lived child (MediaMTX, a per-stream wrapper) without any of this
# shell's file descriptors above stderr: a child that inherited a lock
# descriptor would keep the lock held after this process exited. The same goes
# for a lock descriptor inherited from a parent, e.g. the monitor lock that
# `flock FILE -c ...` leaves open in everything it starts.
#
# Use it as a background command; it replaces the forked subshell with the
# command, so $! is the PID of the command itself:
#   spawn_detached nohup setsid some-command args >>log 2>&1 &
# Called in the foreground it would replace this very process, so it refuses.
spawn_detached() {
    if [[ "${BASHPID}" == "$$" ]]; then
        log ERROR "spawn_detached must run as a background command"
        return 1
    fi
    local entry fd
    for entry in /proc/self/fd/*; do
        fd="${entry##*/}"
        [[ "$fd" =~ ^[0-9]+$ ]] || continue
        # 0-2 are the child's stdio; 255 is bash's own script descriptor, which
        # is close-on-exec
        if [[ $fd -gt 2 && $fd -ne 255 ]]; then
            exec {fd}>&- || true
        fi
    done
    exec "$@"
}

# Check if running as root
check_root() {
    if [[ ${EUID} -ne 0 ]]; then
        error_exit "This script must be run as root (use sudo)" "${E_GENERAL}"
    fi
}

# Check dependencies
check_dependencies() {
    local missing=()

    for cmd in ffmpeg jq arecord; do
        if ! command_exists "$cmd"; then
            missing+=("$cmd")
        fi
    done

    # Check for setsid (optional but recommended)
    if ! command_exists setsid; then
        log WARN "setsid not found - processes will run without session isolation"
    fi

    if [[ ! -x "${MEDIAMTX_BIN}" ]]; then
        missing+=("mediamtx (run install_mediamtx.sh first)")
    fi

    if [[ ${#missing[@]} -gt 0 ]]; then
        error_exit "Missing dependencies: ${missing[*]}" "${E_MISSING_DEPS}"
    fi
}

# Create required directories
setup_directories() {
    mkdir -p "${CONFIG_DIR}"
    mkdir -p "$(dirname "${LOG_FILE}")"
    mkdir -p "$(dirname "${PID_FILE}")"
    mkdir -p "${FFMPEG_PID_DIR}"

    # Set directory permissions: rwxr-xr-x (owner write, group/other read+execute)
    chmod 755 "${FFMPEG_PID_DIR}"

    if [[ ! -f "${LOG_FILE}" ]]; then
        touch "${LOG_FILE}"
        # Set log file permissions: rw-r--r-- (owner write, group/other read)
        chmod 644 "${LOG_FILE}"
    fi

    # v1.4.2: Setup audio recording buffer directories if local recording is enabled
    if [[ "${AUDIO_LOCAL_RECORDING}" == "true" ]]; then
        # Create recording directory (default is /dev/shm which is tmpfs/RAM)
        if [[ ! -d "${AUDIO_RECORDING_PATH}" ]]; then
            if mkdir -p "${AUDIO_RECORDING_PATH}" 2>/dev/null; then
                chmod 755 "${AUDIO_RECORDING_PATH}"
                log INFO "Created audio buffer directory: ${AUDIO_RECORDING_PATH}"
            else
                log WARN "Could not create audio buffer directory: ${AUDIO_RECORDING_PATH}"
            fi
        fi
    fi

    # Setup MediaMTX log rotation if logrotate is available
    if command_exists logrotate && [[ -d /etc/logrotate.d ]]; then
        setup_mediamtx_logrotate
    fi
}

# Setup MediaMTX log rotation
setup_mediamtx_logrotate() {
    # Skip if running under systemd with protected filesystem
    if [[ -n "${INVOCATION_ID:-}" ]] || [[ ! -w /etc/logrotate.d ]]; then
        log DEBUG "Skipping logrotate setup (read-only filesystem or systemd environment)"
        return 0
    fi

    cat >/etc/logrotate.d/mediamtx <<EOF
${MEDIAMTX_LOG_FILE} {
    daily
    rotate 7
    compress
    delaycompress
    missingok
    notifempty
    # copytruncate: MediaMTX's stdout here is an inherited shell redirect (>>),
    # so it cannot be told to reopen the file. Copy-then-truncate-in-place keeps
    # the same inode/fd, so MediaMTX keeps writing to the rotated file instead of
    # an unlinked one that grows invisibly until the disk fills. (The old
    # create + kill -USR1 could not work: the fd is owned by the shell redirect,
    # not by a MediaMTX-managed log file.)
    copytruncate
    size ${MEDIAMTX_LOG_MAX_SIZE}
}

${LOG_FILE} {
    daily
    rotate 7
    compress
    delaycompress
    missingok
    notifempty
    # copytruncate: the manager's log is held open (systemd append: / the
    # running process), so a plain create would leave it writing to the rotated
    # inode.
    copytruncate
    size ${MAIN_LOG_MAX_SIZE}
}

${FFMPEG_PID_DIR}/*.log {
    daily
    rotate 3
    compress
    delaycompress
    missingok
    notifempty
    # copytruncate: each FFmpeg holds its log open and does not reopen on rotate.
    copytruncate
    size ${FFMPEG_LOG_MAX_SIZE}
}
EOF

    chmod 644 /etc/logrotate.d/mediamtx
    log DEBUG "MediaMTX log rotation configured"
}

# Resource monitoring
check_resource_usage() {
    local mediamtx_pid
    mediamtx_pid="$(read_pid_safe "${PID_FILE}")"

    if [[ -z "$mediamtx_pid" ]]; then
        log DEBUG "MediaMTX not running, skipping resource check"
        return 0
    fi

    # Check file descriptors
    local fd_count=0
    if [[ -d "/proc/$mediamtx_pid/fd" ]]; then
        fd_count=$(find "/proc/$mediamtx_pid/fd" -maxdepth 1 -type l 2>/dev/null | wc -l)
    fi

    # Check CPU usage
    local cpu_percent="0"
    if command_exists ps; then
        cpu_percent=$(ps -o %cpu= -p "$mediamtx_pid" 2>/dev/null | tr -d ' ' || echo "0")
    fi

    # Extract integer part of CPU percentage
    local cpu_int="${cpu_percent%.*}"
    cpu_int="${cpu_int:-0}"

    # Check thread count
    local thread_count=0
    if command_exists ps; then
        thread_count=$(ps -o nlwp= -p "$mediamtx_pid" 2>/dev/null | tr -d ' ' || echo "0")
    fi

    # Log current resource usage
    log DEBUG "Resource usage - PID: $mediamtx_pid, FDs: $fd_count, CPU: ${cpu_percent}%, Threads: $thread_count"

    # Check thresholds
    local needs_restart=false
    local reason=""

    if [[ $fd_count -gt ${MAX_FD_CRITICAL} ]]; then
        log ERROR "Critical: File descriptors exceeded limit ($fd_count > ${MAX_FD_CRITICAL})"
        needs_restart=true
        reason="FD_LIMIT"
    elif [[ $fd_count -gt ${MAX_FD_WARNING} ]]; then
        log WARN "Warning: High file descriptor count ($fd_count > ${MAX_FD_WARNING})"
    fi

    if [[ $cpu_int -gt ${MAX_CPU_CRITICAL} ]]; then
        log ERROR "Critical: CPU usage exceeded limit (${cpu_percent}% > ${MAX_CPU_CRITICAL}%)"
        needs_restart=true
        reason="${reason:+$reason,}CPU_LIMIT"
    elif [[ $cpu_int -gt ${MAX_CPU_WARNING} ]]; then
        log WARN "Warning: High CPU usage (${cpu_percent}% > ${MAX_CPU_WARNING}%)"
    fi

    # Check wrapper processes
    local wrapper_count
    wrapper_count=$(count_wrapper_processes)
    local expected_wrappers
    expected_wrappers=$(find "${FFMPEG_PID_DIR}" -maxdepth 1 -name "*.pid" -type f 2>/dev/null | wc -l)

    # Check for excessive wrapper processes
    if [[ $wrapper_count -gt $expected_wrappers ]]; then
        log ERROR "Critical: Extra wrapper processes ($wrapper_count vs expected $expected_wrappers)"
        needs_restart=true
        reason="${reason:+$reason,}WRAPPER_LEAK"
    fi

    # Return exit code 2 if restart needed
    if [[ "$needs_restart" == "true" ]]; then
        log ERROR "CRITICAL: Resource limits exceeded: $reason"
        return ${E_CRITICAL_RESOURCE}
    fi

    return 0
}

# ============================================================================
# Production Reliability Functions (v1.4.2)
# ============================================================================

# Check disk space on critical partitions
# Returns: 0 = OK, 1 = warning, 2 = critical
check_disk_space() {
    local check_paths=("/" "/var" "/var/log" "${FFMPEG_PID_DIR}" "${CONFIG_DIR}")
    local critical_found=false
    local warning_found=false

    for check_path in "${check_paths[@]}"; do
        # Skip if path doesn't exist
        [[ -d "$check_path" ]] || continue

        # Get disk usage (portable method)
        local usage_info
        usage_info=$(df -P "$check_path" 2>/dev/null | tail -1) || continue

        local used_percent available_kb
        used_percent=$(echo "$usage_info" | awk '{print $5}' | tr -d '%')
        available_kb=$(echo "$usage_info" | awk '{print $4}')

        # Skip if we couldn't parse the values
        [[ "$used_percent" =~ ^[0-9]+$ ]] || continue
        [[ "$available_kb" =~ ^[0-9]+$ ]] || continue

        local available_mb=$((available_kb / 1024))

        # Check thresholds
        if [[ $used_percent -ge ${DISK_SPACE_CRITICAL_PERCENT} ]] || [[ $available_mb -lt ${DISK_SPACE_MIN_FREE_MB} ]]; then
            log ERROR "Critical: Disk space on $check_path: ${used_percent}% used, ${available_mb}MB free"
            critical_found=true
        elif [[ $used_percent -ge ${DISK_SPACE_WARNING_PERCENT} ]]; then
            log WARN "Warning: Disk space on $check_path: ${used_percent}% used, ${available_mb}MB free"
            warning_found=true
        fi
    done

    if [[ "$critical_found" == "true" ]]; then
        return 2
    elif [[ "$warning_found" == "true" ]]; then
        return 1
    fi
    return 0
}

# Check memory usage with trending for leak detection
# Stores samples over time to detect gradual growth
check_memory_usage() {
    local mediamtx_pid
    mediamtx_pid="$(read_pid_safe "${PID_FILE}")"

    if [[ -z "$mediamtx_pid" ]]; then
        log DEBUG "MediaMTX not running, skipping memory check"
        return 0
    fi

    # Get RSS memory in KB for MediaMTX
    local rss_kb=0
    if [[ -f "/proc/$mediamtx_pid/status" ]]; then
        rss_kb=$(grep "VmRSS:" "/proc/$mediamtx_pid/status" 2>/dev/null | awk '{print $2}' || echo 0)
    fi

    # Get total RSS for all FFmpeg processes
    local ffmpeg_rss=0
    while IFS= read -r pid; do
        if [[ -n "$pid" ]] && [[ -f "/proc/$pid/status" ]]; then
            local pid_rss
            pid_rss=$(grep "VmRSS:" "/proc/$pid/status" 2>/dev/null | awk '{print $2}' || echo 0)
            ffmpeg_rss=$((ffmpeg_rss + pid_rss))
        fi
    done < <(wrapper_descendant_pids)

    local total_rss_mb=$(((rss_kb + ffmpeg_rss) / 1024))

    # Store sample for trending
    local timestamp
    timestamp=$(date +%s)
    local sample_dir
    sample_dir=$(dirname "${MEM_SAMPLE_FILE}")

    if [[ -d "$sample_dir" ]] || mkdir -p "$sample_dir" 2>/dev/null; then
        echo "${timestamp}:${total_rss_mb}" >>"${MEM_SAMPLE_FILE}" 2>/dev/null || true

        # Keep only last 100 samples
        if [[ -f "${MEM_SAMPLE_FILE}" ]]; then
            tail -100 "${MEM_SAMPLE_FILE}" >"${MEM_SAMPLE_FILE}.tmp" 2>/dev/null \
                && mv "${MEM_SAMPLE_FILE}.tmp" "${MEM_SAMPLE_FILE}" 2>/dev/null || true
        fi

        # Check for memory growth trend (compare first and last sample)
        if [[ -f "${MEM_SAMPLE_FILE}" ]] && [[ $(wc -l <"${MEM_SAMPLE_FILE}") -ge 10 ]]; then
            local first_sample last_sample
            first_sample=$(head -1 "${MEM_SAMPLE_FILE}" | cut -d: -f2)
            last_sample=$(tail -1 "${MEM_SAMPLE_FILE}" | cut -d: -f2)

            if [[ "$first_sample" =~ ^[0-9]+$ ]] && [[ "$last_sample" =~ ^[0-9]+$ ]]; then
                local growth_mb=$((last_sample - first_sample))
                if [[ $growth_mb -gt ${MEM_GROWTH_THRESHOLD_MB} ]]; then
                    log WARN "Memory growth detected: ${growth_mb}MB increase (${first_sample}MB -> ${last_sample}MB)"
                    log WARN "Consider restarting to prevent potential memory leak"
                fi
            fi
        fi
    fi

    log DEBUG "Memory usage: MediaMTX ${rss_kb}KB, FFmpeg ${ffmpeg_rss}KB, Total ${total_rss_mb}MB"

    # Check system memory
    local mem_total mem_available mem_used_percent
    if [[ -f /proc/meminfo ]]; then
        mem_total=$(grep "MemTotal:" /proc/meminfo | awk '{print $2}')
        mem_available=$(grep "MemAvailable:" /proc/meminfo | awk '{print $2}')
        if [[ -n "$mem_total" ]] && [[ -n "$mem_available" ]] && [[ "$mem_total" -gt 0 ]]; then
            mem_used_percent=$(((mem_total - mem_available) * 100 / mem_total))

            if [[ $mem_used_percent -ge ${MEM_CRITICAL_PERCENT} ]]; then
                log ERROR "Critical: System memory usage at ${mem_used_percent}%"
                return 2
            elif [[ $mem_used_percent -ge ${MEM_WARNING_PERCENT} ]]; then
                log WARN "Warning: System memory usage at ${mem_used_percent}%"
                return 1
            fi
        fi
    fi

    return 0
}

# Check network connectivity
# Uses gateway ping by default, configurable target
check_network_connectivity() {
    if [[ "${NETWORK_CHECK_ENABLED}" != "true" ]]; then
        return 0
    fi

    local target="${NETWORK_CHECK_TARGET}"

    # Resolve "gateway" to actual gateway IP
    if [[ "$target" == "gateway" ]]; then
        # Try multiple methods to find gateway
        target=$(ip route | grep default | awk '{print $3}' | head -1 2>/dev/null) \
            || target=$(route -n | grep "^0.0.0.0" | awk '{print $2}' | head -1 2>/dev/null) \
            || target=$(netstat -rn | grep "^0.0.0.0" | awk '{print $2}' | head -1 2>/dev/null) \
            || target=""

        if [[ -z "$target" ]]; then
            log DEBUG "Could not determine gateway, skipping network check"
            return 0
        fi
    fi

    # Ping test
    if command_exists ping; then
        if ping -c 1 -W "${NETWORK_CHECK_TIMEOUT}" "$target" >/dev/null 2>&1; then
            log DEBUG "Network connectivity OK (gateway: $target)"
            # Reset failure counter
            echo "0" >/run/mediamtx-network-failures 2>/dev/null || true
            return 0
        else
            # Increment failure counter
            local failures=0
            [[ -f /run/mediamtx-network-failures ]] && failures=$(cat /run/mediamtx-network-failures 2>/dev/null || echo 0)
            failures=$((failures + 1))
            echo "$failures" >/run/mediamtx-network-failures 2>/dev/null || true

            if [[ $failures -ge ${NETWORK_FAIL_THRESHOLD} ]]; then
                log ERROR "Network connectivity lost: $failures consecutive failures to reach $target"
                return 1
            else
                log WARN "Network check failed ($failures/${NETWORK_FAIL_THRESHOLD}): cannot reach $target"
                return 0
            fi
        fi
    fi

    return 0
}

# Detect MediaMTX API version and return appropriate base URL
# Tries v3, v2, v1 in order if auto-detection is enabled
detect_mediamtx_api_version() {
    local host="${MEDIAMTX_HOST:-localhost}"
    local port="${MEDIAMTX_API_PORT:-9997}"
    local base_url="http://${host}:${port}"

    # If version is explicitly set, use it
    if [[ "${MEDIAMTX_API_VERSION}" != "auto" ]]; then
        echo "${base_url}/${MEDIAMTX_API_VERSION}"
        return 0
    fi

    # Auto-detect: try versions in order
    if command_exists curl; then
        for version in v3 v2 v1; do
            local test_url="${base_url}/${version}/paths/list"
            if curl -s --max-time 2 "$test_url" >/dev/null 2>&1; then
                log DEBUG "Detected MediaMTX API version: $version"
                echo "${base_url}/${version}"
                return 0
            fi
        done

        # Fallback: try without version prefix (very old MediaMTX)
        if [[ "${MEDIAMTX_API_FALLBACK}" == "true" ]]; then
            if curl -s --max-time 2 "${base_url}/paths/list" >/dev/null 2>&1; then
                log DEBUG "Using legacy MediaMTX API (no version prefix)"
                echo "${base_url}"
                return 0
            fi
        fi
    fi

    # Default to v3 if detection fails
    log WARN "Could not detect MediaMTX API version, defaulting to v3"
    echo "${base_url}/v3"
    return 0
}

# ============================================================================
# MediaMTX API Integration Functions (v1.4.3)
# Covers the MediaMTX /v3 REST API (validated against v1.15.5 - v1.19.x)
# ============================================================================

# Make a generic API call to MediaMTX
# Usage: mediamtx_api_call METHOD ENDPOINT [DATA]
# Returns: JSON response on stdout, exit code 0 on success
mediamtx_api_call() {
    local method="${1:-GET}"
    local endpoint="$2"
    local data="${3:-}"

    if ! command_exists curl; then
        log DEBUG "curl not available for API call"
        return 1
    fi

    local api_base
    api_base=$(detect_mediamtx_api_version)
    local url="${api_base}${endpoint}"

    local curl_args=(-s --max-time 10)

    case "$method" in
        GET)
            curl_args+=(-X GET)
            ;;
        POST)
            curl_args+=(-X POST)
            [[ -n "$data" ]] && curl_args+=(-H "Content-Type: application/json" -d "$data")
            ;;
        PATCH)
            curl_args+=(-X PATCH -H "Content-Type: application/json" -d "$data")
            ;;
        DELETE)
            curl_args+=(-X DELETE)
            ;;
        *)
            log ERROR "Unknown HTTP method: $method"
            return 1
            ;;
    esac

    local response
    local http_code

    # Use -w to get HTTP status code
    response=$(curl "${curl_args[@]}" -w "\n%{http_code}" "$url" 2>/dev/null)
    http_code=$(echo "$response" | tail -1)
    http_code="${http_code:-0}"
    response=$(echo "$response" | sed '$d')

    if [[ "$http_code" =~ ^[0-9]+$ ]] && [[ "$http_code" -ge 200 ]] && [[ "$http_code" -lt 300 ]]; then
        echo "$response"
        return 0
    else
        log DEBUG "API call failed: $method $url (HTTP $http_code)"
        return 1
    fi
}

# -----------------------------------------------------------------------------
# Instance Information (/v3/info)
# -----------------------------------------------------------------------------

# Get MediaMTX instance information (version, uptime)
# Returns: JSON with version and upTime fields
mediamtx_get_info() {
    mediamtx_api_call GET "/info"
}

# Get MediaMTX version string
mediamtx_get_version() {
    local info
    info=$(mediamtx_get_info) || return 1
    echo "$info" | grep -o '"version":"[^"]*"' | cut -d'"' -f4
}

# Get MediaMTX uptime in nanoseconds
mediamtx_get_uptime() {
    local info
    info=$(mediamtx_get_info) || return 1
    echo "$info" | grep -o '"upTime":[0-9]*' | cut -d':' -f2
}

# -----------------------------------------------------------------------------
# Global Configuration (/v3/config/global)
# -----------------------------------------------------------------------------

# Get global MediaMTX configuration
mediamtx_get_global_config() {
    mediamtx_api_call GET "/config/global/get"
}

# Patch global MediaMTX configuration
# Usage: mediamtx_patch_global_config '{"logLevel":"debug"}'
mediamtx_patch_global_config() {
    local config_json="$1"
    mediamtx_api_call PATCH "/config/global/patch" "$config_json"
}

# -----------------------------------------------------------------------------
# Path Defaults Configuration (/v3/config/pathdefaults)
# -----------------------------------------------------------------------------

# Get default path configuration
mediamtx_get_path_defaults() {
    mediamtx_api_call GET "/config/pathdefaults/get"
}

# Patch default path configuration
mediamtx_patch_path_defaults() {
    local config_json="$1"
    mediamtx_api_call PATCH "/config/pathdefaults/patch" "$config_json"
}

# -----------------------------------------------------------------------------
# Path Configuration CRUD (/v3/config/paths)
# -----------------------------------------------------------------------------

# List all path configurations (with pagination)
# Usage: mediamtx_list_path_configs [itemsPerPage] [page]
mediamtx_list_path_configs() {
    local items_per_page="${1:-1000}"
    local page="${2:-0}"
    mediamtx_api_call GET "/config/paths/list?itemsPerPage=${items_per_page}&page=${page}"
}

# Get a specific path configuration
mediamtx_get_path_config() {
    local path_name="$1"
    mediamtx_api_call GET "/config/paths/get/${path_name}"
}

# Add a new path configuration
# Usage: mediamtx_add_path_config "stream_name" '{"source":"rtsp://..."}'
mediamtx_add_path_config() {
    local path_name="$1"
    local config_json="${2:-{\}}"
    mediamtx_api_call POST "/config/paths/add/${path_name}" "$config_json"
}

# Patch an existing path configuration
mediamtx_patch_path_config() {
    local path_name="$1"
    local config_json="$2"
    mediamtx_api_call PATCH "/config/paths/patch/${path_name}" "$config_json"
}

# Replace a path configuration entirely
mediamtx_replace_path_config() {
    local path_name="$1"
    local config_json="$2"
    mediamtx_api_call POST "/config/paths/replace/${path_name}" "$config_json"
}

# Delete a path configuration
mediamtx_delete_path_config() {
    local path_name="$1"
    mediamtx_api_call DELETE "/config/paths/delete/${path_name}"
}

# -----------------------------------------------------------------------------
# Runtime Paths (/v3/paths)
# -----------------------------------------------------------------------------

# List all active paths (runtime state)
# Usage: mediamtx_list_paths [itemsPerPage] [page]
# shellcheck disable=SC2120  # Optional parameters with defaults
mediamtx_list_paths() {
    local items_per_page="${1:-1000}"
    local page="${2:-0}"
    mediamtx_api_call GET "/paths/list?itemsPerPage=${items_per_page}&page=${page}"
}

# Get a specific path's runtime state
mediamtx_get_path() {
    local path_name="$1"
    mediamtx_api_call GET "/paths/get/${path_name}"
}

# --- Tolerant JSON status parsing -------------------------------------------
# MediaMTX deprecated the path "ready"/"bytesReceived"/"tracks" fields in favour
# of "available"/"inboundBytes"/"tracks2" (still emitting both as of v1.21.1).
# These helpers accept BOTH shapes so a future MediaMTX that drops "ready" does
# not make every stream look dead. When both fields are present the NEW field
# wins. They are also safe under set -euo pipefail: a zero-match grep must not
# abort the caller (pipefail turns "0 ready paths" into exit 1 otherwise).

# Count occurrences of a fixed pattern in a JSON blob; never fails, prints >= 0.
_json_count_matches() {
    local json="$1" pattern="$2" count
    count=$(printf '%s' "$json" | grep -o "$pattern" | wc -l) || count=0
    printf '%s' "${count:-0}"
}

# Is a single path's JSON "ready"? Tolerates deprecated and current shapes.
mediamtx_json_path_ready() {
    local json="$1"
    if [[ "$json" == *'"available":'* ]]; then
        [[ "$json" == *'"available":true'* ]]
    else
        [[ "$json" == *'"ready":true'* ]]
    fi
}

# Count ready paths in a /v3/paths/list response, tolerant of both shapes.
mediamtx_json_count_ready() {
    local json="$1"
    if [[ "$json" == *'"available":'* ]]; then
        _json_count_matches "$json" '"available":true'
    else
        _json_count_matches "$json" '"ready":true'
    fi
}

# Check if a path is ready (streaming)
mediamtx_path_is_ready() {
    local path_name="$1"
    local path_info
    path_info=$(mediamtx_get_path "$path_name") || return 1
    mediamtx_json_path_ready "$path_info"
}

# -----------------------------------------------------------------------------
# HLS Muxers (/v3/hlsmuxers)
# -----------------------------------------------------------------------------

# List all HLS muxers
mediamtx_list_hls_muxers() {
    local items_per_page="${1:-1000}"
    local page="${2:-0}"
    mediamtx_api_call GET "/hlsmuxers/list?itemsPerPage=${items_per_page}&page=${page}"
}

# Get a specific HLS muxer
mediamtx_get_hls_muxer() {
    local name="$1"
    mediamtx_api_call GET "/hlsmuxers/get/${name}"
}

# -----------------------------------------------------------------------------
# RTSP Connections (/v3/rtspconns)
# -----------------------------------------------------------------------------

# List all RTSP connections
mediamtx_list_rtsp_conns() {
    local items_per_page="${1:-1000}"
    local page="${2:-0}"
    mediamtx_api_call GET "/rtspconns/list?itemsPerPage=${items_per_page}&page=${page}"
}

# Get a specific RTSP connection
mediamtx_get_rtsp_conn() {
    local conn_id="$1"
    mediamtx_api_call GET "/rtspconns/get/${conn_id}"
}

# -----------------------------------------------------------------------------
# RTSP Sessions (/v3/rtspsessions)
# -----------------------------------------------------------------------------

# List all RTSP sessions
# shellcheck disable=SC2120  # Optional parameters with defaults
mediamtx_list_rtsp_sessions() {
    local items_per_page="${1:-1000}"
    local page="${2:-0}"
    mediamtx_api_call GET "/rtspsessions/list?itemsPerPage=${items_per_page}&page=${page}"
}

# Get a specific RTSP session
mediamtx_get_rtsp_session() {
    local session_id="$1"
    mediamtx_api_call GET "/rtspsessions/get/${session_id}"
}

# Kick (disconnect) an RTSP session
mediamtx_kick_rtsp_session() {
    local session_id="$1"
    mediamtx_api_call POST "/rtspsessions/kick/${session_id}"
}

# -----------------------------------------------------------------------------
# RTSPS Connections (/v3/rtspsconns) - Secure RTSP
# -----------------------------------------------------------------------------

# List all RTSPS connections
mediamtx_list_rtsps_conns() {
    local items_per_page="${1:-1000}"
    local page="${2:-0}"
    mediamtx_api_call GET "/rtspsconns/list?itemsPerPage=${items_per_page}&page=${page}"
}

# Get a specific RTSPS connection
mediamtx_get_rtsps_conn() {
    local conn_id="$1"
    mediamtx_api_call GET "/rtspsconns/get/${conn_id}"
}

# -----------------------------------------------------------------------------
# RTSPS Sessions (/v3/rtspssessions) - Secure RTSP
# -----------------------------------------------------------------------------

# List all RTSPS sessions
# shellcheck disable=SC2120  # Optional parameters with defaults
mediamtx_list_rtsps_sessions() {
    local items_per_page="${1:-1000}"
    local page="${2:-0}"
    mediamtx_api_call GET "/rtspssessions/list?itemsPerPage=${items_per_page}&page=${page}"
}

# Get a specific RTSPS session
mediamtx_get_rtsps_session() {
    local session_id="$1"
    mediamtx_api_call GET "/rtspssessions/get/${session_id}"
}

# Kick (disconnect) an RTSPS session
mediamtx_kick_rtsps_session() {
    local session_id="$1"
    mediamtx_api_call POST "/rtspssessions/kick/${session_id}"
}

# -----------------------------------------------------------------------------
# RTMP Connections (/v3/rtmpconns)
# -----------------------------------------------------------------------------

# List all RTMP connections
# shellcheck disable=SC2120  # Optional parameters with defaults
mediamtx_list_rtmp_conns() {
    local items_per_page="${1:-1000}"
    local page="${2:-0}"
    mediamtx_api_call GET "/rtmpconns/list?itemsPerPage=${items_per_page}&page=${page}"
}

# Get a specific RTMP connection
mediamtx_get_rtmp_conn() {
    local conn_id="$1"
    mediamtx_api_call GET "/rtmpconns/get/${conn_id}"
}

# Kick (disconnect) an RTMP connection
mediamtx_kick_rtmp_conn() {
    local conn_id="$1"
    mediamtx_api_call POST "/rtmpconns/kick/${conn_id}"
}

# -----------------------------------------------------------------------------
# RTMPS Connections (/v3/rtmpsconns) - Secure RTMP
# -----------------------------------------------------------------------------

# List all RTMPS connections
mediamtx_list_rtmps_conns() {
    local items_per_page="${1:-1000}"
    local page="${2:-0}"
    mediamtx_api_call GET "/rtmpsconns/list?itemsPerPage=${items_per_page}&page=${page}"
}

# Get a specific RTMPS connection
mediamtx_get_rtmps_conn() {
    local conn_id="$1"
    mediamtx_api_call GET "/rtmpsconns/get/${conn_id}"
}

# Kick (disconnect) an RTMPS connection
mediamtx_kick_rtmps_conn() {
    local conn_id="$1"
    mediamtx_api_call POST "/rtmpsconns/kick/${conn_id}"
}

# -----------------------------------------------------------------------------
# SRT Connections (/v3/srtconns)
# -----------------------------------------------------------------------------

# List all SRT connections
# shellcheck disable=SC2120  # Optional parameters with defaults
mediamtx_list_srt_conns() {
    local items_per_page="${1:-1000}"
    local page="${2:-0}"
    mediamtx_api_call GET "/srtconns/list?itemsPerPage=${items_per_page}&page=${page}"
}

# Get a specific SRT connection
mediamtx_get_srt_conn() {
    local conn_id="$1"
    mediamtx_api_call GET "/srtconns/get/${conn_id}"
}

# Kick (disconnect) an SRT connection
mediamtx_kick_srt_conn() {
    local conn_id="$1"
    mediamtx_api_call POST "/srtconns/kick/${conn_id}"
}

# -----------------------------------------------------------------------------
# WebRTC Sessions (/v3/webrtcsessions)
# -----------------------------------------------------------------------------

# List all WebRTC sessions
# shellcheck disable=SC2120  # Optional parameters with defaults
mediamtx_list_webrtc_sessions() {
    local items_per_page="${1:-1000}"
    local page="${2:-0}"
    mediamtx_api_call GET "/webrtcsessions/list?itemsPerPage=${items_per_page}&page=${page}"
}

# Get a specific WebRTC session
mediamtx_get_webrtc_session() {
    local session_id="$1"
    mediamtx_api_call GET "/webrtcsessions/get/${session_id}"
}

# Kick (disconnect) a WebRTC session
mediamtx_kick_webrtc_session() {
    local session_id="$1"
    mediamtx_api_call POST "/webrtcsessions/kick/${session_id}"
}

# -----------------------------------------------------------------------------
# Recordings (/v3/recordings)
# -----------------------------------------------------------------------------

# List all recordings
mediamtx_list_recordings() {
    local items_per_page="${1:-1000}"
    local page="${2:-0}"
    mediamtx_api_call GET "/recordings/list?itemsPerPage=${items_per_page}&page=${page}"
}

# Get recordings for a specific path
mediamtx_get_recordings() {
    local path_name="$1"
    mediamtx_api_call GET "/recordings/get/${path_name}"
}

# Delete a recording segment
# Usage: mediamtx_delete_recording_segment "path_name" "2024-01-15T10:30:00Z"
mediamtx_delete_recording_segment() {
    local path_name="$1"
    local start_time="$2"
    # URL encode the parameters
    local encoded_path
    encoded_path=$(printf '%s' "$path_name" | sed 's/ /%20/g')
    local encoded_time
    encoded_time=$(printf '%s' "$start_time" | sed 's/:/%3A/g')
    mediamtx_api_call DELETE "/recordings/deletesegment?path=${encoded_path}&start=${encoded_time}"
}

# -----------------------------------------------------------------------------
# Authentication (/v3/auth)
# -----------------------------------------------------------------------------

# Refresh JWT JWKS credentials
mediamtx_refresh_jwks() {
    mediamtx_api_call POST "/auth/jwks/refresh"
}

# -----------------------------------------------------------------------------
# Utility Functions
# -----------------------------------------------------------------------------

# Get total count of active RTSP sessions (listeners)
mediamtx_count_rtsp_sessions() {
    local sessions
    sessions=$(mediamtx_list_rtsp_sessions) || {
        echo "0"
        return
    }
    local count
    count=$(_json_count_matches "$sessions" '"id"')
    echo "${count:-0}"
}

# Get total count of all connections across protocols
mediamtx_count_all_connections() {
    local total=0
    local count

    # RTSP sessions
    count=$(mediamtx_count_rtsp_sessions 2>/dev/null)
    total=$((total + count))

    # RTSPS sessions
    local rtsps
    rtsps=$(mediamtx_list_rtsps_sessions 2>/dev/null) || rtsps=""
    count=$(_json_count_matches "$rtsps" '"id"')
    total=$((total + count))

    # RTMP connections
    local rtmp
    rtmp=$(mediamtx_list_rtmp_conns 2>/dev/null) || rtmp=""
    count=$(_json_count_matches "$rtmp" '"id"')
    total=$((total + count))

    # WebRTC sessions
    local webrtc
    webrtc=$(mediamtx_list_webrtc_sessions 2>/dev/null) || webrtc=""
    count=$(_json_count_matches "$webrtc" '"id"')
    total=$((total + count))

    # SRT connections
    local srt
    srt=$(mediamtx_list_srt_conns 2>/dev/null) || srt=""
    count=$(_json_count_matches "$srt" '"id"')
    total=$((total + count))

    echo "$total"
}

# Get count of ready paths
mediamtx_count_ready_paths() {
    local paths
    paths=$(mediamtx_list_paths) || {
        echo "0"
        return
    }
    local count
    count=$(mediamtx_json_count_ready "$paths")
    echo "${count:-0}"
}

# Check MediaMTX API health (enhanced version using /v3/info)
# Returns: 0 if healthy, 1 if API unreachable, 2 if degraded
mediamtx_check_health() {
    local info
    info=$(mediamtx_get_info) || return 1

    # Verify we got valid response with version
    if ! echo "$info" | grep -q '"version"'; then
        return 2
    fi

    return 0
}

# Get summary of MediaMTX state for monitoring
# Output: Human-readable status summary
mediamtx_get_status_summary() {
    local info
    info=$(mediamtx_get_info 2>/dev/null) || {
        echo "MediaMTX API: UNREACHABLE"
        return 1
    }

    local version
    version=$(echo "$info" | grep -o '"version":"[^"]*"' | cut -d'"' -f4) || true

    local paths_json
    paths_json=$(mediamtx_list_paths 2>/dev/null) || paths_json=""
    local total_paths
    total_paths=$(_json_count_matches "$paths_json" '"name"')
    local ready_paths
    ready_paths=$(mediamtx_json_count_ready "$paths_json")

    local rtsp_sessions
    rtsp_sessions=$(mediamtx_count_rtsp_sessions 2>/dev/null)

    local total_conns
    total_conns=$(mediamtx_count_all_connections 2>/dev/null)

    echo "MediaMTX v${version:-unknown}"
    echo "  Paths: ${ready_paths}/${total_paths} ready"
    echo "  RTSP sessions: ${rtsp_sessions}"
    echo "  Total connections: ${total_conns}"
}

# Check if ALSA device is available before attempting stream restart
# Prevents restart loops when USB device is disconnected
check_alsa_device_available() {
    local card_num="$1"

    if [[ "${USB_ALSA_CHECK_ENABLED}" != "true" ]]; then
        return 0
    fi

    # Check if card exists in ALSA
    if [[ ! -d "/proc/asound/card${card_num}" ]]; then
        log DEBUG "ALSA card ${card_num} not found in /proc/asound"
        return 1
    fi

    # Check if device is accessible
    if command_exists arecord; then
        if ! arecord -l 2>/dev/null | grep -q "card ${card_num}:"; then
            log DEBUG "ALSA card ${card_num} not listed by arecord"
            return 1
        fi
    fi

    # Additional check: verify the device node exists
    local device_path="/dev/snd/pcmC${card_num}D0c"
    if [[ ! -e "$device_path" ]]; then
        log DEBUG "Device node $device_path does not exist"
        return 1
    fi

    return 0
}

# ============================================================================
# Audio level signals (LB-14, X-05; decision D6)
# ============================================================================
# A dead microphone is a stream that is published and silent. The PID file and
# the API's ready flag cannot show it, and it must not be looked for by opening
# the ALSA device a second time: that contends with the capture FFmpeg. The
# level is measured where every listener gets it, from the stream MediaMTX
# publishes, with a short RTSP read. Four signals stay apart: the path is ready
# (probe_stream_ready), bytes move (the deep health probe), the level
# (probe_stream_level) and prolonged silence (track_silence).

# dB with at most one decimal as tenths of a dB, so the threshold comparison
# needs no floating point: "-12.5" -> -125, "-inf" -> -99999. Fails (printing
# nothing) for a value that is not a number. A decimal comma is accepted.
_db_to_tenths() {
    local v="${1//,/.}"
    case "$v" in
        -inf | -Inf | -INF)
            printf '%s' -99999
            return 0
            ;;
        inf | +inf | Inf | INF)
            printf '%s' 99999
            return 0
            ;;
    esac
    local re='^(-?)([0-9]+)(\.([0-9]))?[0-9]*$'
    [[ "$v" =~ $re ]] || return 1
    local tenths=$((10#${BASH_REMATCH[2]} * 10 + 10#${BASH_REMATCH[4]:-0}))
    if [[ -n "${BASH_REMATCH[1]}" ]]; then
        tenths=$((-tenths))
    fi
    printf '%s' "$tenths"
}

# Measure the level of one published stream by reading AUDIO_LEVEL_SAMPLE_DURATION
# seconds of it over RTSP (never an ALSA device).
#
#   probe_stream_level PATH [SECONDS]
#
# Prints one line, "<state> <max dB> <mean dB> <detail>", with "-" where a value
# is unknown, and returns 0. state is
#   ok             samples were read and the loudest one is above
#                  AUDIO_SILENCE_THRESHOLD_DB
#   silent         samples were read and max_volume is at or below the threshold
#                  (digital silence measures -91.0)
#   no_audio_data  the stream opened but delivered no samples
#   unreachable    the stream could not be opened: not published, nothing
#                  listening, timed out (the deep health probe's business)
#   probe_error    the measurement failed: no ffmpeg or timeout, ffmpeg crashed
#                  or printed nothing usable, or the server wants credentials
# Only "silent" says anything about the microphone. The probe is bounded by
# timeout(1): sample seconds + AUDIO_LEVEL_PROBE_GRACE. The RTSP port is
# MEDIAMTX_RTSP_PORT (default 8554).
probe_stream_level() {
    local stream="${1:-}" seconds="${2:-${AUDIO_LEVEL_SAMPLE_DURATION}}"
    local state="probe_error" max="-" mean="-" detail=""

    if [[ ! "$stream" =~ ^[A-Za-z0-9_-]+$ ]]; then
        detail="not a usable stream path: '${stream}'"
    elif ! command_exists ffmpeg || ! command_exists timeout; then
        detail="ffmpeg and timeout are both required"
    else
        if [[ ! "$seconds" =~ ^[0-9]+$ ]] || ((10#$seconds < 1)); then
            seconds=1
        fi
        seconds=$((10#$seconds))
        local port="${MEDIAMTX_RTSP_PORT:-8554}"
        if [[ ! "$port" =~ ^[0-9]+$ ]] || ((10#$port < 1 || 10#$port > 65535)); then
            port=8554
        fi
        port=$((10#$port))

        # volumedetect reports on stderr at INFO level; LC_ALL=C pins the
        # number format. "-f null -" discards the decoded audio.
        local out="" rc=0
        out="$(LC_ALL=C timeout -k 2 "$((seconds + AUDIO_LEVEL_PROBE_GRACE))" \
            ffmpeg -nostdin -hide_banner -nostats -loglevel info -rtsp_transport tcp \
            -i "rtsp://127.0.0.1:${port}/${stream}" -t "$seconds" -vn \
            -af volumedetect -f null - 2>&1)" || rc=$?

        # A filter graph that ffmpeg rebuilt prints one block of its own: the
        # last block is the measurement ("n_samples: 0" blocks carry no volume)
        local re_samples='n_samples: *([0-9]+)'
        local re_mean='mean_volume: *(-?[A-Za-z0-9.,]+) dB'
        local re_max='max_volume: *(-?[A-Za-z0-9.,]+) dB'
        local marker='Input #0' # ffmpeg's first line once the input is open
        local line last_line="" samples=0 connected=false
        while IFS= read -r line; do
            if [[ -n "$line" ]]; then
                last_line="$line"
            fi
            if [[ "$line" == "$marker"* ]]; then
                connected=true
            elif [[ "$line" =~ $re_samples ]]; then
                samples=$((10#${BASH_REMATCH[1]}))
                max="-"
                mean="-"
            elif [[ "$line" =~ $re_mean ]]; then
                mean="${BASH_REMATCH[1]}"
            elif [[ "$line" =~ $re_max ]]; then
                max="${BASH_REMATCH[1]}"
            fi
        done <<<"$out"

        local max_tenths=""
        if ((rc == 0 && samples > 0)) && max_tenths="$(_db_to_tenths "$max")"; then
            if ((max_tenths <= AUDIO_SILENCE_THRESHOLD_DB * 10)); then
                state="silent"
            else
                state="ok"
            fi
            _db_to_tenths "$mean" >/dev/null || mean="-"
        else
            max="-"
            mean="-"
            local re_auth='(401 Unauthorized|403 Forbidden|Server returned 40[13])'
            local re_down='(Connection refused|Connection timed out|Connection reset|Operation timed out|No route to host|Network is unreachable|Name or service not known|404 Not Found|Server returned 4[0-9][0-9]|Server returned 5[0-9][0-9]|method DESCRIBE failed)'
            if [[ "$connected" == "false" && "$out" =~ $re_auth ]]; then
                detail="the server wants credentials, the probe reads anonymously"
            elif [[ "$connected" == "true" ]] && ((rc == 0 || rc == 124)); then
                state="no_audio_data"
                detail="the stream opened but delivered no samples (ffmpeg exit ${rc})"
            elif ((rc == 124)) || [[ "$out" =~ $re_down ]]; then
                state="unreachable"
                detail="could not open rtsp port ${port} path ${stream} (ffmpeg exit ${rc})"
            else
                detail="ffmpeg exit ${rc}, last line: ${last_line:0:120}"
            fi
        fi
    fi

    log DEBUG "Level probe ${stream}: ${state} ${max} ${mean}${detail:+ ${detail}}"
    printf '%s %s %s%s\n' "$state" "$max" "$mean" "${detail:+ ${detail}}"
    return 0
}

# Per-stream signal state, one file per stream under SILENCE_STATE_DIR:
# "<silence start> <alerted 0|1> <last probe>". The times are monotonic seconds
# (_now_monotonic): wall-clock steps cannot turn minutes into a DEAD MIC. "-"
# means "no silence episode" / "never probed". Read into SIGNAL_START,
# SIGNAL_ALERTED and SIGNAL_LAST.
declare -g SIGNAL_START="-" SIGNAL_ALERTED=0 SIGNAL_LAST="-"

_signal_state_read() {
    local file="${SILENCE_STATE_DIR}/${1}.state" start="" alerted="" last=""
    SIGNAL_START="-"
    SIGNAL_ALERTED=0
    SIGNAL_LAST="-"
    [[ -r "$file" ]] || return 0
    { IFS=' ' read -r start alerted last <"$file"; } 2>/dev/null || true
    if [[ "$start" =~ ^[0-9]+$ ]]; then
        SIGNAL_START="$((10#$start))"
    fi
    if [[ "$alerted" == "1" ]]; then
        SIGNAL_ALERTED=1
    fi
    if [[ "$last" =~ ^[0-9]+$ ]]; then
        SIGNAL_LAST="$((10#$last))"
    fi
    return 0
}

_signal_state_write() {
    local stream="$1" file tmp
    file="${SILENCE_STATE_DIR}/${stream}.state"
    tmp="${file}.tmp.$$"
    if mkdir -p "${SILENCE_STATE_DIR}" 2>/dev/null \
        && printf '%s %s %s\n' "$2" "$3" "$4" >"$tmp" 2>/dev/null \
        && mv -f "$tmp" "$file" 2>/dev/null; then
        return 0
    fi
    rm -f "$tmp" 2>/dev/null || true
    log WARN "Cannot record the audio level state of ${stream} in ${SILENCE_STATE_DIR}: silence tracking cannot persist between monitor runs"
    return 0
}

# Feed one verdict of probe_stream_level into the stream's silence episode.
#
#   track_silence STREAM STATE MAX_DB NOW
#
# An episode starts with the first "silent" probe, raises the DEAD MIC error
# once when it has lasted AUDIO_SILENCE_WARN_DURATION seconds, and ends with the
# first "ok" probe (logged as recovery). unreachable, no_audio_data and
# probe_error say nothing about the microphone: they neither start, extend, end
# nor alert an episode. NOW is the monotonic time of the probe; it is also kept
# as the stream's last probe time.
track_silence() {
    local stream="$1" state="$2" max="$3" now="$4"
    _signal_state_read "$stream"
    local start="$SIGNAL_START" alerted="$SIGNAL_ALERTED"
    case "$state" in
        ok)
            if [[ "$start" != "-" ]]; then
                local was=$((now - start))
                if ((was < 0)); then
                    was=0
                fi
                log INFO "Audio recovered on ${stream} after ${was}s of silence (max volume ${max} dB)"
            fi
            start="-"
            alerted=0
            ;;
        silent)
            # A start in the future is a value from another clock scale: begin again
            if [[ "$start" == "-" ]] || ((start > now)); then
                start="$now"
                alerted=0
                log WARN "Silence detected on ${stream}: max volume ${max} dB (threshold: ${AUDIO_SILENCE_THRESHOLD_DB} dB)"
            fi
            local silent_for=$((now - start))
            if ((silent_for >= AUDIO_SILENCE_WARN_DURATION)) && [[ "$alerted" != "1" ]]; then
                alerted=1
                log ERROR "DEAD MIC: ${stream} has been silent for ${silent_for}s (>${AUDIO_SILENCE_WARN_DURATION}s)"
            fi
            ;;
        *) ;;
    esac
    _signal_state_write "$stream" "$start" "$alerted" "$now"
}

# The signals step of one monitor run: for every stream this manager runs (a
# PID file in FFMPEG_PID_DIR names a live process) that MediaMTX reports ready,
# measure the level once and feed the verdict to the silence episode. A stream
# probed less than AUDIO_LEVEL_CHECK_INTERVAL seconds ago is skipped, so one
# monitor run opens at most one short reader per stream. Purely informational:
# it changes nothing and always returns 0. AUDIO_LEVEL_CHECK_ENABLED=false turns
# it off.
monitor_signals() {
    if [[ "${AUDIO_LEVEL_CHECK_ENABLED}" != "true" ]]; then
        return 0
    fi

    local nullglob_state
    shopt -q nullglob && nullglob_state=on || nullglob_state=off
    shopt -s nullglob

    local pid_file stream pid now rc verdict state max mean detail
    for pid_file in "${FFMPEG_PID_DIR}"/*.pid; do
        stream="${pid_file##*/}"
        stream="${stream%.pid}"
        if [[ ! "$stream" =~ ^[A-Za-z0-9_-]+$ ]]; then
            continue
        fi
        pid="$(read_pid_safe "$pid_file")"
        if [[ -z "$pid" ]]; then
            continue
        fi
        rc=0
        probe_stream_ready "$stream" || rc=$?
        if ((rc != 0)); then
            log DEBUG "Level probe skipped for ${stream}: path not ready or API unknown (probe_stream_ready=${rc})"
            continue
        fi
        now="$(_now_monotonic)"
        _signal_state_read "$stream"
        if [[ "$SIGNAL_LAST" != "-" ]] && ((SIGNAL_LAST <= now && now - SIGNAL_LAST < AUDIO_LEVEL_CHECK_INTERVAL)); then
            log DEBUG "Level probe skipped for ${stream}: probed $((now - SIGNAL_LAST))s ago (interval ${AUDIO_LEVEL_CHECK_INTERVAL}s)"
            continue
        fi

        verdict="$(probe_stream_level "$stream")"
        read -r state max mean detail <<<"$verdict"
        case "$state" in
            ok) log DEBUG "Audio level OK for ${stream}: max volume ${max} dB, mean ${mean} dB" ;;
            silent) ;;
            no_audio_data) log WARN "Stream ${stream} is published but delivered no audio samples during the level probe" ;;
            unreachable) log DEBUG "Level probe: ${stream} could not be opened (${detail})" ;;
            *) log WARN "Level probe of ${stream} failed, not counted as silence: ${detail}" ;;
        esac
        track_silence "$stream" "$state" "$max" "$(_now_monotonic)"
    done

    if [[ "$nullglob_state" == "off" ]]; then
        shopt -u nullglob
    fi
    return 0
}

# Validate configuration file syntax
# shellcheck disable=SC2120 # Function accepts optional config_file parameter, defaults to DEVICE_CONFIG_FILE
validate_config() {
    local config_file="${1:-${DEVICE_CONFIG_FILE}}"

    if [[ ! -f "$config_file" ]]; then
        log DEBUG "Config file $config_file does not exist (using defaults)"
        return 0
    fi

    # Check for basic shell syntax errors
    if ! bash -n "$config_file" 2>/dev/null; then
        log ERROR "Configuration file $config_file has syntax errors"
        return 1
    fi

    # Source in subshell to check for errors
    # shellcheck disable=SC1090 # Config file path is validated above, dynamic sourcing is intentional
    if ! (source "$config_file" 2>/dev/null); then
        log ERROR "Configuration file $config_file failed to source"
        return 1
    fi

    log DEBUG "Configuration file $config_file validated successfully"
    return 0
}

# Heartbeat: write the Unix time of this monitor run to HEARTBEAT_FILE
# (lyrebird-metrics.sh reads it as lyrebird_heartbeat_*). Called once per monitor
# run, by check_all_resources, whatever the state of MediaMTX or the streams: the
# file says "the monitor ran at this time" and nothing more.
update_heartbeat() {
    local timestamp
    timestamp=$(date +%s)

    # Ensure directory exists
    local heartbeat_dir
    heartbeat_dir=$(dirname "${HEARTBEAT_FILE}")
    [[ -d "$heartbeat_dir" ]] || mkdir -p "$heartbeat_dir" 2>/dev/null || true

    # Write timestamp atomically
    if ! { echo "$timestamp" >"${HEARTBEAT_FILE}.tmp" && mv "${HEARTBEAT_FILE}.tmp" "${HEARTBEAT_FILE}"; } 2>/dev/null; then
        log WARN "Cannot write the monitor heartbeat ${HEARTBEAT_FILE}"
    fi
    return 0
}

# Settings of features that were removed because they did nothing (LB-15, LB-16;
# decisions D7, D8). They are still read from the environment only to say, once
# per run, that they are ignored and what replaces them.
REMOVED_SETTINGS_WARNED=false
warn_removed_settings() {
    if [[ "${REMOVED_SETTINGS_WARNED}" == "true" ]]; then
        return 0
    fi
    REMOVED_SETTINGS_WARNED=true
    local name found=""
    for name in HEARTBEAT_INTERVAL HARDWARE_WATCHDOG_TIMEOUT ENABLE_HARDWARE_WATCHDOG HARDWARE_WATCHDOG_DEVICE LYREBIRD_WATCHDOG_ENABLED LYREBIRD_WATCHDOG_INTERVAL; do
        if [[ -v "$name" ]]; then
            found+="${found:+, }${name}"
        fi
    done
    if [[ -n "$found" ]]; then
        log WARN "Ignoring removed setting(s): ${found}. The manager has no watchdog: it never opened a watchdog device. For a hardware watchdog use systemd's RuntimeWatchdogSec= (system.conf) or a watchdog daemon; the monitor only records the time of its last run in ${HEARTBEAT_FILE}"
    fi
    found=""
    for name in AUDIO_DISK_PERSIST AUDIO_DISK_PATH; do
        if [[ -v "$name" ]]; then
            found+="${found:+, }${name}"
        fi
    done
    if [[ -n "$found" ]]; then
        log WARN "Ignoring removed setting(s): ${found}. Nothing is moved to disk: recording is RAM-only by default (AUDIO_RECORDING_PATH=/dev/shm/lyrebird-buffer, lost at reboot or power loss). For recording that survives, point AUDIO_RECORDING_PATH at persistent storage"
    fi
    return 0
}

# Version compatibility check
# Verifies that lyrebird-common.sh meets minimum version requirements
check_version_compatibility() {
    # Check if lyrebird-common.sh provides version
    if declare -f lyrebird_common_version >/dev/null 2>&1; then
        local common_version
        common_version=$(lyrebird_common_version 2>/dev/null || echo "0.0.0")

        # Simple version comparison (major.minor.patch)
        local required="${MIN_COMPATIBLE_COMMON_VERSION}"
        local IFS='.'
        read -ra req_parts <<<"$required"
        read -ra cur_parts <<<"$common_version"

        for i in 0 1 2; do
            local req_num="${req_parts[$i]:-0}"
            local cur_num="${cur_parts[$i]:-0}"

            if [[ $cur_num -lt $req_num ]]; then
                log WARN "lyrebird-common.sh version $common_version is older than required $required"
                return 1
            elif [[ $cur_num -gt $req_num ]]; then
                break
            fi
        done
    fi

    return 0
}

# Enhanced resource check that includes all new monitoring
check_all_resources() {
    local issues=0
    local critical=false

    # Original resource check
    if ! check_resource_usage; then
        critical=true
    fi

    # Disk space check. IMPORTANT: disk-full is NOT restart-fixable — restarting
    # the service frees no disk and would just tear down every stream every 5
    # minutes for the whole duration of the condition (a data-loss-maximizing
    # restart storm). Treat it as DEGRADED (logged/alerted, exit 1) so the
    # operator is notified and the storage-cleanup cron can act, while the
    # service keeps running and capturing. A leak in OUR OWN processes is caught
    # by check_resource_usage above, which DOES remain a restart trigger.
    local disk_result
    check_disk_space
    disk_result=$?
    [[ $disk_result -ne 0 ]] && ((issues++)) || true

    # System-wide memory pressure is likewise environmental (it may be caused by
    # other processes) and a restart of our streams cannot remediate it. Degraded,
    # not critical — same restart-storm reasoning as disk.
    local mem_result
    check_memory_usage
    mem_result=$?
    [[ $mem_result -ne 0 ]] && ((issues++)) || true

    # Network check
    if ! check_network_connectivity; then
        ((issues++)) || true
    fi

    # Record the time of this monitor run (it says the monitor ran, not that
    # anything is healthy)
    update_heartbeat

    if [[ "$critical" == "true" ]]; then
        return ${E_CRITICAL_RESOURCE}
    elif [[ $issues -gt 0 ]]; then
        return 1
    fi

    return 0
}

# Detect if running from cron using multi-method detection
is_cron_context() {
    # Multi-method cron detection for maximum reliability

    # Method 1: Check explicit CRON environment variable (most reliable)
    if [[ "${CRON:-0}" == "1" ]]; then
        return 0
    fi

    # Method 2: Check if stdin/stdout are not terminals (typical cron behavior)
    if [[ ! -t 0 ]] && [[ ! -t 1 ]] && [[ -z "${TERM:-}" ]]; then
        # Additional check: not in SSH session (which also has non-tty)
        if [[ -z "${SSH_CLIENT:-}" ]] && [[ -z "${SSH_TTY:-}" ]]; then
            # Check parent process name contains cron-related strings
            local parent_cmd
            parent_cmd="$(ps -o comm= -p $PPID 2>/dev/null || true)"
            if [[ "$parent_cmd" =~ cron|CRON|anacron ]]; then
                return 0
            fi
        fi
    fi

    # Method 3: Check systemd cgroup (systemd-based cron only)
    if [[ -f /proc/self/cgroup ]]; then
        if grep -qE "cron\.service|cronie\.service" /proc/self/cgroup 2>/dev/null; then
            return 0
        fi
    fi

    # Method 4: Check parent process name directly
    if [[ -f /proc/$PPID/comm ]]; then
        local parent_comm
        parent_comm="$(cat /proc/$PPID/comm 2>/dev/null || true)"
        if [[ "$parent_comm" =~ ^(cron|crond|anacron)$ ]]; then
            return 0
        fi
    fi

    return 1
}

# Monotonic seconds since boot. Wall-clock deltas (date +%s) are corrupted by
# NTP steps, DST-adjacent RTC fixes and the first network clock set on an
# RTC-less Pi; /proc/uptime never jumps. All boot-scoped timing state (backoff
# runtimes, cron restart budgets, silence tracking -- kept under /run, which is
# cleared at boot) uses this. Falls back to wall clock only when /proc/uptime
# is unavailable.
_now_monotonic() {
    local up
    if [[ -r /proc/uptime ]]; then
        read -r up _ </proc/uptime
        printf '%s' "${up%%.*}"
    else
        date +%s
    fi
}

# --- Bounded cron resurrection (H8) -----------------------------------------
# Count this stream's cron restarts within the last hour (read-only).
_cron_restart_count() {
    local stream_path="$1"
    local state_file="${CRON_RESTART_STATE_DIR}/${stream_path}.restarts"
    [[ -f "$state_file" ]] || {
        printf '0'
        return 0
    }
    local now cutoff count=0 ts
    now="$(_now_monotonic)"
    cutoff=$((now - 3600))
    while read -r ts; do
        [[ "$ts" =~ ^[0-9]+$ ]] || continue
        ((ts >= cutoff)) && ((count++)) || true
    done <"$state_file"
    printf '%s' "$count"
}

# Record a cron restart attempt for this stream (prunes entries older than 1h).
_record_cron_restart() {
    local stream_path="$1"
    local state_file="${CRON_RESTART_STATE_DIR}/${stream_path}.restarts"
    mkdir -p "${CRON_RESTART_STATE_DIR}" 2>/dev/null || true
    local now cutoff kept="" ts
    now="$(_now_monotonic)"
    cutoff=$((now - 3600))
    if [[ -f "$state_file" ]]; then
        while read -r ts; do
            [[ "$ts" =~ ^[0-9]+$ ]] || continue
            ((ts >= cutoff)) && kept+="${ts}"$'\n'
        done <"$state_file"
    fi
    printf '%s%s\n' "$kept" "$now" >"$state_file" 2>/dev/null || true
}

# Decide whether monitor_streams may (re)start this stream now. Interactive and
# service invocations always may. Under cron, a dead stream is resurrected but
# no more than CRON_RESTART_MAX_PER_HOUR times per hour; the attempt is recorded
# here so the cap also bounds attempts that fail to come up.
should_restart_stream() {
    local stream_path="$1"
    is_cron_context || return 0
    local count
    count="$(_cron_restart_count "$stream_path")"
    if ((count < CRON_RESTART_MAX_PER_HOUR)); then
        _record_cron_restart "$stream_path"
        log INFO "cron: resurrecting dead stream $stream_path (restart ${count}/${CRON_RESTART_MAX_PER_HOUR} this hour)"
        return 0
    fi
    log WARN "cron: $stream_path is down but its restart budget (${CRON_RESTART_MAX_PER_HOUR}/hour) is exhausted; not restarting"
    return 1
}

# --- Deep health probe (H9) --------------------------------------------------
# Ask the MediaMTX control API whether a path is actually publishing.
# Returns: 0 = ready, 1 = not ready, 2 = unknown (curl absent/API unreachable).
probe_stream_ready() {
    local stream_path="$1"
    command_exists curl || return 2
    local api_base response
    api_base=$(detect_mediamtx_api_version)
    if ! response=$(curl -s --max-time 3 "${api_base}/paths/get/${stream_path}" 2>/dev/null) \
        || [[ -z "$response" ]]; then
        return 2
    fi
    if mediamtx_json_path_ready "$response"; then
        return 0
    fi
    return 1
}

# Record a probe verdict for a stream. Not-ready increments a strike counter;
# ready clears it; unknown leaves it untouched (an API blip must neither strike
# a healthy stream nor forgive a stuck one). Returns 0 when the stream has been
# not-ready for DEEP_HEALTH_MAX_STRIKES consecutive checks (caller restarts it,
# counter resets so the next escalation needs a fresh streak).
deep_health_note() {
    local stream_path="$1" verdict="$2"
    local strike_file="${DEEP_HEALTH_STATE_DIR}/${stream_path}.strikes"
    case "$verdict" in
        ready)
            rm -f "$strike_file" 2>/dev/null || true
            return 1
            ;;
        unknown)
            return 1
            ;;
    esac
    mkdir -p "${DEEP_HEALTH_STATE_DIR}" 2>/dev/null || true
    local strikes=0
    if [[ -f "$strike_file" ]]; then
        strikes=$(cat "$strike_file" 2>/dev/null) || strikes=0
    fi
    [[ "$strikes" =~ ^[0-9]+$ ]] || strikes=0
    strikes=$((strikes + 1))
    printf '%s\n' "$strikes" >"$strike_file" 2>/dev/null || true
    if ((strikes >= DEEP_HEALTH_MAX_STRIKES)); then
        rm -f "$strike_file" 2>/dev/null || true
        return 0
    fi
    log INFO "Stream $stream_path: wrapper alive but path not ready (strike ${strikes}/${DEEP_HEALTH_MAX_STRIKES})"
    return 1
}

# Combined probe: 0 => the stream is confirmed stuck (alive wrapper, path
# continuously not-ready) and should be restarted; 1 => leave it alone.
deep_stream_unhealthy() {
    local stream_path="$1"
    [[ "${DEEP_HEALTH_CHECK_ENABLED}" == "true" ]] || return 1
    local rc=0
    probe_stream_ready "$stream_path" || rc=$?
    local verdict
    case "$rc" in
        0) verdict="ready" ;;
        1) verdict="notready" ;;
        *) verdict="unknown" ;;
    esac
    deep_health_note "$stream_path" "$verdict"
}

# Stream health monitoring with automatic restart
monitor_streams() {
    log INFO "Checking stream health..."

    # First check if MediaMTX is running
    local mediamtx_pid
    mediamtx_pid="$(read_pid_safe "${PID_FILE}")"

    if [[ -z "$mediamtx_pid" ]] || ! kill -0 "$mediamtx_pid" 2>/dev/null; then
        log WARN "MediaMTX is not running - skipping stream health check"
        log INFO "Run 'start' command to start MediaMTX and streams"
        return "${E_MEDIAMTX_DOWN}"
    fi

    # Restart decisions are made per-stream by should_restart_stream: interactive
    # and service runs restart a dead stream immediately; cron performs BOUNDED
    # resurrection (up to CRON_RESTART_MAX_PER_HOUR per stream per hour) so a dead
    # stream is brought back instead of staying down forever (H8), without a
    # restart storm.
    if is_cron_context; then
        log DEBUG "Running from cron - bounded resurrection mode"
    fi

    # Get current devices
    local devices=()
    readarray -t devices < <(detect_audio_devices)

    if [[ ${#devices[@]} -eq 0 ]]; then
        log WARN "No USB audio devices detected"
        return "${E_USB_NO_DEVICES}"
    fi

    local streams_healthy=0
    local streams_restarted=0
    local streams_failed=0
    local streams_checked=0

    # Handle multiplex mode health monitoring
    if [[ "${STREAM_MODE}" == "multiplex" ]]; then
        ((streams_checked++)) || true

        # Sanitize stream name (same logic as start_ffmpeg_multiplex_stream)
        local stream_path
        stream_path="$(sanitize_path_name "${MULTIPLEX_STREAM_NAME}")"
        if [[ "$stream_path" =~ ^[0-9] ]]; then
            stream_path="stream_${stream_path}"
        fi

        local pid_file="${FFMPEG_PID_DIR}/${stream_path}.pid"

        # Check if PID file exists
        if [[ ! -f "$pid_file" ]]; then
            if should_restart_stream "$stream_path"; then
                log WARN "Multiplex stream $stream_path has no PID file - restarting"
                if start_ffmpeg_multiplex_stream "${devices[@]}"; then
                    ((streams_restarted++)) || true
                    log INFO "Successfully restarted multiplex stream $stream_path"
                else
                    ((streams_failed++)) || true
                    log ERROR "Failed to restart multiplex stream $stream_path"
                fi
            else
                ((streams_failed++)) || true
                log WARN "Multiplex stream $stream_path has no PID file (cron mode: not restarting)"
            fi
        else
            # Check if process is running
            local pid
            pid="$(read_pid_safe "$pid_file")"

            if [[ -z "$pid" ]]; then
                if should_restart_stream "$stream_path"; then
                    log WARN "Multiplex stream $stream_path PID is invalid - restarting"
                    if start_ffmpeg_multiplex_stream "${devices[@]}"; then
                        ((streams_restarted++)) || true
                        log INFO "Successfully restarted multiplex stream $stream_path"
                    else
                        ((streams_failed++)) || true
                        log ERROR "Failed to restart multiplex stream $stream_path"
                    fi
                else
                    ((streams_failed++)) || true
                    log WARN "Multiplex stream $stream_path PID is invalid (cron mode: not restarting)"
                fi
            elif pid_is_foreign_wrapper "$pid" "$stream_path"; then
                if should_restart_stream "$stream_path"; then
                    log WARN "Multiplex stream $stream_path PID $pid is stale - restarting"
                    rm -f "$pid_file"
                    if start_ffmpeg_multiplex_stream "${devices[@]}"; then
                        ((streams_restarted++)) || true
                        log INFO "Successfully restarted multiplex stream $stream_path"
                    else
                        ((streams_failed++)) || true
                        log ERROR "Failed to restart multiplex stream $stream_path"
                    fi
                else
                    ((streams_failed++)) || true
                    log WARN "Multiplex stream $stream_path PID $pid is stale (cron mode: not restarting)"
                fi
            elif deep_stream_unhealthy "$stream_path"; then
                # Wrapper alive but the path has been continuously not-ready:
                # a hung FFmpeg or endless backoff. Restart within the budget.
                if should_restart_stream "$stream_path"; then
                    log WARN "Multiplex stream $stream_path wrapper is alive but path is not ready - restarting"
                    terminate_process_group "$pid" 5 || true
                    rm -f "$pid_file"
                    if start_ffmpeg_multiplex_stream "${devices[@]}"; then
                        ((streams_restarted++)) || true
                        log INFO "Successfully restarted multiplex stream $stream_path"
                    else
                        ((streams_failed++)) || true
                        log ERROR "Failed to restart multiplex stream $stream_path"
                    fi
                else
                    ((streams_failed++)) || true
                    log WARN "Multiplex stream $stream_path is not ready (restart budget exhausted)"
                fi
            else
                ((streams_healthy++)) || true
                log DEBUG "Multiplex stream $stream_path is healthy (PID: $pid)"
            fi
        fi
    else
        # Individual mode: check each stream
        for device_info in "${devices[@]}"; do
            IFS=':' read -r device_name card_num <<<"$device_info"

            if [[ -z "$device_name" ]] || [[ -z "$card_num" ]]; then
                continue
            fi

            local stream_path
            stream_path="$(generate_stream_path "$device_name" "$card_num")"
            local pid_file="${FFMPEG_PID_DIR}/${stream_path}.pid"

            ((streams_checked++)) || true

            # Check if PID file exists
            if [[ ! -f "$pid_file" ]]; then
                if should_restart_stream "$stream_path"; then
                    # v1.4.2: Check ALSA device availability before restart
                    if ! check_alsa_device_available "$card_num"; then
                        log WARN "Stream $stream_path: ALSA device not available (card $card_num), skipping restart"
                        ((streams_failed++)) || true
                        continue
                    fi
                    log WARN "Stream $stream_path has no PID file - restarting"
                    if start_ffmpeg_stream "$device_name" "$card_num" "$stream_path"; then
                        ((streams_restarted++)) || true
                        log INFO "Successfully restarted stream $stream_path"
                    else
                        ((streams_failed++)) || true
                        log ERROR "Failed to restart stream $stream_path"
                    fi
                else
                    ((streams_failed++)) || true
                    log WARN "Stream $stream_path has no PID file (cron mode: not restarting)"
                fi
                continue
            fi

            # Check if process is running
            local pid
            pid="$(read_pid_safe "$pid_file")"

            if [[ -z "$pid" ]]; then
                if should_restart_stream "$stream_path"; then
                    # v1.4.2: Check ALSA device availability before restart
                    if ! check_alsa_device_available "$card_num"; then
                        log WARN "Stream $stream_path: ALSA device not available (card $card_num), skipping restart"
                        ((streams_failed++)) || true
                        continue
                    fi
                    log WARN "Stream $stream_path PID is invalid - restarting"
                    if start_ffmpeg_stream "$device_name" "$card_num" "$stream_path"; then
                        ((streams_restarted++)) || true
                        log INFO "Successfully restarted stream $stream_path"
                    else
                        ((streams_failed++)) || true
                        log ERROR "Failed to restart stream $stream_path"
                    fi
                else
                    ((streams_failed++)) || true
                    log WARN "Stream $stream_path PID is invalid (cron mode: not restarting)"
                fi
                continue
            fi

            # Verify the PID actually belongs to our wrapper
            if pid_is_foreign_wrapper "$pid" "$stream_path"; then
                if should_restart_stream "$stream_path"; then
                    # v1.4.2: Check ALSA device availability before restart
                    if ! check_alsa_device_available "$card_num"; then
                        log WARN "Stream $stream_path: ALSA device not available (card $card_num), skipping restart"
                        ((streams_failed++)) || true
                        continue
                    fi
                    log WARN "Stream $stream_path PID $pid is stale - restarting"
                    rm -f "$pid_file"
                    if start_ffmpeg_stream "$device_name" "$card_num" "$stream_path"; then
                        ((streams_restarted++)) || true
                        log INFO "Successfully restarted stream $stream_path"
                    else
                        ((streams_failed++)) || true
                        log ERROR "Failed to restart stream $stream_path"
                    fi
                else
                    ((streams_failed++)) || true
                    log WARN "Stream $stream_path PID $pid is stale (cron mode: not restarting)"
                fi
                continue
            fi

            # Wrapper PID alive: shallow-healthy. Deep probe (H9): a path that
            # stays not-ready across consecutive checks while its wrapper is
            # alive is a hung FFmpeg or endless backoff -- restart it.
            if deep_stream_unhealthy "$stream_path"; then
                if should_restart_stream "$stream_path"; then
                    if ! check_alsa_device_available "$card_num"; then
                        log WARN "Stream $stream_path: ALSA device not available (card $card_num), skipping restart"
                        ((streams_failed++)) || true
                        continue
                    fi
                    log WARN "Stream $stream_path wrapper (PID $pid) is alive but path is not ready - restarting"
                    terminate_process_group "$pid" 5 || true
                    rm -f "$pid_file"
                    if start_ffmpeg_stream "$device_name" "$card_num" "$stream_path"; then
                        ((streams_restarted++)) || true
                        log INFO "Successfully restarted stream $stream_path"
                    else
                        ((streams_failed++)) || true
                        log ERROR "Failed to restart stream $stream_path"
                    fi
                else
                    ((streams_failed++)) || true
                    log WARN "Stream $stream_path is not ready (restart budget exhausted)"
                fi
                continue
            fi

            ((streams_healthy++)) || true
            log DEBUG "Stream $stream_path is healthy (PID: $pid)"
        done
    fi

    # Provide accurate summary
    if [[ $streams_failed -gt 0 ]]; then
        if [[ $streams_restarted -gt 0 ]]; then
            log WARN "Stream health check complete: $streams_healthy healthy, $streams_restarted restarted, $streams_failed FAILED (total: $streams_checked)"
        else
            log ERROR "Stream health check complete: $streams_healthy healthy, $streams_failed FAILED (total: $streams_checked)"
        fi
    elif [[ $streams_restarted -gt 0 ]]; then
        log INFO "Stream health check complete: $streams_healthy healthy, $streams_restarted restarted (total: $streams_checked)"
    else
        log INFO "Stream health check complete: all $streams_checked streams healthy"
    fi

    # Return appropriate exit code based on monitoring results
    if [[ -z "$mediamtx_pid" ]] || ! kill -0 "$mediamtx_pid" 2>/dev/null; then
        # MediaMTX not running - critical failure already logged
        return "${E_MEDIAMTX_DOWN}"
    elif [[ $streams_failed -gt 0 ]]; then
        # Some streams failed - degraded state
        return "${E_MONITOR_DEGRADED}"
    else
        # All healthy
        return 0
    fi
}

# Enhanced stream validation
validate_stream() {
    local stream_path="$1"
    local max_attempts="${2:-${STREAM_VALIDATION_ATTEMPTS}}"
    local attempt=0

    log DEBUG "Validating stream $stream_path"

    while [[ $attempt -lt $max_attempts ]]; do
        ((attempt++)) || true

        sleep "${STREAM_VALIDATION_DELAY}"

        # Try API validation if curl available
        # v1.4.2: Use API version detection for compatibility
        # v1.4.4: Restructured to preserve curl exit status for better error detection
        if command_exists curl; then
            local api_base api_response
            api_base=$(detect_mediamtx_api_version)
            local api_url="${api_base}/paths/get/${stream_path}"
            if api_response=$(curl -s --max-time 2 "${api_url}" 2>/dev/null) && mediamtx_json_path_ready "$api_response"; then
                log DEBUG "Stream $stream_path validated via API (attempt ${attempt})"
                return 0
            fi
        fi

        # Fallback to process check
        local pid_file="${FFMPEG_PID_DIR}/${stream_path}.pid"
        if [[ -f "$pid_file" ]]; then
            local pid
            pid="$(read_pid_safe "$pid_file")"
            if [[ -n "$pid" ]] && kill -0 "$pid" 2>/dev/null; then
                # Check if FFmpeg child exists
                if wrapper_has_ffmpeg_child "$pid"; then
                    log DEBUG "Stream $stream_path validated via process (attempt ${attempt})"
                    return 0
                fi
            fi
        fi
    done

    log WARN "Stream $stream_path failed validation after ${max_attempts} attempts"
    return 1
}

# Detect restart scenario
is_restart_scenario() {
    if [[ -f "${RESTART_MARKER}" ]]; then
        local marker_age
        marker_age="$(($(date +%s) - $(stat -c %Y "${RESTART_MARKER}" 2>/dev/null || echo 0)))"
        if [[ $marker_age -lt 60 ]]; then
            return 0
        fi
    fi

    # Processes of an earlier run of THIS manager that are still up, found by
    # identity. (The old test matched every process called mediamtx and every
    # RTSP FFmpeg on the host, so any other installation looked like a restart.)
    if owned_mediamtx_pid >/dev/null; then
        return 0
    fi
    local pid_file pid
    for pid_file in "${FFMPEG_PID_DIR}"/*.pid; do
        [[ -f "$pid_file" ]] || continue
        pid="$(read_pid_safe "$pid_file")"
        [[ -n "$pid" ]] || continue
        if ! pid_is_foreign_wrapper "$pid" "$(basename "$pid_file" .pid)"; then
            return 0
        fi
    done

    return 1
}

mark_restart() {
    touch "${RESTART_MARKER}"
}

clear_restart_marker() {
    rm -f "${RESTART_MARKER}"
}

# Clean up what is left of this manager's own processes and files, by identity
#
# Execution order (as implemented):
# 1. Wrapper processes (via PID files in FFMPEG_PID_DIR)
#    - Each recorded PID is signalled only if it is provably this manager's
#      wrapper (start time matches the record, a bash running that stream's
#      script): terminate_process_group with 5s timeout, which also stops the
#      wrapper's FFmpeg children
#    - A recorded PID that is something else (recycled) is NOT signalled; only
#      the stale record is dropped
#    - Deletes the PID files and their start-time records
# 2. MediaMTX process (via PID_FILE), under the same proof: the recorded PID, the
#    configured binary as its executable and the configuration file as argv[1]
#    - Calls terminate_process_group with 5s timeout
#    - Deletes the PID file and its record
# 3. Generated wrapper scripts whose wrapper is gone
# 4. Marker files
#    - Deletes: CLEANUP_MARKER, RESTART_MARKER
#    - Never deletes a lock file (LOCK_FILE, CONFIG_LOCK_FILE): the inode is the
#      lock, and removing it while another process holds it splits the lock
#
# No process is chosen by name or command-line pattern, so another
# installation's MediaMTX or FFmpeg, mediamtx.service's process or an operator's
# FFmpeg that reads a stream are never touched. The FFmpeg logs are kept: they
# are the post-mortem of the run that is being cleaned up (rotate_ffmpeg_log
# bounds them).
#
# start_mediamtx calls this only when it cannot prove that the MediaMTX it finds
# is its own and healthy, or on a restart; a healthy start changes nothing.
#
# Parameters:
#   $1 = seconds before SIGKILL (default 5; 0 = SIGKILL at once, for force-stop)
#
# Returns: 0 (always - best-effort cleanup)
#
# Side Effects:
#   - Terminates processes (wrappers, FFmpeg, MediaMTX) that are provably ours
#   - Deletes files (PID files, scripts, markers)
#   - Modifies nullglob shell option (saves and restores state)
#   - Logs INFO at start and completion, DEBUG for each operation
cleanup_stale_processes() {
    local timeout="${1:-5}"
    log INFO "Cleaning up stale processes and files"

    # Save and set nullglob
    local nullglob_state
    shopt -q nullglob && nullglob_state=on || nullglob_state=off
    shopt -s nullglob

    # Clean up wrapper scripts (and their FFmpeg children)
    local pid_file script
    for pid_file in "${FFMPEG_PID_DIR}"/*.pid; do
        if [[ -f "$pid_file" ]]; then
            stop_recorded_process "$pid_file" wrapper "$timeout" "$(basename "$pid_file" .pid)" || true
        fi
    done

    # Clean up MediaMTX
    stop_recorded_process "${PID_FILE}" mediamtx "$timeout" || true

    # Records whose PID file is gone, and the generated scripts of wrappers that
    # are gone (a wrapper that could not be identified keeps both)
    for pid_file in "${FFMPEG_PID_DIR}"/*.pid.id; do
        [[ -e "${pid_file%.id}" ]] || rm -f -- "$pid_file"
    done
    for script in "${FFMPEG_PID_DIR}"/*.sh; do
        [[ -e "${script%.sh}.pid" ]] || rm -f -- "$script"
    done

    # Clean up markers
    rm -f "${CLEANUP_MARKER}"
    rm -f "${RESTART_MARKER}"

    # Restore nullglob only if it was originally off (avoids redundant shopt -s)
    [[ "$nullglob_state" == "off" ]] && shopt -u nullglob

    log INFO "Cleanup completed"
}

# Print one line per process of this installation, found by what it runs or
# writes, never by its name: `<pid> <starttime> <kind> <why>`. Used by
# `force-stop --kill-all` (the preview and the kill) and the cleanup check.
# kind is
#   mediamtx  the executable is the configured MediaMTX binary
#   wrapper   an argument is a path inside the wrapper directory
#   ffmpeg    an FFmpeg that writes its log into the wrapper directory, or any
#             other child of such a wrapper
# The calling process and its ancestors are never listed.
scan_instance_processes() {
    local dir pid ppid start state arg base want_exe log_file
    local REPLY
    local -a fields
    local -A seen=() kids=() starts=() kinds=() whys=()
    want_exe="$(_canon_path "${MEDIAMTX_BIN}")"

    # This process, its subshell and every ancestor
    pid="$$"
    while [[ -n "$pid" && "$pid" != "0" && "$pid" != "1" ]]; do
        seen[$pid]=1
        pid="$(_proc_stat_field "$pid" 1)" || break
    done
    seen[${BASHPID}]=1

    for dir in /proc/[0-9]*; do
        pid="${dir#/proc/}"
        [[ -z "${seen[$pid]:-}" ]] || continue
        _proc_stat_rest "$pid" || continue
        read -ra fields <<<"$REPLY"
        state="${fields[0]}"
        [[ "$state" != "Z" && "$state" != "X" ]] || continue
        ppid="${fields[1]}"
        start="${fields[19]:-0}"
        starts[$pid]="$start"
        kids[$ppid]+="${pid} "
        proc_load_argv "$pid" || continue
        [[ ${#PROC_ARGV[@]} -gt 0 ]] || continue
        base="${PROC_ARGV[0]##*/}"

        if [[ "/proc/${pid}/exe" -ef "${MEDIAMTX_BIN}" ]] \
            || { [[ "$base" == "${MEDIAMTX_BIN##*/}" ]] && [[ "$(proc_exe "$pid")" == "$want_exe" ]]; }; then
            kinds[$pid]="mediamtx"
            whys[$pid]="its executable is the configured MediaMTX binary ${MEDIAMTX_BIN}"
            continue
        fi
        for arg in "${PROC_ARGV[@]}"; do
            if [[ "$arg" == "${FFMPEG_PID_DIR}/"* ]]; then
                kinds[$pid]="wrapper"
                whys[$pid]="its command line names ${arg}, in this installation's wrapper directory ${FFMPEG_PID_DIR}"
                break
            fi
        done
        [[ -z "${kinds[$pid]:-}" ]] || continue
        if [[ "$base" == "ffmpeg" ]]; then
            for log_file in "${FFMPEG_PID_DIR}"/*.log; do
                if [[ "/proc/${pid}/fd/1" -ef "$log_file" || "/proc/${pid}/fd/2" -ef "$log_file" ]]; then
                    kinds[$pid]="ffmpeg"
                    whys[$pid]="FFmpeg writing its log ${log_file} in this installation's wrapper directory"
                    break
                fi
            done
        fi
    done

    [[ ${#kinds[@]} -gt 0 ]] || return 0

    # Everything below a wrapper goes with it
    local wrapper_pid child head
    local -a queue
    for wrapper_pid in "${!kinds[@]}"; do
        [[ "${kinds[$wrapper_pid]}" == "wrapper" ]] || continue
        queue=("$wrapper_pid")
        head=0
        while ((head < ${#queue[@]})); do
            pid="${queue[head]}"
            ((head++)) || true
            for child in ${kids[$pid]:-}; do
                [[ -z "${kinds[$child]:-}" ]] || continue
                kinds[$child]="ffmpeg"
                whys[$child]="child of wrapper ${wrapper_pid}"
                queue+=("$child")
            done
        done
    done

    for pid in "${!kinds[@]}"; do
        printf '%s %s %s %s\n' "$pid" "${starts[$pid]}" "${kinds[$pid]}" "${whys[$pid]}"
    done | sort -n
}

# Wait for USB stabilization
wait_for_usb_stabilization() {
    local max_wait="${1:-${USB_STABILIZATION_DELAY}}"
    local stable_count_needed=2
    local stable_count=0
    local last_device_hash=""
    local elapsed=0

    log INFO "Waiting for USB audio subsystem to stabilize (max ${max_wait}s)..."

    while [[ $elapsed -lt $max_wait ]]; do
        local current_device_hash
        current_device_hash="$(detect_audio_devices | sort | compute_hash)"

        if [[ "$current_device_hash" == "$last_device_hash" ]] && [[ -n "$current_device_hash" ]]; then
            ((stable_count++)) || true
            if [[ $stable_count -ge $stable_count_needed ]]; then
                local device_count
                device_count="$(detect_audio_devices | wc -l)"
                log INFO "USB audio subsystem stable with $device_count devices"
                return 0
            fi
        else
            stable_count=0
            last_device_hash="$current_device_hash"
        fi

        sleep "$MEDIUM_SLEEP"
        ((elapsed += 2))
    done

    local device_count
    device_count="$(detect_audio_devices | wc -l)"
    if [[ $device_count -gt 0 ]]; then
        log WARN "USB stabilization timeout, proceeding with $device_count devices"
        return 0
    else
        log ERROR "No USB audio devices detected after ${max_wait} seconds"
        return 1
    fi
}

# Wait for MediaMTX API
wait_for_mediamtx_ready() {
    local pid="$1"
    local max_wait="${MEDIAMTX_API_TIMEOUT}"
    local elapsed=0

    log INFO "Waiting for MediaMTX to become ready..."

    while [[ $elapsed -lt $max_wait ]]; do
        if ! kill -0 "$pid" 2>/dev/null; then
            log ERROR "MediaMTX process died during startup"
            return 1
        fi

        if command_exists curl; then
            # v1.4.2: Try multiple API versions for compatibility
            for api_version in v3 v2 v1 ""; do
                local test_url="http://${MEDIAMTX_HOST}:9997/${api_version:+$api_version/}paths/list"
                if curl -s --max-time 2 "$test_url" >/dev/null 2>&1; then
                    log INFO "MediaMTX API is ready after ${elapsed} seconds (API: ${api_version:-legacy})"
                    return 0
                fi
            done
        else
            # Fallback: just check if process is running
            if [[ $elapsed -ge 10 ]]; then
                log INFO "MediaMTX assumed ready (curl not available)"
                return 0
            fi
        fi

        sleep 1
        ((elapsed++)) || true

        if [[ $((elapsed % 5)) -eq 0 ]]; then
            log DEBUG "Still waiting for MediaMTX API... (${elapsed}s/${max_wait}s)"
        fi
    done

    log ERROR "MediaMTX API did not become ready within ${max_wait} seconds"
    return 1
}

# Device configuration
load_device_config() {
    [[ -f "${DEVICE_CONFIG_FILE}" ]] || return 0

    # A device config truncated by a power loss mid-write, corrupted by SD-card
    # bit-rot, or fat-fingered by an operator would otherwise be `source`d
    # directly: a syntax error then aborts the WHOLE run under errexit, so
    # `start` fails and NO streams come up on the next unattended boot -- a
    # total outage triggered by one bad line. Validate syntax first and, on
    # failure, fall back to built-in defaults (degrade, don't die).
    if ! bash -n "${DEVICE_CONFIG_FILE}" 2>/dev/null; then
        log ERROR "Device config ${DEVICE_CONFIG_FILE} is corrupt (syntax error); ignoring it and using defaults"
        return 0
    fi

    # Even syntactically valid config is sourced defensively: a `set -e`/command
    # inside it must not abort or hang the manager. Source in the current shell
    # (values must persist) but neutralise errexit for the duration.
    local _had_errexit=0
    [[ $- == *e* ]] && _had_errexit=1
    set +e
    # shellcheck source=/dev/null
    source "${DEVICE_CONFIG_FILE}"
    local _src_rc=$?
    [[ $_had_errexit -eq 1 ]] && set -e
    if [[ $_src_rc -ne 0 ]]; then
        log WARN "Device config ${DEVICE_CONFIG_FILE} raised errors while loading (rc=${_src_rc}); continuing with whatever loaded plus defaults"
    fi
    return 0
}

save_device_config() {
    local tmp_config
    tmp_config="$(mktemp -p "$(dirname "${DEVICE_CONFIG_FILE}")" "$(basename "${DEVICE_CONFIG_FILE}").XXXXXX")"

    cat >"$tmp_config" <<'EOF'
# Audio device configuration
# Format: DEVICE_<name>_<parameter>=value
#
# You can use either:
#   1. Friendly stream names (e.g., DEVICE_BLUE_YETI_SAMPLE_RATE=44100)
#   2. Full device names (e.g., DEVICE_USB_AUDIO_BLUE_YETI_SAMPLE_RATE=44100)
#
# Friendly names are recommended and match the RTSP stream paths.

# Universal defaults:
# - Sample Rate: 48000 Hz
# - Channels: 2 (stereo)
# - Format: s16le (16-bit little-endian)
# - Codec: opus
# - Bitrate: 128k

# Example overrides using friendly names:
# DEVICE_BLUE_YETI_SAMPLE_RATE=44100
# DEVICE_BLUE_YETI_CHANNELS=1
# DEVICE_BLUE_YETI_CODEC=pcm_s16le
# DEVICE_BLUE_YETI_BITRATE=256k
EOF

    mv -f "$tmp_config" "${DEVICE_CONFIG_FILE}"
    chmod 644 "${DEVICE_CONFIG_FILE}"
}

sanitize_device_name() {
    local name="$1"
    local sanitized
    sanitized=$(printf '%s' "$name" | sed 's/[^a-zA-Z0-9]/_/g; s/__*/_/g; s/^_//; s/_$//')

    if [[ "$sanitized" =~ ^[0-9] ]]; then
        sanitized="dev_${sanitized}"
    fi

    if [[ -z "$sanitized" ]]; then
        sanitized="unknown_device_$(date +%s)"
    fi

    printf '%s\n' "$sanitized"
}

# Sanitize device name for RTSP path usage
#
# Transformation sequence:
# 1. Strips prefixes: "usb-audio-" and "usb_audio_"
# 2. Converts to lowercase
# 3. Replaces non-alphanumeric characters with underscore
# 4. Collapses multiple consecutive underscores to single underscore
# 5. Removes leading and trailing underscores
# 6. If result is empty: generates "stream_$(date +%s)"
# 7. If matches reserved words: prefixes with "stream_"
# 8. If exceeds MAX_STREAM_NAME_LENGTH: truncates and appends 8-char hash
# 9. If below MIN_STREAM_NAME_LENGTH: replaces with "stream_$(date +%s)"
#
# Parameters:
#   $1 = Raw device name (e.g., "USB Audio Device #1")
#
# Returns:
#   stdout: Sanitized path name (lowercase alphanumeric + underscore only)
#   exit: 0 (always)
#
# Examples (observable from code logic):
#   "USB Audio Device" -> "usb_audio_device"
#   "Device-123" -> "device_123"
#   "   " (spaces only) -> "stream_1699564821" (timestamp fallback)
#   Reserved word -> "stream_<reserved>" (prefixed)
#   Very long name -> "truncated_name_a1b2c3d4" (with hash)
sanitize_path_name() {
    local name="$1"
    name="${name#usb-audio-}"
    name="${name#usb_audio_}"
    local sanitized
    sanitized="$(echo "$name" | tr '[:upper:]' '[:lower:]' | sed 's/[^0-9a-z]/_/g' | sed 's/__*/_/g' | sed 's/^_*//;s/_*$//')"

    # Generate fallback if empty
    if [[ -z "$sanitized" ]]; then
        sanitized="stream_$(date +%s)"
    fi

    # Check reserved words
    if [[ "$sanitized" =~ ^(${RESERVED_STREAM_NAMES})$ ]]; then
        log WARN "Stream name '$sanitized' is reserved, adding prefix"
        sanitized="stream_${sanitized}"
    fi

    # Enforce length limits
    if [[ ${#sanitized} -gt $MAX_STREAM_NAME_LENGTH ]]; then
        local hash
        hash="$(echo -n "$sanitized" | md5sum | cut -c1-8)"
        sanitized="${sanitized:0:$((MAX_STREAM_NAME_LENGTH - 9))}_${hash}"
        log DEBUG "Truncated long stream name to: $sanitized"
    fi

    if [[ ${#sanitized} -lt $MIN_STREAM_NAME_LENGTH ]]; then
        sanitized="stream_$(date +%s)"
        log WARN "Stream name too short, using fallback: $sanitized"
    fi

    echo "$sanitized"
}

get_device_config() {
    local device_name="$1"
    local param="$2"
    local default_value="$3"
    local stream_path="${4:-}" # Optional friendly stream path

    local config_value=""

    # Strategy 1: Try friendly stream name first (if provided)
    if [[ -n "$stream_path" ]]; then
        local friendly_name
        friendly_name="$(sanitize_device_name "$stream_path")"
        local friendly_key="DEVICE_${friendly_name^^}_${param^^}"

        if [[ -n "${!friendly_key+x}" ]]; then
            config_value="${!friendly_key}"
        fi
    fi

    # Strategy 2: Fall back to full device name
    if [[ -z "$config_value" ]]; then
        local safe_name
        safe_name="$(sanitize_device_name "$device_name")"
        local device_key="DEVICE_${safe_name^^}_${param^^}"

        if [[ -n "${!device_key+x}" ]]; then
            config_value="${!device_key}"
        fi
    fi

    # Strategy 3: Return default if no match
    if [[ -z "$config_value" ]]; then
        config_value="$default_value"
    fi

    echo "$config_value"
}

# Detect USB audio devices
detect_audio_devices() {
    local devices=()
    local retry_count=0
    local max_retries=3

    while [[ $retry_count -lt $max_retries ]]; do
        devices=()

        if [[ -d /dev/snd/by-id ]]; then
            for device in /dev/snd/by-id/*; do
                if [[ -L "$device" ]] && [[ "$device" != *"-event-"* ]]; then
                    local device_name
                    device_name="$(basename "$device")"

                    local target
                    target="$(readlink -f "$device")"
                    if [[ "$target" =~ controlC([0-9]+) ]]; then
                        local card_num="${BASH_REMATCH[1]}"

                        if [[ -f "/proc/asound/card${card_num}/usbid" ]]; then
                            devices+=("${device_name}:${card_num}")
                        fi
                    fi
                fi
            done
        fi

        # If we found devices or this is our last retry, break
        if [[ ${#devices[@]} -gt 0 ]] || [[ $retry_count -eq $((max_retries - 1)) ]]; then
            break
        fi

        # Wait a bit before retry
        sleep 0.5
        ((retry_count++)) || true
    done

    # Fallback to /proc/asound/cards if no devices found
    if [[ ${#devices[@]} -eq 0 ]] && [[ -f /proc/asound/cards ]]; then
        while IFS= read -r line || [[ -n "$line" ]]; do
            if [[ "$line" =~ ^[[:space:]]*([0-9]+)[[:space:]]+\[([^]]+)\] ]]; then
                local card_num="${BASH_REMATCH[1]}"
                local card_name="${BASH_REMATCH[2]}"
                if [[ -f "/proc/asound/card${card_num}/usbid" ]]; then
                    local safe_name
                    safe_name="$(echo "$card_name" | tr '[:upper:]' '[:lower:]' | tr ' ' '-' | tr -cd 'a-z0-9-')"
                    if [[ -n "$safe_name" ]]; then
                        devices+=("usb-audio-${safe_name}:${card_num}")
                    fi
                fi
            fi
        done </proc/asound/cards
    fi

    if [[ ${#devices[@]} -gt 0 ]]; then
        printf '%s\n' "${devices[@]}"
    fi
}

# Check audio device availability
check_audio_device() {
    local card_num="$1"

    if [[ ! -e "/dev/snd/pcmC${card_num}D0c" ]]; then
        return 1
    fi

    # Use a simple existence check instead of opening the device
    if arecord -l 2>/dev/null | grep -q "card ${card_num}:"; then
        return 0
    fi

    return 1
}

# Generate stream path
generate_stream_path() {
    local device_name="$1"
    local card_num="${2:-}"
    local base_path=""

    if [[ -n "$card_num" ]] && [[ -f "/proc/asound/cards" ]]; then
        local card_info
        card_info=$(grep -E "^ *${card_num} " /proc/asound/cards 2>/dev/null || true)

        if [[ -n "$card_info" ]]; then
            if [[ "$card_info" =~ \[([^]]+)\] ]]; then
                local card_name="${BASH_REMATCH[1]}"
                card_name="$(echo "$card_name" | xargs)"

                if [[ "$card_name" =~ ^[a-z][a-z0-9_-]{0,31}$ ]]; then
                    base_path="$card_name"
                fi
            fi
        fi
    fi

    if [[ -z "$base_path" ]]; then
        base_path="$(sanitize_path_name "$device_name")"
    fi

    if [[ ! "$base_path" =~ ^[a-zA-Z][a-zA-Z0-9_-]*$ ]]; then
        base_path="stream_${base_path}"
    fi

    if [[ ${#base_path} -gt 64 ]]; then
        base_path="${base_path:0:64}"
    fi

    echo "$base_path"
}

# Start FFmpeg multiplex stream (single stream from multiple devices)
start_ffmpeg_multiplex_stream() {
    local -a devices=("$@")

    if [[ ${#devices[@]} -eq 0 ]]; then
        log ERROR "No devices provided for multiplex stream"
        return 1
    fi

    # Sanitize stream name to prevent RTSP URL parsing failures
    local stream_path
    stream_path="$(sanitize_path_name "${MULTIPLEX_STREAM_NAME}")"

    # Ensure stream name doesn't start with a digit
    if [[ "$stream_path" =~ ^[0-9] ]]; then
        stream_path="stream_${stream_path}"
    fi

    # Validate final stream name
    if [[ ${#stream_path} -gt $MAX_STREAM_NAME_LENGTH ]]; then
        log ERROR "Stream name too long after sanitization: $stream_path (max: $MAX_STREAM_NAME_LENGTH)"
        return 1
    fi

    if [[ "$stream_path" =~ ^(${RESERVED_STREAM_NAMES})$ ]]; then
        log ERROR "Stream name '$stream_path' conflicts with reserved MediaMTX path"
        return 1
    fi

    local pid_file="${FFMPEG_PID_DIR}/${stream_path}.pid"

    # Check if already running
    if [[ -f "$pid_file" ]]; then
        local existing_pid
        existing_pid="$(read_pid_safe "$pid_file")"
        if [[ -n "$existing_pid" ]] && kill -0 "$existing_pid" 2>/dev/null; then
            # Verify PID actually belongs to our wrapper script
            if ! pid_is_foreign_wrapper "$existing_pid" "$stream_path"; then
                log DEBUG "Multiplex stream $stream_path already running"
                return 0
            else
                log WARN "Stale PID file for $stream_path (PID $existing_pid is not our wrapper)"
                rm -f "$pid_file"
            fi
        fi
    fi

    # Validate filter type
    if [[ "${MULTIPLEX_FILTER_TYPE}" != "amix" ]] && [[ "${MULTIPLEX_FILTER_TYPE}" != "amerge" ]]; then
        log ERROR "Invalid MULTIPLEX_FILTER_TYPE: ${MULTIPLEX_FILTER_TYPE}. Must be 'amix' or 'amerge'"
        return 1
    fi

    # Build device array and validate all devices
    local -a valid_devices=()
    local -a card_numbers=()
    local -a device_names=()

    for device_info in "${devices[@]}"; do
        IFS=':' read -r device_name card_num <<<"$device_info"

        if [[ -z "$device_name" ]] || [[ -z "$card_num" ]]; then
            log WARN "Skipping invalid device info: $device_info"
            continue
        fi

        if ! check_audio_device "$card_num"; then
            log WARN "Audio device card ${card_num} is not accessible, skipping"
            continue
        fi

        valid_devices+=("$device_info")
        card_numbers+=("$card_num")
        device_names+=("$device_name")
    done

    if [[ ${#valid_devices[@]} -eq 0 ]]; then
        log ERROR "No valid audio devices available for multiplex stream"
        return 1
    fi

    log INFO "Starting multiplex FFmpeg stream with ${#valid_devices[@]} devices (filter: ${MULTIPLEX_FILTER_TYPE})"

    # Get audio configuration from first device (all devices should match)
    local first_device="${device_names[0]}"
    local sample_rate channels codec bitrate thread_queue
    sample_rate="$(get_device_config "$first_device" "SAMPLE_RATE" "$DEFAULT_SAMPLE_RATE" "$stream_path")"
    channels="$(get_device_config "$first_device" "CHANNELS" "$DEFAULT_CHANNELS" "$stream_path")"
    codec="$(get_device_config "$first_device" "CODEC" "$DEFAULT_CODEC" "$stream_path")"
    bitrate="$(get_device_config "$first_device" "BITRATE" "$DEFAULT_BITRATE" "$stream_path")"
    thread_queue="$(get_device_config "$first_device" "THREAD_QUEUE" "$DEFAULT_THREAD_QUEUE" "$stream_path")"

    # Create wrapper script
    local wrapper_script="${FFMPEG_PID_DIR}/${stream_path}.sh"
    local ffmpeg_log="${FFMPEG_PID_DIR}/${stream_path}.log"
    rotate_ffmpeg_log "$ffmpeg_log"

    # Create wrapper with all variables properly quoted
    cat >"$wrapper_script" <<'WRAPPER_START'
#!/bin/bash
set -euo pipefail

# Ensure PATH includes common binary locations
export PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin:$PATH"

WRAPPER_START

    # Write configuration variables
    cat >>"$wrapper_script" <<EOF
# Stream Configuration
STREAM_PATH="$stream_path"
SAMPLE_RATE="$sample_rate"
CHANNELS="$channels"
BITRATE="$bitrate"
THREAD_QUEUE="$thread_queue"
ANALYZEDURATION="$DEFAULT_ANALYZEDURATION"
PROBESIZE="$DEFAULT_PROBESIZE"
CODEC="$codec"
FILTER_TYPE="${MULTIPLEX_FILTER_TYPE}"

# File paths
FFMPEG_LOG="$ffmpeg_log"
LOG_FILE="$LOG_FILE"
WRAPPER_PID_FILE="$pid_file"
CLEANUP_MARKER="$CLEANUP_MARKER"
MEDIAMTX_HOST="$MEDIAMTX_HOST"

# Restart configuration
RESTART_COUNT=0
CONSECUTIVE_FAILURES=0
MAX_CONSECUTIVE_FAILURES=$MAX_CONSECUTIVE_FAILURES
MAX_WRAPPER_RESTARTS=$MAX_WRAPPER_RESTARTS
WRAPPER_SUCCESS_DURATION=$WRAPPER_SUCCESS_DURATION
RESTART_DELAY=$INITIAL_RESTART_DELAY
FFMPEG_LOG_MAX_SIZE=$FFMPEG_LOG_MAX_SIZE

# Device arrays (initialized empty, populated below)
declare -a CARD_NUMBERS=()
declare -a DEVICE_NAMES=()

FFMPEG_PID=""
MAIN_SCRIPT_PID="$$"
EOF

    # Populate arrays with proper quoting to handle spaces in device names
    for i in "${!card_numbers[@]}"; do
        cat >>"$wrapper_script" <<EOF
CARD_NUMBERS+=("${card_numbers[$i]}")
DEVICE_NAMES+=("${device_names[$i]}")
EOF
    done

    # Add device count after arrays are populated
    cat >>"$wrapper_script" <<EOF

# Number of devices
NUM_DEVICES=${#valid_devices[@]}
EOF

    # Add the wrapper logic
    cat >>"$wrapper_script" <<'WRAPPER_LOGIC'

# Create log file if it doesn't exist
touch "${FFMPEG_LOG}" 2>/dev/null || true

log_message() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] [MULTIPLEX-WRAPPER] $1" >> "${FFMPEG_LOG}" 2>/dev/null || true
}

log_critical() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] [STREAM:${STREAM_PATH}] $1" >> "${LOG_FILE}" 2>/dev/null || true
}

# Monotonic seconds since boot for run-time/backoff math. Wall-clock deltas
# break on NTP steps (an RTC-less Pi can jump years when it first gets
# network): a healthy multi-hour run would measure negative and count as a
# consecutive failure, eventually killing the wrapper on a healthy stream.
now_s() {
    local up
    if [[ -r /proc/uptime ]]; then
        read -r up _ < /proc/uptime
        printf '%s' "${up%%.*}"
    else
        date +%s
    fi
}

# Cleanup handler
cleanup_wrapper() {
    local exit_code=$?
    log_message "Wrapper cleanup initiated (exit code: $exit_code)"
    
    # Atomic check and kill
    local ffmpeg_pid="${FFMPEG_PID:-}"
    if [[ -n "$ffmpeg_pid" ]]; then
        if kill -0 "$ffmpeg_pid" 2>/dev/null; then
            log_message "Sending SIGINT to FFmpeg process ${ffmpeg_pid}"
            kill -INT "$ffmpeg_pid" 2>/dev/null || true
            
            # Wait briefly for termination
            local term_wait=0
            while kill -0 "$ffmpeg_pid" 2>/dev/null && [[ $term_wait -lt 5 ]]; do
                sleep 0.2
                ((term_wait++)) || true
            done
            
            # Force kill if still running
            if kill -0 "$ffmpeg_pid" 2>/dev/null; then
                kill -KILL "$ffmpeg_pid" 2>/dev/null || true
            fi
        fi
    fi
    
    rm -f "${WRAPPER_PID_FILE}"
    log_critical "Multiplex stream wrapper terminated for ${STREAM_PATH}"
    exit "$exit_code"
}

trap cleanup_wrapper EXIT INT TERM

# Run FFmpeg with multiplex configuration
run_ffmpeg() {
    log_message "Starting FFmpeg with ${NUM_DEVICES} devices (filter: ${FILTER_TYPE})"
    
    # Build command array to handle spaces properly
    local ffmpeg_cmd=(
        ffmpeg
        -hide_banner
        -loglevel warning
    )
    
    # Add input for each device
    for i in "${!CARD_NUMBERS[@]}"; do
        local card_num="${CARD_NUMBERS[$i]}"
        local audio_device="plughw:${card_num},0"
        
        log_message "Adding input $((i+1))/${NUM_DEVICES}: ${DEVICE_NAMES[$i]} (card ${card_num})"
        
        ffmpeg_cmd+=(
            -analyzeduration "${ANALYZEDURATION}"
            -probesize "${PROBESIZE}"
            -f alsa
            -ar "${SAMPLE_RATE}"
            -ac "${CHANNELS}"
            -thread_queue_size "${THREAD_QUEUE}"
            -i "${audio_device}"
        )
    done
    
    # Build filter complex based on filter type
    if [[ "${FILTER_TYPE}" == "amix" ]]; then
        # Mix all audio inputs into a single output
        # Create input labels [0:a][1:a][2:a]... and use amix filter
        local filter_inputs=""
        for i in "${!CARD_NUMBERS[@]}"; do
            filter_inputs+="[${i}:a]"
        done
        
        local filter_complex="${filter_inputs}amix=inputs=${NUM_DEVICES}:duration=longest:normalize=0,aresample=async=1:first_pts=0"
        ffmpeg_cmd+=(-filter_complex "$filter_complex")
        
        log_message "Using amix filter to mix ${NUM_DEVICES} audio streams"
        
    elif [[ "${FILTER_TYPE}" == "amerge" ]]; then
        # Merge all audio inputs keeping channels separate
        # This creates a single stream with (NUM_DEVICES * CHANNELS) channels
        local filter_inputs=""
        for i in "${!CARD_NUMBERS[@]}"; do
            filter_inputs+="[${i}:a]"
        done
        
        local filter_complex="${filter_inputs}amerge=inputs=${NUM_DEVICES},aresample=async=1:first_pts=0"
        ffmpeg_cmd+=(-filter_complex "$filter_complex")
        
        log_message "Using amerge filter to merge ${NUM_DEVICES} audio streams"
    else
        log_message "ERROR: Invalid filter type: ${FILTER_TYPE}"
        return 1
    fi
    
    # Add codec options based on codec type
    case "${CODEC}" in
        opus)
            ffmpeg_cmd+=(-c:a libopus -b:a "${BITRATE}" -application audio)
            ;;
        aac)
            ffmpeg_cmd+=(-c:a aac -b:a "${BITRATE}")
            ;;
        mp3)
            ffmpeg_cmd+=(-c:a libmp3lame -b:a "${BITRATE}")
            ;;
        *)
            ffmpeg_cmd+=(-c:a libopus -b:a "${BITRATE}")
            ;;
    esac
    
    # Add output options
    ffmpeg_cmd+=(
        -f rtsp
        -rtsp_transport tcp
        "rtsp://${MEDIAMTX_HOST}:8554/${STREAM_PATH}"
    )
    
    # Log the complete command for debugging
    log_message "FFmpeg command: ${ffmpeg_cmd[*]}"
    
    # Rotate log if exceeds size limit to prevent disk exhaustion
    if [[ -f "${FFMPEG_LOG}" ]]; then
        local current_size
        current_size=$(stat -c %s "${FFMPEG_LOG}" 2>/dev/null || echo 0)
        if (( current_size > FFMPEG_LOG_MAX_SIZE )); then
            log_message "Rotating FFmpeg log (current size: ${current_size} bytes, max: ${FFMPEG_LOG_MAX_SIZE})"
            mv -f "${FFMPEG_LOG}" "${FFMPEG_LOG}.old" 2>/dev/null || true
            # Note: FFmpeg will automatically create new log file on next write
        fi
    fi
    
    # Start FFmpeg with proper process group
    if command -v setsid &>/dev/null; then
        setsid "${ffmpeg_cmd[@]}" >> "${FFMPEG_LOG}" 2>&1 &
        FFMPEG_PID=$!
    else
        "${ffmpeg_cmd[@]}" >> "${FFMPEG_LOG}" 2>&1 &
        FFMPEG_PID=$!
    fi
    
    # Validate FFmpeg process started
    sleep 0.5
    if ! kill -0 "$FFMPEG_PID" 2>/dev/null; then
        log_message "ERROR: FFmpeg failed to start"
        if [[ -f "${FFMPEG_LOG}" ]]; then
            log_message "Last output: $(tail -n 5 "${FFMPEG_LOG}" 2>/dev/null | tr '\n' ' ')"
        fi
        FFMPEG_PID=""
        return 1
    fi
    
    log_message "Started multiplex FFmpeg with PID ${FFMPEG_PID}"
    return 0
}

check_devices_exist() {
    for card_num in "${CARD_NUMBERS[@]}"; do
        if [[ ! -e "/dev/snd/pcmC${card_num}D0c" ]]; then
            log_message "Device card ${card_num} no longer exists"
            return 1
        fi
    done
    return 0
}

# Check if parent is still alive
check_parent_alive() {
    # Intentionally a no-op. MAIN_SCRIPT_PID is the transient launcher process,
    # which exits BY DESIGN after starting the wrappers (start_mediamtx returns
    # and the systemd unit is Type=forking). Tying wrapper lifetime to it made
    # every wrapper exit shortly after boot, defeating auto-restart entirely.
    # Graceful shutdown is handled by the CLEANUP_MARKER check in the loop and by
    # `stop` terminating the wrapper process groups directly; an abnormal launcher
    # exit creates CLEANUP_MARKER, which also stops the wrappers. Kept as a
    # function (rather than deleting call sites) to minimise churn in the
    # generated wrapper.
    return 0
}

# Log startup
log_critical "Multiplex stream wrapper starting for ${STREAM_PATH} with ${NUM_DEVICES} devices"
log_message "Wrapper PID: $$, Main script PID: ${MAIN_SCRIPT_PID}"
log_message "Filter type: ${FILTER_TYPE}"

# Main restart loop
while true; do
    # Check parent is alive
    if ! check_parent_alive; then
        break
    fi
    
    if [[ -f "${CLEANUP_MARKER}" ]]; then
        log_message "Cleanup in progress, stopping wrapper"
        break
    fi
    
    if ! check_devices_exist; then
        log_message "One or more devices no longer exist"
        break
    fi
    
    if [[ $CONSECUTIVE_FAILURES -ge $MAX_CONSECUTIVE_FAILURES ]]; then
        log_message "Too many consecutive failures ($CONSECUTIVE_FAILURES)"
        break
    fi
    
    if [[ $RESTART_COUNT -ge $MAX_WRAPPER_RESTARTS ]]; then
        log_message "Max restarts reached ($RESTART_COUNT)"
        break
    fi
    
    log_message "Starting FFmpeg (attempt #$((RESTART_COUNT + 1)))"
    
    START_TIME=$(now_s)
    
    if ! run_ffmpeg; then
        log_message "Failed to start FFmpeg"
        ((CONSECUTIVE_FAILURES++)) || true
        # Protect against integer overflow in restart delay
        if (( RESTART_DELAY <= 0 )) || (( RESTART_DELAY > MAX_RESTART_DELAY )); then
            RESTART_DELAY=$INITIAL_RESTART_DELAY
        else
            RESTART_DELAY=$((RESTART_DELAY * 2))
            if (( RESTART_DELAY > MAX_RESTART_DELAY )); then
                RESTART_DELAY=$MAX_RESTART_DELAY
            fi
        fi
        sleep $RESTART_DELAY
        continue
    fi
    
    # Wait for FFmpeg to exit.
    # NOTE: capture the status with `|| exit_code=$?`. A bare `wait` returns
    # FFmpeg's (usually non-zero) exit status and, under `set -euo pipefail`,
    # errexit would kill the wrapper HERE -- before the restart/backoff logic
    # below -- so streams never auto-restarted after a failure.
    exit_code=0
    wait "${FFMPEG_PID}" 2>/dev/null || exit_code=$?
    
    FFMPEG_PID=""
    
    END_TIME=$(now_s)
    RUN_TIME=$((END_TIME - START_TIME))
    
    log_message "FFmpeg exited with code ${exit_code} after ${RUN_TIME} seconds"
    
    ((RESTART_COUNT++)) || true
    
    # Reset failures and delay if ran successfully
    if [[ ${RUN_TIME} -gt ${WRAPPER_SUCCESS_DURATION} ]]; then
        # A run longer than WRAPPER_SUCCESS_DURATION is "healthy": reset BOTH the
        # consecutive-failure counter AND the restart odometer. RESTART_COUNT was
        # previously never reset, making MAX_WRAPPER_RESTARTS a LIFETIME cap
        # rather than a rate -- so benign restarts (USB re-enumeration, MediaMTX
        # blips) accumulated over weeks until the wrapper gave up for good and the
        # stream died silently on an unattended box.
        CONSECUTIVE_FAILURES=0
        RESTART_COUNT=0
        RESTART_DELAY=$INITIAL_RESTART_DELAY
        log_message "Successful run, reset delay to ${RESTART_DELAY}s"
    else
        ((CONSECUTIVE_FAILURES++)) || true
        # Protect against integer overflow in restart delay
        if (( RESTART_DELAY <= 0 )) || (( RESTART_DELAY > MAX_RESTART_DELAY )); then
            RESTART_DELAY=$INITIAL_RESTART_DELAY
        else
            RESTART_DELAY=$((RESTART_DELAY * 2))
            if (( RESTART_DELAY > MAX_RESTART_DELAY )); then
                RESTART_DELAY=$MAX_RESTART_DELAY
            fi
        fi
    fi
    
    # Check parent before sleeping
    if ! check_parent_alive; then
        break
    fi
    
    log_message "Waiting ${RESTART_DELAY}s before restart (failures: $CONSECUTIVE_FAILURES)"
    sleep ${RESTART_DELAY}
done

log_message "Wrapper exiting for ${STREAM_PATH}"
WRAPPER_LOGIC

    chmod +x "$wrapper_script"

    # Check wrapper script was created properly
    if [[ ! -x "$wrapper_script" ]]; then
        log ERROR "Failed to create executable wrapper script"
        return 1
    fi

    # Validate wrapper script syntax
    if ! bash -n "$wrapper_script" 2>/dev/null; then
        log ERROR "Wrapper script has syntax errors"
        return 1
    fi

    # Start wrapper with process group using setsid if available
    log DEBUG "Starting multiplex wrapper script: $wrapper_script"
    if command_exists setsid; then
        spawn_detached nohup setsid bash "$wrapper_script" >/dev/null 2>&1 &
    else
        spawn_detached nohup bash "$wrapper_script" >/dev/null 2>&1 &
    fi

    local wrapper_pid=$!

    # Give wrapper time to start
    sleep "${QUICK_SLEEP}"

    # Verify wrapper is running
    if ! kill -0 "$wrapper_pid" 2>/dev/null; then
        log ERROR "Multiplex wrapper failed to start"
        return 1
    fi

    # Write wrapper PID atomically
    if ! write_pid_atomic "$wrapper_pid" "$pid_file"; then
        log ERROR "Failed to write multiplex wrapper PID"
        kill -TERM "$wrapper_pid" 2>/dev/null || true
        return 1
    fi

    log INFO "Multiplex stream started successfully (wrapper PID: $wrapper_pid)"
    return 0
}

# Start FFmpeg stream
start_ffmpeg_stream() {
    local device_name="$1"
    local card_num="$2"
    local stream_path="$3"

    local pid_file="${FFMPEG_PID_DIR}/${stream_path}.pid"

    # Check if already running
    if [[ -f "$pid_file" ]]; then
        local existing_pid
        existing_pid="$(read_pid_safe "$pid_file")"
        if [[ -n "$existing_pid" ]] && kill -0 "$existing_pid" 2>/dev/null; then
            # Verify PID actually belongs to our wrapper script
            if ! pid_is_foreign_wrapper "$existing_pid" "$stream_path"; then
                log DEBUG "Stream $stream_path already running"
                return 0
            else
                log WARN "Stale PID file for $stream_path (PID $existing_pid is not our wrapper)"
                rm -f "$pid_file"
            fi
        fi
    fi

    if ! check_audio_device "$card_num"; then
        log ERROR "Audio device card ${card_num} is not accessible"
        return 1
    fi

    # Get device configuration
    local sample_rate channels codec bitrate thread_queue
    sample_rate="$(get_device_config "$device_name" "SAMPLE_RATE" "$DEFAULT_SAMPLE_RATE" "$stream_path")"
    channels="$(get_device_config "$device_name" "CHANNELS" "$DEFAULT_CHANNELS" "$stream_path")"
    codec="$(get_device_config "$device_name" "CODEC" "$DEFAULT_CODEC" "$stream_path")"
    bitrate="$(get_device_config "$device_name" "BITRATE" "$DEFAULT_BITRATE" "$stream_path")"
    thread_queue="$(get_device_config "$device_name" "THREAD_QUEUE" "$DEFAULT_THREAD_QUEUE" "$stream_path")"

    log INFO "Starting FFmpeg for $stream_path (device: $device_name, card: $card_num)"

    # Create wrapper script
    local wrapper_script="${FFMPEG_PID_DIR}/${stream_path}.sh"
    local ffmpeg_log="${FFMPEG_PID_DIR}/${stream_path}.log"
    rotate_ffmpeg_log "$ffmpeg_log"

    # Create wrapper with all variables properly quoted
    cat >"$wrapper_script" <<'WRAPPER_START'
#!/bin/bash
set -euo pipefail

# Ensure PATH includes common binary locations
export PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin:$PATH"

WRAPPER_START

    # Write configuration variables
    cat >>"$wrapper_script" <<EOF
# Stream Configuration
STREAM_PATH="$stream_path"
CARD_NUM="$card_num"
SAMPLE_RATE="$sample_rate"
CHANNELS="$channels"
BITRATE="$bitrate"
THREAD_QUEUE="$thread_queue"
ANALYZEDURATION="$DEFAULT_ANALYZEDURATION"
PROBESIZE="$DEFAULT_PROBESIZE"
CODEC="$codec"

# File paths
FFMPEG_LOG="$ffmpeg_log"
LOG_FILE="$LOG_FILE"
WRAPPER_PID_FILE="$pid_file"
CLEANUP_MARKER="$CLEANUP_MARKER"
MEDIAMTX_HOST="$MEDIAMTX_HOST"

# Parent process tracking - use main script PID, not immediate parent
MAIN_SCRIPT_PID="$$"

# Restart configuration
RESTART_COUNT=0
CONSECUTIVE_FAILURES=0
MAX_CONSECUTIVE_FAILURES=$MAX_CONSECUTIVE_FAILURES
MAX_WRAPPER_RESTARTS=$MAX_WRAPPER_RESTARTS
WRAPPER_SUCCESS_DURATION=$WRAPPER_SUCCESS_DURATION
RESTART_DELAY=$INITIAL_RESTART_DELAY
FFMPEG_LOG_MAX_SIZE=$FFMPEG_LOG_MAX_SIZE

# Audio buffering configuration
AUDIO_BUFFER_ENABLED="${AUDIO_BUFFER_ENABLED}"
AUDIO_RTBUFSIZE="${AUDIO_RTBUFSIZE}"
AUDIO_LOCAL_RECORDING="${AUDIO_LOCAL_RECORDING}"
AUDIO_RECORDING_PATH="${AUDIO_RECORDING_PATH}"
AUDIO_RECORDING_SEGMENT_TIME="${AUDIO_RECORDING_SEGMENT_TIME}"
AUDIO_RECORDING_SEGMENTS="${AUDIO_RECORDING_SEGMENTS}"

FFMPEG_PID=""
EOF

    # Add the wrapper logic
    cat >>"$wrapper_script" <<'WRAPPER_LOGIC'

# Create log file if it doesn't exist
touch "${FFMPEG_LOG}" 2>/dev/null || true

log_message() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] [WRAPPER] $1" >> "${FFMPEG_LOG}" 2>/dev/null || true
}

log_critical() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] [STREAM:${STREAM_PATH}] $1" >> "${LOG_FILE}" 2>/dev/null || true
}

# Monotonic seconds since boot for run-time/backoff math. Wall-clock deltas
# break on NTP steps (an RTC-less Pi can jump years when it first gets
# network): a healthy multi-hour run would measure negative and count as a
# consecutive failure, eventually killing the wrapper on a healthy stream.
now_s() {
    local up
    if [[ -r /proc/uptime ]]; then
        read -r up _ < /proc/uptime
        printf '%s' "${up%%.*}"
    else
        date +%s
    fi
}

# Cleanup handler
cleanup_wrapper() {
    local exit_code=$?
    log_message "Wrapper cleanup initiated (exit code: $exit_code)"
    
    # Atomic check and kill
    local ffmpeg_pid="${FFMPEG_PID:-}"
    if [[ -n "$ffmpeg_pid" ]]; then
        if kill -0 "$ffmpeg_pid" 2>/dev/null; then
            log_message "Sending SIGINT to FFmpeg process ${ffmpeg_pid}"
            kill -INT "$ffmpeg_pid" 2>/dev/null || true
            
            # Wait briefly for termination
            local term_wait=0
            while kill -0 "$ffmpeg_pid" 2>/dev/null && [[ $term_wait -lt 5 ]]; do
                sleep 0.2
                ((term_wait++)) || true
            done
            
            # Force kill if still running
            if kill -0 "$ffmpeg_pid" 2>/dev/null; then
                kill -KILL "$ffmpeg_pid" 2>/dev/null || true
            fi
        fi
    fi
    
    rm -f "${WRAPPER_PID_FILE}"
    log_critical "Stream wrapper terminated for ${STREAM_PATH}"
    exit "$exit_code"
}

trap cleanup_wrapper EXIT INT TERM

# Run FFmpeg with proper quoting
run_ffmpeg() {
    local audio_device="plughw:${CARD_NUM},0"

    log_message "Starting FFmpeg with device: $audio_device"

    # Build command array to handle spaces properly
    local ffmpeg_cmd=(
        ffmpeg
        -hide_banner
        -loglevel warning
        -analyzeduration "${ANALYZEDURATION}"
        -probesize "${PROBESIZE}"
    )

    # v1.4.2: Add memory buffering if enabled (reduces data loss on restart)
    if [[ "${AUDIO_BUFFER_ENABLED}" == "true" ]]; then
        ffmpeg_cmd+=(-rtbufsize "${AUDIO_RTBUFSIZE}")
        log_message "Memory buffering enabled: ${AUDIO_RTBUFSIZE} bytes"
    fi

    # Add input options
    ffmpeg_cmd+=(
        -f alsa
        -ar "${SAMPLE_RATE}"
        -ac "${CHANNELS}"
        -thread_queue_size "${THREAD_QUEUE}"
        -i "${audio_device}"
        -af "aresample=async=1:first_pts=0"
    )

    # Add codec options based on codec type
    local codec_opts=()
    case "${CODEC}" in
        opus)
            codec_opts=(-c:a libopus -b:a "${BITRATE}" -application audio)
            ;;
        aac)
            codec_opts=(-c:a aac -b:a "${BITRATE}")
            ;;
        mp3)
            codec_opts=(-c:a libmp3lame -b:a "${BITRATE}")
            ;;
        *)
            codec_opts=(-c:a libopus -b:a "${BITRATE}")
            ;;
    esac

    # v1.4.2: Add local recording if enabled (ring buffer in tmpfs/RAM)
    if [[ "${AUDIO_LOCAL_RECORDING}" == "true" ]]; then
        # Create recording directory (defaults to /dev/shm which is tmpfs/RAM)
        mkdir -p "${AUDIO_RECORDING_PATH}/${STREAM_PATH}" 2>/dev/null || true

        # Use tee muxer for simultaneous streaming and recording
        ffmpeg_cmd+=("${codec_opts[@]}")
        ffmpeg_cmd+=(
            -f tee
            -map 0:a
            "[f=rtsp:rtsp_transport=tcp]rtsp://${MEDIAMTX_HOST}:8554/${STREAM_PATH}|[f=segment:segment_time=${AUDIO_RECORDING_SEGMENT_TIME}:segment_wrap=${AUDIO_RECORDING_SEGMENTS}:strftime=0]${AUDIO_RECORDING_PATH}/${STREAM_PATH}/audio_%03d.${CODEC}"
        )
        log_message "Local recording enabled: ${AUDIO_RECORDING_PATH}/${STREAM_PATH} (${AUDIO_RECORDING_SEGMENTS} x ${AUDIO_RECORDING_SEGMENT_TIME}s segments)"
    else
        # Standard output: stream only
        ffmpeg_cmd+=("${codec_opts[@]}")
        ffmpeg_cmd+=(
            -f rtsp
            -rtsp_transport tcp
            "rtsp://${MEDIAMTX_HOST}:8554/${STREAM_PATH}"
        )
    fi
    
    # Rotate log if exceeds size limit to prevent disk exhaustion
    if [[ -f "${FFMPEG_LOG}" ]]; then
        local current_size
        current_size=$(stat -c %s "${FFMPEG_LOG}" 2>/dev/null || echo 0)
        if (( current_size > FFMPEG_LOG_MAX_SIZE )); then
            log_message "Rotating FFmpeg log (current size: ${current_size} bytes, max: ${FFMPEG_LOG_MAX_SIZE})"
            mv -f "${FFMPEG_LOG}" "${FFMPEG_LOG}.old" 2>/dev/null || true
            # Note: FFmpeg will automatically create new log file on next write
        fi
    fi
    
    # Start FFmpeg with proper process group
    if command -v setsid &>/dev/null; then
        setsid "${ffmpeg_cmd[@]}" >> "${FFMPEG_LOG}" 2>&1 &
        FFMPEG_PID=$!
    else
        "${ffmpeg_cmd[@]}" >> "${FFMPEG_LOG}" 2>&1 &
        FFMPEG_PID=$!
    fi
    
    # Validate FFmpeg process started
    sleep 0.2
    if ! kill -0 "$FFMPEG_PID" 2>/dev/null; then
        log_message "ERROR: FFmpeg failed to start"
        if [[ -f "${FFMPEG_LOG}" ]]; then
            log_message "Last output: $(tail -n 3 "${FFMPEG_LOG}" 2>/dev/null | tr '\n' ' ')"
        fi
        FFMPEG_PID=""
        return 1
    fi
    
    log_message "Started FFmpeg with PID ${FFMPEG_PID}"
    return 0
}

check_device_exists() {
    [[ -e "/dev/snd/pcmC${CARD_NUM}D0c" ]]
}

# Check if parent is still alive
check_parent_alive() {
    # Intentionally a no-op. MAIN_SCRIPT_PID is the transient launcher process,
    # which exits BY DESIGN after starting the wrappers (start_mediamtx returns
    # and the systemd unit is Type=forking). Tying wrapper lifetime to it made
    # every wrapper exit shortly after boot, defeating auto-restart entirely.
    # Graceful shutdown is handled by the CLEANUP_MARKER check in the loop and by
    # `stop` terminating the wrapper process groups directly; an abnormal launcher
    # exit creates CLEANUP_MARKER, which also stops the wrappers. Kept as a
    # function (rather than deleting call sites) to minimise churn in the
    # generated wrapper.
    return 0
}

# Log startup
log_critical "Stream wrapper starting for ${STREAM_PATH} (card ${CARD_NUM})"
log_message "Wrapper PID: $$, Main script PID: ${MAIN_SCRIPT_PID}"

# Main restart loop
while true; do
    # Check parent is alive
    if ! check_parent_alive; then
        break
    fi
    
    if [[ -f "${CLEANUP_MARKER}" ]]; then
        log_message "Cleanup in progress, stopping wrapper"
        break
    fi
    
    if ! check_device_exists; then
        log_message "Device card ${CARD_NUM} no longer exists"
        break
    fi
    
    if [[ $CONSECUTIVE_FAILURES -ge $MAX_CONSECUTIVE_FAILURES ]]; then
        log_message "Too many consecutive failures ($CONSECUTIVE_FAILURES)"
        break
    fi
    
    if [[ $RESTART_COUNT -ge $MAX_WRAPPER_RESTARTS ]]; then
        log_message "Max restarts reached ($RESTART_COUNT)"
        break
    fi
    
    log_message "Starting FFmpeg (attempt #$((RESTART_COUNT + 1)))"
    
    START_TIME=$(now_s)
    
    if ! run_ffmpeg; then
        log_message "Failed to start FFmpeg"
        ((CONSECUTIVE_FAILURES++)) || true
        # Protect against integer overflow in restart delay
        if (( RESTART_DELAY <= 0 )) || (( RESTART_DELAY > MAX_RESTART_DELAY )); then
            RESTART_DELAY=$INITIAL_RESTART_DELAY
        else
            RESTART_DELAY=$((RESTART_DELAY * 2))
            if (( RESTART_DELAY > MAX_RESTART_DELAY )); then
                RESTART_DELAY=$MAX_RESTART_DELAY
            fi
        fi
        sleep $RESTART_DELAY
        continue
    fi
    
    # Wait for FFmpeg to exit.
    # NOTE: capture the status with `|| exit_code=$?`. A bare `wait` returns
    # FFmpeg's (usually non-zero) exit status and, under `set -euo pipefail`,
    # errexit would kill the wrapper HERE -- before the restart/backoff logic
    # below -- so streams never auto-restarted after a failure.
    exit_code=0
    wait "${FFMPEG_PID}" 2>/dev/null || exit_code=$?
    
    FFMPEG_PID=""
    
    END_TIME=$(now_s)
    RUN_TIME=$((END_TIME - START_TIME))
    
    log_message "FFmpeg exited with code ${exit_code} after ${RUN_TIME} seconds"
    
    ((RESTART_COUNT++)) || true
    
    # Reset failures and delay if ran successfully
    if [[ ${RUN_TIME} -gt ${WRAPPER_SUCCESS_DURATION} ]]; then
        # A run longer than WRAPPER_SUCCESS_DURATION is "healthy": reset BOTH the
        # consecutive-failure counter AND the restart odometer. RESTART_COUNT was
        # previously never reset, making MAX_WRAPPER_RESTARTS a LIFETIME cap
        # rather than a rate -- so benign restarts (USB re-enumeration, MediaMTX
        # blips) accumulated over weeks until the wrapper gave up for good and the
        # stream died silently on an unattended box.
        CONSECUTIVE_FAILURES=0
        RESTART_COUNT=0
        RESTART_DELAY=$INITIAL_RESTART_DELAY
        log_message "Successful run, reset delay to ${RESTART_DELAY}s"
    else
        ((CONSECUTIVE_FAILURES++)) || true
        # Protect against integer overflow in restart delay
        if (( RESTART_DELAY <= 0 )) || (( RESTART_DELAY > MAX_RESTART_DELAY )); then
            RESTART_DELAY=$INITIAL_RESTART_DELAY
        else
            RESTART_DELAY=$((RESTART_DELAY * 2))
            if (( RESTART_DELAY > MAX_RESTART_DELAY )); then
                RESTART_DELAY=$MAX_RESTART_DELAY
            fi
        fi
    fi
    
    # Check parent before sleeping
    if ! check_parent_alive; then
        break
    fi
    
    log_message "Waiting ${RESTART_DELAY}s before restart (failures: $CONSECUTIVE_FAILURES)"
    sleep ${RESTART_DELAY}
done

log_message "Wrapper exiting for ${STREAM_PATH}"
WRAPPER_LOGIC

    chmod +x "$wrapper_script"

    # Check wrapper script was created properly
    if [[ ! -x "$wrapper_script" ]]; then
        log ERROR "Failed to create executable wrapper script"
        return 1
    fi

    # Start wrapper with process group using setsid if available
    log DEBUG "Starting wrapper script: $wrapper_script"
    if command_exists setsid; then
        spawn_detached nohup setsid bash "$wrapper_script" >/dev/null 2>&1 &
    else
        spawn_detached nohup bash "$wrapper_script" >/dev/null 2>&1 &
    fi
    local pid=$!

    # Give wrapper time to start and check for immediate failures
    sleep 0.5

    if ! kill -0 "$pid" 2>/dev/null; then
        log ERROR "Wrapper failed to start for $stream_path"
        # Check if log file exists and has error messages
        if [[ -f "$ffmpeg_log" ]]; then
            local recent_logs
            recent_logs="$(tail -n 10 "$ffmpeg_log" 2>/dev/null)"
            if [[ -n "$recent_logs" ]]; then
                log ERROR "Wrapper logs (last 10 lines):"
                while IFS= read -r line; do
                    log ERROR "  $line"
                done <<<"$recent_logs"
            fi
        fi
        rm -f "$wrapper_script"
        return 1
    fi

    # Write PID file with enhanced validation
    if ! write_pid_atomic "$pid" "$pid_file"; then
        log ERROR "Failed to write PID file for $stream_path"
        kill "$pid" 2>/dev/null || true
        rm -f "$wrapper_script"
        return 1
    fi

    log DEBUG "Wrapper started with PID $pid for stream $stream_path"

    # Wait for stream to stabilize
    sleep $((STREAM_STARTUP_DELAY + 3))

    if validate_stream "$stream_path"; then
        log INFO "Stream $stream_path started successfully"
        return 0
    else
        log ERROR "Stream $stream_path failed validation"
        kill "$pid" 2>/dev/null || true
        rm -f "$pid_file"
        return 1
    fi
}

# Stop FFmpeg stream
stop_ffmpeg_stream() {
    local stream_path="$1"
    local pid_file="${FFMPEG_PID_DIR}/${stream_path}.pid"

    if [[ ! -f "$pid_file" ]]; then
        return 0
    fi

    local pid
    pid="$(read_pid_safe "$pid_file")"

    if [[ -n "$pid" ]]; then
        log INFO "Stopping FFmpeg for $stream_path (PID: $pid)"
    fi

    # Only a wrapper that is provably this manager's is signalled, and only the
    # stream's wrapper and its children: no other FFmpeg is touched. The log
    # stays (rotate_ffmpeg_log keeps it bounded): it is the post-mortem.
    local rc=0
    stop_recorded_process "$pid_file" wrapper 10 "$stream_path" || rc=$?
    if [[ $rc -eq 0 ]]; then
        rm -f "${FFMPEG_PID_DIR}/${stream_path}.sh"
    fi
    return "$rc"
}

# Keep the last FFMPEG_LOG_KEEP runs of a stream's FFmpeg log. Called before a
# new wrapper is started: the log of the previous run becomes <log>.prev.1,
# older ones move up, and the ones beyond the limit are removed (also after the
# limit was lowered). Nothing is deleted just because a stream is started,
# stopped or cleaned up: the log of a run that went wrong is the post-mortem.
# The archives are not named *.log, so logrotate's glob does not truncate them.
rotate_ffmpeg_log() {
    local log_file="$1" keep="${FFMPEG_LOG_KEEP}" archive n i
    for archive in "${log_file}.prev."*; do
        [[ -e "$archive" ]] || continue
        n="${archive##*.prev.}"
        if [[ "$n" =~ ^[0-9]+$ ]] && ((10#$n > keep)); then
            rm -f -- "$archive"
        fi
    done
    [[ -s "$log_file" ]] || return 0
    if ((keep == 0)); then
        rm -f -- "$log_file"
        return 0
    fi
    for ((i = keep - 1; i >= 1; i--)); do
        if [[ -e "${log_file}.prev.${i}" ]]; then
            mv -f -- "${log_file}.prev.${i}" "${log_file}.prev.$((i + 1))"
        fi
    done
    mv -f -- "$log_file" "${log_file}.prev.1"
}

# Start all streams with stable device list
start_all_ffmpeg_streams() {
    # Receive device list as arguments instead of detecting again
    local devices=("$@")

    if [[ ${#devices[@]} -eq 0 ]]; then
        log WARN "No USB audio devices provided"
        return 0
    fi

    log INFO "Starting FFmpeg streams for ${#devices[@]} devices"

    local success_count=0
    local failed_streams=()
    local device_idx=0

    for device_info in "${devices[@]}"; do
        ((device_idx++)) || true
        IFS=':' read -r device_name card_num <<<"$device_info"

        if [[ -z "$device_name" ]] || [[ -z "$card_num" ]]; then
            continue
        fi

        if [[ ! -e "/dev/snd/controlC${card_num}" ]]; then
            continue
        fi

        local stream_path
        stream_path="$(generate_stream_path "$device_name" "$card_num")"

        # Progress feedback for manual starts
        echo "Starting stream ${device_idx}/${#devices[@]}: ${stream_path}..."

        if start_ffmpeg_stream "$device_name" "$card_num" "$stream_path"; then
            ((success_count++)) || true
        else
            failed_streams+=("$stream_path")
            log ERROR "Failed to start stream for $device_name (card $card_num)"
        fi
    done

    # Log summary with details about failures
    if [[ ${#failed_streams[@]} -gt 0 ]]; then
        log WARN "Started $success_count/${#devices[@]} FFmpeg streams. Failed: ${failed_streams[*]}"
    else
        log INFO "Successfully started all $success_count/${#devices[@]} FFmpeg streams"
    fi

    # Always return 0 for best-effort behavior
    return 0
}

# Stop all streams
stop_all_ffmpeg_streams() {
    log INFO "Stopping all FFmpeg streams"

    local nullglob_state
    shopt -q nullglob && nullglob_state=on || nullglob_state=off
    shopt -s nullglob

    local failed=0
    for pid_file in "${FFMPEG_PID_DIR}"/*.pid; do
        if [[ -f "$pid_file" ]]; then
            local stream_path
            stream_path="$(basename "$pid_file" .pid)"
            stop_ffmpeg_stream "$stream_path" || ((failed++)) || true
        fi
    done

    # Restore nullglob only if it was originally off (avoids redundant shopt -s)
    [[ "$nullglob_state" == "off" ]] && shopt -u nullglob

    # No pattern kill of "every FFmpeg that talks to localhost:8554" here: it
    # also killed other installations' FFmpeg and the operator's own readers.
    # Each wrapper's FFmpeg is stopped with its wrapper above.
    if ((failed > 0)); then
        log ERROR "$failed stream wrapper(s) could not be stopped"
        return 1
    fi
    return 0
}

# Does the installed MediaMTX accept the top-level "moq" key (>= 1.19.0)?
# Fails when the binary is missing or its version cannot be read.
mediamtx_supports_moq_key() {
    local ver
    [[ -x "${MEDIAMTX_BIN}" ]] || return 1
    if command_exists timeout; then
        ver=$(timeout 10 "${MEDIAMTX_BIN}" --version 2>/dev/null | head -n 1) || return 1
    else
        ver=$("${MEDIAMTX_BIN}" --version 2>/dev/null | head -n 1) || return 1
    fi
    [[ "$ver" =~ ^v?([0-9]+)\.([0-9]+)\.[0-9]+ ]] || return 1
    local major=$((10#${BASH_REMATCH[1]})) minor=$((10#${BASH_REMATCH[2]}))
    ((major > 1 || (major == 1 && minor >= 19)))
}

# Generate MediaMTX configuration without subshell locking
generate_mediamtx_config() {
    log INFO "Generating MediaMTX configuration"

    if [[ ! -f "${DEVICE_CONFIG_FILE}" ]]; then
        save_device_config
    fi

    load_device_config

    # Ensure config directory exists
    if [[ ! -d "${CONFIG_DIR}" ]]; then
        mkdir -p "${CONFIG_DIR}" 2>/dev/null || {
            log ERROR "Failed to create config directory: ${CONFIG_DIR}"
            return 1
        }
    fi

    # Don't use subshell for locking - keep lock in main shell
    if ! acquire_config_lock 10; then
        return 1
    fi

    # Create temp file for atomic write
    local tmp_config
    tmp_config="$(mktemp -p "$(dirname "${CONFIG_FILE}")" "$(basename "${CONFIG_FILE}").XXXXXX")"

    # Ensure temp file and lock are cleaned up on any failure
    local _config_cleanup_needed=true
    trap 'if [[ "${_config_cleanup_needed:-}" == "true" ]]; then rm -f "$tmp_config" 2>/dev/null; release_config_lock_unsafe; fi' RETURN

    cat >"$tmp_config" <<'EOF'
# MediaMTX Configuration - Audio Streams
logLevel: info
readTimeout: 30s
writeTimeout: 30s

api: yes
apiAddress: :9997

metrics: yes
metricsAddress: :9998

rtsp: yes
rtspAddress: :8554
rtspTransports: [tcp, udp]

rtmp: no
hls: no
webrtc: no
srt: no
EOF

    # MediaMTX >= 1.19.0 also starts a MoQ (Media over QUIC) server by default:
    # :8892/tcp, :8892/udp and :8893/udp on every interface. Turn it off, but
    # only where the key exists -- 1.15-1.18 reject an unknown "moq" key and
    # refuse to start, so an unknown version leaves the key out.
    if mediamtx_supports_moq_key; then
        printf 'moq: no\n' >>"$tmp_config"
    fi
    printf '\npaths:\n' >>"$tmp_config"

    # Add paths based on stream mode
    if [[ "${STREAM_MODE}" == "multiplex" ]]; then
        cat >>"$tmp_config" <<EOF
  ${MULTIPLEX_STREAM_NAME}:
    source: publisher
    sourceProtocol: automatic
    sourceOnDemand: no
EOF
    else
        # Individual mode - accept any stream name
        cat >>"$tmp_config" <<EOF
  '~^[a-zA-Z0-9_-]+$':
    source: publisher
    sourceProtocol: automatic
    sourceOnDemand: no
EOF
    fi

    # Set permissions BEFORE atomic move (following write_pid_atomic pattern)
    chmod 644 "$tmp_config" 2>/dev/null || {
        rm -f "$tmp_config"
        log ERROR "Failed to set permissions on temp config file"
        release_config_lock_unsafe
        return 1
    }

    # Atomically move into place
    mv -f "$tmp_config" "${CONFIG_FILE}" || {
        rm -f "$tmp_config"
        log ERROR "Failed to move config file into place"
        release_config_lock_unsafe
        return 1
    }

    # Release config lock
    release_config_lock_unsafe

    _config_cleanup_needed=false
    log INFO "Configuration generated successfully"
    return 0
}

# Check if MediaMTX is running: the process recorded in PID_FILE is alive and is
# not provably some other program. A process that cannot be identified (its
# /proc entry is unreadable without root) counts as running.
is_mediamtx_running() {
    local pid rc=0
    pid="$(read_pid_safe "${PID_FILE}")"
    [[ -n "$pid" ]] || return 1
    is_managed_mediamtx_pid "$pid" || rc=$?
    [[ $rc -ne 1 ]]
}

# Start MediaMTX with single device detection
#
# One owner (D1): the MediaMTX this manager runs is the one it started and
# recorded in PID_FILE. A MediaMTX that someone else started (the standalone
# mediamtx.service, another unit, a manual run on the same configuration) is
# not replaced, stopped or signalled: the start is refused with E_OWNERSHIP and
# nothing is touched.
#
# Idempotent (LB-01): when that MediaMTX is running, `start` changes nothing
# that works. It does not clean up, wait for the USB subsystem, regenerate the
# configuration or restart anything; it only starts the streams that are
# missing. Cleanup runs only when the recorded ownership is not provably intact
# (the PID is dead, was reused, or is not MediaMTX) or on a restart.
start_mediamtx() {
    if ! acquire_lock; then
        # Nothing was started or stopped, so there is nothing to clean up: an
        # exit marker here would make the NEXT start tear down the healthy
        # stack that holds the lock.
        SKIP_CLEANUP=true
        error_exit "Failed to acquire lock" "${E_LOCK_FAILED}"
    fi

    local foreign_owner=""
    if foreign_owner="$(foreign_mediamtx_owner)"; then
        # Nothing was started or stopped: no exit marker, for the same reason
        SKIP_CLEANUP=true
        log ERROR "Refusing to start: ${foreign_owner}"
        error_exit "This manager runs only the MediaMTX it started itself and never signals another; nothing was changed. Stop the other MediaMTX first, or remove it with: ${SCRIPT_NAME} force-stop --kill-all" "${E_OWNERSHIP}"
    fi

    # Handle deferred cleanup from previous termination
    handle_deferred_cleanup

    local owned_pid=""
    if owned_pid="$(owned_mediamtx_pid)"; then
        log INFO "MediaMTX is already running (PID: ${owned_pid}) and owned by this manager; leaving it and its streams alone"
        local running_devices=()
        readarray -t running_devices < <(detect_audio_devices)
        if [[ ${#running_devices[@]} -eq 0 ]]; then
            log WARN "No USB audio devices detected; no stream to start"
            return 0
        fi
        start_streams_and_report "${running_devices[@]}"
        return $?
    fi

    if is_restart_scenario; then
        log INFO "Detected restart scenario, cleaning up"
        cleanup_stale_processes
        if ! wait_for_usb_stabilization "${RESTART_STABILIZATION_DELAY}"; then
            log ERROR "USB subsystem not stable after restart"
            return "${E_USB_NO_DEVICES}"
        fi
        clear_restart_marker
    else
        cleanup_stale_processes
    fi

    if is_mediamtx_running; then
        log WARN "MediaMTX already running"
        return 0
    fi

    log INFO "Starting MediaMTX..."

    if ! wait_for_usb_stabilization "${USB_STABILIZATION_DELAY}"; then
        log ERROR "USB audio subsystem not ready"
        return "${E_USB_NO_DEVICES}"
    fi

    # Detect devices ONCE after stabilization
    local devices=()
    readarray -t devices < <(detect_audio_devices)

    if [[ ${#devices[@]} -eq 0 ]]; then
        log ERROR "No USB audio devices detected"
        return "${E_USB_NO_DEVICES}"
    fi

    if ! generate_mediamtx_config; then
        error_exit "Failed to generate configuration" "${E_CONFIG_ERROR}"
    fi

    # Check ports if lsof is available
    if command_exists lsof; then
        for port in 8554 9997 9998; do
            if lsof -i ":$port" >/dev/null 2>&1; then
                log ERROR "Port $port is already in use"
                return 1
            fi
        done
    elif command_exists ss; then
        for port in 8554 9997 9998; do
            if ss -tuln | grep -q ":$port "; then
                log ERROR "Port $port appears to be in use"
                return 1
            fi
        done
    else
        log WARN "Cannot check if MediaMTX ports are in use"
    fi

    # Set limits
    ulimit -n 65536 2>/dev/null || true
    ulimit -u 4096 2>/dev/null || true

    # Start MediaMTX with process group
    if command_exists setsid; then
        spawn_detached nohup setsid "${MEDIAMTX_BIN}" "${CONFIG_FILE}" >>"${MEDIAMTX_LOG_FILE}" 2>&1 &
    else
        spawn_detached nohup "${MEDIAMTX_BIN}" "${CONFIG_FILE}" >>"${MEDIAMTX_LOG_FILE}" 2>&1 &
    fi
    local pid=$!

    sleep "$QUICK_SLEEP"

    if ! kill -0 "$pid" 2>/dev/null; then
        log ERROR "MediaMTX process died immediately"
        return 1
    fi

    # Record the process (and its start time) before the readiness wait, not
    # after it: a start that is interrupted while waiting would otherwise leave
    # a running MediaMTX that no PID file names, which this manager (which only
    # signals what it can prove it started) could not take over again
    if ! write_pid_atomic "$pid" "${PID_FILE}"; then
        log ERROR "Failed to write PID file"
        terminate_process_group "$pid" 5
        return 1
    fi

    if ! wait_for_mediamtx_ready "$pid"; then
        terminate_process_group "$pid" 5
        pid_file_remove "${PID_FILE}"
        log ERROR "MediaMTX failed to become ready"
        return 1
    fi

    log INFO "MediaMTX started successfully (PID: $pid)"

    start_streams_and_report "${devices[@]}"
}

# Start the streams of DEVICES (one per device, or the single multiplexed
# stream) that are not running yet, and print their RTSP URLs. A stream that is
# already running is left alone: the per-stream start checks its wrapper.
start_streams_and_report() {
    local devices=("$@")

    # Start streams based on mode
    if [[ "${STREAM_MODE}" == "multiplex" ]]; then
        # Validate device count before starting multiplex stream
        if [[ ${#devices[@]} -eq 0 ]]; then
            log ERROR "Multiplex mode requires devices but none detected"
            stop_mediamtx
            return "${E_USB_NO_DEVICES}"
        fi

        log INFO "Multiplex mode - starting single multiplexed stream to ${MULTIPLEX_STREAM_NAME}"
        echo "Starting multiplexed stream (${#devices[@]} devices): ${MULTIPLEX_STREAM_NAME}..."
        # Start single multiplex stream with all devices
        if ! start_ffmpeg_multiplex_stream "${devices[@]}"; then
            log ERROR "Failed to start multiplex stream"
            stop_mediamtx
            return 1
        fi
    else
        log INFO "Individual stream mode - starting separate streams"
        # Pass the stable device list to start function
        start_all_ffmpeg_streams "${devices[@]}"
    fi

    # Display stream status based on mode
    echo
    echo -e "${GREEN}=== Available RTSP Streams ===${NC}"

    if [[ "${STREAM_MODE}" == "multiplex" ]]; then
        # In multiplex mode, validate the single multiplexed stream
        local stream_path="${MULTIPLEX_STREAM_NAME}"
        if validate_stream "$stream_path"; then
            echo -e "${GREEN}[OK]${NC} rtsp://${MEDIAMTX_HOST}:8554/${stream_path} (multiplexed from ${#devices[@]} devices)"
        else
            echo -e "${RED}[FAIL]${NC} rtsp://${MEDIAMTX_HOST}:8554/${stream_path} (failed)"
        fi
    else
        # In individual mode, validate each device's stream
        for device_info in "${devices[@]}"; do
            IFS=':' read -r device_name card_num <<<"$device_info"
            local stream_path
            stream_path="$(generate_stream_path "$device_name" "$card_num")"

            if validate_stream "$stream_path"; then
                echo -e "${GREEN}[OK]${NC} rtsp://${MEDIAMTX_HOST}:8554/${stream_path}"
            else
                echo -e "${RED}[FAIL]${NC} rtsp://${MEDIAMTX_HOST}:8554/${stream_path} (failed)"
            fi
        done
    fi

    echo
    return 0
}

# Stop MediaMTX without requiring lock
stop_mediamtx() {
    STOPPING_SERVICE=true

    # Wait (bounded) for the lifecycle lock. A stop that ran while a start is
    # mid-flight would tear down processes that start is still creating, so if
    # the lock cannot be taken, report the holder (acquire_lock logged it) and
    # refuse without touching anything.
    if ! acquire_lock "${STOP_LOCK_TIMEOUT}"; then
        log ERROR "Refusing to stop: another lifecycle command holds the lock (${LOCK_FILE})"
        STOPPING_SERVICE=false
        SKIP_CLEANUP=true
        return "${E_LOCK_FAILED}"
    fi

    local stop_failed=false
    stop_all_ffmpeg_streams || stop_failed=true

    if ! is_mediamtx_running; then
        log WARN "MediaMTX is not running"
        # A record of a process that is gone, or is not MediaMTX, is dropped
        stop_recorded_process "${PID_FILE}" mediamtx 0 || true
        STOPPING_SERVICE=false
        [[ "$stop_failed" == "false" ]] || return 1
        return 0
    fi

    log INFO "Stopping MediaMTX..."

    # Only the MediaMTX recorded in PID_FILE, and only while it is provably the
    # one this manager started (never another instance's, never mediamtx.service's)
    if ! stop_recorded_process "${PID_FILE}" mediamtx 30; then
        log ERROR "MediaMTX could not be stopped"
        STOPPING_SERVICE=false
        return 1
    fi

    log INFO "MediaMTX stopped"
    STOPPING_SERVICE=false
    [[ "$stop_failed" == "false" ]] || return 1
    return 0
}

# Print what `force-stop --kill-all` would signal, and why
print_kill_all_preview() {
    local pid start kind why cmdline
    local -a found=()
    mapfile -t found < <(scan_instance_processes)
    if [[ ${#found[@]} -eq 0 ]]; then
        echo "force-stop --kill-all: no process of this installation was found; there is nothing to signal."
        return 0
    fi
    echo "force-stop --kill-all would send SIGKILL to these ${#found[@]} process(es):"
    local line
    for line in "${found[@]}"; do
        read -r pid start kind why <<<"$line"
        cmdline="$(tr '\0' ' ' 2>/dev/null <"/proc/${pid}/cmdline")" || cmdline=""
        printf '  PID %s (%s): %s\n' "$pid" "$kind" "$why"
        printf '      command line: %s\n' "${cmdline:0:200}"
    done
}

# The broad kill: SIGKILL to every process scan_instance_processes lists, but
# each only while it is still the process that was listed (same start time).
# Wrappers and FFmpeg first, so nothing restarts what is being killed, then
# MediaMTX. Returns 1 when one of them survives.
kill_all_instance_processes() {
    local pid start kind why line waited=0 survivors=0 kind_wanted
    local -a found=()
    mapfile -t found < <(scan_instance_processes)
    [[ ${#found[@]} -gt 0 ]] || return 0
    for kind_wanted in wrapper ffmpeg mediamtx; do
        for line in "${found[@]}"; do
            read -r pid start kind why <<<"$line"
            [[ "$kind" == "$kind_wanted" ]] || continue
            log WARN "Sending SIGKILL to PID $pid ($kind): $why"
            _signal_if_same KILL "$pid" "$start" || true
        done
    done
    while ((waited < 30)); do
        survivors=0
        for line in "${found[@]}"; do
            read -r pid start _ <<<"$line"
            if _proc_is_same_live "$pid" "$start"; then
                survivors=$((survivors + 1))
            fi
        done
        ((survivors > 0)) || break
        sleep "$QUICK_SLEEP"
        ((waited++)) || true
    done
    if ((survivors > 0)); then
        log ERROR "$survivors process(es) survived SIGKILL"
        return 1
    fi
    return 0
}

# Force stop. Takes the lifecycle lock (bounded wait) so it never overlaps a
# start/stop/restart; if the lock cannot be taken it reports the holder and
# refuses without touching anything. The lock file itself is never deleted.
#
#   force-stop                    SIGKILL at once to the wrappers (with their
#                                 FFmpeg) and the MediaMTX recorded in this
#                                 manager's PID files, each only while it is
#                                 provably the process this manager started
#   force-stop --kill-all         the one broad kill. Prints every process of
#                                 this installation found by what it runs (the
#                                 configured MediaMTX binary, a command line in
#                                 the wrapper directory, FFmpeg that logs
#                                 there) and why, and exits 1 without signalling
#   force-stop --kill-all --yes   sends SIGKILL to exactly that list
#
# The FFmpeg logs are kept (they are the post-mortem), the lock files are never
# removed.
force_stop_mediamtx() {
    local kill_all=false confirmed=false arg
    for arg in "$@"; do
        case "$arg" in
            --kill-all) kill_all=true ;;
            --yes) confirmed=true ;;
            *)
                log ERROR "Unknown force-stop option: $arg (usage: force-stop [--kill-all [--yes]])"
                SKIP_CLEANUP=true
                return "${E_GENERAL}"
                ;;
        esac
    done
    if [[ "$confirmed" == "true" && "$kill_all" != "true" ]]; then
        log ERROR "force-stop: --yes only applies to --kill-all (usage: force-stop [--kill-all [--yes]])"
        SKIP_CLEANUP=true
        return "${E_GENERAL}"
    fi

    # Without --yes the broad kill is only a preview: nothing is signalled or
    # removed, so no lock is needed, and the non-zero exit must not leave the
    # cleanup marker that stops the wrappers
    if [[ "$kill_all" == "true" && "$confirmed" != "true" ]]; then
        print_kill_all_preview
        echo "Nothing was signalled. To signal exactly these processes run: ${SCRIPT_NAME} force-stop --kill-all --yes"
        SKIP_CLEANUP=true
        return "${E_GENERAL}"
    fi

    STOPPING_SERVICE=true

    if ! acquire_lock "${STOP_LOCK_TIMEOUT}"; then
        log ERROR "Refusing to force-stop: another lifecycle command holds the lock (${LOCK_FILE})"
        log ERROR "Wait for it to finish, or stop the process reported above, then run force-stop again"
        STOPPING_SERVICE=false
        SKIP_CLEANUP=true
        return "${E_LOCK_FAILED}"
    fi

    log WARN "Force stopping MediaMTX and all related processes"

    local rc=0
    if [[ "$kill_all" == "true" ]]; then
        print_kill_all_preview
        kill_all_instance_processes || rc=1
    fi

    # Wrappers (with their FFmpeg) and MediaMTX from the PID files, then the
    # records, generated scripts and markers they leave. SIGKILL at once.
    cleanup_stale_processes 0

    local leftover
    for leftover in "${PID_FILE}" "${FFMPEG_PID_DIR}"/*.pid; do
        if [[ -f "$leftover" ]]; then
            log ERROR "Could not stop the process recorded in $leftover"
            rc=1
        fi
    done

    log INFO "Force stop completed"
    STOPPING_SERVICE=false
    return "$rc"
}

# Restart MediaMTX
#
# The lifecycle lock is taken first and kept across the stop and the start. A
# restart that cannot get it is refused before anything is written: it used to
# mark the restart first, so a refused restart left the restart marker behind
# and the next start treated the node as being in a restart for 60 seconds.
# Nothing is changed either when another unit owns MediaMTX (E_OWNERSHIP).
restart_mediamtx() {
    if ! acquire_lock; then
        log ERROR "Refusing to restart: another lifecycle command holds the lock (${LOCK_FILE})"
        SKIP_CLEANUP=true
        return "${E_LOCK_FAILED}"
    fi

    local foreign_owner=""
    if foreign_owner="$(foreign_mediamtx_owner)"; then
        SKIP_CLEANUP=true
        log ERROR "Refusing to restart: ${foreign_owner}"
        return "${E_OWNERSHIP}"
    fi

    mark_restart
    stop_mediamtx
    sleep "$MEDIUM_SLEEP"
    start_mediamtx
}

# Show status
show_status() {
    SKIP_CLEANUP=true

    echo -e "${CYAN}=== MediaMTX Audio Stream Status ===${NC}"
    echo

    if is_mediamtx_running; then
        local pid
        pid="$(read_pid_safe "${PID_FILE}")"
        echo -e "MediaMTX: ${GREEN}Running${NC} (PID: $pid)"

        # Show resource usage
        if [[ -n "$pid" ]]; then
            local fd_count cpu_percent thread_count
            fd_count=$(find "/proc/$pid/fd" -maxdepth 1 -type l 2>/dev/null | wc -l || echo "?")
            cpu_percent=$(ps -o %cpu= -p "$pid" 2>/dev/null | tr -d ' ' || echo "?")
            thread_count=$(ps -o nlwp= -p "$pid" 2>/dev/null | tr -d ' ' || echo "?")
            echo "  Resources: FDs=$fd_count, CPU=${cpu_percent}%, Threads=$thread_count"
        fi
    else
        echo -e "MediaMTX: ${RED}Not running${NC}"
    fi

    echo

    local multiplex_pid_file="${FFMPEG_PID_DIR}/${MULTIPLEX_STREAM_NAME}.pid"
    local is_multiplex_mode=false

    if [[ -f "$multiplex_pid_file" ]]; then
        local multiplex_pid
        multiplex_pid="$(read_pid_safe "$multiplex_pid_file")"
        if [[ -n "$multiplex_pid" ]] && kill -0 "$multiplex_pid" 2>/dev/null; then
            is_multiplex_mode=true
        fi
    fi

    local devices=()
    readarray -t devices < <(detect_audio_devices)

    if [[ "$is_multiplex_mode" == "true" ]]; then
        # Multiplex mode is active
        echo "Multiplex stream (combining ${#devices[@]} devices):"
        echo "  Stream: rtsp://${MEDIAMTX_HOST}:8554/${MULTIPLEX_STREAM_NAME}"

        local multiplex_pid
        multiplex_pid="$(read_pid_safe "$multiplex_pid_file")"
        if [[ -n "$multiplex_pid" ]] && kill -0 "$multiplex_pid" 2>/dev/null; then
            echo -e "  Status: ${GREEN}Running${NC} (PID: $multiplex_pid)"
        else
            echo -e "  Status: ${RED}Not running${NC}"
        fi

        echo
        echo "Source devices:"
        if [[ ${#devices[@]} -eq 0 ]]; then
            echo "  No devices found"
        else
            for device_info in "${devices[@]}"; do
                IFS=':' read -r device_name card_num <<<"$device_info"
                echo "  - $device_name (card $card_num)"
            done
        fi
    else
        # Individual stream mode
        echo "Detected USB audio devices:"
        if [[ ${#devices[@]} -eq 0 ]]; then
            echo "  No devices found"
        else
            for device_info in "${devices[@]}"; do
                IFS=':' read -r device_name card_num <<<"$device_info"

                local stream_path
                stream_path="$(generate_stream_path "$device_name" "$card_num")"

                echo "  - $device_name (card $card_num)"
                echo "    Stream: rtsp://${MEDIAMTX_HOST}:8554/$stream_path"

                local pid_file="${FFMPEG_PID_DIR}/${stream_path}.pid"
                if [[ -f "$pid_file" ]]; then
                    local pid
                    pid="$(read_pid_safe "$pid_file")"
                    if [[ -n "$pid" ]] && kill -0 "$pid" 2>/dev/null; then
                        echo -e "    Status: ${GREEN}Running${NC} (PID: $pid)"
                    else
                        echo -e "    Status: ${RED}Not running${NC}"
                    fi
                else
                    echo -e "    Status: ${RED}Not running${NC}"
                fi
            done
        fi
    fi

    SKIP_CLEANUP=false
}

# Show configuration
show_config() {
    echo -e "${CYAN}=== Device Configuration ===${NC}"
    echo

    if [[ ! -f "${DEVICE_CONFIG_FILE}" ]]; then
        echo "Creating default configuration..."
        save_device_config
    fi

    cat "${DEVICE_CONFIG_FILE}"
}

# Create systemd service
create_systemd_service() {
    local service_file="/etc/systemd/system/mediamtx-audio.service"

    # Capture current configuration for systemd service
    local stream_mode="${STREAM_MODE:-individual}"
    local multiplex_filter="${MULTIPLEX_FILTER_TYPE:-amix}"
    local multiplex_name="${MULTIPLEX_STREAM_NAME:-all_mics}"

    cat >"$service_file" <<EOF
[Unit]
Description=MediaMTX Audio Stream Manager v${VERSION}
After=network.target sound.target
Wants=sound.target

[Service]
Type=forking
ExecStart=${SCRIPT_DIR}/${SCRIPT_NAME} start
ExecStop=${SCRIPT_DIR}/${SCRIPT_NAME} stop
ExecReload=${SCRIPT_DIR}/${SCRIPT_NAME} restart
PIDFile=${PID_FILE}
Restart=on-failure
RestartSec=30
StartLimitInterval=1200
StartLimitBurst=10
User=root
Group=audio

StandardOutput=append:${LOG_FILE}
StandardError=append:${LOG_FILE}

TimeoutStartSec=300
TimeoutStopSec=120

LimitNOFILE=65536
LimitNPROC=4096

PrivateTmp=yes
ProtectSystem=full
NoNewPrivileges=yes
ReadWritePaths=/etc/mediamtx /var/lib/mediamtx-ffmpeg /var/log /var/run

Environment="HOME=/root"
Environment="PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
Environment="USB_STABILIZATION_DELAY=10"
Environment="STREAM_MODE=${stream_mode}"
Environment="MULTIPLEX_FILTER_TYPE=${multiplex_filter}"
Environment="MULTIPLEX_STREAM_NAME=${multiplex_name}"
Environment="INVOCATION_ID=systemd"
WorkingDirectory=${SCRIPT_DIR}

[Install]
WantedBy=multi-user.target
EOF

    chmod 644 "$service_file"

    # Setup logrotate configuration during install
    if command_exists logrotate && [[ -d /etc/logrotate.d ]]; then
        log INFO "Setting up log rotation configuration"
        cat >/etc/logrotate.d/mediamtx <<EOF
${MEDIAMTX_LOG_FILE} {
    daily
    rotate 7
    compress
    delaycompress
    missingok
    notifempty
    # copytruncate: MediaMTX's stdout here is an inherited shell redirect (>>),
    # so it cannot be told to reopen the file. Copy-then-truncate-in-place keeps
    # the same inode/fd, so MediaMTX keeps writing to the rotated file instead of
    # an unlinked one that grows invisibly until the disk fills. (The old
    # create + kill -USR1 could not work: the fd is owned by the shell redirect,
    # not by a MediaMTX-managed log file.)
    copytruncate
    size ${MEDIAMTX_LOG_MAX_SIZE}
}

${LOG_FILE} {
    daily
    rotate 7
    compress
    delaycompress
    missingok
    notifempty
    # copytruncate: the manager's log is held open (systemd append: / the
    # running process), so a plain create would leave it writing to the rotated
    # inode.
    copytruncate
    size ${MAIN_LOG_MAX_SIZE}
}

${FFMPEG_PID_DIR}/*.log {
    daily
    rotate 3
    compress
    delaycompress
    missingok
    notifempty
    # copytruncate: each FFmpeg holds its log open and does not reopen on rotate.
    copytruncate
    size ${FFMPEG_LOG_MAX_SIZE}
}
EOF
        chmod 644 /etc/logrotate.d/mediamtx
        log INFO "Log rotation configured successfully"
    fi

    # Create monitoring cron job with conservative restart policy and overlap protection
    # Conservative restart policy: only restart on critical resource failure
    # Using flock to prevent overlapping monitor instances when checks exceed 5 minutes
    cat >/etc/cron.d/mediamtx-monitor <<EOF
# Monitor MediaMTX resource usage and stream health every 5 minutes
# Conservative restart policy (only on critical resource failure):
#   Exit 0: All healthy - no action
#   Exit 2: Critical resource state - RESTART SERVICE
#   Exit 6: No USB devices - LOG ONLY (transient, will recover)
#   Exit 7: MediaMTX not running - LOG ONLY (may recover)
#   Exit 10: Stream degradation - LOG ONLY (monitor will fix on next cycle)
#
# CRON=1 enables explicit cron context detection
# flock prevents overlapping runs when monitor exceeds 5-minute interval
SHELL=/bin/bash
PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
CRON=1

*/5 * * * * root flock -n /run/mediamtx-monitor.lock -c '${SCRIPT_DIR}/${SCRIPT_NAME} monitor; EXIT=\$?; if [ \$EXIT -eq 2 ]; then systemctl restart mediamtx-audio; elif [ \$EXIT -ne 0 ]; then logger -t mediamtx-monitor "Non-critical exit code \$EXIT (no restart)"; fi' || logger -t mediamtx-monitor "Monitor already running or locked"
EOF

    systemctl daemon-reload

    echo "Systemd service created: $service_file"
    echo "Monitoring cron job created: /etc/cron.d/mediamtx-monitor"
    echo ""
    echo "=== v1.4.1 Configuration Enhancements ==="
    echo "  * Friendly name support for audio device configuration"
    echo "  * Use stream names in config (e.g., DEVICE_BLUE_YETI_SAMPLE_RATE=44100)"
    echo "  * 100% backward compatible with existing full device name configs"
    echo ""
    echo "=== v1.4.0 Production Enhancements ==="
    echo "  * Separate monitoring lock (eliminates service/cron contention)"
    echo "  * Conservative restart policy (only on critical resource failure)"
    echo "  * Overlapping monitor protection (flock-based locking)"
    echo "  * Increased restart tolerance (10 restarts in 20 minutes)"
    echo "  * Recursive process cleanup (ensures complete termination)"
    echo ""
    echo "=== Stream Mode Configuration ==="
    echo "Current mode: ${stream_mode}"
    if [[ "${stream_mode}" == "multiplex" ]]; then
        echo "  Filter type: ${multiplex_filter}"
        echo "  Stream name: ${multiplex_name}"
    fi
    echo ""
    echo "To change mode after installation:"
    echo "  sudo systemctl edit mediamtx-audio"
    echo "  Add/modify: Environment=\"STREAM_MODE=multiplex\""
    echo "  Add/modify: Environment=\"MULTIPLEX_FILTER_TYPE=amix\""
    echo "  Add/modify: Environment=\"MULTIPLEX_STREAM_NAME=studio\""
    echo "  Then: sudo systemctl daemon-reload && sudo systemctl restart mediamtx-audio"
    echo ""
    echo "Enable: sudo systemctl enable mediamtx-audio"
    echo "Start: sudo systemctl start mediamtx-audio"
}

# Show help
show_help() {
    cat <<EOF
MediaMTX Stream Manager v${VERSION}
Part of LyreBirdAudio - RTSP Audio Streaming Suite

Usage: ${SCRIPT_NAME} [OPTIONS] COMMAND

Options:
    -m, --mode MODE      Stream mode (individual|multiplex) [default: individual]
    -f, --filter TYPE    Multiplex filter type (amix|amerge) [default: amix]
    -n, --name NAME      Multiplex stream name [default: all_mics]
    -d, --debug          Enable debug output
    -h, --help           Show this help message

Environment Variables:
    MULTIPLEX_FILTER_TYPE    Multiplex audio filter type [default: amix]
                             - amix: Mix all audio sources into one output
                             - amerge: Merge sources keeping channels separate

Commands:
    start       Start MediaMTX and FFmpeg streams. Safe to repeat: when this
                manager's own MediaMTX is running it is left alone (same PIDs,
                no outage) and only streams that are missing are started.
                Refused with exit 8 while another MediaMTX owns the node
                (mediamtx.service, or a MediaMTX this manager did not start).
    stop        Stop MediaMTX and FFmpeg streams. Only processes this manager
                started are signalled (PID files + process start time).
    force-stop  SIGKILL, at once, the processes this manager started (emergency
                use; the FFmpeg logs are kept)
    force-stop --kill-all [--yes]
                The only broad kill: every process whose executable is the
                configured MediaMTX binary, whose command line names a file in
                the wrapper directory, or that is an FFmpeg logging there (this
                also stops another MediaMTX that uses the same binary). Without
                --yes it only prints those processes and why, signals nothing
                and exits 1.
    restart     Restart everything
    status      Show current status
    config      Show device configuration
    monitor     Check resource usage and stream health
                Exit codes: 0=healthy, 2=critical resources, 3=MediaMTX down,
                            7=no devices, 10=streams degraded
    install     Create systemd service
    help        Show this help

Configuration files:
    Device config: ${DEVICE_CONFIG_FILE}
    MediaMTX config: ${CONFIG_FILE}
    System log: ${LOG_FILE}
    MediaMTX log: ${MEDIAMTX_LOG_FILE}

Multiplex Mode Usage:
    Individual mode (default):
        sudo ./lyrebird-stream-manager.sh start
        Creates separate RTSP streams for each USB microphone

    Multiplex mode - Mix audio (amix):
        sudo ./lyrebird-stream-manager.sh -m multiplex -f amix start
        # Or use default filter (amix)
        sudo ./lyrebird-stream-manager.sh -m multiplex start
        Mixes all microphones into a single audio stream
        Output: rtsp://localhost:8554/${MULTIPLEX_STREAM_NAME}

    Multiplex mode - Separate channels (amerge):
        sudo ./lyrebird-stream-manager.sh -m multiplex -f amerge start
        Merges all microphones keeping channels separate
        Output: Single stream with (num_devices * channels_per_device) total channels

    Custom stream name:
        sudo ./lyrebird-stream-manager.sh -m multiplex -f amix -n studio start
        Output: rtsp://localhost:8554/studio


Resource Monitoring:
    The monitor command now checks:
    - Stream health (automatically restarts dead streams)
    - File descriptor usage (warn: ${MAX_FD_WARNING}, critical: ${MAX_FD_CRITICAL})
    - High CPU usage (warn: ${MAX_CPU_WARNING}%, critical: ${MAX_CPU_CRITICAL}%)
    - Wrapper process health
    
    Conservative restart policy:
    - Exit 2 (Critical resource failure): Triggers full service restart
    - Exit 7 (MediaMTX down): Logged, no restart (may recover)
    - Exit 6 (No USB devices): Logged, no restart (transient state)
    - Exit 10 (Stream degraded): Logged, no restart (fixed on next cycle)

Exit Codes:
    0  - Success
    1  - General error
    2  - Critical resource state (TRIGGERS RESTART in cron)
    3  - Missing dependencies
    4  - Configuration error
    5  - Lock acquisition failed
    6  - No USB devices found (logged only)
    7  - MediaMTX not running (logged only)
    8  - Another MediaMTX owns the node (start/restart refused, nothing changed)
    10 - Stream monitoring degraded (logged only)

FFmpeg logs:
    The log of each stream's previous run is kept as <stream>.log.prev.1 ...
    in ${FFMPEG_PID_DIR}: FFMPEG_LOG_KEEP runs (default 3, at most 20). start,
    stop and force-stop never delete them.

EOF
}

# Main function with enhanced argument parsing
parse_arguments() {
    # Parse options
    while [[ $# -gt 0 ]]; do
        case "$1" in
            -m | --mode)
                shift
                STREAM_MODE="${1}"
                if [[ "${STREAM_MODE}" != "individual" ]] && [[ "${STREAM_MODE}" != "multiplex" ]]; then
                    echo "Error: Invalid stream mode '${STREAM_MODE}'. Use 'individual' or 'multiplex'" >&2
                    exit 1
                fi
                shift
                ;;
            -f | --filter)
                shift
                MULTIPLEX_FILTER_TYPE="${1}"
                if [[ "${MULTIPLEX_FILTER_TYPE}" != "amix" ]] && [[ "${MULTIPLEX_FILTER_TYPE}" != "amerge" ]]; then
                    echo "Error: Invalid filter type '${MULTIPLEX_FILTER_TYPE}'. Use 'amix' or 'amerge'" >&2
                    exit 1
                fi
                shift
                ;;
            -n | --name)
                shift
                MULTIPLEX_STREAM_NAME="${1}"
                shift
                ;;
            -d | --debug)
                export DEBUG=true
                shift
                ;;
            -h | --help)
                show_help
                exit 0
                ;;
            -*)
                echo "Error: Unknown option '$1'" >&2
                show_help
                exit 1
                ;;
            *)
                # This is the command - return it and preserve remaining args
                COMMAND="$1"
                shift
                COMMAND_ARGS=("$@")
                return 0
                ;;
        esac
    done

    # No command specified
    COMMAND="help"
}

# Main entry point and command router
#
# Execution flow:
# 1. Calls parse_arguments() to parse command-line options and extract command
# 2. Logs stream mode if non-default
# 3. Routes to command handler via case statement
# 4. Captures exit code from command handler
# 5. Exits with propagated exit code
#
# Commands:
#   start       - Checks root, dependencies, directories, then starts service
#   stop        - Checks root, dependencies, directories, then stops service
#   force-stop  - Checks root, directories, then force-stops service
#   restart     - Checks root, dependencies, directories, then restarts service
#   status      - Shows current status (no root check)
#   config      - Shows configuration (no root check)
#   monitor     - Checks root, directories, resources, then monitors streams
#   install     - Checks root, then creates systemd service
#   help        - Shows help text
#
# Parameters:
#   $@ = Command-line arguments (passed to parse_arguments)
#
# Returns:
#   0 = Success (E_GENERAL=0 not used, success is 0)
#   1 = General error (E_GENERAL)
#   2 = Critical resource state (E_CRITICAL_RESOURCE)
#   3 = Missing dependencies (E_MISSING_DEPS)
#   4 = Configuration error (E_CONFIG_ERROR)
#   5 = Lock acquisition failed (E_LOCK_FAILED)
#   6 = No USB devices found (E_USB_NO_DEVICES)
#   7 = MediaMTX not running (E_MEDIAMTX_DOWN)
#   8 = Another MediaMTX owns the node; start/restart refused (E_OWNERSHIP)
#   10 = Stream monitoring degraded (E_MONITOR_DEGRADED)
#
# Side Effects:
#   - Calls exit() - does not return
#   - May modify filesystem (logs, config files, PID files)
#   - May start/stop processes
main() {
    local exit_code=0

    # Parse arguments
    # Note: COMMAND is global so cleanup() can check it
    COMMAND=""
    parse_arguments "$@"
    warn_removed_settings

    # Log stream mode if set
    if [[ -n "${STREAM_MODE}" ]] && [[ "${STREAM_MODE}" != "individual" ]]; then
        log INFO "Stream mode: ${STREAM_MODE}"
    fi

    case "${COMMAND}" in
        start)
            check_root
            check_dependencies
            setup_directories
            # v1.4.2: Pre-start validation and initialization
            check_version_compatibility || log WARN "Version compatibility check failed (continuing anyway)"
            validate_config || error_exit "Configuration validation failed" ${E_CONFIG_ERROR}
            start_mediamtx
            exit_code=$?
            ;;
        stop)
            check_root
            check_dependencies
            setup_directories
            stop_mediamtx
            exit_code=$?
            ;;
        force-stop)
            check_root
            setup_directories
            force_stop_mediamtx ${COMMAND_ARGS[@]+"${COMMAND_ARGS[@]}"}
            exit_code=$?
            ;;
        restart)
            check_root
            check_dependencies
            setup_directories
            restart_mediamtx
            exit_code=$?
            ;;
        status)
            show_status
            exit_code=$?
            ;;
        config)
            show_config
            exit_code=$?
            ;;
        monitor)
            check_root
            setup_directories
            # v1.4.2: Use enhanced resource monitoring with disk, memory, and network checks
            # First check all resources (returns E_CRITICAL_RESOURCE if critical issues)
            local resource_code=0
            check_all_resources || resource_code=$?
            if [[ $resource_code -eq ${E_CRITICAL_RESOURCE} ]]; then
                exit ${E_CRITICAL_RESOURCE}
            fi
            # Non-critical resource issues are logged but we continue
            # Audio level / dead-mic signals (informational, never fails the run)
            monitor_signals || true
            # Then check and restart streams (returns error codes for failures)
            monitor_streams
            exit_code=$?
            # Log exit code for debugging
            if [[ $exit_code -ne 0 ]]; then
                log DEBUG "Monitor command exiting with code $exit_code"
            fi
            ;;
        install)
            check_root
            create_systemd_service
            exit_code=$?
            ;;
        help | --help | -h | "")
            show_help
            exit_code=0
            ;;
        *)
            echo "Error: Unknown command '${1}'" >&2
            show_help
            exit_code=1
            ;;
    esac

    # Properly propagate exit code
    exit ${exit_code}
}

# Run main only when executed directly, not when sourced (e.g. by the test
# suite). Matches the source guard used by every other script in the suite.
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi
