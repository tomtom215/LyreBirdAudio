#!/usr/bin/env bats
# What the orchestrator tells the user after it has started or restarted the
# streams (register: LB-21): the outcome the stream manager recorded (its status
# document), stream by stream, instead of an inference from state captured before
# the command ran; and every way that outcome can be unreadable. Real
# orchestrator, stand-ins for the delegated scripts, on a pseudo-terminal (see
# tests/orchestrator_helper.bash). tests/test_orchestrator_manager_contract.bats
# feeds the orchestrator documents written by the REAL stream manager.

load scratch_tmpdir
load orchestrator_helper

setup() {
    scratch_setup
    orch_setup
    command -v jq >/dev/null || skip "jq is needed"
}

teardown() {
    scratch_teardown
}

# streaming OPTION [PREAMBLE]: choose option 1 (start) or 3 (restart) in the
# Audio Streaming Control menu, press Enter at the pause, leave
streaming() {
    orch_run \
        --step 'Select option: ' "${1}\n" \
        --step 'Press Enter to continue' '\n' \
        --step 'Select option: ' '0\n' \
        "${2:-}
menu_streaming"
}

# The text before the pause: what the user read as the answer to the action
answer() {
    printf '%s' "${output%%Press Enter to continue*}"
}

# ---------------------------------------------------------------------------
# A start that exits 0
# ---------------------------------------------------------------------------

@test "start, exit 0, every stream publishing: each stream and the overall state are shown [LB-21]" {
    orch_doc "$ORCH_DIR/ok.json" ok true "mic1|true|true|" "mic2|true|true|"
    export STUB_DOC_start="$ORCH_DIR/ok.json"
    streaming 1
    echo "$output"
    [ "$status" -eq 0 ]
    [[ "$(answer)" == *"[OK] All 2 stream(s) are publishing"* ]]
    [[ "$(answer)" == *"[OK] mic1: publishing, bytes flowing"* ]]
    [[ "$(answer)" == *"[OK] mic2: publishing, bytes flowing"* ]]
    [[ "$(answer)" != *"[ERROR]"* ]]
    [[ "$(answer)" != *"Next steps"* ]]
}

@test "start, exit 0, one stream not publishing: degraded, with that stream's reason and what to do [LB-21]" {
    orch_doc "$ORCH_DIR/degraded.json" degraded true "mic1|true|true|" "mic2|false|false|the stream could not be started (see /var/lib/mediamtx-ffmpeg/mic2.log)"
    export STUB_DOC_start="$ORCH_DIR/degraded.json"
    streaming 1
    echo "$output"
    [ "$status" -eq 0 ]
    [[ "$(answer)" == *"Degraded: 1 of 2 streams are publishing"* ]]
    [[ "$(answer)" == *"[OK] mic1: publishing, bytes flowing"* ]]
    [[ "$(answer)" == *"[FAIL] mic2: not publishing - the stream could not be started (see /var/lib/mediamtx-ffmpeg/mic2.log)"* ]]
    [[ "$(answer)" == *"Next steps"* ]]
    [[ "$(answer)" == *"Start again: Audio Streaming Control -> Start All Streams"* ]]
    # exit 0 is not a failure
    [[ "$(answer)" != *"[ERROR]"* ]]
}

@test "start, exit 0, a stream whose path is ready but moves no bytes, and one whose state is unknown, are not called publishing [LB-21]" {
    orch_doc "$ORCH_DIR/odd.json" degraded true "mic1|true|false|the path is ready but its inbound byte counter did not grow in 3s" "mic2|null|null|the MediaMTX API did not answer"
    export STUB_DOC_start="$ORCH_DIR/odd.json"
    streaming 1
    echo "$output"
    [ "$status" -eq 0 ]
    [[ "$(answer)" == *"[!] mic1: path ready, but no bytes are flowing - the path is ready but its inbound byte counter did not grow in 3s"* ]]
    [[ "$(answer)" == *"[!] mic2: state unknown (the MediaMTX API did not answer) - the MediaMTX API did not answer"* ]]
}

@test "start, exit 0, no microphone: says MediaMTX is waiting for devices and what to do, not a failure [LB-21]" {
    orch_doc "$ORCH_DIR/waiting.json" waiting_for_devices true
    export STUB_DOC_start="$ORCH_DIR/waiting.json"
    : >"$ORCH_DIR/cron-file"
    streaming 1 "MONITOR_CRON_FILE='$ORCH_DIR/cron-file'"
    echo "$output"
    [ "$status" -eq 0 ]
    [[ "$(answer)" == *"MediaMTX is running and waiting for devices: no USB microphone is detected"* ]]
    [[ "$(answer)" == *"Plug in a USB microphone."* ]]
    [[ "$(answer)" == *"The monitor (cron job $ORCH_DIR/cron-file, every 5 minutes as shipped) starts its stream on its next run."* ]]
    [[ "$(answer)" == *"To start it right away: Audio Streaming Control -> Start All Streams."* ]]
    [[ "$(answer)" != *"[ERROR]"* ]]
    [[ "$(answer)" != *"fail"* ]]
}

@test "start, exit 0, no microphone and no monitor cron job: says nothing will pick the microphone up by itself [LB-21]" {
    orch_doc "$ORCH_DIR/waiting.json" waiting_for_devices true
    export STUB_DOC_start="$ORCH_DIR/waiting.json"
    streaming 1 "MONITOR_CRON_FILE='$ORCH_DIR/no-such-cron-file'"
    echo "$output"
    [ "$status" -eq 0 ]
    [[ "$(answer)" == *"No monitor cron job is installed ($ORCH_DIR/no-such-cron-file not found), so nothing will start the stream by itself."* ]]
    [[ "$(answer)" == *"To start it right away: Audio Streaming Control -> Start All Streams."* ]]
    [[ "$(answer)" != *"The monitor (cron job"* ]]
}

@test "start, exit 0, but the status says the node is failed: the contradiction is shown, not hidden [LB-21]" {
    orch_doc "$ORCH_DIR/failed.json" failed false "mic1|false|false|MediaMTX is not running"
    export STUB_DOC_start="$ORCH_DIR/failed.json"
    streaming 1
    echo "$output"
    [ "$status" -eq 0 ]
    [[ "$(answer)" == *"The start reported success, but the stream manager now reports the node as 'failed'"* ]]
    [[ "$(answer)" == *"[FAIL] mic1: not publishing - MediaMTX is not running"* ]]
}

# ---------------------------------------------------------------------------
# A start that exits 9: the start policy was not met
# ---------------------------------------------------------------------------

@test "start, exit 9, MediaMTX still up: 'MediaMTX is up but no stream is publishing', with each stream's reason [LB-21]" {
    orch_doc "$ORCH_DIR/failed.json" failed true "mic1|false|false|the stream could not be started (see mic1.log)" "mic2|false|false|device node /dev/snd/controlC4 does not exist"
    export STUB_DOC_start="$ORCH_DIR/failed.json" STUB_RC_stream_manager_start=9
    streaming 1
    echo "$output"
    [ "$status" -eq 0 ]
    [[ "$(answer)" == *"lyrebird-stream-manager.sh failed (exit code: 9 - no stream is publishing"* ]]
    [[ "$(answer)" == *"[ERROR] MediaMTX is up but no stream is publishing"* ]]
    [[ "$(answer)" == *"[FAIL] mic1: not publishing - the stream could not be started (see mic1.log)"* ]]
    [[ "$(answer)" == *"[FAIL] mic2: not publishing - device node /dev/snd/controlC4 does not exist"* ]]
    [[ "$(answer)" == *"Next steps"* ]]
    # not a success, and not the generic failure either
    [[ "$(answer)" != *"[OK]"* ]]
    [[ "$(answer)" != *"Degraded"* ]]
}

@test "start, exit 9, MediaMTX was stopped again: says so, instead of claiming it is up [LB-21]" {
    orch_doc "$ORCH_DIR/failed.json" failed false "mic1|false|false|the stream could not be started (see mic1.log)"
    export STUB_DOC_start="$ORCH_DIR/failed.json" STUB_RC_stream_manager_start=9
    streaming 1
    echo "$output"
    [ "$status" -eq 0 ]
    [[ "$(answer)" == *"[ERROR] No stream is publishing, and MediaMTX was stopped again: a failed start takes down what it started"* ]]
    [[ "$(answer)" != *"MediaMTX is up"* ]]
    [[ "$(answer)" == *"[FAIL] mic1: not publishing - the stream could not be started (see mic1.log)"* ]]
}

@test "start, exit 9 under the strict policy: names the policy; the streams that were publishing say why they were stopped [LB-21]" {
    ORCH_DOC_POLICY=strict orch_doc "$ORCH_DIR/strict.json" failed false "mic1|false|false|was publishing; stopped again because the start failed under policy 'strict'" "mic2|false|false|the stream could not be started (see mic2.log)"
    export STUB_DOC_start="$ORCH_DIR/strict.json" STUB_RC_stream_manager_start=9
    streaming 1
    echo "$output"
    [ "$status" -eq 0 ]
    [[ "$(answer)" == *"[ERROR] Not every stream is publishing, and the start policy 'strict' requires every stream: what the start started was stopped again"* ]]
    [[ "$(answer)" == *"[FAIL] mic1: not publishing - was publishing; stopped again because the start failed under policy 'strict'"* ]]
}

@test "restart, exit 9: the same report, worded for the restart [LB-21]" {
    orch_doc "$ORCH_DIR/failed.json" failed false "mic1|false|false|the stream could not be started (see mic1.log)"
    export STUB_DOC_restart="$ORCH_DIR/failed.json" STUB_RC_stream_manager_restart=9
    streaming 3
    echo "$output"
    [ "$status" -eq 0 ]
    grep -qx 'stream_manager restart' "$ORCH_CALLS"
    [[ "$(answer)" == *"[ERROR] No stream is publishing, and MediaMTX was stopped again: a failed restart takes down what it started"* ]]
    [[ "$(answer)" == *"[FAIL] mic1: not publishing"* ]]
}

# ---------------------------------------------------------------------------
# Starts that were refused or failed otherwise
# ---------------------------------------------------------------------------

@test "start refused (5, 8): the exit status is explained and an earlier status file is NOT reported as this start's outcome [LB-21]" {
    # The status file holds a healthy node from before; a start that is refused
    # writes nothing, so what the file says is not what this start did
    orch_doc "$ORCH_DIR/old.json" ok true "mic1|true|true|" "mic2|true|true|"
    cp "$ORCH_DIR/old.json" "$LYREBIRD_STATUS_FILE"
    export STUB_RC_stream_manager_start=5
    streaming 1
    echo "$output"
    [ "$status" -eq 0 ]
    [[ "$(answer)" == *"failed (exit code: 5 - another lifecycle command (start, stop or restart) is running; nothing was changed, try again shortly)"* ]]
    [[ "$(answer)" == *"Wait for the other start, stop or restart to finish, then try again."* ]]
    [[ "$(answer)" != *"mic1"* ]]
    [[ "$(answer)" != *"[OK]"* ]]

    export STUB_RC_stream_manager_start=8
    streaming 1
    echo "$output"
    [ "$status" -eq 0 ]
    [[ "$(answer)" == *"failed (exit code: 8 - another MediaMTX owns this node (for example mediamtx.service); nothing was changed)"* ]]
    [[ "$(answer)" == *"Stop the other MediaMTX first (for example: sudo systemctl stop mediamtx.service), then start again."* ]]
    [[ "$(answer)" != *"mic1"* ]]
}

@test "start failures 1, 3, 4, 6: each exit status is explained and gets its own next step [LB-21]" {
    local code fragment step
    while IFS='|' read -r code fragment step; do
        export STUB_RC_stream_manager_start="$code"
        streaming 1
        [ "$status" -eq 0 ] || { echo "$output"; return 1; }
        [[ "$(answer)" == *"failed (exit code: $code - $fragment"* ]] || { echo "$output"; echo "exit $code not explained as: $fragment"; return 1; }
        [[ "$(answer)" == *"$step"* ]] || { echo "$output"; echo "exit $code has no next step: $step"; return 1; }
    done <<'TABLE'
1|general error|Read the stream manager log: Logs & Status -> View Stream Manager Log.
3|a required tool or the MediaMTX binary is missing|Install what is missing (ffmpeg, jq, arecord, curl) or MediaMTX
4|invalid configuration|Validate Device Configuration
6|no USB audio device is detected|Plug in a USB microphone, then start again.
TABLE
}

@test "start that was not run at all (the script failed its integrity check): reported once, nothing invented [LB-21]" {
    streaming 1 'SCRIPT_CHECKSUMS[stream_manager]=0000'
    echo "$output"
    [ "$status" -eq 0 ]
    [[ "$(answer)" == *"SECURITY: Script modified since validation"* ]]
    [[ "$(answer)" != *"publishing"* ]]
    [[ "$(answer)" != *"Next steps"* ]]
    [ ! -s "$ORCH_CALLS" ]
}

# ---------------------------------------------------------------------------
# A status that is not there, not readable, or older than the command
# ---------------------------------------------------------------------------

@test "start, exit 0, no status file: the live state (status --json) is asked for and shown [LB-21]" {
    orch_doc "$ORCH_DIR/live.json" ok true "mic1|true|true|"
    export STUB_DOC_status_json="$ORCH_DIR/live.json"
    streaming 1
    echo "$output"
    [ "$status" -eq 0 ]
    grep -qx 'stream_manager status --json' "$ORCH_CALLS"
    [[ "$(answer)" == *"asking the stream manager for the live state"* ]]
    [[ "$(answer)" == *"[OK] All 1 stream(s) are publishing"* ]]
    [[ "$(answer)" == *"[OK] mic1: publishing, bytes flowing"* ]]
}

@test "start, exit 0, no status file and no answer to status --json: the exit status alone is reported, as unconfirmed [LB-21]" {
    export STUB_RC_stream_manager_status_json=1
    streaming 1
    echo "$output"
    [ "$status" -eq 0 ]
    [[ "$(answer)" == *"The start reported success (exit code 0), but the stream state could not be read (status --json exited with status 1); whether streams are publishing is not confirmed here"* ]]
    [[ "$(answer)" != *"[OK] All"* ]]
    # and the menu is still there
    [[ "$output" == *"Audio Streaming Control"*"Audio Streaming Control"* ]]
}

@test "start, exit 0, a status file that is not JSON: falls back to the live state, then to the exit status alone [LB-21]" {
    printf 'this is not json {' >"$ORCH_DIR/garbage.json"
    export STUB_DOC_start="$ORCH_DIR/garbage.json" STUB_RC_stream_manager_status_json=1
    streaming 1
    echo "$output"
    [ "$status" -eq 0 ]
    grep -qx 'stream_manager status --json' "$ORCH_CALLS"
    [[ "$(answer)" == *"but the stream state could not be read (status --json exited with status 1)"* ]]
    # with a good live answer the garbage file does not matter
    orch_doc "$ORCH_DIR/live.json" degraded true "mic1|true|true|" "mic2|false|false|no stream wrapper is running for this stream"
    export STUB_DOC_status_json="$ORCH_DIR/live.json"
    unset STUB_RC_stream_manager_status_json
    streaming 1
    [ "$status" -eq 0 ]
    [[ "$(answer)" == *"Degraded: 1 of 2 streams are publishing"* ]]
}

@test "start, exit 9, a status file that is not JSON: the exit status alone, no crash [LB-21]" {
    printf '\000\001garbage' >"$ORCH_DIR/garbage.json"
    export STUB_DOC_start="$ORCH_DIR/garbage.json" STUB_RC_stream_manager_start=9
    streaming 1
    echo "$output"
    [ "$status" -eq 0 ]
    [[ "$(answer)" == *"The start did not meet its start policy: no stream is publishing (exit code 9)"* ]]
    [[ "$(answer)" == *"Next steps"* ]]
    # no live query after a failure: the exit status is the answer
    ! grep -q 'status --json' "$ORCH_CALLS"
}

@test "without jq the orchestrator reports from the exit status alone [LB-21]" {
    orch_doc "$ORCH_DIR/ok.json" ok true "mic1|true|true|"
    export STUB_DOC_start="$ORCH_DIR/ok.json"
    streaming 1 'command_exists() { [[ "$1" != jq ]] && command -v "$1" >/dev/null 2>&1; }'
    echo "$output"
    [ "$status" -eq 0 ]
    [[ "$(answer)" == *"The start reported success (exit code 0), but the stream state could not be read (jq is not installed)"* ]]
    [[ "$(answer)" != *"[OK] All"* ]]
}

@test "start, exit 0, a status file of another schema version: not trusted [LB-21]" {
    jq -n '{schema_version: 2, overall: "ok", streams: []}' >"$ORCH_DIR/v2.json"
    export STUB_DOC_start="$ORCH_DIR/v2.json" STUB_RC_stream_manager_status_json=1
    streaming 1
    echo "$output"
    [ "$status" -eq 0 ]
    [[ "$(answer)" != *"[OK] All"* ]]
    [[ "$(answer)" == *"the stream state could not be read"* ]]
}

@test "parse_status_document: documents that are not a usable schema 1 status are refused with a reason, never an abort [LB-21]" {
    orch_run '
for doc in "" "[]" "42" "null" "{}" "{\"schema_version\":1}" "{\"schema_version\":1,\"overall\":\"ok\"}" \
    "{\"schema_version\":\"1\",\"overall\":\"ok\",\"streams\":[]}" "{\"schema_version\":1,\"overall\":\"ok\",\"streams\":[1]}" \
    "{\"schema_version\":1,\"overall\":7,\"streams\":[]}"; do
    reset_outcome
    rc=0
    parse_status_document "$doc" || rc=$?
    echo "DOC [$doc] rc=$rc overall=[$OUTCOME_OVERALL] problem=[$OUTCOME_PROBLEM]"
done
reset_outcome
parse_status_document "{\"schema_version\":1,\"overall\":\"rebooting\",\"policy\":\"x\",\"streams\":[]}"
echo "UNKNOWN overall=$OUTCOME_OVERALL policy=$OUTCOME_POLICY mediamtx=$OUTCOME_MEDIAMTX"'
    echo "$output"
    [ "$status" -eq 0 ]
    [ "$(grep -c '^DOC .* rc=1 overall=\[\] problem=\[the status document is not valid, or is not a schema_version 1 document\]$' <<<"$output")" -eq 10 ]
    [[ "$output" == *"UNKNOWN overall=unknown policy=unknown mediamtx=unknown"* ]]
}

@test "a reason from the status file is printed as text: no escape sequence in it reaches the terminal, no backslash in it is interpreted [LB-21]" {
    local esc
    esc="$(printf '\033')"
    orch_doc "$ORCH_DIR/evil.json" failed true "mic1|false|false|bad ${esc}[31mred and \\033[32m green \\n newline"
    # cat -v shows a control byte as ^X: none may be left in what is printed
    orch_run '
parse_status_document "$(cat "$ORCH_DIR/evil.json")"
printf "VALUE=[%s]\n" "${OUTCOME_S_ERROR[0]}" | cat -v
print_outcome_streams | grep mic1 | sed "s/^.*not publishing/LINE: not publishing/" | cat -v'
    echo "$output"
    [ "$status" -eq 0 ]
    # the ESC byte is gone from the value (cat -v would show it as ^[) ...
    [[ "$output" != *'^['* ]]
    [[ "$output" == *'VALUE=[bad [31mred and \033[32m green \n newline]'* ]]
    # ... and the literal backslash sequences are printed as typed, not interpreted
    [[ "$output" == *'LINE: not publishing - bad [31mred and \033[32m green \n newline'* ]]
}

@test "a status document with more than 100 streams lists 100 and counts the rest [LB-21]" {
    local specs=() i
    for ((i = 0; i < 130; i++)); do specs+=("mic$i|true|true|"); done
    orch_doc "$ORCH_DIR/many.json" ok true "${specs[@]}"
    export STUB_DOC_start="$ORCH_DIR/many.json"
    streaming 1
    [ "$status" -eq 0 ]
    [[ "$(answer)" == *"All 130 stream(s) are publishing"* ]]
    [ "$(grep -c '\[OK\] mic[0-9]*: publishing' <<<"$output")" -eq 100 ]
    [[ "$(answer)" == *"... and 30 more"* ]]
}

# ---------------------------------------------------------------------------
# State from before the command must not decide what is reported
# ---------------------------------------------------------------------------

@test "stale state, forwards: an earlier 'failed' status and 'MediaMTX stopped' processes do not hide a start that worked [LB-21]" {
    orch_doc "$ORCH_DIR/old.json" failed false "mic1|false|false|MediaMTX is not running"
    cp "$ORCH_DIR/old.json" "$LYREBIRD_STATUS_FILE"
    orch_doc "$ORCH_DIR/ok.json" ok true "mic1|true|true|"
    export STUB_DOC_start="$ORCH_DIR/ok.json"
    streaming 1
    echo "$output"
    [ "$status" -eq 0 ]
    [[ "$(answer)" == *"[OK] All 1 stream(s) are publishing"* ]]
    [[ "$(answer)" != *"MediaMTX is not running"* ]]
}

@test "stale state, backwards: an earlier 'ok' status and running processes do not hide a start that failed [LB-21]" {
    export STUB_PGREP_MEDIAMTX=1 STUB_PGREP_FFMPEG=2
    orch_doc "$ORCH_DIR/old.json" ok true "mic1|true|true|" "mic2|true|true|"
    cp "$ORCH_DIR/old.json" "$LYREBIRD_STATUS_FILE"
    orch_doc "$ORCH_DIR/failed.json" failed false "mic1|false|false|the stream could not be started (see mic1.log)" "mic2|false|false|the stream could not be started (see mic2.log)"
    export STUB_DOC_start="$ORCH_DIR/failed.json" STUB_RC_stream_manager_start=9
    streaming 1
    echo "$output"
    [ "$status" -eq 0 ]
    [[ "$(answer)" == *"[ERROR] No stream is publishing"* ]]
    [[ "$(answer)" != *"[OK]"* ]]
}

@test "the exit status, the verdict and where the state came from are logged [LB-21]" {
    orch_doc "$ORCH_DIR/failed.json" failed true "mic1|false|false|x"
    export STUB_DOC_start="$ORCH_DIR/failed.json" STUB_RC_stream_manager_start=9
    streaming 1
    [ "$status" -eq 0 ]
    grep -q 'stream manager start: exit status 9, verdict streams_failed, state failed (status file)' "$ORCH_DIR/orchestrator.log"
}

@test "the menu no longer collapses a start or restart with '|| true' [LB-21]" {
    # The exit status is what tells "no stream is publishing" (9) from "busy" (5)
    # from "another MediaMTX owns this node" (8); `|| true` on the call discards it
    ! grep -nE 'execute_script +"stream_manager" +(start|restart)( +\|\| +true)' "$ORCH_ROOT/lyrebird-orchestrator.sh" || false
    [ "$(grep -c 'run_stream_lifecycle \(start\|restart\)$' "$ORCH_ROOT/lyrebird-orchestrator.sh")" -ge 2 ]
}
