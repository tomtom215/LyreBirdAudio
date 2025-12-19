#!/bin/bash
# lyrebird-alerts.sh - Webhook Alerting System for LyreBirdAudio
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
#   Pure-bash webhook alerting system for remote monitoring of LyreBirdAudio
#   deployments. Sends HTTP POST notifications when streams fail, devices
#   disconnect, or resource thresholds are exceeded.
#
# FEATURES:
#   - Webhook alerts (Discord, Slack, ntfy, generic HTTP POST)
#   - Rate limiting to prevent alert spam
#   - Alert deduplication within configurable window
#   - Multiple webhook destinations
#   - Customizable alert templates
#   - No external dependencies beyond curl (already required)
#
# USAGE:
#   # Send a test alert
#   ./lyrebird-alerts.sh test
#
#   # Send a custom alert
#   ./lyrebird-alerts.sh send --level warning --message "Disk space low"
#
#   # Check alert status
#   ./lyrebird-alerts.sh status
#
#   # Configure webhooks
#   ./lyrebird-alerts.sh config
#
# CONFIGURATION:
#   Webhooks are configured in /etc/lyrebird/alerts.conf or via environment:
#
#   LYREBIRD_WEBHOOK_URL="https://your-webhook-url"
#   LYREBIRD_WEBHOOK_TYPE="generic"  # generic, discord, slack, ntfy
#   LYREBIRD_ALERT_RATE_LIMIT=60     # Minimum seconds between same alerts
#   LYREBIRD_ALERT_ENABLED=true
#
# SUPPORTED WEBHOOK TYPES:
#   - generic:  Simple HTTP POST with JSON body
#   - discord:  Discord webhook format
#   - slack:    Slack webhook format
#   - ntfy:     ntfy.sh notification service
#   - pushover: Pushover notification service
#
# EXIT CODES:
#   0 - Success
#   1 - General error
#   2 - Configuration error
#   3 - Webhook delivery failed
#   4 - Rate limited (not an error, alert suppressed)

set -euo pipefail

#=============================================================================
# Script Metadata
#=============================================================================

readonly SCRIPT_NAME="lyrebird-alerts"
readonly SCRIPT_VERSION="1.0.0"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly SCRIPT_DIR

#=============================================================================
# Source Common Library
#=============================================================================

_COMMON_LIB="${SCRIPT_DIR}/lyrebird-common.sh"
if [[ -f "$_COMMON_LIB" ]]; then
    # shellcheck source=lyrebird-common.sh
    source "$_COMMON_LIB"
else
    # Minimal fallback if common library not available
    RED='\033[0;31m'
    GREEN='\033[0;32m'
    YELLOW='\033[0;33m'
    BLUE='\033[0;34m'
    NC='\033[0m'
    log_info() { echo "[INFO] $*"; }
    log_warn() { echo "[WARN] $*" >&2; }
    log_error() { echo "[ERROR] $*" >&2; }
    log_debug() { [[ "${DEBUG:-false}" == "true" ]] && echo "[DEBUG] $*"; }
fi

#=============================================================================
# Configuration
#=============================================================================

# Configuration file location
readonly ALERT_CONFIG_FILE="${LYREBIRD_ALERT_CONFIG:-/etc/lyrebird/alerts.conf}"
readonly ALERT_STATE_DIR="${LYREBIRD_ALERT_STATE_DIR:-/var/lib/lyrebird/alerts}"
readonly ALERT_LOG_FILE="${LYREBIRD_ALERT_LOG:-/var/log/lyrebird/alerts.log}"

# Default configuration (can be overridden by config file or environment)
LYREBIRD_ALERT_ENABLED="${LYREBIRD_ALERT_ENABLED:-false}"
LYREBIRD_WEBHOOK_URL="${LYREBIRD_WEBHOOK_URL:-}"
LYREBIRD_WEBHOOK_TYPE="${LYREBIRD_WEBHOOK_TYPE:-generic}"
LYREBIRD_ALERT_RATE_LIMIT="${LYREBIRD_ALERT_RATE_LIMIT:-300}"  # 5 minutes default
LYREBIRD_ALERT_DEDUP_WINDOW="${LYREBIRD_ALERT_DEDUP_WINDOW:-3600}"  # 1 hour
LYREBIRD_ALERT_TIMEOUT="${LYREBIRD_ALERT_TIMEOUT:-30}"
LYREBIRD_ALERT_RETRIES="${LYREBIRD_ALERT_RETRIES:-3}"
LYREBIRD_HOSTNAME="${LYREBIRD_HOSTNAME:-$(hostname -s 2>/dev/null || echo 'unknown')}"
LYREBIRD_LOCATION="${LYREBIRD_LOCATION:-}"

# Validate timeout bounds (5-120 seconds)
if [[ "$LYREBIRD_ALERT_TIMEOUT" -lt 5 ]]; then
    LYREBIRD_ALERT_TIMEOUT=5
elif [[ "$LYREBIRD_ALERT_TIMEOUT" -gt 120 ]]; then
    LYREBIRD_ALERT_TIMEOUT=120
fi

# Additional webhook URLs (space-separated)
LYREBIRD_WEBHOOK_URLS="${LYREBIRD_WEBHOOK_URLS:-}"

# Pushover-specific (optional)
LYREBIRD_PUSHOVER_TOKEN="${LYREBIRD_PUSHOVER_TOKEN:-}"
LYREBIRD_PUSHOVER_USER="${LYREBIRD_PUSHOVER_USER:-}"

# ntfy-specific (optional)
LYREBIRD_NTFY_TOPIC="${LYREBIRD_NTFY_TOPIC:-lyrebird}"
LYREBIRD_NTFY_SERVER="${LYREBIRD_NTFY_SERVER:-https://ntfy.sh}"

#=============================================================================
# Alert Levels
#=============================================================================

# shellcheck disable=SC2034  # These constants are exported for use by other scripts
readonly ALERT_LEVEL_INFO="info"
# shellcheck disable=SC2034
readonly ALERT_LEVEL_WARNING="warning"
# shellcheck disable=SC2034
readonly ALERT_LEVEL_ERROR="error"
# shellcheck disable=SC2034
readonly ALERT_LEVEL_CRITICAL="critical"

# Colors for each level (for Discord/Slack)
declare -A ALERT_COLORS=(
    [info]=3447003      # Blue
    [warning]=16776960  # Yellow
    [error]=15158332    # Orange
    [critical]=15548997 # Red
)

# Emoji for each level
declare -A ALERT_EMOJI=(
    [info]="ℹ️"
    [warning]="⚠️"
    [error]="❌"
    [critical]="🚨"
)

#=============================================================================
# Alert Types (for deduplication keys)
#=============================================================================

readonly ALERT_TYPE_STREAM_DOWN="stream_down"
readonly ALERT_TYPE_STREAM_UP="stream_up"
readonly ALERT_TYPE_DEVICE_DISCONNECT="device_disconnect"
readonly ALERT_TYPE_DEVICE_CONNECT="device_connect"
readonly ALERT_TYPE_DISK_WARNING="disk_warning"
readonly ALERT_TYPE_DISK_CRITICAL="disk_critical"
readonly ALERT_TYPE_MEMORY_WARNING="memory_warning"
readonly ALERT_TYPE_CPU_WARNING="cpu_warning"
readonly ALERT_TYPE_MEDIAMTX_DOWN="mediamtx_down"
readonly ALERT_TYPE_MEDIAMTX_UP="mediamtx_up"
readonly ALERT_TYPE_NETWORK_DOWN="network_down"
readonly ALERT_TYPE_NETWORK_UP="network_up"
readonly ALERT_TYPE_TEST="test"
# shellcheck disable=SC2034  # Exported for use by other scripts
readonly ALERT_TYPE_CUSTOM="custom"

#=============================================================================
# Helper Functions
#=============================================================================

# URL-encode a string (handles all special characters)
url_encode() {
    local string="$1"
    # Use jq if available, otherwise fall back to printf-based encoding
    if command -v jq &>/dev/null; then
        printf '%s' "$string" | jq -sRr @uri
    else
        # Fallback: encode using printf with hex conversion
        local length="${#string}"
        local i char
        for ((i = 0; i < length; i++)); do
            char="${string:i:1}"
            case "$char" in
                [a-zA-Z0-9.~_-]) printf '%s' "$char" ;;
                *) printf '%%%02X' "'$char" ;;
            esac
        done
    fi
}

# Load configuration file if it exists
load_config() {
    if [[ -f "$ALERT_CONFIG_FILE" ]]; then
        log_debug "Loading configuration from $ALERT_CONFIG_FILE"
        # shellcheck source=/dev/null
        source "$ALERT_CONFIG_FILE"
    fi
}

# Ensure state directory exists
ensure_state_dir() {
    if [[ ! -d "$ALERT_STATE_DIR" ]]; then
        mkdir -p "$ALERT_STATE_DIR" 2>/dev/null || {
            log_warn "Cannot create state directory: $ALERT_STATE_DIR"
            return 1
        }
    fi
}

# Ensure log directory exists
ensure_log_dir() {
    local log_dir
    log_dir="$(dirname "$ALERT_LOG_FILE")"
    if [[ ! -d "$log_dir" ]]; then
        mkdir -p "$log_dir" 2>/dev/null || true
    fi
}

# Log alert to file
log_alert() {
    local level="$1"
    local message="$2"
    local timestamp
    timestamp="$(date '+%Y-%m-%d %H:%M:%S')"

    ensure_log_dir
    echo "[$timestamp] [$level] $message" >> "$ALERT_LOG_FILE" 2>/dev/null || true
}

# Generate hash for deduplication
generate_alert_hash() {
    local alert_type="$1"
    local message="$2"

    # Use simple checksum if sha256sum not available
    if command -v sha256sum &>/dev/null; then
        echo -n "${alert_type}:${message}" | sha256sum | cut -d' ' -f1 | head -c 16
    elif command -v md5sum &>/dev/null; then
        echo -n "${alert_type}:${message}" | md5sum | cut -d' ' -f1 | head -c 16
    else
        # Fallback: use simple string hash
        echo -n "${alert_type}:${message}" | cksum | cut -d' ' -f1
    fi
}

# Check if alert should be rate limited
is_rate_limited() {
    local alert_hash="$1"
    local rate_limit="${LYREBIRD_ALERT_RATE_LIMIT}"
    local state_file="${ALERT_STATE_DIR}/${alert_hash}.last"

    ensure_state_dir || return 1  # Not rate limited if we can't check

    if [[ ! -f "$state_file" ]]; then
        return 1  # Not rate limited
    fi

    local last_sent
    last_sent=$(cat "$state_file" 2>/dev/null || echo 0)
    local now
    now=$(date +%s)
    local elapsed=$((now - last_sent))

    if ((elapsed < rate_limit)); then
        log_debug "Alert rate limited: ${elapsed}s since last (limit: ${rate_limit}s)"
        return 0  # Rate limited
    fi

    return 1  # Not rate limited
}

# Update rate limit state
update_rate_limit() {
    local alert_hash="$1"
    local state_file="${ALERT_STATE_DIR}/${alert_hash}.last"

    ensure_state_dir || return 1
    date +%s > "$state_file" 2>/dev/null || true
}

# Clean old state files
cleanup_state() {
    local max_age="${LYREBIRD_ALERT_DEDUP_WINDOW}"

    ensure_state_dir || return 0

    find "$ALERT_STATE_DIR" -name "*.last" -mmin "+$((max_age / 60))" -delete 2>/dev/null || true
}

#=============================================================================
# Webhook Formatters
#=============================================================================

# Format message for generic webhook (simple JSON)
format_generic() {
    local level="$1"
    local title="$2"
    local message="$3"
    local alert_type="$4"
    local timestamp
    timestamp="$(date -u '+%Y-%m-%dT%H:%M:%SZ')"

    cat <<EOF
{
  "level": "${level}",
  "title": "${title}",
  "message": "${message}",
  "type": "${alert_type}",
  "hostname": "${LYREBIRD_HOSTNAME}",
  "location": "${LYREBIRD_LOCATION}",
  "timestamp": "${timestamp}",
  "source": "lyrebird-alerts"
}
EOF
}

# Format message for Discord webhook
format_discord() {
    local level="$1"
    local title="$2"
    local message="$3"
    local alert_type="$4"
    local color="${ALERT_COLORS[$level]:-3447003}"
    local emoji="${ALERT_EMOJI[$level]:-ℹ️}"
    local timestamp
    timestamp="$(date -u '+%Y-%m-%dT%H:%M:%SZ')"

    # Escape special characters for JSON
    message="${message//\\/\\\\}"
    message="${message//\"/\\\"}"
    message="${message//$'\n'/\\n}"
    title="${title//\\/\\\\}"
    title="${title//\"/\\\"}"

    cat <<EOF
{
  "embeds": [{
    "title": "${emoji} ${title}",
    "description": "${message}",
    "color": ${color},
    "fields": [
      {"name": "Host", "value": "${LYREBIRD_HOSTNAME}", "inline": true},
      {"name": "Level", "value": "${level}", "inline": true},
      {"name": "Type", "value": "${alert_type}", "inline": true}
    ],
    "footer": {"text": "LyreBirdAudio Alerts"},
    "timestamp": "${timestamp}"
  }]
}
EOF
}

# Format message for Slack webhook
format_slack() {
    local level="$1"
    local title="$2"
    local message="$3"
    local alert_type="$4"
    local emoji="${ALERT_EMOJI[$level]:-ℹ️}"

    # Escape special characters for JSON
    message="${message//\\/\\\\}"
    message="${message//\"/\\\"}"
    message="${message//$'\n'/\\n}"
    title="${title//\\/\\\\}"
    title="${title//\"/\\\"}"

    # Slack colors
    local color
    case "$level" in
        info) color="#3498db" ;;
        warning) color="#f1c40f" ;;
        error) color="#e67e22" ;;
        critical) color="#e74c3c" ;;
        *) color="#95a5a6" ;;
    esac

    cat <<EOF
{
  "attachments": [{
    "color": "${color}",
    "title": "${emoji} ${title}",
    "text": "${message}",
    "fields": [
      {"title": "Host", "value": "${LYREBIRD_HOSTNAME}", "short": true},
      {"title": "Level", "value": "${level}", "short": true}
    ],
    "footer": "LyreBirdAudio Alerts",
    "ts": $(date +%s)
  }]
}
EOF
}

# Format message for ntfy.sh
format_ntfy() {
    local level="$1"
    local title="$2"
    local message="$3"
    local alert_type="$4"

    # Map level to ntfy priority
    local priority
    case "$level" in
        info) priority="default" ;;
        warning) priority="high" ;;
        error) priority="high" ;;
        critical) priority="urgent" ;;
        *) priority="default" ;;
    esac

    # ntfy uses headers, not JSON body for simple messages
    # Return special format that send_webhook will parse
    echo "NTFY:${priority}:${title}:${message}"
}

# Format message for Pushover
format_pushover() {
    local level="$1"
    local title="$2"
    local message="$3"
    local alert_type="$4"

    # Map level to pushover priority (-2 to 2)
    local priority
    case "$level" in
        info) priority="-1" ;;
        warning) priority="0" ;;
        error) priority="1" ;;
        critical) priority="2" ;;
        *) priority="0" ;;
    esac

    # Properly URL-encode message and title (handles &, =, and all special chars)
    local encoded_message encoded_title
    encoded_message=$(url_encode "$message")
    encoded_title=$(url_encode "$title")

    # Return form-encoded data
    echo "token=${LYREBIRD_PUSHOVER_TOKEN}&user=${LYREBIRD_PUSHOVER_USER}&title=${encoded_title}&message=${encoded_message}&priority=${priority}"
}

#=============================================================================
# Webhook Sender
#=============================================================================

# Send webhook with retries
send_webhook() {
    local webhook_url="$1"
    local webhook_type="$2"
    local payload="$3"
    local retries="${LYREBIRD_ALERT_RETRIES}"
    local timeout="${LYREBIRD_ALERT_TIMEOUT}"
    local attempt=0

    while ((attempt < retries)); do
        ((attempt++))
        log_debug "Sending webhook (attempt ${attempt}/${retries}): ${webhook_url}"

        local http_code
        local curl_args=(-s -w '%{http_code}' -o /dev/null --connect-timeout "$timeout" --max-time "$((timeout * 2))")

        case "$webhook_type" in
            ntfy)
                # Parse ntfy format: NTFY:priority:title:message
                if [[ "$payload" =~ ^NTFY:([^:]+):([^:]+):(.+)$ ]]; then
                    local priority="${BASH_REMATCH[1]}"
                    local title="${BASH_REMATCH[2]}"
                    local message="${BASH_REMATCH[3]}"
                    local ntfy_url="${LYREBIRD_NTFY_SERVER}/${LYREBIRD_NTFY_TOPIC}"

                    http_code=$(curl "${curl_args[@]}" \
                        -H "Title: ${title}" \
                        -H "Priority: ${priority}" \
                        -H "Tags: lyrebird" \
                        -d "${message}" \
                        "$ntfy_url" 2>/dev/null) || http_code="000"
                else
                    log_error "Invalid ntfy payload format"
                    return 1
                fi
                ;;
            pushover)
                http_code=$(curl "${curl_args[@]}" \
                    -X POST \
                    -d "$payload" \
                    "https://api.pushover.net/1/messages.json" 2>/dev/null) || http_code="000"
                ;;
            *)
                # Generic, Discord, Slack all use JSON POST
                http_code=$(curl "${curl_args[@]}" \
                    -X POST \
                    -H "Content-Type: application/json" \
                    -d "$payload" \
                    "$webhook_url" 2>/dev/null) || http_code="000"
                ;;
        esac

        log_debug "Webhook response code: $http_code"

        # Check for success (2xx)
        if [[ "$http_code" =~ ^2[0-9][0-9]$ ]]; then
            log_debug "Webhook sent successfully"
            return 0
        fi

        # Retry with backoff and jitter (prevents thundering herd)
        if ((attempt < retries)); then
            local delay=$(( (attempt * 2) + (RANDOM % 3) ))
            log_debug "Webhook failed, retrying in ${delay}s..."
            sleep "$delay"
        fi
    done

    log_error "Webhook delivery failed after ${retries} attempts"
    return 1
}

#=============================================================================
# Main Alert Function
#=============================================================================

# Send an alert
# Usage: send_alert <level> <title> <message> [alert_type]
send_alert() {
    local level="${1:-info}"
    local title="${2:-LyreBirdAudio Alert}"
    local message="${3:-No message provided}"
    local alert_type="${4:-custom}"

    # Validate level
    case "$level" in
        info|warning|error|critical) ;;
        *) level="info" ;;
    esac

    # Check if alerts are enabled
    if [[ "${LYREBIRD_ALERT_ENABLED}" != "true" ]]; then
        log_debug "Alerts disabled, skipping: ${title}"
        return 0
    fi

    # Check if webhook URL is configured
    if [[ -z "${LYREBIRD_WEBHOOK_URL}" ]] && [[ -z "${LYREBIRD_WEBHOOK_URLS}" ]]; then
        log_debug "No webhook URL configured, skipping alert"
        return 0
    fi

    # Generate deduplication hash
    local alert_hash
    alert_hash=$(generate_alert_hash "$alert_type" "$message")

    # Check rate limiting
    if is_rate_limited "$alert_hash"; then
        log_debug "Alert rate limited: ${alert_type}"
        log_alert "$level" "[RATE LIMITED] ${message}"
        return 4
    fi

    # Log the alert
    log_alert "$level" "${message}"

    # Build list of webhooks to send to
    local webhooks=()
    if [[ -n "${LYREBIRD_WEBHOOK_URL}" ]]; then
        webhooks+=("${LYREBIRD_WEBHOOK_URL}:${LYREBIRD_WEBHOOK_TYPE}")
    fi

    # Add additional webhooks
    if [[ -n "${LYREBIRD_WEBHOOK_URLS}" ]]; then
        for url in ${LYREBIRD_WEBHOOK_URLS}; do
            webhooks+=("${url}:generic")
        done
    fi

    # Send to all configured webhooks
    local any_success=false
    for webhook_spec in "${webhooks[@]}"; do
        local url="${webhook_spec%:*}"
        local type="${webhook_spec##*:}"

        # Format payload based on webhook type
        local payload
        case "$type" in
            discord)
                payload=$(format_discord "$level" "$title" "$message" "$alert_type")
                ;;
            slack)
                payload=$(format_slack "$level" "$title" "$message" "$alert_type")
                ;;
            ntfy)
                payload=$(format_ntfy "$level" "$title" "$message" "$alert_type")
                ;;
            pushover)
                payload=$(format_pushover "$level" "$title" "$message" "$alert_type")
                ;;
            *)
                payload=$(format_generic "$level" "$title" "$message" "$alert_type")
                ;;
        esac

        if send_webhook "$url" "$type" "$payload"; then
            any_success=true
        fi
    done

    if $any_success; then
        # Update rate limit only on success
        update_rate_limit "$alert_hash"
        return 0
    else
        return 3
    fi
}

#=============================================================================
# Convenience Functions for Common Alerts
#=============================================================================

# Stream went down
alert_stream_down() {
    local stream_name="${1:-unknown}"
    local reason="${2:-Stream stopped unexpectedly}"

    send_alert "error" "Stream Down: ${stream_name}" \
        "Stream '${stream_name}' is no longer active. ${reason}" \
        "$ALERT_TYPE_STREAM_DOWN"
}

# Stream came back up
alert_stream_up() {
    local stream_name="${1:-unknown}"

    send_alert "info" "Stream Recovered: ${stream_name}" \
        "Stream '${stream_name}' is now active." \
        "$ALERT_TYPE_STREAM_UP"
}

# Device disconnected
alert_device_disconnect() {
    local device_name="${1:-unknown}"

    send_alert "warning" "Device Disconnected: ${device_name}" \
        "USB audio device '${device_name}' has been disconnected." \
        "$ALERT_TYPE_DEVICE_DISCONNECT"
}

# Device connected
alert_device_connect() {
    local device_name="${1:-unknown}"

    send_alert "info" "Device Connected: ${device_name}" \
        "USB audio device '${device_name}' has been connected." \
        "$ALERT_TYPE_DEVICE_CONNECT"
}

# Disk space warning
alert_disk_warning() {
    local usage_percent="${1:-unknown}"
    local mount_point="${2:-/}"

    send_alert "warning" "Disk Space Warning" \
        "Disk usage at ${usage_percent}% on ${mount_point}. Consider cleanup." \
        "$ALERT_TYPE_DISK_WARNING"
}

# Disk space critical
alert_disk_critical() {
    local usage_percent="${1:-unknown}"
    local mount_point="${2:-/}"

    send_alert "critical" "Disk Space Critical" \
        "Disk usage at ${usage_percent}% on ${mount_point}! Immediate action required." \
        "$ALERT_TYPE_DISK_CRITICAL"
}

# MediaMTX service down
alert_mediamtx_down() {
    local reason="${1:-Service not responding}"

    send_alert "critical" "MediaMTX Down" \
        "MediaMTX server is not running. ${reason}" \
        "$ALERT_TYPE_MEDIAMTX_DOWN"
}

# MediaMTX service recovered
alert_mediamtx_up() {
    send_alert "info" "MediaMTX Recovered" \
        "MediaMTX server is now running." \
        "$ALERT_TYPE_MEDIAMTX_UP"
}

# Network connectivity lost
alert_network_down() {
    local interface="${1:-unknown}"

    send_alert "critical" "Network Down" \
        "Network connectivity lost on interface '${interface}'." \
        "$ALERT_TYPE_NETWORK_DOWN"
}

# Network connectivity restored
alert_network_up() {
    local interface="${1:-unknown}"

    send_alert "info" "Network Restored" \
        "Network connectivity restored on interface '${interface}'." \
        "$ALERT_TYPE_NETWORK_UP"
}

# Memory warning
alert_memory_warning() {
    local usage_percent="${1:-unknown}"

    send_alert "warning" "Memory Warning" \
        "Memory usage at ${usage_percent}%. Performance may be affected." \
        "$ALERT_TYPE_MEMORY_WARNING"
}

# CPU warning
alert_cpu_warning() {
    local load="${1:-unknown}"

    send_alert "warning" "High CPU Load" \
        "CPU load average: ${load}. System may be under stress." \
        "$ALERT_TYPE_CPU_WARNING"
}

#=============================================================================
# Command Line Interface
#=============================================================================

show_help() {
    cat <<EOF
${SCRIPT_NAME} v${SCRIPT_VERSION} - Webhook Alerting System

USAGE:
    ${SCRIPT_NAME}.sh <command> [options]

COMMANDS:
    test                Send a test alert to verify configuration
    send                Send a custom alert
    status              Show alerting system status
    config              Show current configuration
    setup               Interactive configuration setup
    help                Show this help message

SEND OPTIONS:
    --level <level>     Alert level: info, warning, error, critical
    --title <title>     Alert title
    --message <msg>     Alert message
    --type <type>       Alert type for deduplication

EXAMPLES:
    # Send test alert
    ${SCRIPT_NAME}.sh test

    # Send custom warning
    ${SCRIPT_NAME}.sh send --level warning --title "Custom Alert" --message "Something happened"

    # Check status
    ${SCRIPT_NAME}.sh status

CONFIGURATION:
    Config file: ${ALERT_CONFIG_FILE}

    Required environment variables:
      LYREBIRD_ALERT_ENABLED=true
      LYREBIRD_WEBHOOK_URL=<your-webhook-url>
      LYREBIRD_WEBHOOK_TYPE=generic|discord|slack|ntfy|pushover

    Optional:
      LYREBIRD_ALERT_RATE_LIMIT=300  (seconds between duplicate alerts)
      LYREBIRD_HOSTNAME=<hostname>   (identifier in alerts)
      LYREBIRD_LOCATION=<location>   (physical location description)

For more information, see: https://github.com/tomtom215/LyreBirdAudio
EOF
}

show_status() {
    echo "LyreBird Alerts Status"
    echo "======================"
    echo ""
    echo "Configuration:"
    echo "  Enabled:     ${LYREBIRD_ALERT_ENABLED}"
    echo "  Config file: ${ALERT_CONFIG_FILE}"
    echo "  State dir:   ${ALERT_STATE_DIR}"
    echo "  Log file:    ${ALERT_LOG_FILE}"
    echo ""
    echo "Webhook:"
    if [[ -n "${LYREBIRD_WEBHOOK_URL}" ]]; then
        # Mask the URL for security
        local masked_url
        masked_url="${LYREBIRD_WEBHOOK_URL:0:30}..."
        echo "  URL:  ${masked_url}"
        echo "  Type: ${LYREBIRD_WEBHOOK_TYPE}"
    else
        echo "  URL:  (not configured)"
    fi
    echo ""
    echo "Settings:"
    echo "  Rate limit:    ${LYREBIRD_ALERT_RATE_LIMIT}s"
    echo "  Dedup window:  ${LYREBIRD_ALERT_DEDUP_WINDOW}s"
    echo "  Timeout:       ${LYREBIRD_ALERT_TIMEOUT}s"
    echo "  Retries:       ${LYREBIRD_ALERT_RETRIES}"
    echo "  Hostname:      ${LYREBIRD_HOSTNAME}"
    echo "  Location:      ${LYREBIRD_LOCATION:-'(not set)'}"
    echo ""

    # Show recent alerts from log
    if [[ -f "$ALERT_LOG_FILE" ]]; then
        echo "Recent alerts (last 5):"
        tail -5 "$ALERT_LOG_FILE" 2>/dev/null | sed 's/^/  /'
    else
        echo "No alert log found."
    fi
}

show_config() {
    echo "# LyreBird Alerts Configuration"
    echo "# Save this to: ${ALERT_CONFIG_FILE}"
    echo ""
    echo "# Enable/disable alerting"
    echo "LYREBIRD_ALERT_ENABLED=${LYREBIRD_ALERT_ENABLED}"
    echo ""
    echo "# Webhook configuration"
    echo "# Supported types: generic, discord, slack, ntfy, pushover"
    echo "LYREBIRD_WEBHOOK_URL=\"${LYREBIRD_WEBHOOK_URL}\""
    echo "LYREBIRD_WEBHOOK_TYPE=\"${LYREBIRD_WEBHOOK_TYPE}\""
    echo ""
    echo "# Rate limiting (seconds between duplicate alerts)"
    echo "LYREBIRD_ALERT_RATE_LIMIT=${LYREBIRD_ALERT_RATE_LIMIT}"
    echo ""
    echo "# Alert deduplication window (seconds)"
    echo "LYREBIRD_ALERT_DEDUP_WINDOW=${LYREBIRD_ALERT_DEDUP_WINDOW}"
    echo ""
    echo "# Device identification"
    echo "LYREBIRD_HOSTNAME=\"${LYREBIRD_HOSTNAME}\""
    echo "LYREBIRD_LOCATION=\"${LYREBIRD_LOCATION}\""
    echo ""
    echo "# ntfy.sh settings (if using ntfy)"
    echo "LYREBIRD_NTFY_SERVER=\"${LYREBIRD_NTFY_SERVER}\""
    echo "LYREBIRD_NTFY_TOPIC=\"${LYREBIRD_NTFY_TOPIC}\""
    echo ""
    echo "# Pushover settings (if using pushover)"
    echo "LYREBIRD_PUSHOVER_TOKEN=\"\""
    echo "LYREBIRD_PUSHOVER_USER=\"\""
}

interactive_setup() {
    echo "LyreBird Alerts - Interactive Setup"
    echo "===================================="
    echo ""

    # Check if we can write config
    local config_dir
    config_dir="$(dirname "$ALERT_CONFIG_FILE")"
    if [[ ! -d "$config_dir" ]]; then
        echo "Creating config directory: $config_dir"
        if ! sudo mkdir -p "$config_dir" 2>/dev/null; then
            echo "Error: Cannot create config directory. Run with sudo."
            return 1
        fi
    fi

    echo "Choose your webhook provider:"
    echo "  1) Discord"
    echo "  2) Slack"
    echo "  3) ntfy.sh (free, open source)"
    echo "  4) Pushover"
    echo "  5) Generic HTTP webhook"
    echo ""
    read -rp "Selection [1-5]: " provider_choice

    local webhook_type
    case "$provider_choice" in
        1) webhook_type="discord" ;;
        2) webhook_type="slack" ;;
        3) webhook_type="ntfy" ;;
        4) webhook_type="pushover" ;;
        *) webhook_type="generic" ;;
    esac

    local webhook_url=""
    if [[ "$webhook_type" != "ntfy" ]] && [[ "$webhook_type" != "pushover" ]]; then
        echo ""
        read -rp "Enter webhook URL: " webhook_url
    fi

    local ntfy_topic=""
    local ntfy_server=""
    if [[ "$webhook_type" == "ntfy" ]]; then
        echo ""
        read -rp "Enter ntfy server [https://ntfy.sh]: " ntfy_server
        ntfy_server="${ntfy_server:-https://ntfy.sh}"
        read -rp "Enter ntfy topic: " ntfy_topic
    fi

    local pushover_token=""
    local pushover_user=""
    if [[ "$webhook_type" == "pushover" ]]; then
        echo ""
        read -rp "Enter Pushover API token: " pushover_token
        read -rp "Enter Pushover user key: " pushover_user
    fi

    echo ""
    read -rp "Device hostname [${LYREBIRD_HOSTNAME}]: " hostname
    hostname="${hostname:-$LYREBIRD_HOSTNAME}"

    read -rp "Physical location (optional): " location

    echo ""
    echo "Creating configuration..."

    # Write config file
    cat > /tmp/lyrebird-alerts.conf <<EOF
# LyreBird Alerts Configuration
# Generated by setup wizard

LYREBIRD_ALERT_ENABLED=true
LYREBIRD_WEBHOOK_URL="${webhook_url}"
LYREBIRD_WEBHOOK_TYPE="${webhook_type}"
LYREBIRD_ALERT_RATE_LIMIT=300
LYREBIRD_HOSTNAME="${hostname}"
LYREBIRD_LOCATION="${location}"
LYREBIRD_NTFY_SERVER="${ntfy_server}"
LYREBIRD_NTFY_TOPIC="${ntfy_topic}"
LYREBIRD_PUSHOVER_TOKEN="${pushover_token}"
LYREBIRD_PUSHOVER_USER="${pushover_user}"
EOF

    if sudo mv /tmp/lyrebird-alerts.conf "$ALERT_CONFIG_FILE" 2>/dev/null; then
        sudo chmod 600 "$ALERT_CONFIG_FILE"
        echo "Configuration saved to: $ALERT_CONFIG_FILE"
        echo ""
        echo "Testing configuration..."

        # Reload config
        load_config
        LYREBIRD_ALERT_ENABLED=true

        # Send test
        if send_alert "info" "LyreBird Alerts Configured" \
            "Alerts are now configured for ${hostname}." \
            "$ALERT_TYPE_TEST"; then
            echo "Test alert sent successfully!"
        else
            echo "Warning: Test alert may have failed. Check your webhook configuration."
        fi
    else
        echo "Error: Could not save configuration. Try running with sudo."
        return 1
    fi
}

cmd_send() {
    local level="info"
    local title="LyreBirdAudio Alert"
    local message=""
    local alert_type="custom"

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --level)
                level="$2"
                shift 2
                ;;
            --title)
                title="$2"
                shift 2
                ;;
            --message)
                message="$2"
                shift 2
                ;;
            --type)
                alert_type="$2"
                shift 2
                ;;
            *)
                shift
                ;;
        esac
    done

    if [[ -z "$message" ]]; then
        echo "Error: --message is required"
        return 1
    fi

    send_alert "$level" "$title" "$message" "$alert_type"
}

cmd_test() {
    echo "Sending test alert..."

    # Temporarily enable if disabled
    local was_enabled="${LYREBIRD_ALERT_ENABLED}"
    LYREBIRD_ALERT_ENABLED="true"

    if send_alert "info" "Test Alert from LyreBirdAudio" \
        "This is a test alert from ${LYREBIRD_HOSTNAME}. If you received this, alerts are working!" \
        "$ALERT_TYPE_TEST"; then
        echo "Test alert sent successfully!"
        return 0
    else
        echo "Failed to send test alert. Check your configuration."
        return 1
    fi
    # Note: was_enabled restoration removed - unreachable after return statements
}

#=============================================================================
# Main Entry Point
#=============================================================================

main() {
    # Load configuration
    load_config

    # Parse command
    local command="${1:-help}"
    shift || true

    case "$command" in
        test)
            cmd_test
            ;;
        send)
            cmd_send "$@"
            ;;
        status)
            show_status
            ;;
        config)
            show_config
            ;;
        setup)
            interactive_setup
            ;;
        help|--help|-h)
            show_help
            ;;
        *)
            echo "Unknown command: $command"
            echo "Run '${SCRIPT_NAME}.sh help' for usage."
            return 1
            ;;
    esac
}

# Run if not being sourced
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi
