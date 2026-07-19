#!/usr/bin/env bats
# Hardware-free END-TO-END integration tests.
#
# These drive REAL cross-component flows with PATH-shim fakes (a stub MediaMTX
# HTTP API via a fake `curl`, a mock webhook endpoint, fake `df`) -- no USB
# hardware, no running MediaMTX, no network. They complement the per-file unit
# regression tests by exercising whole flows the way the field does.

setup() {
    TEST_DIR="$( cd "$( dirname "$BATS_TEST_FILENAME" )" && pwd )"
    PROJECT_ROOT="$( cd "$TEST_DIR/.." && pwd )"
    E2E_TMP="$(mktemp -d)"
}

teardown() {
    rm -rf "$E2E_TMP" 2>/dev/null || true
}

# ---------------------------------------------------------------------------
# Metrics <-> stub MediaMTX API
# ---------------------------------------------------------------------------

# A fake `curl` that answers the MediaMTX control-API endpoints the exporter
# queries. The exporter passes the URL as the LAST argument.
_write_stub_mediamtx_curl() {
    local bin="$1"
    cat > "$bin/curl" <<'CURLEOF'
#!/bin/bash
url="${!#}"    # last positional arg is the URL
case "$url" in
    */v3/info)             echo '{"version":"1.19.2","upTime":123456}' ;;
    */v3/paths/list)       echo '{"itemCount":2,"items":[{"name":"mic1","ready":true},{"name":"mic2","ready":true}]}' ;;
    */v3/rtspsessions/list) echo '{"itemCount":1,"items":[{"id":"sess-1"}]}' ;;
    */v3/paths/get/*)      echo '{"name":"mic1","ready":true}' ;;
    *)                     echo '{"itemCount":0,"items":[]}' ;;
esac
exit 0
CURLEOF
    chmod +x "$bin/curl"
}

@test "E2E: metrics produces a VALID Prometheus scrape against a stub MediaMTX API" {
    mkdir -p "$E2E_TMP/bin"
    _write_stub_mediamtx_curl "$E2E_TMP/bin"

    run env PROJECT_ROOT="$PROJECT_ROOT" PATH="$E2E_TMP/bin:$PATH" \
        FFMPEG_PID_DIR="$(mktemp -d)" PID_FILE="$(mktemp)" HEARTBEAT_FILE="$(mktemp)" \
        bash -c 'set -euo pipefail; source "$PROJECT_ROOT/lyrebird-metrics.sh"; generate_all_metrics'
    [ "$status" -eq 0 ]

    local scrape="$E2E_TMP/scrape.prom"
    printf '%s\n' "$output" > "$scrape"

    # The stub API is reachable, and its 2 ready paths are counted.
    grep -qx 'lyrebird_api_up 1' "$scrape"
    grep -qx 'lyrebird_api_paths_total 2' "$scrape"
    grep -qx 'lyrebird_api_paths_ready 2' "$scrape"

    # Prometheus format validity: exactly one # HELP and one # TYPE per family
    # (the C6 regression class -- a duplicate rejects the whole scrape).
    run bash -c "awk '/^# HELP /{h[\$3]++} /^# TYPE /{t[\$3]++} END{for(n in h) if(h[n]>1) print \"DUPHELP \"n; for(n in t) if(t[n]>1) print \"DUPTYPE \"n}' '$scrape'"
    [ -z "$output" ]

    # No bare value-only line (the "0\n0" / empty-value class that breaks a scrape):
    # every non-comment line must have a metric NAME before the value.
    run grep -nxE '[[:space:]]*[-0-9.]+' "$scrape"
    [ "$status" -ne 0 ]
}

# ---------------------------------------------------------------------------
# Alerts -> mock webhook endpoint
# ---------------------------------------------------------------------------

@test "E2E: an alert is delivered to a mock webhook with a valid JSON body" {
    mkdir -p "$E2E_TMP/bin"
    # Fake curl for send_webhook: it uses `-w '%{http_code}' -o /dev/null ... URL`
    # and reads stdout as the HTTP code. Record the -d payload and the URL, and
    # return 200 so delivery is considered successful.
    cat > "$E2E_TMP/bin/curl" <<EOF
#!/bin/bash
prev=""
for a in "\$@"; do
    [[ "\$prev" == "-d" || "\$prev" == "--data-raw" ]] && echo "\$a" > "$E2E_TMP/payload.json"
    case "\$a" in http*://*) echo "\$a" > "$E2E_TMP/url.txt" ;; esac
    prev="\$a"
done
echo "200"
EOF
    chmod +x "$E2E_TMP/bin/curl"

    run env PROJECT_ROOT="$PROJECT_ROOT" PATH="$E2E_TMP/bin:$PATH" \
        LYREBIRD_ALERT_ENABLED=true \
        LYREBIRD_WEBHOOK_URL="http://webhook.example/hook" \
        LYREBIRD_WEBHOOK_TYPE=generic \
        LYREBIRD_ALERT_STATE_DIR="$(mktemp -d)" \
        bash -c 'set +euo pipefail; source "$PROJECT_ROOT/lyrebird-alerts.sh"; send_alert "critical" "Stream Down: mic1" "no data from mic1" "stream_down"'
    [ "$status" -eq 0 ]

    # The webhook was actually called...
    [ -f "$E2E_TMP/url.txt" ]
    grep -q 'webhook.example/hook' "$E2E_TMP/url.txt"
    # ...with a syntactically valid JSON body.
    [ -f "$E2E_TMP/payload.json" ]
    python3 -c 'import json,sys; json.load(open(sys.argv[1])); print("valid json")' "$E2E_TMP/payload.json"
}

# ---------------------------------------------------------------------------
# mic-check config  ->  stream-manager consumption (the C4 contract)
# ---------------------------------------------------------------------------

@test "E2E: mic-check and stream-manager agree on the per-device config KEY [C4 contract]" {
    local dev="Blue Yeti"
    local mickey smkey
    mickey=$(env PROJECT_ROOT="$PROJECT_ROOT" bash -c 'source "$PROJECT_ROOT/lyrebird-mic-check.sh" >/dev/null 2>&1; set +e; s=$(sanitize_device_name "'"$dev"'"); printf "DEVICE_%s_SAMPLE_RATE" "${s^^}"')
    smkey=$(env PROJECT_ROOT="$PROJECT_ROOT" bash -c 'source "$PROJECT_ROOT/lyrebird-stream-manager.sh" >/dev/null 2>&1; set +e; s=$(sanitize_device_name "'"$dev"'"); printf "DEVICE_%s_SAMPLE_RATE" "${s^^}"')
    [ -n "$mickey" ]
    [ "$mickey" = "$smkey" ]     # a mismatch here is exactly the C4 defect
}

@test "E2E: a per-device config (mic-check key format) is honored by stream-manager, not defaulted [C4]" {
    local dev="Blue Yeti"
    local key
    key=$(env PROJECT_ROOT="$PROJECT_ROOT" bash -c 'source "$PROJECT_ROOT/lyrebird-mic-check.sh" >/dev/null 2>&1; set +e; s=$(sanitize_device_name "'"$dev"'"); printf "DEVICE_%s_SAMPLE_RATE" "${s^^}"')
    local cfg="$E2E_TMP/audio-devices.conf"
    printf '%s=96000\n' "$key" > "$cfg"

    run env PROJECT_ROOT="$PROJECT_ROOT" CFG="$cfg" bash -c '
        source "$PROJECT_ROOT/lyrebird-stream-manager.sh" >/dev/null 2>&1
        set +e
        source "$CFG"
        get_device_config "Blue Yeti" "SAMPLE_RATE" "48000"
    '
    [ "$status" -eq 0 ]
    [ "$output" = "96000" ]      # the mic's 96kHz honored; pre-C4-fix it read the 48000 default
}

# ---------------------------------------------------------------------------
# Storage disk-full  ->  monitor acts (dry-run, no real deletion)
# ---------------------------------------------------------------------------

@test "E2E: storage monitor detects a full disk and engages emergency cleanup (dry-run)" {
    mkdir -p "$E2E_TMP/bin"
    cat > "$E2E_TMP/bin/df" <<'DFEOF'
#!/bin/bash
posix=0; for a in "$@"; do [[ "$a" == -*P* ]] && posix=1; done
echo "Filesystem 1024-blocks Used Available Capacity Mounted on"
if [[ $posix -eq 1 ]]; then
  echo "/dev/mapper/vg--data 1000000 990000 10000 99% /"
else
  echo "/dev/mapper/vg--data"
  echo "                     1000000 990000 10000 99% /"
fi
DFEOF
    chmod +x "$E2E_TMP/bin/df"
    local rec="$E2E_TMP/rec"; mkdir -p "$rec"; : > "$rec/keep.wav"

    run env PROJECT_ROOT="$PROJECT_ROOT" PATH="$E2E_TMP/bin:$PATH" \
        LYREBIRD_RECORDING_DIR="$rec" LYREBIRD_LOG_DIR="$(mktemp -d)" \
        LYREBIRD_BUFFER_DIR="$(mktemp -d)" DRY_RUN=true \
        bash -c 'set -euo pipefail; source "$PROJECT_ROOT/lyrebird-storage.sh"; cmd_monitor 2>&1'
    [ "$status" -eq 0 ]
    [[ "$output" =~ EMERGENCY ]]        # a genuinely full disk is acted on...
    [ -f "$rec/keep.wav" ]              # ...but DRY_RUN deletes nothing
}
