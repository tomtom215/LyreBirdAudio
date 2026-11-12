#!/usr/bin/env bats
# Features lyrebird-stream-manager.sh claimed and never implemented, and what is
# left of them (register: LB-15, X-13 manager side, LB-16; decisions D7, D8).
#
# The real script is sourced (or run) in a fresh bash for every call and the real
# functions run; nothing here re-implements one. Hardware that the code would
# have touched is a FIFO (a watchdog device stand-in whose opening is visible).

load scratch_tmpdir

setup() {
    scratch_setup
    TEST_DIR="$(cd "$(dirname "$BATS_TEST_FILENAME")" && pwd)"
    PROJECT_ROOT="$(cd "$TEST_DIR/.." && pwd)"
    RF="$TEST_SCRATCH/rf"
    mkdir -p "$RF"/{bin,ff,cfg,state}
    BG_PIDS=()
    export PROJECT_ROOT RF
    export MEDIAMTX_CONFIG_DIR="$RF/cfg" MEDIAMTX_FFMPEG_DIR="$RF/ff" MEDIAMTX_PID_FILE="$RF/mtx.pid"
    export MEDIAMTX_LOCK_FILE="$RF/run.lock" MEDIAMTX_LOG_FILE="$RF/sm.log" STREAM_MANAGER_LOG_FILE="$RF/sm.log"
    export MEDIAMTX_RESTART_MARKER="$RF/restart.marker" MEDIAMTX_CLEANUP_MARKER="$RF/cleanup.marker"
    export CRON_RESTART_STATE_DIR="$RF/cron" DEEP_HEALTH_STATE_DIR="$RF/deep" SILENCE_STATE_DIR="$RF/silence"
    export MEM_SAMPLE_FILE="$RF/ff/.mem_samples" NETWORK_CHECK_ENABLED=false
    export HEARTBEAT_FILE="$RF/heartbeat" MEDIAMTX_HOST=removed.invalid
    SCRIPT="$PROJECT_ROOT/lyrebird-stream-manager.sh"
}

teardown() {
    local pid
    for pid in "${BG_PIDS[@]:-}"; do
        [[ -n "$pid" ]] && kill -9 "$pid" 2>/dev/null || true
    done
    scratch_teardown
}

# The six variables of the removed watchdog implementation
WD_VARS=(HEARTBEAT_INTERVAL HARDWARE_WATCHDOG_TIMEOUT ENABLE_HARDWARE_WATCHDOG HARDWARE_WATCHDOG_DEVICE LYREBIRD_WATCHDOG_ENABLED LYREBIRD_WATCHDOG_INTERVAL)

count_log() { grep -c -- "$1" "$RF/sm.log" 2>/dev/null || true; }

# The manager's own non-comment lines, without the function that names the removed settings
code_without_removed_settings_warning() {
    awk '/^warn_removed_settings\(\) \{/ {skip=1} !skip {print} skip && /^}/ {skip=0}' "$SCRIPT" | grep -v '^[[:space:]]*#'
}

static_hits() { code_without_removed_settings_warning | grep -n -i -E "$1"; }

# ---------------------------------------------------------------------------
# D7: no watchdog (LB-15)
# ---------------------------------------------------------------------------

@test "the watchdog and heartbeat-interval settings and functions no longer exist [LB-15, D7]" {
    run env -u HEARTBEAT_INTERVAL -u HARDWARE_WATCHDOG_TIMEOUT -u ENABLE_HARDWARE_WATCHDOG -u HARDWARE_WATCHDOG_DEVICE \
        bash -c '
        source "$1" >/dev/null 2>&1
        for f in init_hardware_watchdog kick_hardware_watchdog; do
            ! declare -F "$f" >/dev/null || { echo "$f still exists"; exit 1; }
        done
        for v in HEARTBEAT_INTERVAL HARDWARE_WATCHDOG_TIMEOUT ENABLE_HARDWARE_WATCHDOG HARDWARE_WATCHDOG_DEVICE; do
            ! declare -p "$v" >/dev/null 2>&1 || { echo "$v is still defined"; exit 1; }
        done
        # the heartbeat file stays: it is the last-monitor-run time that lyrebird-metrics reads
        declare -p HEARTBEAT_FILE >/dev/null
        declare -F update_heartbeat >/dev/null
        echo gone' _ "$SCRIPT"
    [ "$status" -eq 0 ]
    [ "$output" = "gone" ]
}

@test "no executable line of the manager opens a watchdog device or talks to systemd's notify socket [LB-15, D7]" {
    # the control: the pattern does match the script, in the warning that names the removed settings
    run grep -c -i -E '/dev/watchdog|NOTIFY_SOCKET|systemd-notify|WATCHDOG' "$SCRIPT"
    [ "$status" -eq 0 ]
    run static_hits '/dev/watchdog|NOTIFY_SOCKET|systemd-notify|WATCHDOG|USR2'
    [ "$status" -eq 1 ]
    [ -z "$output" ]
}

@test "the removed settings in the environment are named once per run, with their replacement; unset, nothing is said [LB-15, D7]" {
    local env_args=() v
    for v in "${WD_VARS[@]}"; do env_args+=("$v=1"); done
    run env "${env_args[@]}" bash "$SCRIPT" help
    [ "$status" -eq 0 ]
    local lines
    lines="$(grep -c "Ignoring removed setting" <<<"$output" || true)"
    [ "$lines" -eq 1 ]
    for v in "${WD_VARS[@]}"; do
        [[ "$output" == *"$v"* ]]
    done
    [[ "$output" == *"RuntimeWatchdogSec="* ]]
    [ "$(count_log 'Ignoring removed setting')" -eq 1 ]

    # one of them, set to an empty string, still counts as set; the others are not named
    run env HEARTBEAT_INTERVAL= bash "$SCRIPT" help
    [ "$(grep -c "Ignoring removed setting(s): HEARTBEAT_INTERVAL\." <<<"$output" || true)" -eq 1 ]

    # none of them: no warning
    run env -u HEARTBEAT_INTERVAL -u HARDWARE_WATCHDOG_TIMEOUT -u ENABLE_HARDWARE_WATCHDOG -u HARDWARE_WATCHDOG_DEVICE \
        -u LYREBIRD_WATCHDOG_ENABLED -u LYREBIRD_WATCHDOG_INTERVAL bash "$SCRIPT" help
    [ "$status" -eq 0 ]
    [[ "$output" != *"Ignoring removed setting"* ]]
}

@test "the removed-settings warning is logged once even when the function runs twice in a process [LB-15, D7]" {
    run env ENABLE_HARDWARE_WATCHDOG=yes bash -c 'source "$1" >/dev/null 2>&1; warn_removed_settings; warn_removed_settings; warn_removed_settings' _ "$SCRIPT"
    [ "$status" -eq 0 ]
    [ "$(count_log 'Ignoring removed setting')" -eq 1 ]
}

@test "with the old watchdog settings in the environment the monitor path never opens the configured device [LB-15, D7]" {
    # A FIFO is the device: a writer's open() would complete a reader's open() and the byte would arrive
    mkfifo "$RF/wd"
    cat "$RF/wd" >"$RF/wd.got" &
    BG_PIDS+=("$!")
    local reader=$!
    # (timeout: code that did write to the FIFO would block on its second open, with no reader left)
    run timeout 20 env HARDWARE_WATCHDOG_ACTIVE=true ENABLE_HARDWARE_WATCHDOG=yes HARDWARE_WATCHDOG_DEVICE="$RF/wd" \
        HARDWARE_WATCHDOG_TIMEOUT=5 HEARTBEAT_INTERVAL=5 bash -c '
        source "$1" >/dev/null 2>&1
        check_all_resources || true
        update_heartbeat
        update_heartbeat' _ "$SCRIPT"
    [ "$status" -eq 0 ]
    sleep 0.5
    # nothing opened the FIFO: the reader is still blocked in open() and has read nothing
    kill -0 "$reader"
    [ ! -s "$RF/wd.got" ]
    [ -s "$HEARTBEAT_FILE" ]
}

@test "SIGUSR2 no longer writes the heartbeat: only a monitor run does [LB-15, X-13, D7]" {
    run grep -n "USR2" "$SCRIPT"
    [ "$status" -eq 1 ]
}

# ---------------------------------------------------------------------------
# D7 / X-13 (manager side): the heartbeat is the time of the last monitor run
# ---------------------------------------------------------------------------

@test "update_heartbeat writes one line, the Unix time of the call, atomically [LB-15, X-13]" {
    local before after
    before="$(date +%s)"
    run bash -c 'source "$1" >/dev/null 2>&1; update_heartbeat' _ "$SCRIPT"
    after="$(date +%s)"
    [ "$status" -eq 0 ]
    [ "$(wc -l <"$HEARTBEAT_FILE")" -eq 1 ]
    local content mtime
    content="$(cat "$HEARTBEAT_FILE")"
    [[ "$content" =~ ^[0-9]+$ ]]
    [ "$content" -ge "$before" ]
    [ "$content" -le "$after" ]
    mtime="$(stat -c %Y "$HEARTBEAT_FILE")"
    [ "$mtime" -ge "$before" ]
    [ "$mtime" -le "$((after + 1))" ]
    [ ! -e "${HEARTBEAT_FILE}.tmp" ]
}

@test "update_heartbeat creates the directory, rewrites an older heartbeat and reports an unwritable one without failing [LB-15, X-13]" {
    echo 1000 >"$HEARTBEAT_FILE"
    run bash -c 'source "$1" >/dev/null 2>&1; update_heartbeat' _ "$SCRIPT"
    [ "$(cat "$HEARTBEAT_FILE")" -gt 1000 ]
    rm -f "$HEARTBEAT_FILE"
    run env HEARTBEAT_FILE="$RF/newdir/deeper/hb" bash -c 'source "$1" >/dev/null 2>&1; update_heartbeat' _ "$SCRIPT"
    [ "$status" -eq 0 ]
    [ -s "$RF/newdir/deeper/hb" ]
    # a regular file where the directory should be
    printf x >"$RF/blocker"
    run env HEARTBEAT_FILE="$RF/blocker/hb" bash -c 'set -euo pipefail; source "$1" >/dev/null 2>&1; update_heartbeat; echo "rc=$?"' _ "$SCRIPT"
    [ "$status" -eq 0 ]
    [[ "$output" == *"rc=0" ]]
    [ "$(count_log 'Cannot write the monitor heartbeat')" -eq 1 ]
}

@test "the monitor command writes the heartbeat exactly once per run, also while MediaMTX is down [LB-15, X-13]" {
    # every move into place of the heartbeat is recorded by a mv shim that runs the real mv
    cat >"$RF/bin/mv" <<'SHIM'
#!/bin/bash
case "$*" in *"$HEARTBEAT_FILE"*) echo "$*" >>"$RF/mv.heartbeat" ;; esac
exec /bin/mv "$@"
SHIM
    chmod +x "$RF/bin/mv"
    # MediaMTX is down: there is no PID file
    [ ! -e "$MEDIAMTX_PID_FILE" ]
    local before after
    before="$(date +%s)"
    run env PATH="$RF/bin:$PATH" bash -c '
        source "$1" >/dev/null 2>&1
        check_root() { :; }
        setup_directories() { :; }
        monitor_signals() { :; }
        monitor_streams() { return "${E_MEDIAMTX_DOWN}"; }
        main monitor' _ "$SCRIPT"
    after="$(date +%s)"
    [ "$status" -eq 7 ]
    [ "$(grep -c . "$RF/mv.heartbeat")" -eq 1 ]
    local content
    content="$(cat "$HEARTBEAT_FILE")"
    [ "$content" -ge "$before" ]
    [ "$content" -le "$after" ]
    # a second run writes a second heartbeat, not more
    sleep 1
    run env PATH="$RF/bin:$PATH" bash -c '
        source "$1" >/dev/null 2>&1
        check_root() { :; }
        setup_directories() { :; }
        monitor_signals() { :; }
        monitor_streams() { return 0; }
        main monitor' _ "$SCRIPT"
    [ "$status" -eq 0 ]
    [ "$(grep -c . "$RF/mv.heartbeat")" -eq 2 ]
    [ "$(cat "$HEARTBEAT_FILE")" -gt "$content" ]
}

@test "the heartbeat the monitor writes is healthy for lyrebird-metrics, and one older than LYREBIRD_HEARTBEAT_MAX_AGE is not [LB-15, X-13]" {
    run bash -c 'source "$1" >/dev/null 2>&1; update_heartbeat' _ "$SCRIPT"
    [ "$status" -eq 0 ]
    local metrics_env=(HEARTBEAT_FILE="$HEARTBEAT_FILE" MEDIAMTX_HOST=metrics.invalid PID_FILE="$RF/none.pid"
        FFMPEG_PID_DIR="$RF/none" MEDIAMTX_CONFIG_DIR="$RF/none-cfg")
    run env "${metrics_env[@]}" bash "$PROJECT_ROOT/lyrebird-metrics.sh" --once
    [[ "$output" == *$'\nlyrebird_heartbeat_healthy 1\n'* ]]
    echo "$(($(date +%s) - 1000))" >"$HEARTBEAT_FILE"
    run env "${metrics_env[@]}" bash "$PROJECT_ROOT/lyrebird-metrics.sh" --once
    [[ "$output" == *$'\nlyrebird_heartbeat_healthy 0\n'* ]]
}

# ---------------------------------------------------------------------------
# D8: no disk-persistence switch (LB-16)
# ---------------------------------------------------------------------------

@test "AUDIO_DISK_PERSIST and AUDIO_DISK_PATH are no longer read or handled by any executable line [LB-16, D8]" {
    run grep -c -E 'AUDIO_DISK_(PERSIST|PATH)' "$SCRIPT"
    [ "$status" -eq 0 ] # the control: the names are in the script, in the warning and the comment that explain the removal
    run static_hits 'AUDIO_DISK|disk recording directory|persistence'
    [ "$status" -eq 1 ]
    [ -z "$output" ]
    run env -u AUDIO_DISK_PERSIST -u AUDIO_DISK_PATH bash -c '
        source "$1" >/dev/null 2>&1
        ! declare -p AUDIO_DISK_PERSIST >/dev/null 2>&1 && ! declare -p AUDIO_DISK_PATH >/dev/null 2>&1 && echo gone' _ "$SCRIPT"
    [ "$output" = "gone" ]
}

@test "setup_directories creates the recording directory and never AUDIO_DISK_PATH, with AUDIO_DISK_PERSIST=true [LB-16, D8]" {
    run env AUDIO_LOCAL_RECORDING=true AUDIO_RECORDING_PATH="$RF/recording" AUDIO_DISK_PERSIST=true AUDIO_DISK_PATH="$RF/disk-recordings" \
        MEDIAMTX_LOG_FILE="$RF/logs/sm.log" STREAM_MANAGER_LOG_FILE="$RF/logs/sm.log" bash -c '
        source "$1" >/dev/null 2>&1
        setup_mediamtx_logrotate() { :; }   # would write /etc/logrotate.d on a host that has logrotate
        setup_directories
        echo "rc=$?"' _ "$SCRIPT"
    [ "$status" -eq 0 ]
    [[ "$output" == *"rc=0" ]]
    [ -d "$RF/recording" ]
    [ ! -e "$RF/disk-recordings" ]
}

@test "the removed disk-persistence settings are named once per run, with where durable recording goes [LB-16, D8]" {
    run env AUDIO_DISK_PERSIST=true AUDIO_DISK_PATH=/srv/recordings bash "$SCRIPT" help
    [ "$status" -eq 0 ]
    [ "$(grep -c "Ignoring removed setting" <<<"$output" || true)" -eq 1 ]
    [[ "$output" == *"Ignoring removed setting(s): AUDIO_DISK_PERSIST, AUDIO_DISK_PATH."* ]]
    [[ "$output" == *"RAM-only by default"* ]]
    [[ "$output" == *"point AUDIO_RECORDING_PATH at persistent storage"* ]]
    [ "$(count_log 'Ignoring removed setting')" -eq 1 ]

    # either one alone is enough
    run env AUDIO_DISK_PATH=/srv/recordings bash "$SCRIPT" help
    [[ "$output" == *"Ignoring removed setting(s): AUDIO_DISK_PATH."* ]]

    # the watchdog group and the disk group each warn once
    run env AUDIO_DISK_PERSIST=true ENABLE_HARDWARE_WATCHDOG=yes bash "$SCRIPT" help
    [ "$(grep -c "Ignoring removed setting" <<<"$output" || true)" -eq 2 ]

    # unset: nothing
    run env -u AUDIO_DISK_PERSIST -u AUDIO_DISK_PATH bash "$SCRIPT" help
    [[ "$output" != *"AUDIO_DISK"* ]]
}

@test "recording stays RAM-only by default: the default path is tmpfs and no wrapper code names a disk path [LB-16, D8]" {
    run env -u AUDIO_RECORDING_PATH bash -c 'source "$1" >/dev/null 2>&1; echo "$AUDIO_RECORDING_PATH"' _ "$SCRIPT"
    [ "$output" = "/dev/shm/lyrebird-buffer" ]
    # the wrapper generators write the segments to AUDIO_RECORDING_PATH, and know no other recording path
    run bash -c 'source "$1" >/dev/null 2>&1; declare -f start_ffmpeg_stream start_ffmpeg_multiplex_stream' _ "$SCRIPT"
    [ "$status" -eq 0 ]
    [[ "$output" == *'${AUDIO_RECORDING_PATH}/${STREAM_PATH}'* ]]
    [[ "$output" != *DISK* ]]
}
