#!/usr/bin/env bats
# The update history log (written by every update path, readable with no
# network and no git) and `lyrebird-updater.sh --history`. Real script, real
# git repositories: see tests/updater_helper.bash.

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
    scratch_teardown
}

# ============================================================================
# What gets recorded
# ============================================================================

@test "a successful update is appended to the history log as one tab-separated line" {
    updater_checkout v1.1.0
    local from to
    from="$(git -C "$REPO" rev-parse HEAD)"
    to="$(git -C "$REPO" rev-parse v1.2.0^{commit})"
    updater_stdin 3 v1.2.0 "" q
    updater_run
    [ "$status" -eq 0 ]
    [ "$(wc -l <"$HISTORY")" -eq 1 ]
    local ts kind result f_commit f_label t_commit t_label note
    IFS=$'\t' read -r ts kind result f_commit f_label t_commit t_label note <"$HISTORY"
    [[ "$ts" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$ ]]
    [ "$kind" = "update" ]
    [ "$result" = "ok" ]
    [ "$f_commit" = "$from" ]
    [ "$f_label" = "v1.1.0" ]
    [ "$t_commit" = "$to" ]
    [ "$t_label" = "v1.2.0" ]
    [ "$note" = "-" ]
}

@test "a self-update is recorded once, as ok, by the re-exec'd updater" {
    updater_checkout v1.1.0
    updater_stdin 3 v1.3.0 "" q
    updater_run
    [ "$status" -eq 0 ]
    [[ "$output" == *"Restarting with updated version"* ]]
    [ "$(wc -l <"$HISTORY")" -eq 1 ]
    grep -q $'\tupdate\tok\t' "$HISTORY"
    grep -q $'\tv1.1.0\t' "$HISTORY"
    grep -q $'\tv1.3.0\t' "$HISTORY"
    [ ! -e "$REPO/.git/lyrebird-updater/transaction" ]
}

@test "an update that failed and was rolled back is recorded with the reason" {
    updater_checkout v1.1.0
    updater_inject checkout after FAIL
    updater_stdin 3 v1.2.0
    updater_run
    [ "$status" -eq 1 ]
    [ "$(wc -l <"$HISTORY")" -eq 1 ]
    grep -q $'\tupdate\trolled-back\t' "$HISTORY"
    grep -q $'\tcheckout failed$' "$HISTORY"
    [ ! -e "$REPO/.git/lyrebird-updater/transaction" ]
}

@test "a failure before anything changed is recorded as failed, a cancelled one is not recorded" {
    updater_checkout v1.1.0
    echo "edit" >>"$REPO/config.txt"
    updater_stdin 3 v1.2.0 n
    updater_run
    [ "$status" -eq 9 ]
    [ ! -e "$HISTORY" ]
    updater_inject stash-push before FAIL
    updater_stdin 3 v1.2.0 y
    updater_run
    [ "$status" -eq 1 ]
    [ "$(wc -l <"$HISTORY")" -eq 1 ]
    grep -q $'\tupdate\tfailed\t' "$HISTORY"
}

@test "an interrupted update (SIGTERM) is recorded as rolled back with the signal" {
    updater_checkout v1.1.0
    updater_inject checkout after TERM
    updater_stdin 3 v1.2.0
    updater_run
    [ "$status" -eq 9 ]
    grep -q $'\tupdate\trolled-back\t' "$HISTORY"
    grep -q 'interrupted by SIGTERM' "$HISTORY"
}

@test "an update whose saved changes conflict is recorded ok with the note" {
    updater_checkout v1.0.0
    echo "config LOCAL EDIT" >"$REPO/config.txt"
    updater_stdin 3 v1.1.0 y
    updater_run
    [ "$status" -eq 10 ]
    grep -q $'\tupdate\tok\t' "$HISTORY"
    grep -q 'saved changes kept in the stash' "$HISTORY"
}

@test "a reset (menu 6) is recorded, and --rollback goes back to where it started" {
    updater_checkout v1.1.0
    echo "to be discarded" >>"$REPO/config.txt"
    local from
    from="$(git -C "$REPO" rev-parse HEAD)"
    updater_stdin 6 2 yes "" q
    updater_run
    [ "$status" -eq 0 ]
    [ "$(git -C "$REPO" rev-parse HEAD)" != "$from" ]
    [ "$(wc -l <"$HISTORY")" -eq 1 ]
    local ts kind result f_commit f_label t_commit t_label note
    IFS=$'\t' read -r ts kind result f_commit f_label t_commit t_label note <"$HISTORY"
    [ "$kind" = "reset" ]
    [ "$result" = "ok" ]
    [ "$f_commit" = "$from" ]
    [ "$f_label" = "v1.1.0" ]
    [ "$t_label" = "origin/main" ]
    [ "$note" = "uncommitted changes discarded" ]
    updater_run --rollback
    [ "$status" -eq 0 ]
    [ "$(git -C "$REPO" rev-parse HEAD)" = "$from" ]
}

# ============================================================================
# --history
# ============================================================================

@test "--history on a node that never updated says so and exits 0" {
    updater_checkout v1.1.0
    updater_run --history
    [ "$status" -eq 0 ]
    [[ "$output" == *"No updates recorded yet."* ]]
}

@test "--history lists past updates, failures and rollbacks with versions, newest last" {
    updater_checkout v1.1.0
    updater_stdin 3 v1.2.0 "" q
    updater_run
    [ "$status" -eq 0 ]
    updater_inject checkout after FAIL
    updater_stdin 3 v1.0.0
    updater_run
    [ "$status" -eq 1 ]
    updater_inject_clear
    updater_run --history
    [ "$status" -eq 0 ]
    [[ "$output" == *"WHEN (UTC)"* ]]
    local ok_line rb_line
    ok_line="$(grep -n 'ok ' <<<"$output" | head -n1 | cut -d: -f1)"
    rb_line="$(grep -n 'rolled-back' <<<"$output" | head -n1 | cut -d: -f1)"
    [ -n "$ok_line" ] && [ -n "$rb_line" ] && [ "$ok_line" -lt "$rb_line" ]
    [[ "$output" == *"v1.1.0 ("* && "$output" == *"v1.2.0 ("* ]]
    [[ "$output" == *"checkout failed"* ]]
}

@test "--history needs neither network, lock nor git" {
    updater_checkout v1.1.0
    updater_stdin 3 v1.2.0 "" q
    updater_run
    [ "$status" -eq 0 ]
    # the origin is gone, another updater holds the lock, and git itself is broken
    git -C "$REPO" remote set-url origin "http://nonexistent.invalid/github.com/tomtom215/LyreBirdAudio.git"
    mkdir -p "$NODE/nogit"
    printf '#!/bin/bash\necho "git must not be called" >&2\nexit 99\n' >"$NODE/nogit/git"
    chmod +x "$NODE/nogit/git"
    mkdir -p "$REPO/.git/lyrebird-updater/lock"
    ( exec -a "lyrebird-updater.sh" sleep 30 ) &
    local holder=$!
    echo "$holder" >"$REPO/.git/lyrebird-updater/lock/pid"
    run env PATH="$NODE/nogit:$PATH" LYREBIRD_UPDATER_LOCK_WAIT=1 bash "$REPO/lyrebird-updater.sh" --history
    kill "$holder" 2>/dev/null || true
    wait "$holder" 2>/dev/null || true
    [ "$status" -eq 0 ]
    [[ "$output" == *"v1.2.0"* ]]
    [[ "$output" != *"git must not be called"* ]]
}

@test "--history skips an unreadable (torn) line and says so; the next record is not glued to it" {
    updater_checkout v1.1.0
    updater_stdin 3 v1.2.0 "" q
    updater_run
    [ "$status" -eq 0 ]
    printf 'half a recor' >>"$HISTORY" # a power cut in the middle of a write
    updater_run --history
    [ "$status" -eq 0 ]
    [[ "$output" == *"1 unreadable line(s) skipped"* ]]
    [[ "$output" == *"v1.2.0"* ]]
    updater_inject checkout after FAIL
    updater_stdin 3 v1.1.0
    updater_run
    [ "$status" -eq 1 ]
    updater_inject_clear
    [ "$(wc -l <"$HISTORY")" -eq 3 ]
    ! grep -q 'half a recor2' "$HISTORY" || false
    updater_run --history
    [[ "$output" == *"1 unreadable line(s) skipped"* ]]
    [[ "$output" == *"rolled-back"* ]]
}

@test "--history shows an update that never finished" {
    updater_checkout v1.1.0
    updater_inject checkout after KILL
    updater_stdin 3 v1.2.0
    updater_run
    [ "$status" -eq 137 ]
    updater_inject_clear
    updater_run --history
    [ "$status" -eq 0 ]
    [[ "$output" == *"Not finished:"* ]]
    [[ "$output" == *"update to v1.2.0"* ]]
}
