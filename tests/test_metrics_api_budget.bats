#!/usr/bin/env bats
# X-30 (c): a scrape spends a bounded time on the MediaMTX API.
#
# With the API down every scrape used to wait at least a second (the retry's
# sleep between two attempts that were both refused at once), and a MediaMTX
# that accepted the connection and never answered held the scrape for ever (curl
# was given a connect timeout and nothing else): in --serve mode that is added to
# every response, in a cron --file run the jobs pile up. The collector now has one
# time budget for all its requests (LYREBIRD_API_TIMEOUT, default 5 s).
#
# The real script and the real curl run against real sockets: a port nothing
# listens on (refused), and tests/helpers/mediamtx/slow_api.py, which accepts and
# never answers. Ports are the OS's choice or in the private block 40000-40099.
# Shims for sleep and curl only record what was called and then run the real tool.

load scratch_tmpdir

setup() {
    scratch_setup
    PROJECT_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
    SHIMS="$TEST_SCRATCH/shims"
    SLEEP_LOG="$TEST_SCRATCH/sleep.log"
    CURL_LOG="$TEST_SCRATCH/curl.log"
    mkdir -p "$SHIMS"
    : >"$SLEEP_LOG"
    : >"$CURL_LOG"
    REAL_SLEEP="$(command -v sleep)"
    REAL_CURL="$(command -v curl)"
    printf '#!/bin/bash\necho "sleep $*" >>"%s"\nexec "%s" "$@"\n' "$SLEEP_LOG" "$REAL_SLEEP" >"$SHIMS/sleep"
    printf '#!/bin/bash\necho "curl $*" >>"%s"\nexec "%s" "$@"\n' "$CURL_LOG" "$REAL_CURL" >"$SHIMS/curl"
    chmod +x "$SHIMS/sleep" "$SHIMS/curl"
    HELPER_PID=""
}

teardown() {
    if [[ -n "$HELPER_PID" ]]; then
        kill "$HELPER_PID" 2>/dev/null || true
        wait "$HELPER_PID" 2>/dev/null || true
    fi
    scratch_teardown
}

# A port in the private block that nothing listens on (curl exit status 7)
refused_port() {
    local p rc
    for p in $(seq 40010 40099); do
        rc=0
        "$REAL_CURL" -s --connect-timeout 1 "http://127.0.0.1:$p/" >/dev/null 2>&1 || rc=$?
        if ((rc == 7)); then
            echo "$p"
            return 0
        fi
    done
    return 1
}

# Start tests/helpers/mediamtx/slow_api.py [all]; sets API_PORT
start_slow_api() {
    python3 -I "$PROJECT_ROOT/tests/helpers/mediamtx/slow_api.py" "$@" >"$TEST_SCRATCH/api.port" 3>&- &
    HELPER_PID=$!
    local i
    for ((i = 0; i < 100; i++)); do
        [[ -s "$TEST_SCRATCH/api.port" ]] && break
        sleep 0.05
    done
    API_PORT="$(head -1 "$TEST_SCRATCH/api.port")"
    [[ "$API_PORT" =~ ^[0-9]+$ ]]
}

# Run the real collect_api_metrics in a child shell, bounded by `timeout` (a
# collector that waits for ever is a failure, not a hung test run). Arguments are
# env assignments. Output: $TEST_SCRATCH/out and err; RUN_RC; ELAPSED_MS.
run_api_collector() {
    local started ended
    RUN_RC=0
    started="$(date +%s%N)"
    env PROJECT_ROOT="$PROJECT_ROOT" PATH="$SHIMS:$PATH" MEDIAMTX_HOST=127.0.0.1 "$@" \
        timeout 20 "$BASH" -c 'source "$PROJECT_ROOT/lyrebird-metrics.sh"; collect_api_metrics' \
        >"$TEST_SCRATCH/out" 2>"$TEST_SCRATCH/err" || RUN_RC=$?
    ended="$(date +%s%N)"
    ELAPSED_MS=$(((ended - started) / 1000000))
}

@test "a refused API connection ends the API work at once: one request, no retry pause, far less than the second it used to cost [X-30]" {
    local port
    port="$(refused_port)"
    run_api_collector MEDIAMTX_API_PORT="$port"
    [ "$RUN_RC" -eq 0 ]
    grep -qx 'lyrebird_api_up 0' "$TEST_SCRATCH/out"
    echo "API down, refused at once: ${ELAPSED_MS} ms" >&3
    # the old code asked twice with a one second sleep between
    [ "$(grep -c '^curl ' "$CURL_LOG")" -eq 1 ] || { cat "$CURL_LOG"; return 1; }
    [ ! -s "$SLEEP_LOG" ] || { cat "$SLEEP_LOG"; return 1; }
    [ "$ELAPSED_MS" -lt 700 ]
}

@test "an API that accepts the connection and never answers is given up on after LYREBIRD_API_TIMEOUT seconds in all, not waited for for ever [X-30]" {
    start_slow_api all
    run_api_collector MEDIAMTX_API_PORT="$API_PORT" LYREBIRD_API_TIMEOUT=2
    [ "$RUN_RC" -eq 0 ] || { echo "status $RUN_RC (124 = still waiting after 20 s)"; return 1; }
    grep -qx 'lyrebird_api_up 0' "$TEST_SCRATCH/out"
    echo "API hung, LYREBIRD_API_TIMEOUT=2: ${ELAPSED_MS} ms" >&3
    [ "$ELAPSED_MS" -ge 1500 ]
    [ "$ELAPSED_MS" -lt 4500 ]
}

@test "the budget covers all requests of the scrape: an API that answers /v3/info and hangs on the lists leaves their metrics out and fails the collector, within the budget [X-30]" {
    start_slow_api
    run_api_collector MEDIAMTX_API_PORT="$API_PORT" LYREBIRD_API_TIMEOUT=3
    [ "$RUN_RC" -eq 1 ] || { echo "status $RUN_RC (124 = still waiting after 20 s)"; cat "$TEST_SCRATCH/err"; return 1; }
    echo "API answers /v3/info, hangs on the rest, LYREBIRD_API_TIMEOUT=3: ${ELAPSED_MS} ms" >&3
    grep -qx 'lyrebird_api_up 1' "$TEST_SCRATCH/out"
    grep -qx 'lyrebird_api_uptime_seconds 100' "$TEST_SCRATCH/out"
    grep -qF 'lyrebird_api_info{version="1.19.2"} 1' "$TEST_SCRATCH/out"
    # unknown, not 0: no value, and no total made of the lists that did not arrive
    ! grep -q '^lyrebird_api_paths_total\|^lyrebird_api_total_connections\|^lyrebird_api_recordings_total' "$TEST_SCRATCH/out" || false
    grep -q "did not answer every request within 3s" "$TEST_SCRATCH/err" || { cat "$TEST_SCRATCH/err"; return 1; }
    [ "$ELAPSED_MS" -lt 6500 ]
}

@test "a transient failure is retried once after a short pause, and the scrape recovers [X-30]" {
    # the first request ends in an empty reply (curl status 52), every later one is answered
    cat >"$SHIMS/curl" <<EOF
#!/bin/bash
echo "curl \$*" >>"$CURL_LOG"
if [[ "\$(wc -l <"$CURL_LOG")" -eq 1 ]]; then exit 52; fi
for a in "\$@"; do
    case "\$a" in *"/v3/info") echo '{"version":"1.19.2","upTime":100}'; exit 0 ;; esac
done
echo '{"itemCount":0,"items":[]}'
EOF
    run_api_collector MEDIAMTX_API_PORT=9
    [ "$RUN_RC" -eq 0 ] || { cat "$TEST_SCRATCH/err"; return 1; }
    grep -qx 'lyrebird_api_up 1' "$TEST_SCRATCH/out"
    # the pause is a fraction of a second (it was a whole one)
    [ "$(cat "$SLEEP_LOG")" = "sleep 0.2" ]
    [ "$ELAPSED_MS" -lt 900 ]
}

@test "a list that comes back empty does not abort the collector under set -u: the total is still computed [X-30]" {
    # /v3/info is a valid document; every list is answered with 200 and no body
    cat >"$SHIMS/curl" <<'EOF'
#!/bin/bash
for a in "$@"; do
    case "$a" in *"/v3/info") echo '{"version":"1.19.2","upTime":100}'; exit 0 ;; esac
done
exit 0
EOF
    run_api_collector MEDIAMTX_API_PORT=9
    [ "$RUN_RC" -eq 0 ] || { cat "$TEST_SCRATCH/err"; return 1; }
    grep -qx 'lyrebird_api_up 1' "$TEST_SCRATCH/out"
    grep -qx 'lyrebird_api_total_connections 0' "$TEST_SCRATCH/out"
    ! grep -q 'unbound variable' "$TEST_SCRATCH/err" || false
}

@test "LYREBIRD_API_TIMEOUT takes a positive whole number of seconds; anything else is ignored with a warning and 5 s is used [X-30]" {
    local v
    for v in 7 007 120; do
        run env PROJECT_ROOT="$PROJECT_ROOT" LYREBIRD_API_TIMEOUT="$v" bash -c 'source "$PROJECT_ROOT/lyrebird-metrics.sh"; echo "$API_TIMEOUT"'
        [ "$status" -eq 0 ]
        [ "$output" = "$((10#$v))" ]
    done
    run env PROJECT_ROOT="$PROJECT_ROOT" bash -c 'source "$PROJECT_ROOT/lyrebird-metrics.sh"; echo "$API_TIMEOUT"'
    [ "$output" = "5" ]
    for v in 0 abc -3 1.5 "2 s"; do
        run env PROJECT_ROOT="$PROJECT_ROOT" LYREBIRD_API_TIMEOUT="$v" bash -c 'source "$PROJECT_ROOT/lyrebird-metrics.sh"; echo "$API_TIMEOUT"'
        [ "$status" -eq 0 ]
        [[ "$output" == *"ignoring LYREBIRD_API_TIMEOUT='$v'"* ]] || { echo "$v: $output"; return 1; }
        [[ "$output" == *$'\n5' || "$output" == "5" ]] || { echo "$v: $output"; return 1; }
    done
}
