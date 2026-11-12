#!/usr/bin/env bats
# The interactive menu's exit-status contract (finding U-18): a switch or reset
# that fails is reported and the menu stays open, Q leaves with the status of
# the last switch or reset, and end of input at a prompt is a clean quit with
# its own status (12) and a message, never a silent 1. Everything is driven
# through stdin against the real script and real git repositories: see
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
    updater_checkout v1.1.0
}

teardown() {
    scratch_teardown
}

# _menu_run LINES...: the menu with exactly LINES on stdin (each ended by a
# newline; after the last one the input is closed). A leading "y" answers the
# root prompt when the suite runs as root. With MENU_NO_FINAL_NEWLINE set the
# last line has no newline.
_menu_run() {
    updater_stdin "$@"
    if [[ -n "${MENU_NO_FINAL_NEWLINE:-}" ]]; then
        UPDATER_INPUT="${UPDATER_INPUT%$'\n'}"
    fi
    run env "${UPDATER_SIGNAL_ARGS[@]}" PATH="$SHIMS:$PATH" bash "$REPO/lyrebird-updater.sh" \
        < <(printf '%s' "$UPDATER_INPUT")
    unset UPDATER_INPUT
}

# ============================================================================
# A failed action does not end the run
# ============================================================================

@test "a switch that fails is reported and the menu stays open; Q leaves with its status" {
    _menu_run 3 v9.9.9 "" 5 "" q
    [ "$status" -eq 1 ]
    [[ "$output" == *"Version 'v9.9.9' does not exist"* ]]
    [[ "$output" == *"That did not complete (exit status 1). The menu is still open."* ]]
    # the menu was still there: the status screen was reachable afterwards
    [[ "$output" == *"=== Repository Status ==="* ]]
    [[ "$output" == *"Thank you for using"* ]]
    [ "$(updater_head)" = "v1.1.0" ]
}

@test "a failed action followed by a successful one: Q leaves with the last action's status" {
    _menu_run 3 v9.9.9 "" 3 v1.2.0 "" q
    [ "$status" -eq 0 ]
    [ "$(updater_head)" = "v1.2.0" ]
    [[ "$output" == *"That did not complete (exit status 1)"* ]]
    [[ "$output" == *"Thank you for using"* ]]
}

@test "every switch option reports its failure and carries on: options 1 and 2 refused in the middle of a merge (exit 8)" {
    touch "$REPO/.git/MERGE_HEAD"
    _menu_run 1 "" 2 "" q
    rm -f "$REPO/.git/MERGE_HEAD"
    [ "$status" -eq 8 ]
    [ "$(grep -c 'That did not complete (exit status 8)' <<<"$output")" -eq 2 ]
    [[ "$output" == *"Thank you for using"* ]]
    [ "$(updater_head)" = "v1.1.0" ]
}

@test "a reset that fails is reported and the menu stays open; Q leaves with its status" {
    updater_checkout main
    touch "$REPO/.git/MERGE_HEAD"
    _menu_run 6 1 "" 5 "" q
    rm -f "$REPO/.git/MERGE_HEAD"
    [ "$status" -eq 8 ]
    [[ "$output" == *"Git merge in progress"* ]]
    [[ "$output" == *"That did not complete (exit status 8)"* ]]
    [[ "$output" == *"=== Repository Status ==="* ]]
}

@test "a status or help screen shown after a failure does not hide it" {
    _menu_run 3 v9.9.9 "" 5 "" h "" 4 "" q
    [ "$status" -eq 1 ]
    [[ "$output" == *"EXIT STATUS OF THE MENU"* ]]
}

@test "the menu leaves with 0 when nothing failed" {
    _menu_run 5 "" q
    [ "$status" -eq 0 ]
}

@test "an action that returns with its transaction still open is rolled back, so the menu is not left refusing every later action" {
    run bash -c '
        cd "$1" || exit 90
        export LYREBIRD_UPDATER_STATE_DIR="$2"
        source "$3"
        set +e
        stub() { transaction_begin "stub" "" "" update; return 3; }
        menu_run stub
        echo "active=${TRANSACTION_STATE[active]} last=${MENU_LAST_STATUS} journal=$([[ -e "$JOURNAL_FILE" ]] && echo present || echo absent)"
        stub_ok() { transaction_begin "stub" "" "" update; return 0; }
        menu_run stub_ok
        echo "active=${TRANSACTION_STATE[active]} last=${MENU_LAST_STATUS}"
    ' _ "$REPO" "$TEST_SCRATCH/state" "$REPO/lyrebird-updater.sh"
    [ "$status" -eq 0 ] || { echo "$output"; return 1; }
    [[ "$output" == *"active=false last=3 journal=absent"* ]]
    [[ "$output" == *"active=false last=1"* ]]
}

# ============================================================================
# End of input at a prompt
# ============================================================================

# nothing may be left behind by a run that ended at EOF: the lock is free and
# core.fileMode is back where it was
_left_clean() {
    flock -n "$(updater_lock_path)" true
    [ ! -e "$REPO/.git/lyrebird-updater/core.fileMode.saved" ]
}

@test "end of input at any prompt leaves with 12 and says why, and the run cleans up after itself" {
    local -a cases=("" "5" "3" "6" "6 3")
    local c
    for c in "${cases[@]}"; do
        # shellcheck disable=SC2086  # the words of the case are the lines typed
        _menu_run $c
        [ "$status" -eq 12 ] || { echo "input [$c]: status $status"; echo "$output"; return 1; }
        [[ "$output" == *"Input ended (end of file) at a prompt: leaving the version manager."* ]] || { echo "input [$c]: $output"; return 1; }
        [[ "$output" == *"Exit status 12 means the input ended"* ]]
        _left_clean
    done
}

@test "end of input after a failed action also says what that action ended with" {
    _menu_run 3 v9.9.9 ""
    [ "$status" -eq 12 ]
    [[ "$output" == *"The last action ended with exit status 1."* ]]
}

@test "a last line without a newline is still an answer" {
    MENU_NO_FINAL_NEWLINE=1 _menu_run q
    [ "$status" -eq 0 ]
    [[ "$output" == *"Thank you for using"* ]]
}

@test "--help documents the menu's exit status" {
    updater_run --help
    [ "$status" -eq 0 ]
    [[ "$output" == *"with the status of the last switch or reset"* ]]
    [[ "$output" == *"leaves with status 12"* ]]
}
