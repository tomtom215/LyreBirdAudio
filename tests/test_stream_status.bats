#!/usr/bin/env bats
# The status document and file of lyrebird-stream-manager.sh (register: LB-03,
# D4, D5): what `status --json` prints, what every state-changing command
# records in the status file, the desired-state marker, and the one function
# that asks MediaMTX's API about a path. See tests/manager_stage.bash for what
# is real in these tests and what stands in for hardware, MediaMTX and FFmpeg;
# the field names of the real MediaMTX binaries are checked in
# tests/test_mediamtx_live.bats.

load scratch_tmpdir
load manager_stage

setup() {
    scratch_setup
    TEST_DIR="$(cd "$(dirname "$BATS_TEST_FILENAME")" && pwd)"
    PROJECT_ROOT="$(cd "$TEST_DIR/.." && pwd)"
    stage_setup
    STATUS="$LYREBIRD_STATE_DIR/status.json"
}

teardown() {
    stage_teardown
    scratch_teardown
}

# jq -e on $output: the filter must be true
json_true() {
    jq -e "$1" <<<"$output" >/dev/null
}

# ---------------------------------------------------------------------------
# mediamtx_path_info: the one place that asks the API about a path
# ---------------------------------------------------------------------------

@test "mediamtx_path_info: 0 with the object when MediaMTX has the path, 1 when it says there is none (404) [D4]" {
    echo '{"name":"mic1","ready":true,"bytesReceived":5}' >"$API/mic1.json"
    stage 'rc=0; mediamtx_path_info mic1 || rc=$?; echo " rc=$rc"'
    [ "$output" = '{"name":"mic1","ready":true,"bytesReceived":5} rc=0' ]
    stage 'rc=0; mediamtx_path_info nobody >/dev/null || rc=$?; echo "rc=$rc"'
    [ "$output" = "rc=1" ]
}

@test "mediamtx_path_info: an unreachable API, an authentication failure and an empty answer are 'not known' (2), never 'no such path' [D4]" {
    : >"$ST/api-down"
    stage 'rc=0; mediamtx_path_info mic1 >/dev/null || rc=$?; echo "down rc=$rc"'
    [ "$output" = "down rc=2" ]
    rm -f "$ST/api-down"

    # 401 and 500 answers, and a 200 with no body
    cat >"$ST/shim/curl" <<'CURL_EOF'
#!/bin/bash
printf '%s' "$FAKE_BODY"
printf '\n%s' "$FAKE_CODE"
CURL_EOF
    FAKE_CODE=401 FAKE_BODY='{"error":"authentication error"}' stage 'rc=0; mediamtx_path_info mic1 >/dev/null || rc=$?; echo "401 rc=$rc"'
    [ "$output" = "401 rc=2" ]
    FAKE_CODE=500 FAKE_BODY='boom' stage 'rc=0; mediamtx_path_info mic1 >/dev/null || rc=$?; echo "500 rc=$rc"'
    [ "$output" = "500 rc=2" ]
    FAKE_CODE=200 FAKE_BODY='' stage 'rc=0; mediamtx_path_info mic1 >/dev/null || rc=$?; echo "empty rc=$rc"'
    [ "$output" = "empty rc=2" ]
}

@test "mediamtx_json_inbound_bytes reads inboundBytes (MediaMTX >= 1.18), falls back to bytesReceived (1.15) and prefers the new name [D4]" {
    stage 'mediamtx_json_inbound_bytes "{\"ready\":true,\"bytesReceived\":10}"; echo; mediamtx_json_inbound_bytes "{\"inboundBytes\":20}"; echo; mediamtx_json_inbound_bytes "{\"inboundBytes\":30,\"bytesReceived\":31}"; echo; mediamtx_json_inbound_bytes "{\"ready\":true}" || echo none'
    [ "$output" = "$(printf '10\n20\n30\nnone')" ]
}

# ---------------------------------------------------------------------------
# The document
# ---------------------------------------------------------------------------

# One good microphone, one whose capture fails, brought up by the real start
two_streams_up() {
    device_add mic1 31
    device_add mic2 32
    bad_card 32
    stage 'COMMAND=start; start_mediamtx'
    [ "$status" -eq 0 ]
}

@test "status --json prints the schema, MediaMTX and, per stream, configured / process_alive / path_ready / bytes_flowing / last_error, and records it in the status file [D4]" {
    two_streams_up
    stage 'show_status --json'
    [ "$status" -eq 0 ]
    json_true '.schema_version == 1'
    json_true '(.timestamp | test("^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9:]{8}Z$")) and (.timestamp_epoch | type == "number")'
    json_true '.command == "status" and .policy == "degraded" and .stream_mode == "individual"'
    json_true '.overall == "degraded"'
    json_true ".mediamtx.running == true and .mediamtx.pid == $(mediamtx_pid)"
    json_true '(.streams | length) == 2'
    json_true '.streams[0] == {"device":"mic1","card":"31","path":"mic1","configured":true,"process_alive":true,"path_ready":true,"bytes_flowing":true,"last_error":null}'
    json_true '.streams[1] | .device == "mic2" and .path == "mic2" and .configured == false and .process_alive == false and .path_ready == false and .bytes_flowing == false and (.last_error | type == "string" and length > 0)'
    # the same document is the status file's content
    [ "$(cat "$STATUS")" = "$output" ]
    [ "$(stat -c %a "$STATUS")" = "644" ]
    [ "$(stat -c %a "$LYREBIRD_STATE_DIR")" = "755" ]
}

@test "the status file is rewritten by start, stop and force-stop; a stopped node is 'stopped' with no stream [D4]" {
    device_add mic1 31
    stage 'COMMAND=start; start_mediamtx'
    [ "$status" -eq 0 ]
    jq -e '.command == "start" and .overall == "ok" and .mediamtx.running == true and (.streams | length) == 1 and .streams[0].path_ready == true and .streams[0].bytes_flowing == true' "$STATUS"

    stage 'COMMAND=stop; stop_mediamtx'
    [ "$status" -eq 0 ]
    jq -e '.command == "stop" and .overall == "stopped" and .mediamtx.running == false and .mediamtx.pid == null and .streams == []' "$STATUS"

    stage 'COMMAND=start; start_mediamtx'
    [ "$status" -eq 0 ]
    jq -e '.overall == "ok"' "$STATUS"
    stage 'COMMAND=force-stop; force_stop_mediamtx'
    [ "$status" -eq 0 ]
    jq -e '.command == "force-stop" and .overall == "stopped" and .streams == []' "$STATUS"
}

@test "start with no device records waiting_for_devices [D5]" {
    stage 'COMMAND=start; start_mediamtx'
    [ "$status" -eq 0 ]
    jq -e '.command == "start" and .overall == "waiting_for_devices" and .mediamtx.running == true and .streams == []' "$STATUS"
}

@test "an API that does not answer gives path_ready and bytes_flowing null and says so, not 'false' [D4]" {
    device_add mic1 31
    stage 'COMMAND=start; start_mediamtx'
    [ "$status" -eq 0 ]
    : >"$ST/api-down"
    stage 'show_status --json'
    json_true '.streams[0] | .process_alive == true and .path_ready == null and .bytes_flowing == null and .last_error == "the MediaMTX API did not answer"'
    json_true '.overall == "failed"'
}

@test "a MediaMTX that is down while the node is meant to run is 'failed'; after stop it is 'stopped' [D4, D5]" {
    device_add mic1 31
    stage 'COMMAND=start; start_mediamtx'
    [ "$status" -eq 0 ]
    local mtx
    mtx="$(mediamtx_pid)"
    kill -KILL "$mtx"
    wait_until '! pid_running '"$mtx"
    stage 'show_status --json'
    json_true '.overall == "failed" and .mediamtx.running == false and .mediamtx.pid == null'
    json_true '.streams[0].last_error == "MediaMTX is not running"'
    stage 'COMMAND=stop; stop_mediamtx'
    stage 'show_status --json'
    json_true '.overall == "stopped"'
}

@test "the human status shows each stream's state, the overall state and where the status file is [D4]" {
    two_streams_up
    stage 'show_status'
    [ "$status" -eq 0 ]
    [[ "$output" == *"mic1: path ready, bytes flowing"* ]]
    [[ "$output" == *"mic2: path not ready, no bytes flowing"* ]]
    [[ "$output" == *"last error: "* ]]
    [[ "$output" == *"Overall: degraded (start policy: degraded)"* ]]
    [[ "$output" == *"Status file: $STATUS"* ]]
    jq -e '.command == "status" and .overall == "degraded"' "$STATUS"
}

@test "status rejects an unknown option and keeps a stopped node's output free of stream lines [D4]" {
    stage 'show_status --frobnicate'
    [ "$status" -ne 0 ]
    [[ "$output" == *"unknown status option '--frobnicate'"* ]]
    stage 'show_status'
    [ "$status" -eq 0 ]
    [[ "$output" == *"Overall: stopped"* ]]
    [[ "$output" != *"Streams (as MediaMTX sees them)"* ]]
}

@test "bytes_flowing reads the inbound counter of every MediaMTX generation (1.15 bytesReceived, 1.18+ both, a future inboundBytes only) [D4]" {
    device_add mic1 31
    local shape
    for shape in old new newonly; do
        echo "$shape" >"$ST/api-shape"
        stage 'COMMAND=start; start_mediamtx'
        [ "$status" -eq 0 ]
        stage 'show_status --json'
        json_true '.streams[0] | .path_ready == true and .bytes_flowing == true'
        stage 'COMMAND=stop; stop_mediamtx'
        [ "$status" -eq 0 ]
    done
}

@test "a counter that does not grow between the two samples is 'bytes_flowing: false' with the reason [D4]" {
    device_add mic1 31
    stage 'COMMAND=start; start_mediamtx'
    [ "$status" -eq 0 ]
    # a publisher that is connected but sends nothing: the object stays, frozen
    kill -STOP "$(ps -o pid= --ppid "$(stream_pid mic1)" | head -n1 | tr -d ' ')"
    stage 'show_status --json'
    json_true '.streams[0] | .path_ready == true and .bytes_flowing == false and (.last_error | test("did not grow"))'
    kill -CONT "$(ps -o pid= --ppid "$(stream_pid mic1)" | head -n1 | tr -d ' ')"
}

# ---------------------------------------------------------------------------
# The file
# ---------------------------------------------------------------------------

@test "json_string and the document survive quotes, backslashes, newlines and control characters in a device name [D4]" {
    cat >"$ST/code.sh" <<'CODE'
stream_outcome_reset
stream_outcome_add p1 $'we"ird\\back\nline\tTab\001' 7
OUTCOME_ERROR[p1]=$'bad "thing"\nhappened'
status_document test
CODE
    stage 'source "$ST/code.sh"'
    [ "$status" -eq 0 ]
    json_true '.streams[0].device == "we\"ird\\back\nline\tTab " and .streams[0].last_error == "bad \"thing\"\nhappened"'
}

@test "an unwritable status location never fails the command or the document [D4]" {
    device_add mic1 31
    LYREBIRD_STATUS_FILE=/proc/no-such-dir/status.json stage 'show_status --json'
    [ "$status" -eq 0 ]
    json_true '.schema_version == 1'
}

@test "the status file is replaced atomically: a reader never sees a partial document, and no temporary file is left [D4]" {
    device_add mic1 31
    stage 'COMMAND=start; start_mediamtx'
    [ "$status" -eq 0 ]
    local reader_out="$ST/reader.out"
    : >"$reader_out"
    (
        bad=0
        n=0
        while [[ ! -e "$ST/writers-done" ]]; do
            if [[ -s "$STATUS" ]]; then
                jq -e '.schema_version == 1' "$STATUS" >/dev/null 2>&1 || bad=$((bad + 1))
                n=$((n + 1))
            fi
        done
        echo "reads=$n bad=$bad" >"$reader_out"
    ) 3>&- &
    local reader=$!
    local i w
    local -a writers=()
    for i in 1 2 3; do
        stage_bg 'stream_outcome_reset; for i in $(seq 150); do status_publish test; done'
        writers+=("$STAGE_PID")
    done
    for w in "${writers[@]}"; do
        wait "$w"
    done
    : >"$ST/writers-done"
    wait "$reader"
    [[ "$(cat "$reader_out")" == *"bad=0" ]]
    [ "$(sed 's/reads=\([0-9]*\).*/\1/' "$reader_out")" -gt 10 ]
    # only the status file is there: no temporary file is left
    ! compgen -G "$LYREBIRD_STATE_DIR/.status.json.*" >/dev/null
    jq -e '.schema_version == 1' "$STATUS" >/dev/null
}

# ---------------------------------------------------------------------------
# The desired-state marker
# ---------------------------------------------------------------------------

@test "start writes the desired-state marker; stop and force-stop remove it; a refused stop leaves it [D5]" {
    device_add mic1 31
    local marker="$LYREBIRD_STATE_DIR/desired-running"
    [ ! -e "$marker" ]
    stage 'COMMAND=start; start_mediamtx'
    [ "$status" -eq 0 ]
    [ -s "$marker" ]

    # another lifecycle command holds the lock: stop is refused and changes nothing
    bash -c 'exec 8<>"$MEDIAMTX_LOCK_FILE"; flock -x 8; : >"$ST/holder.ready"; exec sleep 30' 3>&- &
    local holder=$!
    wait_until '[[ -e "$ST/holder.ready" ]]'
    stage 'COMMAND=stop; stop_mediamtx'
    [ "$status" -eq 5 ]
    [ -s "$marker" ]
    kill "$holder"

    stage 'COMMAND=stop; stop_mediamtx'
    [ "$status" -eq 0 ]
    [ ! -e "$marker" ]
    stage 'COMMAND=start; start_mediamtx'
    [ -s "$marker" ]
    stage 'COMMAND=force-stop; force_stop_mediamtx'
    [ ! -e "$marker" ]
}

@test "a start that is refused for ownership does not mark the node as meant to run [D5, D1]" {
    # a MediaMTX this manager did not start, on its configuration
    "$MEDIAMTX_BINARY" "$MEDIAMTX_CONFIG_DIR/mediamtx.yml" </dev/null >/dev/null 2>&1 3>&- &
    disown
    sleep 0.5
    stage 'COMMAND=start; start_mediamtx'
    [ "$status" -eq 8 ]
    [ ! -e "$LYREBIRD_STATE_DIR/desired-running" ]
}
