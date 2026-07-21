#!/usr/bin/env bats
# Monotonic-timing regression tests (the deferred "non-monotonic timing" item).
#
# A field Pi without an RTC boots with a bogus clock and steps it -- sometimes
# by years -- when NTP first syncs. Wall-clock deltas (date +%s) then corrupt:
#  - the wrapper's RUN_TIME (a healthy multi-hour run measures negative and is
#    counted as a consecutive FAILURE -> wrapper eventually gives up), and
#  - the cron restart budget (a forward step ages every recorded restart out
#    of the window -> the anti-storm budget evaporates).
# The fix reads /proc/uptime (monotonic). These tests simulate clock jumps
# with a PATH-shim `date` and prove the timing survives them.

setup() {
    TEST_DIR="$( cd "$( dirname "$BATS_TEST_FILENAME" )" && pwd )"
    PROJECT_ROOT="$( cd "$TEST_DIR/.." && pwd )"
    MT_TMP="$(mktemp -d)"
    mkdir -p "$MT_TMP/bin"
}

teardown() {
    rm -rf "$MT_TMP" 2>/dev/null || true
}

# A fake `date` whose +%s output JUMPS BACKWARD 5000s on every call; all other
# formats pass through to the real date.
_write_jumping_date() {
    date +%s > "$MT_TMP/date.state"
    cat > "$MT_TMP/bin/date" <<EOF
#!/bin/bash
if [[ "\${1:-}" == "+%s" ]]; then
    n=\$(cat "$MT_TMP/date.state")
    echo "\$n"
    echo \$((n - 5000)) > "$MT_TMP/date.state"
else
    exec /bin/date "\$@"
fi
EOF
    chmod +x "$MT_TMP/bin/date"
}

# Extract the real now_s helper and the real (2nd, individual-stream) restart
# loop from the generated-wrapper heredocs.
_extract_now_s() {
    awk '/^now_s\(\) \{$/ { c++; if (c == 1) p = 1 } p { print } p && /^\}$/ { exit }' \
        "$PROJECT_ROOT/lyrebird-stream-manager.sh"
}

_extract_restart_loop() {
    awk '
        /^# Main restart loop$/ { c++ }
        c == 2 { print }
        /^log_message "Wrapper exiting/ && c == 2 { exit }
    ' "$PROJECT_ROOT/lyrebird-stream-manager.sh"
}

@test "wrapper does not count healthy runs as failures across BACKWARD clock jumps [E2E]" {
    # ffmpeg fake: runs 2s (> WRAPPER_SUCCESS_DURATION=1) then exits cleanly --
    # every run is healthy. The jumping `date` makes each wall-clock RUN_TIME
    # negative; pre-fix that increments CONSECUTIVE_FAILURES until the wrapper
    # gives up after exactly MAX_CONSECUTIVE_FAILURES=2 launches.
    cat > "$MT_TMP/bin/ffmpeg" <<EOF
#!/bin/bash
echo "call" >> "$MT_TMP/calls.log"
sleep 2
exit 0
EOF
    chmod +x "$MT_TMP/bin/ffmpeg"
    : > "$MT_TMP/calls.log"
    _write_jumping_date

    local wrapper="$MT_TMP/wrapper.sh"
    {
        echo '#!/bin/bash'
        echo 'set -euo pipefail'
        echo "export PATH=\"$MT_TMP/bin:\$PATH\""
        cat <<'CFG'
STREAM_PATH="testmic"; CARD_NUM=0; FFMPEG_PID=""
CLEANUP_MARKER="/nonexistent/cleanup.marker"
RESTART_COUNT=0; CONSECUTIVE_FAILURES=0
MAX_CONSECUTIVE_FAILURES=2; MAX_WRAPPER_RESTARTS=100
WRAPPER_SUCCESS_DURATION=1
INITIAL_RESTART_DELAY=1; MAX_RESTART_DELAY=1; RESTART_DELAY=1
log_message() { :; }
log_critical() { :; }
check_parent_alive() { return 0; }
check_device_exists() { return 0; }
run_ffmpeg() { ffmpeg >/dev/null 2>&1 & FFMPEG_PID=$!; return 0; }
CFG
        _extract_now_s
        _extract_restart_loop
    } > "$wrapper"
    bash -n "$wrapper"

    # Pre-fix: exactly 2 launches then the wrapper quits ("too many consecutive
    # failures") even though every run was healthy. Post-fix: it keeps going.
    timeout 12s bash "$wrapper" || true
    local calls
    calls=$(grep -c 'call' "$MT_TMP/calls.log" 2>/dev/null || echo 0)
    [ "$calls" -ge 3 ]
}

@test "cron restart budget survives a FORWARD clock jump (anti-storm guarantee) [H8]" {
    # Record 3 restarts, then step the wall clock +2h. Pre-fix the budget
    # window is computed from date +%s, so every recorded restart ages out and
    # the count collapses to 0 -- the restart-storm brake evaporates.
    cat > "$MT_TMP/bin/date" <<EOF
#!/bin/bash
if [[ "\${1:-}" == "+%s" ]]; then
    echo \$(( \$(/bin/date +%s) + 7200 ))
else
    exec /bin/date "\$@"
fi
EOF
    chmod +x "$MT_TMP/bin/date"

    run env PROJECT_ROOT="$PROJECT_ROOT" MT_TMP="$MT_TMP" \
        CRON_RESTART_STATE_DIR="$MT_TMP/cron" bash -c '
        set -euo pipefail
        source "$PROJECT_ROOT/lyrebird-stream-manager.sh" >/dev/null 2>&1
        log() { :; }
        # Record with the REAL clock...
        _record_cron_restart mic1
        _record_cron_restart mic1
        _record_cron_restart mic1
        # ...then count with the clock stepped +2h.
        export PATH="$MT_TMP/bin:$PATH"
        _cron_restart_count mic1
    '
    [ "$status" -eq 0 ]
    [ "$output" = "3" ]
}

@test "cron restart budget is not corrupted by a BACKWARD clock jump" {
    cat > "$MT_TMP/bin/date" <<EOF
#!/bin/bash
if [[ "\${1:-}" == "+%s" ]]; then
    echo \$(( \$(/bin/date +%s) - 7200 ))
else
    exec /bin/date "\$@"
fi
EOF
    chmod +x "$MT_TMP/bin/date"

    run env PROJECT_ROOT="$PROJECT_ROOT" MT_TMP="$MT_TMP" \
        CRON_RESTART_STATE_DIR="$MT_TMP/cron" bash -c '
        set -euo pipefail
        source "$PROJECT_ROOT/lyrebird-stream-manager.sh" >/dev/null 2>&1
        log() { :; }
        _record_cron_restart mic1
        _record_cron_restart mic1
        export PATH="$MT_TMP/bin:$PATH"
        _cron_restart_count mic1
    '
    [ "$status" -eq 0 ]
    [ "$output" = "2" ]
}

@test "silence tracking does not fire a false DEAD MIC after a forward clock jump" {
    # First check records silence-start; then the wall clock steps +2h; the
    # second check must NOT conclude the mic has been dead for 2 hours.
    mkdir -p "$MT_TMP/ffbin"
    cat > "$MT_TMP/ffbin/ffmpeg" <<'EOF'
#!/bin/bash
echo "[Parsed_volumedetect_0 @ 0x0] max_volume: -91.0 dB" >&2
exit 0
EOF
    chmod +x "$MT_TMP/ffbin/ffmpeg"
    cp "$MT_TMP/ffbin/ffmpeg" "$MT_TMP/bin/ffmpeg"
    cat > "$MT_TMP/bin/date" <<EOF
#!/bin/bash
if [[ "\${1:-}" == "+%s" ]]; then
    echo \$(( \$(/bin/date +%s) + 7200 ))
else
    exec /bin/date "\$@"
fi
EOF
    chmod +x "$MT_TMP/bin/date"

    local stream="mtjumptest$$"
    rm -f "/run/mediamtx-silence-${stream}" 2>/dev/null || true

    run env PROJECT_ROOT="$PROJECT_ROOT" MT_TMP="$MT_TMP" STREAM="$stream" \
        AUDIO_LEVEL_CHECK_ENABLED=true AUDIO_SILENCE_WARN_DURATION=6000 \
        bash -c '
            set -euo pipefail
            source "$PROJECT_ROOT/lyrebird-stream-manager.sh" >/dev/null 2>&1
            msgs="$MT_TMP/log.txt"
            log() { echo "$*" >> "$msgs"; }
            export PATH="$MT_TMP/ffbin:$PATH"
            check_audio_level 0 "$STREAM" || true   # records silence start
            export PATH="$MT_TMP/bin:$PATH"         # NOW the clock steps +2h
            check_audio_level 0 "$STREAM" || true
            cat "$msgs"
        '
    rm -f "/run/mediamtx-silence-${stream}" 2>/dev/null || true
    [ "$status" -eq 0 ]
    [[ "$output" == *"Silence detected"* ]]
    [[ "$output" != *"DEAD MIC"* ]]
}
