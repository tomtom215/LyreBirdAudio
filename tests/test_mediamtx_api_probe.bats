#!/usr/bin/env bats
# Readiness and health probes of the MediaMTX control API (register: LB-13).
#
# The old code used `curl -s` with no status and no shape check: a 404, a 401, a
# 500 or any garbage counted as "ready", so a MediaMTX that was not serving
# anything looked up, the API-version fallback could never fire, and against an
# authenticated API a healthy stream looked not ready and was restarted after
# three monitor runs. These tests run the real wait_for_mediamtx_ready,
# detect_mediamtx_api_version, probe_stream_ready and deep_stream_unhealthy
# against a stub HTTP server on a private port (tests/helpers/mediamtx/
# http_stub.py) that answers what each row of the tables says, with the real
# curl. test_mediamtx_api_live.bats does the same against real MediaMTX
# binaries.

load scratch_tmpdir
load mediamtx_live_helper

LIST='{"itemCount":0,"pageCount":0,"items":[]}'
LIST_WITH_ONE='{"itemCount":1,"pageCount":1,"items":[{"name":"mic1","ready":true,"available":true}]}'
PATH_READY='{"name":"mic1","ready":true,"available":true}'
PATH_READY_OLD='{"name":"mic1","ready":true}'
PATH_NOT_READY='{"name":"mic1","ready":false,"available":false}'
NOT_FOUND='{"status":"error","error":"path not found"}'
UNAUTH='{"status":"error","error":"authentication error"}'

setup() {
    scratch_setup
    PROJECT_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
    SM="$PROJECT_ROOT/lyrebird-stream-manager.sh"
    D="$TEST_SCRATCH/d"
    mkdir -p "$D/strikes"
    HELD_PIDS=()
    mtx_ports_setup
    echo '{}' >"$TEST_SCRATCH/stub-plan.json"
    export MEDIAMTX_HOST=127.0.0.1 MEDIAMTX_API_PORT="$P_API"
    export MEDIAMTX_LOG_FILE="$D/sm.log" STREAM_MANAGER_LOG_FILE="$D/sm.log" MEDIAMTX_FFMPEG_DIR="$D/ff" MEDIAMTX_CONFIG_DIR="$D/cfg"
    export DEEP_HEALTH_STATE_DIR="$D/strikes" DEEP_HEALTH_MAX_STRIKES=3
    unset MEDIAMTX_API_VERSION MEDIAMTX_API_FALLBACK
    sleep 300 3>&- &
    ALIVE_PID=$!
    HELD_PIDS+=("$ALIVE_PID")
}

teardown() {
    local pid
    for pid in "${HELD_PIDS[@]:-}"; do
        [[ -n "$pid" ]] && kill -9 "$pid" 2>/dev/null || true
    done
    mtx_cleanup
    scratch_teardown
}

# plan_reset; plan_route PATH STATUS BODY [DELAY]; plan_default STATUS BODY
plan_reset() {
    echo '{}' >"$TEST_SCRATCH/plan.json"
    stub_plan "$(cat "$TEST_SCRATCH/plan.json")"
}

plan_route() {
    jq -c --arg p "$1" --argjson s "$2" --arg b "$3" --argjson d "${4:-0}" --argjson t "${5:-false}" --argjson x "${6:-false}" \
        '.routes[$p] = {status: $s, body: $b, delay: $d, truncate: $t, drop: $x}' "$TEST_SCRATCH/plan.json" >"$TEST_SCRATCH/plan.new"
    mv -f "$TEST_SCRATCH/plan.new" "$TEST_SCRATCH/plan.json"
    stub_plan "$(cat "$TEST_SCRATCH/plan.json")"
}

plan_default() {
    jq -c --argjson s "$1" --arg b "$2" '.default = {status: $s, body: $b}' "$TEST_SCRATCH/plan.json" >"$TEST_SCRATCH/plan.new"
    mv -f "$TEST_SCRATCH/plan.new" "$TEST_SCRATCH/plan.json"
    stub_plan "$(cat "$TEST_SCRATCH/plan.json")"
}

start_stub() {
    plan_reset
    stub_start "$P_API"
}

requests() {
    cat "$TEST_SCRATCH/stub.log"
}

# The last line of $output
last_line() {
    printf '%s' "${output##*$'\n'}"
}

# Run CODE with the real stream manager sourced. WITHOUT_JQ=1 hides jq from it.
sm() {
    bash -c '
        source "$1" >/dev/null 2>&1
        set +e
        if [[ "${WITHOUT_JQ:-}" == 1 ]]; then
            command_exists() { [[ "$1" == jq ]] && return 1; command -v "$1" >/dev/null 2>&1; }
        fi
        eval "$2"' _ "$SM" "$1"
}

# wait_for_mediamtx_ready against the live ALIVE_PID, given at most $1 seconds
ready_within() {
    MEDIAMTX_API_TIMEOUT="$1" run sm "wait_for_mediamtx_ready $ALIVE_PID"
}

# ---------------------------------------------------------------------------
# wait_for_mediamtx_ready
# ---------------------------------------------------------------------------

@test "readiness: a 200 with a paths list is ready, at once [LB-13]" {
    start_stub
    plan_route /v3/paths/list 200 "$LIST"
    ready_within 5
    [ "$status" -eq 0 ]
    [[ "$output" == *"MediaMTX API is ready after 0 seconds"* || "$(<"$D/sm.log")" == *"MediaMTX API is ready after 0 seconds"* ]]
    [ "$(requests)" = "GET /v3/paths/list" ]
}

@test "readiness: a paths list with entries is ready too, with and without jq [LB-13]" {
    start_stub
    plan_route /v3/paths/list 200 "$LIST_WITH_ONE"
    ready_within 5
    [ "$status" -eq 0 ]
    WITHOUT_JQ=1 ready_within 5
    [ "$status" -eq 0 ]
}

@test "readiness: a 200 that is not a paths list is not ready, with and without jq [LB-13]" {
    start_stub
    local body
    for body in 'not json at all' '<html><body>It works!</body></html>' '' '{}' '[]' 'null' '"string"' '{"itemCount":0}' \
        '{"items":{}}' '{"items":"x"}' '{"items":null}' '{"error":"x"}' '{"items":[]'; do
        plan_route /v3/paths/list 200 "$body"
        plan_route /v2/paths/list 200 "$body"
        plan_route /v1/paths/list 200 "$body"
        plan_route /paths/list 200 "$body"
        ready_within 1
        [ "$status" -eq 1 ] || {
            echo "ready on [$body] with jq"
            false
        }
        WITHOUT_JQ=1 ready_within 1
        [ "$status" -eq 1 ] || {
            echo "ready on [$body] without jq"
            false
        }
    done
    # and it does not go looking at older prefixes: this prefix answered
    ! requests | grep -q '/v2/\|/v1/\|^GET /paths'
}

@test "readiness: a 404 everywhere, a 5xx, a redirect and any other status are not ready [LB-13]" {
    start_stub
    local code
    for code in 404 500 502 503 301 302 204 202 400 405 410 418; do
        plan_default "$code" "$NOT_FOUND"
        ready_within 1
        [ "$status" -eq 1 ] || {
            echo "ready on HTTP $code"
            false
        }
    done
    plan_default 404 "404 page not found"
    ready_within 1
    [ "$status" -eq 1 ]
    [[ "$(<"$D/sm.log")" == *"did not become ready within 1 seconds (notready at http://127.0.0.1:${P_API}/v3, last HTTP status 404)"* ]]
}

@test "readiness: a 401 or 403 means MediaMTX is up behind an authenticated API: accepted with a warning, never 'not ready' [LB-13]" {
    start_stub
    local code
    for code in 401 403; do
        plan_default "$code" "$UNAUTH"
        : >"$TEST_SCRATCH/stub.log"
        ready_within 5
        [ "$status" -eq 0 ] || {
            echo "HTTP $code: $output"
            false
        }
        [[ "$(<"$D/sm.log")" == *"MediaMTX is up (HTTP ${code} from http://127.0.0.1:${P_API}/v3) but its API requires credentials"* ]]
        # the answer says nothing about the API version, so no other prefix is tried
        [ "$(requests)" = "GET /v3/paths/list" ]
    done
}

@test "readiness: a 404 on /v3 falls back to /v2, then /v1, then the unversioned API, as documented [LB-13]" {
    start_stub
    plan_default 404 "404 page not found"
    plan_route /v2/paths/list 200 "$LIST"
    ready_within 5
    [ "$status" -eq 0 ]
    [ "$(requests)" = $'GET /v3/paths/list\nGET /v2/paths/list' ]

    # API v1 sent its items as an object keyed by name
    plan_reset
    plan_default 404 "404 page not found"
    plan_route /v1/paths/list 200 '{"itemCount":1,"pageCount":1,"items":{"mic1":{"name":"mic1","ready":true}}}'
    : >"$TEST_SCRATCH/stub.log"
    ready_within 5
    [ "$status" -eq 0 ]
    [ "$(requests)" = $'GET /v3/paths/list\nGET /v2/paths/list\nGET /v1/paths/list' ]

    plan_reset
    plan_default 404 "404 page not found"
    plan_route /paths/list 200 '{"itemCount":0,"pageCount":0,"items":{}}'
    : >"$TEST_SCRATCH/stub.log"
    ready_within 5
    [ "$status" -eq 0 ]
    [ "$(requests)" = $'GET /v3/paths/list\nGET /v2/paths/list\nGET /v1/paths/list\nGET /paths/list' ]
    # unless the fallback is switched off
    MEDIAMTX_API_FALLBACK=false ready_within 1
    [ "$status" -eq 1 ]
}

@test "readiness: v3 and v2 want an items array, so an items object there is not ready [LB-13]" {
    start_stub
    plan_default 404 "404 page not found"
    plan_route /v3/paths/list 200 '{"items":{"a":{}}}'
    ready_within 1
    [ "$status" -eq 1 ]
}

@test "readiness: an explicit MEDIAMTX_API_VERSION asks only that version [LB-13]" {
    start_stub
    plan_default 404 "404 page not found"
    plan_route /v2/paths/list 200 "$LIST"
    MEDIAMTX_API_VERSION=v2 ready_within 5
    [ "$status" -eq 0 ]
    [ "$(requests)" = "GET /v2/paths/list" ]
    : >"$TEST_SCRATCH/stub.log"
    MEDIAMTX_API_VERSION=v3 ready_within 1
    [ "$status" -eq 1 ]
    [ "$(requests)" = "GET /v3/paths/list" ]
}

@test "readiness: a refused connection is not ready until the deadline, and the message says so [LB-13]" {
    # nothing listens on this port
    MEDIAMTX_API_PORT="$P_SPARE1" ready_within 2
    [ "$status" -eq 1 ]
    [[ "$(<"$D/sm.log")" == *"(unreachable at http://127.0.0.1:${P_SPARE1}/v3, last HTTP status 000)"* ]]
}

@test "readiness: an answer that takes longer than the request limit is not ready [LB-13]" {
    start_stub
    plan_route /v3/paths/list 200 "$LIST" 6
    local started=$SECONDS
    ready_within 1
    [ "$status" -eq 1 ]
    # curl gave up after its own limit; the stub's delay was not waited out
    [ $((SECONDS - started)) -lt 5 ]
    # no answer says nothing about the other prefixes: they are not asked
    [ "$(requests)" = "GET /v3/paths/list" ]
}

@test "readiness: an answer cut off before its announced length, or a connection closed without one, is no answer [LB-13]" {
    start_stub
    # the body is a complete paths list, but the server announced more than it sent
    plan_route /v3/paths/list 200 "$LIST" 0 true
    ready_within 1
    [ "$status" -eq 1 ]
    [[ "$(<"$D/sm.log")" == *"(notready at"* || "$(<"$D/sm.log")" == *"(unreachable at"* ]]
    plan_route /v3/paths/list 200 "$LIST" 0 false true
    ready_within 1
    [ "$status" -eq 1 ]
    plan_route /v3/paths/get/mic1 200 "$PATH_READY" 0 true
    run sm 'probe_stream_ready mic1; echo "rc=$?"'
    [ "${output##*rc=}" = 2 ]
}

@test "readiness: it keeps asking until the API answers properly [LB-13]" {
    start_stub
    plan_default 500 "oops"
    (
        sleep 1.5
        plan_route /v3/paths/list 200 "$LIST"
    ) 3>&- &
    HELD_PIDS+=("$!")
    ready_within 10
    [ "$status" -eq 0 ]
    [[ "$(<"$D/sm.log")" == *"MediaMTX API is ready after "[1-9]" seconds"* ]]
}

@test "readiness: a MediaMTX that died during start-up ends the wait at once [LB-13]" {
    start_stub
    plan_route /v3/paths/list 200 "$LIST"
    kill -9 "$ALIVE_PID"
    wait "$ALIVE_PID" 2>/dev/null || true
    local started=$SECONDS
    ready_within 30
    [ "$status" -eq 1 ]
    [ $((SECONDS - started)) -lt 5 ]
    [ ! -s "$TEST_SCRATCH/stub.log" ]
    [[ "$(<"$D/sm.log")" == *"MediaMTX process died during startup"* ]]
}

# ---------------------------------------------------------------------------
# detect_mediamtx_api_version
# ---------------------------------------------------------------------------

@test "version detection: v3 when /v3 answers with a paths list [LB-13]" {
    start_stub
    plan_route /v3/paths/list 200 "$LIST"
    run sm detect_mediamtx_api_version
    [ "$output" = "http://127.0.0.1:${P_API}/v3" ]
}

@test "version detection: a 404 on /v3 moves on to /v2 and /v1, which could never happen before [LB-13]" {
    start_stub
    plan_default 404 "404 page not found"
    plan_route /v2/paths/list 200 "$LIST"
    run sm detect_mediamtx_api_version
    [ "$output" = "http://127.0.0.1:${P_API}/v2" ]
    plan_reset
    plan_default 404 "404 page not found"
    plan_route /v1/paths/list 200 '{"items":{}}'
    run sm detect_mediamtx_api_version
    [ "$output" = "http://127.0.0.1:${P_API}/v1" ]
    plan_reset
    plan_default 404 "404 page not found"
    plan_route /paths/list 200 '{"items":{}}'
    run sm detect_mediamtx_api_version
    [ "$output" = "http://127.0.0.1:${P_API}" ]
}

@test "version detection: a 401, a 5xx, garbage or no answer default to v3 without trying older prefixes [LB-13]" {
    start_stub
    local code
    for code in 401 403 500 503; do
        plan_default "$code" "$UNAUTH"
        : >"$TEST_SCRATCH/stub.log"
        run sm detect_mediamtx_api_version
        [[ "$(last_line)" == "http://127.0.0.1:${P_API}/v3" ]] || {
            echo "HTTP $code: $output"
            false
        }
        [ "$(requests)" = "GET /v3/paths/list" ]
    done
    plan_default 200 "this is not MediaMTX"
    : >"$TEST_SCRATCH/stub.log"
    run sm detect_mediamtx_api_version
    [[ "$(last_line)" == "http://127.0.0.1:${P_API}/v3" ]]
    [ "$(requests)" = "GET /v3/paths/list" ]
    MEDIAMTX_API_PORT="$P_SPARE1" run sm detect_mediamtx_api_version
    [[ "$(last_line)" == "http://127.0.0.1:${P_SPARE1}/v3" ]]
}

@test "version detection: an explicit MEDIAMTX_API_VERSION is used without asking [LB-13]" {
    start_stub
    MEDIAMTX_API_VERSION=v2 run sm detect_mediamtx_api_version
    [ "$output" = "http://127.0.0.1:${P_API}/v2" ]
    [ ! -s "$TEST_SCRATCH/stub.log" ]
}

@test "the API host follows MEDIAMTX_API_BIND, and MEDIAMTX_HOST when the API listens on every interface [D9, LB-13]" {
    run env -u MEDIAMTX_API_BIND MEDIAMTX_HOST=localhost bash -c 'source "$1" >/dev/null 2>&1; mediamtx_api_root' _ "$SM"
    [ "$output" = "http://127.0.0.1:${P_API}" ]
    local bind
    for bind in "" 0.0.0.0 ::; do
        run env "MEDIAMTX_API_BIND=$bind" MEDIAMTX_HOST=localhost bash -c 'source "$1" >/dev/null 2>&1; mediamtx_api_root' _ "$SM"
        [ "$output" = "http://localhost:${P_API}" ] || {
            echo "bind [$bind]: $output"
            false
        }
    done
    run env MEDIAMTX_API_BIND=192.0.2.9 bash -c 'source "$1" >/dev/null 2>&1; mediamtx_api_root' _ "$SM"
    [ "$output" = "http://192.0.2.9:${P_API}" ]
    run env MEDIAMTX_API_BIND=::1 bash -c 'source "$1" >/dev/null 2>&1; mediamtx_api_root' _ "$SM"
    [ "$output" = "http://[::1]:${P_API}" ]
}

# ---------------------------------------------------------------------------
# probe_stream_ready
# ---------------------------------------------------------------------------

# probe_rc BODY STATUS: probe_stream_ready mic1 against that answer; prints its status
probe_rc() {
    plan_route /v3/paths/list 200 "$LIST"
    plan_route /v3/paths/get/mic1 "$2" "$1"
    run sm 'probe_stream_ready mic1; echo "rc=$?"'
    printf '%s\n' "${output##*rc=}"
}

@test "probe: a published path is ready (0); an unavailable one, and a path MediaMTX does not know, are not ready (1) [LB-13]" {
    start_stub
    [ "$(probe_rc "$PATH_READY" 200)" = 0 ]
    [ "$(probe_rc "$PATH_READY_OLD" 200)" = 0 ]
    [ "$(probe_rc '{"name":"mic1","available":true}' 200)" = 0 ]
    [ "$(probe_rc "$PATH_NOT_READY" 200)" = 1 ]
    # the new field wins over the deprecated one
    [ "$(probe_rc '{"name":"mic1","ready":true,"available":false}' 200)" = 1 ]
    [ "$(probe_rc "$NOT_FOUND" 404)" = 1 ]
}

@test "probe: a 401 or 403, a 5xx, a plain-text 404, garbage and a path of the wrong shape are unknown (2), not 'not ready' [LB-13]" {
    start_stub
    local code
    for code in 401 403; do
        [ "$(probe_rc "$UNAUTH" "$code")" = 2 ] || {
            echo "HTTP $code"
            false
        }
    done
    for code in 500 502 503 301 400; do
        [ "$(probe_rc "$NOT_FOUND" "$code")" = 2 ] || {
            echo "HTTP $code"
            false
        }
    done
    [ "$(probe_rc "404 page not found" 404)" = 2 ]
    [ "$(probe_rc '{}' 404)" = 2 ]
    [ "$(probe_rc '{"error":5}' 404)" = 2 ]
    [ "$(probe_rc '[]' 404)" = 2 ]
    local body
    for body in 'not json' '' '{}' '[]' 'null' '{"name":"mic1"}' '{"ready":true}' '{"name":1,"ready":true}' '{"name":"mic1","ready":"yes"}' \
        '{"name":"mic1","available":null}' "<html>ok</html>"; do
        [ "$(probe_rc "$body" 200)" = 2 ] || {
            echo "answer [$body]"
            false
        }
    done
}

@test "probe: no answer at all (refused, too slow) is unknown (2) [LB-13]" {
    MEDIAMTX_API_PORT="$P_SPARE1" run sm 'probe_stream_ready mic1; echo "rc=$?"'
    [ "${output##*rc=}" = 2 ]
    start_stub
    plan_route /v3/paths/list 200 "$LIST"
    plan_route /v3/paths/get/mic1 200 "$PATH_READY" 6
    run sm 'probe_stream_ready mic1; echo "rc=$?"'
    [ "${output##*rc=}" = 2 ]
}

@test "probe: the same verdicts without jq [LB-13]" {
    start_stub
    export WITHOUT_JQ=1
    [ "$(probe_rc "$PATH_READY" 200)" = 0 ]
    [ "$(probe_rc "$PATH_NOT_READY" 200)" = 1 ]
    [ "$(probe_rc "$NOT_FOUND" 404)" = 1 ]
    [ "$(probe_rc "$UNAUTH" 401)" = 2 ]
    [ "$(probe_rc "404 page not found" 404)" = 2 ]
    [ "$(probe_rc '{}' 404)" = 2 ]
    [ "$(probe_rc '{"error":5}' 404)" = 2 ]
    [ "$(probe_rc 'not json' 200)" = 2 ]
    [ "$(probe_rc '{}' 200)" = 2 ]
    [ "$(probe_rc '{"name":"mic1"}' 200)" = 2 ]
    [ "$(probe_rc '{"ready":true}' 200)" = 2 ]
    [ "$(probe_rc "$NOT_FOUND" 500)" = 2 ]
}

@test "probe: the path name goes under the detected API prefix [LB-13]" {
    start_stub
    plan_default 404 "404 page not found"
    plan_route /v2/paths/list 200 "$LIST"
    plan_route /v2/paths/get/mic1 200 "$PATH_READY"
    run sm 'probe_stream_ready mic1; echo "rc=$?"'
    [ "${output##*rc=}" = 0 ]
    requests | grep -qx 'GET /v2/paths/get/mic1'
}

# ---------------------------------------------------------------------------
# validate_stream (what `start` prints as [OK] or [FAIL])
# ---------------------------------------------------------------------------

@test "validate_stream trusts the API only for a 200 that says the path is ready [LB-13]" {
    start_stub
    plan_route /v3/paths/list 200 "$LIST"
    plan_route /v3/paths/get/mic1 200 "$PATH_READY"
    STREAM_VALIDATION_DELAY=0 STREAM_VALIDATION_ATTEMPTS=2 run sm 'validate_stream mic1; echo "rc=$?"'
    [ "${output##*rc=}" = 0 ]
    # A ready-looking body that came with an error status is no proof, and
    # without a wrapper process to fall back on the stream is not validated
    local code
    for code in 500 401 403 404 502; do
        plan_route /v3/paths/get/mic1 "$code" "$PATH_READY"
        STREAM_VALIDATION_DELAY=0 STREAM_VALIDATION_ATTEMPTS=2 run sm 'validate_stream mic1; echo "rc=$?"'
        [ "${output##*rc=}" = 1 ] || {
            echo "validated on HTTP $code"
            false
        }
    done
    plan_route /v3/paths/get/mic1 200 "$PATH_NOT_READY"
    STREAM_VALIDATION_DELAY=0 STREAM_VALIDATION_ATTEMPTS=2 run sm 'validate_stream mic1; echo "rc=$?"'
    [ "${output##*rc=}" = 1 ]
}

# ---------------------------------------------------------------------------
# What the deep health check does with a verdict
# ---------------------------------------------------------------------------

@test "deep health: a healthy stream behind an authenticated API is never struck, however often it is checked [LB-13]" {
    start_stub
    plan_default 401 "$UNAUTH"
    local i
    for i in 1 2 3 4 5 6; do
        run sm 'deep_stream_unhealthy mic1; echo "rc=$?"'
        [ "${output##*rc=}" = 1 ] || {
            echo "run $i: $output"
            false
        }
    done
    [ -z "$(ls -A "$D/strikes")" ]
}

@test "deep health: a 5xx, garbage or an unreachable API never strike either; a path that is not ready does, until it is restarted [LB-13]" {
    start_stub
    plan_default 500 "oops"
    local i
    for i in 1 2 3 4; do
        run sm 'deep_stream_unhealthy mic1; echo "rc=$?"'
        [ "${output##*rc=}" = 1 ]
    done
    plan_default 200 "not json"
    for i in 1 2 3 4; do
        run sm 'deep_stream_unhealthy mic1; echo "rc=$?"'
        [ "${output##*rc=}" = 1 ]
    done
    [ -z "$(ls -A "$D/strikes")" ]
    # the control: a path MediaMTX reports as not available is struck, and the third strike restarts it
    plan_route /v3/paths/list 200 "$LIST"
    plan_route /v3/paths/get/mic1 200 "$PATH_NOT_READY"
    run sm 'deep_stream_unhealthy mic1; echo "rc=$?"'
    [ "${output##*rc=}" = 1 ]
    run sm 'deep_stream_unhealthy mic1; echo "rc=$?"'
    [ "${output##*rc=}" = 1 ]
    run sm 'deep_stream_unhealthy mic1; echo "rc=$?"'
    [ "${output##*rc=}" = 0 ]
}
