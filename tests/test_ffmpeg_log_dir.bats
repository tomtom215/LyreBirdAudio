#!/usr/bin/env bats
# Where the per-stream FFmpeg logs are (register: X-51).
#
# The stream manager writes <stream>.log next to its wrapper scripts and PID files:
# MEDIAMTX_FFMPEG_DIR, /var/lib/mediamtx-ffmpeg by default. The diagnostics script
# (FFMPEG_LOG_DIR), the orchestrator's "Logs & Status" item 4 and the shipped
# logrotate file looked in /var/log/lyrebird, where no FFmpeg log is ever written
# (the only file there is the alert log): a healthy node showed "Not found" and
# "No stream logs found". The real scripts are sourced in child processes and asked
# where they look.

load scratch_tmpdir
load orchestrator_helper

setup() {
    scratch_setup
    PROJECT_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
    export PROJECT_ROOT
    orch_setup
    FF="$TEST_SCRATCH/ffmpeg-dir"
    mkdir -p "$FF"
}

teardown() {
    scratch_teardown
}

# the directory each script treats as the FFmpeg log directory, one line each
ffmpeg_dirs() {
    env -u FFMPEG_LOG_DIR -u MEDIAMTX_FFMPEG_DIR "$@" bash -c '
        source "$PROJECT_ROOT/lyrebird-stream-manager.sh" >/dev/null 2>&1; echo "manager=$FFMPEG_PID_DIR"
    '
    env -u FFMPEG_LOG_DIR -u MEDIAMTX_FFMPEG_DIR "$@" bash -c '
        source "$PROJECT_ROOT/lyrebird-diagnostics.sh" >/dev/null 2>&1; echo "diagnostics=$FFMPEG_LOG_DIR"
    '
    env -u FFMPEG_LOG_DIR -u MEDIAMTX_FFMPEG_DIR "$@" bash -c '
        source "$PROJECT_ROOT/lyrebird-orchestrator.sh" >/dev/null 2>&1; echo "orchestrator=$FFMPEG_LOG_DIR"
    '
}

@test "the manager, the diagnostics and the orchestrator name one FFmpeg log directory by default [X-51]" {
    run ffmpeg_dirs
    [ "$status" -eq 0 ]
    [[ "$output" == *"manager=/var/lib/mediamtx-ffmpeg"* ]]
    [[ "$output" == *"diagnostics=/var/lib/mediamtx-ffmpeg"* ]]
    [[ "$output" == *"orchestrator=/var/lib/mediamtx-ffmpeg"* ]]
}

@test "MEDIAMTX_FFMPEG_DIR moves the FFmpeg log directory in all three; FFMPEG_LOG_DIR still overrides the two display scripts [X-51]" {
    run ffmpeg_dirs MEDIAMTX_FFMPEG_DIR="$FF"
    [ "$status" -eq 0 ]
    [[ "$output" == *"manager=$FF"* ]]
    [[ "$output" == *"diagnostics=$FF"* ]]
    [[ "$output" == *"orchestrator=$FF"* ]]

    run env MEDIAMTX_FFMPEG_DIR="$FF" FFMPEG_LOG_DIR="$TEST_SCRATCH/elsewhere" bash -c '
        source "$PROJECT_ROOT/lyrebird-diagnostics.sh" >/dev/null 2>&1; echo "diagnostics=$FFMPEG_LOG_DIR"
    '
    [[ "$output" == *"diagnostics=$TEST_SCRATCH/elsewhere"* ]]
    run env MEDIAMTX_FFMPEG_DIR="$FF" FFMPEG_LOG_DIR="$TEST_SCRATCH/elsewhere" bash -c '
        source "$PROJECT_ROOT/lyrebird-orchestrator.sh" >/dev/null 2>&1; echo "orchestrator=$FFMPEG_LOG_DIR"
    '
    [[ "$output" == *"orchestrator=$TEST_SCRATCH/elsewhere"* ]]
}

@test "the orchestrator takes only a safe absolute path as the FFmpeg log directory [X-51]" {
    local bad
    for bad in 'relative/dir' '/var/lib/../../etc' '/var/lib/with space' '/var/lib/$(touch pwned)' '/tmp/a;b'; do
        run env -u MEDIAMTX_FFMPEG_DIR FFMPEG_LOG_DIR="$bad" bash -c '
            source "$PROJECT_ROOT/lyrebird-orchestrator.sh" >/dev/null 2>&1; echo "dir=$FFMPEG_LOG_DIR"
        '
        [ "$output" = "dir=/var/lib/mediamtx-ffmpeg" ] || {
            echo "accepted: $bad -> $output"
            false
        }
    done
}

@test "the diagnostics log check finds the directory the manager writes its FFmpeg logs to [X-51]" {
    touch "$FF/usb-mic.log"
    run env -u FFMPEG_LOG_DIR MEDIAMTX_FFMPEG_DIR="$FF" bash -c '
        source "$PROJECT_ROOT/lyrebird-diagnostics.sh" >/dev/null 2>&1
        check_log_locations
    '
    [ "$status" -eq 0 ]
    [[ "$output" == *"FFmpeg Log Dir: $FF"* ]]
    [[ "$output" != *"Not found: /var/log/lyrebird"* ]]
    [[ "$output" != *"/var/log/lyrebird"* ]]
}

@test "a manager log that exists tells the diagnostics the manager was installed; the FFmpeg directory holds no such file [X-51]" {
    local pgshim="$TEST_SCRATCH/shim"
    mkdir -p "$pgshim"
    printf '#!/bin/bash\nexit 1\n' >"$pgshim/pgrep"
    printf '#!/bin/bash\nexit 1\n' >"$pgshim/systemctl"
    chmod +x "$pgshim/pgrep" "$pgshim/systemctl"
    # a stream-manager.log in the FFmpeg directory is not what the manager writes
    touch "$FF/stream-manager.log"
    run env PATH="$pgshim:$PATH" MEDIAMTX_FFMPEG_DIR="$FF" STREAM_MANAGER_LOG_FILE="$TEST_SCRATCH/none.log" bash -c '
        source "$PROJECT_ROOT/lyrebird-diagnostics.sh" >/dev/null 2>&1
        get_stream_manager_status
    '
    [ "$output" = "not_configured" ]
    touch "$TEST_SCRATCH/sm.log"
    run env PATH="$pgshim:$PATH" MEDIAMTX_FFMPEG_DIR="$FF" STREAM_MANAGER_LOG_FILE="$TEST_SCRATCH/sm.log" bash -c '
        source "$PROJECT_ROOT/lyrebird-diagnostics.sh" >/dev/null 2>&1
        get_stream_manager_status
    '
    [ "$output" = "stopped" ]
}

@test "Logs & Status item 4 lists the FFmpeg logs the manager wrote, in MEDIAMTX_FFMPEG_DIR [X-51]" {
    touch "$FF/usb-mic-one.log" "$FF/usb-mic-two.log"
    export MEDIAMTX_FFMPEG_DIR="$FF"
    unset FFMPEG_LOG_DIR
    orch_run --step 'Select option' '4\n' --step 'Press Enter' '\n' --step 'Select option' '0\n' 'menu_logs_status'
    [ "$status" -eq 0 ] || {
        echo "$output"
        false
    }
    [[ "$output" == *"usb-mic-one.log"* ]]
    [[ "$output" == *"usb-mic-two.log"* ]]
    [[ "$output" != *"No stream logs found"* ]]
    [[ "$output" != *"Stream log directory not found"* ]]
}

@test "the shipped logrotate file rotates the directory the alert log is written to and does not call it the FFmpeg log directory [X-51]" {
    local conf="$PROJECT_ROOT/config/lyrebird-logrotate.conf" alert_dir
    alert_dir="$(env -u LYREBIRD_ALERT_LOG bash -c 'source "$PROJECT_ROOT/lyrebird-alerts.sh" >/dev/null 2>&1; dirname -- "$ALERT_LOG_FILE"')"
    [ "$alert_dir" = "/var/log/lyrebird" ]
    # the stanza that rotates the alert log's directory stays
    grep -qxF "$alert_dir/*.log {" "$conf"
    # and no comment above it claims FFmpeg logs are in that directory
    local block
    block="$(awk -v want="$alert_dir/*.log {" '
        /^#/ { c = c $0 "\n"; next }
        /^$/ { c = ""; next }
        $0 == want { printf "%s", c; exit }
        { c = "" }
    ' "$conf")"
    [[ "$block" == *"alerts.log"* ]]
    [[ "$block" != *"FFmpeg per-device logs"* ]]
    # the manager's FFmpeg directory is not listed a second time next to the file
    # `install` writes (that one rotates ${FFMPEG_PID_DIR}/*.log)
    ! grep -vE '^[[:space:]]*#' "$conf" | grep -qF 'mediamtx-ffmpeg'
}

@test "install's logrotate file rotates the FFmpeg logs where the manager writes them [X-51]" {
    local root="$TEST_SCRATCH/sysroot" shim="$TEST_SCRATCH/lrshim"
    mkdir -p "$root/etc/logrotate.d" "$root/etc/systemd/system" "$root/etc/cron.d" "$shim"
    printf '#!/bin/bash\nexit 0\n' >"$shim/logrotate"
    printf '#!/bin/bash\nexit 0\n' >"$shim/systemctl"
    chmod +x "$shim/logrotate" "$shim/systemctl"
    run env PATH="$shim:$PATH" LYREBIRD_SYSROOT="$root" MEDIAMTX_FFMPEG_DIR="$FF" \
        bash "$PROJECT_ROOT/lyrebird-stream-manager.sh" install </dev/null
    [ "$status" -eq 0 ] || {
        echo "$output"
        false
    }
    grep -qxF "$FF/*.log {" "$root/etc/logrotate.d/mediamtx"
}

# The log paths a logrotate file lists, one per line (the lines before each "{", comments
# and the directives inside the braces left out)
stanza_logs() {
    awk '
        /^[[:space:]]*#/ { next }
        /^[[:space:]]*$/ { next }
        inside { if ($0 ~ /}/) inside = 0; next }
        {
            line = $0
            if (line ~ /\{[[:space:]]*$/) { sub(/[[:space:]]*\{[[:space:]]*$/, "", line); inside = 1 }
            n = split(line, parts, /[[:space:]]+/)
            for (i = 1; i <= n; i++) if (parts[i] != "") print parts[i]
        }' "$1"
}

@test "every log file is rotated by exactly one logrotate file: the shipped one and the one install writes list no log in common [X-51]" {
    local root="$TEST_SCRATCH/lrroot" shim="$TEST_SCRATCH/lrshim2" conf="$TEST_SCRATCH/lrconf"
    local real_logrotate
    real_logrotate="$(command -v logrotate || true)"
    mkdir -p "$root/etc/logrotate.d" "$root/etc/systemd/system" "$root/etc/cron.d" "$shim" "$conf"
    printf '#!/bin/bash\nexit 0\n' >"$shim/logrotate"
    printf '#!/bin/bash\nexit 0\n' >"$shim/systemctl"
    chmod +x "$shim/logrotate" "$shim/systemctl"
    # install's file for the DEFAULT locations (the ones the shipped file names): the manager
    # sourced with its own defaults and its log silenced, so nothing is written outside the root
    run env -u MEDIAMTX_LOG_FILE -u STREAM_MANAGER_LOG_FILE -u MEDIAMTX_FFMPEG_DIR -u MEDIAMTX_CONFIG_DIR \
        -u MEDIAMTX_PID_FILE -u MEDIAMTX_LOCK_FILE LYREBIRD_SYSROOT="$root" PATH="$shim:$PATH" bash -c '
        source "$PROJECT_ROOT/lyrebird-stream-manager.sh" >/dev/null 2>&1
        log() { :; }
        create_systemd_service >/dev/null 2>&1; echo "install rc=$?"'
    [[ "$output" == *"install rc=0"* ]]
    install -m 0644 "$root/etc/logrotate.d/mediamtx" "$conf/mediamtx"
    install -m 0644 "$PROJECT_ROOT/config/lyrebird-logrotate.conf" "$conf/lyrebird"

    local installed shipped
    installed="$(stanza_logs "$conf/mediamtx")"
    shipped="$(stanza_logs "$conf/lyrebird")"
    [ -n "$installed" ] && [ -n "$shipped" ]
    # no log is listed by both
    run comm -12 <(sort <<<"$installed") <(sort <<<"$shipped")
    [ -z "$output" ] || {
        echo "listed by both files: $output"
        false
    }
    # and none of the logs the scripts write is lost: each is listed once, by one of the two
    local want
    for want in /var/log/mediamtx.out /var/log/lyrebird-stream-manager.log '/var/lib/mediamtx-ffmpeg/*.log' \
        '/var/log/lyrebird/*.log' /var/log/lyrebird-orchestrator.log /var/log/lyrebird-updater.log \
        /var/log/lyrebird-diagnostics.log /var/log/usb-audio-mapper.log; do
        [ "$(printf '%s\n%s\n' "$installed" "$shipped" | grep -cxF -- "$want")" -eq 1 ] || {
            echo "$want is not listed exactly once"
            false
        }
    done

    # logrotate itself, where this machine has it: no duplicate entry, and each log considered once
    if [[ -z "$real_logrotate" ]]; then
        skip "logrotate is not installed; the lists above were compared without it"
    fi
    run "$real_logrotate" -d -s "$TEST_SCRATCH/logrotate.state" "$conf/mediamtx" "$conf/lyrebird"
    [[ "$output" != *"duplicate log entry"* ]] || {
        echo "$output"
        false
    }
    for want in /var/log/mediamtx.out /var/log/lyrebird-stream-manager.log '/var/lib/mediamtx-ffmpeg/*.log' '/var/log/lyrebird/alerts.log'; do
        [ "$(grep -cxF -- "considering log ${want}" <<<"$output")" -eq 1 ] || {
            echo "${want} is not considered exactly once"
            echo "$output"
            false
        }
    done
}
