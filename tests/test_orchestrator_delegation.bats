#!/usr/bin/env bats
# What the orchestrator's execute_script does with the exit status of the script
# it delegates to (register: LB-21): the real status is kept, a failure is shown
# or recorded, and the stream manager's and the updater's exit codes are
# explained in one line each. Real orchestrator, stand-ins for the six
# delegated scripts, on a pseudo-terminal (see tests/orchestrator_helper.bash).

load scratch_tmpdir
load orchestrator_helper

setup() {
    scratch_setup
    orch_setup
}

teardown() {
    scratch_teardown
}

@test "execute_script keeps the real exit status of every delegated script, and a failure is shown or recorded [LB-21]" {
    # A script that fails with 7: whichever of the six it is, the status must be
    # available afterwards and the failure must not vanish (the menus call
    # `execute_script ... || true`, which discards the return value)
    export STUB_RC_default=7
    orch_run '
for key in installer stream_manager usb_mapper mic_check updater diagnostics; do
    out="$(mktemp)"
    LAST_ERROR=""
    LAST_EXIT_CODE=""
    execute_script "$key" probe >"$out" 2>&1 || true
    if [[ "$LAST_EXIT_CODE" != 7 ]]; then
        echo "LOST $key: the exit status was not kept (LAST_EXIT_CODE=[$LAST_EXIT_CODE])"
    elif ! grep -q "exit code" "$out" && [[ -z "$LAST_ERROR" ]]; then
        echo "LOST $key: the failure was neither shown nor recorded"
    else
        echo "KEPT $key"
    fi
done'
    echo "$output"
    [ "$status" -eq 0 ]
    [[ "$output" != *"LOST"* ]]
    local key
    for key in installer stream_manager usb_mapper mic_check updater diagnostics; do
        [[ "$output" == *"KEPT $key"* ]]
    done
}

@test "execute_script: LAST_EXIT_CODE is 0 after a success and empty after a call that ran nothing [LB-21]" {
    orch_run '
LAST_EXIT_CODE=99
execute_script stream_manager status >/dev/null 2>&1
echo "after success: [$LAST_EXIT_CODE]"
LAST_EXIT_CODE=99
rc=0
execute_script no_such_script >/dev/null 2>&1 || rc=$?
echo "unknown key: rc=$rc [$LAST_EXIT_CODE]"
SCRIPT_CHECKSUMS[stream_manager]=0000
LAST_EXIT_CODE=99
rc=0
execute_script stream_manager status >/dev/null 2>&1 || rc=$?
echo "integrity: rc=$rc [$LAST_EXIT_CODE]"'
    echo "$output"
    [ "$status" -eq 0 ]
    [[ "$output" == *"after success: [0]"* ]]
    [[ "$output" == *"unknown key: rc=1 []"* ]]
    [[ "$output" == *"integrity: rc=1 []"* ]]
    # and nothing was run for the last two
    [ "$(grep -c '^stream_manager status' "$ORCH_CALLS")" -eq 1 ]
}

@test "execute_script explains each exit code of the stream manager in one line [LB-21]" {
    orch_run '
for code in 1 2 3 4 5 6 7 8 9 10 130 143 77; do
    export STUB_RC_default=$code
    LAST_ERROR=""
    execute_script stream_manager start >/dev/null 2>&1 || true
    echo "CODE $code [$LAST_EXIT_CODE] $LAST_ERROR"
done'
    echo "$output"
    [ "$status" -eq 0 ]
    while IFS='|' read -r code fragment; do
        grep -F "CODE $code [$code] lyrebird-stream-manager.sh failed (exit code: $code - " <<<"$output" | grep -qF "$fragment" \
            || { echo "exit code $code is not explained as '$fragment'"; return 1; }
    done <<'TABLE'
1|general error
2|critical resource state
3|missing
4|invalid configuration
5|another lifecycle command
6|no USB audio device
7|MediaMTX is not running
8|another MediaMTX owns this node
9|no stream is publishing
10|not publishing
130|SIGINT
143|SIGTERM
TABLE
    # a status with no documented meaning is still shown, without a made-up one
    [[ "$output" == *"CODE 77 [77] lyrebird-stream-manager.sh failed (exit code: 77)"* ]]
}

@test "execute_script explains each exit code of the updater in one line [LB-21]" {
    orch_run '
for code in 1 2 3 4 5 6 7 8 9 10 11; do
    export STUB_RC_default=$code
    LAST_ERROR=""
    execute_script updater --rollback >/dev/null 2>&1 || true
    echo "CODE $code [$LAST_EXIT_CODE] $LAST_ERROR"
done'
    echo "$output"
    [ "$status" -eq 0 ]
    while IFS='|' read -r code fragment; do
        grep -F "CODE $code [$code] lyrebird-updater.sh failed (exit code: $code - " <<<"$output" | grep -qF "$fragment" \
            || { echo "exit code $code is not explained as '$fragment'"; return 1; }
    done <<'TABLE'
1|general error
2|prerequisites
3|not a git repository
4|could not reach the remote
5|permission problem
6|not available in this clone
7|another updater is running
8|unusable git state
9|cancelled
10|saved changes conflict
11|could not restore everything
TABLE
}

@test "execute_script shows the explained failure and records it as the last error [LB-21]" {
    export STUB_RC_stream_manager_start=9
    orch_run 'execute_script stream_manager start || true; echo "LAST_ERROR=$LAST_ERROR"'
    echo "$output"
    [ "$status" -eq 0 ]
    [[ "$output" == *"[ERROR] lyrebird-stream-manager.sh failed (exit code: 9 - no stream is publishing"* ]]
    [[ "$output" == *"LAST_ERROR=lyrebird-stream-manager.sh failed (exit code: 9 - no stream is publishing"* ]]
}

@test "execute_script: the privilege-dropped updater keeps and explains its exit status too [LB-21]" {
    # `sudo -u USER env -i ...` stand-in: drop the first four words, run the rest
    cat >"$ORCH_DIR/bin/sudo" <<'SUDO_EOF'
#!/bin/bash
shift 4
exec env "$@"
SUDO_EOF
    chmod +x "$ORCH_DIR/bin/sudo"
    export SUDO_USER=nobody STUB_RC_updater___rollback=6
    orch_run 'execute_script updater --rollback || true; echo "LAST_EXIT_CODE=$LAST_EXIT_CODE"'
    echo "$output"
    [ "$status" -eq 0 ]
    [[ "$output" == *"LAST_EXIT_CODE=6"* ]]
    [[ "$output" == *"lyrebird-updater.sh failed (exit code: 6 - that version is not available in this clone"* ]]
}

@test "MediaMTX menu: every installer action reports its failure with the exit status before the pause [LB-21]" {
    export STUB_RC_default=5
    orch_run \
        --step 'Select option: ' '1\n' --step 'Press Enter to continue' '\n' \
        --step 'Select option: ' '2\n' --step 'Press Enter to continue' '\n' \
        --step 'Select option: ' '3\n' --step 'Continue\? \(y/n\)' 'y' --step 'Press Enter to continue' '\n' \
        --step 'Select option: ' '4\n' --step 'Are you sure\? \(y/n\)' 'y' --step 'Press Enter to continue' '\n' \
        --step 'Select option: ' '0\n' \
        'menu_mediamtx'
    echo "$output"
    [ "$status" -eq 0 ]
    local action
    for action in installation update reinstallation uninstallation; do
        [[ "$output" == *"[ERROR] MediaMTX ${action} failed (installer exit code: 5); see the installer's message above"* ]] \
            || { echo "no failure line for the ${action}"; return 1; }
    done
    # right after the action, not only in the next redraw's "Last Error"
    [[ "${output%%Press Enter to continue*}" == *"installer exit code: 5"* ]]
}

@test "MediaMTX menu: installer exit status 7 is explained as already installed or a failed step, 0 is silent [LB-21]" {
    export STUB_RC_installer_install=7
    orch_run --step 'Select option: ' '1\n' --step 'Press Enter to continue' '\n' --step 'Select option: ' '0\n' 'menu_mediamtx'
    echo "$output"
    [ "$status" -eq 0 ]
    [[ "$output" == *"The installer exited with code 7: MediaMTX is already installed (use Update or Reinstall), or an install step failed"* ]]
    export STUB_RC_installer_install=0
    orch_run --step 'Select option: ' '1\n' --step 'Press Enter to continue' '\n' --step 'Select option: ' '0\n' 'menu_mediamtx'
    [ "$status" -eq 0 ]
    [[ "$output" != *"installer exit code"* ]]
    [[ "$output" != *"exited with code"* ]]
}
