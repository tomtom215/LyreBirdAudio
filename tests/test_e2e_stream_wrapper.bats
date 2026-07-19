#!/usr/bin/env bats
# End-to-end test (no real hardware) for the FFmpeg supervisor wrapper.
#
# It extracts the REAL "Main restart loop" body from lyrebird-stream-manager.sh,
# drives it with a fake `ffmpeg` that fails, and asserts the wrapper restarts it.
# Before the C2/C3 fixes the wrapper died after the first ffmpeg exit (bare
# `wait` under set -e) so ffmpeg would run exactly once.

setup() {
    TEST_DIR="$( cd "$( dirname "$BATS_TEST_FILENAME" )" && pwd )"
    PROJECT_ROOT="$( cd "$TEST_DIR/.." && pwd )"
    E2E_TMP="$(mktemp -d)"
}

teardown() {
    rm -rf "$E2E_TMP" 2>/dev/null || true
}

# Extract the individual wrapper's restart loop (the 2nd "# Main restart loop"),
# stopping before the heredoc terminator.
_extract_restart_loop() {
    awk '
        /^# Main restart loop$/ { c++ }
        c == 2 { print }
        /^log_message "Wrapper exiting/ && c == 2 { exit }
    ' "$PROJECT_ROOT/lyrebird-stream-manager.sh"
}

@test "wrapper restarts a failing ffmpeg without hardware [C2/C3 E2E]" {
    # Fake ffmpeg: record each invocation, run briefly, then fail.
    mkdir -p "$E2E_TMP/bin"
    cat > "$E2E_TMP/bin/ffmpeg" <<EOF
#!/bin/bash
echo "call" >> "$E2E_TMP/calls.log"
sleep 0.3
exit 1
EOF
    chmod +x "$E2E_TMP/bin/ffmpeg"
    : > "$E2E_TMP/calls.log"

    # Assemble a runnable wrapper: test config + helpers + the REAL loop body.
    local wrapper="$E2E_TMP/wrapper.sh"
    {
        echo '#!/bin/bash'
        echo 'set -euo pipefail'
        echo "export PATH=\"$E2E_TMP/bin:\$PATH\""
        # Config the loop references (fast restarts, high caps so it keeps going)
        cat <<'CFG'
STREAM_PATH="testmic"; CARD_NUM=0; FFMPEG_PID=""
CLEANUP_MARKER="/nonexistent/cleanup.marker"
RESTART_COUNT=0; CONSECUTIVE_FAILURES=0
MAX_CONSECUTIVE_FAILURES=100; MAX_WRAPPER_RESTARTS=100
WRAPPER_SUCCESS_DURATION=300
INITIAL_RESTART_DELAY=1; MAX_RESTART_DELAY=1; RESTART_DELAY=1
log_message() { :; }
log_critical() { :; }
check_parent_alive() { return 0; }
check_device_exists() { return 0; }
run_ffmpeg() { ffmpeg >/dev/null 2>&1 & FFMPEG_PID=$!; return 0; }
CFG
        _extract_restart_loop
    } > "$wrapper"

    # The assembled wrapper must be syntactically valid.
    bash -n "$wrapper"

    # Run it for a few seconds; it loops forever until stopped.
    timeout 5s bash "$wrapper" || true

    # It must have launched ffmpeg at least twice (i.e. it RESTARTED after a
    # failure). The pre-fix wrapper would show exactly one invocation.
    local calls
    calls=$(grep -c 'call' "$E2E_TMP/calls.log" 2>/dev/null || echo 0)
    [ "$calls" -ge 2 ]
}

@test "wrapper stops when the cleanup marker appears [E2E]" {
    mkdir -p "$E2E_TMP/bin"
    cat > "$E2E_TMP/bin/ffmpeg" <<EOF
#!/bin/bash
sleep 0.2
exit 1
EOF
    chmod +x "$E2E_TMP/bin/ffmpeg"

    local marker="$E2E_TMP/cleanup.marker"
    local wrapper="$E2E_TMP/wrapper.sh"
    {
        echo '#!/bin/bash'
        echo 'set -euo pipefail'
        echo "export PATH=\"$E2E_TMP/bin:\$PATH\""
        echo "CLEANUP_MARKER=\"$marker\""
        cat <<'CFG'
STREAM_PATH="testmic"; CARD_NUM=0; FFMPEG_PID=""
RESTART_COUNT=0; CONSECUTIVE_FAILURES=0
MAX_CONSECUTIVE_FAILURES=100; MAX_WRAPPER_RESTARTS=100
WRAPPER_SUCCESS_DURATION=300
INITIAL_RESTART_DELAY=1; MAX_RESTART_DELAY=1; RESTART_DELAY=1
log_message() { :; }
log_critical() { :; }
check_parent_alive() { return 0; }
check_device_exists() { return 0; }
run_ffmpeg() { ffmpeg >/dev/null 2>&1 & FFMPEG_PID=$!; return 0; }
CFG
        _extract_restart_loop
    } > "$wrapper"

    # Create the marker, then run: the wrapper must exit promptly (graceful stop).
    : > "$marker"
    run timeout 5s bash "$wrapper"
    # timeout returns 124 only if the wrapper was still running at the deadline.
    [ "$status" -ne 124 ]
}

@test "wrapper does NOT give up at MAX_WRAPPER_RESTARTS when runs succeed [SM-1 E2E regression]" {
    # RESTART_COUNT was a lifetime odometer that was never reset, so after
    # MAX_WRAPPER_RESTARTS benign restarts the wrapper quit for good. It must now
    # reset on each healthy (>WRAPPER_SUCCESS_DURATION) run and keep supervising.
    mkdir -p "$E2E_TMP/bin"
    cat > "$E2E_TMP/bin/ffmpeg" <<EOF
#!/bin/bash
echo "call" >> "$E2E_TMP/calls.log"
sleep 2       # longer than WRAPPER_SUCCESS_DURATION -> counts as a successful run
exit 0
EOF
    chmod +x "$E2E_TMP/bin/ffmpeg"
    : > "$E2E_TMP/calls.log"

    local wrapper="$E2E_TMP/wrapper.sh"
    {
        echo '#!/bin/bash'
        echo 'set -euo pipefail'
        echo "export PATH=\"$E2E_TMP/bin:\$PATH\""
        cat <<'CFG'
STREAM_PATH="testmic"; CARD_NUM=0; FFMPEG_PID=""
CLEANUP_MARKER="/nonexistent/cleanup.marker"
RESTART_COUNT=0; CONSECUTIVE_FAILURES=0
MAX_CONSECUTIVE_FAILURES=100; MAX_WRAPPER_RESTARTS=2
WRAPPER_SUCCESS_DURATION=1
INITIAL_RESTART_DELAY=1; MAX_RESTART_DELAY=1; RESTART_DELAY=1
log_message() { :; }
log_critical() { :; }
check_parent_alive() { return 0; }
check_device_exists() { return 0; }
check_devices_exist() { return 0; }
run_ffmpeg() { ffmpeg >/dev/null 2>&1 & FFMPEG_PID=$!; return 0; }
CFG
        _extract_restart_loop
    } > "$wrapper"
    bash -n "$wrapper"

    # With MAX_WRAPPER_RESTARTS=2 and the pre-fix lifetime counter, ffmpeg would
    # be launched exactly 2 times and the wrapper would exit. With the reset it
    # keeps going, so >2 calls in the window.
    timeout 12s bash "$wrapper" || true
    local calls
    calls=$(grep -c 'call' "$E2E_TMP/calls.log" 2>/dev/null || echo 0)
    [ "$calls" -gt 2 ]
}
