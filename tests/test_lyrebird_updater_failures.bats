#!/usr/bin/env bats
# lyrebird-updater.sh against real git repositories and injected failures: a
# local bare origin, a node that is a clone of it, PATH shims for git (kill,
# signal, DNS failure at a chosen point of an update) and a re-rooted system
# tree (LYREBIRD_UPDATER_SYSROOT), so a full update runs without touching the
# host. See tests/updater_helper.bash for the fixture and its tags.

load bats_shell_state
load scratch_tmpdir
load updater_helper

setup_file() {
    updater_template_build
}

setup() {
    scratch_setup
    updater_node_setup
}

teardown() {
    scratch_teardown
}

# source the script under test in a throw-away shell and print variables
_updater_vars() {
    env "$@" bash -c 'source "$1"; shift; for v in "$@"; do printf "%s=%s\n" "$v" "${!v}"; done' _ \
        "$REPO/lyrebird-updater.sh" "${VARS[@]}"
}

# ============================================================================
# Configuration knobs
# ============================================================================

@test "LYREBIRD_UPDATER_SYSROOT re-roots every system path the updater touches" {
    VARS=(SERVICE_FILE SERVICE_CRON_FILE SERVICE_UPDATE_MARKER MIGRATION_MARKER_DIR
        OLD_STREAM_MANAGER_LOG NEW_STREAM_MANAGER_LOG STREAM_MANAGER_BIN_DIR)
    run _updater_vars LYREBIRD_UPDATER_SYSROOT=/tmp/sysroot-x/
    [ "$status" -eq 0 ]
    [[ "$output" == *"SERVICE_FILE=/tmp/sysroot-x/etc/systemd/system/mediamtx-audio.service"* ]]
    [[ "$output" == *"SERVICE_CRON_FILE=/tmp/sysroot-x/etc/cron.d/mediamtx-monitor"* ]]
    [[ "$output" == *"SERVICE_UPDATE_MARKER=/tmp/sysroot-x/run/lyrebird-service-update.marker"* ]]
    [[ "$output" == *"MIGRATION_MARKER_DIR=/tmp/sysroot-x/var/lib/lyrebird/migrations"* ]]
    [[ "$output" == *"OLD_STREAM_MANAGER_LOG=/tmp/sysroot-x/var/log/mediamtx-stream-manager.log"* ]]
    [[ "$output" == *"NEW_STREAM_MANAGER_LOG=/tmp/sysroot-x/var/log/lyrebird-stream-manager.log"* ]]
    [[ "$output" == *"STREAM_MANAGER_BIN_DIR=/tmp/sysroot-x/usr/local/bin"* ]]
}

@test "without LYREBIRD_UPDATER_SYSROOT the paths are the real system paths" {
    VARS=(SERVICE_FILE SERVICE_UPDATE_MARKER MIGRATION_MARKER_DIR STREAM_MANAGER_BIN_DIR)
    run _updater_vars LYREBIRD_UPDATER_SYSROOT=
    [ "$status" -eq 0 ]
    [[ "$output" == *"SERVICE_FILE=/etc/systemd/system/mediamtx-audio.service"* ]]
    [[ "$output" == *"SERVICE_UPDATE_MARKER=/run/lyrebird-service-update.marker"* ]]
    [[ "$output" == *"MIGRATION_MARKER_DIR=/var/lib/lyrebird/migrations"* ]]
    [[ "$output" == *"STREAM_MANAGER_BIN_DIR=/usr/local/bin"* ]]
}

@test "fetch and lock tuning variables are honoured; invalid values fall back to the defaults" {
    VARS=(FETCH_TIMEOUT FETCH_RETRIES FETCH_RETRY_DELAY LOCK_MAX_WAIT)
    run _updater_vars LYREBIRD_FETCH_TIMEOUT=7 LYREBIRD_FETCH_RETRIES=5 LYREBIRD_FETCH_RETRY_DELAY=9 \
        LYREBIRD_UPDATER_LOCK_WAIT=2
    [ "$status" -eq 0 ]
    [[ "$output" == *"FETCH_TIMEOUT=7"* && "$output" == *"FETCH_RETRIES=5"* ]]
    [[ "$output" == *"FETCH_RETRY_DELAY=9"* && "$output" == *"LOCK_MAX_WAIT=2"* ]]
    local bad
    for bad in abc 0 -3 "" 1.5; do
        run _updater_vars LYREBIRD_FETCH_TIMEOUT="$bad" LYREBIRD_FETCH_RETRIES="$bad" \
            LYREBIRD_FETCH_RETRY_DELAY="$bad" LYREBIRD_UPDATER_LOCK_WAIT="$bad"
        [ "$status" -eq 0 ]
        [[ "$output" == *"FETCH_TIMEOUT=30"* && "$output" == *"FETCH_RETRIES=3"* ]] || { echo "bad=$bad: $output"; return 1; }
        [[ "$output" == *"FETCH_RETRY_DELAY=2"* && "$output" == *"LOCK_MAX_WAIT=30"* ]]
    done
}
