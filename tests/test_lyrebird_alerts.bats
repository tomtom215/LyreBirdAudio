#!/usr/bin/env bats
# Unit tests for lyrebird-alerts.sh
# Run with: bats tests/test_lyrebird_alerts.bats
# Install bats: sudo apt-get install bats

# Setup - source the alerts script
load bats_shell_state

setup() {
    # Get the directory of this test file
    TEST_DIR="$( cd "$( dirname "$BATS_TEST_FILENAME" )" && pwd )"
    PROJECT_ROOT="$( cd "$TEST_DIR/.." && pwd )"

    # Create temp directory for test state
    export LYREBIRD_ALERT_STATE_DIR="$(mktemp -d)"
    export LYREBIRD_ALERT_LOG="$(mktemp)"
    export LYREBIRD_ALERT_CONFIG="$(mktemp)"

    # Disable actual webhook sending for tests
    export LYREBIRD_ALERT_ENABLED="false"
    export LYREBIRD_WEBHOOK_URL=""

    # The real sleep, for tests that replace "sleep" on PATH with a recording stub
    REAL_SLEEP="$(command -v sleep)"
    export REAL_SLEEP

    # Source the alerts script (functions only, don't run main)
    bats_save_shell_state
    source "$PROJECT_ROOT/lyrebird-alerts.sh"
    bats_restore_shell_state
}

# Teardown - clean up temp files (and any helper process a test left running)
teardown() {
    local pid
    for pid in ${BG_PIDS:-}; do
        kill "$pid" 2>/dev/null || true
    done
    rm -rf "$LYREBIRD_ALERT_STATE_DIR" 2>/dev/null || true
    rm -f "$LYREBIRD_ALERT_LOG" 2>/dev/null || true
    rm -f "$LYREBIRD_ALERT_CONFIG" 2>/dev/null || true
}

# ============================================================================
# Script Metadata Tests
# ============================================================================

@test "SCRIPT_VERSION is defined" {
    [ -n "$SCRIPT_VERSION" ]
    [[ "$SCRIPT_VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]
}

@test "SCRIPT_NAME is lyrebird-alerts" {
    [ "$SCRIPT_NAME" = "lyrebird-alerts" ]
}

# ============================================================================
# Alert Level Tests
# ============================================================================

@test "ALERT_LEVEL_INFO is defined" {
    [ "$ALERT_LEVEL_INFO" = "info" ]
}

@test "ALERT_LEVEL_WARNING is defined" {
    [ "$ALERT_LEVEL_WARNING" = "warning" ]
}

@test "ALERT_LEVEL_ERROR is defined" {
    [ "$ALERT_LEVEL_ERROR" = "error" ]
}

@test "ALERT_LEVEL_CRITICAL is defined" {
    [ "$ALERT_LEVEL_CRITICAL" = "critical" ]
}

# ============================================================================
# Alert Type Tests
# ============================================================================

@test "ALERT_TYPE_STREAM_DOWN is defined" {
    [ "$ALERT_TYPE_STREAM_DOWN" = "stream_down" ]
}

@test "ALERT_TYPE_DEVICE_DISCONNECT is defined" {
    [ "$ALERT_TYPE_DEVICE_DISCONNECT" = "device_disconnect" ]
}

@test "ALERT_TYPE_DISK_WARNING is defined" {
    [ "$ALERT_TYPE_DISK_WARNING" = "disk_warning" ]
}

@test "ALERT_TYPE_MEDIAMTX_DOWN is defined" {
    [ "$ALERT_TYPE_MEDIAMTX_DOWN" = "mediamtx_down" ]
}

# ============================================================================
# Alert Color Tests
# ============================================================================

@test "ALERT_COLORS array has info color" {
    [ -n "${ALERT_COLORS[info]}" ]
}

@test "ALERT_COLORS array has critical color" {
    [ -n "${ALERT_COLORS[critical]}" ]
}

@test "ALERT_PREFIX array has warning prefix" {
    [ "${ALERT_PREFIX[warning]}" = "[WARN]" ]
}

# The maps are declared with -g so they survive being sourced from a function
# (as bats setup() does). With plain declare -A they were local to setup(), and
# every level silently fell back to the info color and prefix.
@test "level maps survive sourcing from a function" {
    run get_alert_prefix critical
    [ "$output" = "[CRITICAL]" ]
    run format_discord "critical" "T" "M" "t"
    [[ "$output" =~ \"color\":\ *15548997 ]]
}

# ============================================================================
# Hash Generation Tests
# ============================================================================

@test "generate_alert_hash returns non-empty hash" {
    run generate_alert_hash "test_type" "test message"
    [ "$status" -eq 0 ]
    [ -n "$output" ]
}

@test "generate_alert_hash returns consistent hash for same input" {
    hash1=$(generate_alert_hash "type1" "message1")
    hash2=$(generate_alert_hash "type1" "message1")
    [ "$hash1" = "$hash2" ]
}

@test "generate_alert_hash returns different hash for different input" {
    hash1=$(generate_alert_hash "type1" "message1")
    hash2=$(generate_alert_hash "type2" "message2")
    [ "$hash1" != "$hash2" ]
}

# ============================================================================
# Rate Limiting Tests
# ============================================================================

# Delivery state is per (alert, destination) since LB-17, so these take a
# destination id as their second argument. Before, they took one hash and
# shared the stamp between all destinations.
@test "is_rate_limited returns 1 for new alert (not limited)" {
    run is_rate_limited "new_hash_12345" "dest1"
    [ "$status" -eq 1 ]
}

@test "update_rate_limit creates state file" {
    update_rate_limit "test_hash_update" "dest1"
    [ -f "${LYREBIRD_ALERT_STATE_DIR}/test_hash_update.dest1.last" ]
    # the stamp is a plain epoch second
    [[ "$(cat "${LYREBIRD_ALERT_STATE_DIR}/test_hash_update.dest1.last")" =~ ^[0-9]+$ ]]
}

@test "is_rate_limited returns 0 after update_rate_limit" {
    export LYREBIRD_ALERT_RATE_LIMIT=3600  # 1 hour
    update_rate_limit "test_hash_ratelimit" "dest1"
    run is_rate_limited "test_hash_ratelimit" "dest1"
    [ "$status" -eq 0 ]
}

# ============================================================================
# State Directory Tests
# ============================================================================

@test "ensure_state_dir creates directory if missing" {
    # ALERT_STATE_DIR is readonly, fixed from LYREBIRD_ALERT_STATE_DIR when
    # the script was sourced; remove it and check it is recreated.
    [ "$ALERT_STATE_DIR" = "$LYREBIRD_ALERT_STATE_DIR" ]
    rmdir "$ALERT_STATE_DIR"
    run ensure_state_dir
    [ "$status" -eq 0 ]
    [ -d "$ALERT_STATE_DIR" ]
}

# ============================================================================
# Formatter Tests - Generic
# ============================================================================

@test "format_generic returns valid JSON" {
    run format_generic "info" "Test Title" "Test message" "test_type"
    [ "$status" -eq 0 ]
    [[ "$output" =~ \"level\":\ *\"info\" ]]
    [[ "$output" =~ \"title\":\ *\"Test\ Title\" ]]
    [[ "$output" =~ \"message\":\ *\"Test\ message\" ]]
}

@test "format_generic includes timestamp" {
    run format_generic "warning" "Title" "Message" "type"
    [ "$status" -eq 0 ]
    [[ "$output" =~ \"timestamp\":\ *\"[0-9]{4}-[0-9]{2}-[0-9]{2}T ]]
}

@test "format_generic includes source field" {
    run format_generic "error" "Title" "Message" "type"
    [ "$status" -eq 0 ]
    [[ "$output" =~ \"source\":\ *\"lyrebird-alerts\" ]]
}

# ============================================================================
# Formatter Tests - Discord
# ============================================================================

@test "format_discord returns embeds array" {
    run format_discord "info" "Test Title" "Test message" "test_type"
    [ "$status" -eq 0 ]
    [[ "$output" =~ \"embeds\":\ *\[ ]]
}

@test "format_discord includes color field" {
    run format_discord "critical" "Alert" "Urgent" "type"
    [ "$status" -eq 0 ]
    [[ "$output" =~ \"color\":\ *[0-9]+ ]]
}

@test "format_discord includes title with emoji" {
    run format_discord "warning" "Warning Title" "Message" "type"
    [ "$status" -eq 0 ]
    # Should have emoji prefix in title
    [[ "$output" =~ \"title\":\ *\".+Warning\ Title\" ]]
}

# ============================================================================
# Formatter Tests - Slack
# ============================================================================

@test "format_slack returns attachments array" {
    run format_slack "info" "Test Title" "Test message" "test_type"
    [ "$status" -eq 0 ]
    [[ "$output" =~ \"attachments\":\ *\[ ]]
}

@test "format_slack includes color hex" {
    run format_slack "error" "Error" "Message" "type"
    [ "$status" -eq 0 ]
    [[ "$output" =~ \"color\":\ *\"#[0-9a-f]+\" ]]
}

# ============================================================================
# Formatter Tests - ntfy
# ============================================================================

@test "format_ntfy returns NTFY prefix format" {
    run format_ntfy "warning" "Title" "Message" "type"
    [ "$status" -eq 0 ]
    [[ "$output" =~ ^NTFY: ]]
}

@test "format_ntfy includes priority" {
    run format_ntfy "critical" "Urgent" "Help!" "type"
    [ "$status" -eq 0 ]
    [[ "$output" =~ NTFY:urgent: ]]
}

# ============================================================================
# Send Alert Tests (with alerts disabled)
# ============================================================================

@test "send_alert returns 0 when alerts disabled" {
    export LYREBIRD_ALERT_ENABLED="false"
    run send_alert "info" "Test" "Message"
    [ "$status" -eq 0 ]
}

@test "send_alert returns 0 when no webhook configured" {
    export LYREBIRD_ALERT_ENABLED="true"
    export LYREBIRD_WEBHOOK_URL=""
    export LYREBIRD_WEBHOOK_URLS=""
    run send_alert "info" "Test" "Message"
    [ "$status" -eq 0 ]
}

# ============================================================================
# Convenience Function Tests
# ============================================================================

@test "alert_stream_down function exists" {
    run type alert_stream_down
    [ "$status" -eq 0 ]
}

@test "alert_stream_up function exists" {
    run type alert_stream_up
    [ "$status" -eq 0 ]
}

@test "alert_device_disconnect function exists" {
    run type alert_device_disconnect
    [ "$status" -eq 0 ]
}

@test "alert_disk_warning function exists" {
    run type alert_disk_warning
    [ "$status" -eq 0 ]
}

@test "alert_disk_critical function exists" {
    run type alert_disk_critical
    [ "$status" -eq 0 ]
}

@test "alert_mediamtx_down function exists" {
    run type alert_mediamtx_down
    [ "$status" -eq 0 ]
}

@test "alert_network_down function exists" {
    run type alert_network_down
    [ "$status" -eq 0 ]
}

# ============================================================================
# Log Alert Tests
# ============================================================================

@test "log_alert writes to log file" {
    log_alert "info" "Test log message"
    [ -f "$LYREBIRD_ALERT_LOG" ]
    grep -q "Test log message" "$LYREBIRD_ALERT_LOG"
}

@test "log_alert includes level in log" {
    log_alert "warning" "Warning message"
    grep -q "\[warning\]" "$LYREBIRD_ALERT_LOG"
}

@test "log_alert includes timestamp" {
    log_alert "error" "Error message"
    # Should have timestamp format [YYYY-MM-DD HH:MM:SS]
    grep -qE "\[[0-9]{4}-[0-9]{2}-[0-9]{2} [0-9]{2}:[0-9]{2}:[0-9]{2}\]" "$LYREBIRD_ALERT_LOG"
}

# ============================================================================
# CLI Tests
# ============================================================================

@test "show_help runs without error" {
    run show_help
    [ "$status" -eq 0 ]
    [[ "$output" =~ "USAGE:" ]]
}

@test "show_status runs without error" {
    run show_status
    [ "$status" -eq 0 ]
    [[ "$output" =~ "Configuration:" ]]
}

@test "show_config runs without error" {
    run show_config
    [ "$status" -eq 0 ]
    [[ "$output" =~ "LYREBIRD_ALERT_ENABLED" ]]
}

# ============================================================================
# Regression tests for destination detection / dispatch (C5)
# ============================================================================

@test "ntfy destination is recognized without a webhook URL [C5 regression]" {
    LYREBIRD_WEBHOOK_URL="" LYREBIRD_WEBHOOK_URLS="" \
    LYREBIRD_WEBHOOK_TYPE="ntfy" LYREBIRD_NTFY_TOPIC="mytopic" \
        alert_destination_configured
}

@test "pushover destination requires both token and user [C5 regression]" {
    LYREBIRD_WEBHOOK_URL="" LYREBIRD_WEBHOOK_URLS="" LYREBIRD_WEBHOOK_TYPE="pushover"
    run env LYREBIRD_WEBHOOK_URL="" LYREBIRD_WEBHOOK_URLS="" LYREBIRD_WEBHOOK_TYPE="pushover" \
        LYREBIRD_PUSHOVER_TOKEN="" LYREBIRD_PUSHOVER_USER="" bash -c \
        "source '$PROJECT_ROOT/lyrebird-alerts.sh' >/dev/null 2>&1; set +euo pipefail; alert_destination_configured"
    [ "$status" -ne 0 ]
    LYREBIRD_PUSHOVER_TOKEN="tok" LYREBIRD_PUSHOVER_USER="usr" \
    LYREBIRD_WEBHOOK_URL="" LYREBIRD_WEBHOOK_URLS="" LYREBIRD_WEBHOOK_TYPE="pushover" \
        alert_destination_configured
}

@test "send_alert actually dispatches an ntfy alert via curl [C5 regression]" {
    # Previously send_alert returned 0 from the guard WITHOUT sending. Shim curl
    # to record the endpoint it is called with and prove dispatch happens.
    local calllog="${BATS_TEST_TMPDIR:-$LYREBIRD_ALERT_STATE_DIR}/curl.log"
    : > "$calllog"
    curl() { printf '%s\n' "$*" >> "$calllog"; printf '200'; }
    LYREBIRD_ALERT_ENABLED="true"
    LYREBIRD_WEBHOOK_URL="" LYREBIRD_WEBHOOK_URLS=""
    LYREBIRD_WEBHOOK_TYPE="ntfy" LYREBIRD_NTFY_TOPIC="t" LYREBIRD_NTFY_SERVER="https://ntfy.example"
    run send_alert "info" "Stream Down: mic1" "Body text" "test"
    [ "$status" -eq 0 ]
    grep -q 'ntfy.example/t' "$calllog"
}

# ============================================================================
# Regression tests for JSON escaping validity (H10)
# ============================================================================

@test "json_escape yields a valid JSON string for control chars/backslash [H10 regression]" {
    # backslash, quote, newline, tab, ESC (0x1b), backspace (0x08), formfeed (0x0c)
    local msg; msg=$(printf 'a\\b"c\nd\te\033f\010g\014h')
    local esc; esc=$(json_escape "$msg")
    # Wrapping the escaped output in quotes must parse as a JSON string.
    run python3 -c 'import json,sys; json.loads("\""+sys.argv[1]+"\""); print("OK")' "$esc"
    [ "$status" -eq 0 ]
    [ "$output" = "OK" ]
}

@test "format_discord payload is valid JSON with a hostile message [H10 regression]" {
    # ANSI colour codes (ESC), newline, tab, quotes, backslash, and a colon title.
    local msg; msg=$(printf 'ffmpeg \033[31merror\033[0m\nline2\ttab "q" \\ back')
    run format_discord "critical" "Stream Down: mic1" "$msg" "stream_down"
    [ "$status" -eq 0 ]
    printf '%s' "$output" | python3 -c 'import json,sys; json.load(sys.stdin); print("valid")'
}

# ============================================================================
# Regression tests for delivery correctness (ALERT-3/4)
# ============================================================================

@test "format_pushover adds retry+expire for critical (priority 2) [ALERT-3 regression]" {
    export LYREBIRD_PUSHOVER_TOKEN="tok" LYREBIRD_PUSHOVER_USER="usr"
    run format_pushover "critical" "MediaMTX down" "server unreachable" "mediamtx_down"
    [ "$status" -eq 0 ]
    # priority=2 without retry/expire is rejected by Pushover with HTTP 400.
    [[ "$output" == *"priority=2"* ]]
    [[ "$output" == *"retry="* ]]
    [[ "$output" == *"expire="* ]]
}

@test "format_pushover does not add retry/expire below priority 2 [ALERT-3 regression]" {
    export LYREBIRD_PUSHOVER_TOKEN="tok" LYREBIRD_PUSHOVER_USER="usr"
    run format_pushover "warning" "Disk high" "80% used" "disk_warning"
    [ "$status" -eq 0 ]
    [[ "$output" != *"retry="* ]]
    [[ "$output" != *"expire="* ]]
}

@test "format_ntfy round-trips a title/message containing colons [ALERT-4 regression]" {
    run format_ntfy "critical" "Stream Down: mydevice" "Stream 'mydevice' is down: no data" "stream_down"
    [ "$status" -eq 0 ]
    # Payload is NTFY:<priority>:<base64 title>:<base64 message>; base64 has no
    # ':' so the field split is unambiguous. Decode and compare to the originals.
    local tag prio b64t b64m
    IFS=: read -r tag prio b64t b64m <<< "$output"
    [ "$tag" = "NTFY" ]
    [ "$prio" = "urgent" ]
    [ "$(printf '%s' "$b64t" | base64 -d)" = "Stream Down: mydevice" ]
    [ "$(printf '%s' "$b64m" | base64 -d)" = "Stream 'mydevice' is down: no data" ]
}

# ============================================================================
# LB-17: delivery state (rate limit / de-duplication) correctness
# ============================================================================

# Write a delivery stamp as if the delivery happened AGE seconds ago: the
# recorded epoch and the file's mtime both go back, as they would in real life.
make_old_stamp() {
    local file="$1" age="$2" then
    then=$(($(date +%s) - age))
    printf '%s\n' "$then" >"$file"
    touch -d "@$then" "$file"
}

@test "cleanup_state keeps state for the rate-limit window when it exceeds the dedup window [LB-17]" {
    # RATE_LIMIT (7200) > DEDUP_WINDOW (60): the stamp is only 50 minutes old, so
    # the identical alert must still be suppressed. cleanup_state used to expire
    # on DEDUP_WINDOW alone and deleted it, silently shortening the rate limit.
    LYREBIRD_ALERT_RATE_LIMIT=7200
    LYREBIRD_ALERT_DEDUP_WINDOW=60
    make_old_stamp "${ALERT_STATE_DIR}/aaaa.dest1.last" 3000
    cleanup_state
    [ -f "${ALERT_STATE_DIR}/aaaa.dest1.last" ]
    run is_rate_limited aaaa dest1
    [ "$status" -eq 0 ]
}

@test "cleanup_state rounds retention up so a stamp is never deleted before its rate limit ends [LB-17]" {
    # 90 s limit, 60 s dedup window: a 70 s old stamp is still inside the limit.
    # Truncating 90 s to 1 minute would delete anything older than 60 s.
    LYREBIRD_ALERT_RATE_LIMIT=90
    LYREBIRD_ALERT_DEDUP_WINDOW=60
    make_old_stamp "${ALERT_STATE_DIR}/bbbb.dest1.last" 70
    cleanup_state
    [ -f "${ALERT_STATE_DIR}/bbbb.dest1.last" ]
}

@test "cleanup_state still removes state older than both windows [LB-17]" {
    LYREBIRD_ALERT_RATE_LIMIT=300
    LYREBIRD_ALERT_DEDUP_WINDOW=3600
    make_old_stamp "${ALERT_STATE_DIR}/old.dest1.last" 4000
    make_old_stamp "${ALERT_STATE_DIR}/fresh.dest1.last" 100
    # a stamp in the pre-1.1.0 name format (no destination part) expires too
    make_old_stamp "${ALERT_STATE_DIR}/legacy.last" 4000
    cleanup_state
    [ ! -e "${ALERT_STATE_DIR}/old.dest1.last" ]
    [ ! -e "${ALERT_STATE_DIR}/legacy.last" ]
    [ -f "${ALERT_STATE_DIR}/fresh.dest1.last" ]
}

# curl stand-in placed first on PATH. Every call appends ONE line
# ("<endpoint> <pid> lockfds=<n>") in a single write, so concurrent callers cannot
# interleave. Behaviour comes from environment variables:
#   SHIM_DELAY   seconds to wait before answering (widens race windows)
#   SHIM_HANG    seconds to hang without ever answering; the process is replaced by
#                sleep (exec), so it keeps every file descriptor it inherited
#   SHIM_BAD_OK  path; once that file exists *bad.example* answers 200 instead of 500
install_curl_shim() {
    SHIM_DIR="${BATS_TEST_TMPDIR}/shim"
    SHIM_LOG="${BATS_TEST_TMPDIR}/curl.log"
    export SHIM_LOG
    mkdir -p "$SHIM_DIR"
    : >"$SHIM_LOG"
    cat >"$SHIM_DIR/curl" <<'SHIM'
#!/bin/bash
url="${*: -1}"
locked=$(ls -l "/proc/$$/fd" 2>/dev/null | grep -c '\.lock' || true)
printf '%s %s lockfds=%s\n' "$url" "$$" "$locked" >>"$SHIM_LOG"
if [[ -n "${SHIM_HANG:-}" ]]; then exec "$REAL_SLEEP" "$SHIM_HANG"; fi
if [[ -n "${SHIM_DELAY:-}" ]]; then "$REAL_SLEEP" "$SHIM_DELAY"; fi
case "$url" in
    *bad.example*)
        if [[ -e "${SHIM_BAD_OK:-/nonexistent}" ]]; then printf 200; else printf 500; fi
        ;;
    *) printf 200 ;;
esac
SHIM
    # sleep stand-in: the retry back-off (2 s or more) is recorded, with the lock FDs
    # it inherited, and skipped; short sleeps (the tests' own polling) are real.
    cat >"$SHIM_DIR/sleep" <<'SHIM'
#!/bin/bash
if [[ "$1" == 0* ]]; then exec "$REAL_SLEEP" "$@"; fi
locked=$(ls -l "/proc/$$/fd" 2>/dev/null | grep -c '\.lock' || true)
printf 'sleep:%s %s lockfds=%s\n' "$1" "$$" "$locked" >>"$SHIM_LOG"
SHIM
    chmod +x "$SHIM_DIR/curl" "$SHIM_DIR/sleep"
    PATH="$SHIM_DIR:$PATH"
}

# Number of curl calls whose endpoint contains $1.
shim_calls() {
    grep -c -- "$1" "$SHIM_LOG" || true
}

# Wait (at most ~10 s) until the file $1 exists.
wait_for_file() {
    local i
    for ((i = 0; i < 200; i++)); do
        [ -e "$1" ] && return 0
        sleep 0.05
    done
    return 1
}

# Print the exit status of send_alert "$@"; its stderr is appended to $ERR_LOG.
send_rc() {
    local rc=0
    send_alert "$@" >/dev/null 2>>"$ERR_LOG" || rc=$?
    printf '%s' "$rc"
}

# One working and one failing destination, no retries (fast), real rate limit.
configure_ok_and_bad() {
    ERR_LOG="${BATS_TEST_TMPDIR}/stderr.log"
    : >"$ERR_LOG"
    LYREBIRD_ALERT_ENABLED=true
    LYREBIRD_WEBHOOK_TYPE=generic
    LYREBIRD_WEBHOOK_URL="http://ok.example/hook"
    LYREBIRD_WEBHOOK_URLS="http://bad.example/hook"
    LYREBIRD_ALERT_RETRIES=1
    LYREBIRD_ALERT_RATE_LIMIT=300
}

# A single working destination.
configure_ok_only() {
    configure_ok_and_bad
    LYREBIRD_WEBHOOK_URLS=""
}

# Path of the delivery stamp of alert (type $1, message $2) for a generic destination $3.
stamp_path() {
    alert_stamp_file "$(generate_alert_hash "$1" "$2")" "$(generate_destination_id generic "$3")"
}

@test "N parallel identical alerts deliver exactly once per destination [LB-17]" {
    # Before, the stamp was written only after the send, with no lock, so every
    # caller that arrived while another was still sending delivered again.
    install_curl_shim
    configure_ok_only
    LYREBIRD_WEBHOOK_URLS="http://two.example/hook"
    export SHIM_DELAY=0.5
    local i
    for i in 1 2 3 4 5 6; do
        (printf '%s' "$(send_rc error "t" "identical alert" custom)" >"${BATS_TEST_TMPDIR}/rc.$i") &
    done
    wait
    [ "$(shim_calls ok.example)" -eq 1 ]
    [ "$(shim_calls two.example)" -eq 1 ]
    # every caller either delivered or was suppressed, and somebody delivered
    local delivered=0
    for i in 1 2 3 4 5 6; do
        case "$(cat "${BATS_TEST_TMPDIR}/rc.$i")" in
            0) delivered=$((delivered + 1)) ;;
            4) ;;
            *) false ;;
        esac
    done
    [ "$delivered" -ge 1 ]
}

@test "parallel identical alerts that all succeed leave one stamp per destination [LB-17]" {
    install_curl_shim
    configure_ok_only
    LYREBIRD_WEBHOOK_URLS="http://two.example/hook"
    export SHIM_DELAY=0.3
    local i
    for i in 1 2 3 4; do
        (send_rc error "t" "stamp count" custom >/dev/null) &
    done
    wait
    [ "$(find "$ALERT_STATE_DIR" -maxdepth 1 -name '*.last' | wc -l)" -eq 2 ]
}

@test "partial failure returns 5 and the next identical alert retries only the failed destination [LB-17]" {
    install_curl_shim
    configure_ok_and_bad
    # Before: rc 0 (any success is success), and the failed destination was not
    # retried inside the rate-limit window.
    [ "$(send_rc error "t" "same message" custom)" -eq 5 ]
    [ "$(shim_calls ok.example)" -eq 1 ]
    [ "$(shim_calls bad.example)" -eq 1 ]
    # only the destination that confirmed has a stamp
    [ "$(find "$ALERT_STATE_DIR" -maxdepth 1 -name '*.last' | wc -l)" -eq 1 ]
    [ -f "$(stamp_path custom "same message" "http://ok.example/hook")" ]
    [ ! -e "$(stamp_path custom "same message" "http://bad.example/hook")" ]
    grep -q "FAILED" "$ERR_LOG"

    # the destination recovers: the identical alert reaches it, and only it
    : >"${BATS_TEST_TMPDIR}/bad_ok"
    export SHIM_BAD_OK="${BATS_TEST_TMPDIR}/bad_ok"
    [ "$(send_rc error "t" "same message" custom)" -eq 0 ]
    [ "$(shim_calls ok.example)" -eq 1 ]
    [ "$(shim_calls bad.example)" -eq 2 ]

    # now everything holds the alert: suppressed, no request at all
    [ "$(send_rc error "t" "same message" custom)" -eq 4 ]
    [ "$(shim_calls ok.example)" -eq 1 ]
    [ "$(shim_calls bad.example)" -eq 2 ]
}

@test "a destination that keeps failing is retried every time and stays partial [LB-17]" {
    install_curl_shim
    configure_ok_and_bad
    [ "$(send_rc error "t" "still broken" custom)" -eq 5 ]
    [ "$(send_rc error "t" "still broken" custom)" -eq 5 ]
    [ "$(send_rc error "t" "still broken" custom)" -eq 5 ]
    [ "$(shim_calls ok.example)" -eq 1 ]
    [ "$(shim_calls bad.example)" -eq 3 ]
}

@test "total failure returns 3, records nothing and is retried by the next identical alert [LB-17]" {
    install_curl_shim
    configure_ok_only
    LYREBIRD_WEBHOOK_URL="http://bad.example/hook"
    [ "$(send_rc error "t" "nobody home" custom)" -eq 3 ]
    [ "$(find "$ALERT_STATE_DIR" -maxdepth 1 -name '*.last' | wc -l)" -eq 0 ]
    [ "$(send_rc error "t" "nobody home" custom)" -eq 3 ]
    [ "$(shim_calls bad.example)" -eq 2 ]
}

@test "all destinations delivered returns 0; an identical alert is then suppressed with 4 and no request [LB-17]" {
    install_curl_shim
    configure_ok_only
    LYREBIRD_WEBHOOK_URLS="http://two.example/hook"
    [ "$(send_rc error "t" "all fine" custom)" -eq 0 ]
    [ "$(shim_calls example)" -eq 2 ]
    [ "$(send_rc error "t" "all fine" custom)" -eq 4 ]
    [ "$(shim_calls example)" -eq 2 ]
    # a different message is a different alert
    [ "$(send_rc error "t" "another one" custom)" -eq 0 ]
    [ "$(shim_calls example)" -eq 4 ]
}

@test "partial status also covers a destination that already had the alert while another fails [LB-17]" {
    # ok.example delivered earlier; bad.example fails now and nothing else was sent.
    # The alert exists at one destination, so this is not a total failure (3).
    install_curl_shim
    configure_ok_only
    [ "$(send_rc error "t" "earlier" custom)" -eq 0 ]
    LYREBIRD_WEBHOOK_URLS="http://bad.example/hook"
    [ "$(send_rc error "t" "earlier" custom)" -eq 5 ]
    [ "$(shim_calls ok.example)" -eq 1 ]
}

@test "with no usable destination send_alert fails with 3 and says why [LB-17]" {
    install_curl_shim
    configure_ok_only
    # a URL is set, but the type is ntfy with an empty topic: nothing can be built
    LYREBIRD_WEBHOOK_TYPE=ntfy
    LYREBIRD_NTFY_TOPIC=""
    [ "$(send_rc error "t" "nowhere" custom)" -eq 3 ]
    grep -q "no usable destination" "$ERR_LOG"
    [ "$(shim_calls "")" -eq 0 ]
}

@test "delivery state and logs never contain a destination URL or token [LB-17]" {
    install_curl_shim
    configure_ok_and_bad
    local secret="SECRETTOKEN0123456789"
    LYREBIRD_WEBHOOK_URL="http://ok.example/hook/${secret}"
    LYREBIRD_WEBHOOK_URLS="http://bad.example/hook/${secret}-other"
    [ "$(send_rc error "t" "hide the secret" custom)" -eq 5 ]
    ! grep -rq "$secret" "$ALERT_STATE_DIR" || false
    [[ "$(ls -A "$ALERT_STATE_DIR")" != *SECRET* ]]
    ! grep -q "$secret" "$ALERT_LOG_FILE" || false
    ! grep -q "$secret" "$ERR_LOG" || false
    # the failure is still reported, with the URL masked (mask_url: 30 characters + ***)
    grep -qF "failed: $(mask_url "$LYREBIRD_WEBHOOK_URLS") " "$ERR_LOG"
    grep -qF '***' "$ERR_LOG"

    # Pushover: token and user key identify the destination but are never stored
    LYREBIRD_WEBHOOK_TYPE=pushover
    LYREBIRD_WEBHOOK_URL="" LYREBIRD_WEBHOOK_URLS=""
    LYREBIRD_PUSHOVER_TOKEN="PUSHTOKENSECRET1234" LYREBIRD_PUSHOVER_USER="PUSHUSERSECRET5678"
    [ "$(send_rc error "t" "pushover secret" custom)" -eq 0 ]
    ! grep -rq -e PUSHTOKENSECRET -e PUSHUSERSECRET "$ALERT_STATE_DIR" || false
    [[ "$(ls -A "$ALERT_STATE_DIR")" != *PUSH* ]]
    ! grep -q -e PUSHTOKENSECRET -e PUSHUSERSECRET "$ALERT_LOG_FILE" "$ERR_LOG" || false
}

@test "generate_destination_id is stable and separates type, endpoint and credentials [LB-17]" {
    local url="https://hooks.example/services/SECRETTOKEN0123456789"
    local a b
    a="$(generate_destination_id generic "$url")"
    b="$(generate_destination_id generic "$url")"
    [ -n "$a" ]
    [ "$a" = "$b" ]
    [[ "$a" =~ ^[0-9a-f]+$ ]]
    [ "$a" != "$(generate_destination_id discord "$url")" ]
    [ "$a" != "$(generate_destination_id generic "${url}x")" ]
    [ "$(generate_destination_id pushover pushover-api "tok1|usr")" != "$(generate_destination_id pushover pushover-api "tok2|usr")" ]
    [ "$(generate_destination_id pushover pushover-api "tok1|usr1")" != "$(generate_destination_id pushover pushover-api "tok1|usr2")" ]
}

@test "delivery state is per destination: another destination is not rate limited by it [LB-17]" {
    export LYREBIRD_ALERT_RATE_LIMIT=3600
    update_rate_limit "hash1" "destA"
    run is_rate_limited "hash1" "destA"
    [ "$status" -eq 0 ]
    run is_rate_limited "hash1" "destB"
    [ "$status" -eq 1 ]
    run is_rate_limited "hash2" "destA"
    [ "$status" -eq 1 ]
}

@test "a stamp that is empty, torn or not a number never suppresses an alert and is rewritten [LB-17]" {
    install_curl_shim
    configure_ok_only
    local url="http://ok.example/hook" stamp content calls=0 now
    stamp="$(stamp_path custom "torn stamp" "$url")"
    ensure_state_dir
    now="$(date +%s)"
    # "1731" is what a write cut off after four digits looks like; the rest is
    # empty, whitespace, text, a sign, an overflowing number and a float, and
    # current-looking epochs that are not a plain number (arithmetic would accept
    # them: trailing space, "+0", a leading plus).
    for content in '' ' ' $'\n' 'garbage' '12abc' '-5' '1731' '99999999999999999999' '1e9' \
        "${now} " "${now}+0" "+${now}" "${now}x"; do
        printf '%s' "$content" >"$stamp"
        run is_rate_limited "$(generate_alert_hash custom "torn stamp")" "$(generate_destination_id generic "$url")"
        [ "$status" -eq 1 ]
        [ "$(send_rc error "t" "torn stamp" custom)" -eq 0 ]
        calls=$((calls + 1))
        [ "$(shim_calls ok.example)" -eq "$calls" ]
        # the stamp was replaced by a valid, current one
        [[ "$(cat "$stamp")" =~ ^[0-9]+$ ]]
        [ "$(($(date +%s) - $(cat "$stamp")))" -lt 60 ]
    done
}

@test "a stamp dated in the future (clock stepped back) does not suppress alerts [LB-17]" {
    export LYREBIRD_ALERT_RATE_LIMIT=300
    ensure_state_dir
    printf '%s\n' "$(($(date +%s) + 86400))" >"$(alert_stamp_file hhh ddd)"
    run is_rate_limited hhh ddd
    [ "$status" -eq 1 ]
}

@test "a non-numeric rate limit or dedup window falls back to the defaults instead of aborting [LB-17]" {
    # Under the script's own strict mode (set -u) a word like "abc" is an unbound
    # variable inside arithmetic, which used to abort the caller.
    run env LYREBIRD_ALERT_RATE_LIMIT=5m LYREBIRD_ALERT_DEDUP_WINDOW=abc \
        LYREBIRD_ALERT_STATE_DIR="$ALERT_STATE_DIR" LYREBIRD_ALERT_LOG="$LYREBIRD_ALERT_LOG" \
        bash -c 'source "$1"
                 update_rate_limit hhh ddd
                 # default rate limit (300 s): the stamp just written is inside it
                 is_rate_limited hhh ddd || exit 10
                 cleanup_state || exit 11
                 [[ -f "$(alert_stamp_file hhh ddd)" ]] || exit 12' _ "$PROJECT_ROOT/lyrebird-alerts.sh"
    [ "$status" -eq 0 ]
}

@test "a reader never sees an empty or partial stamp while it is rewritten [LB-17]" {
    # Before: `date +%s > file` truncates first, so a concurrent reader saw an
    # empty file, which counted as "never sent".
    local file
    file="$(alert_stamp_file rrr ddd)"
    update_rate_limit rrr ddd
    local w
    for w in 1 2; do
        (
            local n
            for ((n = 0; n < 100; n++)); do
                update_rate_limit rrr ddd
            done
        ) &
    done
    local bad=0 i
    for ((i = 0; i < 1500; i++)); do
        read_delivery_stamp "$file" >/dev/null || bad=$((bad + 1))
    done
    wait
    [ "$bad" -eq 0 ]
}

@test "rate limit longer than the dedup window: another alert's cleanup does not re-arm an alert [LB-17]" {
    install_curl_shim
    configure_ok_only
    LYREBIRD_ALERT_DEDUP_WINDOW=60
    LYREBIRD_ALERT_RATE_LIMIT=7200
    [ "$(send_rc error "t" "message A" custom)" -eq 0 ]
    # A was delivered 50 minutes ago, well inside the two-hour rate limit
    make_old_stamp "$(stamp_path custom "message A" "http://ok.example/hook")" 3000
    # a successful send of any other alert runs cleanup_state
    [ "$(send_rc error "t" "message B" custom)" -eq 0 ]
    [ -f "$(stamp_path custom "message A" "http://ok.example/hook")" ]
    [ "$(send_rc error "t" "message A" custom)" -eq 4 ]
    [ "$(shim_calls ok.example)" -eq 2 ]
}

@test "a destination being delivered to by another process is skipped (4), then sent once it is free [LB-17]" {
    install_curl_shim
    configure_ok_only
    local ah dh
    ah="$(generate_alert_hash custom "held message")"
    dh="$(generate_destination_id generic "http://ok.example/hook")"
    ensure_state_dir
    # Hold the claim the way a concurrent sender does.
    (
        exec 8>>"${ALERT_STATE_DIR}/${ah}.${dh}.lock"
        flock 8
        : >"${BATS_TEST_TMPDIR}/held"
        exec "$REAL_SLEEP" 60
    ) 3>&- &
    BG_PIDS="$!"
    wait_for_file "${BATS_TEST_TMPDIR}/held"

    [ "$(send_rc error "t" "held message" custom)" -eq 4 ]
    [ "$(shim_calls ok.example)" -eq 0 ]
    [ "$(find "$ALERT_STATE_DIR" -maxdepth 1 -name '*.last' | wc -l)" -eq 0 ]

    # the holder dies without having delivered: the kernel drops its lock
    kill "$BG_PIDS"
    wait "$BG_PIDS" 2>/dev/null || true
    [ "$(send_rc error "t" "held message" custom)" -eq 0 ]
    [ "$(shim_calls ok.example)" -eq 1 ]
}

@test "a sender that finished between another's check and claim is not duplicated [LB-17]" {
    # The check before the claim saw no stamp; by the time the claim is taken, the
    # other sender has delivered and recorded it. alert_claim is replaced by a hook
    # that records that delivery first (the real claim logic is covered above).
    install_curl_shim
    configure_ok_only
    local url="http://ok.example/hook"
    alert_claim() {
        update_rate_limit "$1" "$2"
        return 2
    }
    [ "$(send_rc error "t" "raced" custom)" -eq 4 ]
    [ "$(shim_calls ok.example)" -eq 0 ]
}

@test "a delivery whose state cannot be recorded still succeeds and warns that it may repeat [LB-17]" {
    install_curl_shim
    configure_ok_only
    lyrebird_atomic_write() { return 1; }
    [ "$(send_rc error "t" "no state" custom)" -eq 0 ]
    [ "$(shim_calls ok.example)" -eq 1 ]
    grep -q "could not be recorded" "$ERR_LOG"
}

@test "a sender killed mid-delivery leaves no claim behind, even with its curl still running [LB-17]" {
    # SIGKILL the sender while its curl hangs. The lock is released by the kernel
    # (no staleness heuristic) and the surviving curl must not hold it: it would
    # have inherited the lock FD if that were not closed in children.
    install_curl_shim
    configure_ok_only
    SHIM_HANG=60 send_alert error "t" "killed sender" custom >/dev/null 2>&1 3>&- &
    local sender=$!
    local i
    for ((i = 0; i < 200; i++)); do
        [ -s "$SHIM_LOG" ] && break
        sleep 0.05
    done
    [ "$(shim_calls ok.example)" -eq 1 ]
    local hung_curl
    hung_curl="$(awk '{print $2}' "$SHIM_LOG")"
    BG_PIDS="$hung_curl"
    kill -KILL "$sender"
    wait "$sender" 2>/dev/null || true
    kill -0 "$hung_curl" # the orphaned curl is still running

    [ "$(send_rc error "t" "killed sender" custom)" -eq 0 ]
    [ "$(shim_calls ok.example)" -eq 2 ]
}

@test "no child of a sender (curl, sleep between retries) inherits the claim lock [LB-17]" {
    install_curl_shim
    configure_ok_and_bad
    LYREBIRD_ALERT_RETRIES=2
    # bad.example fails, so the back-off sleep between attempts runs as well
    [ "$(send_rc error "t" "fd hygiene" custom)" -eq 5 ]
    # ok.example once; bad.example twice with a sleep in between
    [ "$(shim_calls "")" -eq 4 ]
    [ "$(shim_calls "sleep:")" -eq 1 ]
    ! grep -v 'lockfds=0$' "$SHIM_LOG" || false
}

@test "an unusable claim does not stop delivery: flock failing sends with a warning [LB-17]" {
    install_curl_shim
    configure_ok_only
    printf '#!/bin/bash\nexit 71\n' >"${SHIM_DIR}/flock"
    chmod +x "${SHIM_DIR}/flock"
    [ "$(send_rc error "t" "no flock" custom)" -eq 0 ]
    [ "$(shim_calls ok.example)" -eq 1 ]
    grep -q "without duplicate protection" "$ERR_LOG"
}

@test "an unusable claim guard does not stop delivery [LB-17]" {
    install_curl_shim
    configure_ok_only
    mkdir -p "${ALERT_STATE_DIR}/.claim.guard" # cannot be opened as a file
    [ "$(send_rc error "t" "bad guard" custom)" -eq 0 ]
    [ "$(shim_calls ok.example)" -eq 1 ]
    grep -q "without duplicate protection" "$ERR_LOG"
}

@test "an unusable state directory does not stop delivery [LB-17]" {
    install_curl_shim
    : >"${BATS_TEST_TMPDIR}/notadir"
    run env PATH="$PATH" SHIM_LOG="$SHIM_LOG" \
        LYREBIRD_ALERT_STATE_DIR="${BATS_TEST_TMPDIR}/notadir/state" \
        LYREBIRD_ALERT_LOG="$LYREBIRD_ALERT_LOG" LYREBIRD_ALERT_ENABLED=true \
        LYREBIRD_WEBHOOK_URL="http://ok.example/hook" LYREBIRD_WEBHOOK_TYPE=generic \
        bash -c 'source "$1"; send_alert error t "no state dir" custom' _ "$PROJECT_ROOT/lyrebird-alerts.sh"
    [ "$status" -eq 0 ]
    [ "$(shim_calls ok.example)" -eq 1 ]
}

@test "cleanup_state removes old claim files nobody holds, keeps held and fresh ones and the guard [LB-17]" {
    ensure_state_dir
    local old="${ALERT_STATE_DIR}/aa.d1.lock" held="${ALERT_STATE_DIR}/bb.d1.lock" fresh="${ALERT_STATE_DIR}/cc.d1.lock"
    : >"$old"
    : >"$held"
    : >"$fresh"
    touch -d '3 hours ago' "$old" "$held"
    (
        exec 8>>"$held"
        flock 8
        : >"${BATS_TEST_TMPDIR}/held"
        exec "$REAL_SLEEP" 60
    ) 3>&- &
    BG_PIDS="$!"
    wait_for_file "${BATS_TEST_TMPDIR}/held"

    cleanup_state
    [ ! -e "$old" ]
    [ -f "$held" ]
    [ -f "$fresh" ]
    [ -f "${ALERT_STATE_DIR}/.claim.guard" ]
}

@test "cleanup_state removes a temp file a killed writer left behind, once it is old [LB-17]" {
    ensure_state_dir
    : >"${ALERT_STATE_DIR}/.aa.d1.last.AbC123"
    : >"${ALERT_STATE_DIR}/.bb.d1.last.XyZ789"
    touch -d '3 hours ago' "${ALERT_STATE_DIR}/.aa.d1.last.AbC123"
    cleanup_state
    [ ! -e "${ALERT_STATE_DIR}/.aa.d1.last.AbC123" ]
    [ -e "${ALERT_STATE_DIR}/.bb.d1.last.XyZ789" ]
}

@test "stamps are written with the local fallback when the common library lacks lyrebird_atomic_write [LB-17]" {
    # A copy of the script next to a common library that has logging but no
    # atomic write (an older install).
    local dir="${BATS_TEST_TMPDIR}/oldinstall"
    mkdir -p "$dir"
    cp "$PROJECT_ROOT/lyrebird-alerts.sh" "$dir/"
    cat >"$dir/lyrebird-common.sh" <<'OLDLIB'
log_info() { :; }
log_warn() { :; }
log_error() { :; }
log_debug() { :; }
OLDLIB
    run env LYREBIRD_ALERT_STATE_DIR="${BATS_TEST_TMPDIR}/oldstate" LYREBIRD_ALERT_LOG="$LYREBIRD_ALERT_LOG" \
        bash -c 'source "$1/lyrebird-alerts.sh"; declare -F lyrebird_atomic_write >/dev/null || exit 10
                 update_rate_limit h d || exit 11
                 [[ "$(cat "$ALERT_STATE_DIR/h.d.last")" =~ ^[0-9]+$ ]] || exit 12
                 [[ -z "$(find "$ALERT_STATE_DIR" -name ".*.XXXXXX" -o -name ".h.d.last.*")" ]] || exit 13
                 is_rate_limited h d' _ "$dir"
    [ "$status" -eq 0 ]
}

@test "the send CLI exits 5 on partial failure, 3 on total failure and 4 when suppressed, under strict mode [LB-17]" {
    install_curl_shim
    local common=(env PATH="$PATH" SHIM_LOG="$SHIM_LOG"
        LYREBIRD_ALERT_STATE_DIR="$ALERT_STATE_DIR" LYREBIRD_ALERT_LOG="$LYREBIRD_ALERT_LOG"
        LYREBIRD_ALERT_CONFIG="$LYREBIRD_ALERT_CONFIG" LYREBIRD_ALERT_ENABLED=true
        LYREBIRD_WEBHOOK_TYPE=generic LYREBIRD_ALERT_RETRIES=1)
    run "${common[@]}" LYREBIRD_WEBHOOK_URL="http://ok.example/hook" LYREBIRD_WEBHOOK_URLS="http://bad.example/hook" \
        bash "$PROJECT_ROOT/lyrebird-alerts.sh" send --level error --message "cli partial"
    [ "$status" -eq 5 ]
    run "${common[@]}" LYREBIRD_WEBHOOK_URL="http://bad.example/hook" \
        bash "$PROJECT_ROOT/lyrebird-alerts.sh" send --level error --message "cli total"
    [ "$status" -eq 3 ]
    run "${common[@]}" LYREBIRD_WEBHOOK_URL="http://ok.example/hook" \
        bash "$PROJECT_ROOT/lyrebird-alerts.sh" send --level error --message "cli ok"
    [ "$status" -eq 0 ]
    run "${common[@]}" LYREBIRD_WEBHOOK_URL="http://ok.example/hook" \
        bash "$PROJECT_ROOT/lyrebird-alerts.sh" send --level error --message "cli ok"
    [ "$status" -eq 4 ]
}

@test "the test command reports a partial delivery instead of success [LB-17]" {
    install_curl_shim
    configure_ok_and_bad
    run cmd_test
    [ "$status" -eq 1 ]
    [[ "$output" == *"some destinations"* ]]
    [[ "$output" != *"sent successfully"* ]]
}

@test "help lists the send_alert exit statuses including the partial-failure code [LB-17]" {
    run show_help
    [ "$status" -eq 0 ]
    [[ "$output" == *"EXIT STATUS"* ]]
    [[ "$output" =~ 5[[:space:]]+partial ]]
}
