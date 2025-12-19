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
# Version: 1.1.0 - Enhanced MediaMTX API metrics coverage

set -euo pipefail

readonly VERSION="1.1.0"
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

# ============================================================================
# Metric Collection Functions
# ============================================================================

# Output a metric in Prometheus format
emit_metric() {
    local name="$1"
    local value="$2"
    local help="${3:-}"
    local type="${4:-gauge}"
    local labels="${5:-}"

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

# Collect MediaMTX service metrics
collect_mediamtx_metrics() {
    local mediamtx_running=0
    local mediamtx_pid=0

    # Check if MediaMTX is running
    if pgrep -f "mediamtx" >/dev/null 2>&1; then
        mediamtx_running=1
        mediamtx_pid=$(pgrep -f "mediamtx" | head -1)
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
            fd_count=$(find "/proc/${mediamtx_pid}/fd" -maxdepth 1 -type l 2>/dev/null | wc -l)
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
}

# Collect stream manager metrics
collect_stream_manager_metrics() {
    local stream_mgr_running=0
    local active_streams=0
    local configured_devices=0

    # Check if stream manager is running
    if [[ -f "$PID_FILE" ]]; then
        local pid
        pid=$(cat "$PID_FILE" 2>/dev/null)
        if [[ -n "$pid" ]] && kill -0 "$pid" 2>/dev/null; then
            stream_mgr_running=1
        fi
    fi

    emit_metric "stream_manager_up" "$stream_mgr_running" "Stream manager running (1=up, 0=down)"

    # Count active FFmpeg streams
    if [[ -d "$FFMPEG_PID_DIR" ]]; then
        for pid_file in "${FFMPEG_PID_DIR}"/*.pid; do
            [[ -f "$pid_file" ]] || continue
            local pid
            pid=$(cat "$pid_file" 2>/dev/null)
            if [[ -n "$pid" ]] && kill -0 "$pid" 2>/dev/null; then
                ((++active_streams))
            fi
        done
    fi

    emit_metric "active_streams" "$active_streams" "Number of active audio streams"

    # Count configured devices
    if [[ -f "$DEVICE_CONFIG" ]]; then
        configured_devices=$(grep -c "^DEVICE_" "$DEVICE_CONFIG" 2>/dev/null || echo 0)
    fi

    emit_metric "configured_devices" "$configured_devices" "Number of configured audio devices"

    # Heartbeat freshness
    if [[ -f "$HEARTBEAT_FILE" ]]; then
        local heartbeat_time
        heartbeat_time=$(cat "$HEARTBEAT_FILE" 2>/dev/null || echo 0)
        local now
        now=$(date +%s)
        local heartbeat_age=$((now - heartbeat_time))
        emit_metric "heartbeat_age_seconds" "$heartbeat_age" "Seconds since last heartbeat"

        # Heartbeat healthy (< 60 seconds old)
        local heartbeat_healthy=0
        [[ $heartbeat_age -lt 60 ]] && heartbeat_healthy=1
        emit_metric "heartbeat_healthy" "$heartbeat_healthy" "Heartbeat is recent (1=healthy, 0=stale)"
    else
        emit_metric "heartbeat_age_seconds" "-1" "Seconds since last heartbeat"
        emit_metric "heartbeat_healthy" "0" "Heartbeat is recent (1=healthy, 0=stale)"
    fi
}

# Collect USB audio device metrics
collect_usb_audio_metrics() {
    local usb_audio_count=0
    local total_audio_cards=0

    # Count audio cards from ALSA
    if [[ -f "/proc/asound/cards" ]]; then
        while IFS= read -r line; do
            if [[ "$line" =~ ^[[:space:]]*([0-9]+)[[:space:]]*\[ ]]; then
                ((++total_audio_cards))
                local card_num="${BASH_REMATCH[1]}"
                if [[ -f "/proc/asound/card${card_num}/usbid" ]]; then
                    ((++usb_audio_count))
                fi
            fi
        done </proc/asound/cards
    fi

    emit_metric "usb_audio_devices" "$usb_audio_count" "Number of USB audio devices detected"
    emit_metric "total_audio_cards" "$total_audio_cards" "Total ALSA audio cards"
}

# Collect system resource metrics
collect_system_metrics() {
    # Disk usage for relevant paths
    for path in "/" "/var" "/tmp"; do
        if [[ -d "$path" ]] && has_command df; then
            local usage
            usage=$(df "$path" 2>/dev/null | tail -1 | awk '{print $5}' | sed 's/%//')
            if [[ "$usage" =~ ^[0-9]+$ ]]; then
                local label="mount=\"${path}\""
                emit_metric "disk_usage_percent" "$usage" "Disk usage percentage" "gauge" "$label"
            fi
        fi
    done

    # Memory
    if [[ -f "/proc/meminfo" ]]; then
        local mem_total
        local mem_available
        mem_total=$(grep "^MemTotal:" /proc/meminfo | awk '{print $2}')
        mem_available=$(grep "^MemAvailable:" /proc/meminfo | awk '{print $2}')

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
        ((attempt++))
        result=$(curl -s --connect-timeout "$timeout" "$url" 2>/dev/null) && break
        # Brief pause before retry
        ((attempt < retries)) && sleep 1
    done

    echo "$result"
}

# Collect MediaMTX API metrics (if available)
# Enhanced in v1.1.0 with full MediaMTX v1.15.5 API coverage
collect_api_metrics() {
    if ! has_command curl; then
        return
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
        emit_metric "api_info" "1" "MediaMTX instance info" "gauge" "version=\"${version}\""

        # Extract uptime (in nanoseconds, convert to seconds)
        local uptime_ns
        uptime_ns=$(echo "$info_json" | grep -o '"upTime":[0-9]*' | cut -d':' -f2 || echo "0")
        if [[ -n "$uptime_ns" ]] && [[ "$uptime_ns" =~ ^[0-9]+$ ]]; then
            local uptime_sec=$((uptime_ns / 1000000000))
            emit_metric "api_uptime_seconds" "$uptime_sec" "MediaMTX uptime in seconds"
        fi

        # Get path count from API
        local paths_json
        paths_json=$(curl -s --connect-timeout 5 "${api_url}/v3/paths/list" 2>/dev/null)

        if [[ -n "$paths_json" ]]; then
            # Count paths (simple grep approach for portability)
            local path_count
            path_count=$(echo "$paths_json" | grep -o '"name"' | wc -l)
            emit_metric "api_paths_total" "$path_count" "Total paths registered in MediaMTX"

            # Count ready paths
            local ready_count
            ready_count=$(echo "$paths_json" | grep -o '"ready":true' | wc -l)
            emit_metric "api_paths_ready" "$ready_count" "Paths with ready status"
        fi

        # Collect RTSP session metrics
        local rtsp_sessions_json
        rtsp_sessions_json=$(curl -s --connect-timeout 5 "${api_url}/v3/rtspsessions/list" 2>/dev/null)
        if [[ -n "$rtsp_sessions_json" ]]; then
            local rtsp_session_count
            rtsp_session_count=$(echo "$rtsp_sessions_json" | grep -o '"id"' | wc -l)
            emit_metric "api_rtsp_sessions" "$rtsp_session_count" "Active RTSP sessions (listeners)"
        fi

        # Collect RTSP connection metrics
        local rtsp_conns_json
        rtsp_conns_json=$(curl -s --connect-timeout 5 "${api_url}/v3/rtspconns/list" 2>/dev/null)
        if [[ -n "$rtsp_conns_json" ]]; then
            local rtsp_conn_count
            rtsp_conn_count=$(echo "$rtsp_conns_json" | grep -o '"id"' | wc -l)
            emit_metric "api_rtsp_connections" "$rtsp_conn_count" "Active RTSP connections"
        fi

        # Collect RTSPS (secure) session metrics
        local rtsps_sessions_json
        rtsps_sessions_json=$(curl -s --connect-timeout 5 "${api_url}/v3/rtspssessions/list" 2>/dev/null)
        if [[ -n "$rtsps_sessions_json" ]]; then
            local rtsps_session_count
            rtsps_session_count=$(echo "$rtsps_sessions_json" | grep -o '"id"' | wc -l)
            emit_metric "api_rtsps_sessions" "$rtsps_session_count" "Active RTSPS sessions (secure)"
        fi

        # Collect RTMP connection metrics
        local rtmp_conns_json
        rtmp_conns_json=$(curl -s --connect-timeout 5 "${api_url}/v3/rtmpconns/list" 2>/dev/null)
        if [[ -n "$rtmp_conns_json" ]]; then
            local rtmp_conn_count
            rtmp_conn_count=$(echo "$rtmp_conns_json" | grep -o '"id"' | wc -l)
            emit_metric "api_rtmp_connections" "$rtmp_conn_count" "Active RTMP connections"
        fi

        # Collect RTMPS (secure) connection metrics
        local rtmps_conns_json
        rtmps_conns_json=$(curl -s --connect-timeout 5 "${api_url}/v3/rtmpsconns/list" 2>/dev/null)
        if [[ -n "$rtmps_conns_json" ]]; then
            local rtmps_conn_count
            rtmps_conn_count=$(echo "$rtmps_conns_json" | grep -o '"id"' | wc -l)
            emit_metric "api_rtmps_connections" "$rtmps_conn_count" "Active RTMPS connections (secure)"
        fi

        # Collect WebRTC session metrics
        local webrtc_sessions_json
        webrtc_sessions_json=$(curl -s --connect-timeout 5 "${api_url}/v3/webrtcsessions/list" 2>/dev/null)
        if [[ -n "$webrtc_sessions_json" ]]; then
            local webrtc_session_count
            webrtc_session_count=$(echo "$webrtc_sessions_json" | grep -o '"id"' | wc -l)
            emit_metric "api_webrtc_sessions" "$webrtc_session_count" "Active WebRTC sessions"
        fi

        # Collect SRT connection metrics
        local srt_conns_json
        srt_conns_json=$(curl -s --connect-timeout 5 "${api_url}/v3/srtconns/list" 2>/dev/null)
        if [[ -n "$srt_conns_json" ]]; then
            local srt_conn_count
            srt_conn_count=$(echo "$srt_conns_json" | grep -o '"id"' | wc -l)
            emit_metric "api_srt_connections" "$srt_conn_count" "Active SRT connections"
        fi

        # Collect HLS muxer metrics
        local hls_muxers_json
        hls_muxers_json=$(curl -s --connect-timeout 5 "${api_url}/v3/hlsmuxers/list" 2>/dev/null)
        if [[ -n "$hls_muxers_json" ]]; then
            local hls_muxer_count
            hls_muxer_count=$(echo "$hls_muxers_json" | grep -o '"path"' | wc -l)
            emit_metric "api_hls_muxers" "$hls_muxer_count" "Active HLS muxers"
        fi

        # Collect recording metrics
        local recordings_json
        recordings_json=$(curl -s --connect-timeout 5 "${api_url}/v3/recordings/list" 2>/dev/null)
        if [[ -n "$recordings_json" ]]; then
            local recording_count
            recording_count=$(echo "$recordings_json" | grep -o '"name"' | wc -l)
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
}

# Collect per-stream metrics
collect_stream_metrics() {
    if [[ ! -d "$FFMPEG_PID_DIR" ]]; then
        return
    fi

    for pid_file in "${FFMPEG_PID_DIR}"/*.pid; do
        [[ -f "$pid_file" ]] || continue

        local stream_name
        stream_name=$(basename "$pid_file" .pid)
        local pid
        pid=$(cat "$pid_file" 2>/dev/null)

        # Stream status
        local status=0
        if [[ -n "$pid" ]] && kill -0 "$pid" 2>/dev/null; then
            status=1
        fi

        local labels="stream=\"${stream_name}\""
        emit_metric "stream_up" "$status" "Stream running status" "gauge" "$labels"

        if [[ $status -eq 1 ]] && [[ -d "/proc/${pid}" ]]; then
            # Stream memory usage
            if [[ -f "/proc/${pid}/status" ]]; then
                local vm_rss
                vm_rss=$(grep "^VmRSS:" "/proc/${pid}/status" 2>/dev/null | awk '{print $2}' || echo 0)
                if [[ "$vm_rss" =~ ^[0-9]+$ ]]; then
                    emit_metric "stream_memory_bytes" "$((vm_rss * 1024))" "Stream memory usage" "gauge" "$labels"
                fi
            fi

            # Stream CPU usage
            if has_command ps; then
                local cpu
                cpu=$(ps -p "$pid" -o %cpu= 2>/dev/null | tr -d ' ' || echo 0)
                emit_metric "stream_cpu_percent" "${cpu%.*}" "Stream CPU usage" "gauge" "$labels"
            fi
        fi
    done
}

# ============================================================================
# Output Functions
# ============================================================================

generate_all_metrics() {
    echo "# LyreBirdAudio Prometheus Metrics"
    echo "# Generated at $(date -Iseconds)"
    echo ""

    # Build info
    emit_metric "build_info" "1" "LyreBirdAudio metrics exporter version" "gauge" "version=\"${VERSION}\""
    echo ""

    collect_mediamtx_metrics
    echo ""

    collect_stream_manager_metrics
    echo ""

    collect_usb_audio_metrics
    echo ""

    collect_system_metrics
    echo ""

    collect_api_metrics
    echo ""

    collect_stream_metrics
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
    cat << EOF
Usage: ${SCRIPT_NAME} [OPTIONS]

Export LyreBirdAudio metrics in Prometheus format.

Options:
  -h, --help          Show this help message
  -v, --version       Show version
  --serve PORT        Start HTTP server on PORT (default: 9100)
  --file PATH         Write metrics to file (for node_exporter textfile)
  --once              Output metrics once and exit (default)

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
            generate_all_metrics > "${output_file}.tmp"
            mv "${output_file}.tmp" "$output_file"
            ;;
        once|*)
            generate_all_metrics
            ;;
    esac
}

main "$@"
