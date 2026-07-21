#!/usr/bin/env bats
# Regression tests for the errexit/pipefail silent-abort class (N2 sweep).
#
# Pattern: var=$(cmd | grep PAT | tail/cut/awk/head ...) under set -euo pipefail.
# When grep matches nothing the PIPELINE fails (pipefail), the assignment fails,
# and errexit kills the whole script mid-run -- even though the very next lines
# handle the empty-variable case. Every test here drives a REAL function into
# its documented fallback path; before the guards, each one aborted instead.

setup() {
    TEST_DIR="$( cd "$( dirname "$BATS_TEST_FILENAME" )" && pwd )"
    PROJECT_ROOT="$( cd "$TEST_DIR/.." && pwd )"
    PA_TMP="$(mktemp -d)"
    mkdir -p "$PA_TMP/bin"
}

teardown() {
    rm -rf "$PA_TMP" 2>/dev/null || true
}

@test "diagnostics: NTP offset probe survives an UNSYNCED ntpd (the normal pre-sync field state)" {
    # ntpq -p output with peers but no '*'/'o' selected peer => grep matches 0 lines.
    cat > "$PA_TMP/bin/ntpq" <<'EOF'
#!/bin/bash
echo "     remote           refid      st t when poll reach   delay   offset  jitter"
echo "=============================================================================="
echo " 0.debian.pool.n .POOL.          16 p    -   64    0    0.000   +0.000   0.000"
exit 0
EOF
    chmod +x "$PA_TMP/bin/ntpq"

    run env PROJECT_ROOT="$PROJECT_ROOT" PATH="$PA_TMP/bin:$PATH" bash -c '
        set -euo pipefail
        source "$PROJECT_ROOT/lyrebird-diagnostics.sh" >/dev/null 2>&1
        get_ntp_offset_ms
    '
    [ "$status" -eq 0 ]
    [[ "$output" == *"unknown"* ]]
}

@test "diagnostics: NTP offset probe survives chronyd not running" {
    rm -f "$PA_TMP/bin/ntpq"
    cat > "$PA_TMP/bin/chronyc" <<'EOF'
#!/bin/bash
echo "506 Cannot talk to daemon" >&2
exit 1
EOF
    chmod +x "$PA_TMP/bin/chronyc"

    run env PROJECT_ROOT="$PROJECT_ROOT" PATH="$PA_TMP/bin:$PATH" bash -c '
        set -euo pipefail
        source "$PROJECT_ROOT/lyrebird-diagnostics.sh" >/dev/null 2>&1
        command -v ntpq >/dev/null 2>&1 && exit 99   # test needs chronyc branch
        get_ntp_offset_ms
    '
    if [ "$status" -eq 99 ]; then
        skip "real ntpq present on this host; chronyc branch unreachable"
    fi
    [ "$status" -eq 0 ]
    [[ "$output" == *"unknown"* ]]
}

@test "diagnostics: get_script_version on a script with NO version marker returns 'unknown'" {
    printf '#!/bin/bash\necho hi\n' > "$PA_TMP/noversion.sh"
    run env PROJECT_ROOT="$PROJECT_ROOT" bash -c '
        set -euo pipefail
        source "$PROJECT_ROOT/lyrebird-diagnostics.sh" >/dev/null 2>&1
        get_script_version "'"$PA_TMP"'/noversion.sh"
    '
    [ "$status" -eq 0 ]
    [ "$output" = "unknown" ]
}

@test "stream-manager: check_audio_level survives ffmpeg exiting 0 with NO volumedetect output" {
    # An ffmpeg that succeeds but prints nothing parseable (e.g. muted loglevel,
    # driver quirk). Must return 2 (check failed), never abort the monitor run.
    printf '#!/bin/bash\nexit 0\n' > "$PA_TMP/bin/ffmpeg"
    chmod +x "$PA_TMP/bin/ffmpeg"

    run env PROJECT_ROOT="$PROJECT_ROOT" PATH="$PA_TMP/bin:$PATH" \
        AUDIO_LEVEL_CHECK_ENABLED=true bash -c '
        set -euo pipefail
        source "$PROJECT_ROOT/lyrebird-stream-manager.sh" >/dev/null 2>&1
        log() { :; }
        rc=0
        check_audio_level 0 pipefailtest || rc=$?
        echo "rc=$rc"
    '
    [ "$status" -eq 0 ]
    [[ "$output" == *"rc=2"* ]]
}

@test "stream-manager: get_status_summary survives an /v3/info body without a version field" {
    cat > "$PA_TMP/bin/curl" <<'EOF'
#!/bin/bash
url="${!#}"
with_code=0
for a in "$@"; do case "$a" in *%{http_code}*) with_code=1 ;; esac; done
case "$url" in
    */info*) body='{"upTime":1}' ;;
    *)       body='{"itemCount":0,"items":[]}' ;;
esac
if [[ $with_code -eq 1 ]]; then printf '%s\n200' "$body"; else printf '%s' "$body"; fi
exit 0
EOF
    chmod +x "$PA_TMP/bin/curl"

    run env PROJECT_ROOT="$PROJECT_ROOT" PATH="$PA_TMP/bin:$PATH" MEDIAMTX_API_VERSION=v3 bash -c '
        set -euo pipefail
        source "$PROJECT_ROOT/lyrebird-stream-manager.sh" >/dev/null 2>&1
        mediamtx_get_status_summary
    '
    [ "$status" -eq 0 ]
    [[ "$output" == *"unknown"* ]]
}

@test "metrics: collect_mediamtx_metrics survives MediaMTX dying between the two pgrep calls" {
    # Stateful pgrep: first call (the running check) succeeds, second call (the
    # PID fetch) finds nothing -- the process died in between. The scrape must
    # still complete (a mid-scrape abort leaves a stale .prom: dead recorder
    # looks alive).
    : > "$PA_TMP/pgrep.calls"
    cat > "$PA_TMP/bin/pgrep" <<EOF
#!/bin/bash
echo x >> "$PA_TMP/pgrep.calls"
n=\$(wc -l < "$PA_TMP/pgrep.calls")
if [[ \$n -le 1 ]]; then echo 12345; exit 0; else exit 1; fi
EOF
    chmod +x "$PA_TMP/bin/pgrep"

    run env PROJECT_ROOT="$PROJECT_ROOT" PATH="$PA_TMP/bin:$PATH" bash -c '
        set -euo pipefail
        source "$PROJECT_ROOT/lyrebird-metrics.sh"
        collect_mediamtx_metrics
        echo "SCRAPE-COMPLETE"
    '
    [ "$status" -eq 0 ]
    [[ "$output" == *"SCRAPE-COMPLETE"* ]]
}

@test "orchestrator: stream count survives ffmpeg dying between the two pgrep calls (BusyBox fallback path)" {
    # pgrep whose --help does NOT advertise -c (BusyBox-style) so the fallback
    # `pgrep -x ffmpeg | head | wc -l` path runs; the gate call sees ffmpeg,
    # the count call does not.
    : > "$PA_TMP/pgrep.calls"
    cat > "$PA_TMP/bin/pgrep" <<EOF
#!/bin/bash
if [[ "\$*" == *--help* ]]; then echo "usage: pgrep [-flnovx] PATTERN"; exit 0; fi
if [[ "\$*" == *mediamtx* ]]; then exit 1; fi
echo x >> "$PA_TMP/pgrep.calls"
n=\$(wc -l < "$PA_TMP/pgrep.calls")
if [[ \$n -le 1 ]]; then echo 12345; exit 0; else exit 1; fi
EOF
    chmod +x "$PA_TMP/bin/pgrep"

    run env PROJECT_ROOT="$PROJECT_ROOT" PATH="$PA_TMP/bin:$PATH" bash -c '
        set -euo pipefail
        source "$PROJECT_ROOT/lyrebird-orchestrator.sh" >/dev/null 2>&1
        log() { :; }
        refresh_system_state
        echo "STATE-REFRESHED streams=$ACTIVE_STREAMS"
    '
    [ "$status" -eq 0 ]
    [[ "$output" == *"STATE-REFRESHED streams=0"* ]]
}

@test "usb-mapper: get_usb_physical_port survives a DEVPATH with no usb port pattern" {
    # udevadm answers with a platform-bus DEVPATH (no N-N.N segment): the
    # extraction grep matches nothing and must fall through, not abort.
    cat > "$PA_TMP/bin/udevadm" <<'EOF'
#!/bin/bash
echo "DEVPATH=/devices/platform/soc/fe00b840.mailbox/sound"
exit 0
EOF
    chmod +x "$PA_TMP/bin/udevadm"

    # The function only consults udevadm when /dev/bus/usb/<bus>/<dev> exists.
    # Creating that node needs root: do it directly when we are root, via
    # non-interactive sudo on CI runners, and skip (with the reason) elsewhere
    # rather than fail on an environment limitation.
    if mkdir -p /dev/bus/usb/990 2>/dev/null; then
        : > /dev/bus/usb/990/991
        PA_DEV_SUDO=""
    elif command -v sudo >/dev/null 2>&1 && sudo -n true 2>/dev/null; then
        sudo -n mkdir -p /dev/bus/usb/990
        sudo -n touch /dev/bus/usb/990/991
        PA_DEV_SUDO="sudo -n"
    else
        skip "cannot create /dev/bus/usb test node (needs root or passwordless sudo)"
    fi

    run env PROJECT_ROOT="$PROJECT_ROOT" PATH="$PA_TMP/bin:$PATH" bash -c '
        set -euo pipefail
        source "$PROJECT_ROOT/usb-audio-mapper.sh" >/dev/null 2>&1
        rc=0
        get_usb_physical_port 990 991 || rc=$?
        echo "COMPLETED rc=$rc"
    '
    ${PA_DEV_SUDO} rm -rf /dev/bus/usb/990
    [ "$status" -eq 0 ]
    [[ "$output" == *"COMPLETED"* ]]
}

@test "installer: verify_checksum reports a MISSING checksum entry instead of aborting" {
    echo "binary-data" > "$PA_TMP/mediamtx.tar.gz"
    echo "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef  other_file.tar.gz" \
        > "$PA_TMP/checksums.sha256"

    run env PROJECT_ROOT="$PROJECT_ROOT" PA_TMP="$PA_TMP" bash -c '
        set -euo pipefail
        source "$PROJECT_ROOT/install_mediamtx.sh" >/dev/null 2>&1
        rc=0
        verify_checksum "$PA_TMP/mediamtx.tar.gz" "$PA_TMP/checksums.sha256" "mediamtx.tar.gz" || rc=$?
        echo "HANDLED rc=$rc"
    '
    [ "$status" -eq 0 ]
    [[ "$output" == *"HANDLED rc=1"* ]]
}

@test "installer: show_status prints 'unknown' for a version-less mediamtx binary" {
    mkdir -p "$PA_TMP/prefix/bin"
    printf '#!/bin/bash\necho "development build"\nexit 0\n' > "$PA_TMP/prefix/bin/mediamtx"
    chmod +x "$PA_TMP/prefix/bin/mediamtx"

    run env PROJECT_ROOT="$PROJECT_ROOT" MEDIAMTX_PREFIX="$PA_TMP/prefix" bash -c '
        set -euo pipefail
        source "$PROJECT_ROOT/install_mediamtx.sh" >/dev/null 2>&1
        show_status || true
    '
    [ "$status" -eq 0 ]
    [[ "$output" == *"Version: unknown"* ]]
}

@test "updater: service-env merge survives a service file with NO Environment= lines" {
    cat > "$PA_TMP/test.service" <<'EOF'
[Unit]
Description=Test service

[Service]
WorkingDirectory=/opt/test
ExecStart=/bin/true

[Install]
WantedBy=multi-user.target
EOF
    printf '#!/bin/bash\nexit 0\n' > "$PA_TMP/fake-manager.sh"
    chmod +x "$PA_TMP/fake-manager.sh"

    run env PROJECT_ROOT="$PROJECT_ROOT" PA_TMP="$PA_TMP" bash -c '
        set -o errexit -o pipefail -o nounset
        source "$PROJECT_ROOT/lyrebird-updater.sh" >/dev/null 2>&1
        SERVICE_STATE[has_customizations]="true"
        SERVICE_STATE[service_file]="$PA_TMP/test.service"
        SERVICE_CUSTOM_ENV=("Environment=LYREBIRD_CUSTOM=yes")
        reinstall_service_with_customizations "$PA_TMP/fake-manager.sh"
        echo "MERGE-COMPLETE"
    '
    [ "$status" -eq 0 ]
    [[ "$output" == *"MERGE-COMPLETE"* ]]
    grep -q 'Environment=LYREBIRD_CUSTOM=yes' "$PA_TMP/test.service"
}
