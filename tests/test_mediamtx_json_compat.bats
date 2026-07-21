#!/usr/bin/env bats
# MediaMTX control-API JSON compatibility + abort-safety tests.
#
# Two failure classes are locked down here:
#  1. errexit/pipefail abort: count=$(echo "$json" | grep -o PAT | wc -l) makes
#     the WHOLE script die when grep matches nothing (pipefail -> assignment
#     fails -> errexit), so "0 ready paths" killed the manager mid-run.
#  2. Deprecated field shapes: "ready" is deprecated in favour of "available";
#     a future MediaMTX that drops "ready" must not make every stream look dead.
#
# All tests drive the REAL functions from lyrebird-stream-manager.sh /
# lyrebird-metrics.sh against a stub MediaMTX API (PATH-shim fake curl).

setup() {
    TEST_DIR="$( cd "$( dirname "$BATS_TEST_FILENAME" )" && pwd )"
    PROJECT_ROOT="$( cd "$TEST_DIR/.." && pwd )"
    JC_TMP="$(mktemp -d)"
    mkdir -p "$JC_TMP/bin"
}

teardown() {
    rm -rf "$JC_TMP" 2>/dev/null || true
}

# Write a fake curl that answers /v3/paths/list and /v3/paths/get/* with the
# JSON bodies given as $2 / $3. mediamtx_api_call appends "\n%{http_code}".
_write_stub_curl() {
    local list_json="$1" get_json="$2"
    cat > "$JC_TMP/bin/curl" <<CURLEOF
#!/bin/bash
url="\${!#}"
for a in "\$@"; do
    case "\$a" in *%{http_code}*) with_code=1 ;; esac
done
body='{}'
case "\$url" in
    */paths/list*) body='${list_json}' ;;
    */paths/get/*) body='${get_json}' ;;
    */v3/info*)    body='{"version":"1.19.2","upTime":123456}' ;;
esac
if [[ "\${with_code:-0}" == "1" ]]; then
    printf '%s\n200' "\$body"
else
    printf '%s' "\$body"
fi
exit 0
CURLEOF
    chmod +x "$JC_TMP/bin/curl"
}

# Run a snippet with the real stream-manager sourced and the stub API on PATH.
_sm() {
    env PROJECT_ROOT="$PROJECT_ROOT" PATH="$JC_TMP/bin:$PATH" \
        MEDIAMTX_API_VERSION=v3 \
        bash -c "set -euo pipefail; source \"\$PROJECT_ROOT/lyrebird-stream-manager.sh\" >/dev/null 2>&1; $1"
}

# --- 1. abort-safety (errexit/pipefail) -------------------------------------

@test "count_ready_paths with ZERO ready paths returns 0 instead of killing the script [N1]" {
    _write_stub_curl '{"itemCount":0,"items":[]}' '{}'
    run _sm 'mediamtx_count_ready_paths; echo "SURVIVED"'
    [ "$status" -eq 0 ]
    [[ "$output" == *"SURVIVED"* ]]
    [[ "$output" == *"0"* ]]
}

@test "count_rtsp_sessions with zero sessions survives under set -euo pipefail [N1]" {
    _write_stub_curl '{"itemCount":0,"items":[]}' '{}'
    run _sm 'mediamtx_count_rtsp_sessions; echo "SURVIVED"'
    [ "$status" -eq 0 ]
    [[ "$output" == *"SURVIVED"* ]]
}

@test "count_all_connections with an idle server survives and prints 0 [N1]" {
    _write_stub_curl '{"itemCount":0,"items":[]}' '{}'
    run _sm 'mediamtx_count_all_connections; echo "SURVIVED"'
    [ "$status" -eq 0 ]
    [[ "$output" == *"SURVIVED"* ]]
}

@test "get_status_summary with zero ready paths completes instead of aborting mid-print [N1]" {
    _write_stub_curl '{"itemCount":1,"items":[{"name":"mic1","ready":false}]}' '{}'
    run _sm 'mediamtx_get_status_summary'
    [ "$status" -eq 0 ]
    [[ "$output" == *"0/1 ready"* ]]
}

# --- 2. deprecated vs current field shapes ----------------------------------

@test "path_is_ready accepts the OLD shape (ready:true only)" {
    _write_stub_curl '{}' '{"name":"mic1","ready":true}'
    run _sm 'mediamtx_path_is_ready mic1 && echo YES'
    [ "$status" -eq 0 ]
    [[ "$output" == *"YES"* ]]
}

@test "path_is_ready accepts the NEW shape (available:true, no ready field)" {
    _write_stub_curl '{}' '{"name":"mic1","available":true,"tracks2":[{"type":"audio"}]}'
    run _sm 'mediamtx_path_is_ready mic1 && echo YES'
    [ "$status" -eq 0 ]
    [[ "$output" == *"YES"* ]]
}

@test "path_is_ready prefers the new field when both are present and disagree" {
    # Transitional server: available=false must win over a stale ready=true.
    _write_stub_curl '{}' '{"name":"mic1","ready":true,"available":false}'
    run _sm 'mediamtx_path_is_ready mic1 || echo NOTREADY'
    [[ "$output" == *"NOTREADY"* ]]
}

@test "path_is_ready is not fooled by ready:false" {
    _write_stub_curl '{}' '{"name":"mic1","ready":false}'
    run _sm 'mediamtx_path_is_ready mic1 || echo NOTREADY'
    [[ "$output" == *"NOTREADY"* ]]
}

@test "count_ready_paths counts NEW-shape (available) paths" {
    _write_stub_curl '{"itemCount":2,"items":[{"name":"a","available":true},{"name":"b","available":false}]}' '{}'
    run _sm 'mediamtx_count_ready_paths'
    [ "$status" -eq 0 ]
    [ "${lines[-1]}" = "1" ]
}

@test "count_ready_paths does not double-count when BOTH fields are present" {
    _write_stub_curl '{"itemCount":2,"items":[{"name":"a","ready":true,"available":true},{"name":"b","ready":true,"available":true}]}' '{}'
    run _sm 'mediamtx_count_ready_paths'
    [ "$status" -eq 0 ]
    [ "${lines[-1]}" = "2" ]
}

@test "validate_stream succeeds against a NEW-shape paths/get response" {
    _write_stub_curl '{}' '{"name":"mic1","available":true}'
    run env PROJECT_ROOT="$PROJECT_ROOT" PATH="$JC_TMP/bin:$PATH" \
        MEDIAMTX_API_VERSION=v3 STREAM_VALIDATION_DELAY=0 STREAM_VALIDATION_ATTEMPTS=1 \
        bash -c 'set -euo pipefail; source "$PROJECT_ROOT/lyrebird-stream-manager.sh" >/dev/null 2>&1; validate_stream mic1 && echo VALID'
    [ "$status" -eq 0 ]
    [[ "$output" == *"VALID"* ]]
}

@test "metrics api_paths_ready counts NEW-shape paths" {
    cat > "$JC_TMP/bin/curl" <<'CURLEOF'
#!/bin/bash
url="${!#}"
case "$url" in
    */v3/info)       echo '{"version":"1.19.2","upTime":123456}' ;;
    */v3/paths/list) echo '{"itemCount":2,"items":[{"name":"a","available":true},{"name":"b","available":true}]}' ;;
    *)               echo '{"itemCount":0,"items":[]}' ;;
esac
exit 0
CURLEOF
    chmod +x "$JC_TMP/bin/curl"
    run env PROJECT_ROOT="$PROJECT_ROOT" PATH="$JC_TMP/bin:$PATH" \
        FFMPEG_PID_DIR="$(mktemp -d)" PID_FILE="$(mktemp)" HEARTBEAT_FILE="$(mktemp)" \
        bash -c 'set -euo pipefail; source "$PROJECT_ROOT/lyrebird-metrics.sh"; generate_all_metrics'
    [ "$status" -eq 0 ]
    [[ "$output" == *"lyrebird_api_paths_ready 2"* ]]
}
