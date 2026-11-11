#!/bin/bash
# lyrebird-metrics.sh - Prometheus metrics exporter for LyreBirdAudio
# Part of LyreBirdAudio - RTSP Audio Streaming Suite
# https://github.com/tomtom215/LyreBirdAudio
#
# Exports metrics in Prometheus text format for monitoring and alerting.
#
# Usage:
#   ./lyrebird-metrics.sh              # Output metrics to stdout
#   ./lyrebird-metrics.sh --serve 9100 # Start HTTP server on port 9100
#   ./lyrebird-metrics.sh --file /path # Write metrics to file
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
readonly PID_FILE="${PID_FILE:-/run/mediamtx-audio.pid}"
readonly FFMPEG_PID_DIR="${FFMPEG_PID_DIR:-/var/lib/mediamtx-ffmpeg}"
readonly CONFIG_DIR="${MEDIAMTX_CONFIG_DIR:-/etc/mediamtx}"
readonly DEVICE_CONFIG="${CONFIG_DIR}/audio-devices.conf"

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

# Collect MediaMTX service metrics
collect_mediamtx_metrics() {
    local mediamtx_running=0
    local mediamtx_pid=0

    # Without pgrep "not running" cannot be told from "cannot tell"; report the
    # collector as failed instead of publishing a false lyrebird_mediamtx_up 0.
    if ! has_command pgrep; then
        log "ERROR: pgrep not found; cannot tell whether MediaMTX is running (install procps)"
        return 1
    fi

    # Check if MediaMTX is running
    if pgrep -f "mediamtx" >/dev/null 2>&1; then
        mediamtx_running=1
        mediamtx_pid=$(pgrep -f "mediamtx" | head -1) || true
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

        # File descriptors
        if [[ -d "/proc/${mediamtx_pid}/fd" ]]; then
            local fd_count
            fd_count=$(find "/proc/${mediamtx_pid}/fd" -maxdepth 1 -type l 2>/dev/null | wc -l || true)
            emit_metric "mediamtx_open_fds" "$fd_count" "MediaMTX open file descriptors"
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
    return 0
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
        local pid
        if pid=$(cat "$PID_FILE" 2>/dev/null); then
            if [[ -n "$pid" ]] && kill -0 "$pid" 2>/dev/null; then
                stream_mgr_running=1
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
            if [[ -n "$pid" ]] && kill -0 "$pid" 2>/dev/null; then
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

# Helper function for API calls with retry for transient network failures
# Usage: api_call_with_retry <url> [timeout] [retries]
api_call_with_retry() {
    local url="$1"
    local timeout="${2:-5}"
    local retries="${3:-2}"
    local attempt=0
    local result=""

    while ((attempt < retries)); do
        ((attempt++)) || true
        result=$(curl -s --connect-timeout "$timeout" "$url" 2>/dev/null) && break
        # Brief pause before retry
        ((attempt < retries)) && sleep 1
    done

    echo "$result"
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

    # Check API availability and get instance info (with retry for transient failures)
    local api_up=0
    local info_json
    info_json=$(api_call_with_retry "${api_url}/v3/info" 2 2)
    if [[ -n "$info_json" ]] && echo "$info_json" | grep -q '"version"'; then
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
        paths_json=$(curl -s --connect-timeout 5 "${api_url}/v3/paths/list" 2>/dev/null || true)

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
        rtsp_sessions_json=$(curl -s --connect-timeout 5 "${api_url}/v3/rtspsessions/list" 2>/dev/null || true)
        if [[ -n "$rtsp_sessions_json" ]]; then
            local rtsp_session_count
            rtsp_session_count=$(echo "$rtsp_sessions_json" | grep -o '"id"' | wc -l || true)
            emit_metric "api_rtsp_sessions" "$rtsp_session_count" "Active RTSP sessions (listeners)"
        fi

        # Collect RTSP connection metrics
        local rtsp_conns_json
        rtsp_conns_json=$(curl -s --connect-timeout 5 "${api_url}/v3/rtspconns/list" 2>/dev/null || true)
        if [[ -n "$rtsp_conns_json" ]]; then
            local rtsp_conn_count
            rtsp_conn_count=$(echo "$rtsp_conns_json" | grep -o '"id"' | wc -l || true)
            emit_metric "api_rtsp_connections" "$rtsp_conn_count" "Active RTSP connections"
        fi

        # Collect RTSPS (secure) session metrics
        local rtsps_sessions_json
        rtsps_sessions_json=$(curl -s --connect-timeout 5 "${api_url}/v3/rtspssessions/list" 2>/dev/null || true)
        if [[ -n "$rtsps_sessions_json" ]]; then
            local rtsps_session_count
            rtsps_session_count=$(echo "$rtsps_sessions_json" | grep -o '"id"' | wc -l || true)
            emit_metric "api_rtsps_sessions" "$rtsps_session_count" "Active RTSPS sessions (secure)"
        fi

        # Collect RTMP connection metrics
        local rtmp_conns_json
        rtmp_conns_json=$(curl -s --connect-timeout 5 "${api_url}/v3/rtmpconns/list" 2>/dev/null || true)
        if [[ -n "$rtmp_conns_json" ]]; then
            local rtmp_conn_count
            rtmp_conn_count=$(echo "$rtmp_conns_json" | grep -o '"id"' | wc -l || true)
            emit_metric "api_rtmp_connections" "$rtmp_conn_count" "Active RTMP connections"
        fi

        # Collect RTMPS (secure) connection metrics
        local rtmps_conns_json
        rtmps_conns_json=$(curl -s --connect-timeout 5 "${api_url}/v3/rtmpsconns/list" 2>/dev/null || true)
        if [[ -n "$rtmps_conns_json" ]]; then
            local rtmps_conn_count
            rtmps_conn_count=$(echo "$rtmps_conns_json" | grep -o '"id"' | wc -l || true)
            emit_metric "api_rtmps_connections" "$rtmps_conn_count" "Active RTMPS connections (secure)"
        fi

        # Collect WebRTC session metrics
        local webrtc_sessions_json
        webrtc_sessions_json=$(curl -s --connect-timeout 5 "${api_url}/v3/webrtcsessions/list" 2>/dev/null || true)
        if [[ -n "$webrtc_sessions_json" ]]; then
            local webrtc_session_count
            webrtc_session_count=$(echo "$webrtc_sessions_json" | grep -o '"id"' | wc -l || true)
            emit_metric "api_webrtc_sessions" "$webrtc_session_count" "Active WebRTC sessions"
        fi

        # Collect SRT connection metrics
        local srt_conns_json
        srt_conns_json=$(curl -s --connect-timeout 5 "${api_url}/v3/srtconns/list" 2>/dev/null || true)
        if [[ -n "$srt_conns_json" ]]; then
            local srt_conn_count
            srt_conn_count=$(echo "$srt_conns_json" | grep -o '"id"' | wc -l || true)
            emit_metric "api_srt_connections" "$srt_conn_count" "Active SRT connections"
        fi

        # Collect HLS muxer metrics
        local hls_muxers_json
        hls_muxers_json=$(curl -s --connect-timeout 5 "${api_url}/v3/hlsmuxers/list" 2>/dev/null || true)
        if [[ -n "$hls_muxers_json" ]]; then
            local hls_muxer_count
            hls_muxer_count=$(echo "$hls_muxers_json" | grep -o '"path"' | wc -l || true)
            emit_metric "api_hls_muxers" "$hls_muxer_count" "Active HLS muxers"
        fi

        # Collect recording metrics
        local recordings_json
        recordings_json=$(curl -s --connect-timeout 5 "${api_url}/v3/recordings/list" 2>/dev/null || true)
        if [[ -n "$recordings_json" ]]; then
            local recording_count
            recording_count=$(echo "$recordings_json" | grep -o '"name"' | wc -l || true)
            emit_metric "api_recordings_total" "$recording_count" "Total recording paths"
        fi

        # Calculate total connections across all protocols
        local total_connections=0
        [[ "${rtsp_session_count:-0}" =~ ^[0-9]+$ ]] && total_connections=$((total_connections + rtsp_session_count))
        [[ "${rtsps_session_count:-0}" =~ ^[0-9]+$ ]] && total_connections=$((total_connections + rtsps_session_count))
        [[ "${rtmp_conn_count:-0}" =~ ^[0-9]+$ ]] && total_connections=$((total_connections + rtmp_conn_count))
        [[ "${rtmps_conn_count:-0}" =~ ^[0-9]+$ ]] && total_connections=$((total_connections + rtmps_conn_count))
        [[ "${webrtc_session_count:-0}" =~ ^[0-9]+$ ]] && total_connections=$((total_connections + webrtc_session_count))
        [[ "${srt_conn_count:-0}" =~ ^[0-9]+$ ]] && total_connections=$((total_connections + srt_conn_count))
        emit_metric "api_total_connections" "$total_connections" "Total active connections across all protocols"
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
    local pid_file stream_name pid i n labels
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
        stream_names+=("$stream_name")
        stream_pids+=("$pid")
        if [[ -n "$pid" ]] && kill -0 "$pid" 2>/dev/null; then
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

# Simple HTTP server using netcat (for basic metrics serving)
serve_metrics() {
    local port="${1:-9100}"
    local nc_pid=""

    # Cleanup function to kill any lingering nc processes
    cleanup_server() {
        log "Shutting down metrics server..."
        [[ -n "$nc_pid" ]] && kill "$nc_pid" 2>/dev/null || true
        # Kill any orphaned nc processes on our port
        pkill -f "nc.*-l.*$port" 2>/dev/null || true
        exit 0
    }

    # Set up signal handlers for graceful shutdown
    trap cleanup_server EXIT INT TERM

    if ! has_command nc && ! has_command netcat; then
        log "ERROR: nc (netcat) required for --serve mode"
        exit 1
    fi

    log "Starting metrics server on port $port"
    log "Metrics available at http://localhost:${port}/metrics"
    log "Press Ctrl+C to stop"

    while true; do
        local metrics
        metrics=$(generate_all_metrics)
        local content_length=${#metrics}

        local response="HTTP/1.1 200 OK
Content-Type: text/plain; charset=utf-8
Content-Length: ${content_length}
Connection: close

${metrics}"

        echo -e "$response" | nc -l -p "$port" -q 1 2>/dev/null \
            || echo -e "$response" | nc -l "$port" 2>/dev/null \
            || true

        sleep 0.1
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
  --serve PORT        Start HTTP server on PORT (default: 9100)
  --file PATH         Write metrics to file (for node_exporter textfile); the file
                      is replaced atomically and the previous one is kept if
                      anything fails
  --once              Output metrics once and exit (default)

Exit status:
  0  every collector completed
  1  command-line error
  2  nothing could be delivered (--file could not publish; the previous file
     is kept)
  3  the output was delivered, but at least one collector failed
     (lyrebird_scrape_success is 0; the failing collector is named in
     lyrebird_collector_success and on stderr)

Examples:
  ${SCRIPT_NAME}                        # Output to stdout
  ${SCRIPT_NAME} --serve 9100           # Start HTTP server
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

    case "$mode" in
        serve)
            serve_metrics "$port"
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
