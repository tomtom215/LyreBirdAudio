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

# ============================================================================
# Dirty-tree detection and the transaction stash
# ============================================================================

@test "a chmod of a tracked file after the last index refresh is not reported as a local modification" {
    updater_checkout v1.1.0
    git -C "$REPO" status --porcelain >/dev/null # refresh the index: stat data now matches
    sleep 1.1                                    # git compares timestamps to the second
    chmod 755 "$REPO/lyrebird-common.sh"         # same mode, new ctime: what the updater's own chmod leaves behind
    # the plumbing the updater used to ask ("git diff-index") reports that stale stat data as a change
    ! git -C "$REPO" diff-index --quiet HEAD || false
    updater_run --status
    [ "$status" -eq 0 ]
    [[ "$output" == *"Ready (no local modifications)"* ]]
}

@test "a self-update does not leave the node looking modified" {
    updater_checkout v1.1.0
    updater_stdin 3 v1.3.0 "" q
    updater_run
    [ "$status" -eq 0 ]
    [ "$(updater_head)" = "v1.3.0" ]
    [[ "$output" != *"local modifications"* ]]
}

@test "an update never adopts or pops a stash the operator made earlier" {
    updater_checkout v1.1.0
    echo "operator work" >"$REPO/operator-notes.txt"
    git -C "$REPO" stash push -u -m operator-stash >/dev/null
    # The updater believes the tree is dirty (a new untracked file) but its own
    # `git stash push` saves nothing -- as when the operator removes the file in
    # that instant. stash@{0} is then the operator's stash.
    echo "scratch" >"$REPO/scratch.txt"
    updater_inject stash-push before SKIP
    updater_stdin 3 v1.2.0 y "" q
    updater_run
    [ "$status" -eq 0 ]
    [ "$(updater_head)" = "v1.2.0" ]
    [ "$(git -C "$REPO" stash list | wc -l)" -eq 1 ]
    git -C "$REPO" stash list | grep -q operator-stash
    [ ! -e "$REPO/operator-notes.txt" ]
}

# ============================================================================
# Rollback returns to where the operator was and never discards their work
# ============================================================================

@test "a failed switch from a tag goes back to that tag, not the version it was leaving" {
    updater_checkout v1.1.0
    # git completes the checkout, then reports failure (what a write error half way through looks like)
    updater_inject checkout after FAIL
    updater_stdin 3 v1.2.0
    updater_run
    [ "$status" -eq 1 ]
    [[ "$output" == *"Rollback complete"* ]]
    [ "$(updater_head)" = "v1.1.0" ]
    grep -q 'lyrebird-stream-manager v1.1.0' "$REPO/lyrebird-stream-manager.sh"
    grep -q 'lyrebird-diagnostics v1.0.0' "$REPO/lyrebird-diagnostics.sh"
    updater_git_clean
}

@test "a rollback removes the files the failed switch had already added" {
    updater_checkout v1.1.0
    updater_inject checkout after FAIL
    updater_stdin 3 v1.2.0
    updater_run
    [ "$status" -eq 1 ]
    [ "$(updater_head)" = "v1.1.0" ]
    [ ! -e "$REPO/added-in-1.2.0.txt" ]
    updater_git_clean
}

@test "SIGTERM during a switch rolls back to the original tag and exits 9" {
    updater_checkout v1.1.0
    updater_inject checkout after TERM
    updater_stdin 3 v1.2.0
    updater_run
    [ "$status" -eq 9 ]
    [[ "$output" == *"interrupted"* ]]
    [ "$(updater_head)" = "v1.1.0" ]
    [ ! -e "$REPO/added-in-1.2.0.txt" ]
    updater_git_clean
}

@test "SIGINT during a switch rolls back to the original tag and exits 9" {
    updater_checkout v1.1.0
    updater_inject checkout after INT
    updater_stdin 3 v1.2.0
    updater_run
    [ "$status" -eq 9 ]
    [ "$(updater_head)" = "v1.1.0" ]
    updater_git_clean
}

@test "a rollback of a branch update puts the branch tip back where it was" {
    updater_checkout main
    local tip
    tip="$(git -C "$REPO" rev-parse main)"
    echo "newer" >"$WORK/newer.txt"
    git -C "$WORK" add newer.txt
    git -C "$WORK" commit -qm "newer on main"
    git -C "$WORK" push -q origin main 2>/dev/null
    git -C "$REPO" fetch -q origin
    # the fast-forward happens, then git reports failure
    updater_inject merge after FAIL
    updater_stdin 3 main
    updater_run
    [ "$status" -eq 1 ]
    [ "$(git -C "$REPO" symbolic-ref --short HEAD)" = "main" ]
    [ "$(git -C "$REPO" rev-parse main)" = "$tip" ]
    [ ! -e "$REPO/newer.txt" ]
}

@test "declining to save local changes keeps them" {
    updater_checkout v1.1.0
    echo "precious edit" >>"$REPO/config.txt"
    updater_stdin 3 v1.2.0 n
    updater_run
    [ "$status" -eq 9 ]
    [[ "$output" == *"Operation cancelled"* ]]
    grep -qx "precious edit" "$REPO/config.txt"
    [ "$(updater_head)" = "v1.1.0" ]
    [ -z "$(git -C "$REPO" stash list)" ]
}

@test "a failed stash keeps local changes in the working tree" {
    updater_checkout v1.1.0
    echo "precious edit" >>"$REPO/config.txt"
    updater_inject stash-push before FAIL
    updater_stdin 3 v1.2.0 y
    updater_run
    [ "$status" -eq 1 ]
    [[ "$output" == *"Failed to save your changes"* ]]
    grep -qx "precious edit" "$REPO/config.txt"
    [ "$(updater_head)" = "v1.1.0" ]
}

@test "a divergent local branch is refused, the original tag restored and the local commit kept" {
    updater_checkout v1.1.0
    updater_make_diverged_dev
    local local_tip
    local_tip="$(git -C "$REPO" rev-parse dev)"
    updater_checkout v1.1.0
    updater_stdin 3 dev
    updater_run
    [ "$status" -eq 1 ]
    [[ "$output" == *"local history has diverged"* ]]
    [ "$(updater_head)" = "v1.1.0" ]
    [ "$(git -C "$REPO" rev-parse dev)" = "$local_tip" ]
    [ ! -e "$REPO/local-only.txt" ]
    updater_git_clean
}

@test "a checkout that reports success after a write error is caught and rolled back" {
    updater_checkout v1.1.0
    updater_make_big_tag
    echo "precious edit" >>"$REPO/config.txt"
    # RLIMIT_FSIZE: git prints "unable to write file big.bin", leaves it truncated and exits 0
    updater_stdin 3 v1.4.0 y
    run env PATH="$SHIMS:$PATH" bash -c 'trap "" XFSZ; ulimit -f 200; exec bash "$1"' _ \
        "$REPO/lyrebird-updater.sh" <<<"${UPDATER_INPUT%$'\n'}"
    unset UPDATER_INPUT
    [ "$status" -eq 1 ]
    [[ "$output" == *"do not match version v1.4.0"* ]]
    [[ "$output" == *"Rollback complete"* ]]
    [ "$(updater_head)" = "v1.1.0" ]
    [ ! -e "$REPO/big.bin" ]
    [ ! -e "$REPO/aa-first.txt" ]
    grep -qx "precious edit" "$REPO/config.txt"
    [ -z "$(git -C "$REPO" stash list)" ]
}

@test "disk full while checking out: rolled back to the original version with the local edit intact (real ENOSPC)" {
    updater_unshare_cmd || skip "mount namespaces are not permitted here"
    updater_checkout v1.1.0
    updater_make_big_tag
    export SMALL="$NODE/small"
    mkdir -p "$SMALL"
    updater_stdin 3 v1.4.0 y
    export INPUT="$UPDATER_INPUT"
    run "${UNSHARE_CMD[@]}" bash -c '
        mount -t tmpfs -o size=3m tmpfs "$SMALL" || exit 99
        cp -a "$REPO" "$SMALL/repo"
        cd "$SMALL/repo" || exit 98
        git fetch -q origin --tags
        git checkout -q v1.1.0
        echo "precious edit" >>config.txt
        free_kb="$(df -k --output=avail . | tail -1)"
        dd if=/dev/zero of="$SMALL/filler" bs=1k count=$((free_kb - 300)) 2>/dev/null
        printf "%s" "$INPUT" | env PATH="$SHIMS:$PATH" bash ./lyrebird-updater.sh >"$SMALL/out.txt" 2>&1
        echo "RC=$?"
        echo "HEAD=$(git describe --tags --exact-match 2>/dev/null)"
        echo "DIRTY=$(git -c core.fileMode=false status --porcelain | wc -l)"
        echo "EDIT=$(grep -c "precious edit" config.txt)"
        echo "BIG=$([ -e big.bin ] && echo present || echo absent)"
        echo "FIRST=$([ -e aa-first.txt ] && echo present || echo absent)"
        echo "STASH=$(git stash list | wc -l)"
        cat "$SMALL/out.txt"
    '
    [[ "$output" == *"unable to write file"* ]] || [[ "$output" == *"Failed to switch to version"* ]]
    [[ "$output" == *"RC=1"* ]]
    [[ "$output" == *"HEAD=v1.1.0"* ]]
    [[ "$output" == *"DIRTY=1"* ]] # only the operator's config.txt edit
    [[ "$output" == *"EDIT=1"* ]]
    [[ "$output" == *"BIG=absent"* ]]
    [[ "$output" == *"FIRST=absent"* ]]
    [[ "$output" == *"STASH=0"* ]]
}

@test "when the rollback itself fails it says so, exits 11 and names the manual command" {
    updater_checkout v1.1.0
    updater_make_diverged_dev
    updater_checkout v1.1.0
    local original
    original="$(git -C "$REPO" rev-parse HEAD)"
    echo "precious edit" >>"$REPO/config.txt"
    updater_inject checkout-force before FAIL
    updater_stdin 3 dev y
    updater_run
    [ "$status" -eq 11 ]
    [[ "$output" == *"Could not restore the original version"* ]]
    [[ "$output" == *"git checkout --force $original"* ]]
    [[ "$output" == *"Rollback incomplete"* ]]
    # the operator's edit is safe in the stash, not lost
    git -C "$REPO" stash list | grep -q lyrebird-tx
}
