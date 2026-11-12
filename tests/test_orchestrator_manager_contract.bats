#!/usr/bin/env bats
# The orchestrator reads the status document the stream manager writes
# (register: LB-21 on the reading side, LB-03/D4/D5 on the writing side). Every
# other orchestrator test feeds it a document a test built; these feed it the
# document the REAL stream manager wrote (tests/manager_stage.bash: the real
# start_mediamtx, wrappers, lock and status file; hardware, MediaMTX and FFmpeg
# are stand-ins), so a change to the manager's schema or to what its exit 9
# leaves behind cannot pass unnoticed.

load scratch_tmpdir
load manager_stage
load orchestrator_helper

setup() {
    scratch_setup
    TEST_DIR="$(cd "$(dirname "$BATS_TEST_FILENAME")" && pwd)"
    PROJECT_ROOT="$(cd "$TEST_DIR/.." && pwd)"
    command -v jq >/dev/null || skip "jq is needed"
    stage_setup
    # after stage_setup, which unsets it: the manager and the orchestrator share one file
    orch_setup
    STATUS_FILE="$LYREBIRD_STATUS_FILE"
}

teardown() {
    stage_teardown
    scratch_teardown
}

# read_outcome RC: the orchestrator reads the status file the real manager left
# and classifies a start that exited with RC
read_outcome() {
    orch_run "
parse_status_document \"\$(status_file_content)\" || echo \"UNPARSED: \$OUTCOME_PROBLEM\"
OUTCOME_SOURCE='status file'
LIFECYCLE_RC=$1
classify_lifecycle $1
echo \"VERDICT=\$LIFECYCLE_VERDICT OVERALL=\$OUTCOME_OVERALL POLICY=\$OUTCOME_POLICY MEDIAMTX=\$OUTCOME_MEDIAMTX TOTAL=\$OUTCOME_TOTAL READY=\$OUTCOME_READY\"
print_outcome_streams
report_lifecycle start"
}

@test "a document the real manager wrote after a good start is read as ok, stream by stream [LB-21, D4]" {
    device_add mic1 31
    device_add mic2 32
    stage 'COMMAND=start; start_mediamtx'
    [ "$status" -eq 0 ]
    read_outcome 0
    echo "$output"
    [ "$status" -eq 0 ]
    [[ "$output" == *"VERDICT=ok OVERALL=ok POLICY=degraded MEDIAMTX=true TOTAL=2 READY=2"* ]]
    [[ "$output" == *"[OK] mic1: publishing, bytes flowing"* ]]
    [[ "$output" == *"[OK] mic2: publishing, bytes flowing"* ]]
    [[ "$output" == *"[OK] All 2 stream(s) are publishing"* ]]
}

@test "a document the real manager wrote after a degraded start names the stream that is not publishing and why [LB-21, D4]" {
    device_add mic1 31
    device_add mic2 32
    bad_card 32
    stage 'COMMAND=start; start_mediamtx'
    [ "$status" -eq 0 ]
    read_outcome 0
    echo "$output"
    [ "$status" -eq 0 ]
    [[ "$output" == *"VERDICT=degraded OVERALL=degraded POLICY=degraded MEDIAMTX=true TOTAL=2 READY=1"* ]]
    [[ "$output" == *"[OK] mic1: publishing, bytes flowing"* ]]
    # the manager's own reason, whatever its wording, follows the stream
    [[ "$output" == *"[FAIL] mic2: not publishing - "?* ]]
    [[ "$output" == *"Degraded: 1 of 2 streams are publishing"* ]]
}

@test "a document the real manager wrote for an empty start is read as waiting_for_devices [LB-21, D5]" {
    stage 'COMMAND=start; start_mediamtx'
    [ "$status" -eq 0 ]
    read_outcome 0
    echo "$output"
    [ "$status" -eq 0 ]
    [[ "$output" == *"VERDICT=waiting OVERALL=waiting_for_devices POLICY=degraded MEDIAMTX=true TOTAL=0 READY=0"* ]]
    [[ "$output" == *"MediaMTX is running and waiting for devices"* ]]
    [[ "$output" == *"Plug in a USB microphone."* ]]
}

@test "after the real manager's start exits 9, MediaMTX is down and every stream says why: the report says so [LB-21, LB-03, D4]" {
    # The orchestrator's claim for exit 9: when the document says MediaMTX is not
    # running the failed start took it down again ("MediaMTX is up but ..." only
    # when it is up). This is what the manager does.
    device_add mic1 31
    bad_card 31
    stage 'COMMAND=start; rc=0; start_mediamtx || rc=$?; echo "start exited $rc"; exit "$rc"'
    [ "$status" -eq 9 ]
    read_outcome 9
    echo "$output"
    [ "$status" -eq 0 ]
    [[ "$output" == *"VERDICT=streams_failed OVERALL=failed POLICY=degraded MEDIAMTX=false TOTAL=1 READY=0"* ]]
    [[ "$output" == *"[FAIL] mic1: not publishing - "?* ]]
    [[ "$output" == *"[ERROR] No stream is publishing, and MediaMTX was stopped again: a failed start takes down what it started"* ]]
    [[ "$output" != *"MediaMTX is up"* ]]
}

@test "after the real manager's start exits 9 on a node that was already running, MediaMTX stays up: the report says that [LB-21, LB-01, D4]" {
    # The repeated start of LB-01 never touches a stack that was already running, so
    # when it fails under the strict policy MediaMTX is still up
    device_add mic1 31
    stage 'COMMAND=start; start_mediamtx'
    [ "$status" -eq 0 ]
    device_add mic2 32
    bad_card 32
    stage 'COMMAND=start; export LYREBIRD_START_POLICY=strict; rc=0; start_mediamtx || rc=$?; exit "$rc"'
    [ "$status" -eq 9 ]
    read_outcome 9
    echo "$output"
    [ "$status" -eq 0 ]
    [[ "$output" == *"VERDICT=streams_failed OVERALL="* ]]
    [[ "$output" == *"POLICY=strict MEDIAMTX=true"* ]]
    [[ "$output" == *"[ERROR] Not every stream is publishing, and the start policy 'strict' requires every stream"* ]]
    [[ "$output" == *"[FAIL] mic2: not publishing - "?* ]]
}

@test "the manager's own 'status --json' document is read the same way as the file [LB-21, D4]" {
    device_add mic1 31
    stage 'COMMAND=start; start_mediamtx'
    [ "$status" -eq 0 ]
    stage 'show_status --json'
    [ "$status" -eq 0 ]
    printf '%s\n' "$output" >"$ORCH_DIR/live.json"
    orch_run '
parse_status_document "$(cat "$ORCH_DIR/live.json")" || echo "UNPARSED: $OUTCOME_PROBLEM"
echo "OVERALL=$OUTCOME_OVERALL TOTAL=$OUTCOME_TOTAL READY=$OUTCOME_READY MEDIAMTX=$OUTCOME_MEDIAMTX"'
    echo "$output"
    [ "$status" -eq 0 ]
    [[ "$output" == *"OVERALL=ok TOTAL=1 READY=1 MEDIAMTX=true"* ]]
}
