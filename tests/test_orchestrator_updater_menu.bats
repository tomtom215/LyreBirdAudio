#!/usr/bin/env bats
# Version Management of lyrebird-orchestrator.sh: the updater's --history and
# --rollback (register: LB-21; the updater side is X-21). Real orchestrator in a copy of a checkout
# (a .git directory, so the updater's state directory can be derived as it is on a
# node), stand-ins for the delegated scripts, on a pseudo-terminal (see
# tests/orchestrator_helper.bash). The history log is read with the REAL updater's
# own writer and selection in "agrees with the real updater".

load scratch_tmpdir
load orchestrator_helper

C1=1111111111111111111111111111111111111111
C2=2222222222222222222222222222222222222222
C3=3333333333333333333333333333333333333333

setup() {
    scratch_setup
    orch_setup
    ORCH_REPO="$TEST_SCRATCH/repo"
    mkdir -p "$ORCH_REPO/.git"
    # ORCH_UNDER_TEST: another orchestrator to run the same tests against (the
    # mutation checks use it)
    cp "${ORCH_UNDER_TEST:-$ORCH_ROOT/lyrebird-orchestrator.sh}" "$ORCH_REPO/lyrebird-orchestrator.sh"
    cp "$ORCH_ROOT/lyrebird-common.sh" "$ORCH_ROOT/lyrebird-updater.sh" "$ORCH_REPO/"
    export ORCH_SOURCE="$ORCH_REPO/lyrebird-orchestrator.sh"
    HISTORY="$ORCH_REPO/.git/lyrebird-updater/history.log"
}

teardown() {
    scratch_teardown
}

# history_line TIME KIND RESULT FROM_COMMIT FROM_LABEL TO_COMMIT TO_LABEL [NOTE]:
# one record in the updater's format (tab separated, "-" for an empty field)
history_line() {
    mkdir -p "$(dirname "$HISTORY")"
    printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$1" "$2" "$3" "$4" "$5" "$6" "$7" "${8:--}" >>"$HISTORY"
}

# versions STEP...: the Version Management menu, with the answers given as
# --step REGEX TEXT arguments, ending with "0" at the menu
versions() {
    orch_run "$@" 'menu_versions'
}

# rollback VERSION_ANSWER CONFIRM: option 4 with the answer to the version prompt
# (\n alone = the previous version) and to the confirmation ("" = never asked)
rollback() {
    local -a steps=(--step 'Select option: ' '4\n' --step 'Version to roll back to: ' "$1")
    if [[ -n "${2:-}" ]]; then
        steps+=(--step 'Continue\? \(y/n\)' "$2")
    fi
    steps+=(--step 'Press Enter to continue' '\n' --step 'Select option: ' '0\n')
    versions "${steps[@]}"
}

# What the user read as the answer to the rollback: before the final pause
answer() {
    printf '%s' "${output%%Press Enter to continue*}"
}

# ---------------------------------------------------------------------------
# The menu
# ---------------------------------------------------------------------------

@test "Version Management keeps options 1, 2 and 0 and adds 3 (history) and 4 (rollback) [LB-21]" {
    versions --step 'Select option: ' '0\n'
    echo "$output"
    [ "$status" -eq 0 ]
    [[ "$output" == *"  1) Launch Update Manager (Interactive)"* ]]
    [[ "$output" == *"  2) Show Component Versions"* ]]
    [[ "$output" == *"  3) Show Update History"* ]]
    [[ "$output" == *"  4) Roll Back to a Previous Version"* ]]
    [[ "$output" == *"  0) Back to Main Menu"* ]]
}

@test "option 3 shows the updater's history, with no network access asked for [LB-21]" {
    versions --step 'Select option: ' '3\n' --step 'Press Enter to continue' '\n' --step 'Select option: ' '0\n'
    echo "$output"
    [ "$status" -eq 0 ]
    [[ "$output" == *"stub updater --history"* ]]
    grep -qx 'updater --history' "$ORCH_CALLS"
    # exactly one call, and it is --history: nothing that fetches
    [ "$(wc -l <"$ORCH_CALLS")" -eq 1 ]
}

@test "option 3: a failing updater is explained, not hidden [LB-21]" {
    export STUB_RC_updater___history=5
    versions --step 'Select option: ' '3\n' --step 'Press Enter to continue' '\n' --step 'Select option: ' '0\n'
    echo "$output"
    [ "$status" -eq 0 ]
    [[ "$output" == *"lyrebird-updater.sh failed (exit code: 5 - permission problem"* ]]
}

# ---------------------------------------------------------------------------
# Rollback: which version, and a confirmation first
# ---------------------------------------------------------------------------

@test "rollback to the previous version: the version it will go to is shown, a confirmation is asked, then the updater runs without a version [LB-21]" {
    history_line 2026-11-01T10:00:00Z update ok $C1 v1.1.0 $C2 v1.2.0
    rollback '\n' y
    echo "$output"
    [ "$status" -eq 0 ]
    [[ "$(answer)" == *"Before the last update this node ran: v1.1.0 (1111111)"* ]]
    [[ "$(answer)" == *"This will roll back LyreBirdAudio to: v1.1.0 (1111111)"* ]]
    [[ "$(answer)" == *"It never uses the network."* ]]
    # the updater is told to go back to where the last update came from (its own
    # history decides, to the exact commit): no version on the command line
    [ "$(cat "$ORCH_CALLS")" = "updater --rollback" ]
    [[ "$(answer)" == *"stub updater --rollback"* ]]
    [[ "$(answer)" == *"The updater finished the rollback (exit code 0)"* ]]
    [[ "$(answer)" == *"leave it and start it again"* ]]
}

@test "rollback: declining the confirmation changes nothing and does not run the updater [LB-21]" {
    history_line 2026-11-01T10:00:00Z update ok $C1 v1.1.0 $C2 v1.2.0
    rollback '\n' n
    echo "$output"
    [ "$status" -eq 0 ]
    [[ "$(answer)" == *"This will roll back LyreBirdAudio to: v1.1.0 (1111111)"* ]]
    [[ "$(answer)" == *"Cancelled; nothing was changed"* ]]
    [ ! -s "$ORCH_CALLS" ]
}

@test "rollback: 0 at the version prompt cancels before anything is asked or run [LB-21]" {
    history_line 2026-11-01T10:00:00Z update ok $C1 v1.1.0 $C2 v1.2.0
    rollback '0\n'
    echo "$output"
    [ "$status" -eq 0 ]
    [[ "$(answer)" == *"Cancelled; nothing was changed"* ]]
    [[ "$(answer)" != *"This will roll back"* ]]
    [ ! -s "$ORCH_CALLS" ]
}

@test "rollback: end of input at the version prompt cancels [LB-21]" {
    history_line 2026-11-01T10:00:00Z update ok $C1 v1.1.0 $C2 v1.2.0
    versions --step 'Select option: ' '4\n' --step 'Version to roll back to: ' '\x04' --step 'Press Enter to continue' '\n' --step 'Select option: ' '0\n'
    echo "$output"
    [ "$status" -eq 0 ]
    [[ "$output" == *"Input stream closed - operation cancelled"* ]]
    [ ! -s "$ORCH_CALLS" ]
}

@test "rollback to a named version: the updater gets exactly that version, and the confirmation names it [LB-21]" {
    rollback 'v1.2.0\n' y
    echo "$output"
    [ "$status" -eq 0 ]
    [[ "$(answer)" == *"No previous version is recorded in the update history."* ]]
    [[ "$(answer)" == *"This will roll back LyreBirdAudio to: v1.2.0"* ]]
    [ "$(cat "$ORCH_CALLS")" = "updater --rollback v1.2.0" ]
}

@test "rollback to a commit hash is accepted as typed [LB-21]" {
    rollback 'a1b2c3d\n' y
    [ "$status" -eq 0 ]
    [ "$(cat "$ORCH_CALLS")" = "updater --rollback a1b2c3d" ]
}

@test "rollback: a version that could be an option or a shell word is refused before anything is asked [LB-21]" {
    local bad
    for bad in '--help' '-x' '--rollback' '.hidden' '../x' 'v1;id' '$(id)' 'a`b' 'v1|x' "v1'x" 'a\\x'; do
        rollback "${bad}\\n"
        [ "$status" -eq 0 ] || { echo "$output"; return 1; }
        [[ "$output" == *"Not a valid version: use a release tag such as v1.3.0 or a commit hash"* ]] \
            || { echo "$output"; echo "not refused: $bad"; return 1; }
        [[ "$output" != *"This will roll back"* ]] || { echo "asked to confirm: $bad"; return 1; }
    done
    [ ! -s "$ORCH_CALLS" ]
}

@test "rollback: Enter with no recorded previous version is refused, the updater is not run [LB-21]" {
    rollback '\n'
    echo "$output"
    [ "$status" -eq 0 ]
    [[ "$(answer)" == *"No previous version is recorded: type the version to roll back to"* ]]
    [[ "$(answer)" != *"This will roll back"* ]]
    [ ! -s "$ORCH_CALLS" ]
}

@test "rollback: the previous version comes from the last update that completed, not from a failed one [LB-21]" {
    history_line 2026-11-01T10:00:00Z update ok $C1 v1.1.0 $C2 v1.2.0
    history_line 2026-11-02T10:00:00Z update failed $C2 v1.2.0 $C3 v1.3.0 "checkout failed"
    history_line 2026-11-02T10:05:00Z update rolled-back $C2 v1.2.0 $C3 v1.3.0 "interrupted by SIGTERM"
    rollback '\n' n
    echo "$output"
    [[ "$(answer)" == *"Before the last update this node ran: v1.1.0 (1111111)"* ]]
}

@test "rollback: a previous version with no tag is shown by its short hash [LB-21]" {
    history_line 2026-11-01T10:00:00Z update ok $C1 - $C2 v1.2.0
    rollback '\n' n
    echo "$output"
    [[ "$(answer)" == *"Before the last update this node ran: 1111111 (1111111)"* ]]
}

@test "rollback: a record that did not note where the update came from (an older updater) is not a previous version [LB-21]" {
    history_line 2026-11-01T10:00:00Z update ok - - $C2 v1.2.0
    rollback '\n'
    echo "$output"
    [[ "$(answer)" == *"No previous version is recorded in the update history."* ]]
    [ ! -s "$ORCH_CALLS" ]
}

# ---------------------------------------------------------------------------
# Rollback: what the updater's exit status means, and the integrity baseline
# ---------------------------------------------------------------------------

@test "rollback: each exit status of the updater is explained and only exit 0 says it finished [LB-21]" {
    history_line 2026-11-01T10:00:00Z update ok $C1 v1.1.0 $C2 v1.2.0
    local code fragment
    while IFS='|' read -r code fragment; do
        export STUB_RC_updater___rollback="$code"
        rollback '\n' y
        [ "$status" -eq 0 ] || { echo "$output"; return 1; }
        [[ "$(answer)" == *"lyrebird-updater.sh failed (exit code: $code - $fragment"* ]] \
            || { echo "$output"; echo "exit $code not explained as: $fragment"; return 1; }
        [[ "$(answer)" != *"finished the rollback"* ]] || { echo "exit $code said it finished"; return 1; }
    done <<'TABLE'
1|general error
5|permission problem
6|that version is not available in this clone (a rollback never uses the network)
7|another updater is running
8|unusable git state
9|cancelled
10|the switch is done, but your saved changes conflict with the new version and were NOT re-applied; they are in the git stash
11|the automatic rollback could not restore everything
TABLE
}

@test "rollback to a version that is not on this node (exit 6): says where to look [LB-21]" {
    export STUB_RC_updater___rollback=6
    rollback 'v9.9.9\n' y
    echo "$output"
    [[ "$(answer)" == *"exit code: 6 - that version is not available in this clone"* ]]
    [[ "$(answer)" == *"Option 3, Show Update History, lists the versions this node has run."* ]]
}

@test "rollback: the integrity baseline is refreshed after the updater rewrote the scripts, so the next action still runs [LB-21]" {
    history_line 2026-11-01T10:00:00Z update ok $C1 v1.1.0 $C2 v1.2.0
    export STUB_UPDATER_REWRITES="$ORCH_STUBS/lyrebird-stream-manager.sh"
    versions \
        --step 'Select option: ' '4\n' --step 'Version to roll back to: ' '\n' --step 'Continue\? \(y/n\)' 'y' \
        --step 'Press Enter to continue' '\n' --step 'Select option: ' '0\n' \
        'SCRIPT_CHECKSUMS[stream_manager]="$(sha256sum "$ORCH_STUBS/lyrebird-stream-manager.sh" | cut -d" " -f1)"
menu_versions
if verify_script_integrity stream_manager; then echo "INTEGRITY: ok"; else echo "INTEGRITY: the rewritten script is rejected"; fi
execute_script stream_manager status >/dev/null && echo "NEXT-ACTION: ran"'
    echo "$output"
    [ "$status" -eq 0 ]
    grep -q 'rewritten by the updater' "$ORCH_STUBS/lyrebird-stream-manager.sh"
    [[ "$output" == *"INTEGRITY: ok"* ]]
    [[ "$output" == *"NEXT-ACTION: ran"* ]]
}

# ---------------------------------------------------------------------------
# The history log is the updater's: same place, same selection
# ---------------------------------------------------------------------------

@test "updater_state_dir derives the updater's state directory from a .git directory, a gitdir file (absolute and relative), and refuses a non-checkout [LB-21]" {
    run bash -c 'source "$1/lyrebird-orchestrator.sh" >/dev/null 2>&1; updater_state_dir' _ "$ORCH_REPO"
    [ "$status" -eq 0 ]
    [ "$output" = "$ORCH_REPO/.git/lyrebird-updater" ]

    # a linked worktree: .git is a file naming the real directory
    rm -rf "$ORCH_REPO/.git"
    mkdir -p "$TEST_SCRATCH/gitdirs/wt"
    echo "gitdir: $TEST_SCRATCH/gitdirs/wt" >"$ORCH_REPO/.git"
    run bash -c 'source "$1/lyrebird-orchestrator.sh" >/dev/null 2>&1; updater_state_dir' _ "$ORCH_REPO"
    [ "$status" -eq 0 ]
    [ "$output" = "$TEST_SCRATCH/gitdirs/wt/lyrebird-updater" ]
    echo "gitdir: ../gitdirs/wt" >"$ORCH_REPO/.git"
    run bash -c 'source "$1/lyrebird-orchestrator.sh" >/dev/null 2>&1; updater_state_dir' _ "$ORCH_REPO"
    [ "$status" -eq 0 ]
    [ "$output" = "$ORCH_REPO/../gitdirs/wt/lyrebird-updater" ]

    # not a checkout
    rm -f "$ORCH_REPO/.git"
    run bash -c 'source "$1/lyrebird-orchestrator.sh" >/dev/null 2>&1; updater_state_dir || echo "none (status $?)"' _ "$ORCH_REPO"
    [ "$output" = "none (status 1)" ]
}

@test "the orchestrator agrees with the real updater on where the history is and which version a rollback goes back to [LB-21]" {
    # The history is written by the REAL updater's history_record and read by its
    # history_last_change; the orchestrator must name the same directory and the
    # same from-version for every shape of history
    local updater_out orch_out upd_from orch_from case_name expected
    local -A want=(
        [none]="FROM=none"
        [update-ok]="FROM=$C1 v1.1.0"
        [ok-then-failed]="FROM=$C1 v1.1.0"
        [ok-then-rollback-ok]="FROM=$C2 v1.2.0"
        [ok-then-rolled-back-then-reset]="FROM=$C2 v1.2.0"
        [older-updater-record]="FROM=none"
    )
    for case_name in none update-ok ok-then-failed ok-then-rollback-ok ok-then-rolled-back-then-reset older-updater-record; do
        expected="${want[$case_name]}"
        rm -rf "$ORCH_REPO/.git/lyrebird-updater"
        updater_out="$(CASE="$case_name" C1=$C1 C2=$C2 C3=$C3 bash -c '
            source "$1/lyrebird-updater.sh" >/dev/null 2>&1
            rec() { history_record "$@" >/dev/null 2>&1; }
            case "$CASE" in
                none) ;;
                update-ok) rec update ok $C1 v1.1.0 $C2 v1.2.0 ;;
                ok-then-failed) rec update ok $C1 v1.1.0 $C2 v1.2.0; rec update failed $C2 v1.2.0 $C3 v1.3.0 "checkout failed" ;;
                ok-then-rollback-ok) rec update ok $C1 v1.1.0 $C2 v1.2.0; rec rollback ok $C2 v1.2.0 $C1 v1.1.0 ;;
                ok-then-rolled-back-then-reset) rec update ok $C1 v1.1.0 $C2 v1.2.0; rec update rolled-back $C2 v1.2.0 $C3 v1.3.0 "x"; rec reset ok $C2 v1.2.0 $C3 "" ;;
                older-updater-record) rec update ok "" "" $C2 v1.2.0 ;;
            esac
            echo "STATE=$UPDATER_STATE_DIR"
            line="$(history_last_change)"
            IFS=$'"'"'\t'"'"' read -r _ _ _ from_commit from_label _ <<<"$line"
            echo "FROM=${from_commit:-none} ${from_label:-}"
        ' _ "$ORCH_REPO")"
        orch_out="$(bash -c '
            source "$1/lyrebird-orchestrator.sh" >/dev/null 2>&1
            echo "STATE=$(updater_state_dir)"
            if updater_previous_version; then echo "FROM=$ROLLBACK_FROM_COMMIT $ROLLBACK_FROM_LABEL"; else echo "FROM=none "; fi
        ' _ "$ORCH_REPO")"
        [ "$(grep '^STATE=' <<<"$updater_out")" = "$(grep '^STATE=' <<<"$orch_out")" ] \
            || { echo "$case_name: different state directories"; echo "$updater_out"; echo "$orch_out"; return 1; }
        upd_from="$(grep '^FROM=' <<<"$updater_out")"
        orch_from="$(grep '^FROM=' <<<"$orch_out")"
        # the updater prints "-" for a field it did not record; the orchestrator says none/empty
        upd_from="${upd_from/FROM=- -/FROM=none }"
        upd_from="${upd_from/FROM=- /FROM=none }"
        [ "${upd_from% }" = "${orch_from% }" ] \
            || { echo "$case_name: the updater goes back to [$upd_from], the orchestrator says [$orch_from]"; return 1; }
        # and both say what the history means (an agreement on "none" everywhere
        # would also be reached by a history that was never written)
        [ "${orch_from% }" = "$expected" ] \
            || { echo "$case_name: expected [$expected], got [$orch_from]"; echo "$updater_out"; return 1; }
    done
}
