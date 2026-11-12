#!/usr/bin/env bats
# Post-update migrations after a self-update (finding U-19). An update that
# replaces the updater itself hands over to the new updater (--post-update-*);
# that updater must run the migrations of the version it installs, once, and
# the journal (phase "handoff", kept until the hand-over is finished) makes
# a kill -9 before they ran recoverable. The migration used here is the real
# stream-manager rename: it removes the old script from /usr/local/bin,
# installs the new one there and writes a marker file. Real script, real git
# repositories: see tests/updater_helper.bash.

load bats_shell_state
load scratch_tmpdir
load updater_helper

setup_file() {
    updater_template_build
}

setup() {
    scratch_setup
    updater_node_setup
    STATE="$REPO/.git/lyrebird-updater"
    BIN="$SYSROOT/usr/local/bin"
    MARKER="$SYSROOT/var/lib/lyrebird/migrations/stream-manager-rename-v1"
    # a node that was installed under the old script name
    printf '#!/bin/bash\necho old stream manager\n' >"$BIN/mediamtx-stream-manager.sh"
}

teardown() {
    scratch_teardown
}

# how many times a migration ran in OUTPUT
_migration_runs() {
    grep -c 'Running migration: stream-manager-rename' <<<"$output" || true
}

# the migration did its work
_migrated() {
    [ -f "$MARKER" ]
    [ ! -e "$BIN/mediamtx-stream-manager.sh" ]
    [ -x "$BIN/lyrebird-stream-manager.sh" ]
}

# v1.2.2: the updater changes (so updating to it restarts the updater), the stream manager does not
_make_updater_only_tag() {
    git -C "$WORK" checkout -q v1.2.0
    printf '\n# v1.2.2 marker comment\n' >>"$WORK/lyrebird-updater.sh"
    git -C "$WORK" commit -qam "v1.2.2 (updater only)"
    git -C "$WORK" tag v1.2.2
    git -C "$WORK" push -q origin v1.2.2 2>/dev/null
    git -C "$WORK" checkout -q main
    git -C "$REPO" fetch -q origin --tags
}

# ============================================================================
# Which updates run the migrations
# ============================================================================

@test "an update that keeps the updater runs the post-update migrations once" {
    updater_checkout v1.1.0
    updater_stdin 3 v1.2.0 "" q
    updater_run
    [ "$status" -eq 0 ]
    [[ "$output" != *"Restarting with updated version"* ]]
    [ "$(_migration_runs)" -eq 1 ]
    _migrated
}

@test "a self-update runs the migrations of the version it installs, once" {
    updater_checkout v1.1.0
    updater_stdin 3 v1.3.0 "" q
    updater_run
    [ "$status" -eq 0 ]
    [[ "$output" == *"Restarting with updated version"* ]]
    [ "$(updater_head)" = "v1.3.0" ]
    [ "$(_migration_runs)" -eq 1 ]
    _migrated
    # and the hand-over was closed after them
    [ ! -e "$STATE/transaction" ]
    grep -q $'\tupdate\tok\t' "$STATE/history.log"
}

@test "a self-update with saved changes runs the migrations on the tree as the new version left it, before the changes come back" {
    updater_checkout v1.1.0
    _make_updater_only_tag
    updater_checkout v1.2.0
    echo "# local edit" >>"$REPO/lyrebird-stream-manager.sh"
    updater_stdin 3 v1.2.2 y "" q
    updater_run
    [ "$status" -eq 0 ]
    [[ "$output" == *"Restarting with updated version"* ]]
    [ "$(updater_head)" = "v1.2.2" ]
    [ "$(_migration_runs)" -eq 1 ]
    _migrated
    # the installed copy is the version's, not the operator's edited one ...
    ! grep -q "local edit" "$BIN/lyrebird-stream-manager.sh" || false
    # ... and the edit is back in the clone
    grep -q "local edit" "$REPO/lyrebird-stream-manager.sh"
    [ -z "$(git -C "$REPO" stash list)" ]
}

@test "a rollback that restarts the updater runs the migrations once as well" {
    # the node is on v1.3.0 (main); v1.2.0 has another updater script
    updater_run --rollback v1.2.0
    [ "$status" -eq 0 ]
    [ "$(updater_head)" = "v1.2.0" ]
    [[ "$output" == *"Restarting with updated version"* ]]
    [ "$(_migration_runs)" -eq 1 ]
    _migrated
}

@test "migrations that already ran are not run again by a self-update" {
    updater_checkout v1.1.0
    mkdir -p "$(dirname "$MARKER")"
    echo "done earlier" >"$MARKER"
    updater_stdin 3 v1.3.0 "" q
    updater_run
    [ "$status" -eq 0 ]
    [ "$(updater_head)" = "v1.3.0" ]
    [ "$(_migration_runs)" -eq 0 ]
    [ -e "$BIN/mediamtx-stream-manager.sh" ]
    [ "$(cat "$MARKER")" = "done earlier" ]
}

# ============================================================================
# kill -9 between the checkout and the migrations
# ============================================================================

@test "kill -9 of the re-exec'd updater before its migrations: the next run completes the self-update and runs them once" {
    updater_checkout v1.1.0
    updater_install_killat mkdir
    export KILLAT_ARG="$SYSROOT/var/lib/lyrebird/migrations"
    updater_stdin 3 v1.3.0 "" q
    updater_run
    [ "$status" -eq 137 ]
    unset KILLAT_ARG
    # the new version is checked out, nothing was migrated, the journal says the hand-over is not finished
    [ "$(updater_head)" = "v1.3.0" ]
    [ ! -e "$MARKER" ]
    [ -e "$BIN/mediamtx-stream-manager.sh" ]
    grep -q '^phase=handoff$' "$STATE/transaction"
    updater_stdin q
    updater_run
    [ "$status" -eq 0 ]
    [[ "$output" == *"self-update was completed"* ]]
    [ "$(_migration_runs)" -eq 1 ]
    _migrated
    [ ! -e "$STATE/transaction" ]
    grep -q $'\tupdate\tok\t' "$STATE/history.log"
    # and a later run has nothing left to do
    updater_stdin q
    updater_run
    [ "$(_migration_runs)" -eq 0 ]
}

@test "kill -9 in the middle of the migrations: the next run finishes them" {
    updater_checkout v1.1.0
    updater_install_killat cp
    export KILLAT_ARG="$SYSROOT/usr/local/bin/lyrebird-stream-manager.sh"
    updater_stdin 3 v1.3.0 "" q
    updater_run
    [ "$status" -eq 137 ]
    unset KILLAT_ARG
    # half done: the old script is gone, the new one is not installed, no marker
    [ ! -e "$BIN/mediamtx-stream-manager.sh" ]
    [ ! -e "$BIN/lyrebird-stream-manager.sh" ]
    [ ! -e "$MARKER" ]
    updater_stdin q
    updater_run
    [ "$status" -eq 0 ]
    [[ "$output" == *"self-update was completed"* ]]
    [ "$(_migration_runs)" -eq 1 ]
    _migrated
}

@test "kill -9 after the migrations: the next run completes the self-update without running them again" {
    updater_checkout v1.1.0
    echo "precious edit" >>"$REPO/config.txt"
    updater_inject stash-pop before KILL
    updater_stdin 3 v1.3.0 y
    updater_run
    [ "$status" -eq 137 ]
    updater_inject_clear
    _migrated
    [ "$(git -C "$REPO" stash list | wc -l)" -eq 1 ]
    updater_stdin q
    updater_run
    [ "$status" -eq 0 ]
    [[ "$output" == *"self-update was completed"* ]]
    [ "$(_migration_runs)" -eq 0 ]
    grep -qx "precious edit" "$REPO/config.txt"
    [ -z "$(git -C "$REPO" stash list)" ]
}
