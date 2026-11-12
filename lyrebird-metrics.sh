#!/bin/bash
# lyrebird-metrics.sh - Prometheus metrics exporter for LyreBirdAudio
# Part of LyreBirdAudio - RTSP Audio Streaming Suite
# https://github.com/tomtom215/LyreBirdAudio
#
# Exports metrics in Prometheus text format for monitoring and alerting.
#
# Usage:
#   ./lyrebird-metrics.sh              # Output metrics to stdout
#   ./lyrebird-metrics.sh --serve 9100 # HTTP server on 127.0.0.1:9100 (also: serve --port 9100)
#   ./lyrebird-metrics.sh serve --port 9100 --bind 0.0.0.0   # on every interface (no authentication)
#   ./lyrebird-metrics.sh --file /path # Write metrics to file (atomic replace)
#
# Exit status: 0 ok, 1 command-line error, 2 nothing delivered (file not
# published / server cannot run), 3 delivered but a collector failed.
#
# Integration with Prometheus:
#   Add to prometheus.yml:
#     - job_name: 'lyrebird'
#       static_configs:
#         - targets: ['localhost:9100']
#       metrics_path: /metrics
#
# Integration with node_exporter:
#   ./lyrebird-metrics.sh --file /var/lib/node_exporter/textfile_collector/lyrebird.prom
#
# Version: 1.3.0 - Valid-by-construction exposition, collector/scrape status,
#                  atomic --file publishing, hardened --serve, heartbeat max age

set -euo pipefail

readonly VERSION="1.3.0"
SCRIPT_NAME="$(basename "${BASH_SOURCE[0]}")"
readonly SCRIPT_NAME

# Configuration
readonly MEDIAMTX_API_HOST="${MEDIAMTX_HOST:-localhost}"
readonly MEDIAMTX_API_PORT="${MEDIAMTX_API_PORT:-9997}"
# shellcheck disable=SC2034  # Exported for use by install_mediamtx.sh and external scripts
readonly MEDIAMTX_RTSP_PORT="${MEDIAMTX_PORT:-8554}"
readonly HEARTBEAT_FILE="${HEARTBEAT_FILE:-/run/mediamtx-audio.heartbeat}"
# The PID file of the stream manager's MediaMTX: PID_FILE, else the variable the
# manager itself reads (MEDIAMTX_PID_FILE)
readonly PID_FILE="${PID_FILE:-${MEDIAMTX_PID_FILE:-/run/mediamtx-audio.pid}}"
readonly FFMPEG_PID_DIR="${FFMPEG_PID_DIR:-/var/lib/mediamtx-ffmpeg}"
readonly CONFIG_DIR="${MEDIAMTX_CONFIG_DIR:-/etc/mediamtx}"
readonly DEVICE_CONFIG="${CONFIG_DIR}/audio-devices.conf"
# The MediaMTX this installation runs, named by the variables the stream manager
# reads: a process is this MediaMTX when its executable is MEDIAMTX_BIN and its
# first argument is MEDIAMTX_CONFIG_FILE (that is how the manager and the
# mediamtx.service unit start it)
readonly MEDIAMTX_BIN="${MEDIAMTX_BINARY:-/usr/local/bin/mediamtx}"
readonly MEDIAMTX_CONFIG_FILE="${MEDIAMTX_CONFIG_FILE:-${CONFIG_DIR}/mediamtx.yml}"

# Metric prefix
readonly METRIC_PREFIX="lyrebird"

# Exit statuses (also in --help). 1 is a command-line error.
readonly EXIT_FAILED=2   # nothing could be delivered (the file was not published, the server cannot run)
readonly EXIT_DEGRADED=3 # the output was delivered but a collector failed (lyrebird_scrape_success 0)

# ============================================================================
# Helper Functions
# ============================================================================

log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" >&2
}

# Check if command exists
has_command() {
    command -v "$1" &>/dev/null
}

# Get current timestamp in milliseconds
get_timestamp_ms() {
    if has_command date; then
        echo "$(($(date +%s) * 1000))"
    else
        echo "0"
    fi
}

# The longest age, in seconds, at which the stream-manager heartbeat file still
# counts as "the monitor ran recently" (lyrebird_heartbeat_healthy). The file is
# written by the manager's monitor pass, which cron runs every 5 minutes, so the
# default is three cycles (900 s); a threshold below the cadence would report
# "unhealthy" on most scrapes of a healthy node. Override with
# LYREBIRD_HEARTBEAT_MAX_AGE (a positive integer number of seconds).
resolve_heartbeat_max_age() {
    local raw="${LYREBIRD_HEARTBEAT_MAX_AGE-}"
    local default=900

    if [[ -z "$raw" ]]; then
        printf '%s' "$default"
    elif [[ "$raw" =~ ^[0-9]+$ ]] && ((10#$raw > 0)); then
        printf '%s' "$((10#$raw))"
    else
        log "WARN: ignoring LYREBIRD_HEARTBEAT_MAX_AGE='${raw}' (need a positive integer number of seconds); using ${default}"
        printf '%s' "$default"
    fi
}
HEARTBEAT_MAX_AGE="$(resolve_heartbeat_max_age)"
readonly HEARTBEAT_MAX_AGE

# The longest, in seconds, that one scrape may spend on the MediaMTX API in all,
# every request and retry together. A MediaMTX that is hung or being restarted
# must not stall the scrape: a Prometheus scrape gives up after its
# scrape_timeout (10 s by default), a `--serve` response waits for the scrape and
# a cron `--file` run would pile up behind it. Override with LYREBIRD_API_TIMEOUT
# (a positive integer number of seconds). The limit is kept to whole seconds, so
# a scrape can take up to one second more than this.
resolve_api_timeout() {
    local raw="${LYREBIRD_API_TIMEOUT-}"
    local default=5

    if [[ -z "$raw" ]]; then
        printf '%s' "$default"
    elif [[ "$raw" =~ ^[0-9]+$ ]] && ((10#$raw > 0)); then
        printf '%s' "$((10#$raw))"
    else
        log "WARN: ignoring LYREBIRD_API_TIMEOUT='${raw}' (need a positive integer number of seconds); using ${default}"
        printf '%s' "$default"
    fi
}
API_TIMEOUT="$(resolve_api_timeout)"
readonly API_TIMEOUT

# ============================================================================
# Process state
# ============================================================================
#
# A process is looked at through /proc/<pid>/stat, which every user may read, and
# never by sending it a signal: `kill -0` fails with EPERM for another user's
# process, so a stream wrapper owned by root read as down whenever the exporter
# ran as an unprivileged user (a cron job as node_exporter, a unit with User=).
# A /proc entry that exists but cannot be read (/proc mounted with hidepid=1) is
# "cannot tell", which is not "down": the caller leaves the metric out and fails
# its collector rather than publish a made-up 0.

_PS_STATE="" # set by read_proc_stat
_PS_START=""
_REC_START="" # set by pid_file_recorded_start

# Set _PS_STATE and _PS_START from /proc/PID/stat. Returns 0 when read, 1 when
# there is no such process, 2 when there is one whose stat cannot be read. The
# command name is the only field that can contain spaces and is enclosed in
# parentheses, so everything up to the last ") " is skipped.
read_proc_stat() {
    # the shutdown trap can interrupt `IFS= read` with that IFS still in effect
    local IFS=$' \t\n'
    local stat rest
    local -a fields
    _PS_STATE=""
    _PS_START=""
    if ! { read -r stat <"/proc/$1/stat"; } 2>/dev/null; then
        [[ -d "/proc/$1" ]] && return 2
        return 1
    fi
    rest="${stat##*) }"
    read -r -a fields <<<"$rest"
    _PS_STATE="${fields[0]:-}"
    _PS_START="${fields[19]:-}"
    return 0
}

# Is PID running, and (when START is given) the process that started at START
# (field 22 of /proc/PID/stat)? A PID that has been reused has another start
# time; a zombie has exited and counts as gone.
#   0  running
#   1  not running (no such process, a zombie, or another process under that PID)
#   2  cannot tell: its /proc entry exists but cannot be read
proc_check() {
    local pid="$1" start="${2-}" rc=0
    [[ "$pid" =~ ^[1-9][0-9]*$ ]] || return 1
    read_proc_stat "$pid" || rc=$?
    ((rc == 0)) || return "$rc"
    [[ "$_PS_STATE" != "Z" && "$_PS_STATE" != "X" ]] || return 1
    [[ -z "$start" || "$_PS_START" == "$start" ]]
}

# Set _REC_START to the start time the stream manager recorded next to PID file
# $1 for process $2 ("<pid> <starttime>" in "<pid file>.id"); empty when there is
# no record (older versions wrote none) or it is about another PID.
pid_file_recorded_start() {
    local rec_pid="" rec_start=""
    _REC_START=""
    { IFS=' ' read -r rec_pid rec_start _ <"${1}.id"; } 2>/dev/null || true
    if [[ "$rec_pid" == "$2" && "$rec_start" =~ ^[0-9]+$ ]]; then
        _REC_START="$rec_start"
    fi
}

# Is PID $2 of PID file $1 still the process the manager recorded? proc_check's
# statuses, with the recorded start time telling a reused PID from the original.
pid_file_process_state() {
    pid_file_recorded_start "$1" "$2"
    proc_check "$2" "$_REC_START"
}

# Which process is MediaMTX is decided by identity, as the stream manager does it
# (is_managed_mediamtx_pid), never by a name or command-line pattern: a pattern
# such as `pgrep -f mediamtx` also matches an editor on mediamtx.yml, a
# mediamtx-exporter, `tail -f /var/log/mediamtx.log` and another installation's
# MediaMTX, whose memory and uptime were then published as ours.

_ARGV1=""  # set by proc_argv
MTX_PID="" # set by mediamtx_locate
_MTX_WANT_EXE=""

# Set _ARGV1 to the first argument of process $1 (the one after the program name;
# cmdline is NUL-separated and, unlike /proc/PID/exe, readable by every user).
# Returns 0 when read, 1 when there is no such process, 2 when there is one whose
# cmdline cannot be read.
proc_argv() {
    _ARGV1=""
    if ! {
        IFS= read -r -d '' _ || true
        IFS= read -r -d '' _ARGV1 || true
    } 2>/dev/null <"/proc/$1/cmdline"; then
        [[ -d "/proc/$1" ]] && return 2
        return 1
    fi
    return 0
}

# Is PID $1 this installation's MediaMTX: running, the executable is MEDIAMTX_BIN
# (an upgrade may have replaced the file since: the kernel then reports
# "<path> (deleted)", still the same program) and argv[1] is MEDIAMTX_CONFIG_FILE?
# $2 is the start time the manager recorded for the PID, if any.
#   0  yes
#   1  no (not running, another program, another configuration)
#   2  cannot tell: the executable of another user's process cannot be read and
#      there is no recorded start time to go by instead
mediamtx_verify_pid() {
    local pid="$1" recorded="${2-}" rc=0 exe="" deleted_suffix=" (deleted)"
    proc_check "$pid" "$recorded" || rc=$?
    ((rc == 0)) || return "$rc"
    # argv[1] first: it is read without forking and rules out almost everything
    proc_argv "$pid" || rc=$?
    ((rc == 0)) || return "$rc"
    [[ "$_ARGV1" == "$MEDIAMTX_CONFIG_FILE" ]] || return 1
    if exe="$(readlink "/proc/${pid}/exe" 2>/dev/null)" && [[ -n "$exe" ]]; then
        [[ "${exe%"${deleted_suffix}"}" == "$_MTX_WANT_EXE" ]]
        return
    fi
    [[ -d "/proc/${pid}" ]] || return 1
    # The process started at the recorded time and runs the configuration, which
    # is the one the manager recorded after it had started MediaMTX itself
    [[ -n "$recorded" ]] && return 0
    return 2
}

# Look through every process for this installation's MediaMTX. Sets MTX_PID.
# 0 = found, 1 = no such process, 2 = not found but not ruled out either: a
# process that runs the configuration has an executable that cannot be read.
mediamtx_scan() {
    local dir pid rc unknown=0
    MTX_PID=""
    for dir in /proc/[0-9]*; do
        pid="${dir#/proc/}"
        rc=0
        proc_argv "$pid" || rc=$?
        if ((rc == 2)); then
            unknown=1
            continue
        elif ((rc != 0)); then
            continue
        fi
        [[ "$_ARGV1" == "$MEDIAMTX_CONFIG_FILE" ]] || continue
        rc=0
        mediamtx_verify_pid "$pid" || rc=$?
        if ((rc == 0)); then
            MTX_PID="$pid"
            return 0
        elif ((rc == 2)); then
            unknown=1
        fi
    done
    ((unknown == 0)) || return 2
    return 1
}

# Find MediaMTX: the process the stream manager recorded in PID_FILE (with its
# start-time record) if that is verified, else the scan above, which is also what
# finds a stand-alone MediaMTX (mediamtx.service) and one the manager's PID file
# no longer names. Sets MTX_PID; 0 = running, 1 = not running, 2 = cannot tell.
mediamtx_locate() {
    local raw="" pid="" rc=0
    MTX_PID=""
    _MTX_WANT_EXE="$(readlink -f -- "$MEDIAMTX_BIN" 2>/dev/null)" || _MTX_WANT_EXE=""
    [[ -n "$_MTX_WANT_EXE" ]] || _MTX_WANT_EXE="$MEDIAMTX_BIN"
    if [[ -f "$PID_FILE" ]] && raw="$(cat "$PID_FILE" 2>/dev/null)"; then
        pid="${raw%%[[:space:]]*}"
        if [[ "$pid" =~ ^[1-9][0-9]*$ ]]; then
            pid_file_recorded_start "$PID_FILE" "$pid"
            mediamtx_verify_pid "$pid" "$_REC_START" || rc=$?
            if ((rc == 0)); then
                MTX_PID="$pid"
                return 0
            fi
        fi
    fi
    rc=0
    mediamtx_scan || rc=$?
    return "$rc"
}

# ============================================================================
# Metric Collection Functions
# ============================================================================

# Escape a Prometheus label VALUE per the text exposition format: backslash and
# double-quote are backslash-escaped and newlines become "\n". An unescaped `"`,
# `\`, or newline in a value (a device name, or the version string from the
# MediaMTX API) produces a malformed line and Prometheus rejects the ENTIRE
# scrape — so every dynamic label value must pass through here.
prom_escape_label() {
    local v="$1"
    v="${v//\\/\\\\}"   # backslash first
    v="${v//\"/\\\"}"   # then double-quote
    v="${v//$'\n'/\\n}" # then newline
    printf '%s' "$v"
}

# Number of samples emit_metric has refused in this shell, so a caller can tell
# that a document is missing samples.
_EMIT_ERRORS=0

# A Prometheus sample value: a float, +/-Inf or NaN. Anything else (an empty
# string from a failed read, "N/A", a locale decimal comma) makes the text parser
# reject the WHOLE scrape.
is_prom_number() {
    local re_float='^[-+]?([0-9]+(\.[0-9]*)?|\.[0-9]+)([eE][-+]?[0-9]+)?$'
    [[ "$1" =~ $re_float ]] || [[ "$1" == "NaN" ]] || [[ "$1" =~ ^[-+]?Inf$ ]]
}

# Output a metric in Prometheus format. A value that is not a valid sample value
# prints nothing, so one failed read can never poison the document. The refusal
# is logged and counted in _EMIT_ERRORS rather than returned as a failure status,
# so it cannot abort a collector that runs under `set -e`.
emit_metric() {
    local name="$1"
    local value="$2"
    local help="${3:-}"
    local type="${4:-gauge}"
    local labels="${5:-}"

    if ! is_prom_number "$value"; then
        log "ERROR: refusing to emit ${METRIC_PREFIX}_${name}: '${value}' is not a numeric sample value"
        _EMIT_ERRORS=$((_EMIT_ERRORS + 1))
        return 0
    fi

    if [[ -n "$help" ]]; then
        echo "# HELP ${METRIC_PREFIX}_${name} ${help}"
        echo "# TYPE ${METRIC_PREFIX}_${name} ${type}"
    fi

    if [[ -n "$labels" ]]; then
        echo "${METRIC_PREFIX}_${name}{${labels}} ${value}"
    else
        echo "${METRIC_PREFIX}_${name} ${value}"
    fi
}

# Emit ONLY the HELP/TYPE header lines for a metric family. Prometheus requires
# exactly one HELP and one TYPE per family; for metrics produced in a loop (one
# sample per disk/stream) the header must be printed once, before the samples,
# with each per-sample emit_metric call passing an empty help argument.
emit_help_type() {
    local name="$1"
    local help="$2"
    local type="${3:-gauge}"
    echo "# HELP ${METRIC_PREFIX}_${name} ${help}"
    echo "# TYPE ${METRIC_PREFIX}_${name} ${type}"
}

# Collect MediaMTX service metrics. The process is this installation's MediaMTX
# by identity (mediamtx_locate); when that cannot be settled (another user's
# processes cannot be looked at) mediamtx_up is left out and the collector fails,
# instead of publishing a false lyrebird_mediamtx_up 0.
collect_mediamtx_metrics() {
    local mediamtx_running=0
    local mediamtx_pid=0
    local failed=0 located=0

    mediamtx_locate || located=$?
    if ((located == 2)); then
        log "ERROR: cannot tell whether MediaMTX (${MEDIAMTX_BIN} ${MEDIAMTX_CONFIG_FILE}) is running: the executable of a process that runs that configuration cannot be read (run as root)"
        return 1
    elif ((located == 0)); then
        mediamtx_running=1
        mediamtx_pid="$MTX_PID"
    fi

    emit_metric "mediamtx_up" "$mediamtx_running" "MediaMTX server running (1=up, 0=down)"

    if [[ $mediamtx_running -eq 1 ]] && [[ -n "$mediamtx_pid" ]]; then
        # Memory usage
        if [[ -f "/proc/${mediamtx_pid}/status" ]]; then
            local vm_rss
            vm_rss=$(grep "^VmRSS:" "/proc/${mediamtx_pid}/status" 2>/dev/null | awk '{print $2}' || echo 0)
            if [[ "$vm_rss" =~ ^[0-9]+$ ]]; then
                emit_metric "mediamtx_memory_bytes" "$((vm_rss * 1024))" "MediaMTX memory usage in bytes"
            fi
        fi

        # CPU usage
        if has_command ps; then
            local cpu_usage
            cpu_usage=$(ps -p "$mediamtx_pid" -o %cpu= 2>/dev/null | tr -d ' ' || echo 0)
            cpu_usage="${cpu_usage:-0}"
            emit_metric "mediamtx_cpu_percent" "${cpu_usage%.*}" "MediaMTX CPU usage percentage"
        fi

        # File descriptors. /proc/PID/fd can be listed by the process's own user
        # and by root only: where it cannot, the count is unknown (the glob stays
        # unexpanded), not 0.
        if [[ -d "/proc/${mediamtx_pid}/fd" ]]; then
            local -a fds=("/proc/${mediamtx_pid}"/fd/*)
            if [[ -L "${fds[0]}" ]]; then
                emit_metric "mediamtx_open_fds" "${#fds[@]}" "MediaMTX open file descriptors"
            else
                log "ERROR: cannot list /proc/${mediamtx_pid}/fd; the number of open file descriptors of MediaMTX is unknown (run as root)"
                failed=1
            fi
        fi

        # Process uptime
        if [[ -f "/proc/${mediamtx_pid}/stat" ]]; then
            local start_time_ticks
            start_time_ticks=$(awk '{print $22}' "/proc/${mediamtx_pid}/stat" 2>/dev/null)
            if [[ -n "$start_time_ticks" ]] && [[ -f "/proc/uptime" ]]; then
                local clk_tck
                clk_tck=$(getconf CLK_TCK 2>/dev/null || echo 100)
                # Guard against division by zero
                [[ "$clk_tck" -eq 0 ]] && clk_tck=100
                local uptime_sec
                uptime_sec=$(awk '{print int($1)}' /proc/uptime)
                local proc_age=$((uptime_sec - (start_time_ticks / clk_tck)))
                emit_metric "mediamtx_uptime_seconds" "$proc_age" "MediaMTX process uptime in seconds"
            fi
        fi
    fi
    return "$failed"
}

# Collect stream manager metrics
#
# A source that exists but cannot be read makes the corresponding metric unknown:
# it is left out and the collector is reported as failed, rather than publishing
# a made-up 0 that would fire "stream manager down" alerts for a permission error.
collect_stream_manager_metrics() {
    local stream_mgr_running=0
    local active_streams=0
    local configured_devices=0
    local failed=0

    # Check if stream manager is running
    if [[ -f "$PID_FILE" ]]; then
        local pid state=0
        if pid=$(cat "$PID_FILE" 2>/dev/null); then
            pid_file_process_state "$PID_FILE" "$pid" || state=$?
            if ((state == 0)); then
                stream_mgr_running=1
            elif ((state == 2)); then
                log "ERROR: cannot tell whether PID ${pid} of ${PID_FILE} is running: /proc/${pid} cannot be read (run as root)"
                failed=1
                stream_mgr_running=""
            fi
        elif [[ -e "$PID_FILE" ]]; then
            log "ERROR: cannot read ${PID_FILE}"
            failed=1
            stream_mgr_running=""
        fi
    fi

    [[ -z "$stream_mgr_running" ]] || emit_metric "stream_manager_up" "$stream_mgr_running" "Stream manager running (1=up, 0=down)"

    # Count active FFmpeg streams
    if [[ -d "$FFMPEG_PID_DIR" ]]; then
        for pid_file in "${FFMPEG_PID_DIR}"/*.pid; do
            [[ -f "$pid_file" ]] || continue
            local pid
            if ! pid=$(cat "$pid_file" 2>/dev/null); then
                # a pid file removed while we looked is a stopped stream, not an error
                [[ -e "$pid_file" ]] || continue
                log "ERROR: cannot read ${pid_file}"
                failed=1
                active_streams=""
                break
            fi
            local state=0
            pid_file_process_state "$pid_file" "$pid" || state=$?
            if ((state == 2)); then
                log "ERROR: cannot tell whether PID ${pid} of ${pid_file} is running: /proc/${pid} cannot be read (run as root)"
                failed=1
                active_streams=""
                break
            elif ((state == 0)); then
                ((++active_streams))
            fi
        done
    fi

    [[ -z "$active_streams" ]] || emit_metric "active_streams" "$active_streams" "Number of active audio streams"

    # Count configured devices (grep -c: 0 = matches, 1 = none, 2 = cannot read)
    if [[ -f "$DEVICE_CONFIG" ]]; then
        local grep_rc=0
        configured_devices=$(grep -c "^DEVICE_" "$DEVICE_CONFIG" 2>/dev/null) || grep_rc=$?
        if ((grep_rc > 1)); then
            log "ERROR: cannot read ${DEVICE_CONFIG}"
            failed=1
            configured_devices=""
        fi
    fi

    [[ -z "$configured_devices" ]] || emit_metric "configured_devices" "$configured_devices" "Number of configured audio devices"

    # Heartbeat freshness. The file holds the Unix time of the stream manager's
    # last monitor pass (run from cron every 5 minutes), so what it can prove is
    # that the monitor ran recently: not that MediaMTX or any stream is up (the
    # monitor also writes it while MediaMTX is down). Streams are lyrebird_stream_up
    # and lyrebird_api_up.
    local heartbeat_age_help="Seconds since the stream-manager monitor last wrote its heartbeat file (-1 if there is none)"
    local heartbeat_healthy_help="1 if the stream-manager monitor ran within the last ${HEARTBEAT_MAX_AGE} seconds (LYREBIRD_HEARTBEAT_MAX_AGE), else 0; proves only that the monitor ran, not that streams are healthy"
    local heartbeat_time=""
    local heartbeat_state="missing" # missing | read | unreadable
    if [[ -f "$HEARTBEAT_FILE" ]]; then
        if heartbeat_time=$(cat "$HEARTBEAT_FILE" 2>/dev/null); then
            heartbeat_state="read"
        elif [[ -e "$HEARTBEAT_FILE" ]]; then
            log "ERROR: cannot read ${HEARTBEAT_FILE}"
            heartbeat_state="unreadable"
            failed=1
        fi
    fi

    case "$heartbeat_state" in
        read)
            # a corrupt or non-numeric file reads as "never" (age = now)
            [[ "$heartbeat_time" =~ ^[0-9]+$ ]] || heartbeat_time=0
            local now
            now=$(date +%s)
            local heartbeat_age=$((now - 10#$heartbeat_time))
            emit_metric "heartbeat_age_seconds" "$heartbeat_age" "$heartbeat_age_help"

            # Within the maximum age, and not from the future: a clock that was
            # stepped back cannot vouch for recency.
            local heartbeat_healthy=0
            ((heartbeat_age >= 0 && heartbeat_age <= HEARTBEAT_MAX_AGE)) && heartbeat_healthy=1
            emit_metric "heartbeat_healthy" "$heartbeat_healthy" "$heartbeat_healthy_help"
            ;;
        missing)
            emit_metric "heartbeat_age_seconds" "-1" "$heartbeat_age_help"
            emit_metric "heartbeat_healthy" "0" "$heartbeat_healthy_help"
            ;;
    esac
    return "$failed"
}

# Collect USB audio device metrics
collect_usb_audio_metrics() {
    local usb_audio_count=0
    local total_audio_cards=0
    local failed=0
    local cards=""

    # Count audio cards from ALSA
    if [[ -f "/proc/asound/cards" ]]; then
        if cards=$(cat /proc/asound/cards 2>/dev/null); then
            while IFS= read -r line; do
                if [[ "$line" =~ ^[[:space:]]*([0-9]+)[[:space:]]*\[ ]]; then
                    ((++total_audio_cards))
                    local card_num="${BASH_REMATCH[1]}"
                    if [[ -f "/proc/asound/card${card_num}/usbid" ]]; then
                        ((++usb_audio_count))
                    fi
                fi
            done <<<"$cards"
        else
            log "ERROR: cannot read /proc/asound/cards"
            failed=1
        fi
    fi

    if ((failed == 0)); then
        emit_metric "usb_audio_devices" "$usb_audio_count" "Number of USB audio devices detected"
        emit_metric "total_audio_cards" "$total_audio_cards" "Total ALSA audio cards"
    fi
    return "$failed"
}

# Collect system resource metrics
collect_system_metrics() {
    # Disk usage for relevant paths. HELP/TYPE for the disk_usage_percent family
    # must appear exactly once (not once per path) or Prometheus rejects the whole
    # scrape. df -P forces single-line POSIX output; a wrapped long device name
    # (LVM/dm/ZFS) would otherwise shift columns and yield a non-numeric percent.
    local _disk_hdr=0
    local failed=0
    for path in "/" "/var" "/tmp"; do
        if [[ -d "$path" ]] && has_command df; then
            local usage df_out
            if ! df_out=$(df -P "$path" 2>/dev/null); then
                log "ERROR: df failed for ${path}"
                failed=1
                continue
            fi
            usage=$(awk 'NR==2 {gsub(/%/,"",$5); print $5}' <<<"$df_out")
            if [[ "$usage" =~ ^[0-9]+$ ]]; then
                if [[ $_disk_hdr -eq 0 ]]; then
                    emit_help_type "disk_usage_percent" "Disk usage percentage" "gauge"
                    _disk_hdr=1
                fi
                local label
                label="mount=\"$(prom_escape_label "${path}")\""
                emit_metric "disk_usage_percent" "$usage" "" "gauge" "$label"
            fi
        fi
    done

    # Memory
    if [[ -f "/proc/meminfo" ]]; then
        local mem_total
        local mem_available
        mem_total=$(grep "^MemTotal:" /proc/meminfo | awk '{print $2}' || true)
        mem_available=$(grep "^MemAvailable:" /proc/meminfo | awk '{print $2}' || true)

        if [[ -n "$mem_total" ]] && [[ "$mem_total" =~ ^[0-9]+$ ]]; then
            emit_metric "system_memory_total_bytes" "$((mem_total * 1024))" "Total system memory in bytes"
        fi
        if [[ -n "$mem_available" ]] && [[ "$mem_available" =~ ^[0-9]+$ ]]; then
            emit_metric "system_memory_available_bytes" "$((mem_available * 1024))" "Available system memory in bytes"
        fi
    fi

    # Load average
    if [[ -f "/proc/loadavg" ]]; then
        local load1
        load1=$(awk '{print $1}' /proc/loadavg)
        emit_metric "system_load_1m" "$load1" "System load average (1 minute)"
    fi

    # Entropy (important for TLS/crypto operations)
    if [[ -f "/proc/sys/kernel/random/entropy_avail" ]]; then
        local entropy
        entropy=$(cat /proc/sys/kernel/random/entropy_avail)
        emit_metric "system_entropy_available" "$entropy" "Available entropy bytes"
    fi
    return "$failed"
}

# The scrape's time for the MediaMTX API runs out at this value of SECONDS (set by
# collect_api_metrics); API_BODY is what api_get received; API_INCOMPLETE is 1
# once a request of the scrape went unanswered.
API_DEADLINE=0
API_BODY=""
API_INCOMPLETE=0

# GET URL from the MediaMTX API within what is left of the scrape's budget
# (API_TIMEOUT seconds for all requests together): every request is bounded by
# curl's --max-time, so a MediaMTX that accepts the connection and never answers
# cannot hold the scrape. Puts the body in API_BODY. Returns 0 for an answer,
# else curl's exit status (28 also when no time is left).
# A refused or unresolvable connection is final at once (nothing listens, and a
# second attempt a moment later would only cost the scrape a pause: with the
# API down every scrape used to wait a second); any other failure (a reset, an
# empty reply, a timeout) is tried once more after a short pause if time is left.
api_get() {
    local url="$1" attempt remaining rc=0
    API_BODY=""
    for attempt in 1 2; do
        remaining=$((API_DEADLINE - SECONDS))
        if ((remaining < 1)); then
            return 28
        fi
        rc=0
        API_BODY="$(curl -s --connect-timeout "$((remaining < 2 ? remaining : 2))" --max-time "$remaining" "$url" 2>/dev/null)" || rc=$?
        if ((rc == 0)); then
            return 0
        fi
        API_BODY=""
        case "$rc" in
            6 | 7) return "$rc" ;;
        esac
        if ((attempt == 1)); then
            sleep 0.2 2>/dev/null || true
        fi
    done
    return "$rc"
}

# api_get for the optional lists after /v3/info: a request that went unanswered
# leaves its metrics out (API_BODY is empty) and marks the scrape incomplete.
api_list() {
    if ! api_get "$1"; then
        API_BODY=""
        API_INCOMPLETE=1
    fi
    return 0
}

# Collect MediaMTX API metrics (if available)
# Enhanced in v1.1.0 with MediaMTX /v3 API coverage (validated v1.15.5 - v1.19.x)
collect_api_metrics() {
    # Without curl the API state is unknown (not "down"); fail the collector.
    if ! has_command curl; then
        log "ERROR: curl not found; cannot query the MediaMTX API (install curl)"
        return 1
    fi

    local api_url="http://${MEDIAMTX_API_HOST}:${MEDIAMTX_API_PORT}"

    # Everything this collector asks the API shares one time budget
    API_DEADLINE=$((SECONDS + API_TIMEOUT))
    API_INCOMPLETE=0

    # Check API availability and get instance info
    local api_up=0
    local info_json=""
    if api_get "${api_url}/v3/info"; then
        info_json="$API_BODY"
    fi
    # A pattern match, not `echo | grep -q`: grep -q leaves at the first match, and
    # under pipefail the echo that is still writing a large body then dies of
    # SIGPIPE, the pipeline's status is 141 and a live API read as down.
    if [[ "$info_json" == *'"version"'* ]]; then
        api_up=1
    fi

    emit_metric "api_up" "$api_up" "MediaMTX API reachable (1=up, 0=down)"

    if [[ $api_up -eq 1 ]]; then
        # Extract version for info metric
        local version
        version=$(echo "$info_json" | grep -o '"version":"[^"]*"' | cut -d'"' -f4 || echo "unknown")
        emit_metric "api_info" "1" "MediaMTX instance info" "gauge" "version=\"$(prom_escape_label "${version}")\""

        # Extract uptime (in nanoseconds, convert to seconds)
        local uptime_ns
        uptime_ns=$(echo "$info_json" | grep -o '"upTime":[0-9]*' | cut -d':' -f2 || echo "0")
        if [[ -n "$uptime_ns" ]] && [[ "$uptime_ns" =~ ^[0-9]+$ ]]; then
            local uptime_sec=$((uptime_ns / 1000000000))
            emit_metric "api_uptime_seconds" "$uptime_sec" "MediaMTX uptime in seconds"
        fi

        # Get path count from API
        local paths_json
        api_list "${api_url}/v3/paths/list"
        paths_json="$API_BODY"

        if [[ -n "$paths_json" ]]; then
            # Count paths (simple grep approach for portability)
            local path_count
            path_count=$(echo "$paths_json" | grep -o '"name"' | wc -l || true)
            emit_metric "api_paths_total" "$path_count" "Total paths registered in MediaMTX"

            # Count ready paths. MediaMTX deprecated "ready" in favour of
            # "available"; accept both shapes, preferring the new field.
            local ready_count
            if [[ "$paths_json" == *'"available":'* ]]; then
                ready_count=$(echo "$paths_json" | grep -o '"available":true' | wc -l || true)
            else
                ready_count=$(echo "$paths_json" | grep -o '"ready":true' | wc -l || true)
            fi
            emit_metric "api_paths_ready" "$ready_count" "Paths with ready status"
        fi

        # Collect RTSP session metrics
        local rtsp_sessions_json
        api_list "${api_url}/v3/rtspsessions/list"
        rtsp_sessions_json="$API_BODY"
        if [[ -n "$rtsp_sessions_json" ]]; then
            local rtsp_session_count
            rtsp_session_count=$(echo "$rtsp_sessions_json" | grep -o '"id"' | wc -l || true)
            emit_metric "api_rtsp_sessions" "$rtsp_session_count" "Active RTSP sessions (listeners)"
        fi

        # Collect RTSP connection metrics
        local rtsp_conns_json
        api_list "${api_url}/v3/rtspconns/list"
        rtsp_conns_json="$API_BODY"
        if [[ -n "$rtsp_conns_json" ]]; then
            local rtsp_conn_count
            rtsp_conn_count=$(echo "$rtsp_conns_json" | grep -o '"id"' | wc -l || true)
            emit_metric "api_rtsp_connections" "$rtsp_conn_count" "Active RTSP connections"
        fi

        # Collect RTSPS (secure) session metrics
        local rtsps_sessions_json
        api_list "${api_url}/v3/rtspssessions/list"
        rtsps_sessions_json="$API_BODY"
        if [[ -n "$rtsps_sessions_json" ]]; then
            local rtsps_session_count
            rtsps_session_count=$(echo "$rtsps_sessions_json" | grep -o '"id"' | wc -l || true)
            emit_metric "api_rtsps_sessions" "$rtsps_session_count" "Active RTSPS sessions (secure)"
        fi

        # Collect RTMP connection metrics
        local rtmp_conns_json
        api_list "${api_url}/v3/rtmpconns/list"
        rtmp_conns_json="$API_BODY"
        if [[ -n "$rtmp_conns_json" ]]; then
            local rtmp_conn_count
            rtmp_conn_count=$(echo "$rtmp_conns_json" | grep -o '"id"' | wc -l || true)
            emit_metric "api_rtmp_connections" "$rtmp_conn_count" "Active RTMP connections"
        fi

        # Collect RTMPS (secure) connection metrics
        local rtmps_conns_json
        api_list "${api_url}/v3/rtmpsconns/list"
        rtmps_conns_json="$API_BODY"
        if [[ -n "$rtmps_conns_json" ]]; then
            local rtmps_conn_count
            rtmps_conn_count=$(echo "$rtmps_conns_json" | grep -o '"id"' | wc -l || true)
            emit_metric "api_rtmps_connections" "$rtmps_conn_count" "Active RTMPS connections (secure)"
        fi

        # Collect WebRTC session metrics
        local webrtc_sessions_json
        api_list "${api_url}/v3/webrtcsessions/list"
        webrtc_sessions_json="$API_BODY"
        if [[ -n "$webrtc_sessions_json" ]]; then
            local webrtc_session_count
            webrtc_session_count=$(echo "$webrtc_sessions_json" | grep -o '"id"' | wc -l || true)
            emit_metric "api_webrtc_sessions" "$webrtc_session_count" "Active WebRTC sessions"
        fi

        # Collect SRT connection metrics
        local srt_conns_json
        api_list "${api_url}/v3/srtconns/list"
        srt_conns_json="$API_BODY"
        if [[ -n "$srt_conns_json" ]]; then
            local srt_conn_count
            srt_conn_count=$(echo "$srt_conns_json" | grep -o '"id"' | wc -l || true)
            emit_metric "api_srt_connections" "$srt_conn_count" "Active SRT connections"
        fi

        # Collect HLS muxer metrics
        local hls_muxers_json
        api_list "${api_url}/v3/hlsmuxers/list"
        hls_muxers_json="$API_BODY"
        if [[ -n "$hls_muxers_json" ]]; then
            local hls_muxer_count
            hls_muxer_count=$(echo "$hls_muxers_json" | grep -o '"path"' | wc -l || true)
            emit_metric "api_hls_muxers" "$hls_muxer_count" "Active HLS muxers"
        fi

        # Collect recording metrics
        local recordings_json
        api_list "${api_url}/v3/recordings/list"
        recordings_json="$API_BODY"
        if [[ -n "$recordings_json" ]]; then
            local recording_count
            recording_count=$(echo "$recordings_json" | grep -o '"name"' | wc -l || true)
            emit_metric "api_recordings_total" "$recording_count" "Total recording paths"
        fi

        # Calculate total connections across all protocols. A total over lists
        # that were not all received would be a made-up number, so it is left out.
        if ((API_INCOMPLETE == 0)); then
            local total_connections=0
            [[ "${rtsp_session_count:-0}" =~ ^[0-9]+$ ]] && total_connections=$((total_connections + ${rtsp_session_count:-0}))
            [[ "${rtsps_session_count:-0}" =~ ^[0-9]+$ ]] && total_connections=$((total_connections + ${rtsps_session_count:-0}))
            [[ "${rtmp_conn_count:-0}" =~ ^[0-9]+$ ]] && total_connections=$((total_connections + ${rtmp_conn_count:-0}))
            [[ "${rtmps_conn_count:-0}" =~ ^[0-9]+$ ]] && total_connections=$((total_connections + ${rtmps_conn_count:-0}))
            [[ "${webrtc_session_count:-0}" =~ ^[0-9]+$ ]] && total_connections=$((total_connections + ${webrtc_session_count:-0}))
            [[ "${srt_conn_count:-0}" =~ ^[0-9]+$ ]] && total_connections=$((total_connections + ${srt_conn_count:-0}))
            emit_metric "api_total_connections" "$total_connections" "Total active connections across all protocols"
        fi
    fi
    if ((API_INCOMPLETE != 0)); then
        log "ERROR: the MediaMTX API did not answer every request within ${API_TIMEOUT}s; the API metrics missing from this scrape are unknown, not 0"
        return 1
    fi
    return 0
}

# Collect per-stream metrics
#
# The text exposition format requires every sample of a metric family to be in
# one contiguous group (with HELP/TYPE first), so the streams are read once into
# arrays and then written family by family; emitting up/memory/cpu per stream
# interleaves the families as soon as there are two streams.
collect_stream_metrics() {
    if [[ ! -d "$FFMPEG_PID_DIR" ]]; then
        return 0
    fi

    local -a stream_names=() stream_pids=() stream_alive=()
    local pid_file stream_name pid i n labels state
    local failed=0
    for pid_file in "${FFMPEG_PID_DIR}"/*.pid; do
        [[ -f "$pid_file" ]] || continue
        stream_name=$(basename "$pid_file" .pid)
        if ! pid=$(cat "$pid_file" 2>/dev/null); then
            # a pid file removed while we looked is a stopped stream, not an error;
            # one that exists but cannot be read leaves that stream's state unknown
            [[ -e "$pid_file" ]] || continue
            log "ERROR: cannot read ${pid_file}"
            failed=1
            continue
        fi
        state=0
        pid_file_process_state "$pid_file" "$pid" || state=$?
        if ((state == 2)); then
            # a stream whose process cannot be looked at is neither up nor down:
            # its samples are left out
            log "ERROR: cannot tell whether PID ${pid} of ${pid_file} is running: /proc/${pid} cannot be read (run as root)"
            failed=1
            continue
        fi
        stream_names+=("$stream_name")
        stream_pids+=("$pid")
        if ((state == 0)); then
            stream_alive+=(1)
        else
            stream_alive+=(0)
        fi
    done

    n=${#stream_names[@]}
    if ((n == 0)); then
        return "$failed"
    fi

    emit_help_type "stream_up" "Stream running status" "gauge"
    for ((i = 0; i < n; i++)); do
        labels="stream=\"$(prom_escape_label "${stream_names[i]}")\""
        emit_metric "stream_up" "${stream_alive[i]}" "" "gauge" "$labels"
    done

    emit_help_type "stream_memory_bytes" "Stream memory usage in bytes" "gauge"
    for ((i = 0; i < n; i++)); do
        [[ "${stream_alive[i]}" -eq 1 ]] || continue
        pid="${stream_pids[i]}"
        [[ -d "/proc/${pid}" ]] && [[ -f "/proc/${pid}/status" ]] || continue
        local vm_rss
        vm_rss=$(grep "^VmRSS:" "/proc/${pid}/status" 2>/dev/null | awk '{print $2}' || echo 0)
        if [[ "$vm_rss" =~ ^[0-9]+$ ]]; then
            labels="stream=\"$(prom_escape_label "${stream_names[i]}")\""
            emit_metric "stream_memory_bytes" "$((vm_rss * 1024))" "" "gauge" "$labels"
        fi
    done

    emit_help_type "stream_cpu_percent" "Stream CPU usage percentage" "gauge"
    if has_command ps; then
        for ((i = 0; i < n; i++)); do
            [[ "${stream_alive[i]}" -eq 1 ]] || continue
            pid="${stream_pids[i]}"
            [[ -d "/proc/${pid}" ]] || continue
            # ps may print nothing if the process just exited; default to 0 so we
            # never emit a metric line with an empty value.
            local cpu
            cpu=$(ps -p "$pid" -o %cpu= 2>/dev/null | tr -d ' ' || true)
            cpu="${cpu:-0}"
            labels="stream=\"$(prom_escape_label "${stream_names[i]}")\""
            emit_metric "stream_cpu_percent" "${cpu%.*}" "" "gauge" "$labels"
        done
    fi
    return "$failed"
}

# ============================================================================
# Output Functions
# ============================================================================

# The collectors, as a fixed list: the name is the stable, bounded value of the
# `collector` label of lyrebird_collector_success, the function produces the
# metrics.
COLLECTOR_NAMES=(mediamtx stream_manager usb_audio system api streams)
COLLECTOR_FUNCS=(
    collect_mediamtx_metrics
    collect_stream_manager_metrics
    collect_usb_audio_metrics
    collect_system_metrics
    collect_api_metrics
    collect_stream_metrics
)

# Run one collector isolated in a subshell, so that nothing it does (an `exit`, a
# clobbered variable, a hung-up pipe) can take the document or its neighbours
# down. Sets COLLECTOR_OUTPUT to whatever it printed and COLLECTOR_STATUS to 0
# when it completed cleanly: it returned 0 and emit_metric refused no sample.
# The status is read from the return value, not from `set -e`, which is switched
# off for any function called from an `if`/`||` and so cannot be relied on.
run_collector() {
    local fn="$1"
    local out=""
    local status=0

    out="$(
        _EMIT_ERRORS=0
        collector_rc=0
        "$fn" || collector_rc=$?
        if ((collector_rc == 0 && _EMIT_ERRORS > 0)); then
            collector_rc=1
        fi
        exit "$collector_rc"
    )" || status=$?

    COLLECTOR_OUTPUT="$out"
    COLLECTOR_STATUS="$status"
}

# Print the whole document. Returns 0 when every collector completed, EXIT_DEGRADED
# when the document is complete and valid but at least one collector failed (the
# failure is in lyrebird_scrape_success / lyrebird_collector_success), and 1 when
# the document could not be written. Collector failures are logged, never fatal.
generate_all_metrics() {
    local doc="" i name fn ok failed=0
    local -a status_names=() status_values=()

    doc+="# LyreBirdAudio Prometheus Metrics"$'\n'
    doc+="# Generated at $(date -Iseconds)"$'\n\n'
    doc+="$(emit_metric "build_info" "1" "LyreBirdAudio metrics exporter version" "gauge" "version=\"${VERSION}\"")"$'\n\n'

    for ((i = 0; i < ${#COLLECTOR_NAMES[@]}; i++)); do
        name="${COLLECTOR_NAMES[i]}"
        fn="${COLLECTOR_FUNCS[i]}"
        run_collector "$fn"
        if [[ -n "$COLLECTOR_OUTPUT" ]]; then
            doc+="${COLLECTOR_OUTPUT}"$'\n\n'
        fi
        ok=1
        if ((COLLECTOR_STATUS != 0)); then
            ok=0
            failed=$((failed + 1))
            log "WARN: collector '${name}' failed (status ${COLLECTOR_STATUS}); its metrics may be missing or partial"
        fi
        status_names+=("$name")
        status_values+=("$ok")
    done

    doc+="$(emit_help_type "collector_success" "1 if the collector completed without error, 0 if it failed and its metrics may be missing or partial" "gauge")"$'\n'
    for ((i = 0; i < ${#status_names[@]}; i++)); do
        doc+="$(emit_metric "collector_success" "${status_values[i]}" "" "gauge" "collector=\"${status_names[i]}\"")"$'\n'
    done
    doc+=$'\n'

    ok=1
    ((failed == 0)) || ok=0
    doc+="$(emit_metric "scrape_success" "$ok" "1 if every collector completed without error, 0 if any failed (see lyrebird_collector_success); alert on == 0")"$'\n\n'

    # In-band staleness marker. A textfile .prom left behind by a dead exporter
    # is otherwise indistinguishable from a live one -- the node "looks alive"
    # while recording nothing. Alert on:
    #   time() - lyrebird_scrape_timestamp_seconds > <2x scrape interval>
    doc+="$(emit_metric "scrape_timestamp_seconds" "$(date +%s)" "Unix time this scrape was generated (alert when stale)")"$'\n'

    printf '%s' "$doc" || return 1
    ((failed == 0)) || return "$EXIT_DEGRADED"
    return 0
}

# The hidden temp file of the publish in progress, for the signal handlers.
_PUBLISH_TMP=""

# Publish the document as FILE (the node_exporter textfile collector reads it).
#
# The document is written to a hidden, uniquely named temp file in the same
# directory (so writers never collide and rename(2) is atomic) and renamed over
# FILE only once it is complete: readers see the previous document or the new
# one, never a partial one, and a failed run leaves the last good file in place.
# The temp name starts with "." and does not end in ".prom", so the textfile
# collector never reads it.
#
# There is deliberately no fsync of the file or the directory: the document is
# regenerated every interval, and if a power cut loses the newest rename the
# worst case is the previous document (or an empty file after a crash on a
# delayed-allocation filesystem), which the in-band lyrebird_scrape_timestamp_seconds
# alert already treats as stale. A SIGKILL can still leave one ".FILE.XXXXXX"
# temp file behind; it is never read as FILE.
#
# Returns 0 when published, EXIT_DEGRADED when published with a failed collector,
# EXIT_FAILED when nothing was published. Never fatal to the calling shell.
publish_metrics_file() {
    local output_file="$1"
    local dir base tmp mode gen_rc=0

    if [[ -d "$output_file" ]]; then
        log "ERROR: ${output_file} is a directory; not publishing"
        return "$EXIT_FAILED"
    fi
    dir="$(dirname -- "$output_file")"
    base="$(basename -- "$output_file")"

    if ! tmp="$(mktemp "${dir}/.${base}.XXXXXX" 2>/dev/null)"; then
        log "ERROR: cannot create a temporary file in ${dir}; ${output_file} was not updated"
        return "$EXIT_FAILED"
    fi

    # Drop the temp file if we are stopped mid-run (cron overrun, shutdown).
    _PUBLISH_TMP="$tmp"
    trap 'rm -f -- "$_PUBLISH_TMP"; exit 129' HUP
    trap 'rm -f -- "$_PUBLISH_TMP"; exit 130' INT
    trap 'rm -f -- "$_PUBLISH_TMP"; exit 143' TERM

    # mktemp creates 0600; keep the mode a plain redirect would have given (a
    # node_exporter running as another user must be able to read the file).
    mode="$(printf '%04o' $((0666 & ~$(umask))))"

    generate_all_metrics >"$tmp" || gen_rc=$?
    if ((gen_rc != 0 && gen_rc != EXIT_DEGRADED)); then
        log "ERROR: writing the metrics failed (status ${gen_rc}); keeping the previous ${output_file}"
    elif [[ ! -s "$tmp" ]]; then
        gen_rc=1
        log "ERROR: the generated metrics are empty; keeping the previous ${output_file}"
    elif ! chmod "$mode" -- "$tmp"; then
        gen_rc=1
        log "ERROR: cannot set the mode of ${tmp}; keeping the previous ${output_file}"
    elif ! mv -f -- "$tmp" "$output_file"; then
        gen_rc=1
        log "ERROR: cannot replace ${output_file}; keeping the previous file"
    fi

    rm -f -- "$tmp"
    _PUBLISH_TMP=""
    trap - HUP INT TERM

    if ((gen_rc != 0 && gen_rc != EXIT_DEGRADED)); then
        return "$EXIT_FAILED"
    fi
    return "$gen_rc"
}

# ============================================================================
# HTTP server (--serve)
# ============================================================================
#
# A small HTTP/1.1 server for `GET /metrics` on top of netcat, one connection at
# a time. nc is only the socket: for each connection one `nc -l` is started whose
# stdout (the request) is a pipe we read and whose stdin is a FIFO we write the
# response to, so the metrics are generated AFTER the request has arrived and are
# never older than the request.
#
# Things this does on purpose, because the previous loop got them wrong:
#  * binds 127.0.0.1 unless told otherwise (--bind) and says so truthfully;
#  * knows which netcat it has (OpenBSD, ncat, traditional/GNU, BusyBox) by what
#    `nc -h` reports and builds the right command line for it, instead of trying
#    flags until one happens not to fail;
#  * stops only the nc it started (pid + start time from /proc), never a process
#    that merely has "nc ... -l ... PORT" somewhere in its command line;
#  * refuses to start when the port is taken (nc sets SO_REUSEPORT, so a second
#    nc would bind NEXT TO the first and split its connections) and backs off,
#    bounded, instead of spinning;
#  * frames responses correctly (CRLF, Content-Length in bytes, Connection: close).
#
# nc accepts one connection and then stops listening, so as soon as a request has
# arrived the NEXT nc is started, before the metrics are generated: a scraper
# that arrives while a request is being answered (a second Prometheus, a retry)
# finds a listener, and its request waits until the current one is done. Requests
# are still answered one at a time. What is left is a client that connects and
# sends nothing: it occupies the one armed listener until SERVE_IDLE_ROTATE
# recycles it. There is no authentication or TLS.

SERVE_IDLE_ROTATE=10    # seconds an idle listener lives before it is recycled; bounds a client that connects and never sends
SERVE_REQUEST_TIMEOUT=5 # seconds a client has to deliver the rest of its request after the first line
SERVE_CLOSE_TIMEOUT=3   # seconds nc has to finish after the response was written before it is stopped
SERVE_START_ATTEMPTS=5  # consecutive failed listener starts before giving up
SERVE_RETRY_MS=500      # first back-off after a failed start, doubled each time
SERVE_BIND_WAIT_MS=3000 # how long a new listener has to show up as bound

# State of the running server (see serve_metrics). A listener is one nc; there are
# two slots, the one being served and the one armed for the next connection.
_SRV_DIR=""      # private temp directory: the FIFOs and nc's stderr
_SRV_SLEEP=""    # fd of a FIFO nothing writes to: reading it with a timeout is an interruptible sleep
_SRV_CUR=0       # the slot whose connection is being served
_L_PID=("" "")   # per slot: pid of the nc we started
_L_START=("" "") # its start time (field 22 of /proc/PID/stat): pid + start time identify it
_L_R=("" "")     # fd: nc's stdout (the request)
_L_W=("" "")     # fd: nc's stdin (the response)
_L_FIFO=("" "")  # FIFO carrying the response to nc's stdin
_L_ERR=("" "")   # nc's stderr
_SRV_PORT=""
_SRV_BIND=""
_SRV_NC_BIN=""
_SRV_NC_VARIANT=""
_SRV_NC_HELP=""
_SRV_NC_CMD=()
_BYTES=0 # set by byte_length

# A TCP port number, 1-65535.
valid_port() {
    [[ "$1" =~ ^[0-9]{1,5}$ ]] && ((10#$1 >= 1 && 10#$1 <= 65535))
}

# An IPv4 dotted quad or an IPv6 literal.
valid_bind() {
    local addr="$1" octet
    if [[ "$addr" =~ ^([0-9]{1,3})\.([0-9]{1,3})\.([0-9]{1,3})\.([0-9]{1,3})$ ]]; then
        for octet in "${BASH_REMATCH[@]:1:4}"; do
            ((10#$octet <= 255)) || return 1
        done
        return 0
    fi
    [[ "$addr" == *:*:* ]] && [[ "$addr" =~ ^[0-9A-Fa-f:.]+$ ]]
}

is_wildcard_bind() {
    [[ "$1" == "0.0.0.0" || "$1" == "::" ]]
}

is_loopback_bind() {
    [[ "$1" == 127.* || "$1" == "::1" ]]
}

# The help text of a netcat binary, which is how its variant is told apart.
nc_help_text() {
    local bin="$1"
    if has_command timeout; then
        timeout 3 "$bin" -h </dev/null 2>&1 || true
    else
        "$bin" -h </dev/null 2>&1 || true
    fi
}

# Print the variant a help text belongs to (openbsd, ncat, traditional, busybox),
# nothing if it is none of them.
classify_nc() {
    case "$1" in
        *BusyBox*) echo busybox ;;
        Ncat* | *"nmap.org/ncat"*) echo ncat ;;
        *"OpenBSD netcat"* | *"usage: nc ["*) echo openbsd ;;
        *"GNU netcat"* | *"[v1.10"* | *"connect to somewhere"*) echo traditional ;;
        *) ;;
    esac
}

# Find a usable netcat: sets _SRV_NC_BIN, _SRV_NC_VARIANT and _SRV_NC_HELP.
detect_nc() {
    local candidate bin help variant
    for candidate in nc ncat netcat; do
        bin="$(command -v "$candidate" 2>/dev/null)" || continue
        [[ "$bin" == /* ]] || continue
        help="$(nc_help_text "$bin")"
        variant="$(classify_nc "$help")"
        if [[ -n "$variant" ]]; then
            _SRV_NC_BIN="$bin"
            _SRV_NC_VARIANT="$variant"
            _SRV_NC_HELP="$help"
            return 0
        fi
        log "WARN: ${bin} is not a netcat variant this server knows how to drive; skipping it"
    done
    return 1
}

# Build the listen command for the detected variant into _SRV_NC_CMD. The
# end-of-response handling is chosen from what the variant's help advertises:
# `-q 0` (quit right after EOF on stdin) where it exists, else `-N` (shut the
# socket down after EOF on stdin). Returns 1 if the variant cannot bind to BIND.
build_nc_command() {
    local bind="$1" port="$2" help="$_SRV_NC_HELP"
    local re_has_n='\[-[A-Za-z0-9]*N'

    case "$_SRV_NC_VARIANT" in
        openbsd)
            _SRV_NC_CMD=("$_SRV_NC_BIN" -l)
            if [[ "$help" == *"[-q "* ]]; then
                _SRV_NC_CMD+=(-q 0)
            elif [[ "$help" =~ $re_has_n ]]; then
                _SRV_NC_CMD+=(-N)
            fi
            _SRV_NC_CMD+=("$bind" "$port")
            ;;
        ncat)
            _SRV_NC_CMD=("$_SRV_NC_BIN" -l "$bind" "$port")
            ;;
        traditional)
            _SRV_NC_CMD=("$_SRV_NC_BIN" -l -p "$port" -s "$bind")
            if [[ "$help" == *"-q secs"* ]]; then
                _SRV_NC_CMD+=(-q 0)
            fi
            ;;
        busybox)
            if [[ "$help" == *"-s ADDR"* ]]; then
                _SRV_NC_CMD=("$_SRV_NC_BIN" -l -p "$port" -s "$bind")
            elif is_wildcard_bind "$bind"; then
                _SRV_NC_CMD=("$_SRV_NC_BIN" -l -p "$port")
            else
                log "ERROR: this BusyBox nc cannot bind to a given address (no -s); use --bind 0.0.0.0 or install netcat-openbsd"
                return 1
            fi
            ;;
        *)
            log "ERROR: no usable netcat variant"
            return 1
            ;;
    esac
    return 0
}

# Interruptible sleep (a signal ends it at once): a timed read of a FIFO that is
# never written to. Takes seconds, fractions allowed.
srv_sleep() {
    read -r -t "$1" -u "$_SRV_SLEEP" _ || true
}

# Is the nc we started in slot $1 still running? A pid alone could have been
# reused; its start time cannot. A zombie counts as gone.
listener_alive() {
    local slot="$1"
    [[ -n "${_L_PID[slot]}" ]] || return 1
    read_proc_stat "${_L_PID[slot]}" || return 1
    [[ "$_PS_STATE" != "Z" && "$_PS_STATE" != "X" ]] || return 1
    [[ -z "${_L_START[slot]}" || "$_PS_START" == "${_L_START[slot]}" ]]
}

# The tcp tables to look at (IPv4 and, where present, IPv6).
_tcp_tables() {
    local table
    for table in /proc/net/tcp /proc/net/tcp6; do
        [[ -r "$table" ]] && echo "$table"
    done
    return 0
}

# Is something already listening on PORT where we want to bind? Needed because nc
# sets SO_REUSEPORT: a second nc on the same address binds without error and the
# kernel then splits the connections between the two, so "nc failed" cannot be
# relied on to notice a taken port. Returns 0 if a listener is there.
port_in_use() {
    local port="$1" bind="$2" hexport bindhex="" wild=0
    local -a tables
    mapfile -t tables < <(_tcp_tables)
    ((${#tables[@]} > 0)) || return 1
    printf -v hexport '%04X' "$((10#$port))"
    if is_wildcard_bind "$bind"; then
        wild=1
    elif [[ "$bind" =~ ^([0-9]+)\.([0-9]+)\.([0-9]+)\.([0-9]+)$ ]]; then
        # /proc/net/tcp shows an IPv4 address as its bytes in reverse order
        printf -v bindhex '%02X%02X%02X%02X' "$((10#${BASH_REMATCH[4]}))" "$((10#${BASH_REMATCH[3]}))" \
            "$((10#${BASH_REMATCH[2]}))" "$((10#${BASH_REMATCH[1]}))"
    fi
    awk -v port="$hexport" -v bind="$bindhex" -v wild="$wild" '
        $4 == "0A" {
            split($2, a, ":")
            if (a[2] == port && (wild == 1 || a[1] ~ /^0+$/ || (bind != "" && a[1] == bind))) found = 1
        }
        END { exit(found ? 0 : 1) }' "${tables[@]}" 2>/dev/null
}

# Does the nc we started own a listening socket on PORT? Compares the inodes of
# its sockets with those of the listeners in /proc/net/tcp*. Returns 2 where /proc
# cannot tell.
listener_bound() {
    local pid="$1" port="$2" hexport inodes link fd
    local -a tables
    mapfile -t tables < <(_tcp_tables)
    ((${#tables[@]} > 0)) || return 2
    printf -v hexport '%04X' "$((10#$port))"
    inodes="$(awk -v port="$hexport" '$4 == "0A" { split($2, a, ":"); if (a[2] == port) print $10 }' "${tables[@]}" 2>/dev/null)" || true
    [[ -n "$inodes" ]] || return 1
    for fd in /proc/"$pid"/fd/*; do
        link="$(readlink "$fd" 2>/dev/null)" || continue
        [[ "$link" =~ ^socket:\[([0-9]+)\]$ ]] || continue
        case $'\n'"$inodes"$'\n' in
            *$'\n'"${BASH_REMATCH[1]}"$'\n'*) return 0 ;;
        esac
    done
    return 1
}

# Wait for the listener in slot $1 to be bound. 0 = bound (or running, where /proc
# cannot confirm it and it survived a short wait), 1 = it died or never bound.
wait_listener_bound() {
    local slot="$1" waited=0 rc=0
    while ((waited < SERVE_BIND_WAIT_MS)); do
        rc=0
        listener_bound "${_L_PID[slot]}" "$_SRV_PORT" || rc=$?
        if ((rc == 0)); then
            return 0
        elif ((rc == 2)); then
            srv_sleep 0.3
            listener_alive "$slot"
            return $?
        fi
        listener_alive "$slot" || return 1
        srv_sleep 0.05
        waited=$((waited + 50))
    done
    return 1
}

# Start nc listening in slot $1 and record its pid. The pid is taken from the
# subshell that becomes nc by exec, so it is nc's own. The write end of the FIFO
# is opened read-write only AFTER nc was started, and nc is made to close every
# listener fd it inherited: a write end of ITS stdin FIFO left open anywhere else
# would keep it from ever seeing EOF.
start_listener() {
    local slot="$1" pid="" rfd="" wfd="" ofd
    local fifo="${_L_FIFO[slot]}" err="${_L_ERR[slot]}"
    : >"$err"
    _L_PID[slot]=""
    _L_START[slot]=""
    exec {rfd}< <(
        printf '%s\n' "$BASHPID"
        for ofd in "${_L_W[@]}" "${_L_R[@]}" "$_SRV_SLEEP"; do
            [[ -z "$ofd" ]] || exec {ofd}>&-
        done
        exec "${_SRV_NC_CMD[@]}" <"$fifo" 2>"$err"
    ) || return 1
    _L_R[slot]="$rfd"
    if ! exec {wfd}<>"$fifo"; then
        stop_listener "$slot"
        return 1
    fi
    _L_W[slot]="$wfd"
    if ! IFS= read -r -t 5 -u "$rfd" pid || [[ ! "$pid" =~ ^[0-9]+$ ]]; then
        stop_listener "$slot"
        return 1
    fi
    _L_PID[slot]="$pid"
    if read_proc_stat "$pid"; then
        _L_START[slot]="$_PS_START"
    fi
    return 0
}

# Stop the nc we started in slot $1 (only that one), and close our ends.
stop_listener() {
    local slot="$1" i fd
    fd="${_L_W[slot]}"
    if [[ -n "$fd" ]]; then
        exec {fd}>&-
        _L_W[slot]=""
    fi
    fd="${_L_R[slot]}"
    if [[ -n "$fd" ]]; then
        exec {fd}<&-
        _L_R[slot]=""
    fi
    if listener_alive "$slot"; then
        kill "${_L_PID[slot]}" 2>/dev/null || true
        for ((i = 0; i < 40; i++)); do
            listener_alive "$slot" || break
            srv_sleep 0.05
        done
        if listener_alive "$slot"; then
            kill -KILL "${_L_PID[slot]}" 2>/dev/null || true
        fi
    fi
    _L_PID[slot]=""
    _L_START[slot]=""
}

# What the nc in slot $1 said on stderr (a bind error, typically), on one line.
listener_error() {
    local line=""
    { read -r line <"${_L_ERR[$1]}"; } 2>/dev/null || true
    printf '%s' "$line"
}

# Number of bytes in a string, whatever the locale: sets _BYTES. ${#var} counts
# characters in a UTF-8 locale, and Content-Length is a count of bytes.
byte_length() {
    local LC_ALL=C
    _BYTES=${#1}
}

http_status_text() {
    case "$1" in
        200) printf 'OK' ;;
        400) printf 'Bad Request' ;;
        404) printf 'Not Found' ;;
        405) printf 'Method Not Allowed' ;;
        *) printf 'Internal Server Error' ;;
    esac
}

# Write one complete HTTP/1.1 response to nc: CRLF line endings, Content-Length
# in bytes, Connection: close. Usage: send_response CODE CONTENT-TYPE BODY [HEADER]
send_response() {
    local code="$1" ctype="$2" body="$3" extra="${4:-}" response
    byte_length "$body"
    response="HTTP/1.1 ${code} $(http_status_text "$code")"$'\r\n'
    response+="Content-Type: ${ctype}"$'\r\n'
    response+="Content-Length: ${_BYTES}"$'\r\n'
    if [[ -n "$extra" ]]; then
        response+="${extra}"$'\r\n'
    fi
    response+="Connection: close"$'\r\n\r\n'
    response+="$body"
    # a dead nc would leave a large write blocked on the FIFO we hold open
    listener_alive "$_SRV_CUR" || return 1
    printf '%s' "$response" >&"${_L_W[_SRV_CUR]}"
}

# Consume the rest of the request head (everything up to the empty line) within
# SERVE_REQUEST_TIMEOUT; closing with unread input would reset the connection
# and could cut the response short.
read_request_head() {
    local deadline=$((SECONDS + SERVE_REQUEST_TIMEOUT)) left header count=0
    while :; do
        left=$((deadline - SECONDS))
        ((left > 0)) || return 1
        IFS= read -r -t "$left" -n 8192 -u "${_L_R[_SRV_CUR]}" header || return 1
        header="${header%$'\r'}"
        [[ -n "$header" ]] || return 0
        count=$((count + 1))
        ((count <= 100)) || return 1
    done
}

# Answer one request. $1 is its first line. Only GET / and GET /metrics get the
# metrics; any other path is 404, any other method on those paths 405.
handle_connection() {
    local line="${1%$'\r'}" method path body rc=0
    local re_request='^([A-Z]+) (/[^ ]*) HTTP/[0-9]\.[0-9]$'

    if [[ ! "$line" =~ $re_request ]]; then
        send_response 400 "text/plain; charset=utf-8" $'Bad Request\n' || true
        return 0
    fi
    method="${BASH_REMATCH[1]}"
    path="${BASH_REMATCH[2]%%\?*}"

    if ! read_request_head; then
        send_response 400 "text/plain; charset=utf-8" $'Bad Request\n' || true
        return 0
    fi

    case "$path" in
        / | /metrics) ;;
        *)
            send_response 404 "text/plain; charset=utf-8" $'Not Found\n' || true
            return 0
            ;;
    esac
    if [[ "$method" != "GET" ]]; then
        send_response 405 "text/plain; charset=utf-8" $'Method Not Allowed\n' "Allow: GET" || true
        return 0
    fi

    # Generated now, after the request arrived: never older than the request.
    body="$(generate_all_metrics)" || rc=$?
    if ((rc != 0 && rc != EXIT_DEGRADED)); then
        log "ERROR: generating the metrics failed (status ${rc})"
        send_response 500 "text/plain; charset=utf-8" $'Internal Server Error\n' || true
        return 0
    fi
    send_response 200 "text/plain; version=0.0.4; charset=utf-8" "${body}"$'\n' || true
    return 0
}

# Let the nc of the connection being served finish the response (it quits on EOF
# of its stdin, then the peer's FIN) and stop it if it does not within
# SERVE_CLOSE_TIMEOUT.
finish_connection() {
    local slot="$_SRV_CUR" fd deadline=$((SECONDS + SERVE_CLOSE_TIMEOUT))
    fd="${_L_W[slot]}"
    if [[ -n "$fd" ]]; then
        exec {fd}>&-
        _L_W[slot]=""
    fi
    fd="${_L_R[slot]}"
    if [[ -n "$fd" ]]; then
        while IFS= read -r -t "$SERVE_CLOSE_TIMEOUT" -n 65536 -u "$fd" _; do
            ((SECONDS < deadline)) || break
        done
    fi
    stop_listener "$slot"
}

# Exit trap of the server: stop our nc processes and remove the private directory.
srv_cleanup() {
    log "Shutting down metrics server..."
    stop_listener 0
    stop_listener 1
    if [[ -n "$_SRV_SLEEP" ]]; then
        exec {_SRV_SLEEP}<&-
        _SRV_SLEEP=""
    fi
    if [[ -n "$_SRV_DIR" ]]; then
        rm -rf -- "$_SRV_DIR"
        _SRV_DIR=""
    fi
}

# Run the server on BIND:PORT until stopped (SIGTERM/SIGINT end it cleanly with
# status 0). Returns EXIT_FAILED when it cannot run: no usable netcat, no private
# temp directory, or the port cannot be bound after SERVE_START_ATTEMPTS tries.
serve_metrics() {
    local port="$1" bind="$2"
    local failures=0 delay_ms="$SERVE_RETRY_MS" err="" first="" rrc=0 url_host="" cur=0

    _SRV_PORT="$port"
    _SRV_BIND="$bind"

    if ! detect_nc; then
        log "ERROR: a netcat (nc) is required for the HTTP server; install netcat-openbsd"
        return "$EXIT_FAILED"
    fi
    build_nc_command "$bind" "$port" || return "$EXIT_FAILED"

    if ! _SRV_DIR="$(mktemp -d)"; then
        log "ERROR: cannot create a temporary directory for the server"
        return "$EXIT_FAILED"
    fi
    _L_FIFO=("${_SRV_DIR}/to_nc.0" "${_SRV_DIR}/to_nc.1")
    _L_ERR=("${_SRV_DIR}/nc.err.0" "${_SRV_DIR}/nc.err.1")
    if ! mkfifo "${_L_FIFO[0]}" "${_L_FIFO[1]}" "${_SRV_DIR}/sleep" || ! exec {_SRV_SLEEP}<>"${_SRV_DIR}/sleep"; then
        log "ERROR: cannot create the server's FIFOs in ${_SRV_DIR}"
        rm -rf -- "$_SRV_DIR"
        _SRV_DIR=""
        return "$EXIT_FAILED"
    fi

    trap 'exit 0' HUP INT TERM
    trap srv_cleanup EXIT

    # Come up, or say why not: a taken port and a failed bind are retried a few
    # times (the previous instance may still be closing its socket), then fatal.
    while :; do
        if port_in_use "$port" "$bind"; then
            err="something is already listening on ${bind}:${port}"
        elif start_listener 0 && wait_listener_bound 0; then
            break
        else
            err="$(listener_error 0)"
            err="${err:-the netcat did not bind}"
            stop_listener 0
        fi
        failures=$((failures + 1))
        if ((failures >= SERVE_START_ATTEMPTS)); then
            log "ERROR: cannot listen on ${bind}:${port}: ${err}"
            return "$EXIT_FAILED"
        fi
        log "WARN: cannot listen on ${bind}:${port} (${err}); retrying"
        srv_sleep "$((delay_ms / 1000)).$(printf '%03d' $((delay_ms % 1000)))"
        delay_ms=$((delay_ms * 2))
    done

    url_host="$bind"
    if is_wildcard_bind "$bind"; then
        url_host="<this host>"
    elif [[ "$bind" == *:* ]]; then
        url_host="[${bind}]"
    fi
    log "Metrics server listening on http://${url_host}:${port}/metrics (netcat: ${_SRV_NC_VARIANT}; GET / and GET /metrics; one connection at a time)"
    if ! is_loopback_bind "$bind"; then
        log "WARN: ${bind} is not a loopback address: the metrics are served without authentication or TLS to anything that can reach ${bind}:${port}"
    fi
    log "Stop with SIGTERM or Ctrl+C"

    failures=0
    delay_ms="$SERVE_RETRY_MS"
    _SRV_CUR=0
    while :; do
        cur="$_SRV_CUR"
        if [[ -z "${_L_PID[cur]}" ]] && ! start_listener "$cur"; then
            err="could not start ${_SRV_NC_BIN}"
            rrc=1
        else
            rrc=0
            first=""
            IFS= read -r -t "$SERVE_IDLE_ROTATE" -n 8192 -u "${_L_R[cur]}" first || rrc=$?
            err=""
        fi

        if ((rrc == 0)); then
            # A client is connected to this nc, which no longer listens: arm the
            # other slot before the metrics are generated, so the port is never
            # left without a listener while a request is answered. If that fails
            # it is noticed (and counted) when the slot becomes the current one.
            start_listener "$((1 - cur))" || true
            handle_connection "$first" || log "WARN: request handling failed"
            finish_connection
            _SRV_CUR=$((1 - cur))
            failures=0
            delay_ms="$SERVE_RETRY_MS"
        elif ((rrc > 128)); then
            # Idle: recycle the listener. This also drops a client that connected
            # and never sent anything, which would otherwise hold the only
            # connection for ever.
            stop_listener "$cur"
        else
            # nc ended without a request: it failed (it said so on stderr), or a
            # client connected and left without sending.
            err="${err:-$(listener_error "$cur")}"
            stop_listener "$cur"
            if [[ -n "$err" ]]; then
                failures=$((failures + 1))
                if ((failures >= SERVE_START_ATTEMPTS)); then
                    log "ERROR: the listener on ${bind}:${port} keeps failing: ${err}"
                    return "$EXIT_FAILED"
                fi
                log "WARN: the listener on ${bind}:${port} failed (${err}); restarting"
                srv_sleep "$((delay_ms / 1000)).$(printf '%03d' $((delay_ms % 1000)))"
                delay_ms=$((delay_ms * 2))
            else
                srv_sleep 0.05
            fi
        fi
    done
}

# ============================================================================
# Main
# ============================================================================

show_help() {
    cat <<EOF
Usage: ${SCRIPT_NAME} [OPTIONS]

Export LyreBirdAudio metrics in Prometheus format.

Options:
  -h, --help          Show this help message
  -v, --version       Show version
  --serve [PORT]      Serve the metrics over HTTP on PORT (default: 9100); the
                      same as the "serve" command with --port
  serve               Serve over HTTP; combine with --port and --bind
  --port PORT         Port for the HTTP server (default: 9100)
  --bind ADDR         Address the HTTP server listens on: an IPv4/IPv6 literal
                      or "localhost" (default: 127.0.0.1). The server has no
                      authentication or TLS; bind a non-loopback address only
                      on a network you trust
  --file PATH         Write metrics to file (for node_exporter textfile); the file
                      is replaced atomically and the previous one is kept if
                      anything fails
  --once              Output metrics once and exit (default)

The HTTP server answers GET / and GET /metrics (200), any other path with 404 and
any other method with 405, one connection at a time. It needs netcat (OpenBSD
nc, ncat, traditional/GNU nc or BusyBox nc). SIGTERM or SIGINT stops it cleanly.

Exit status:
  0  every collector completed (the server: stopped by a signal)
  1  command-line error
  2  nothing could be delivered: --file could not publish (the previous file
     is kept), or the HTTP server cannot run (no usable netcat, port in use)
  3  the output was delivered, but at least one collector failed
     (lyrebird_scrape_success is 0; the failing collector is named in
     lyrebird_collector_success and on stderr)

Examples:
  ${SCRIPT_NAME}                        # Output to stdout
  ${SCRIPT_NAME} --serve 9100           # Start HTTP server on 127.0.0.1:9100
  ${SCRIPT_NAME} serve --port 9100 --bind 0.0.0.0   # Same, on all interfaces
  ${SCRIPT_NAME} --file /tmp/lyrebird.prom  # Write to file

Integration:
  # Add to Prometheus scrape config:
  - job_name: 'lyrebird'
    static_configs:
      - targets: ['localhost:9100']

  # Or use with node_exporter textfile collector:
  */1 * * * * ${SCRIPT_NAME} --file /var/lib/node_exporter/textfile_collector/lyrebird.prom
EOF
}

main() {
    local mode="once"
    local port="9100"
    local bind="127.0.0.1"
    local server_option_given=0
    local output_file=""
    local gen_rc=0

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
            --serve)
                mode="serve"
                if [[ -n "${2:-}" ]] && [[ "$2" =~ ^[0-9]+$ ]]; then
                    port="$2"
                    shift
                fi
                shift
                ;;
            serve)
                mode="serve"
                shift
                ;;
            --port)
                if [[ -z "${2:-}" ]]; then
                    log "ERROR: --port requires a port number"
                    exit 1
                fi
                port="$2"
                server_option_given=1
                shift 2
                ;;
            --bind)
                if [[ -z "${2:-}" ]]; then
                    log "ERROR: --bind requires an address"
                    exit 1
                fi
                bind="$2"
                server_option_given=1
                shift 2
                ;;
            --file)
                mode="file"
                if [[ -n "${2:-}" ]]; then
                    output_file="$2"
                    shift
                else
                    log "ERROR: --file requires a path argument"
                    exit 1
                fi
                shift
                ;;
            --once)
                mode="once"
                shift
                ;;
            *)
                log "ERROR: Unknown option: $1"
                show_help
                exit 1
                ;;
        esac
    done

    if [[ "$mode" != "serve" ]] && ((server_option_given)); then
        log "ERROR: --port and --bind apply to the HTTP server only (use serve or --serve)"
        exit 1
    fi

    case "$mode" in
        serve)
            if [[ "$bind" == "localhost" ]]; then
                bind="127.0.0.1"
            fi
            if ! valid_port "$port"; then
                log "ERROR: invalid port '${port}' (need 1-65535)"
                exit 1
            fi
            if ! valid_bind "$bind"; then
                log "ERROR: invalid --bind address '${bind}' (need an IPv4 or IPv6 literal, or localhost)"
                exit 1
            fi
            gen_rc=0
            serve_metrics "$port" "$bind" || gen_rc=$?
            return "$gen_rc"
            ;;
        file)
            if [[ -z "$output_file" ]]; then
                log "ERROR: Output file path required"
                exit 1
            fi
            gen_rc=0
            publish_metrics_file "$output_file" || gen_rc=$?
            return "$gen_rc"
            ;;
        once | *)
            gen_rc=0
            generate_all_metrics || gen_rc=$?
            return "$gen_rc"
            ;;
    esac
}

# Only execute when run directly, not when sourced (e.g. by the test suite)
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi
