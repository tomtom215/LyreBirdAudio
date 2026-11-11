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

# ============================================================================
# The updater's own lock must not be part of the working tree
# ============================================================================

@test "the updater lock is not an untracked file: a pristine clone reports no local modifications" {
    updater_checkout v1.1.0
    updater_run --status
    [ "$status" -eq 0 ]
    [[ "$output" == *"Ready (no local modifications)"* ]]
    [ -z "$(git -C "$REPO" status --porcelain)" ]
    [ ! -e "$REPO/.lyrebird-updater.lock" ]
}

@test "the lock is still held while the working tree is switched, even with local changes stashed" {
    updater_checkout v1.1.0
    echo "local edit" >>"$REPO/config.txt"
    echo "notes" >"$REPO/mynotes.txt"
    export FAULT_PROBE_PATH="$REPO/.git/lyrebird-updater/lock"
    updater_inject checkout before PROBE
    updater_stdin 3 v1.2.0 y "" q
    updater_run
    [ "$status" -eq 0 ]
    [ "$(updater_head)" = "v1.2.0" ]
    grep -q "probe present $FAULT_PROBE_PATH" "$FAULT_LOG"
    # and it is released again at exit
    [ ! -e "$FAULT_PROBE_PATH" ]
}

@test "a self-update restores local changes and leaves no stash entry behind" {
    updater_checkout v1.1.0
    echo "local edit" >>"$REPO/config.txt"
    echo "notes" >"$REPO/mynotes.txt"
    updater_stdin 3 v1.3.0 y "" q
    updater_run
    [ "$status" -eq 0 ]
    [[ "$output" == *"Restarting with updated version"* ]]
    [ "$(updater_head)" = "v1.3.0" ]
    [ -z "$(git -C "$REPO" stash list)" ]
    grep -qx "local edit" "$REPO/config.txt"
    [ -f "$REPO/mynotes.txt" ]
}

@test "a self-update on a clean node does not stash anything" {
    updater_checkout v1.1.0
    updater_stdin 3 v1.3.0 "" q
    updater_run
    [ "$status" -eq 0 ]
    [ "$(updater_head)" = "v1.3.0" ]
    [ -z "$(git -C "$REPO" stash list)" ]
}

@test "a lock directory left in the working tree by an older updater is cleaned up" {
    updater_checkout v1.1.0
    mkdir "$REPO/.lyrebird-updater.lock"
    echo 2147483646 >"$REPO/.lyrebird-updater.lock/pid"
    updater_run --status
    [ "$status" -eq 0 ]
    [ ! -e "$REPO/.lyrebird-updater.lock" ]
    [[ "$output" == *"Ready (no local modifications)"* ]]
}

@test "a live older updater holding the in-tree lock is honoured (exit 7)" {
    updater_checkout v1.1.0
    ( exec -a "lyrebird-updater.sh" sleep 30 ) &
    local holder=$!
    mkdir "$REPO/.lyrebird-updater.lock"
    echo "$holder" >"$REPO/.lyrebird-updater.lock/pid"
    LYREBIRD_UPDATER_LOCK_WAIT=1 updater_run --status
    kill "$holder" 2>/dev/null || true
    wait "$holder" 2>/dev/null || true
    [ "$status" -eq 7 ]
    [[ "$output" == *"older"* ]]
}

@test "a second updater is refused while the first holds the lock (exit 7)" {
    updater_checkout v1.1.0
    mkdir -p "$REPO/.git/lyrebird-updater/lock"
    ( exec -a "lyrebird-updater.sh" sleep 30 ) &
    local holder=$!
    echo "$holder" >"$REPO/.git/lyrebird-updater/lock/pid"
    LYREBIRD_UPDATER_LOCK_WAIT=1 updater_run --status
    kill "$holder" 2>/dev/null || true
    wait "$holder" 2>/dev/null || true
    [ "$status" -eq 7 ]
    [[ "$output" == *"Lock held by process $holder"* ]]
}
