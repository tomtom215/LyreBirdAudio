#!/usr/bin/env bats
# Validation of the shipped sample config files (systemd units + logrotate).
# These files are documented for operators to `cp` into place, so a broken
# sample is a real 24/7 hazard (restart loops, ineffective log rotation).

setup() {
    TEST_DIR="$( cd "$( dirname "$BATS_TEST_FILENAME" )" && pwd )"
    PROJECT_ROOT="$( cd "$TEST_DIR/.." && pwd )"
    CFG="$PROJECT_ROOT/config"
}

# --- systemd watchdog must not be set (CFG-1 / CFG-2) ------------------------

@test "mediamtx.service sets no active WatchdogSec (MediaMTX can't feed it) [CFG-1]" {
    run grep -E '^[[:space:]]*WatchdogSec=' "$CFG/mediamtx.service"
    [ "$status" -ne 0 ]     # no uncommented WatchdogSec directive
}

@test "mediamtx-audio.service sets no active WatchdogSec [CFG-2]" {
    run grep -E '^[[:space:]]*WatchdogSec=' "$CFG/mediamtx-audio.service"
    [ "$status" -ne 0 ]
}

# --- the audio unit must be Type=forking with a PIDFile (CFG-2) --------------

@test "mediamtx-audio.service is Type=forking with a PIDFile (start daemonizes) [CFG-2]" {
    grep -qE '^Type=forking$' "$CFG/mediamtx-audio.service"
    grep -qE '^PIDFile=' "$CFG/mediamtx-audio.service"
    # Type=simple would make systemd treat the forking `start` as an exit -> loop.
    run grep -qE '^Type=simple$' "$CFG/mediamtx-audio.service"
    [ "$status" -ne 0 ]
}

# --- StartLimit* must be in [Unit], not [Service] (systemd ignores it there) --

@test "StartLimitIntervalSec is not placed in a [Service] section" {
    # For each unit, ensure no StartLimitIntervalSec appears after the [Service]
    # header (awk tracks the current section).
    for unit in mediamtx.service mediamtx-audio.service; do
        run awk '
            /^\[Service\]/ { insvc=1 }
            /^\[/ && !/^\[Service\]/ { insvc=0 }
            insvc && /^StartLimitIntervalSec=/ { print; found=1 }
            END { exit found }
        ' "$CFG/$unit"
        [ "$status" -eq 0 ]     # awk exit 0 => not found in [Service]
    done
}

# --- logrotate must copytruncate the held-open logs (CFG-3) ------------------

@test "logrotate uses copytruncate for MediaMTX/manager/ffmpeg logs [CFG-3]" {
    # The three held-open logs must copytruncate (create+signal can't reopen them).
    grep -q 'copytruncate' "$CFG/lyrebird-logrotate.conf"
    # And must NOT try to signal a reopen that cannot work (active directives
    # only -- explanatory comments mentioning the old approach are fine).
    run bash -c "grep -vE '^[[:space:]]*#' '$CFG/lyrebird-logrotate.conf' | grep -E 'kill.*-HUP|pkill.*-USR1'"
    [ "$status" -ne 0 ]
}

# --- systemd-analyze verify (only if the tool is present) --------------------

@test "systemd-analyze verify reports no unknown/ignored keys [config]" {
    command -v systemd-analyze >/dev/null 2>&1 || skip "systemd-analyze not available"
    for unit in mediamtx.service mediamtx-audio.service; do
        # Ignore the expected "command not executable" (binaries absent in CI).
        run bash -c "systemd-analyze verify '$CFG/$unit' 2>&1 | grep -iE 'Unknown key|ignoring'"
        [ "$status" -ne 0 ]
    done
}
