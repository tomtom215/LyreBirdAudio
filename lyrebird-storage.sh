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
#   (--quiet for cleanup and monitor: warnings, errors and one summary line;
#   --once for monitor: one check, which is all monitor ever does)
#
# Configuration: environment variables, or /etc/lyrebird/storage.conf (see
# --help and the "Configuration" section below).
#
# Cron Integration:
#   # Daily cleanup at 3 AM
#   0 3 * * * /usr/local/bin/lyrebird-storage.sh cleanup --quiet
#
#   # Every 15 minutes: silent while the disk is fine
#   */15 * * * * /usr/local/bin/lyrebird-storage.sh monitor --once
#
# Exit status: 0 success, 1 usage error, 3 finished but something could not be
# done: a deletion failed (permission, immutable file, read-only filesystem) or a
# directory could not be listed (see the ERROR lines), 4 finished but lines of the
# configuration file were not accepted.
#
# Version: 1.3.0 - Symlinked and relative directories, listing failures counted,
#                  --quiet/--once, /etc/lyrebird/storage.conf (read as data);
#                  1.2.0: every recording codec covered, empty/active segment
#                  handling, failed deletions surfaced, deterministic eviction

set -euo pipefail

readonly VERSION="1.3.0"
SCRIPT_NAME="$(basename "${BASH_SOURCE[0]}")"
readonly SCRIPT_NAME

# ============================================================================
# Configuration
# ============================================================================

# Configuration file. /etc/lyrebird/storage.conf (README, docs/components.html),
# or the file LYREBIRD_STORAGE_CONFIG names; set to the empty string it means "no
# file". The file is DATA: it is read line by line and never sourced, so nothing
# in it runs and no variable of this script (PATH, IFS, DRY_RUN, ...) can be
# set from it. Each line is KEY=VALUE, a blank line or a # comment; the value is
# bare, 'single-quoted' or "double-quoted" and is taken literally (no expansion);
# a # comment may follow it. KEY must be one of the settings below: the names the
# environment variables have, and RECORDING_DIR and LOG_DIR, which the
# documentation uses, as aliases of LYREBIRD_RECORDING_DIR and LYREBIRD_LOG_DIR
# (the aliases are read from this file only: a variable called LOG_DIR in the
# environment of some other program is not an instruction to delete there). The
# environment wins over the file; a line that cannot be accepted is reported with
# its file and line number, ignored, and makes the run's exit status 4.
# A file that is writable by everyone or owned by another user than root (or the
# user running this) is not read: it decides what gets deleted.
readonly STORAGE_CONFIG_PATH="${LYREBIRD_STORAGE_CONFIG-/etc/lyrebird/storage.conf}"
readonly STORAGE_CONFIG_MAX_BYTES=65536
readonly STORAGE_CONFIG_MAX_LINE=4096
readonly STORAGE_CONFIG_MAX_PROBLEMS=100
readonly STORAGE_CONFIG_KEYS="LYREBIRD_RECORDING_DIR (alias RECORDING_DIR), LYREBIRD_LOG_DIR (alias LOG_DIR), LYREBIRD_TEMP_DIR, LYREBIRD_BUFFER_DIR, MEDIAMTX_LOG, RECORDING_RETENTION_DAYS, LOG_RETENTION_DAYS, TEMP_RETENTION_HOURS, DISK_WARNING_PERCENT, DISK_CRITICAL_PERCENT, DISK_EMERGENCY_PERCENT, MIN_FREE_SPACE_MB, MAX_LOG_SIZE, LYREBIRD_CLOCK_SANE_EPOCH, LYREBIRD_ACTIVE_SEGMENT_SECONDS"
readonly EXIT_CONFIG=4

# Problems found in the configuration file, and the file when it was read
CONFIG_PROBLEMS=0
CONFIG_FILE_USED=""

# The settings: key -> kind of value
declare -gA _CONF_KIND=(
    [LYREBIRD_RECORDING_DIR]=path [RECORDING_DIR]=path
    [LYREBIRD_LOG_DIR]=path [LOG_DIR]=path
    [LYREBIRD_TEMP_DIR]=path [LYREBIRD_BUFFER_DIR]=path [MEDIAMTX_LOG]=path
    [RECORDING_RETENTION_DAYS]=uint [LOG_RETENTION_DAYS]=uint [TEMP_RETENTION_HOURS]=uint
    [DISK_WARNING_PERCENT]=uint [DISK_CRITICAL_PERCENT]=uint [DISK_EMERGENCY_PERCENT]=uint
    [MIN_FREE_SPACE_MB]=uint [MAX_LOG_SIZE]=uint
    [LYREBIRD_CLOCK_SANE_EPOCH]=uint [LYREBIRD_ACTIVE_SEGMENT_SECONDS]=uint
)
declare -gA _CONF_ALIAS_OF=([RECORDING_DIR]=LYREBIRD_RECORDING_DIR [LOG_DIR]=LYREBIRD_LOG_DIR)
# What the file set, by setting; the alias spellings are kept apart so that the
# LYREBIRD_ spelling wins whatever the order of the lines
declare -gA _CONF_VALUE=()
declare -gA _CONF_ALIAS_VALUE=()
declare -gA _CONF_LINE=()

# These run before the logging functions below exist
_conf_log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] [$1] ${*:2}" >&2
}

# _conf_problem FILE LINE KEY TEXT [EXPECTED]: an error, counted
_conf_problem() {
    local where="$1" key="$3" text="$4" expected="${5-}"
    if (($2 > 0)); then
        where="${1}:${2}"
    fi
    CONFIG_PROBLEMS=$((CONFIG_PROBLEMS + 1))
    _conf_log ERROR "${where}: ${key:+${key}: }${text}${expected:+ (expected: ${expected})}"
}

# Read FILE into _CONF_VALUE / _CONF_ALIAS_VALUE. $2 is "yes" when the file was
# asked for by name (LYREBIRD_STORAGE_CONFIG): then a missing file is a problem.
_load_config_file() {
    local file="$1" explicit="$2"
    # character classes mean ASCII, whatever the locale
    local LC_ALL=C
    local line lineno=0 rest key kind canon value body tail st owner mode size
    local re_expansion='[$`\\]'

    if [[ ! -e "$file" ]]; then
        if [[ "$explicit" == "yes" ]]; then
            _conf_problem "$file" 0 "" "does not exist" "the file LYREBIRD_STORAGE_CONFIG names"
        fi
        return 0
    fi
    if [[ ! -f "$file" ]]; then
        _conf_problem "$file" 0 "" "is not a regular file" "a regular file with KEY=value lines"
        return 0
    fi
    if [[ ! -r "$file" ]]; then
        _conf_problem "$file" 0 "" "cannot be read" "a readable file"
        return 0
    fi
    st="$(stat -c '%u %a %s' -- "$file" 2>/dev/null)" || st=""
    read -r owner mode size <<<"$st"
    if [[ ! "$owner" =~ ^[0-9]+$ || ! "$mode" =~ ^[0-7]+$ || ! "$size" =~ ^[0-9]+$ ]]; then
        _conf_problem "$file" 0 "" "its owner and mode cannot be determined, so it is not read"
        return 0
    fi
    if ((8#$mode & 8#002)); then
        _conf_problem "$file" 0 "" "is writable by everyone (mode ${mode}), so it is not read: it decides what is deleted" "a file only root can write"
        return 0
    fi
    if ((owner != 0 && owner != EUID)); then
        _conf_problem "$file" 0 "" "belongs to user ${owner}, so it is not read: it decides what is deleted" "a file owned by root"
        return 0
    fi
    if ((size > STORAGE_CONFIG_MAX_BYTES)); then
        _conf_problem "$file" 0 "" "is ${size} bytes long, more than the ${STORAGE_CONFIG_MAX_BYTES} byte limit" "a short list of KEY=value lines"
        return 0
    fi

    CONFIG_FILE_USED="$file"
    while IFS= read -r line || [[ -n "$line" ]]; do
        lineno=$((lineno + 1))
        if ((CONFIG_PROBLEMS >= STORAGE_CONFIG_MAX_PROBLEMS)); then
            _conf_log ERROR "${file}:${lineno}: stopped reading after ${STORAGE_CONFIG_MAX_PROBLEMS} problems; this line and the rest of the file were not read"
            break
        fi
        # the length is checked before anything else touches the line
        if ((${#line} > STORAGE_CONFIG_MAX_LINE)); then
            if [[ "$line" != "#"* ]]; then
                _conf_problem "$file" "$lineno" "" "line is ${#line} characters long, more than the ${STORAGE_CONFIG_MAX_LINE} character limit"
            fi
            continue
        fi
        if ((lineno == 1)); then
            line="${line#$'\xef\xbb\xbf'}"
        fi
        line="${line%$'\r'}"
        line="${line//$'\t'/ }"
        line="${line#"${line%%[![:space:]]*}"}"
        if [[ -z "$line" || "$line" == "#"* ]]; then
            continue
        fi
        if [[ ! "$line" =~ ^([A-Za-z_][A-Za-z0-9_]*)=(.*)$ ]]; then
            _conf_problem "$file" "$lineno" "" "not a KEY=value line (shell commands are not run): '${line:0:40}'" "KEY=value"
            continue
        fi
        key="${BASH_REMATCH[1]}"
        rest="${BASH_REMATCH[2]}"
        kind="${_CONF_KIND[$key]-}"
        if [[ -z "$kind" ]]; then
            _conf_problem "$file" "$lineno" "$key" "unknown setting" "one of ${STORAGE_CONFIG_KEYS}"
            continue
        fi

        # the value: bare, 'single-quoted' or "double-quoted", then at most a comment
        case "$rest" in
            "'"*)
                body="${rest:1}"
                if [[ "$body" != *"'"* ]]; then
                    _conf_problem "$file" "$lineno" "$key" "unterminated single quote" "a value in matching quotes"
                    continue
                fi
                value="${body%%"'"*}"
                tail="${body#*"'"}"
                ;;
            '"'*)
                body="${rest:1}"
                if [[ "$body" != *'"'* ]]; then
                    _conf_problem "$file" "$lineno" "$key" "unterminated double quote" "a value in matching quotes"
                    continue
                fi
                value="${body%%'"'*}"
                tail="${body#*'"'}"
                if [[ "$value" =~ $re_expansion ]]; then
                    _conf_problem "$file" "$lineno" "$key" "\$, backticks and backslashes are not interpreted in a value" "a plain value, or one in single quotes"
                    continue
                fi
                ;;
            *)
                value="${rest%%[[:space:]]*}"
                tail="${rest#"$value"}"
                if [[ ! "$value" =~ ^[A-Za-z0-9._+:/@%,=-]*$ ]]; then
                    _conf_problem "$file" "$lineno" "$key" "shell syntax is not accepted in a value: '${value:0:40}'" "a plain value, or one in quotes"
                    continue
                fi
                ;;
        esac
        tail="${tail#"${tail%%[![:space:]]*}"}"
        if [[ -n "$tail" && "$tail" != "#"* ]]; then
            _conf_problem "$file" "$lineno" "$key" "unexpected text after the value: '${tail:0:40}'" "one value, optionally followed by a # comment"
            continue
        fi

        case "$kind" in
            uint)
                if [[ ! "$value" =~ ^[0-9]{1,12}$ ]]; then
                    _conf_problem "$file" "$lineno" "$key" "not a whole number: '${value:0:40}'" "digits only, for example 30"
                    continue
                fi
                ;;
            path)
                if [[ "$value" != /* ]]; then
                    _conf_problem "$file" "$lineno" "$key" "not an absolute path: '${value:0:40}'" "a path that starts with /"
                    continue
                fi
                ;;
        esac

        canon="${_CONF_ALIAS_OF[$key]-}"
        if [[ -n "$canon" ]]; then
            _CONF_ALIAS_VALUE[$canon]="$value"
        else
            canon="$key"
            if [[ -n "${_CONF_VALUE[$canon]+x}" ]]; then
                _conf_log WARN "${file}:${lineno}: ${key}: overrides the value on line ${_CONF_LINE[$canon]}"
            fi
            _CONF_VALUE[$canon]="$value"
            _CONF_LINE[$canon]="$lineno"
        fi
    done <"$file"
    return 0
}

# Make what the file set the value of each setting that the environment does not
# set, so that the defaults below ("${NAME:-default}") see it.
_apply_config_file() {
    local key value
    for key in "${!_CONF_KIND[@]}"; do
        [[ -z "${_CONF_ALIAS_OF[$key]-}" ]] || continue
        value="${_CONF_VALUE[$key]-}"
        [[ -n "$value" ]] || value="${_CONF_ALIAS_VALUE[$key]-}"
        [[ -n "$value" ]] || continue
        [[ -z "${!key:-}" ]] || continue
        printf -v "$key" '%s' "$value"
    done
}

if [[ -n "$STORAGE_CONFIG_PATH" ]]; then
    if [[ -n "${LYREBIRD_STORAGE_CONFIG+x}" ]]; then
        _load_config_file "$STORAGE_CONFIG_PATH" yes
    else
        _load_config_file "$STORAGE_CONFIG_PATH" no
    fi
    _apply_config_file
fi

# Paths. Each is made absolute here, once: a relative value is taken relative to
# the directory the script was started in. `find` reads an argument that starts
# with "-" as part of its expression, not as a directory, so a relative
# LYREBIRD_RECORDING_DIR=-rec made every listing fail (hidden by 2>/dev/null) and
# cleanup report "Cleaned 0 recording file(s)" with old files left; an absolute
# path starts with "/".
_absolute_path() {
    case "$1" in
        /*) printf '%s' "$1" ;;
        *) printf '%s/%s' "$PWD" "$1" ;;
    esac
}

_rec_dir="$(_absolute_path "${LYREBIRD_RECORDING_DIR:-/var/lib/mediamtx-ffmpeg/recordings}")"
_log_dir="$(_absolute_path "${LYREBIRD_LOG_DIR:-/var/log/lyrebird}")"
_mtx_log="$(_absolute_path "${MEDIAMTX_LOG:-/var/log/mediamtx.out}")"
_tmp_dir="$(_absolute_path "${LYREBIRD_TEMP_DIR:-/tmp}")"
_buf_dir="$(_absolute_path "${LYREBIRD_BUFFER_DIR:-/dev/shm/lyrebird-buffer}")"
# The directory of the MediaMTX log (for a file directly under /, that is /)
_mtx_log_dir="${_mtx_log%/*}"
[[ -n "$_mtx_log_dir" ]] || _mtx_log_dir="/"

readonly RECORDING_DIR="$_rec_dir"
readonly LOG_DIR="$_log_dir"
readonly MEDIAMTX_LOG="$_mtx_log"
readonly MEDIAMTX_LOG_DIR="$_mtx_log_dir"
readonly TEMP_DIR="$_tmp_dir"
readonly BUFFER_DIR="$_buf_dir"
unset _rec_dir _log_dir _mtx_log _mtx_log_dir _tmp_dir _buf_dir

# Coerce a value to a non-negative base-10 integer, falling back to a default
# when the input is not all digits. A non-numeric env value (e.g. an operator
# setting RECORDING_RETENTION_DAYS=none/unlimited to "keep everything") would
# otherwise make the arithmetic clamps below trip `nounset` and ABORT the whole
# script at load — silently stopping the daily cleanup and hourly monitor crons
# and letting the disk fill. Base-10 also stops values like 08/09 from being
# misread as invalid octal later.
_coerce_uint() {
    local value="$1" default="$2"
    if [[ "$value" =~ ^[0-9]+$ ]]; then
        printf '%s' "$((10#$value))"
    else
        printf '%s' "$default"
    fi
}

# Retention policies (in days) - must be positive integers
_rec_ret=$(_coerce_uint "${RECORDING_RETENTION_DAYS:-30}" 30)
_log_ret=$(_coerce_uint "${LOG_RETENTION_DAYS:-7}" 7)
_tmp_ret=$(_coerce_uint "${TEMP_RETENTION_HOURS:-24}" 24)

# Ensure retention values are positive (minimum 1)
((_rec_ret < 1)) && _rec_ret=1
((_log_ret < 1)) && _log_ret=1
((_tmp_ret < 1)) && _tmp_ret=1

readonly RECORDING_RETENTION_DAYS="$_rec_ret"
readonly LOG_RETENTION_DAYS="$_log_ret"
readonly TEMP_RETENTION_HOURS="$_tmp_ret"
unset _rec_ret _log_ret _tmp_ret

# Clock-sanity floor for age-based recording deletion. An RTC-less Pi boots
# with its clock in 1970 until NTP syncs; recordings captured in that window
# carry mtimes decades in the past, and the moment the clock steps to the real
# date `find -mtime +N` sees minutes-old data as 56 years old and deletes it.
# No recording can legitimately predate the project, so any mtime before this
# epoch (default 2025-01-01) means "written with a broken clock, real age
# unknown" -- age-based cleanup must keep it. Emergency size-based cleanup is
# deliberately NOT gated on this: a full disk must still be freed.
_clock_floor=$(_coerce_uint "${LYREBIRD_CLOCK_SANE_EPOCH:-1735689600}" 1735689600)
readonly CLOCK_SANE_EPOCH="$_clock_floor"
unset _clock_floor

# Recording file extensions: the ONE list that retention, emergency eviction and
# `status` all use. lyrebird-stream-manager.sh records through FFmpeg's segment
# muxer to `audio_%03d.${CODEC}`, so the extension IS the CODEC value and FFmpeg
# picks the container from it: opus -> .opus (Ogg Opus), aac -> .aac (ADTS),
# mp3 -> .mp3 (verified with ffmpeg 6.1.1). Any other CODEC is encoded with
# libopus under its own name, which only produces a recording where that
# container accepts Opus (ogg); the other names still leave empty or truncated
# files behind when the muxer refuses the stream (flac, m4a, adts, wav).
# adts/m4a are the other names FFmpeg gives AAC. wav/flac cover recordings from
# other tools and earlier releases. tests/test_storage_codecs.bats fails when the
# manager gains a CODEC that is missing here.
readonly RECORDING_EXTENSIONS=(opus ogg aac adts m4a mp3 flac wav)

# find(1) test matching RECORDING_EXTENSIONS, built once from the list above.
RECORDING_NAME_TEST=()
for _ext in "${RECORDING_EXTENSIONS[@]}"; do
    if ((${#RECORDING_NAME_TEST[@]} > 0)); then
        RECORDING_NAME_TEST+=(-o)
    fi
    RECORDING_NAME_TEST+=(-name "*.${_ext}")
done
RECORDING_NAME_TEST=(\( "${RECORDING_NAME_TEST[@]}" \))
readonly RECORDING_NAME_TEST
unset _ext

# How long a file may sit unmodified and still count as part of a stream that is
# recording right now. Emergency eviction never touches such a file, and an
# empty segment younger than this is a segment being opened, not debris.
# Measured with ffmpeg 6.1.1 (the manager's tee + segment muxer): the segment in
# progress is a 0-byte file whose mtime stays at its creation time until the
# first 256 KiB chunk is flushed (16 s at 128 kb/s; 350 s at 6 kb/s, the lowest
# useful audio rate), then the mtime advances once per chunk. 900 s is well
# above that; a hard-killed FFmpeg leaves the in-progress segment at 0 bytes (or
# cut at a 256 KiB boundary, which still decodes), so such debris ages past this
# window and is removed. Floor 60 s so 0 cannot disable the protection.
_active_window=$(_coerce_uint "${LYREBIRD_ACTIVE_SEGMENT_SECONDS:-900}" 900)
((_active_window < 60)) && _active_window=60
readonly ACTIVE_SEGMENT_SECONDS="$_active_window"
unset _active_window

# Disk thresholds (percentage) - validate bounds 0-100
_disk_warning=$(_coerce_uint "${DISK_WARNING_PERCENT:-80}" 80)
_disk_critical=$(_coerce_uint "${DISK_CRITICAL_PERCENT:-90}" 90)
_disk_emergency=$(_coerce_uint "${DISK_EMERGENCY_PERCENT:-95}" 95)

# Clamp percentage values to valid range
((_disk_warning > 100)) && _disk_warning=100
((_disk_critical > 100)) && _disk_critical=100
((_disk_emergency > 100)) && _disk_emergency=100

readonly DISK_WARNING_PERCENT="$_disk_warning"
readonly DISK_CRITICAL_PERCENT="$_disk_critical"
readonly DISK_EMERGENCY_PERCENT="$_disk_emergency"
unset _disk_warning _disk_critical _disk_emergency

# Minimum free space (MB) - must be a non-negative integer
_min_free=$(_coerce_uint "${MIN_FREE_SPACE_MB:-500}" 500)
readonly MIN_FREE_SPACE_MB="$_min_free"
unset _min_free

# Log file size limits (bytes)
_max_log_size=$(_coerce_uint "${MAX_LOG_SIZE:-104857600}" 104857600)
((_max_log_size < 1)) && _max_log_size=104857600
readonly MAX_LOG_SIZE="$_max_log_size" # default 100MB
unset _max_log_size

# Dry run mode (set to true to see what would be deleted)
DRY_RUN="${DRY_RUN:-false}"

# Exit status of a run that finished but could not delete at least one file
# (permission, immutable bit, read-only filesystem, ...). 1 stays "usage error";
# 2 is lyrebird-common's E_PERMISSION, which this is not specific to.
readonly EXIT_DELETE_FAILED=3

# Deletions that failed in this run; every delete goes through safe_delete.
DELETE_FAILURES=0

# Files removed (or, in a dry run, that would be) in this run and their size in
# bytes, for the summary line; safe_delete keeps them.
RUN_FILES=0
RUN_BYTES=0

# Most files one emergency run evicts, so a single run stays short; the next
# monitor run continues.
readonly EMERGENCY_MAX_DELETE=100

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
        # Require trailing slash match to prevent /tmp-evil matching /tmp
        if [[ "$resolved_path" == "$parent/"* ]] || [[ "$resolved_path" == "$parent" ]]; then
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

# The log is stderr: this script writes nothing to stdout except `status`. With
# --quiet (QUIET=true) the informational lines are dropped and warnings, errors
# and the one summary line of the run (log_summary) remain; a cron job then
# mails, or an `>> file 2>&1` redirection keeps, one line per run plus whatever
# needs attention.
QUIET=false

log() {
    local level="${1:-INFO}"
    shift
    if [[ "$QUIET" == "true" && "$level" == "INFO" ]]; then
        return 0
    fi
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] [${level}] $*" >&2
}

log_info() { log INFO "$@"; }
log_warn() { log WARN "$@"; }
log_error() { log ERROR "$@"; }
log_debug() { [[ "${DEBUG:-false}" == "true" ]] && log DEBUG "$@" || true; }
# The one line --quiet still prints at INFO level
log_summary() {
    local QUIET=false
    log INFO "$@"
}

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

# Get disk usage percentage for a path.
# Uses POSIX `df -P`, which guarantees single-line output: a plain `df` wraps a
# long filesystem name (LVM/LUKS/`/dev/mapper/...`, common on field boxes) onto
# its own line, so `tail -1 | awk '{print $5}'` then reads the MOUNT POINT column
# instead of Use%. That returned a non-numeric value ("/"), the threshold tests
# (`[[ "/" -ge 95 ]]`) errored, and a FULL disk was silently reported "OK" with
# no cleanup — a direct data-loss path. Emits an empty string if df can't be
# parsed; callers must treat that as "unknown", never as "OK".
get_disk_usage() {
    local path="${1:-/}" out=""
    # `|| out=""` keeps a df failure (path gone) from propagating out of the
    # pipeline and aborting the caller under `set -euo pipefail`.
    out=$(df -P "$path" 2>/dev/null | awk 'NR==2 {print $5}' | tr -cd '0-9') || out=""
    printf '%s' "$out"
}

# Get inode usage percentage for a path (POSIX `df -Pi`). A recorder writing
# many small files can exhaust INODES long before blocks: writes then fail
# with ENOSPC while block-based monitoring still reports the disk "OK", so no
# cleanup ever runs -- silent recording failure. Emits an empty string when
# inode accounting is unavailable (e.g. btrfs reports "-"); callers treat that
# as unknown, never as pressure.
get_inode_usage() {
    local path="${1:-/}" out=""
    out=$(df -Pi "$path" 2>/dev/null | awk 'NR==2 {print $5}' | tr -cd '0-9') || out=""
    printf '%s' "$out"
}

# Get free space in MB for a path (POSIX `df -Pk` → 1024-byte blocks).
# Emits an empty string if df can't be parsed (caller treats as "unknown").
get_free_space_mb() {
    local path="${1:-/}" kb=""
    kb=$(df -Pk "$path" 2>/dev/null | awk 'NR==2 {print $4}' | tr -cd '0-9') || kb=""
    [[ -n "$kb" ]] && printf '%s' "$((kb / 1024))"
    return 0
}

# Get directory size in bytes
get_dir_size() {
    local path="$1"
    if [[ -d "$path" ]]; then
        # du exits 1 for a subdirectory it cannot read but still prints the total
        # of the rest; under pipefail and errexit that status used to end `status`
        # right after its "Recordings:" heading, printing nothing more.
        { du -sbD "$path" 2>/dev/null || true; } | cut -f1
    else
        echo "0"
    fi
}

# Count files in directory matching pattern
count_files() {
    local path="$1"
    local pattern="${2:-*}"
    find -H "$path" -maxdepth 1 -name "$pattern" -type f 2>/dev/null | wc -l
}

# Safe delete with dry run support. Returns 0 when the file is gone (or, in a dry
# run, would be) and 1 when rm refused; a refusal is logged with rm's reason and
# counted in DELETE_FAILURES so the run's exit status reports it. Under
# `set -e` an unhandled rm failure used to abort the whole run mid-cleanup, so
# nothing after the first stuck file was cleaned and no summary was logged.
# Files only: there is no -r, so a path swapped for a directory between the
# listing and the removal fails instead of taking a tree with it.
safe_delete() {
    local path="$1"
    local desc="${2:-file}"
    local err size

    # what the run's summary reports (stat does not follow a symlink)
    size=$(stat -c%s -- "$path" 2>/dev/null || echo 0)

    if [[ "$DRY_RUN" == "true" ]]; then
        log_info "[DRY RUN] Would delete ${desc}: $path"
        RUN_FILES=$((RUN_FILES + 1))
        RUN_BYTES=$((RUN_BYTES + size))
        return 0
    fi

    log_debug "Deleting ${desc}: $path"
    if err=$(rm -f -- "$path" 2>&1); then
        RUN_FILES=$((RUN_FILES + 1))
        RUN_BYTES=$((RUN_BYTES + size))
        return 0
    fi
    # Already gone (another run, or the recorder reusing the slot): done.
    if [[ ! -e "$path" && ! -L "$path" ]]; then
        return 0
    fi
    ((++DELETE_FAILURES))
    log_error "Cannot delete ${desc} ${path}: ${err:-rm failed}"
    return 1
}

# Totals of the current _sweep calls; _sweep_reset starts a new tally.
SWEEP_DELETED=0
SWEEP_FAILED=0
SWEEP_FREED=0

_sweep_reset() {
    SWEEP_DELETED=0
    SWEEP_FAILED=0
    SWEEP_FREED=0
}

# Directory listings that failed in this run. A listing that could not be made
# is not "nothing to clean": `find ... 2>/dev/null` used to turn an unreadable
# directory (or any other find failure) into an empty result and a clean run.
SCAN_FAILURES=0

# A listing is NUL-separated records. When find fails, _find0 ends its listing
# with one record that starts with this tag (real records are absolute paths, or
# "<mtime> <path>" from _list_oldest_first, so none can look like it) and carries
# find's exit status and the directory; _next_record reads it as the end of the
# listing and counts it. find's own message ("find: '/x': Permission denied") is
# left on stderr.
readonly FIND_FAILED_TAG='!find-failed:'

# find -H DIR [ARGS...], with the listing protocol above. -ignore_readdir_race:
# a file that goes away between find reading its directory entry and looking at
# it (the recorder rotating a segment) is not an error; it would only make a run
# of a live system fail now and then.
_find0() {
    local dir="$1" rc=0
    shift
    find -H "$dir" -ignore_readdir_race "$@" || rc=$?
    if ((rc != 0)); then
        printf '%s%d:%s\0' "$FIND_FAILED_TAG" "$rc" "$dir"
    fi
    return 0
}

# Read the next record of a listing from stdin into the variable named $1.
# Returns 1 at the end of the listing; a failure record ends it too, after it has
# been counted in SCAN_FAILURES and logged.
_next_record() {
    local failure rc dir
    IFS= read -r -d '' "$1" || return 1
    if [[ "${!1}" == "$FIND_FAILED_TAG"* ]]; then
        failure="${!1#"$FIND_FAILED_TAG"}"
        rc="${failure%%:*}"
        dir="${failure#*:}"
        ((++SCAN_FAILURES))
        log_error "Cannot list ${dir} completely: find exited with status ${rc} (its message is above); the files it could not reach were not examined"
        return 1
    fi
    return 0
}

# Count the records of a listing read from stdin into COUNT_RECORDS.
COUNT_RECORDS=0
_count_records() {
    # shellcheck disable=SC2034  # _next_record fills `record`; only the count matters
    local record
    COUNT_RECORDS=0
    while _next_record record; do
        ((++COUNT_RECORDS))
    done
}

# Delete every NUL-separated path read from stdin through safe_delete, adding to
# the SWEEP_* totals. A failure is counted and the sweep carries on.
_sweep() {
    local desc="$1" file size
    while _next_record file; do
        size=$(stat -c%s -- "$file" 2>/dev/null || echo 0)
        if safe_delete "$file" "$desc"; then
            ((++SWEEP_DELETED))
            SWEEP_FREED=$((SWEEP_FREED + size))
        else
            ((++SWEEP_FAILED))
        fi
    done
    return 0
}

# "; N deletion(s) FAILED" when N > 0, nothing otherwise (for summary lines).
_failed_suffix() {
    if (($1 > 0)); then
        printf '; %d deletion(s) FAILED' "$1"
    fi
}

# End-of-command verdict: the run's exit status is EXIT_DELETE_FAILED when any
# deletion failed or any directory could not be listed, 0 otherwise.
_report_delete_failures() {
    local rc=0
    if ((DELETE_FAILURES > 0)); then
        log_error "Run finished with ${DELETE_FAILURES} failed deletion(s); the files named in the errors above are still on disk"
        rc="$EXIT_DELETE_FAILED"
    fi
    if ((SCAN_FAILURES > 0)); then
        log_error "Run finished with ${SCAN_FAILURES} directory listing(s) that failed; what could not be listed was not cleaned (see the errors above)"
        rc="$EXIT_DELETE_FAILED"
    fi
    return "$rc"
}

# True when mtime $1 (epoch seconds) lies within ACTIVE_SEGMENT_SECONDS of now $2
# (either side: a file dated in the future by more than the window cannot be an
# active write, it was stamped by a clock that has since been corrected).
_recently_modified() {
    local age=$(($2 - $1))
    if ((age < 0)); then
        age=$((-age))
    fi
    ((age <= ACTIVE_SEGMENT_SECONDS))
}

# Regular files under $1 that match the find arguments after it, oldest first,
# as NUL-terminated "<mtime> <path>" records. A symlink given as $1 itself is
# followed (-H): /var/lib/.../recordings -> /mnt/usb is a normal setup, and
# without -H find sees only the link and reports nothing, so retention and
# eviction silently did nothing. Symlinks found INSIDE the tree are never
# followed (-type f excludes them), so nothing outside the configured directory
# can be reached through one. Equal mtimes are ordered by path
# in byte order (LC_ALL=C), so the same tree is always evicted in the same
# order whatever the locale. NUL-terminated because a name may contain a
# newline: the old newline-separated pipeline turned the tail of such a name
# into a separate "path", which was then deleted relative to the current
# directory.
_list_oldest_first() {
    local root="$1" rc=0
    shift
    find -H "$root" -ignore_readdir_race -type f "$@" -printf '%T@ %p\0' | LC_ALL=C sort -z -k1,1n -k2 || rc=$?
    # the failure record comes after the sorted list (see _find0)
    if ((rc != 0)); then
        printf '%s%d:%s\0' "$FIND_FAILED_TAG" "$rc" "$root"
    fi
    return 0
}

# Delete the oldest files under $1, at most $2 attempts (0 = no limit), logging
# each as $3 and passing the remaining arguments to find. A file modified within
# ACTIVE_SEGMENT_SECONDS is never touched: it belongs to a stream that is
# recording now, and deleting the open segment would lose its audio and free
# nothing until FFmpeg closes it. Totals land in EVICT_DELETED / EVICT_FAILED /
# EVICT_FREED (bytes) / EVICT_PROTECTED.
_evict_oldest_first() {
    local root="$1" max="$2" desc="$3" rec file size mtime now
    shift 3
    EVICT_DELETED=0
    EVICT_FAILED=0
    EVICT_FREED=0
    EVICT_PROTECTED=0
    now=$(date +%s)
    while _next_record rec; do
        mtime="${rec%% *}"
        file="${rec#* }"
        if _recently_modified "${mtime%%.*}" "$now"; then
            ((++EVICT_PROTECTED))
            continue
        fi
        size=$(stat -c%s -- "$file" 2>/dev/null || echo 0)
        if safe_delete "$file" "$desc"; then
            ((++EVICT_DELETED))
            EVICT_FREED=$((EVICT_FREED + size))
        else
            ((++EVICT_FAILED))
        fi
        if ((max > 0 && EVICT_DELETED + EVICT_FAILED >= max)); then
            break
        fi
    done < <(_list_oldest_first "$root" "$@")
    return 0
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

    # With an unsynced clock every file age is meaningless -- defer age-based
    # deletion until the clock is sane (the next cron run after NTP syncs).
    local now_epoch
    now_epoch=$(date +%s)
    if [[ "$now_epoch" -lt "$CLOCK_SANE_EPOCH" ]]; then
        log_warn "System clock ($now_epoch) predates ${CLOCK_SANE_EPOCH} (not yet NTP-synced?); skipping age-based recording cleanup"
        return 0
    fi

    local count=0
    local freed_bytes=0
    local kept_broken_clock=0
    local failed=0
    local empty_removed=0
    local file mtime size

    # Empty segments no stream has touched for ACTIVE_SEGMENT_SECONDS are debris
    # (crash, ENOSPC, a muxer that refused the stream), not recordings: remove
    # them now instead of letting them sit for the whole retention period. A
    # younger empty file is a segment being opened (FFmpeg keeps the segment in
    # progress at 0 bytes until its first flush). Same clock rule as below: a
    # pre-CLOCK_SANE_EPOCH mtime has no known age, so it is kept.
    while _next_record file; do
        mtime=$(stat -c%Y -- "$file" 2>/dev/null || echo 0)
        if [[ "$mtime" -lt "$CLOCK_SANE_EPOCH" ]] || _recently_modified "$mtime" "$now_epoch"; then
            continue
        fi
        if safe_delete "$file" "empty recording segment"; then
            ((++empty_removed))
        else
            ((++failed))
        fi
    done < <(_find0 "$RECORDING_DIR" -type f "${RECORDING_NAME_TEST[@]}" -empty -print0)

    # Find and delete old recording files
    while _next_record file; do
        # A pre-CLOCK_SANE_EPOCH mtime means the file was written while the
        # clock was broken; its real age is unknown and it may be minutes old.
        mtime=$(stat -c%Y "$file" 2>/dev/null || echo 0)
        if [[ "$mtime" -lt "$CLOCK_SANE_EPOCH" ]]; then
            ((++kept_broken_clock))
            continue
        fi
        size=$(stat -c%s "$file" 2>/dev/null || echo 0)
        if safe_delete "$file" "recording"; then
            ((++count))
            freed_bytes=$((freed_bytes + size))
        else
            ((++failed))
        fi
    done < <(_find0 "$RECORDING_DIR" -type f "${RECORDING_NAME_TEST[@]}" -mtime "+${RECORDING_RETENTION_DAYS}" -print0)

    if [[ $kept_broken_clock -gt 0 ]]; then
        log_warn "Kept $kept_broken_clock recording(s) with pre-${CLOCK_SANE_EPOCH} mtimes (written before NTP sync; real age unknown)"
    fi

    # Remove empty SUBdirectories. `-mindepth 1` is essential: without it, once
    # retention removes the last recordings, find would delete "$RECORDING_DIR"
    # itself, and if the recorder does not recreate it on the next write, every
    # subsequent recording silently fails — permanent data loss on an
    # unattended box.
    if [[ "$DRY_RUN" == "true" ]]; then
        # a dry run removes nothing, directories included
        while _next_record file; do
            log_info "[DRY RUN] Would remove empty directory: $file"
        done < <(_find0 "$RECORDING_DIR" -mindepth 1 -type d -empty -print0)
    else
        local sweep_rc=0
        find -H "$RECORDING_DIR" -ignore_readdir_race -mindepth 1 -type d -empty -delete || sweep_rc=$?
        if ((sweep_rc != 0)); then
            ((++SCAN_FAILURES))
            log_error "Cannot sweep the empty directories of ${RECORDING_DIR} completely: find exited with status ${sweep_rc} (its message is above)"
        fi
    fi

    if [[ $empty_removed -gt 0 ]]; then
        log_info "Removed $empty_removed empty recording segment(s) idle for over ${ACTIVE_SEGMENT_SECONDS}s"
    fi
    log_info "Cleaned $count recording file(s), freed $(format_bytes $freed_bytes)$(_failed_suffix "$failed")"
}

# Clean old log files
cleanup_logs() {
    log_info "Cleaning logs older than ${LOG_RETENTION_DAYS} days"

    _sweep_reset

    # Clean LyreBird logs
    if [[ -d "$LOG_DIR" ]]; then
        _sweep "log" < <(_find0 "$LOG_DIR" -type f -name "*.log*" -mtime "+${LOG_RETENTION_DAYS}" -print0)
    fi

    # Clean rotated MediaMTX logs
    if [[ -d "$MEDIAMTX_LOG_DIR" ]]; then
        _sweep "mediamtx log" < <(_find0 "$MEDIAMTX_LOG_DIR" -type f -name "mediamtx*.out.*" -mtime "+${LOG_RETENTION_DAYS}" -print0)
    fi

    log_info "Cleaned $SWEEP_DELETED log file(s), freed $(format_bytes "$SWEEP_FREED")$(_failed_suffix "$SWEEP_FAILED")"
}

# Clean temporary files
cleanup_temp() {
    log_info "Cleaning temp files older than ${TEMP_RETENTION_HOURS} hours"

    _sweep_reset

    # Clean LyreBird temp files in /tmp
    if [[ -d "$TEMP_DIR" ]]; then
        _sweep "temp" < <(_find0 "$TEMP_DIR" -maxdepth 1 -type f -name "lyrebird-*" -mmin "+$((TEMP_RETENTION_HOURS * 60))" -print0)
    fi

    # Clean memory buffer directory if present
    if [[ -d "$BUFFER_DIR" ]]; then
        _sweep "buffer" < <(_find0 "$BUFFER_DIR" -type f -mmin "+$((TEMP_RETENTION_HOURS * 60))" -print0)
    fi

    log_info "Cleaned $SWEEP_DELETED temp file(s), freed $(format_bytes "$SWEEP_FREED")$(_failed_suffix "$SWEEP_FAILED")"
}

# Truncate oversized log files
truncate_large_logs() {
    log_info "Checking for oversized log files"

    # Clean up any stale .tmp files from interrupted previous runs.
    # MEDIAMTX_LOG_DIR is typically /var/log, so scope tightly to our own files
    # (maxdepth 1 + mediamtx-prefixed) rather than every *.tmp on the system.
    # They go through safe_delete like every other deletion: a dry run leaves them,
    # a refusal is logged and counted (it used to be `-delete 2>/dev/null || true`).
    _sweep_reset
    if [[ -d "$MEDIAMTX_LOG_DIR" ]]; then
        _sweep "stale temp" < <(_find0 "$MEDIAMTX_LOG_DIR" -maxdepth 1 \( -type f -o -type l \) -name "mediamtx*.tmp" -mmin +5 -print0)
    fi
    if [[ -d "$LOG_DIR" ]]; then
        _sweep "stale temp" < <(_find0 "$LOG_DIR" -maxdepth 1 \( -type f -o -type l \) -name "*.tmp" -mmin +5 -print0)
    fi
    if ((SWEEP_DELETED + SWEEP_FAILED > 0)); then
        log_info "Removed $SWEEP_DELETED stale temp file(s)$(_failed_suffix "$SWEEP_FAILED")"
    fi

    # Check MediaMTX log
    if [[ -f "$MEDIAMTX_LOG" ]]; then
        local size
        size=$(stat -c%s "$MEDIAMTX_LOG" 2>/dev/null || echo 0)
        if [[ $size -gt $MAX_LOG_SIZE ]]; then
            log_warn "MediaMTX log oversized: $(format_bytes $size)"
            if [[ "$DRY_RUN" != "true" ]]; then
                # Keep last 10MB, truncating IN PLACE (preserve the inode). The
                # old `mv tmp log` swapped in a new inode, so a process holding
                # the log open (systemd `append:`, MediaMTX's stdout fd) kept
                # writing to the now-unlinked old inode: its space was never
                # reclaimed and it grew invisibly until the disk filled, while
                # `stat` on the path still showed ~10MB so this never re-fired.
                if tail -c 10485760 "$MEDIAMTX_LOG" >"${MEDIAMTX_LOG}.tmp" 2>/dev/null; then
                    cat "${MEDIAMTX_LOG}.tmp" >"$MEDIAMTX_LOG" 2>/dev/null || true
                    log_info "Truncated MediaMTX log"
                fi
                rm -f "${MEDIAMTX_LOG}.tmp" 2>/dev/null || true
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
                    # Truncate in place (preserve inode) so a process holding
                    # the file open keeps writing to the same inode. See the
                    # MediaMTX-log note above.
                    if tail -c 10485760 "$logfile" >"${logfile}.tmp" 2>/dev/null; then
                        cat "${logfile}.tmp" >"$logfile" 2>/dev/null || true
                        log_info "Truncated $logfile"
                    fi
                    rm -f "${logfile}.tmp" 2>/dev/null || true
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
        # 1. Empty segments (debris of a crash, ENOSPC or a muxer that refused the
        #    stream): they hold no audio and cost an inode each.
        _evict_oldest_first "$RECORDING_DIR" "$EMERGENCY_MAX_DELETE" "emergency empty segment" "${RECORDING_NAME_TEST[@]}" -empty
        local empty_deleted=$EVICT_DELETED empty_failed=$EVICT_FAILED protected=$EVICT_PROTECTED
        # 2. Then the oldest recordings that hold audio, truncated ones included
        #    (a killed FFmpeg leaves a decodable prefix).
        _evict_oldest_first "$RECORDING_DIR" "$EMERGENCY_MAX_DELETE" "emergency recording" "${RECORDING_NAME_TEST[@]}" ! -empty
        protected=$((protected + EVICT_PROTECTED))
        log_info "Emergency: Deleted $empty_deleted empty segment(s)$(_failed_suffix "$empty_failed")"
        log_info "Emergency: Deleted $EVICT_DELETED oldest recording(s)$(_failed_suffix "$EVICT_FAILED")"
        if ((protected > 0)); then
            log_info "Emergency: Left $protected file(s) written in the last ${ACTIVE_SEGMENT_SECONDS}s alone (active streams)"
        fi
    fi

    # Delete rotated logs and temp files.
    # These must honour DRY_RUN (a "preview" must not delete anything), and the
    # *.gz sweep must be tightly scoped: MEDIAMTX_LOG_DIR is typically /var/log,
    # so a bare `find -H "$MEDIAMTX_LOG_DIR" -name '*.gz' -delete` would wipe every
    # rotated SYSTEM log (syslog, auth.log, journal exports) during an incident.
    if [[ "$DRY_RUN" == "true" ]]; then
        log_info "[DRY RUN] Would delete rotated LyreBird/MediaMTX logs and LyreBird temp files"
    else
        _sweep_reset
        if [[ -d "$LOG_DIR" ]]; then
            _sweep "rotated log" < <(_find0 "$LOG_DIR" -maxdepth 1 -type f -name "*.gz" -print0)
        fi
        if [[ -d "$MEDIAMTX_LOG_DIR" ]]; then
            _sweep "rotated mediamtx log" < <(_find0 "$MEDIAMTX_LOG_DIR" -maxdepth 1 -type f -name "mediamtx*.out*.gz" -print0)
        fi

        # Clear LyreBird temp files
        if [[ -d "$TEMP_DIR" ]]; then
            _sweep "temp" < <(_find0 "$TEMP_DIR" -maxdepth 1 -name "lyrebird-*" -type f -print0)
        fi
        log_info "Emergency: Deleted $SWEEP_DELETED rotated log/temp file(s)$(_failed_suffix "$SWEEP_FAILED")"
    fi

    # Clear the segment ring buffer (with safety validation): its files, never
    # its directories. The recorder creates "$BUFFER_DIR/<stream>" once, when the
    # stream starts, and FFmpeg's segment muxer cannot recreate it: with the
    # directory gone the tee drops its recording leg at the next segment
    # ("Failed to open segment ... No such file or directory, continuing with
    # 1/2 slaves"), so local recording silently stopped until that stream was
    # restarted. Files written in the last ACTIVE_SEGMENT_SECONDS are the open
    # segment and are left alone like everywhere else.
    if [[ -d "$BUFFER_DIR" ]] && validate_safe_path "$BUFFER_DIR"; then
        _evict_oldest_first "$BUFFER_DIR" 0 "emergency buffer file"
        log_info "Emergency: Deleted $EVICT_DELETED buffer file(s)$(_failed_suffix "$EVICT_FAILED")"
        if ((EVICT_PROTECTED > 0)); then
            log_info "Emergency: Left $EVICT_PROTECTED buffer file(s) written in the last ${ACTIVE_SEGMENT_SECONDS}s alone (active streams)"
        fi
    fi
    return 0
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
            local usage free status
            usage=$(get_disk_usage "$path")
            free=$(get_free_space_mb "$path")
            if [[ "$usage" =~ ^[0-9]+$ ]]; then
                status="OK"
                [[ $usage -ge $DISK_WARNING_PERCENT ]] && status="WARNING"
                [[ $usage -ge $DISK_CRITICAL_PERCENT ]] && status="CRITICAL"
                printf "  %-10s %3d%% used, %sMB free [%s]\n" "$path" "$usage" "${free:-?}" "$status"
            else
                # Non-numeric usage => df output could not be parsed; never
                # crash `status` on a printf %d error, just say so.
                printf "  %-10s   unknown (df unparseable)\n" "$path"
            fi
        fi
    done
    echo ""

    # Recordings
    echo "Recordings:"
    if [[ -d "$RECORDING_DIR" ]]; then
        local rec_size
        rec_size=$(get_dir_size "$RECORDING_DIR")
        local rec_count empty_count scan_failures_before="$SCAN_FAILURES"
        # An unreadable subdirectory is reported (find's message and a failure
        # record), not left out of the count unseen, and does not stop `status`.
        _count_records < <(_find0 "$RECORDING_DIR" -type f "${RECORDING_NAME_TEST[@]}" ! -empty -print0)
        rec_count="$COUNT_RECORDS"
        _count_records < <(_find0 "$RECORDING_DIR" -type f "${RECORDING_NAME_TEST[@]}" -empty -print0)
        empty_count="$COUNT_RECORDS"
        printf "  Path: %s\n" "$RECORDING_DIR"
        printf "  Size: %s\n" "$(format_bytes "$rec_size")"
        printf "  Files: %d\n" "$rec_count"
        printf "  Empty segments: %d\n" "$empty_count"
        if ((SCAN_FAILURES > scan_failures_before)); then
            printf "  (incomplete: part of %s could not be read, see the errors above)\n" "$RECORDING_DIR"
        fi
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
    printf "  Config file: %s\n" "${CONFIG_FILE_USED:-none}"
    printf "  Retention (recordings): %d days\n" "$RECORDING_RETENTION_DAYS"
    printf "  Retention (logs): %d days\n" "$LOG_RETENTION_DAYS"
    printf "  Warning threshold: %d%%\n" "$DISK_WARNING_PERCENT"
    printf "  Critical threshold: %d%%\n" "$DISK_CRITICAL_PERCENT"
    printf "  Emergency threshold: %d%%\n" "$DISK_EMERGENCY_PERCENT"
}

# What this run did, for the one summary line: "removed N file(s), X freed" (in a
# dry run "would remove ..."), and what failed
_run_totals() {
    local verb="removed"
    [[ "$DRY_RUN" != "true" ]] || verb="would remove"
    printf '%s %d file(s), %s freed' "$verb" "$RUN_FILES" "$(format_bytes "$RUN_BYTES")"
    if ((DELETE_FAILURES > 0)); then
        printf '; %d deletion(s) FAILED' "$DELETE_FAILURES"
    fi
    if ((SCAN_FAILURES > 0)); then
        printf '; %d listing(s) FAILED' "$SCAN_FAILURES"
    fi
}

# The steps of a standard cleanup. The status is EXIT_DELETE_FAILED when a
# deletion failed or a directory could not be listed.
_cleanup_steps() {
    log_info "Starting storage cleanup"
    cleanup_recordings
    cleanup_logs
    cleanup_temp
    truncate_large_logs
    _report_delete_failures
}

# Run standard cleanup
cmd_cleanup() {
    local rc=0
    _cleanup_steps || rc=$?
    if ((rc != 0)); then
        log_summary "Cleanup incomplete: $(_run_totals)"
        return "$EXIT_DELETE_FAILED"
    fi
    log_summary "Cleanup completed: $(_run_totals)"
}

# Monitor and cleanup if needed. One check per invocation (run it from cron or a
# timer); it prints nothing while the disk is fine. When it acts or finds the
# disk above a threshold, the last line says what the disk looked like and what
# was done (the one line --quiet keeps).
cmd_monitor() {
    local usage free_mb rc=0 level="ok" iusage=0
    usage=$(get_disk_usage "/")
    free_mb=$(get_free_space_mb "/")

    # If the disk state can't be determined, do NOT guess. Treating it as "OK"
    # would ignore a genuinely full disk; running the emergency path on garbage
    # input would delete recordings indiscriminately. Log loudly and run only
    # the safe, retention-based cleanup (which deletes solely by age).
    if [[ ! "$usage" =~ ^[0-9]+$ ]] || [[ ! "$free_mb" =~ ^[0-9]+$ ]]; then
        log_error "Could not determine disk usage for / (df unparseable: usage='${usage}', free='${free_mb}'MB); running standard cleanup only"
        _cleanup_steps || rc=$?
        log_summary "Monitor: disk usage of / unknown (df unparseable); standard cleanup only: $(_run_totals)"
        return "$rc"
    fi

    # Inode pressure counts as disk pressure: many small recordings exhaust
    # inodes long before blocks, and every write then fails ENOSPC while the
    # block percentage still looks healthy. Unknown ("-", unsupported fs) is
    # treated as no pressure, never as an emergency.
    iusage=$(get_inode_usage "/")
    [[ "$iusage" =~ ^[0-9]+$ ]] || iusage=0

    log_debug "Disk usage: ${usage}%, inodes: ${iusage}%, free: ${free_mb}MB"

    if [[ $usage -ge $DISK_EMERGENCY_PERCENT ]] || [[ $iusage -ge $DISK_EMERGENCY_PERCENT ]] \
        || [[ $free_mb -lt $MIN_FREE_SPACE_MB ]]; then
        level="emergency"
        log_error "EMERGENCY: Disk ${usage}% full, inodes ${iusage}% used, ${free_mb}MB free"
        emergency_cleanup
        _cleanup_steps || rc=$?
    elif [[ $usage -ge $DISK_CRITICAL_PERCENT ]] || [[ $iusage -ge $DISK_CRITICAL_PERCENT ]]; then
        level="critical"
        log_warn "CRITICAL: Disk ${usage}% full, inodes ${iusage}% used"
        _cleanup_steps || rc=$?
    elif [[ $usage -ge $DISK_WARNING_PERCENT ]] || [[ $iusage -ge $DISK_WARNING_PERCENT ]]; then
        level="warning"
        log_warn "WARNING: Disk ${usage}% full, inodes ${iusage}% used"
        cleanup_temp
        truncate_large_logs
        _report_delete_failures || rc=$?
    else
        log_debug "Disk usage OK: ${usage}%"
    fi
    if [[ "$level" != "ok" ]]; then
        log_summary "Monitor: disk ${usage}% used, inodes ${iusage}%, ${free_mb}MB free (${level}): $(_run_totals)"
    fi
    return "$rc"
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
    cat <<EOF
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
  -q, --quiet    (cleanup, monitor) Print only warnings, errors and one summary
                 line per run, to stderr like every other message; nothing to
                 stdout
  --once         (monitor) One check, then exit. This is what monitor always does:
                 it never loops, run it from cron or a timer (there is no
                 --interval)

Environment Variables:
  RECORDING_RETENTION_DAYS   Days to keep recordings (default: 30)
  LOG_RETENTION_DAYS         Days to keep logs (default: 7)
  DISK_WARNING_PERCENT       Warning threshold (default: 80)
  DISK_CRITICAL_PERCENT      Critical threshold (default: 90)
  DISK_EMERGENCY_PERCENT     Emergency threshold (default: 95)
  MIN_FREE_SPACE_MB          Minimum free space (default: 500)
  LYREBIRD_RECORDING_DIR     Recording directory path
  LYREBIRD_LOG_DIR           Log directory path
  LYREBIRD_ACTIVE_SEGMENT_SECONDS
                             A file written this recently belongs to a stream that
                             is recording now: emergency cleanup never deletes it,
                             and an empty segment younger than this is not removed
                             (default: 900, minimum: 60)

Recordings are files ending in: ${RECORDING_EXTENSIONS[*]}

Configuration file:
  ${STORAGE_CONFIG_PATH:-(none)} is read when it exists; LYREBIRD_STORAGE_CONFIG=FILE names another one
  and LYREBIRD_STORAGE_CONFIG= (empty) none. It is data, never run: KEY=value lines,
  # comments, values bare or in '...' / "..." and taken literally. Keys are the
  names of the environment variables above (and LYREBIRD_TEMP_DIR,
  LYREBIRD_BUFFER_DIR, MEDIAMTX_LOG, TEMP_RETENTION_HOURS, MAX_LOG_SIZE,
  LYREBIRD_CLOCK_SANE_EPOCH); RECORDING_DIR and LOG_DIR are accepted as other names
  of LYREBIRD_RECORDING_DIR and LYREBIRD_LOG_DIR in the file (not in the
  environment). A variable in the environment wins over the file. Directories in
  the file must be absolute. A file that anyone can write, or that belongs to a
  user other than root, is not read.

Exit status:
  0  success
  1  usage error
  3  finished, but at least one deletion failed (see the ERROR lines), or a
     directory could not be listed (find's message and an ERROR line say which)
  4  finished, but lines of the configuration file were not accepted and ignored
     (each is reported with its line number)

Examples:
  ${SCRIPT_NAME} status
  ${SCRIPT_NAME} cleanup
  ${SCRIPT_NAME} --dry-run cleanup
  ${SCRIPT_NAME} monitor

Cron Integration:
  # Daily cleanup at 3 AM, one summary line per run
  0 3 * * * ${SCRIPT_NAME} cleanup --quiet

  # Every 15 minutes: silent while the disk is fine
  */15 * * * * ${SCRIPT_NAME} monitor --once
EOF
}

main() {
    local command="" quiet=false once=false

    while [[ $# -gt 0 ]]; do
        case "$1" in
            -h | --help)
                show_help
                exit 0
                ;;
            -v | --version)
                echo "${SCRIPT_NAME} v${VERSION}"
                exit 0
                ;;
            -n | --dry-run)
                DRY_RUN="true"
                shift
                ;;
            -d | --debug)
                DEBUG="true"
                shift
                ;;
            -q | --quiet)
                quiet=true
                shift
                ;;
            --once)
                once=true
                shift
                ;;
            status | cleanup | monitor | emergency)
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
    if [[ "$quiet" == "true" && "$command" != "cleanup" && "$command" != "monitor" ]]; then
        log_error "--quiet applies to cleanup and monitor only (not ${command})"
        exit 1
    fi
    if [[ "$once" == "true" && "$command" != "monitor" ]]; then
        log_error "--once applies to monitor only (not ${command})"
        exit 1
    fi
    QUIET="$quiet"

    local rc=0
    case "$command" in
        status)
            cmd_status || rc=$?
            ;;
        cleanup)
            cmd_cleanup || rc=$?
            ;;
        monitor)
            cmd_monitor || rc=$?
            ;;
        emergency)
            cmd_emergency || rc=$?
            ;;
    esac
    # A configuration file whose lines were ignored is not a clean run (a failed
    # deletion or listing, status 3, is the more specific news and keeps its code)
    if ((rc == 0 && CONFIG_PROBLEMS > 0)); then
        log_error "Finished, but ${CONFIG_PROBLEMS} line(s) of ${STORAGE_CONFIG_PATH} were not accepted and ignored (listed above)"
        rc="$EXIT_CONFIG"
    fi
    return "$rc"
}

# Only execute when run directly, not when sourced (e.g. by the test suite)
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi
