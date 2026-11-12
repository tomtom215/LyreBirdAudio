#!/bin/bash
# lyrebird-alerts.sh - Webhook Alerting System for LyreBirdAudio
# Part of LyreBirdAudio - RTSP Audio Streaming Suite
# https://github.com/tomtom215/LyreBirdAudio
#
# Author: Tom F (https://github.com/tomtom215)
# Copyright: Tom F and LyreBirdAudio contributors
# License: Apache 2.0
#
# Version: 1.1.0
#
# DESCRIPTION:
#   Pure-bash webhook alerting system for remote monitoring of LyreBirdAudio
#   deployments. Sends HTTP POST notifications when streams fail, devices
#   disconnect, or resource thresholds are exceeded.
#
# FEATURES:
#   - Webhook alerts (Discord, Slack, ntfy, generic HTTP POST)
#   - Per-destination delivery de-duplication: an identical alert (same type
#     and message) is not sent again to a destination that has already
#     confirmed it within LYREBIRD_ALERT_RATE_LIMIT seconds
#   - Multiple webhook destinations, each tracked and retried independently
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
#   LYREBIRD_ALERT_DEDUP_WINDOW=3600 # How long delivery state is kept (the
#                                    # larger of this and RATE_LIMIT applies)
#   LYREBIRD_ALERT_ENABLED=true
#
# SUPPORTED WEBHOOK TYPES:
#   - generic:  Simple HTTP POST with JSON body
#   - discord:  Discord webhook format
#   - slack:    Slack webhook format
#   - ntfy:     ntfy.sh notification service
#   - pushover: Pushover notification service
#
# EXIT CODES (send_alert return status and `send` exit status):
#   0 - Delivered: every destination that needed the alert received it
#       (destinations that already had it within the window are not re-sent)
#   1 - General error
#   2 - Configuration error
#   3 - Total failure: no destination holds the alert, at least one failed
#   4 - Suppressed (not an error): every destination already has this alert
#       within the rate-limit window, or another sender is delivering it now
#   5 - Partial failure: at least one destination has the alert and at least
#       one failed; the next identical alert retries only the failed ones

set -euo pipefail

#=============================================================================
# Script Metadata
#=============================================================================

readonly SCRIPT_NAME="lyrebird-alerts"
readonly SCRIPT_VERSION="1.1.0"
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

# Delivery stamps are replaced atomically. If the common library is missing, or is an
# older copy without lyrebird_atomic_write, use the same-directory temp file + rename
# part of it (no fsync) so a reader still never sees a half-written stamp.
if ! declare -F lyrebird_atomic_write >/dev/null 2>&1; then
    lyrebird_atomic_write() {
        local dest="${1:?lyrebird_atomic_write: destination required}"
        local mode="${2:-0644}"
        local tmp
        tmp="$(mktemp "$(dirname -- "$dest")/.$(basename -- "$dest").XXXXXX")" || return 1
        if ! cat >"$tmp" || ! chmod "$mode" -- "$tmp" || ! mv -f -- "$tmp" "$dest"; then
            rm -f -- "$tmp"
            return 1
        fi
    }
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
LYREBIRD_ALERT_RATE_LIMIT="${LYREBIRD_ALERT_RATE_LIMIT:-300}"      # 5 minutes default
LYREBIRD_ALERT_DEDUP_WINDOW="${LYREBIRD_ALERT_DEDUP_WINDOW:-3600}" # 1 hour
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

# Alert level constants - SC2034: These are exported for use by sourcing scripts
# shellcheck disable=SC2034
readonly ALERT_LEVEL_INFO="info"
# shellcheck disable=SC2034
readonly ALERT_LEVEL_WARNING="warning"
# shellcheck disable=SC2034
readonly ALERT_LEVEL_ERROR="error"
# shellcheck disable=SC2034
readonly ALERT_LEVEL_CRITICAL="critical"

# Colors for each level (for Discord/Slack)
declare -gA ALERT_COLORS=(
    [info]=3447003      # Blue
    [warning]=16776960  # Yellow
    [error]=15158332    # Orange
    [critical]=15548997 # Red
)

# Text prefixes for each alert level
declare -gA ALERT_PREFIX=(
    [info]="[INFO]"
    [warning]="[WARN]"
    [error]="[ERROR]"
    [critical]="[CRITICAL]"
)

# send_alert return statuses (see EXIT CODES in the header). Callers that source this
# script can compare against these instead of the literal numbers.
readonly ALERT_RC_DELIVERED=0
readonly ALERT_RC_FAILED=3
readonly ALERT_RC_SUPPRESSED=4
readonly ALERT_RC_PARTIAL=5

# Get alert prefix for level
get_alert_prefix() {
    local level="$1"
    echo "${ALERT_PREFIX[$level]:-[INFO]}"
}

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

# Mask sensitive URLs for safe debug output (shows first 30 chars + ***)
mask_url() {
    local url="$1"
    local visible_len=30
    if [[ ${#url} -gt $visible_len ]]; then
        echo "${url:0:$visible_len}***"
    else
        echo "$url"
    fi
}

# Load configuration file if it exists
# Uses safe key=value parsing instead of source to prevent code injection
load_config() {
    if [[ -f "$ALERT_CONFIG_FILE" ]]; then
        log_debug "Loading configuration from $ALERT_CONFIG_FILE"
        local key value
        while IFS='=' read -r key value; do
            # Skip comments and empty lines
            [[ -z "$key" || "$key" =~ ^[[:space:]]*# ]] && continue
            # Strip whitespace from key
            key="${key#"${key%%[![:space:]]*}"}"
            key="${key%"${key##*[![:space:]]}"}"
            # Only accept known LYREBIRD_ variable names
            if [[ "$key" =~ ^LYREBIRD_[A-Z_]+$ ]]; then
                # Strip surrounding quotes from value
                value="${value#\"}"
                value="${value%\"}"
                value="${value#\'}"
                value="${value%\'}"
                # Export the variable
                declare -g "$key=$value"
            fi
        done <"$ALERT_CONFIG_FILE"
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
    echo "[$timestamp] [$level] $message" >>"$ALERT_LOG_FILE" 2>/dev/null || true
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

#=============================================================================
# Delivery State (rate limit, de-duplication and claims)
#=============================================================================
#
# State is kept per (alert, destination). An alert is identified by a hash of its
# type and message (generate_alert_hash), a destination by a hash of its type,
# endpoint and credentials (generate_destination_id): no URL or token is ever
# written to disk. Files in LYREBIRD_ALERT_STATE_DIR:
#
#   <alert>.<destination>.last   epoch second at which THAT destination confirmed
#                                delivery (HTTP 2xx). Replaced atomically and only
#                                after the confirmation, so a destination that failed
#                                has no stamp and the next identical alert retries it,
#                                while destinations that succeeded are not re-sent.
#   <alert>.<destination>.lock   claim lock. A sender holds an flock on it from before
#                                the first request until it has recorded the result, so
#                                concurrent identical alerts send once per destination.
#                                The kernel drops the lock when the holder dies; there
#                                is no staleness heuristic. Never written, only locked.
#   .claim.guard                 held for microseconds while a claim file is opened and
#                                locked, and by cleanup_state while it removes unheld
#                                claim files, so that removal cannot split a lock across
#                                two inodes. Never held while sending.

readonly ALERT_GUARD_WAIT=5
# FD of the claim currently held by this process (empty when none).
_ALERT_CLAIM_FD=""
_ALERT_GUARD_FD=""

# Print VALUE as a plain unsigned integer, or DEFAULT when it is not one.
_alert_uint() {
    local value="$1" default="$2"
    if [[ "$value" =~ ^[0-9]{1,9}$ ]]; then
        printf '%s' "$((10#$value))"
    else
        printf '%s' "$default"
    fi
}

# Identify a destination without exposing it: a short hash of its type, endpoint and,
# for Pushover, the token and user key.
# Usage: generate_destination_id <type> <endpoint> [<secret>]
generate_destination_id() {
    local type="$1" endpoint="$2" secret="${3:-}"
    generate_alert_hash "destination" "${type}|${endpoint}|${secret}"
}

# Path of the stamp file for an (alert, destination) pair.
alert_stamp_file() {
    printf '%s/%s.%s.last' "$ALERT_STATE_DIR" "$1" "$2"
}

# Print the epoch second recorded in a stamp file. Fails, printing nothing, when the file
# is absent, unreadable, empty, torn or holds anything but a plain number.
read_delivery_stamp() {
    local file="$1" value=""
    [[ -f "$file" ]] || return 1
    { IFS= read -r value || true; } 2>/dev/null <"$file" || return 1
    [[ "$value" =~ ^[0-9]{1,12}$ ]] || return 1
    printf '%s' "$((10#$value))"
}

# Is <destination> still inside the rate-limit window for <alert>?
# Returns 0 (rate limited) when that destination confirmed delivery of this alert less
# than LYREBIRD_ALERT_RATE_LIMIT seconds ago; 1 when the alert may be sent: no stamp, an
# expired one, or one that cannot be trusted (empty, torn, not a number, dated in the
# future). A duplicate alert is better than a lost one.
# Usage: is_rate_limited <alert_hash> <destination_id>
is_rate_limited() {
    local alert_hash="$1" dest_id="$2"
    local rate_limit last_sent now elapsed

    rate_limit="$(_alert_uint "${LYREBIRD_ALERT_RATE_LIMIT}" 300)"

    ensure_state_dir || return 1 # Not rate limited if we can't check
    last_sent="$(read_delivery_stamp "$(alert_stamp_file "$alert_hash" "$dest_id")")" || return 1

    now="$(date +%s)"
    elapsed=$((now - last_sent))
    if ((elapsed < 0)); then
        log_debug "Ignoring a delivery stamp dated in the future"
        return 1
    fi
    if ((elapsed < rate_limit)); then
        log_debug "Alert rate limited: ${elapsed}s since last (limit: ${rate_limit}s)"
        return 0 # Rate limited
    fi

    return 1 # Not rate limited
}

# Record that <destination> confirmed delivery of <alert> now. Atomic: a concurrent
# reader or a crash sees the old stamp or the new one, never a partial file.
# Usage: update_rate_limit <alert_hash> <destination_id>
update_rate_limit() {
    local alert_hash="$1" dest_id="$2"

    ensure_state_dir || return 1
    date +%s | lyrebird_atomic_write "$(alert_stamp_file "$alert_hash" "$dest_id")"
}

# Take the claim guard; its FD number is left in _ALERT_GUARD_FD.
_alert_guard_acquire() {
    _ALERT_GUARD_FD=""
    { exec {_ALERT_GUARD_FD}>>"${ALERT_STATE_DIR}/.claim.guard"; } 2>/dev/null || return 1
    if ! flock -w "$ALERT_GUARD_WAIT" "$_ALERT_GUARD_FD" 2>/dev/null; then
        exec {_ALERT_GUARD_FD}>&-
        return 1
    fi
}

_alert_guard_release() {
    exec {_ALERT_GUARD_FD}>&-
    _ALERT_GUARD_FD=""
}

# Claim <destination> for <alert> before sending to it.
# Returns 0 when claimed (the lock FD stays open in _ALERT_CLAIM_FD until alert_release),
# 1 when another process holds the claim (it is delivering this alert right now), and 2
# when claiming is impossible (state directory unusable, flock missing or failing); the
# caller then sends without the claim: a duplicate alert is better than a lost one.
# Usage: alert_claim <alert_hash> <destination_id>
alert_claim() {
    local alert_hash="$1" dest_id="$2"
    local lock_fd="" rc=0
    _ALERT_CLAIM_FD=""

    ensure_state_dir || return 2
    _alert_guard_acquire || return 2

    if { exec {lock_fd}>>"${ALERT_STATE_DIR}/${alert_hash}.${dest_id}.lock"; } 2>/dev/null; then
        # 200 = somebody else holds it; anything else non-zero is a flock failure.
        flock -n -E 200 "$lock_fd" 2>/dev/null || rc=$?
    else
        rc=70
    fi
    _alert_guard_release

    case "$rc" in
        0)
            _ALERT_CLAIM_FD="$lock_fd"
            return 0
            ;;
        200)
            exec {lock_fd}>&-
            return 1
            ;;
        *)
            if [[ -n "$lock_fd" ]]; then
                exec {lock_fd}>&-
            fi
            return 2
            ;;
    esac
}

# Drop the claim taken by alert_claim (a no-op when none is held).
alert_release() {
    if [[ -n "${_ALERT_CLAIM_FD:-}" ]]; then
        exec {_ALERT_CLAIM_FD}>&-
        _ALERT_CLAIM_FD=""
    fi
}

# Close the claim FD in the CURRENT process. Called first thing inside every subshell
# that runs a long-lived command (curl, sleep): neither the subshell nor the command may
# keep the claim alive after the sender itself has died. The sender's own copy stays open.
_alert_drop_claim() {
    if [[ -n "${_ALERT_CLAIM_FD:-}" ]]; then
        exec {_ALERT_CLAIM_FD}>&-
    fi
}

# Remove claim files older than MINUTES that nobody holds. Taken under the claim guard,
# so a claimant cannot open a file between the lock test and the unlink.
_alert_reap_locks() {
    local minutes="$1" lock fd
    _alert_guard_acquire || return 0
    while IFS= read -r -d '' lock; do
        fd=""
        if { exec {fd}<"$lock"; } 2>/dev/null; then
            if flock -n "$fd" 2>/dev/null; then
                rm -f -- "$lock"
            fi
            exec {fd}>&-
        fi
    done < <(find "$ALERT_STATE_DIR" -maxdepth 1 -name '*.lock' -mmin "+${minutes}" -print0 2>/dev/null)
    _alert_guard_release
}

# Clean old state files.
# State is what enforces the rate limit, so it must outlive LYREBIRD_ALERT_RATE_LIMIT:
# the retention is the larger of that and LYREBIRD_ALERT_DEDUP_WINDOW, rounded UP to
# whole minutes (find -mmin compares in minutes, and rounding down would delete a stamp
# before its rate-limit window has elapsed). Besides stamps this removes the ".<stamp>.XXXXXX"
# temp file a killed writer can leave behind and claim files nobody holds.
cleanup_state() {
    local dedup_window rate_limit retain minutes
    dedup_window="$(_alert_uint "${LYREBIRD_ALERT_DEDUP_WINDOW}" 3600)"
    rate_limit="$(_alert_uint "${LYREBIRD_ALERT_RATE_LIMIT}" 300)"
    retain=$((dedup_window > rate_limit ? dedup_window : rate_limit))
    minutes=$(((retain + 59) / 60))

    ensure_state_dir || return 0

    find "$ALERT_STATE_DIR" -maxdepth 1 \( -name '*.last' -o -name '.*.last.??????' \) \
        -mmin "+${minutes}" -delete 2>/dev/null || true
    _alert_reap_locks "$minutes"
}

#=============================================================================
# Webhook Formatters
#=============================================================================

# Escape a string for safe JSON embedding
json_escape() {
    local s="$1"
    s="${s//\\/\\\\}" # backslash first, or later escapes double-escape
    s="${s//\"/\\\"}"
    s="${s//$'\n'/\\n}"
    s="${s//$'\r'/\\r}"
    s="${s//$'\t'/\\t}"
    s="${s//$'\b'/\\b}"
    s="${s//$'\f'/\\f}"
    # Escape any remaining control characters (U+0001..U+001F -- e.g. ESC 0x1B
    # from ANSI/ffmpeg output pasted into a reason) as \u00XX per RFC 8259.
    # Without this, a control byte yields invalid JSON and the webhook (Discord/
    # Slack) rejects it with HTTP 400, silently dropping the alert.
    if [[ "$s" == *[$'\x01'-$'\x1f']* ]]; then
        local i c cc out=""
        for ((i = 0; i < ${#s}; i++)); do
            c="${s:i:1}"
            if [[ "$c" == [$'\x01'-$'\x1f'] ]]; then
                printf -v cc '\\u%04x' "'$c"
                out+="$cc"
            else
                out+="$c"
            fi
        done
        s="$out"
    fi
    printf '%s' "$s"
}

# Format message for generic webhook (simple JSON)
format_generic() {
    local level="$1"
    local title="$2"
    local message="$3"
    local alert_type="$4"
    local timestamp
    timestamp="$(date -u '+%Y-%m-%dT%H:%M:%SZ')"

    # Escape all values for safe JSON
    level="$(json_escape "$level")"
    title="$(json_escape "$title")"
    message="$(json_escape "$message")"
    alert_type="$(json_escape "$alert_type")"
    local hostname location
    hostname="$(json_escape "${LYREBIRD_HOSTNAME}")"
    location="$(json_escape "${LYREBIRD_LOCATION}")"

    cat <<EOF
{
  "level": "${level}",
  "title": "${title}",
  "message": "${message}",
  "type": "${alert_type}",
  "hostname": "${hostname}",
  "location": "${location}",
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
    local emoji
    emoji=$(get_alert_prefix "$level")
    local timestamp
    timestamp="$(date -u '+%Y-%m-%dT%H:%M:%SZ')"

    # Escape all values for safe JSON
    message="$(json_escape "$message")"
    title="$(json_escape "$title")"
    level="$(json_escape "$level")"
    alert_type="$(json_escape "$alert_type")"
    local hostname
    hostname="$(json_escape "${LYREBIRD_HOSTNAME}")"

    cat <<EOF
{
  "embeds": [{
    "title": "${emoji} ${title}",
    "description": "${message}",
    "color": ${color},
    "fields": [
      {"name": "Host", "value": "${hostname}", "inline": true},
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
    local emoji
    emoji=$(get_alert_prefix "$level")

    # Escape all values for safe JSON
    message="$(json_escape "$message")"
    title="$(json_escape "$title")"
    alert_type="$(json_escape "$alert_type")"
    local hostname
    hostname="$(json_escape "${LYREBIRD_HOSTNAME}")"

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
      {"title": "Host", "value": "${hostname}", "short": true},
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

    # ntfy uses headers, not a JSON body. Pack the fields for send_webhook, but
    # base64-encode title/message so a ":" (or newline) inside them cannot
    # collide with the ":" field delimiter. Built-in titles like
    # "Stream Down: <device>" contain ": " and were otherwise truncated to
    # "Stream Down" with the device name spilling into the message body.
    local b64_title b64_message
    b64_title=$(printf '%s' "$title" | base64 | tr -d '\n')
    b64_message=$(printf '%s' "$message" | base64 | tr -d '\n')
    echo "NTFY:${priority}:${b64_title}:${b64_message}"
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

    # Pushover REQUIRES retry+expire whenever priority=2 (Emergency); without
    # them the API returns HTTP 400 and the alert is dropped — and priority 2 is
    # exactly the critical class (MediaMTX down, disk critical) that matters most
    # on an unattended recorder. Supply sane, overridable defaults (retry>=30,
    # expire<=10800 per the Pushover contract).
    local extra=""
    if [[ "$priority" == "2" ]]; then
        local retry="${LYREBIRD_PUSHOVER_RETRY:-60}"
        local expire="${LYREBIRD_PUSHOVER_EXPIRE:-3600}"
        extra="&retry=${retry}&expire=${expire}"
    fi

    # Return form-encoded data
    echo "token=${LYREBIRD_PUSHOVER_TOKEN}&user=${LYREBIRD_PUSHOVER_USER}&title=${encoded_title}&message=${encoded_message}&priority=${priority}${extra}"
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
        ((attempt++)) || true
        log_debug "Sending webhook (attempt ${attempt}/${retries}): $(mask_url "$webhook_url")"

        local http_code
        local curl_args=(-s -w '%{http_code}' -o /dev/null --connect-timeout "$timeout" --max-time "$((timeout * 2))")

        case "$webhook_type" in
            ntfy)
                # Parse ntfy format: NTFY:priority:<b64 title>:<b64 message>.
                # base64 fields contain no ":", so the split is unambiguous.
                if [[ "$payload" =~ ^NTFY:([^:]+):([^:]*):([^:]*)$ ]]; then
                    local priority="${BASH_REMATCH[1]}"
                    local title message
                    # Strip control chars from the title: it becomes an HTTP
                    # header, so a CR/LF would inject/split the header.
                    title=$(printf '%s' "${BASH_REMATCH[2]}" | base64 -d 2>/dev/null | tr -d '\000-\037')
                    message=$(printf '%s' "${BASH_REMATCH[3]}" | base64 -d 2>/dev/null)
                    local ntfy_url="${LYREBIRD_NTFY_SERVER}/${LYREBIRD_NTFY_TOPIC}"

                    # --data-raw (not -d): a message beginning with "@" must be
                    # sent literally, not interpreted by curl as a filename.
                    http_code=$(
                        _alert_drop_claim
                        curl "${curl_args[@]}" \
                            -H "Title: ${title}" \
                            -H "Priority: ${priority}" \
                            -H "Tags: lyrebird" \
                            --data-raw "${message}" \
                            "$ntfy_url" 2>/dev/null
                    ) || http_code="000"
                else
                    log_error "Invalid ntfy payload format"
                    return 1
                fi
                ;;
            pushover)
                http_code=$(
                    _alert_drop_claim
                    curl "${curl_args[@]}" \
                        -X POST \
                        -d "$payload" \
                        "https://api.pushover.net/1/messages.json" 2>/dev/null
                ) || http_code="000"
                ;;
            *)
                # Generic, Discord, Slack all use JSON POST
                http_code=$(
                    _alert_drop_claim
                    curl "${curl_args[@]}" \
                        -X POST \
                        -H "Content-Type: application/json" \
                        -d "$payload" \
                        "$webhook_url" 2>/dev/null
                ) || http_code="000"
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
            local delay=$(((attempt * 2) + (RANDOM % 3)))
            log_debug "Webhook failed, retrying in ${delay}s..."
            (
                _alert_drop_claim
                exec sleep "$delay"
            )
        fi
    done

    log_error "Webhook delivery failed after ${retries} attempts"
    return 1
}

#=============================================================================
# Main Alert Function
#=============================================================================

# Return 0 if at least one alert destination is configured, else 1.
# Type-aware: ntfy needs a topic, Pushover needs token+user, others need a URL.
# (ntfy/Pushover build their endpoint from their own vars, not LYREBIRD_WEBHOOK_URL.)
alert_destination_configured() {
    [[ -n "${LYREBIRD_WEBHOOK_URL:-}" ]] && return 0
    [[ -n "${LYREBIRD_WEBHOOK_URLS:-}" ]] && return 0
    case "${LYREBIRD_WEBHOOK_TYPE:-generic}" in
        ntfy)
            [[ -n "${LYREBIRD_NTFY_TOPIC:-}" ]] && return 0
            ;;
        pushover)
            [[ -n "${LYREBIRD_PUSHOVER_TOKEN:-}" && -n "${LYREBIRD_PUSHOVER_USER:-}" ]] && return 0
            ;;
    esac
    return 1
}

# Send an alert
# Usage: send_alert <level> <title> <message> [alert_type]
send_alert() {
    local level="${1:-info}"
    local title="${2:-LyreBirdAudio Alert}"
    local message="${3:-No message provided}"
    local alert_type="${4:-custom}"

    # Validate level
    case "$level" in
        info | warning | error | critical) ;;
        *) level="info" ;;
    esac

    # Check if alerts are enabled
    if [[ "${LYREBIRD_ALERT_ENABLED}" != "true" ]]; then
        log_debug "Alerts disabled, skipping: ${title}"
        return 0
    fi

    # Check that at least one destination is configured (type-aware). ntfy and
    # Pushover do NOT use LYREBIRD_WEBHOOK_URL, so keying only off the URL here
    # silently dropped every ntfy/Pushover alert (and cmd_test reported success).
    if ! alert_destination_configured; then
        log_debug "No alert destination configured, skipping alert"
        return 0
    fi

    # Identify the alert (type + message). State is kept per destination, so the
    # per-destination decisions below are all keyed by this hash and a destination id.
    local alert_hash
    alert_hash=$(generate_alert_hash "$alert_type" "$message")

    # Build list of webhooks to send to. ntfy/Pushover get an entry from their own
    # config vars even when LYREBIRD_WEBHOOK_URL is empty -- send_webhook builds
    # the real endpoint for those types, so the URL field here is unused for them.
    local webhooks=() url
    case "${LYREBIRD_WEBHOOK_TYPE}" in
        ntfy)
            [[ -n "${LYREBIRD_NTFY_TOPIC}" ]] \
                && webhooks+=("${LYREBIRD_NTFY_SERVER}/${LYREBIRD_NTFY_TOPIC}:ntfy")
            ;;
        pushover)
            [[ -n "${LYREBIRD_PUSHOVER_TOKEN}" && -n "${LYREBIRD_PUSHOVER_USER}" ]] \
                && webhooks+=("pushover-api:pushover")
            ;;
        *)
            [[ -n "${LYREBIRD_WEBHOOK_URL}" ]] \
                && webhooks+=("${LYREBIRD_WEBHOOK_URL}:${LYREBIRD_WEBHOOK_TYPE}")
            ;;
    esac

    # Add additional webhooks
    if [[ -n "${LYREBIRD_WEBHOOK_URLS}" ]]; then
        for url in ${LYREBIRD_WEBHOOK_URLS}; do
            webhooks+=("${url}:generic")
        done
    fi

    if ((${#webhooks[@]} == 0)); then
        log_error "Alert not sent: no usable destination (check the webhook type and its settings)"
        return "$ALERT_RC_FAILED"
    fi

    # Deliver to every destination independently. Per destination:
    #   - skip it when it already confirmed this alert inside the rate-limit window;
    #   - claim it (flock) BEFORE sending, so identical alerts racing each other send
    #     once; a destination another process is delivering to right now is skipped;
    #   - record the delivery only after the destination confirmed it, so a failed
    #     destination is retried by the next identical alert and the others are not.
    local delivered=0 failed=0 already=0 inflight=0 logged=0
    local webhook_spec type dest_id dest_secret claim_rc payload
    for webhook_spec in "${webhooks[@]}"; do
        url="${webhook_spec%:*}"
        type="${webhook_spec##*:}"
        dest_secret=""
        if [[ "$type" == "pushover" ]]; then
            dest_secret="${LYREBIRD_PUSHOVER_TOKEN}|${LYREBIRD_PUSHOVER_USER}"
        fi
        dest_id="$(generate_destination_id "$type" "$url" "$dest_secret")"

        if is_rate_limited "$alert_hash" "$dest_id"; then
            already=$((already + 1))
            log_debug "Alert already delivered to destination ${dest_id}: ${alert_type}"
            continue
        fi

        claim_rc=0
        alert_claim "$alert_hash" "$dest_id" || claim_rc=$?
        if ((claim_rc == 1)); then
            inflight=$((inflight + 1))
            log_debug "Alert is being delivered to destination ${dest_id} by another process: ${alert_type}"
            continue
        elif ((claim_rc == 2)); then
            log_warn "Cannot claim destination ${dest_id} (state directory or flock unusable); sending without duplicate protection"
        fi

        # Another sender may have finished between the check above and the claim.
        if is_rate_limited "$alert_hash" "$dest_id"; then
            alert_release
            already=$((already + 1))
            continue
        fi

        # Log the alert (once per call, before the first request goes out)
        if ((logged == 0)); then
            log_alert "$level" "${message}"
            logged=1
        fi

        # Format payload based on webhook type
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
            delivered=$((delivered + 1))
            if ! update_rate_limit "$alert_hash" "$dest_id" 2>/dev/null; then
                log_warn "Alert delivered to destination ${dest_id} but its delivery state could not be recorded; an identical alert may be sent again"
            fi
        else
            failed=$((failed + 1))
            log_error "Alert delivery to a ${type} destination failed: $(mask_url "$url") (destination ${dest_id}); the next identical alert will retry it"
        fi
        alert_release
    done

    # Expire old state (this also removes claim files created above).
    if ((delivered + failed > 0)); then
        cleanup_state
    fi

    if ((failed == 0)); then
        if ((delivered > 0)); then
            return "$ALERT_RC_DELIVERED"
        fi
        # Nothing to send: every destination has it already or is being served by
        # another sender.
        log_alert "$level" "[RATE LIMITED] ${message}"
        return "$ALERT_RC_SUPPRESSED"
    fi

    # Surface partial failures: a working destination must not mask a broken one.
    if ((delivered > 0 || already > 0)); then
        log_warn "Alert reached ${delivered} destination(s) now and ${already} earlier, but ${failed} FAILED -- check webhook configuration"
        return "$ALERT_RC_PARTIAL"
    fi
    return "$ALERT_RC_FAILED"
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
    version             Show the version (also --version, -V)
    help                Show this help message

SEND OPTIONS:
    --level <level>     Alert level: info, warning, error, critical
    --title <title>     Alert title
    --message <msg>     Alert message
    --type <type>       Alert type for deduplication

EXIT STATUS (send, and send_alert when sourced):
    0   delivered: every destination that needed the alert received it
    3   total failure: no destination has the alert, at least one failed
    4   suppressed: every destination already has it within the rate limit
    5   partial failure: some destinations have the alert, at least one failed;
        the next identical alert retries only the failed ones

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
      LYREBIRD_ALERT_DEDUP_WINDOW=3600  (seconds delivery state is kept; the
                                         larger of this and the rate limit applies)
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

    # Write config file to secure temp location
    local tmpconf
    tmpconf="$(mktemp /tmp/lyrebird-alerts.XXXXXXXXXX.conf)" || {
        echo "ERROR: Failed to create temp file"
        return 1
    }
    chmod 600 "$tmpconf"
    cat >"$tmpconf" <<EOF
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

    if sudo mv "$tmpconf" "$ALERT_CONFIG_FILE" 2>/dev/null; then
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

    # Force enable for test (no need to save/restore - script exits after test)
    LYREBIRD_ALERT_ENABLED="true"

    # Don't claim success if nothing is configured -- send_alert would return 0
    # (skipped) and we'd falsely report the test as delivered.
    if ! alert_destination_configured; then
        echo "No alert destination is configured."
        echo "Set a webhook URL, or an ntfy topic, or a Pushover token+user"
        echo "(run '${SCRIPT_NAME}.sh setup'), then re-run the test."
        return 1
    fi

    local rc=0
    send_alert "info" "Test Alert from LyreBirdAudio" \
        "This is a test alert from ${LYREBIRD_HOSTNAME}. If you received this, alerts are working!" \
        "$ALERT_TYPE_TEST" || rc=$?

    case "$rc" in
        "$ALERT_RC_DELIVERED")
            echo "Test alert sent successfully!"
            return 0
            ;;
        "$ALERT_RC_PARTIAL")
            echo "Test alert reached only some destinations; at least one FAILED."
            echo "Check the failed destination's webhook configuration (see the log above)."
            return 1
            ;;
        *)
            echo "Failed to send test alert. Check your configuration."
            return 1
            ;;
    esac
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
        help | --help | -h)
            show_help
            ;;
        version | --version | -V)
            echo "${SCRIPT_NAME} version ${SCRIPT_VERSION}"
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
