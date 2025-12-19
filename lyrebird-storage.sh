#!/bin/bash
# lyrebird-storage.sh - Storage management for LyreBirdAudio
# Part of LyreBirdAudio - RTSP Audio Streaming Suite
# https://github.com/tomtom215/LyreBirdAudio
#
# Manages disk space by:
# - Cleaning up old recordings based on retention policy
# - Monitoring disk usage and taking action when thresholds are exceeded
# - Managing log file sizes
# - Cleaning temporary files
#
# Usage:
#   ./lyrebird-storage.sh status        # Show storage status
#   ./lyrebird-storage.sh cleanup       # Run cleanup based on retention policy
#   ./lyrebird-storage.sh emergency     # Emergency cleanup (critical disk usage)
#   ./lyrebird-storage.sh monitor       # Monitor and cleanup if needed
#
# Cron Integration:
#   # Daily cleanup at 3 AM
#   0 3 * * * /usr/local/bin/lyrebird-storage.sh cleanup
#
#   # Hourly monitoring
#   0 * * * * /usr/local/bin/lyrebird-storage.sh monitor
#
# Version: 1.0.0

set -euo pipefail

readonly VERSION="1.0.0"
SCRIPT_NAME="$(basename "${BASH_SOURCE[0]}")"
readonly SCRIPT_NAME

# ============================================================================
# Configuration
# ============================================================================

# Paths
readonly RECORDING_DIR="${LYREBIRD_RECORDING_DIR:-/var/lib/mediamtx-ffmpeg/recordings}"
readonly LOG_DIR="${LYREBIRD_LOG_DIR:-/var/log/lyrebird}"
readonly MEDIAMTX_LOG="${MEDIAMTX_LOG:-/var/log/mediamtx.out}"
readonly MEDIAMTX_LOG_DIR="${MEDIAMTX_LOG%/*}"  # Directory containing MediaMTX log
readonly TEMP_DIR="${LYREBIRD_TEMP_DIR:-/tmp}"
readonly BUFFER_DIR="${LYREBIRD_BUFFER_DIR:-/dev/shm/lyrebird-buffer}"

# Retention policies (in days) - must be positive integers
_rec_ret=${RECORDING_RETENTION_DAYS:-30}
_log_ret=${LOG_RETENTION_DAYS:-7}
_tmp_ret=${TEMP_RETENTION_HOURS:-24}

# Ensure retention values are positive (minimum 1)
(( _rec_ret < 1 )) && _rec_ret=1
(( _log_ret < 1 )) && _log_ret=1
(( _tmp_ret < 1 )) && _tmp_ret=1

readonly RECORDING_RETENTION_DAYS="$_rec_ret"
readonly LOG_RETENTION_DAYS="$_log_ret"
readonly TEMP_RETENTION_HOURS="$_tmp_ret"
unset _rec_ret _log_ret _tmp_ret

# Disk thresholds (percentage) - validate bounds 0-100
_disk_warning=${DISK_WARNING_PERCENT:-80}
_disk_critical=${DISK_CRITICAL_PERCENT:-90}
_disk_emergency=${DISK_EMERGENCY_PERCENT:-95}

# Clamp percentage values to valid range
(( _disk_warning < 0 )) && _disk_warning=0
(( _disk_warning > 100 )) && _disk_warning=100
(( _disk_critical < 0 )) && _disk_critical=0
(( _disk_critical > 100 )) && _disk_critical=100
(( _disk_emergency < 0 )) && _disk_emergency=0
(( _disk_emergency > 100 )) && _disk_emergency=100

readonly DISK_WARNING_PERCENT="$_disk_warning"
readonly DISK_CRITICAL_PERCENT="$_disk_critical"
readonly DISK_EMERGENCY_PERCENT="$_disk_emergency"
unset _disk_warning _disk_critical _disk_emergency

# Minimum free space (MB) - must be positive
_min_free=${MIN_FREE_SPACE_MB:-500}
(( _min_free < 0 )) && _min_free=0
readonly MIN_FREE_SPACE_MB="$_min_free"
unset _min_free

# Log file size limits (bytes)
readonly MAX_LOG_SIZE="${MAX_LOG_SIZE:-104857600}"  # 100MB

# Dry run mode (set to true to see what would be deleted)
DRY_RUN="${DRY_RUN:-false}"

# ============================================================================
# Safety Validation
# ============================================================================

# Validate that a path is under allowed parent directories for deletion
# This prevents accidental deletion of system files if misconfigured
validate_safe_path() {
    local path="$1"
    local allowed_parents=("/dev/shm" "/tmp" "/var/tmp" "/run")

    # Resolve to absolute path
    local resolved_path
    resolved_path=$(realpath -m "$path" 2>/dev/null) || resolved_path="$path"

    for parent in "${allowed_parents[@]}"; do
        if [[ "$resolved_path" == "$parent"* ]]; then
            return 0
        fi
    done

    return 1
}

# Validate BUFFER_DIR at startup
if [[ -n "${BUFFER_DIR:-}" ]] && ! validate_safe_path "$BUFFER_DIR"; then
    echo "ERROR: BUFFER_DIR '$BUFFER_DIR' is not under allowed directories (/dev/shm, /tmp, /var/tmp, /run)" >&2
    echo "This is a safety check to prevent accidental deletion of system files." >&2
    exit 1
fi

# ============================================================================
# Helper Functions
# ============================================================================

log() {
    local level="${1:-INFO}"
    shift
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] [${level}] $*" >&2
}

log_info() { log INFO "$@"; }
log_warn() { log WARN "$@"; }
log_error() { log ERROR "$@"; }
log_debug() { [[ "${DEBUG:-false}" == "true" ]] && log DEBUG "$@" || true; }

# ============================================================================
# Signal Handling
# ============================================================================

# Cleanup function for graceful shutdown
_storage_cleanup() {
    local exit_code=$?
    log_debug "Storage script cleanup triggered (exit code: $exit_code)"
    # Remove any temporary files we may have created
    rm -f -- /tmp/lyrebird-storage-*.tmp 2>/dev/null || true
    exit "$exit_code"
}

# Set up signal handlers for graceful shutdown
trap _storage_cleanup EXIT INT TERM

# Format bytes to human readable
format_bytes() {
    local bytes="$1"
    if [[ $bytes -ge 1073741824 ]]; then
        echo "$(awk "BEGIN {printf \"%.2f\", $bytes/1073741824}")GB"
    elif [[ $bytes -ge 1048576 ]]; then
        echo "$(awk "BEGIN {printf \"%.2f\", $bytes/1048576}")MB"
    elif [[ $bytes -ge 1024 ]]; then
        echo "$(awk "BEGIN {printf \"%.2f\", $bytes/1024}")KB"
    else
        echo "${bytes}B"
    fi
}

# Get disk usage percentage for a path
get_disk_usage() {
    local path="${1:-/}"
    df "$path" 2>/dev/null | tail -1 | awk '{print $5}' | sed 's/%//'
}

# Get free space in MB
get_free_space_mb() {
    local path="${1:-/}"
    df -BM "$path" 2>/dev/null | tail -1 | awk '{print $4}' | sed 's/M//'
}

# Get directory size in bytes
get_dir_size() {
    local path="$1"
    if [[ -d "$path" ]]; then
        du -sb "$path" 2>/dev/null | cut -f1
    else
        echo "0"
    fi
}

# Count files in directory matching pattern
count_files() {
    local path="$1"
    local pattern="${2:-*}"
    find "$path" -maxdepth 1 -name "$pattern" -type f 2>/dev/null | wc -l
}

# Safe delete with dry run support
safe_delete() {
    local path="$1"
    local desc="${2:-file}"

    if [[ "$DRY_RUN" == "true" ]]; then
        log_info "[DRY RUN] Would delete ${desc}: $path"
    else
        log_debug "Deleting ${desc}: $path"
        rm -rf -- "$path"
    fi
}

# ============================================================================
# Cleanup Functions
# ============================================================================

# Clean old recordings based on retention policy
cleanup_recordings() {
    log_info "Cleaning recordings older than ${RECORDING_RETENTION_DAYS} days"

    if [[ ! -d "$RECORDING_DIR" ]]; then
        log_debug "Recording directory does not exist: $RECORDING_DIR"
        return 0
    fi

    local count=0
    local freed_bytes=0

    # Find and delete old recording files
    while IFS= read -r -d '' file; do
        local size
        size=$(stat -c%s "$file" 2>/dev/null || echo 0)
        safe_delete "$file" "recording"
        ((++count))
        ((freed_bytes += size))
    done < <(find "$RECORDING_DIR" -type f \( -name "*.wav" -o -name "*.mp3" -o -name "*.flac" -o -name "*.opus" -o -name "*.ogg" \) -mtime "+${RECORDING_RETENTION_DAYS}" -print0 2>/dev/null)

    # Remove empty directories
    find "$RECORDING_DIR" -type d -empty -delete 2>/dev/null || true

    log_info "Cleaned $count recording file(s), freed $(format_bytes $freed_bytes)"
}

# Clean old log files
cleanup_logs() {
    log_info "Cleaning logs older than ${LOG_RETENTION_DAYS} days"

    local count=0
    local freed_bytes=0

    # Clean LyreBird logs
    if [[ -d "$LOG_DIR" ]]; then
        while IFS= read -r -d '' file; do
            local size
            size=$(stat -c%s "$file" 2>/dev/null || echo 0)
            safe_delete "$file" "log"
            ((++count))
            ((freed_bytes += size))
        done < <(find "$LOG_DIR" -type f -name "*.log*" -mtime "+${LOG_RETENTION_DAYS}" -print0 2>/dev/null)
    fi

    # Clean rotated MediaMTX logs
    if [[ -d "$MEDIAMTX_LOG_DIR" ]]; then
        while IFS= read -r -d '' file; do
            local size
            size=$(stat -c%s "$file" 2>/dev/null || echo 0)
            safe_delete "$file" "mediamtx log"
            ((++count))
            ((freed_bytes += size))
        done < <(find "$MEDIAMTX_LOG_DIR" -type f -name "mediamtx*.out.*" -mtime "+${LOG_RETENTION_DAYS}" -print0 2>/dev/null)
    fi

    log_info "Cleaned $count log file(s), freed $(format_bytes $freed_bytes)"
}

# Clean temporary files
cleanup_temp() {
    log_info "Cleaning temp files older than ${TEMP_RETENTION_HOURS} hours"

    local count=0
    local freed_bytes=0

    # Clean LyreBird temp files in /tmp
    while IFS= read -r -d '' file; do
        local size
        size=$(stat -c%s "$file" 2>/dev/null || echo 0)
        safe_delete "$file" "temp"
        ((++count))
        ((freed_bytes += size))
    done < <(find "$TEMP_DIR" -maxdepth 1 -type f -name "lyrebird-*" -mmin "+$((TEMP_RETENTION_HOURS * 60))" -print0 2>/dev/null)

    # Clean memory buffer directory if present
    if [[ -d "$BUFFER_DIR" ]]; then
        while IFS= read -r -d '' file; do
            local size
            size=$(stat -c%s "$file" 2>/dev/null || echo 0)
            safe_delete "$file" "buffer"
            ((++count))
            ((freed_bytes += size))
        done < <(find "$BUFFER_DIR" -type f -mmin "+$((TEMP_RETENTION_HOURS * 60))" -print0 2>/dev/null)
    fi

    log_info "Cleaned $count temp file(s), freed $(format_bytes $freed_bytes)"
}

# Truncate oversized log files
truncate_large_logs() {
    log_info "Checking for oversized log files"

    # Clean up any stale .tmp files from interrupted previous runs
    find "$MEDIAMTX_LOG_DIR" -name "*.tmp" -mmin +5 -delete 2>/dev/null || true
    [[ -d "$LOG_DIR" ]] && find "$LOG_DIR" -name "*.tmp" -mmin +5 -delete 2>/dev/null || true

    # Check MediaMTX log
    if [[ -f "$MEDIAMTX_LOG" ]]; then
        local size
        size=$(stat -c%s "$MEDIAMTX_LOG" 2>/dev/null || echo 0)
        if [[ $size -gt $MAX_LOG_SIZE ]]; then
            log_warn "MediaMTX log oversized: $(format_bytes $size)"
            if [[ "$DRY_RUN" != "true" ]]; then
                # Keep last 10MB
                tail -c 10485760 "$MEDIAMTX_LOG" > "${MEDIAMTX_LOG}.tmp"
                mv "${MEDIAMTX_LOG}.tmp" "$MEDIAMTX_LOG"
                log_info "Truncated MediaMTX log"
            fi
        fi
    fi

    # Check other log files
    if [[ -d "$LOG_DIR" ]]; then
        for logfile in "$LOG_DIR"/*.log; do
            [[ -f "$logfile" ]] || continue
            local size
            size=$(stat -c%s "$logfile" 2>/dev/null || echo 0)
            if [[ $size -gt $MAX_LOG_SIZE ]]; then
                log_warn "Log file oversized: $logfile ($(format_bytes $size))"
                if [[ "$DRY_RUN" != "true" ]]; then
                    tail -c 10485760 "$logfile" > "${logfile}.tmp"
                    mv "${logfile}.tmp" "$logfile"
                    log_info "Truncated $logfile"
                fi
            fi
        done
    fi
}

# Emergency cleanup - delete oldest files first
emergency_cleanup() {
    log_warn "Running emergency cleanup - disk space critical!"

    # Delete oldest recordings first
    if [[ -d "$RECORDING_DIR" ]]; then
        log_info "Emergency: Removing oldest recordings..."
        local deleted=0
        local max_delete=100

        while IFS= read -r file; do
            safe_delete "$file" "emergency recording"
            ((++deleted))
            [[ $deleted -ge $max_delete ]] && break
        done < <(find "$RECORDING_DIR" -type f \( -name "*.wav" -o -name "*.mp3" -o -name "*.flac" -o -name "*.opus" \) -printf '%T+ %p\n' 2>/dev/null | sort | head -n "$max_delete" | cut -d' ' -f2-)

        log_info "Emergency: Deleted $deleted oldest recording(s)"
    fi

    # Delete all rotated logs
    find "$LOG_DIR" -name "*.gz" -delete 2>/dev/null || true
    find "$MEDIAMTX_LOG_DIR" -name "*.gz" -delete 2>/dev/null || true

    # Clear temp directory
    find "$TEMP_DIR" -maxdepth 1 -name "lyrebird-*" -type f -delete 2>/dev/null || true

    # Clear buffer directory (with safety validation)
    if [[ -d "$BUFFER_DIR" ]] && validate_safe_path "$BUFFER_DIR"; then
        rm -rf "${BUFFER_DIR:?}"/* 2>/dev/null || true
    fi
}

# ============================================================================
# Main Commands
# ============================================================================

# Show storage status
cmd_status() {
    echo "LyreBirdAudio Storage Status"
    echo "============================"
    echo ""

    # Disk usage
    echo "Disk Usage:"
    for path in "/" "/var" "/tmp"; do
        if [[ -d "$path" ]]; then
            local usage
            usage=$(get_disk_usage "$path")
            local free
            free=$(get_free_space_mb "$path")
            local status="OK"
            [[ $usage -ge $DISK_WARNING_PERCENT ]] && status="WARNING"
            [[ $usage -ge $DISK_CRITICAL_PERCENT ]] && status="CRITICAL"
            printf "  %-10s %3d%% used, %sMB free [%s]\n" "$path" "$usage" "$free" "$status"
        fi
    done
    echo ""

    # Recordings
    echo "Recordings:"
    if [[ -d "$RECORDING_DIR" ]]; then
        local rec_size
        rec_size=$(get_dir_size "$RECORDING_DIR")
        local rec_count
        rec_count=$(find "$RECORDING_DIR" -type f 2>/dev/null | wc -l)
        printf "  Path: %s\n" "$RECORDING_DIR"
        printf "  Size: %s\n" "$(format_bytes "$rec_size")"
        printf "  Files: %d\n" "$rec_count"
        printf "  Retention: %d days\n" "$RECORDING_RETENTION_DAYS"
    else
        echo "  No recording directory"
    fi
    echo ""

    # Logs
    echo "Logs:"
    if [[ -d "$LOG_DIR" ]]; then
        local log_size
        log_size=$(get_dir_size "$LOG_DIR")
        printf "  LyreBird logs: %s\n" "$(format_bytes "$log_size")"
    fi
    if [[ -f "$MEDIAMTX_LOG" ]]; then
        local mtx_size
        mtx_size=$(stat -c%s "$MEDIAMTX_LOG" 2>/dev/null || echo 0)
        printf "  MediaMTX log: %s\n" "$(format_bytes "$mtx_size")"
    fi
    echo ""

    # Configuration
    echo "Configuration:"
    printf "  Retention (recordings): %d days\n" "$RECORDING_RETENTION_DAYS"
    printf "  Retention (logs): %d days\n" "$LOG_RETENTION_DAYS"
    printf "  Warning threshold: %d%%\n" "$DISK_WARNING_PERCENT"
    printf "  Critical threshold: %d%%\n" "$DISK_CRITICAL_PERCENT"
    printf "  Emergency threshold: %d%%\n" "$DISK_EMERGENCY_PERCENT"
}

# Run standard cleanup
cmd_cleanup() {
    log_info "Starting storage cleanup"

    cleanup_recordings
    cleanup_logs
    cleanup_temp
    truncate_large_logs

    log_info "Cleanup completed"
}

# Monitor and cleanup if needed
cmd_monitor() {
    local usage
    usage=$(get_disk_usage "/")
    local free_mb
    free_mb=$(get_free_space_mb "/")

    log_debug "Disk usage: ${usage}%, free: ${free_mb}MB"

    if [[ $usage -ge $DISK_EMERGENCY_PERCENT ]] || [[ $free_mb -lt $MIN_FREE_SPACE_MB ]]; then
        log_error "EMERGENCY: Disk ${usage}% full, ${free_mb}MB free"
        emergency_cleanup
        cmd_cleanup
    elif [[ $usage -ge $DISK_CRITICAL_PERCENT ]]; then
        log_warn "CRITICAL: Disk ${usage}% full"
        cmd_cleanup
    elif [[ $usage -ge $DISK_WARNING_PERCENT ]]; then
        log_warn "WARNING: Disk ${usage}% full"
        cleanup_temp
        truncate_large_logs
    else
        log_debug "Disk usage OK: ${usage}%"
    fi
}

# Run emergency cleanup
cmd_emergency() {
    log_warn "Manual emergency cleanup requested"
    emergency_cleanup
    cmd_cleanup
}

# ============================================================================
# Main
# ============================================================================

show_help() {
    cat << EOF
Usage: ${SCRIPT_NAME} [OPTIONS] COMMAND

Storage management for LyreBirdAudio.

Commands:
  status     Show storage status and usage
  cleanup    Run standard cleanup based on retention policy
  monitor    Check disk usage and cleanup if needed
  emergency  Force emergency cleanup (delete oldest files)

Options:
  -h, --help     Show this help message
  -v, --version  Show version
  -n, --dry-run  Show what would be deleted without deleting
  -d, --debug    Enable debug output

Environment Variables:
  RECORDING_RETENTION_DAYS   Days to keep recordings (default: 30)
  LOG_RETENTION_DAYS         Days to keep logs (default: 7)
  DISK_WARNING_PERCENT       Warning threshold (default: 80)
  DISK_CRITICAL_PERCENT      Critical threshold (default: 90)
  DISK_EMERGENCY_PERCENT     Emergency threshold (default: 95)
  MIN_FREE_SPACE_MB          Minimum free space (default: 500)
  LYREBIRD_RECORDING_DIR     Recording directory path
  LYREBIRD_LOG_DIR           Log directory path

Examples:
  ${SCRIPT_NAME} status
  ${SCRIPT_NAME} cleanup
  ${SCRIPT_NAME} --dry-run cleanup
  ${SCRIPT_NAME} monitor

Cron Integration:
  # Daily cleanup at 3 AM
  0 3 * * * ${SCRIPT_NAME} cleanup

  # Hourly monitoring
  0 * * * * ${SCRIPT_NAME} monitor
EOF
}

main() {
    local command=""

    while [[ $# -gt 0 ]]; do
        case "$1" in
            -h|--help)
                show_help
                exit 0
                ;;
            -v|--version)
                echo "${SCRIPT_NAME} v${VERSION}"
                exit 0
                ;;
            -n|--dry-run)
                DRY_RUN="true"
                shift
                ;;
            -d|--debug)
                DEBUG="true"
                shift
                ;;
            status|cleanup|monitor|emergency)
                command="$1"
                shift
                ;;
            *)
                log_error "Unknown option: $1"
                show_help
                exit 1
                ;;
        esac
    done

    if [[ -z "$command" ]]; then
        show_help
        exit 1
    fi

    case "$command" in
        status)
            cmd_status
            ;;
        cleanup)
            cmd_cleanup
            ;;
        monitor)
            cmd_monitor
            ;;
        emergency)
            cmd_emergency
            ;;
    esac
}

main "$@"
