#!/usr/bin/env bats
# Retention vs broken-clock tests (long-horizon / time domain).
#
# Field scenario: an RTC-less Pi records for hours with its clock still in
# 1970, then NTP steps the clock to the real date. The next retention run's
# `find -mtime +30` sees those minutes-old recordings as ~56 years old and
# deletes fresh data -- a silent mass-loss incident. Age-based cleanup must
# treat any mtime before CLOCK_SANE_EPOCH as "real age unknown: keep", and an
# unsynced current clock as "ages are meaningless: skip". Emergency size-based
# cleanup is deliberately exempt (a full disk must still be freed).

setup() {
    TEST_DIR="$( cd "$( dirname "$BATS_TEST_FILENAME" )" && pwd )"
    PROJECT_ROOT="$( cd "$TEST_DIR/.." && pwd )"
    CS_TMP="$(mktemp -d)"
    mkdir -p "$CS_TMP/rec" "$CS_TMP/bin"
}

teardown() {
    rm -rf "$CS_TMP" 2>/dev/null || true
    [[ -n "${CS_BUF:-}" ]] && rm -rf "$CS_BUF" 2>/dev/null || true
}

_run_cleanup() {
    env PROJECT_ROOT="$PROJECT_ROOT" \
        LYREBIRD_RECORDING_DIR="$CS_TMP/rec" \
        LYREBIRD_LOG_DIR="$CS_TMP/logs" \
        DRY_RUN=false \
        "$@" \
        bash -c 'set -euo pipefail; source "$PROJECT_ROOT/lyrebird-storage.sh"; cleanup_recordings 2>&1'
}

@test "recordings with broken-clock (1970) mtimes are KEPT by age-based cleanup" {
    # Written while the clock was unsynced: mtime says 1970, real age is minutes.
    touch -d @1000000 "$CS_TMP/rec/fresh-but-1970.wav"
    # A control file with a sane, genuinely expired mtime.
    touch -d "45 days ago" "$CS_TMP/rec/genuinely-old.wav"

    run _run_cleanup
    [ "$status" -eq 0 ]
    [ -f "$CS_TMP/rec/fresh-but-1970.wav" ]        # broken-clock file survives
    [ ! -f "$CS_TMP/rec/genuinely-old.wav" ]       # real retention still works
    [[ "$output" == *"pre-"*"mtimes"* ]]           # and it says so
}

@test "age-based cleanup is skipped entirely while the system clock is unsynced" {
    touch -d "45 days ago" "$CS_TMP/rec/old.wav"
    # date shim: the system "clock" reads 1000 (long before CLOCK_SANE_EPOCH).
    cat > "$CS_TMP/bin/date" <<'EOF'
#!/bin/bash
if [[ "${1:-}" == "+%s" ]]; then echo 1000; else exec /bin/date "$@"; fi
EOF
    chmod +x "$CS_TMP/bin/date"

    run _run_cleanup PATH="$CS_TMP/bin:$PATH"
    [ "$status" -eq 0 ]
    [ -f "$CS_TMP/rec/old.wav" ]                   # nothing deleted blind
    [[ "$output" == *"skipping age-based"* ]]
}

@test "emergency cleanup still deletes broken-clock recordings when the disk is full" {
    touch -d @1000000 "$CS_TMP/rec/fresh-but-1970.wav"
    CS_BUF="$(mktemp -d /tmp/lyrebird-cs-buffer.XXXXXX)"

    run env PROJECT_ROOT="$PROJECT_ROOT" \
        LYREBIRD_RECORDING_DIR="$CS_TMP/rec" \
        LYREBIRD_LOG_DIR="$CS_TMP/logs" \
        LYREBIRD_BUFFER_DIR="$CS_BUF" \
        DRY_RUN=false \
        bash -c 'set -euo pipefail; source "$PROJECT_ROOT/lyrebird-storage.sh"; emergency_cleanup 2>&1'
    [ "$status" -eq 0 ]
    [ ! -f "$CS_TMP/rec/fresh-but-1970.wav" ]      # emergency is size-driven, not gated
}

@test "retention keeps files younger than the retention window (control)" {
    touch "$CS_TMP/rec/today.wav"
    touch -d "5 days ago" "$CS_TMP/rec/recent.wav"

    run _run_cleanup
    [ "$status" -eq 0 ]
    [ -f "$CS_TMP/rec/today.wav" ]
    [ -f "$CS_TMP/rec/recent.wav" ]
}
