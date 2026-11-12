#!/usr/bin/env bats
# Unit tests for lyrebird-metrics.sh
# Run with: bats tests/test_lyrebird_metrics.bats
# Install bats: sudo apt-get install bats

# Setup - source the metrics script
load bats_shell_state

load scratch_tmpdir

load prom_validate

setup() {
    scratch_setup
    # Get the directory of this test file
    TEST_DIR="$( cd "$( dirname "$BATS_TEST_FILENAME" )" && pwd )"
    PROJECT_ROOT="$( cd "$TEST_DIR/.." && pwd )"

    # Create temp directories for testing
    export FFMPEG_PID_DIR="$(mktemp -d)"
    export HEARTBEAT_FILE="$(mktemp)"
    export PID_FILE="$(mktemp)"

    # Source the metrics script
    bats_save_shell_state
    source "$PROJECT_ROOT/lyrebird-metrics.sh"
    bats_restore_shell_state
}

# Teardown - clean up temp files
teardown() {
    _serve_teardown
    rm -rf "$FFMPEG_PID_DIR" 2>/dev/null || true
    rm -f "$HEARTBEAT_FILE" 2>/dev/null || true
    rm -f "$PID_FILE" 2>/dev/null || true
    scratch_teardown
}

# ============================================================================
# Script Metadata Tests
# ============================================================================

@test "VERSION is defined" {
    [ -n "$VERSION" ]
    [[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]
}

@test "METRIC_PREFIX is lyrebird" {
    [ "$METRIC_PREFIX" = "lyrebird" ]
}

@test "SCRIPT_NAME is defined" {
    [ -n "$SCRIPT_NAME" ]
}

# ============================================================================
# Helper Function Tests
# ============================================================================

@test "has_command returns 0 for bash" {
    run has_command bash
    [ "$status" -eq 0 ]
}

@test "has_command returns 1 for nonexistent command" {
    run has_command this_command_does_not_exist_xyz
    [ "$status" -eq 1 ]
}

@test "get_timestamp_ms returns numeric value" {
    run get_timestamp_ms
    [ "$status" -eq 0 ]
    [[ "$output" =~ ^[0-9]+$ ]]
}

@test "get_timestamp_ms returns milliseconds (13+ digits)" {
    run get_timestamp_ms
    [ "$status" -eq 0 ]
    [ ${#output} -ge 13 ]
}

# ============================================================================
# emit_metric Tests
# ============================================================================

@test "emit_metric outputs metric name with prefix" {
    run emit_metric "test_metric" "42"
    [ "$status" -eq 0 ]
    [[ "$output" =~ lyrebird_test_metric ]]
}

@test "emit_metric includes value" {
    run emit_metric "test_metric" "123"
    [ "$status" -eq 0 ]
    [[ "$output" =~ "123" ]]
}

@test "emit_metric with help outputs HELP comment" {
    run emit_metric "test_metric" "1" "This is help text"
    [ "$status" -eq 0 ]
    [[ "$output" =~ "# HELP" ]]
    [[ "$output" =~ "This is help text" ]]
}

@test "emit_metric with type outputs TYPE comment" {
    run emit_metric "test_metric" "1" "Help" "counter"
    [ "$status" -eq 0 ]
    [[ "$output" =~ "# TYPE" ]]
    [[ "$output" =~ "counter" ]]
}

@test "emit_metric with labels includes labels" {
    run emit_metric "test_metric" "1" "" "gauge" 'name="test",type="unit"'
    [ "$status" -eq 0 ]
    [[ "$output" =~ 'name="test"' ]]
    [[ "$output" =~ 'type="unit"' ]]
}

@test "emit_metric default type is gauge" {
    run emit_metric "test_metric" "1" "Help"
    [ "$status" -eq 0 ]
    [[ "$output" =~ "gauge" ]]
}

# ============================================================================
# Collect Function Tests
# ============================================================================

@test "collect_mediamtx_metrics function exists" {
    run type collect_mediamtx_metrics
    [ "$status" -eq 0 ]
}

@test "collect_mediamtx_metrics outputs mediamtx_up metric" {
    run collect_mediamtx_metrics
    [ "$status" -eq 0 ]
    [[ "$output" =~ lyrebird_mediamtx_up ]]
}

@test "collect_stream_manager_metrics function exists" {
    run type collect_stream_manager_metrics
    [ "$status" -eq 0 ]
}

@test "collect_stream_manager_metrics outputs manager_running metric" {
    run collect_stream_manager_metrics
    [ "$status" -eq 0 ]
    [[ "$output" =~ lyrebird_stream_manager ]]
}

@test "collect_usb_audio_metrics function exists" {
    run type collect_usb_audio_metrics
    [ "$status" -eq 0 ]
}

@test "collect_usb_audio_metrics outputs usb_audio metric" {
    run collect_usb_audio_metrics
    [ "$status" -eq 0 ]
    [[ "$output" =~ lyrebird_usb_audio ]]
}

@test "collect_system_metrics function exists" {
    run type collect_system_metrics
    [ "$status" -eq 0 ]
}

@test "collect_system_metrics outputs cpu_usage metric" {
    run collect_system_metrics
    [ "$status" -eq 0 ]
    [[ "$output" =~ lyrebird_.*cpu ]] || [[ "$output" =~ lyrebird_.*load ]] || [[ "$output" =~ lyrebird_.*memory ]]
}

@test "collect_api_metrics function exists" {
    run type collect_api_metrics
    [ "$status" -eq 0 ]
}

@test "collect_stream_metrics function exists" {
    run type collect_stream_metrics
    [ "$status" -eq 0 ]
}

# ============================================================================
# Metric Format Tests
# ============================================================================

@test "metrics output is valid Prometheus format" {
    # Valid format: metric_name{labels} value
    run emit_metric "test" "1.5"
    [ "$status" -eq 0 ]
    # Should match: prefix_name value
    [[ "$output" =~ ^[a-z_]+\ [0-9.]+ ]]
}

@test "metric names use underscores not hyphens" {
    run emit_metric "test_metric_name" "1"
    [ "$status" -eq 0 ]
    # Should not contain hyphens in metric name
    [[ ! "$output" =~ lyrebird-test ]]
}

@test "metric values can be integers" {
    run emit_metric "int_metric" "42"
    [ "$status" -eq 0 ]
    [[ "$output" =~ "42" ]]
}

@test "metric values can be floats" {
    run emit_metric "float_metric" "3.14"
    [ "$status" -eq 0 ]
    [[ "$output" =~ "3.14" ]]
}

# ============================================================================
# Configuration Tests
# ============================================================================

@test "MEDIAMTX_API_HOST has default value" {
    [ -n "$MEDIAMTX_API_HOST" ]
}

@test "MEDIAMTX_API_PORT has default value" {
    [ -n "$MEDIAMTX_API_PORT" ]
}

@test "MEDIAMTX_RTSP_PORT has default value" {
    [ -n "$MEDIAMTX_RTSP_PORT" ]
}

# ============================================================================
# Integration Tests
# ============================================================================

@test "log function outputs to stderr" {
    run log "test message"
    [ "$status" -eq 0 ]
}

@test "full metrics collection runs without error" {
    # Run all collectors (may produce warnings but should not fail)
    run bash -c "source $PROJECT_ROOT/lyrebird-metrics.sh && collect_mediamtx_metrics && collect_system_metrics"
    [ "$status" -eq 0 ]
}

# ============================================================================
# Regression tests for Prometheus exposition-format validity (C6, M2)
# ============================================================================

@test "no metric family emits duplicate HELP/TYPE with multiple streams [C6 regression]" {
    # >=2 streams and 3 disk mounts previously produced repeated HELP/TYPE lines,
    # which makes the Prometheus text parser reject the ENTIRE scrape.
    # FFMPEG_PID_DIR is created (and made readonly) by setup(); populate it.
    echo $$ > "$FFMPEG_PID_DIR/mic1.pid"
    echo $$ > "$FFMPEG_PID_DIR/mic2.pid"
    output="$( { collect_system_metrics; collect_stream_metrics; } 2>/dev/null )"

    # Each metric name may appear in at most one '# HELP' and one '# TYPE' line.
    dup_help="$(printf '%s\n' "$output" | awk '/^# HELP /{c[$3]++} END{for(n in c) if(c[n]>1) print n}')"
    [ -z "$dup_help" ]
    dup_type="$(printf '%s\n' "$output" | awk '/^# TYPE /{c[$3]++} END{for(n in c) if(c[n]>1) print n}')"
    [ -z "$dup_type" ]
}

@test "no sample line is emitted with an empty value [C6/M2 regression]" {
    echo $$ > "$FFMPEG_PID_DIR/mic1.pid"
    output="$( { collect_system_metrics; collect_stream_metrics; } 2>/dev/null )"
    # A metric/sample line must end with a value; reject a name (optionally with
    # labels) followed by only whitespace/EOL.
    run bash -c 'printf "%s\n" "$1" | grep -nE "^[a-zA-Z_][a-zA-Z0-9_:]*(\{[^}]*\})?[[:space:]]*$"' _ "$output"
    [ "$status" -ne 0 ]
}

# --- MET-1: collectors must not abort the whole scrape (the normal state) -----

@test "collect_api_metrics completes with empty API lists (no publishers/listeners) [MET-1 regression]" {
    local bin; bin="$(mktemp -d)"
    cat > "$bin/curl" <<'CURLEOF'
#!/bin/bash
# Valid /v3/info so api_up=1; empty item lists for every other endpoint.
for a in "$@"; do
    case "$a" in *"/v3/info") echo '{"version":"1.19.2","upTime":100}'; exit 0;; esac
done
echo '{"itemCount":0,"items":[]}'
exit 0
CURLEOF
    chmod +x "$bin/curl"
    run env PROJECT_ROOT="$PROJECT_ROOT" PATH="$bin:$PATH" \
        bash -c 'set -euo pipefail; source "$PROJECT_ROOT/lyrebird-metrics.sh"; collect_api_metrics'
    rm -rf "$bin"
    [ "$status" -eq 0 ]
    # Reaching the LAST metric proves it did not abort on an empty grep|wc-l pipe
    # partway through (the pre-fix code stopped at the first empty list).
    [[ "$output" =~ lyrebird_api_total_connections ]]
    [[ "$output" =~ lyrebird_api_up[[:space:]]+1 ]]
}

# --- X-30 (d): a large /v3/info body must not read as "API down" ---------------

@test "a large /v3/info body that names the version early still reads as an API that is up: no SIGPIPE of echo into grep -q under pipefail [X-30]" {
    local bin="$TEST_SCRATCH/bigapi"
    mkdir -p "$bin"
    # about 2.6 MB over 40000 lines, "version" on the first
    cat >"$bin/curl" <<'CURLEOF'
#!/bin/bash
for a in "$@"; do
    case "$a" in
        *"/v3/info")
            printf '{"version":"1.19.2","upTime":100000000000,\n'
            yes '"pad": "xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx",' | head -n 40000
            printf '"end":1}\n'
            exit 0
            ;;
    esac
done
echo '{"itemCount":0,"items":[]}'
CURLEOF
    chmod +x "$bin/curl"
    local i
    for i in 1 2 3; do
        run env PROJECT_ROOT="$PROJECT_ROOT" PATH="$bin:$PATH" \
            bash -c 'source "$PROJECT_ROOT/lyrebird-metrics.sh"; collect_api_metrics'
        [ "$status" -eq 0 ]
        [[ "$output" == *$'\nlyrebird_api_up 1\n'* ]] || { echo "run $i: $(printf '%s\n' "$output" | grep api_up)"; return 1; }
        [[ "$output" == *'lyrebird_api_info{version="1.19.2"} 1'* ]]
    done
}

# --- MET-2: grep -c must not emit "0\n0" and break the scrape ------------------

@test "configured_devices emits a single valid 0, never '0\\n0' [MET-2 regression]" {
    local cfgdir; cfgdir="$(mktemp -d)"
    printf '# a config with no DEVICE_ lines\n# just comments\n' > "$cfgdir/audio-devices.conf"
    # NOTE: the device-config path derives from MEDIAMTX_CONFIG_DIR; a file that
    # EXISTS but has zero DEVICE_ lines is what triggers `grep -c` to print 0 and
    # exit 1 (the "0\n0" bug). A missing file takes a different branch.
    run env PROJECT_ROOT="$PROJECT_ROOT" MEDIAMTX_CONFIG_DIR="$cfgdir" \
        PID_FILE="$(mktemp)" FFMPEG_PID_DIR="$(mktemp -d)" HEARTBEAT_FILE="$(mktemp)" \
        bash -c 'set -euo pipefail; source "$PROJECT_ROOT/lyrebird-metrics.sh"; collect_stream_manager_metrics'
    rm -rf "$cfgdir"
    [ "$status" -eq 0 ]
    [ "$(printf '%s\n' "$output" | grep -c '^lyrebird_configured_devices ')" -eq 1 ]
    printf '%s\n' "$output" | grep -qx 'lyrebird_configured_devices 0'
    # No stray bare "0" line (the "0\n0" bug) anywhere in the output
    run bash -c 'printf "%s\n" "$1" | grep -qx 0' _ "$output"
    [ "$status" -ne 0 ]
}

# --- MET-6: label values must be escaped so one bad name can't reject a scrape -

@test "prom_escape_label escapes backslash, then quote, then newline [MET-6 regression]" {
    run prom_escape_label 'a"b\c'
    [ "$status" -eq 0 ]
    [ "$output" = 'a\"b\\c' ]
}

@test "emit_metric keeps a quoted device name on one valid line [MET-6 regression]" {
    run emit_metric "stream_up" "1" "" "gauge" "stream=\"$(prom_escape_label 'AKG "C414"')\""
    [ "$status" -eq 0 ]
    [ "$(printf '%s\n' "$output" | grep -c .)" -eq 1 ]     # exactly one line
    [[ "$output" == *'stream="AKG \"C414\""'* ]]
}

@test "scrape output carries an in-band staleness timestamp [stale-.prom detection]" {
    # A .prom left behind by a dead exporter must be detectable: every scrape
    # embeds the Unix time it was generated so Prometheus can alert on age.
    run env PROJECT_ROOT="$PROJECT_ROOT" \
        FFMPEG_PID_DIR="$(mktemp -d)" PID_FILE="$(mktemp)" HEARTBEAT_FILE="$(mktemp)" \
        bash -c 'set -euo pipefail; source "$PROJECT_ROOT/lyrebird-metrics.sh"; generate_all_metrics'
    [ "$status" -eq 0 ]
    local ts now
    ts=$(printf '%s\n' "$output" | awk '/^lyrebird_scrape_timestamp_seconds /{print $2}')
    [[ "$ts" =~ ^[0-9]+$ ]]
    now=$(date +%s)
    (( now - ts < 120 ))     # fresh, not a stale leftover value
}

# ============================================================================
# Exposition validity (LB-18): the document must be accepted by a real parser
# ============================================================================

# A curl that answers like a healthy MediaMTX API, so full scrapes do not wait
# for the real API's retry back-off.
_stub_curl() {
    local dir="$1"
    mkdir -p "$dir"
    cat >"$dir/curl" <<'CURLEOF'
#!/bin/bash
for a in "$@"; do
    case "$a" in *"/v3/info") echo '{"version":"1.19.2","upTime":100}'; exit 0;; esac
done
echo '{"itemCount":0,"items":[]}'
exit 0
CURLEOF
    chmod +x "$dir/curl"
}

# A pid that is guaranteed dead.
_dead_pid() {
    sleep 0 &
    local p=$!
    wait "$p" || true
    printf '%s' "$p"
}

@test "prom_validate accepts a well-formed exposition [test helper]" {
    printf '%b' '# HELP a_x help\n# TYPE a_x gauge\na_x{l="v\\\\n\\"q\\n"} 1\na_x{l="w"} 2.5e3 1700000000\n# comment\n\nb_y 3\nc +Inf\nd NaN\ne{l="Studio-é-麦克风"} 1\n' >"$TEST_SCRATCH/good.prom"
    run prom_validate "$TEST_SCRATCH/good.prom"
    [ "$status" -eq 0 ] || { echo "$output"; return 1; }
}

@test "prom_validate rejects every class of malformed exposition [test helper]" {
    local -a bad=(
        '# HELP a 1\n# HELP a 2\na 1\n'
        '# TYPE a gauge\n# TYPE a gauge\na 1\n'
        'a_x \n'
        'a_x{l="v"} \n'
        'a_x\n'
        'a_x N/A\n'
        'a_x 1,5\n'
        'a_x{l="a\\tb"} 1\n'
        'a_x{l="abc} 1\n'
        'a 1\nb 1\na{x="1"} 2\n'
        'a{x="1"} 1\na{x="1"} 2\n'
        'a 1\n# HELP a late\n'
        'a 1 2 3\n'
        '1abc 1\n'
        'a{l="x\ny"} 1\n'
        'a 1'
        'a{l="\xff"} 1\n'
    )
    local doc
    for doc in "${bad[@]}"; do
        printf '%b' "$doc" >"$TEST_SCRATCH/bad.prom"
        if prom_validate "$TEST_SCRATCH/bad.prom" >/dev/null; then
            echo "validator accepted: $doc"
            return 1
        fi
    done
}

@test "a full scrape with several live streams and hostile stream names is valid exposition [LB-18]" {
    local dir="$TEST_SCRATCH/pids" dead name
    mkdir -p "$dir"
    dead="$(_dead_pid)"
    for name in plain 'Studio "A"' 'a\nb' $'tab\there' $'real\nnewline' 'back\slash' 'é麦克风'; do
        echo $$ >"$dir/${name}.pid"
    done
    echo "$dead" >"$dir/stopped.pid"
    _stub_curl "$TEST_SCRATCH/bin"

    run env PROJECT_ROOT="$PROJECT_ROOT" PATH="$TEST_SCRATCH/bin:$PATH" \
        FFMPEG_PID_DIR="$dir" PID_FILE="$PID_FILE" HEARTBEAT_FILE="$HEARTBEAT_FILE" \
        bash -c 'set -euo pipefail; source "$PROJECT_ROOT/lyrebird-metrics.sh"; generate_all_metrics 2>/dev/null'
    [ "$status" -eq 0 ]
    printf '%s\n' "$output" >"$TEST_SCRATCH/scrape.prom"
    run prom_validate "$TEST_SCRATCH/scrape.prom"
    [ "$status" -eq 0 ] || { echo "$output"; return 1; }
    # the hostile names are present, escaped, and the dead stream reports 0
    grep -qF 'lyrebird_stream_up{stream="Studio \"A\""} 1' "$TEST_SCRATCH/scrape.prom"
    grep -qF 'lyrebird_stream_up{stream="real\nnewline"} 1' "$TEST_SCRATCH/scrape.prom"
    grep -qF 'lyrebird_stream_up{stream="stopped"} 0' "$TEST_SCRATCH/scrape.prom"
}

@test "collect_stream_metrics keeps every family's samples contiguous with two live streams [LB-18]" {
    echo $$ >"$FFMPEG_PID_DIR/mic1.pid"
    echo $$ >"$FFMPEG_PID_DIR/mic2.pid"
    collect_stream_metrics >"$TEST_SCRATCH/streams.prom" 2>/dev/null
    run prom_validate "$TEST_SCRATCH/streams.prom"
    [ "$status" -eq 0 ] || { echo "$output"; return 1; }
    # all three families carry both streams
    [ "$(grep -c '^lyrebird_stream_up{' "$TEST_SCRATCH/streams.prom")" -eq 2 ]
    [ "$(grep -c '^lyrebird_stream_memory_bytes{' "$TEST_SCRATCH/streams.prom")" -eq 2 ]
    [ "$(grep -c '^lyrebird_stream_cpu_percent{' "$TEST_SCRATCH/streams.prom")" -eq 2 ]
}

# A directory of symlinks to the tools a scrape needs, minus the ones named, to
# stand in for a node where a tool is missing. Use as PATH together with "$BASH".
_toolbox_without() {
    local dir="$1" t omit src
    shift
    mkdir -p "$dir"
    for t in date grep awk cat find wc ps df getconf curl head tr cut basename dirname \
        sleep pgrep mktemp mv rm chmod mkfifo id uname readlink nc ncat netcat; do
        for omit in "$@"; do
            [[ "$t" == "$omit" ]] && continue 2
        done
        src="$(command -v "$t" 2>/dev/null)" || continue
        [[ "$src" == /* ]] || continue
        ln -sf "$src" "$dir/$t"
    done
}

# Run the real script once as a child process. Arguments are env assignments;
# stdout goes to $TEST_SCRATCH/out, stderr to $TEST_SCRATCH/err, status to RUN_RC.
_run_once() {
    RUN_RC=0
    env "$@" "$BASH" "$PROJECT_ROOT/lyrebird-metrics.sh" --once \
        >"$TEST_SCRATCH/out" 2>"$TEST_SCRATCH/err" || RUN_RC=$?
}

# --- collector and scrape status (LB-18) --------------------------------------

@test "a healthy scrape reports scrape_success 1 and collector_success 1 for each of the six collectors [LB-18]" {
    _stub_curl "$TEST_SCRATCH/bin"
    _run_once PATH="$TEST_SCRATCH/bin:$PATH" FFMPEG_PID_DIR="$FFMPEG_PID_DIR" PID_FILE="$PID_FILE" HEARTBEAT_FILE="$HEARTBEAT_FILE"
    [ "$RUN_RC" -eq 0 ]
    run prom_validate "$TEST_SCRATCH/out"
    [ "$status" -eq 0 ] || { echo "$output"; return 1; }
    grep -qx 'lyrebird_scrape_success 1' "$TEST_SCRATCH/out"
    # the label set is fixed and bounded: exactly these six collectors
    local labels
    labels="$(grep -o '^lyrebird_collector_success{collector="[a-z_]*"} 1$' "$TEST_SCRATCH/out" | sed 's/.*collector="\([a-z_]*\)".*/\1/' | tr '\n' ' ')"
    [ "$labels" = "mediamtx stream_manager usb_audio system api streams " ] || { echo "labels: $labels"; return 1; }
    [ "$(grep -c '^lyrebird_collector_success{' "$TEST_SCRATCH/out")" -eq 6 ]
}

@test "a failing collector gives scrape_success 0, its own collector_success 0, a valid document and status 3 [LB-18]" {
    run env PROJECT_ROOT="$PROJECT_ROOT" FFMPEG_PID_DIR="$FFMPEG_PID_DIR" PID_FILE="$PID_FILE" HEARTBEAT_FILE="$HEARTBEAT_FILE" \
        bash -c 'set -euo pipefail; source "$PROJECT_ROOT/lyrebird-metrics.sh"
            collect_system_metrics() { emit_metric "partial_system" 7 "half of what it should have printed"; return 1; }
            rc=0; generate_all_metrics 2>/dev/null || rc=$?
            echo "RC=$rc"'
    [ "$status" -eq 0 ]
    local doc="$TEST_SCRATCH/degraded.prom"
    printf '%s\n' "$output" | sed '/^RC=/d' >"$doc"
    [[ "$output" == *"RC=3"* ]]
    run prom_validate "$doc"
    [ "$status" -eq 0 ] || { echo "$output"; return 1; }
    grep -qx 'lyrebird_scrape_success 0' "$doc"
    grep -qx 'lyrebird_collector_success{collector="system"} 0' "$doc"
    grep -qx 'lyrebird_collector_success{collector="mediamtx"} 1' "$doc"
    grep -qx 'lyrebird_collector_success{collector="api"} 1' "$doc"
    # what the failed collector did print is kept, and the others still ran
    grep -qx 'lyrebird_partial_system 7' "$doc"
    grep -q '^lyrebird_stream_manager_up ' "$doc"
}

@test "a collector that exits abruptly cannot take the other collectors or the document down [LB-18]" {
    run env PROJECT_ROOT="$PROJECT_ROOT" FFMPEG_PID_DIR="$FFMPEG_PID_DIR" PID_FILE="$PID_FILE" HEARTBEAT_FILE="$HEARTBEAT_FILE" \
        bash -c 'set -euo pipefail; source "$PROJECT_ROOT/lyrebird-metrics.sh"
            collect_usb_audio_metrics() { emit_metric "before_crash" 1 "printed before the crash"; exit 7; }
            rc=0; generate_all_metrics 2>/dev/null || rc=$?
            echo "RC=$rc"'
    [ "$status" -eq 0 ]
    [[ "$output" == *"RC=3"* ]]
    [[ "$output" == *'lyrebird_collector_success{collector="usb_audio"} 0'* ]]
    [[ "$output" == *'lyrebird_before_crash 1'* ]]
    [[ "$output" == *'lyrebird_collector_success{collector="streams"} 1'* ]]
    [[ "$output" == *'lyrebird_scrape_timestamp_seconds '* ]]
}

@test "a refused sample marks its collector failed even though the collector itself returned 0 [LB-18]" {
    run env PROJECT_ROOT="$PROJECT_ROOT" FFMPEG_PID_DIR="$FFMPEG_PID_DIR" PID_FILE="$PID_FILE" HEARTBEAT_FILE="$HEARTBEAT_FILE" \
        bash -c 'set -euo pipefail; source "$PROJECT_ROOT/lyrebird-metrics.sh"
            collect_usb_audio_metrics() { emit_metric "bad_value" "N/A" "never printed"; return 0; }
            rc=0; generate_all_metrics 2>/dev/null || rc=$?
            echo "RC=$rc"'
    [ "$status" -eq 0 ]
    [[ "$output" == *"RC=3"* ]]
    [[ "$output" == *'lyrebird_collector_success{collector="usb_audio"} 0'* ]]
    [[ "$output" != *'lyrebird_bad_value'* ]]
    [[ "$output" == *'lyrebird_scrape_success 0'* ]]
}

# Changed for X-30. The collector used to look for MediaMTX with `pgrep -f mediamtx`
# and failed visibly without pgrep (the old test pinned that); it now tells MediaMTX
# by identity from /proc and has no use for pgrep, so what is pinned is that a node
# without pgrep is scraped completely. The visible failure when the collector cannot
# tell is in tests/test_metrics_process_identity.bats.
@test "the mediamtx collector needs no pgrep: without it the scrape is complete and no tool is reported missing [LB-18, X-30]" {
    _toolbox_without "$TEST_SCRATCH/nopgrep" pgrep
    _run_once PATH="$TEST_SCRATCH/nopgrep" FFMPEG_PID_DIR="$FFMPEG_PID_DIR" PID_FILE="$PID_FILE" HEARTBEAT_FILE="$HEARTBEAT_FILE"
    [ "$RUN_RC" -eq 0 ]
    run prom_validate "$TEST_SCRATCH/out"
    [ "$status" -eq 0 ] || { echo "$output"; return 1; }
    grep -qx 'lyrebird_collector_success{collector="mediamtx"} 1' "$TEST_SCRATCH/out"
    grep -qx 'lyrebird_scrape_success 1' "$TEST_SCRATCH/out"
    grep -q '^lyrebird_mediamtx_up [01]$' "$TEST_SCRATCH/out"
    ! grep -q 'pgrep' "$TEST_SCRATCH/err" || false
}

@test "without curl the api collector fails visibly instead of publishing nothing silently [LB-18]" {
    _toolbox_without "$TEST_SCRATCH/nocurl" curl
    _run_once PATH="$TEST_SCRATCH/nocurl" FFMPEG_PID_DIR="$FFMPEG_PID_DIR" PID_FILE="$PID_FILE" HEARTBEAT_FILE="$HEARTBEAT_FILE"
    [ "$RUN_RC" -eq 3 ]
    grep -qx 'lyrebird_collector_success{collector="api"} 0' "$TEST_SCRATCH/out"
    grep -qx 'lyrebird_collector_success{collector="mediamtx"} 1' "$TEST_SCRATCH/out"
    ! grep -q '^lyrebird_api_up' "$TEST_SCRATCH/out" || false
    grep -q 'curl' "$TEST_SCRATCH/err"
}

@test "an unreadable pid file leaves stream state unknown: metrics omitted, both stream collectors failed [LB-18]" {
    local real_cat dir="$TEST_SCRATCH/pids"
    mkdir -p "$dir" "$TEST_SCRATCH/bin"
    echo $$ >"$dir/mic1.pid"
    real_cat="$(command -v cat)"
    # cat failing the way it does on a file the user may not read
    cat >"$TEST_SCRATCH/bin/cat" <<EOF
#!/bin/bash
for a in "\$@"; do
    if [[ "\$a" == *.pid ]]; then echo "cat: \$a: Permission denied" >&2; exit 1; fi
done
exec "$real_cat" "\$@"
EOF
    chmod +x "$TEST_SCRATCH/bin/cat"
    echo $$ >"$TEST_SCRATCH/manager.pid"
    _stub_curl "$TEST_SCRATCH/bin"
    _run_once PATH="$TEST_SCRATCH/bin:$PATH" FFMPEG_PID_DIR="$dir" PID_FILE="$TEST_SCRATCH/manager.pid" HEARTBEAT_FILE="$HEARTBEAT_FILE"
    [ "$RUN_RC" -eq 3 ]
    run prom_validate "$TEST_SCRATCH/out"
    [ "$status" -eq 0 ] || { echo "$output"; return 1; }
    grep -qx 'lyrebird_collector_success{collector="stream_manager"} 0' "$TEST_SCRATCH/out"
    grep -qx 'lyrebird_collector_success{collector="streams"} 0' "$TEST_SCRATCH/out"
    ! grep -q '^lyrebird_stream_manager_up\|^lyrebird_active_streams\|^lyrebird_stream_up' "$TEST_SCRATCH/out" || false
    # what could be read is still there
    grep -q '^lyrebird_configured_devices ' "$TEST_SCRATCH/out"
    grep -q '^lyrebird_system_load_1m ' "$TEST_SCRATCH/out"
}

@test "a pid file that vanishes while it is read is a stopped stream, not a collector failure [LB-18]" {
    local dir="$TEST_SCRATCH/pids" real_cat
    mkdir -p "$dir" "$TEST_SCRATCH/bin"
    echo $$ >"$dir/mic1.pid"
    real_cat="$(command -v cat)"
    # the manager removes the pid file between our existence check and the read
    cat >"$TEST_SCRATCH/bin/cat" <<EOF
#!/bin/bash
for a in "\$@"; do
    if [[ "\$a" == *.pid ]]; then rm -f "\$a"; exit 1; fi
done
exec "$real_cat" "\$@"
EOF
    chmod +x "$TEST_SCRATCH/bin/cat"
    # each collector on its own: the first reader consumes the vanishing file, so
    # a full scrape would only ever exercise one of them
    local fn
    for fn in collect_stream_manager_metrics collect_stream_metrics; do
        echo $$ >"$dir/mic1.pid"
        run env PROJECT_ROOT="$PROJECT_ROOT" PATH="$TEST_SCRATCH/bin:$PATH" FFMPEG_PID_DIR="$dir" \
            PID_FILE="$PID_FILE" HEARTBEAT_FILE="$HEARTBEAT_FILE" FN="$fn" \
            bash -c 'set -euo pipefail; source "$PROJECT_ROOT/lyrebird-metrics.sh"; "$FN" 2>&1'
        [ "$status" -eq 0 ] || { echo "$fn returned $status: $output"; return 1; }
        [[ "$output" != *"cannot read"* ]] || { echo "$fn reported: $output"; return 1; }
    done
    # and in a full scrape
    echo $$ >"$dir/mic1.pid"
    _stub_curl "$TEST_SCRATCH/bin"
    _run_once PATH="$TEST_SCRATCH/bin:$PATH" FFMPEG_PID_DIR="$dir" PID_FILE="$PID_FILE" HEARTBEAT_FILE="$HEARTBEAT_FILE"
    [ "$RUN_RC" -eq 0 ]
    grep -qx 'lyrebird_scrape_success 1' "$TEST_SCRATCH/out"
}

@test "a failing df fails the system collector but the rest of the document is still published [LB-18]" {
    mkdir -p "$TEST_SCRATCH/bin"
    printf '#!/bin/bash\necho "df: cannot read table of mounted file systems" >&2\nexit 1\n' >"$TEST_SCRATCH/bin/df"
    chmod +x "$TEST_SCRATCH/bin/df"
    _stub_curl "$TEST_SCRATCH/bin"
    _run_once PATH="$TEST_SCRATCH/bin:$PATH" FFMPEG_PID_DIR="$FFMPEG_PID_DIR" PID_FILE="$PID_FILE" HEARTBEAT_FILE="$HEARTBEAT_FILE"
    [ "$RUN_RC" -eq 3 ]
    run prom_validate "$TEST_SCRATCH/out"
    [ "$status" -eq 0 ] || { echo "$output"; return 1; }
    grep -qx 'lyrebird_collector_success{collector="system"} 0' "$TEST_SCRATCH/out"
    grep -q '^lyrebird_system_memory_total_bytes ' "$TEST_SCRATCH/out"
    ! grep -q '^lyrebird_disk_usage_percent' "$TEST_SCRATCH/out" || false
}

# --- atomic --file publishing (LB-18) ------------------------------------------

# A tiny launcher that sources the real script (main-guard), applies SNIPPET (to
# replace a dependency such as the generator) and runs the real main with the
# launcher's arguments. Prints the launcher's path.
_make_launcher() {
    local path="$TEST_SCRATCH/$1.sh"
    {
        echo '#!/bin/bash'
        echo 'source "$PROJECT_ROOT/lyrebird-metrics.sh"'
        printf '%s\n' "$2"
        echo 'main "$@"'
    } >"$path"
    printf '%s' "$path"
}

# Run `lyrebird-metrics.sh --file OUT` for real with the shared test environment.
_publish() {
    RUN_RC=0
    env PROJECT_ROOT="$PROJECT_ROOT" PATH="$TEST_SCRATCH/bin:$PATH" FFMPEG_PID_DIR="$FFMPEG_PID_DIR" \
        PID_FILE="$PID_FILE" HEARTBEAT_FILE="$HEARTBEAT_FILE" \
        "$BASH" "${LAUNCHER:-$PROJECT_ROOT/lyrebird-metrics.sh}" --file "$1" \
        >"$TEST_SCRATCH/out" 2>"$TEST_SCRATCH/err" || RUN_RC=$?
}

@test "--file: parallel writers never collide; every run exits 0 and every file read meanwhile validates [LB-18]" {
    _stub_curl "$TEST_SCRATCH/bin"
    local pub="$TEST_SCRATCH/pub" n=8 rounds=3 i r
    local -a pids=()
    mkdir -p "$pub"
    local out="$pub/lyrebird.prom"

    # a reader validating whatever is published, for as long as the writers run
    (
        while [[ ! -e "$TEST_SCRATCH/stop" ]]; do
            if cp "$out" "$TEST_SCRATCH/snap.prom" 2>/dev/null; then
                if prom_validate "$TEST_SCRATCH/snap.prom" >"$TEST_SCRATCH/reader.err" 2>&1; then
                    echo ok >>"$TEST_SCRATCH/reader.log"
                else
                    cp "$TEST_SCRATCH/snap.prom" "$TEST_SCRATCH/invalid.prom"
                    echo invalid >>"$TEST_SCRATCH/reader.log"
                fi
            fi
            sleep 0.02
        done
    ) 3>&- &
    local reader=$!

    for ((i = 1; i <= n; i++)); do
        (
            for ((r = 1; r <= rounds; r++)); do
                rc=0
                env PROJECT_ROOT="$PROJECT_ROOT" PATH="$TEST_SCRATCH/bin:$PATH" FFMPEG_PID_DIR="$FFMPEG_PID_DIR" \
                    PID_FILE="$PID_FILE" HEARTBEAT_FILE="$HEARTBEAT_FILE" \
                    "$BASH" "$PROJECT_ROOT/lyrebird-metrics.sh" --file "$out" 2>>"$TEST_SCRATCH/writer.err" >/dev/null || rc=$?
                echo "$rc" >>"$TEST_SCRATCH/rc.$i"
            done
        ) 3>&- &
        pids+=($!)
    done
    for i in "${pids[@]}"; do wait "$i"; done
    touch "$TEST_SCRATCH/stop"
    wait "$reader"

    [ "$(cat "$TEST_SCRATCH"/rc.* | wc -l)" -eq $((n * rounds)) ]
    [ "$(cat "$TEST_SCRATCH"/rc.* | sort -u)" = "0" ] || { cat "$TEST_SCRATCH/writer.err"; return 1; }
    [ "$(grep -c '^ok$' "$TEST_SCRATCH/reader.log")" -ge 1 ]
    ! grep -q invalid "$TEST_SCRATCH/reader.log" || { cat "$TEST_SCRATCH/reader.err"; false; }
    run prom_validate "$out"
    [ "$status" -eq 0 ] || { echo "$output"; return 1; }
    # nothing but the published file is left in the directory
    [ "$(ls -A "$pub")" = "lyrebird.prom" ]
}

@test "--file never uses the fixed FILE.tmp name: a pre-existing FILE.tmp is left alone [LB-18]" {
    _stub_curl "$TEST_SCRATCH/bin"
    mkdir -p "$TEST_SCRATCH/pub"
    printf 'someone else owns this file\n' >"$TEST_SCRATCH/pub/lyrebird.prom.tmp"
    _publish "$TEST_SCRATCH/pub/lyrebird.prom"
    [ "$RUN_RC" -eq 0 ]
    [ "$(cat "$TEST_SCRATCH/pub/lyrebird.prom.tmp")" = "someone else owns this file" ]
    run prom_validate "$TEST_SCRATCH/pub/lyrebird.prom"
    [ "$status" -eq 0 ] || { echo "$output"; return 1; }
}

@test "--file writes through a hidden temp that the textfile collector would not read, and removes it [LB-18]" {
    mkdir -p "$TEST_SCRATCH/pub"
    LAUNCHER="$(_make_launcher watch 'generate_all_metrics() { ls -A "$PUB_DIR" >"$PUB_DIR/../listing"; echo "lyrebird_x 1"; }')"
    PUB_DIR="$TEST_SCRATCH/pub" _publish "$TEST_SCRATCH/pub/lyrebird.prom"
    [ "$RUN_RC" -eq 0 ]
    local temp
    temp="$(cat "$TEST_SCRATCH/listing")"
    [ "$(printf '%s\n' "$temp" | wc -l)" -eq 1 ]
    [[ "$temp" =~ ^\.lyrebird\.prom\.[A-Za-z0-9]{6}$ ]] || { echo "temp name: $temp"; return 1; }
    [[ "$temp" != *.prom ]]
    [ "$(ls -A "$TEST_SCRATCH/pub")" = "lyrebird.prom" ]
    [ "$(cat "$TEST_SCRATCH/pub/lyrebird.prom")" = "lyrebird_x 1" ]
}

@test "--file: a failing generator keeps the last good file byte for byte, leaves no temp and exits 2 [LB-18]" {
    mkdir -p "$TEST_SCRATCH/pub"
    printf '# last good\nlyrebird_scrape_success 1\n' >"$TEST_SCRATCH/pub/lyrebird.prom"
    cp "$TEST_SCRATCH/pub/lyrebird.prom" "$TEST_SCRATCH/good.copy"
    LAUNCHER="$(_make_launcher failgen 'generate_all_metrics() { echo "partial output"; return 1; }')"
    _publish "$TEST_SCRATCH/pub/lyrebird.prom"
    [ "$RUN_RC" -eq 2 ]
    cmp "$TEST_SCRATCH/pub/lyrebird.prom" "$TEST_SCRATCH/good.copy"
    [ "$(ls -A "$TEST_SCRATCH/pub")" = "lyrebird.prom" ]
    grep -q 'keeping the previous' "$TEST_SCRATCH/err"
}

@test "--file: a directory that cannot be written to, or an output that is a directory, exits 2 and creates nothing [LB-18]" {
    mkdir -p "$TEST_SCRATCH/pub/asdir"
    : >"$TEST_SCRATCH/notadir"
    local target
    for target in "$TEST_SCRATCH/missing/dir/lyrebird.prom" "$TEST_SCRATCH/notadir/lyrebird.prom" "$TEST_SCRATCH/pub/asdir"; do
        _publish "$target"
        [ "$RUN_RC" -eq 2 ] || { echo "$target: status $RUN_RC"; return 1; }
        [ -s "$TEST_SCRATCH/err" ]
    done
    [ ! -e "$TEST_SCRATCH/missing" ]
    [ -z "$(ls -A "$TEST_SCRATCH/pub/asdir")" ]
    # a read-only directory: root ignores permissions, so only where it can apply
    if [ "$(id -u)" -ne 0 ]; then
        mkdir -p "$TEST_SCRATCH/ro"
        chmod 555 "$TEST_SCRATCH/ro"
        _publish "$TEST_SCRATCH/ro/lyrebird.prom"
        [ "$RUN_RC" -eq 2 ]
        [ -z "$(ls -A "$TEST_SCRATCH/ro")" ]
    fi
}

@test "--file: a write that fails part-way (file size limit) keeps the last good file, leaves no temp, exits 2 [LB-18]" {
    _stub_curl "$TEST_SCRATCH/bin"
    mkdir -p "$TEST_SCRATCH/pub"
    printf '# last good\nlyrebird_scrape_success 1\n' >"$TEST_SCRATCH/pub/lyrebird.prom"
    cp "$TEST_SCRATCH/pub/lyrebird.prom" "$TEST_SCRATCH/good.copy"
    local rc=0
    (
        ulimit -f 1 # 1 KiB: the document is larger, so the write fails with EFBIG
        trap '' XFSZ
        env PROJECT_ROOT="$PROJECT_ROOT" PATH="$TEST_SCRATCH/bin:$PATH" FFMPEG_PID_DIR="$FFMPEG_PID_DIR" \
            PID_FILE="$PID_FILE" HEARTBEAT_FILE="$HEARTBEAT_FILE" \
            "$BASH" "$PROJECT_ROOT/lyrebird-metrics.sh" --file "$TEST_SCRATCH/pub/lyrebird.prom" \
            >"$TEST_SCRATCH/out" 2>"$TEST_SCRATCH/err"
    ) || rc=$?
    [ "$rc" -eq 2 ] || { echo "status $rc"; cat "$TEST_SCRATCH/err"; return 1; }
    cmp "$TEST_SCRATCH/pub/lyrebird.prom" "$TEST_SCRATCH/good.copy"
    [ "$(ls -A "$TEST_SCRATCH/pub")" = "lyrebird.prom" ]
}

@test "--file publishes a document whose collector failed, with scrape_success 0, and exits 3 [LB-18]" {
    _stub_curl "$TEST_SCRATCH/bin"
    mkdir -p "$TEST_SCRATCH/pub"
    LAUNCHER="$(_make_launcher degraded 'collect_system_metrics() { return 1; }')"
    _publish "$TEST_SCRATCH/pub/lyrebird.prom"
    [ "$RUN_RC" -eq 3 ]
    run prom_validate "$TEST_SCRATCH/pub/lyrebird.prom"
    [ "$status" -eq 0 ] || { echo "$output"; return 1; }
    grep -qx 'lyrebird_scrape_success 0' "$TEST_SCRATCH/pub/lyrebird.prom"
    grep -qx 'lyrebird_collector_success{collector="system"} 0' "$TEST_SCRATCH/pub/lyrebird.prom"
    [ "$(ls -A "$TEST_SCRATCH/pub")" = "lyrebird.prom" ]
}

@test "--file: SIGTERM during generation removes the temp file and keeps the last good file [LB-18]" {
    mkdir -p "$TEST_SCRATCH/pub"
    printf '# last good\n' >"$TEST_SCRATCH/pub/lyrebird.prom"
    local launcher
    launcher="$(_make_launcher slowgen 'generate_all_metrics() { local i; echo partial; for ((i = 0; i < 300; i++)); do sleep 0.1; done; }')"
    env PROJECT_ROOT="$PROJECT_ROOT" "$BASH" "$launcher" --file "$TEST_SCRATCH/pub/lyrebird.prom" \
        >"$TEST_SCRATCH/out" 2>"$TEST_SCRATCH/err" 3>&- &
    local pid=$! i
    for ((i = 0; i < 100; i++)); do
        [ "$(ls -A "$TEST_SCRATCH/pub" | wc -l)" -ge 2 ] && break
        sleep 0.05
    done
    [ "$(ls -A "$TEST_SCRATCH/pub" | wc -l)" -eq 2 ] || { kill "$pid"; wait "$pid" || true; echo "temp never appeared"; return 1; }
    kill -TERM "$pid"
    local rc=0
    wait "$pid" || rc=$?
    [ "$rc" -eq 143 ]
    [ "$(ls -A "$TEST_SCRATCH/pub")" = "lyrebird.prom" ]
    [ "$(cat "$TEST_SCRATCH/pub/lyrebird.prom")" = "# last good" ]
}

@test "--file gives the published file the mode a plain redirect would (umask), not mktemp's 0600 [LB-18]" {
    _stub_curl "$TEST_SCRATCH/bin"
    mkdir -p "$TEST_SCRATCH/pub"
    (umask 022; _publish "$TEST_SCRATCH/pub/a.prom")
    (umask 077; _publish "$TEST_SCRATCH/pub/b.prom")
    [ "$(stat -c %a "$TEST_SCRATCH/pub/a.prom")" = "644" ]
    [ "$(stat -c %a "$TEST_SCRATCH/pub/b.prom")" = "600" ]
}

@test "--file accepts a bare relative file name in the current directory [LB-18]" {
    _stub_curl "$TEST_SCRATCH/bin"
    mkdir -p "$TEST_SCRATCH/pub"
    local rc=0
    (
        cd "$TEST_SCRATCH/pub"
        env PROJECT_ROOT="$PROJECT_ROOT" PATH="$TEST_SCRATCH/bin:$PATH" FFMPEG_PID_DIR="$FFMPEG_PID_DIR" \
            PID_FILE="$PID_FILE" HEARTBEAT_FILE="$HEARTBEAT_FILE" \
            "$BASH" "$PROJECT_ROOT/lyrebird-metrics.sh" --file lyrebird.prom
    ) >/dev/null 2>&1 || rc=$?
    [ "$rc" -eq 0 ]
    run prom_validate "$TEST_SCRATCH/pub/lyrebird.prom"
    [ "$status" -eq 0 ] || { echo "$output"; return 1; }
    [ "$(ls -A "$TEST_SCRATCH/pub")" = "lyrebird.prom" ]
}

# --- heartbeat health threshold (X-13) -------------------------------------------

# Run collect_stream_manager_metrics for real against a heartbeat file written
# AGE seconds ago ("none": no file; "raw:TEXT": that content). Further arguments
# are env assignments. Output goes to $TEST_SCRATCH/hb.prom, stderr to hb.err.
_heartbeat_scrape() {
    local age="$1" hb="$TEST_SCRATCH/heartbeat"
    shift
    rm -f "$hb"
    case "$age" in
        none) ;;
        raw:*) printf '%s\n' "${age#raw:}" >"$hb" ;;
        *) echo $(($(date +%s) - age)) >"$hb" ;;
    esac
    RUN_RC=0
    env -u LYREBIRD_HEARTBEAT_MAX_AGE PROJECT_ROOT="$PROJECT_ROOT" HEARTBEAT_FILE="$hb" \
        PID_FILE="$PID_FILE" FFMPEG_PID_DIR="$FFMPEG_PID_DIR" "$@" \
        "$BASH" -c 'set -euo pipefail; source "$PROJECT_ROOT/lyrebird-metrics.sh"; collect_stream_manager_metrics' \
        >"$TEST_SCRATCH/hb.prom" 2>"$TEST_SCRATCH/hb.err" || RUN_RC=$?
}

_heartbeat_healthy() {
    awk '/^lyrebird_heartbeat_healthy /{print $2}' "$TEST_SCRATCH/hb.prom"
}

@test "heartbeat_healthy is 1 at 59, 299 and 899 s and 0 at 901 s with the default 900 s maximum [X-13]" {
    local age expected
    for age in 59 299 899 901; do
        _heartbeat_scrape "$age"
        [ "$RUN_RC" -eq 0 ]
        expected=1
        [ "$age" -gt 900 ] && expected=0
        [ "$(_heartbeat_healthy)" = "$expected" ] || { echo "age ${age}s: healthy=$(_heartbeat_healthy), want $expected"; return 1; }
        grep -Eq "^lyrebird_heartbeat_age_seconds ($age|$((age + 1)))$" "$TEST_SCRATCH/hb.prom"
    done
}

@test "LYREBIRD_HEARTBEAT_MAX_AGE sets the heartbeat threshold [X-13]" {
    _heartbeat_scrape 59 LYREBIRD_HEARTBEAT_MAX_AGE=60
    [ "$(_heartbeat_healthy)" = "1" ]
    _heartbeat_scrape 70 LYREBIRD_HEARTBEAT_MAX_AGE=60
    [ "$(_heartbeat_healthy)" = "0" ]
    _heartbeat_scrape 3000 LYREBIRD_HEARTBEAT_MAX_AGE=3600
    [ "$(_heartbeat_healthy)" = "1" ]
    _heartbeat_scrape 3700 LYREBIRD_HEARTBEAT_MAX_AGE=3600
    [ "$(_heartbeat_healthy)" = "0" ]
}

@test "the heartbeat HELP text says what it proves and names the threshold in force [X-13]" {
    _heartbeat_scrape 10
    grep -q '^# HELP lyrebird_heartbeat_healthy 1 if the stream-manager monitor ran within the last 900 seconds' "$TEST_SCRATCH/hb.prom"
    grep -q 'proves only that the monitor ran, not that streams are healthy' "$TEST_SCRATCH/hb.prom"
    grep -q '^# HELP lyrebird_heartbeat_age_seconds Seconds since the stream-manager monitor last wrote' "$TEST_SCRATCH/hb.prom"
    _heartbeat_scrape 10 LYREBIRD_HEARTBEAT_MAX_AGE=120
    grep -q 'monitor ran within the last 120 seconds' "$TEST_SCRATCH/hb.prom"
    run prom_validate "$TEST_SCRATCH/hb.prom"
    [ "$status" -eq 0 ] || { echo "$output"; return 1; }
}

@test "an invalid LYREBIRD_HEARTBEAT_MAX_AGE is ignored with a warning and 900 s is used [X-13]" {
    local bad
    for bad in abc 0 -5 1.5 '10 20'; do
        _heartbeat_scrape 800 LYREBIRD_HEARTBEAT_MAX_AGE="$bad"
        [ "$RUN_RC" -eq 0 ]
        grep -q "ignoring LYREBIRD_HEARTBEAT_MAX_AGE='${bad}'" "$TEST_SCRATCH/hb.err" || { echo "no warning for '$bad'"; return 1; }
        [ "$(_heartbeat_healthy)" = "1" ] || { echo "'$bad' did not fall back to 900"; return 1; }
    done
    # unset or empty is the default, without a warning
    _heartbeat_scrape 800 LYREBIRD_HEARTBEAT_MAX_AGE=
    [ ! -s "$TEST_SCRATCH/hb.err" ]
    [ "$(_heartbeat_healthy)" = "1" ]
}

@test "heartbeat edge cases: no file, a timestamp from the future, a corrupt file, leading zeros [X-13]" {
    _heartbeat_scrape none
    [ "$RUN_RC" -eq 0 ]
    grep -qx 'lyrebird_heartbeat_age_seconds -1' "$TEST_SCRATCH/hb.prom"
    [ "$(_heartbeat_healthy)" = "0" ]

    _heartbeat_scrape -300 # written 300 s in the future: the clock was stepped back
    [ "$RUN_RC" -eq 0 ]
    [ "$(_heartbeat_healthy)" = "0" ]

    _heartbeat_scrape "raw:garbage"
    [ "$RUN_RC" -eq 0 ]
    [ "$(_heartbeat_healthy)" = "0" ]

    _heartbeat_scrape "raw:08" # a leading zero must not be read as octal
    [ "$RUN_RC" -eq 0 ] || { cat "$TEST_SCRATCH/hb.err"; return 1; }
    [ "$(_heartbeat_healthy)" = "0" ]
}

@test "an unreadable heartbeat file is left out and fails the collector instead of reading as stale [X-13]" {
    local real_cat
    mkdir -p "$TEST_SCRATCH/bin"
    real_cat="$(command -v cat)"
    cat >"$TEST_SCRATCH/bin/cat" <<EOF
#!/bin/bash
for a in "\$@"; do
    if [[ "\$a" == */heartbeat ]]; then echo "cat: \$a: Permission denied" >&2; exit 1; fi
done
exec "$real_cat" "\$@"
EOF
    chmod +x "$TEST_SCRATCH/bin/cat"
    _heartbeat_scrape 10 PATH="$TEST_SCRATCH/bin:$PATH"
    [ "$RUN_RC" -eq 1 ]
    grep -q 'cannot read' "$TEST_SCRATCH/hb.err"
    ! grep -q '^lyrebird_heartbeat_' "$TEST_SCRATCH/hb.prom" || false
}

@test "emit_metric refuses an empty or non-numeric value: no output, counted, status 0 [LB-18]" {
    local v expected=0
    for v in '' 'N/A' '1,5' 'abc' '1 2' '--1'; do
        emit_metric "x" "$v" "help" "gauge" 'a="b"' >"$TEST_SCRATCH/refused.out" 2>/dev/null
        expected=$((expected + 1))
        [ ! -s "$TEST_SCRATCH/refused.out" ] || { echo "value '$v' produced output"; return 1; }
        [ "$_EMIT_ERRORS" -eq "$expected" ] || { echo "value '$v' was not counted ($_EMIT_ERRORS)"; return 1; }
    done
    for v in 0 -1 3.14 .5 1e3 -2.5E-3 +Inf -Inf NaN; do
        emit_metric "x" "$v" "" "gauge" >"$TEST_SCRATCH/accepted.out" 2>/dev/null
        [ "$(cat "$TEST_SCRATCH/accepted.out")" = "lyrebird_x $v" ] || { echo "value '$v' refused"; return 1; }
    done
    [ "$_EMIT_ERRORS" -eq "$expected" ]
}

@test "configured_devices is omitted, never emitted empty, when the device config cannot be read [LB-18]" {
    local cfgdir="$TEST_SCRATCH/cfg" real_grep
    mkdir -p "$cfgdir" "$TEST_SCRATCH/bin"
    : >"$cfgdir/audio-devices.conf"
    real_grep="$(command -v grep)"
    # grep -c failing the way it does on an unreadable file: status 2, no output
    cat >"$TEST_SCRATCH/bin/grep" <<EOF
#!/bin/bash
for a in "\$@"; do [[ "\$a" == "-c" ]] && exit 2; done
exec "$real_grep" "\$@"
EOF
    chmod +x "$TEST_SCRATCH/bin/grep"
    run env PROJECT_ROOT="$PROJECT_ROOT" PATH="$TEST_SCRATCH/bin:$PATH" MEDIAMTX_CONFIG_DIR="$cfgdir" \
        PID_FILE="$PID_FILE" FFMPEG_PID_DIR="$FFMPEG_PID_DIR" HEARTBEAT_FILE="$HEARTBEAT_FILE" \
        bash -c 'set -euo pipefail; source "$PROJECT_ROOT/lyrebird-metrics.sh"; collect_stream_manager_metrics 2>/dev/null'
    # the collector reports the unreadable source (status 1) but still prints a valid document
    [ "$status" -eq 1 ]
    printf '%s\n' "$output" >"$TEST_SCRATCH/mgr.prom"
    run prom_validate "$TEST_SCRATCH/mgr.prom"
    [ "$status" -eq 0 ] || { echo "$output"; return 1; }
    ! grep -q '^lyrebird_configured_devices' "$TEST_SCRATCH/mgr.prom" || false
}

# ============================================================================
# HTTP server (--serve), LB-18 / X-17. Everything below runs the real script with
# the netcat of this machine (OpenBSD) on ports from the private block 32000-32099,
# or with PATH shims that stand in for the other netcat variants.
# ============================================================================

SERVER_ENV=()
SERVER_PID=""
SERVER_CHILDREN=""
DECOY_PID=""

# Two ports out of the private block 32000-32099 for this test (never 9100).
_serve_port() {
    printf '%s' $((32000 + (BATS_TEST_NUMBER % 48) * 2))
}

# Start the real server in the background. Arguments are the script's arguments;
# LAUNCHER, SERVER_ENV (VAR=value ...), SERVER_PATH and SERVER_PID_DIR adjust the run.
_start_server() {
    local launcher="${LAUNCHER:-$PROJECT_ROOT/lyrebird-metrics.sh}"
    : >"$TEST_SCRATCH/server.err"
    # A background job of a non-interactive shell starts with SIGINT ignored, and a
    # shell cannot un-ignore it; python resets it before exec so Ctrl+C is testable.
    python3 -I -c 'import os, signal, sys; signal.signal(signal.SIGINT, signal.SIG_DFL); os.execvp(sys.argv[1], sys.argv[1:])' \
        env PROJECT_ROOT="$PROJECT_ROOT" PATH="${SERVER_PATH:-$TEST_SCRATCH/bin:$PATH}" \
        FFMPEG_PID_DIR="${SERVER_PID_DIR:-$FFMPEG_PID_DIR}" PID_FILE="$PID_FILE" HEARTBEAT_FILE="$HEARTBEAT_FILE" \
        ${SERVER_ENV[@]+"${SERVER_ENV[@]}"} "$BASH" "$launcher" "$@" \
        >"$TEST_SCRATCH/server.out" 2>"$TEST_SCRATCH/server.err" 3>&- &
    SERVER_PID=$!
}

# Wait until the server says it is listening (0) or dies first (1).
_wait_listening() {
    local i
    for ((i = 0; i < 200; i++)); do
        if grep -q 'listening on' "$TEST_SCRATCH/server.err" 2>/dev/null; then
            return 0
        fi
        kill -0 "$SERVER_PID" 2>/dev/null || return 1
        sleep 0.05
    done
    return 1
}

# Wait for the server process to end; its status goes to SERVER_RC (255 if it had to be killed).
_wait_exit() {
    local i limit="${1:-100}" pid
    SERVER_RC=0
    for ((i = 0; i < limit; i++)); do
        kill -0 "$SERVER_PID" 2>/dev/null || break
        sleep 0.05
    done
    if kill -0 "$SERVER_PID" 2>/dev/null; then
        # it did not stop: kill it, and the netcat processes it started with it
        _note_children
        kill -KILL "$SERVER_PID" 2>/dev/null || true
        for pid in $SERVER_CHILDREN; do
            kill "$pid" 2>/dev/null || true
        done
        SERVER_RC=255
    fi
    wait "$SERVER_PID" 2>/dev/null || SERVER_RC=$?
    SERVER_PID=""
}

# Remember the netcat processes the server started (to reap them if a test fails).
_note_children() {
    SERVER_CHILDREN="$(ps -o pid= --ppid "$SERVER_PID" 2>/dev/null | tr -d ' ' | tr '\n' ' ')"
}

# Stop whatever a test left running: SIGTERM first so the server cleans up, then
# only the pids this test started (and only while they still carry the test port).
_serve_teardown() {
    local pid port
    port="$(_serve_port)"
    if [[ -n "${SERVER_PID:-}" ]] && kill -0 "$SERVER_PID" 2>/dev/null; then
        _note_children
        kill -TERM "$SERVER_PID" 2>/dev/null || true
        _wait_exit 60
    fi
    for pid in ${SERVER_CHILDREN:-} ${DECOY_PID:-}; do
        if grep -qa "$port" "/proc/$pid/cmdline" 2>/dev/null; then
            kill "$pid" 2>/dev/null || true
        fi
    done
    return 0
}

# Local addresses (hex, as /proc/net/tcp shows them) with a listening socket on port $1.
_listen_addrs() {
    local hex table
    local -a tables=()
    hex="$(printf '%04X' "$1")"
    for table in /proc/net/tcp /proc/net/tcp6; do
        [ -r "$table" ] && tables+=("$table")
    done
    awk -v p="$hex" '$4 == "0A" { split($2, a, ":"); if (a[2] == p) print a[1] }' "${tables[@]}" | sort | tr '\n' ' '
}

# Send REQUEST ($2, with \r \n escapes) to port $1 and report the framing (see
# tests/helpers/http_probe.py). Output in $TEST_SCRATCH/probe, body in $TEST_SCRATCH/body.
_probe() {
    python3 -I "$PROJECT_ROOT/tests/helpers/http_probe.py" "$1" "$2" "$TEST_SCRATCH/body" "${3:-20}" ${4:+"$4"} \
        >"$TEST_SCRATCH/probe" 2>&1 || true
}

_probe_field() {
    grep "^$1=" "$TEST_SCRATCH/probe" | head -1 | cut -d= -f2-
}

# The server's own sockets on PORT, from /proc/net/tcp*: "L A" = L listening
# sockets and A sockets in a connection that has not ended (TIME_WAIT and
# CLOSE are over). A server serves one connection with one nc and arms the next
# nc while it does; the nc of a served connection keeps its listening socket
# until it exits, and a client that connects in that time can be given to it and
# reset (SO_REUSEPORT: the kernel splits new connections between listening
# sockets of the same port). So a client that comes right after another is only
# promised an answer once the server is idle again, which is exactly one
# listening socket (the armed nc) and no connection.
_server_sockets() {
    awk -v port="$(printf '%04X' "$1")" '
        { split($2, a, ":") }
        a[2] == port && $4 == "0A" { l++ }
        a[2] == port && $4 ~ /^(01|02|03|04|05|08|09|0B)$/ { c++ }
        END { printf "%d %d\n", l, c }' $(ls /proc/net/tcp /proc/net/tcp6 2>/dev/null) || true
}

# Wait until the server on PORT is idle (see _server_sockets), at most ~10 s.
# This is what "ready for the next request" means: a fixed pause is not (how
# long the previous nc takes to exit depends on the machine's load).
_wait_idle() {
    local i sockets=""
    for ((i = 0; i < 200; i++)); do
        sockets="$(_server_sockets "$1")"
        [ "$sockets" = "1 0" ] && return 0
        sleep 0.05
    done
    echo "the server on port $1 did not become idle (listening sockets, live connections): $sockets"
    return 1
}

# A launcher that sources the real script, applies SNIPPET and runs the real main.
_server_launcher() {
    _make_launcher "$1" "$2"
}

@test "valid_port and valid_bind accept exactly ports 1-65535 and IPv4/IPv6 literals [LB-18]" {
    local p
    for p in 1 80 9100 65535 09100; do valid_port "$p" || { echo "rejected $p"; return 1; }; done
    for p in 0 65536 99999 abc -1 '' '1 2' 100000; do ! valid_port "$p" || { echo "accepted '$p'"; return 1; }; done
    for p in 127.0.0.1 0.0.0.0 255.255.255.255 ::1 :: fe80::1 2001:db8::8a2e:370:7334 ::ffff:10.0.0.1; do
        valid_bind "$p" || { echo "rejected $p"; return 1; }
    done
    for p in 256.1.1.1 1.2.3 1.2.3.4.5 localhost example.com 12345 ':' 'g::1' '1.2.3.4 ' ''; do
        ! valid_bind "$p" || { echo "accepted '$p'"; return 1; }
    done
}

@test "byte_length counts bytes, not characters, in a UTF-8 locale and in the C locale [LB-18]" {
    local s='Studio-é-麦克风' loc n
    for loc in C.utf8 C; do
        n="$(LC_ALL=$loc bash -c 'source "$1"; byte_length "$2"; echo "$_BYTES"' _ "$PROJECT_ROOT/lyrebird-metrics.sh" "$s")"
        [ "$n" -eq "$(printf '%s' "$s" | LC_ALL=C wc -c)" ] || { echo "$loc: counted $n"; return 1; }
    done
    [ "$n" -gt "${#s}" ] || true
}

@test "classify_nc recognises the four netcat variants by their help text and nothing else [LB-18]" {
    [ "$(classify_nc "$(nc -h 2>&1 || true)")" = "openbsd" ]
    [ "$(classify_nc $'usage: nc [-46CDdFhklNnrStUuvZz] [-I length]')" = "openbsd" ]
    [ "$(classify_nc $'Ncat 7.94 ( https://nmap.org/ncat )\nUsage: ncat')" = "ncat" ]
    [ "$(classify_nc $'[v1.10-47]\nconnect to somewhere:\tnc [-options] hostname port[s]')" = "traditional" ]
    [ "$(classify_nc $'GNU netcat 0.7.1, a rewrite of the famous networking tool.')" = "traditional" ]
    [ "$(classify_nc $'BusyBox v1.36.1 multi-call binary.\n\nUsage: nc [OPTIONS] HOST PORT')" = "busybox" ]
    [ -z "$(classify_nc 'mystery netcat 0.1')" ]
    [ -z "$(classify_nc '')" ]
}

@test "serve: --serve PORT listens on 127.0.0.1 only by default and the log line says so [LB-18]" {
    local port
    port="$(_serve_port)"
    _stub_curl "$TEST_SCRATCH/bin"
    _start_server --serve "$port"
    _wait_listening || { cat "$TEST_SCRATCH/server.err"; return 1; }
    [ "$(_listen_addrs "$port")" = "0100007F " ] || { echo "listening on: $(_listen_addrs "$port")"; return 1; }
    grep -q "listening on http://127.0.0.1:${port}/metrics" "$TEST_SCRATCH/server.err"
    ! grep -qi 'localhost' "$TEST_SCRATCH/server.err" || false
    ! grep -q 'WARN' "$TEST_SCRATCH/server.err" || false
    _stop_server_term_ok
}

# SIGTERM the server and require a clean exit (status 0).
_stop_server_term_ok() {
    kill -TERM "$SERVER_PID"
    _wait_exit 100
    [ "$SERVER_RC" -eq 0 ] || { echo "server exit status $SERVER_RC"; cat "$TEST_SCRATCH/server.err"; return 1; }
}

@test "serve: --bind 0.0.0.0 listens on all interfaces and warns that nothing protects it; localhost means 127.0.0.1 [LB-18]" {
    local port
    port="$(_serve_port)"
    _stub_curl "$TEST_SCRATCH/bin"
    _start_server --serve "$port" --bind 0.0.0.0
    _wait_listening || { cat "$TEST_SCRATCH/server.err"; return 1; }
    [ "$(_listen_addrs "$port")" = "00000000 " ] || { echo "listening on: $(_listen_addrs "$port")"; return 1; }
    grep -q 'WARN: 0.0.0.0 is not a loopback address' "$TEST_SCRATCH/server.err"
    grep -q 'without authentication' "$TEST_SCRATCH/server.err"
    _stop_server_term_ok

    _start_server serve --port "$port" --bind localhost
    _wait_listening || { cat "$TEST_SCRATCH/server.err"; return 1; }
    [ "$(_listen_addrs "$port")" = "0100007F " ]
    _stop_server_term_ok
}

@test "serve: 'serve --port PORT' (the documented spelling), '--serve PORT' and '--port PORT serve' all start the server [LB-18]" {
    local port args
    port="$(_serve_port)"
    _stub_curl "$TEST_SCRATCH/bin"
    for args in "serve --port $port" "--serve $port" "--port $port serve" "--serve --port $port" "serve --bind 127.0.0.1 --port $port"; do
        # shellcheck disable=SC2086
        _start_server $args
        _wait_listening || { echo "'$args' did not start"; cat "$TEST_SCRATCH/server.err"; return 1; }
        [ "$(_listen_addrs "$port")" = "0100007F " ] || { echo "'$args': listening on $(_listen_addrs "$port")"; return 1; }
        _stop_server_term_ok
    done
}

@test "serve: a bad command line exits 1 with a message and starts nothing [LB-18]" {
    local port args rc
    port="$(_serve_port)"
    for args in "--port $port" "--bind 127.0.0.1" "--once --port $port" "serve --port 0" "serve --port 65536" \
        "serve --port abc" "serve --port" "serve --bind" "serve --bind notanaddress" "serve --bind 999.1.1.1" \
        "serve --bind 1.2.3" "--serve 70000" "--serve 0"; do
        rc=0
        # shellcheck disable=SC2086
        env PROJECT_ROOT="$PROJECT_ROOT" "$BASH" "$PROJECT_ROOT/lyrebird-metrics.sh" $args \
            >"$TEST_SCRATCH/out" 2>"$TEST_SCRATCH/err" </dev/null || rc=$?
        [ "$rc" -eq 1 ] || { echo "'$args' exited $rc"; return 1; }
        grep -q 'ERROR' "$TEST_SCRATCH/err" || { echo "'$args': no message"; return 1; }
        [ -z "$(_listen_addrs "$port")" ]
    done
}

@test "serve: GET / and GET /metrics are 200, other paths 404, other methods 405, malformed requests 400 [LB-18]" {
    local port case_ request want got
    port="$(_serve_port)"
    _stub_curl "$TEST_SCRATCH/bin"
    _start_server --serve "$port"
    _wait_listening || { cat "$TEST_SCRATCH/server.err"; return 1; }
    local -a cases=(
        'GET /metrics HTTP/1.1\r\nHost: x\r\n\r\n|200'
        'GET / HTTP/1.1\r\nHost: x\r\n\r\n|200'
        'GET /metrics?name=x HTTP/1.1\r\n\r\n|200'
        'GET /metrics HTTP/1.0\r\n\r\n|200'
        'GET /nope HTTP/1.1\r\n\r\n|404'
        'GET /metrics/ HTTP/1.1\r\n\r\n|404'
        'GET /metrics.json HTTP/1.1\r\n\r\n|404'
        'POST /nope HTTP/1.1\r\n\r\n|404'
        'POST /metrics HTTP/1.1\r\nContent-Length: 7\r\n\r\ngarbage|405'
        'PUT / HTTP/1.1\r\n\r\n|405'
        'HEAD /metrics HTTP/1.1\r\n\r\n|405'
        'DELETE /metrics HTTP/1.1\r\n\r\n|405'
        'get /metrics HTTP/1.1\r\n\r\n|400'
        'GET http://host/metrics HTTP/1.1\r\n\r\n|400'
        'GET /metrics\r\n\r\n|400'
        'garbage\r\n\r\n|400'
    )
    for case_ in "${cases[@]}"; do
        request="${case_%|*}"
        want="${case_##*|}"
        _wait_idle "$port"
        _probe "$port" "$request"
        got="$(_probe_field status)"
        [ "$got" = "$want" ] || { echo "$request -> $got, want $want"; cat "$TEST_SCRATCH/probe"; return 1; }
        [ "$(_probe_field head_crlf)" = "1" ]
        [ "$(_probe_field content_length_ok)" = "1" ]
        [ "$(_probe_field header.connection)" = "close" ]
        if [ "$want" = "405" ]; then
            [ "$(_probe_field header.allow)" = "GET" ]
        fi
        if [ "$want" = "200" ]; then
            run prom_validate "$TEST_SCRATCH/body"
            [ "$status" -eq 0 ] || { echo "$output"; return 1; }
        fi
    done
    _stop_server_term_ok
}

@test "serve: responses use CRLF and a Content-Length in bytes, and a multibyte or backslash label arrives untouched, in a UTF-8 and in the C locale [LB-18]" {
    local port loc dir="$TEST_SCRATCH/pids" bytes chars
    port="$(_serve_port)"
    mkdir -p "$dir"
    # Studio-é-麦克风: multibyte; a\nb: backslash + n (what `echo -e` turns into a newline); a tab
    for name in 'Studio-é-麦克风' 'a\nb' $'tab\there' 'c:\dir\table'; do
        echo $$ >"$dir/${name}.pid"
    done
    _stub_curl "$TEST_SCRATCH/bin"
    for loc in C.utf8 C; do
        if [ "$loc" = "C.utf8" ] && [ "$(LC_ALL=C.utf8 bash -c 'x=é; echo ${#x}')" != "1" ]; then
            skip "no UTF-8 locale installed"
        fi
        SERVER_ENV=(LC_ALL="$loc")
        SERVER_PID_DIR="$dir"
        _start_server --serve "$port"
        _wait_listening || { cat "$TEST_SCRATCH/server.err"; return 1; }
        _probe "$port" 'GET /metrics HTTP/1.1\r\nHost: x\r\n\r\n'
        [ "$(_probe_field status)" = "200" ] || { cat "$TEST_SCRATCH/probe"; return 1; }
        [ "$(_probe_field head_crlf)" = "1" ]
        [ "$(_probe_field header.connection)" = "close" ]
        [ "$(_probe_field header.content-type)" = "text/plain; version=0.0.4; charset=utf-8" ]
        [ "$(_probe_field content_length_ok)" = "1" ] || { echo "$loc: $(_probe_field header.content-length) declared, $(_probe_field body_bytes) sent"; return 1; }
        # the document really contains multibyte text (bytes != characters)
        bytes="$(LC_ALL=C wc -c <"$TEST_SCRATCH/body")"
        chars="$(LC_ALL=C.utf8 wc -m <"$TEST_SCRATCH/body")"
        [ "$bytes" -gt "$chars" ] || { echo "no multibyte text in the body ($bytes bytes, $chars chars)"; return 1; }
        grep -qF 'lyrebird_stream_up{stream="Studio-é-麦克风"} 1' "$TEST_SCRATCH/body"
        grep -qF 'lyrebird_stream_up{stream="a\\nb"} 1' "$TEST_SCRATCH/body"
        grep -qF 'lyrebird_stream_up{stream="c:\\dir\\table"} 1' "$TEST_SCRATCH/body"
        grep -qF "lyrebird_stream_up{stream=\"tab"$'\t'"here\"} 1" "$TEST_SCRATCH/body"
        run prom_validate "$TEST_SCRATCH/body"
        [ "$status" -eq 0 ] || { echo "$output"; return 1; }
        _stop_server_term_ok
    done
}

@test "serve: the metrics are generated after the request arrives, not before the server starts waiting [LB-18]" {
    local port t0 ts
    port="$(_serve_port)"
    _stub_curl "$TEST_SCRATCH/bin"
    _start_server --serve "$port"
    _wait_listening || { cat "$TEST_SCRATCH/server.err"; return 1; }
    sleep 2.2
    t0="$(date +%s)"
    _probe "$port" 'GET /metrics HTTP/1.1\r\n\r\n'
    [ "$(_probe_field status)" = "200" ]
    ts="$(awk '/^lyrebird_scrape_timestamp_seconds /{print $2}' "$TEST_SCRATCH/body")"
    [[ "$ts" =~ ^[0-9]+$ ]]
    [ "$ts" -ge "$t0" ] || { echo "generated at $ts, request at $t0: stale by $((t0 - ts)) s"; return 1; }
    _stop_server_term_ok
}

@test "serve: the next listener is armed before the metrics are generated, so the port is never left without one [LB-18]" {
    local port launcher i seen=0
    port="$(_serve_port)"
    launcher="$(_make_launcher slowgen2 'generate_all_metrics() { local i; for ((i = 0; i < 20; i++)); do sleep 0.1; done; echo "lyrebird_slow 1"; }')"
    LAUNCHER="$launcher"
    _start_server --serve "$port"
    _wait_listening || { cat "$TEST_SCRATCH/server.err"; return 1; }
    [ "$(_listen_addrs "$port" | wc -w)" -eq 1 ]
    ( _probe "$port" 'GET /metrics HTTP/1.1\r\n\r\n' 30 ) 3>&- &
    local client=$!
    # while that request is being answered (2 s), a second listener must be up
    for ((i = 0; i < 40; i++)); do
        if [ "$(grep -c . <<<"$(awk -v p="$(printf '%04X' "$port")" '$4 == "0A" { split($2, a, ":"); if (a[2] == p) print a[1] }' /proc/net/tcp)")" -ge 2 ]; then
            seen=1
            break
        fi
        sleep 0.05
    done
    wait "$client"
    [ "$seen" -eq 1 ] || { echo "only one listener while a request was being answered"; return 1; }
    [ "$(_probe_field status)" = "200" ]
    grep -q '^lyrebird_slow 1' "$TEST_SCRATCH/body"
    _stop_server_term_ok
}

@test "serve: requests that follow each other are all answered, each by a freshly armed listener [LB-18]" {
    local port i
    port="$(_serve_port)"
    _stub_curl "$TEST_SCRATCH/bin"
    _start_server --serve "$port"
    _wait_listening || { cat "$TEST_SCRATCH/server.err"; return 1; }
    for ((i = 0; i < 12; i++)); do
        # each request is answered by a listener armed while the previous one was served
        _wait_idle "$port"
        _probe "$port" 'GET /metrics HTTP/1.1\r\n\r\n'
        [ "$(_probe_field status)" = "200" ] || { echo "request $i: $(cat "$TEST_SCRATCH/probe")"; return 1; }
    done
    _stop_server_term_ok
}

@test "listener_alive identifies the nc by pid AND start time: a reused pid is not ours [LB-18]" {
    sleep 30 3>&- &
    local pid=$!
    _L_PID[0]="$pid"
    read_proc_stat "$pid"
    _L_START[0]="$_PS_START"
    listener_alive 0
    # the same pid with a different start time is another process
    _L_START[0]="1"
    ! listener_alive 0 || { kill "$pid"; false; }
    _L_START[0]="$_PS_START"
    kill "$pid"
    wait "$pid" || true
    ! listener_alive 0 || false
}

@test "port_in_use sees a listener on the port, on that address or on every address, and nothing else [LB-18]" {
    local port holder
    port="$(_serve_port)"
    ! port_in_use "$port" 127.0.0.1 || false
    python3 -I "$PROJECT_ROOT/tests/helpers/port_holder.py" "$port" 30 3>&- &
    holder=$!
    DECOY_PID="$holder"
    sleep 0.5
    port_in_use "$port" 127.0.0.1
    port_in_use "$port" 0.0.0.0 # a wildcard bind collides with any listener on the port
    ! port_in_use "$port" 127.0.0.2 || false # another address does not
    ! port_in_use "$((port + 1))" 127.0.0.1 || false
    kill "$holder"
    wait "$holder" 2>/dev/null || true
    sleep 0.2
    # a listener on every address collides with a bind to any one of them
    python3 -I "$PROJECT_ROOT/tests/helpers/port_holder.py" "$port" 30 0.0.0.0 3>&- &
    holder=$!
    DECOY_PID="$holder"
    sleep 0.5
    port_in_use "$port" 127.0.0.1
    port_in_use "$port" 127.0.0.2
    kill "$holder"
    wait "$holder" 2>/dev/null || true
    DECOY_PID=""
}

@test "--help says the server is made for a poller: a client that connects while another is served can be reset [X-44]" {
    # netcat keeps its listening socket until it exits (see _server_sockets), so this is
    # the server's limit, and the help must not promise more than "one connection at a time"
    run "$BASH" "$PROJECT_ROOT/lyrebird-metrics.sh" --help
    [ "$status" -eq 0 ]
    [[ "$output" == *"one connection at a time"* ]]
    [[ "$output" == *"made for a poller"* && "$output" == *"can be reset and has to try again"* ]]
}

@test "serve: a client that half-closes and one that sends a huge or endless request do not wedge the server [LB-18]" {
    local port i
    port="$(_serve_port)"
    _stub_curl "$TEST_SCRATCH/bin"
    _start_server --serve "$port"
    _wait_listening || { cat "$TEST_SCRATCH/server.err"; return 1; }
    # a client that shuts down its sending side before the response (OpenBSD nc closes the socket then)
    _probe "$port" 'GET /metrics HTTP/1.0\r\n\r\n' 20 half-close
    # a request line far beyond any sane length
    _wait_idle "$port"
    _probe "$port" "GET /$(printf 'a%.0s' $(seq 1 12000)) HTTP/1.1\\r\\n\\r\\n"
    [ "$(_probe_field status)" = "400" ] || { cat "$TEST_SCRATCH/probe"; return 1; }
    # an endless header section
    _wait_idle "$port"
    _probe "$port" "GET / HTTP/1.1\\r\\n$(printf 'X: y\\r\\n%.0s' $(seq 1 150))\\r\\n"
    [ "$(_probe_field status)" = "400" ] || { cat "$TEST_SCRATCH/probe"; return 1; }
    # and the server still answers
    _wait_idle "$port"
    _probe "$port" 'GET /metrics HTTP/1.1\r\n\r\n'
    [ "$(_probe_field status)" = "200" ]
    kill -0 "$SERVER_PID"
    _stop_server_term_ok
}

@test "serve: an idle listener is recycled, which frees the port from a client that connected and never sent anything [LB-18]" {
    local port launcher
    port="$(_serve_port)"
    _stub_curl "$TEST_SCRATCH/bin"
    launcher="$(_make_launcher rotate 'SERVE_IDLE_ROTATE=1')"
    LAUNCHER="$launcher"
    _start_server --serve "$port"
    _wait_listening || { cat "$TEST_SCRATCH/server.err"; return 1; }
    # the silent client holds the listener's only connection
    python3 -I - "$port" "$TEST_SCRATCH/silent.out" 3>&- <<'PY' &
import socket, sys, time
port, out = int(sys.argv[1]), sys.argv[2]
silent = socket.create_connection(("127.0.0.1", port), timeout=5)
time.sleep(0.2)
served = None
t0 = time.time()
while time.time() - t0 < 12 and served is None:
    try:
        s = socket.create_connection(("127.0.0.1", port), timeout=5)
        s.sendall(b"GET /metrics HTTP/1.1\r\nHost: x\r\n\r\n")
        d = b""
        while True:
            c = s.recv(65536)
            if not c:
                break
            d += c
        if d.startswith(b"HTTP/1.1 200"):
            served = time.time() - t0
    except OSError:
        pass
    if served is None:
        time.sleep(0.1)
open(out, "w").write("served after %.1f\n" % served if served is not None else "never served\n")
PY
    wait "$!"
    grep -q '^served after' "$TEST_SCRATCH/silent.out" || { cat "$TEST_SCRATCH/silent.out"; return 1; }
    _stop_server_term_ok
}

@test "serve: SIGTERM and SIGINT stop it cleanly, the nc it started is gone and its temp directory is removed [LB-18]" {
    local port sig pid before after state
    port="$(_serve_port)"
    _stub_curl "$TEST_SCRATCH/bin"
    for sig in TERM INT; do
        for state in idle served; do
            before="$(ls -A "$TEST_SCRATCH" | sort | tr '\n' ' ')"
            _start_server --serve "$port"
            _wait_listening || { cat "$TEST_SCRATCH/server.err"; return 1; }
            if [ "$state" = "served" ]; then
                _probe "$port" 'GET /metrics HTTP/1.1\r\n\r\n'
                [ "$(_probe_field status)" = "200" ]
            fi
            _note_children
            [ -n "$SERVER_CHILDREN" ] || { echo "no nc child found"; return 1; }
            kill -"$sig" "$SERVER_PID"
            _wait_exit 60
            [ "$SERVER_RC" -eq 0 ] || { echo "$sig/$state: status $SERVER_RC"; cat "$TEST_SCRATCH/server.err"; return 1; }
            for pid in $SERVER_CHILDREN; do
                ! kill -0 "$pid" 2>/dev/null || { echo "$sig/$state: nc $pid survived the server"; return 1; }
            done
            [ -z "$(_listen_addrs "$port")" ] || { echo "$sig/$state: port still bound"; return 1; }
            grep -q 'Shutting down' "$TEST_SCRATCH/server.err"
            # no private temp directory left behind
            after="$(ls -A "$TEST_SCRATCH" | sort | tr '\n' ' ')"
            [ "$(grep -o 'tmp\.[A-Za-z0-9]*' <<<"$after" | sort | tr '\n' ' ')" = "$(grep -o 'tmp\.[A-Za-z0-9]*' <<<"$before" | sort | tr '\n' ' ')" ] \
                || { echo "$sig/$state: temp left: before=[$before] after=[$after]"; return 1; }
            SERVER_CHILDREN=""
        done
    done
}

@test "serve: SIGTERM while a request is being answered stops both netcat processes once the generation ends [LB-18]" {
    local port launcher i pid seen=0 client
    port="$(_serve_port)"
    launcher="$(_make_launcher slowgen3 'generate_all_metrics() { local i; for ((i = 0; i < 20; i++)); do sleep 0.1; done; echo "lyrebird_slow 1"; }')"
    LAUNCHER="$launcher"
    _start_server --serve "$port"
    _wait_listening || { cat "$TEST_SCRATCH/server.err"; return 1; }
    ( _probe "$port" 'GET /metrics HTTP/1.1\r\n\r\n' 30 ) 3>&- &
    client=$!
    # two netcat processes while it is answered: the one holding the connection and the armed one
    for ((i = 0; i < 40; i++)); do
        _note_children
        if [ "$(wc -w <<<"$SERVER_CHILDREN")" -ge 2 ]; then
            seen=1
            break
        fi
        sleep 0.05
    done
    [ "$seen" -eq 1 ] || { echo "children: [$SERVER_CHILDREN]"; return 1; }
    kill -TERM "$SERVER_PID"
    _wait_exit 200
    [ "$SERVER_RC" -eq 0 ] || { echo "status $SERVER_RC"; cat "$TEST_SCRATCH/server.err"; return 1; }
    for pid in $SERVER_CHILDREN; do
        ! kill -0 "$pid" 2>/dev/null || { echo "nc $pid survived the server"; return 1; }
    done
    wait "$client" || true
}

@test "serve: no private temp directory is a clear error with exit 2 and starts nothing [LB-18]" {
    local port
    port="$(_serve_port)"
    SERVER_ENV=(TMPDIR="$TEST_SCRATCH/does-not-exist")
    _start_server --serve "$port"
    _wait_exit 100
    [ "$SERVER_RC" -eq 2 ] || { echo "status $SERVER_RC"; cat "$TEST_SCRATCH/server.err"; return 1; }
    grep -q 'cannot create a temporary directory' "$TEST_SCRATCH/server.err"
    [ -z "$(_listen_addrs "$port")" ]
}

@test "serve: only the nc it started is stopped; processes whose command line merely looks like one survive [LB-18]" {
    local port decoy2
    port="$(_serve_port)"
    _stub_curl "$TEST_SCRATCH/bin"
    # what the old pkill -f "nc.*-l.*PORT" would have killed, and did not listen on anything
    bash -c "exec -a 'nc -l -p $port' sleep 120" 3>&- &
    DECOY_PID=$!
    bash -c "exec -a 'ncat -k -l 1$port' sleep 120" 3>&- &
    decoy2=$!
    DECOY_PID="$DECOY_PID $decoy2"
    sleep 0.2
    grep -qa "nc.*-l.*${port}" "/proc/${DECOY_PID%% *}/cmdline"
    _start_server --serve "$port"
    _wait_listening || { cat "$TEST_SCRATCH/server.err"; return 1; }
    _probe "$port" 'GET /metrics HTTP/1.1\r\n\r\n'
    [ "$(_probe_field status)" = "200" ]
    _stop_server_term_ok
    kill -0 "${DECOY_PID%% *}" || { echo "decoy 1 was killed"; return 1; }
    kill -0 "$decoy2" || { echo "decoy 2 was killed"; return 1; }
}

@test "serve: a port that something else already listens on fails at once with a clear message, exit 2, no netcat started, no metrics generated [LB-18]" {
    local port launcher holder
    port="$(_serve_port)"
    _stub_curl "$TEST_SCRATCH/bin"
    launcher="$(_make_launcher spy 'SERVE_RETRY_MS=20; generate_all_metrics() { echo x >>"$TEST_SCRATCH/generated"; }')"
    LAUNCHER="$launcher"
    # an nc that logs every listen it is asked to start, then does it
    local real_nc
    real_nc="$(command -v nc)"
    cat >"$TEST_SCRATCH/bin/nc" <<EOF
#!/bin/bash
if [[ "\$1" == "-h" ]]; then exec "$real_nc" -h; fi
echo "\$*" >>"$TEST_SCRATCH/nc.calls"
exec "$real_nc" "\$@"
EOF
    chmod +x "$TEST_SCRATCH/bin/nc"

    # (1) a plain listener, as any other service would have (no SO_REUSEPORT)
    python3 -I "$PROJECT_ROOT/tests/helpers/port_holder.py" "$port" 30 3>&- &
    holder=$!
    DECOY_PID="$holder"
    sleep 0.5
    [ -n "$(_listen_addrs "$port")" ]
    _start_server --serve "$port"
    _wait_exit 200
    [ "$SERVER_RC" -eq 2 ] || { echo "status $SERVER_RC"; cat "$TEST_SCRATCH/server.err"; return 1; }
    grep -q "ERROR: cannot listen on 127.0.0.1:${port}: something is already listening" "$TEST_SCRATCH/server.err"
    kill "$holder" 2>/dev/null || true
    wait "$holder" 2>/dev/null || true
    DECOY_PID=""
    [ ! -e "$TEST_SCRATCH/nc.calls" ] || { echo "nc was started:"; cat "$TEST_SCRATCH/nc.calls"; return 1; }
    [ ! -e "$TEST_SCRATCH/generated" ]

    # (2) another netcat on the same address: it sets SO_REUSEPORT, so a second one
    # would bind NEXT to it without an error and split its connections
    sleep 0.3
    "$real_nc" -l 127.0.0.1 "$port" </dev/null >/dev/null 2>&1 3>&- &
    holder=$!
    DECOY_PID="$holder"
    sleep 0.5
    [ -n "$(_listen_addrs "$port")" ]
    _start_server --serve "$port"
    _wait_exit 200
    [ "$SERVER_RC" -eq 2 ] || { echo "status $SERVER_RC"; cat "$TEST_SCRATCH/server.err"; return 1; }
    grep -q "something is already listening on 127.0.0.1:${port}" "$TEST_SCRATCH/server.err"
    [ ! -e "$TEST_SCRATCH/nc.calls" ]
    [ ! -e "$TEST_SCRATCH/generated" ]
}

@test "serve: a netcat that keeps failing to bind is retried a bounded number of times with back-off, then exit 2, never a busy loop [LB-18]" {
    local port launcher real_nc start end
    port="$(_serve_port)"
    real_nc="$(command -v nc)"
    mkdir -p "$TEST_SCRATCH/bin"
    cat >"$TEST_SCRATCH/bin/nc" <<EOF
#!/bin/bash
if [[ "\$1" == "-h" ]]; then exec "$real_nc" -h; fi
echo "\$*" >>"$TEST_SCRATCH/nc.calls"
echo "nc: Address already in use" >&2
exit 1
EOF
    chmod +x "$TEST_SCRATCH/bin/nc"
    launcher="$(_make_launcher failbind 'SERVE_RETRY_MS=40; generate_all_metrics() { echo x >>"$TEST_SCRATCH/generated"; }')"
    LAUNCHER="$launcher"
    start="$(date +%s.%N)"
    _start_server --serve "$port"
    _wait_exit 400
    end="$(date +%s.%N)"
    [ "$SERVER_RC" -eq 2 ] || { echo "status $SERVER_RC"; cat "$TEST_SCRATCH/server.err"; return 1; }
    # exactly SERVE_START_ATTEMPTS (5) listen attempts, no more
    [ "$(wc -l <"$TEST_SCRATCH/nc.calls")" -eq 5 ] || { cat "$TEST_SCRATCH/nc.calls"; return 1; }
    [ ! -e "$TEST_SCRATCH/generated" ]
    grep -q "ERROR: cannot listen on 127.0.0.1:${port}: nc: Address already in use" "$TEST_SCRATCH/server.err"
    # the back-off was applied (40+80+160+320 ms), and it ended
    awk -v s="$start" -v e="$end" 'BEGIN { exit !((e - s) >= 0.55 && (e - s) < 8) }' || { echo "took $(echo "$end - $start" | bc) s"; return 1; }
}

@test "serve: no usable netcat is a clear error with exit 2 [LB-18]" {
    local port
    port="$(_serve_port)"
    # a node without any netcat
    _toolbox_without "$TEST_SCRATCH/nonc" nc ncat netcat
    SERVER_PATH="$TEST_SCRATCH/nonc"
    _start_server --serve "$port"
    _wait_exit 100
    [ "$SERVER_RC" -eq 2 ]
    grep -q 'a netcat (nc) is required' "$TEST_SCRATCH/server.err"
    # a netcat that is none of the four known kinds
    mkdir -p "$TEST_SCRATCH/mystery"
    ln -sf "$TEST_SCRATCH/nonc"/* "$TEST_SCRATCH/mystery/" 2>/dev/null || true
    printf '#!/bin/bash\necho "mystery netcat 0.1"\n' >"$TEST_SCRATCH/mystery/nc"
    chmod +x "$TEST_SCRATCH/mystery/nc"
    SERVER_PATH="$TEST_SCRATCH/mystery"
    _start_server --serve "$port"
    _wait_exit 100
    [ "$SERVER_RC" -eq 2 ]
    grep -q 'not a netcat variant this server knows how to drive' "$TEST_SCRATCH/server.err"
    grep -q 'a netcat (nc) is required' "$TEST_SCRATCH/server.err"
}

# A stand-in for another netcat variant: it answers -h with that variant's help
# text, records the listen command line it is given, and serves the connection
# with this machine's OpenBSD nc. Usage: _install_nc_shim DIR HELPFILE
_install_nc_shim() {
    local dir="$1" helpfile="$2" real_nc
    real_nc="$(command -v nc)"
    mkdir -p "$dir"
    cat >"$dir/nc" <<EOF
#!/bin/bash
if [[ "\$1" == "-h" ]]; then cat "$helpfile"; exit 1; fi
echo "\$*" >>"$TEST_SCRATCH/nc.calls"
bind="" port="" pos=()
args=("\$@")
i=0
while ((i < \${#args[@]})); do
    case "\${args[i]}" in
        -l | -N) ;;
        -q | -p | -s) val="\${args[i + 1]}"; i=\$((i + 1))
            [[ "\${args[i - 1]}" == "-p" ]] && port="\$val"
            [[ "\${args[i - 1]}" == "-s" ]] && bind="\$val" ;;
        *) pos+=("\${args[i]}") ;;
    esac
    i=\$((i + 1))
done
if ((\${#pos[@]} == 2)); then bind="\${pos[0]}"; port="\${pos[1]}"; fi
exec "$real_nc" -l -q 0 "\${bind:-0.0.0.0}" "\$port"
EOF
    chmod +x "$dir/nc"
}

@test "serve: each netcat variant is recognised by its help text and given its own command line [LB-18]" {
    local port name help want extra
    port="$(_serve_port)"
    _stub_curl "$TEST_SCRATCH/bin"
    local -a table=(
        "openbsd|OpenBSD netcat (Debian patchlevel 1.226-1ubuntu2)\nusage: nc [-46CDdFhklNnrStUuvZz] [-I length]\n\t  [-q seconds] [-s sourceaddr]|-l -q 0 127.0.0.1 ${port}|"
        "bsd|usage: nc [-46CDdFhklNnrStUuvZz] [-I length] [-i interval]|-l -N 127.0.0.1 ${port}|"
        "ncat|Ncat 7.94 ( https://nmap.org/ncat )|-l 127.0.0.1 ${port}|"
        "traditional|[v1.10-47]\nconnect to somewhere:\tnc [-options] hostname port[s] [ports] ...\n\t-q secs\t\tquit after EOF on stdin and delay of secs\n\t-s addr\t\tlocal source address|-l -p ${port} -s 127.0.0.1 -q 0|"
        "gnu|GNU netcat 0.7.1, a rewrite of the famous networking tool.\nBasic usages:\nconnect to somewhere:  netcat [options] hostname port [port] ...|-l -p ${port} -s 127.0.0.1|"
        "busybox|BusyBox v1.36.1 multi-call binary.\n\nUsage: nc [OPTIONS] HOST PORT\n\t-l\tListen mode\n\t-p PORT\tLocal port\n\t-s ADDR\tLocal address|-l -p ${port} -s 127.0.0.1|"
        "busybox-nos|BusyBox v1.36.1 multi-call binary.\n\nUsage: nc [OPTIONS] HOST PORT\n\t-l\tListen mode\n\t-p PORT\tLocal port|-l -p ${port}|--bind 0.0.0.0"
    )
    local entry
    for entry in "${table[@]}"; do
        IFS='|' read -r name help want extra <<<"$entry"
        rm -f "$TEST_SCRATCH/nc.calls"
        printf '%b\n' "$help" >"$TEST_SCRATCH/help.txt"
        _install_nc_shim "$TEST_SCRATCH/shim.$name" "$TEST_SCRATCH/help.txt"
        SERVER_PATH="$TEST_SCRATCH/shim.$name:$TEST_SCRATCH/bin:$PATH"
        # shellcheck disable=SC2086
        _start_server --serve "$port" $extra
        _wait_listening || { echo "$name: did not start"; cat "$TEST_SCRATCH/server.err"; return 1; }
        _probe "$port" 'GET /metrics HTTP/1.1\r\n\r\n'
        [ "$(_probe_field status)" = "200" ] || { echo "$name: $(cat "$TEST_SCRATCH/probe")"; return 1; }
        grep -q "netcat: $(case "$name" in bsd) echo openbsd ;; gnu | traditional) echo traditional ;; busybox*) echo busybox ;; *) echo "$name" ;; esac);" "$TEST_SCRATCH/server.err"
        [ "$(head -1 "$TEST_SCRATCH/nc.calls")" = "$want" ] || { echo "$name: nc was run as '$(head -1 "$TEST_SCRATCH/nc.calls")', want '$want'"; return 1; }
        _stop_server_term_ok
    done
}

@test "serve: a BusyBox nc without -s cannot honour a loopback bind and says so instead of binding every interface [LB-18]" {
    local port
    port="$(_serve_port)"
    printf 'BusyBox v1.36.1 multi-call binary.\n\nUsage: nc [OPTIONS] HOST PORT\n\t-l\tListen mode\n\t-p PORT\tLocal port\n' >"$TEST_SCRATCH/help.txt"
    _install_nc_shim "$TEST_SCRATCH/shim.bb" "$TEST_SCRATCH/help.txt"
    SERVER_PATH="$TEST_SCRATCH/shim.bb:$PATH"
    _start_server --serve "$port"
    _wait_exit 100
    [ "$SERVER_RC" -eq 2 ]
    grep -q 'cannot bind to a given address' "$TEST_SCRATCH/server.err"
    [ ! -e "$TEST_SCRATCH/nc.calls" ]
}
