#!/usr/bin/env bats
# lyrebird-updater.sh --rollback [VERSION]: back to the previously installed
# version (from the update history) or to a tag/commit already in the clone,
# with the update's own transaction (stash, service handling, journal,
# history) and without the network. Real script, real git repositories: see
# tests/updater_helper.bash.

load bats_shell_state
load scratch_tmpdir
load updater_helper

setup_file() {
    updater_template_build
}

setup() {
    scratch_setup
    updater_node_setup
    HISTORY="$REPO/.git/lyrebird-updater/history.log"
}

teardown() {
    updater_blackhole_stop
    scratch_teardown
}

# one update v1.1.0 -> TARGET through the menu, leaving the node on TARGET
_update_to() {
    updater_checkout v1.1.0
    updater_stdin 3 "$1" "" q
    updater_run
    [ "$status" -eq 0 ]
    [ "$(updater_head)" = "$1" ]
}

# ============================================================================
# Which version it goes back to
# ============================================================================

@test "--rollback with no history refuses (exit 6) and changes nothing" {
    updater_checkout v1.1.0
    updater_run --rollback
    [ "$status" -eq 6 ]
    [[ "$output" == *"no previous version"* ]]
    [ "$(updater_head)" = "v1.1.0" ]
    [ ! -e "$HISTORY" ]
}

@test "--rollback returns to the version the last update came from and records it" {
    _update_to v1.2.0
    updater_run --rollback
    [ "$status" -eq 0 ]
    [ "$(updater_head)" = "v1.1.0" ]
    grep -q 'lyrebird-stream-manager v1.1.0' "$REPO/lyrebird-stream-manager.sh"
    [ ! -e "$REPO/added-in-1.2.0.txt" ]
    updater_git_clean
    [ "$(wc -l <"$HISTORY")" -eq 2 ]
    tail -n1 "$HISTORY" | grep -q $'\trollback\tok\t'
    tail -n1 "$HISTORY" | grep -q $'\tv1.2.0\t'
    [ ! -e "$REPO/.git/lyrebird-updater/transaction" ]
}

@test "--rollback twice goes back and forth between the last two versions" {
    _update_to v1.2.0
    updater_run --rollback
    [ "$status" -eq 0 ]
    [ "$(updater_head)" = "v1.1.0" ]
    updater_run --rollback
    [ "$status" -eq 0 ]
    [ "$(updater_head)" = "v1.2.0" ]
}

@test "--rollback VERSION goes to that tag" {
    _update_to v1.2.0
    updater_run --rollback v1.0.0
    [ "$status" -eq 0 ]
    [ "$(updater_head)" = "v1.0.0" ]
    tail -n1 "$HISTORY" | grep -q $'\trollback\tok\t'
    tail -n1 "$HISTORY" | grep -q $'\tv1.0.0$' || tail -n1 "$HISTORY" | grep -q $'\tv1.0.0\t'
}

@test "--rollback VERSION accepts a commit that is in the clone" {
    _update_to v1.2.0
    local short
    short="$(git -C "$REPO" rev-parse --short v1.0.0^{commit})"
    updater_run --rollback "$short"
    [ "$status" -eq 0 ]
    [ "$(updater_head)" = "v1.0.0" ]
}

@test "--rollback to the version already installed does nothing, named by tag or by commit" {
    _update_to v1.2.0
    updater_run --rollback v1.2.0
    [ "$status" -eq 0 ]
    [[ "$output" == *"Already on"* ]]
    updater_run --rollback "$(git -C "$REPO" rev-parse HEAD)"
    [ "$status" -eq 0 ]
    [[ "$output" == *"nothing to do"* ]]
    [ "$(wc -l <"$HISTORY")" -eq 1 ]
    [ -z "$(git -C "$REPO" stash list)" ]
}

@test "--rollback VERSION for a release that is not in the clone exits 6 and says it never uses the network" {
    updater_checkout v1.1.0
    updater_run --rollback v9.9.9
    [ "$status" -eq 6 ]
    [[ "$output" == *"not available in this repository"* ]]
    [[ "$output" == *"never uses the network"* ]]
    [ "$(updater_head)" = "v1.1.0" ]
}

@test "--rollback refuses a branch name: a rollback is to a release or a commit" {
    updater_checkout v1.1.0
    updater_run --rollback main
    [ "$status" -eq 1 ]
    [[ "$output" == *"is a branch"* ]]
    [ "$(updater_head)" = "v1.1.0" ]
}

@test "--rollback with too many arguments is a usage error" {
    updater_checkout v1.1.0
    updater_run --rollback v1.0.0 v1.2.0
    [ "$status" -eq 1 ]
    [[ "$output" == *"Usage:"* ]]
}

@test "--rollback needs no network: it works with the origin black-holed" {
    _update_to v1.2.0
    updater_blackhole
    _start=$SECONDS
    LYREBIRD_FETCH_TIMEOUT=2 LYREBIRD_REMOTE_PROBE_TIMEOUT=2 run timeout 30 env "${UPDATER_SIGNAL_ARGS[@]}" PATH="$SHIMS:$PATH" \
        bash "$REPO/lyrebird-updater.sh" --rollback <<<"$([[ $EUID -eq 0 ]] && echo y)"
    [ "$status" -eq 0 ]
    [ "$(updater_head)" = "v1.1.0" ]
    [ "$((SECONDS - _start))" -lt 25 ]
}

# ============================================================================
# The same safety as an update
# ============================================================================

@test "--rollback keeps the operator's local changes (saved, then restored)" {
    _update_to v1.2.0
    echo "precious edit" >>"$REPO/config.txt"
    updater_stdin y
    updater_run --rollback
    [ "$status" -eq 0 ]
    [ "$(updater_head)" = "v1.1.0" ]
    grep -qx "precious edit" "$REPO/config.txt"
    [ -z "$(git -C "$REPO" stash list)" ]
}

@test "--rollback with local changes and no answer (not interactive) refuses and keeps them" {
    _update_to v1.2.0
    echo "precious edit" >>"$REPO/config.txt"
    updater_stdin
    updater_run --rollback
    [ "$status" -eq 9 ]
    [[ "$output" == *"Operation cancelled"* ]]
    [ "$(updater_head)" = "v1.2.0" ]
    grep -qx "precious edit" "$REPO/config.txt"
}

@test "--rollback refuses in the middle of a merge (exit 8)" {
    _update_to v1.2.0
    touch "$REPO/.git/MERGE_HEAD"
    updater_run --rollback
    rm -f "$REPO/.git/MERGE_HEAD"
    [ "$status" -eq 8 ]
    [ "$(updater_head)" = "v1.2.0" ]
}

@test "--rollback across a self-update goes through the same hand-over, is recorded once and never opens the menu" {
    updater_checkout v1.1.0
    updater_stdin 3 v1.3.0 "" q
    updater_run
    [ "$status" -eq 0 ]
    [ "$(updater_head)" = "v1.3.0" ]
    updater_stdin # nothing on stdin: a command must not wait for a menu answer
    updater_run --rollback
    [ "$status" -eq 0 ]
    [[ "$output" == *"Restarting with updated version"* ]]
    [[ "$output" != *"=== UPDATE ==="* ]]
    [ "$(updater_head)" = "v1.1.0" ]
    [ "$(grep -c $'\trollback\tok\t' "$HISTORY")" -eq 1 ]
    [ ! -e "$REPO/.git/lyrebird-updater/transaction" ]
}

@test "--rollback with local changes across a self-update restores them and does not open the menu either" {
    updater_checkout v1.1.0
    updater_stdin 3 v1.3.0 "" q
    updater_run
    [ "$status" -eq 0 ]
    echo "precious edit" >>"$REPO/config.txt"
    updater_stdin y # save my changes; nothing else on stdin
    updater_run --rollback
    [ "$status" -eq 0 ]
    [[ "$output" == *"Restarting with updated version"* ]]
    [[ "$output" != *"=== UPDATE ==="* ]]
    [ "$(updater_head)" = "v1.1.0" ]
    grep -qx "precious edit" "$REPO/config.txt"
    [ -z "$(git -C "$REPO" stash list)" ]
}

@test "--rollback to a release whose updater cannot resume finishes in this process" {
    _update_to v1.2.0
    updater_make_old_updater_tag
    updater_run --rollback v0.9.0
    [ "$status" -eq 0 ] || { echo "$output"; return 1; }
    [[ "$output" == *"older and cannot resume an update"* ]]
    [ "$(updater_head)" = "v0.9.0" ]
}

@test "kill -9 during --rollback: the next run undoes the half-done rollback" {
    _update_to v1.2.0
    updater_inject checkout after KILL
    updater_run --rollback
    [ "$status" -eq 137 ]
    updater_inject_clear
    [ "$(updater_head)" = "v1.1.0" ] # half way: already switched, nothing else done
    grep -q '^kind=rollback$' "$REPO/.git/lyrebird-updater/transaction"
    updater_stdin q
    updater_run
    [ "$status" -eq 0 ]
    [ "$(updater_head)" = "v1.2.0" ] # back where the rollback started
    [ ! -e "$REPO/.git/lyrebird-updater/transaction" ]
    grep -q $'\trollback\tinterrupted\t' "$HISTORY"
}

# ============================================================================
# With the systemd service installed
# ============================================================================

@test "--rollback stops the service, restores the version and starts the service again" {
    _update_to v1.2.0
    updater_install_fake_service running
    updater_run --rollback
    [ "$status" -eq 0 ]
    [ "$(updater_head)" = "v1.1.0" ]
    [ "$(cat "$FAKE_SVC_STATE")" = "running" ]
    grep -q 'systemctl stop mediamtx-audio' "$FAKE_SVC_LOG"
    grep -q 'systemctl start mediamtx-audio' "$FAKE_SVC_LOG"
    [ ! -e "$SYSROOT/run/lyrebird-service-update.marker" ]
}

@test "a service that will not start on the new version rolls the update back to the original tag" {
    updater_checkout v1.1.0
    updater_install_fake_service running
    export FAKE_SVC_FAIL_START=1
    updater_stdin 3 v1.2.0 "" q
    updater_run
    [ "$status" -eq 1 ]
    [[ "$output" == *"Service update failed after checkout"* ]]
    [[ "$output" == *"Rollback complete"* ]]
    [ "$(updater_head)" = "v1.1.0" ]
    grep -q 'lyrebird-stream-manager v1.1.0' "$REPO/lyrebird-stream-manager.sh"
    [ ! -e "$SYSROOT/run/lyrebird-service-update.marker" ]
    grep -q $'\tupdate\trolled-back\t' "$HISTORY"
    grep -q 'service update failed after checkout' "$HISTORY"
}
