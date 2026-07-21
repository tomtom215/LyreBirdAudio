#!/usr/bin/env bats
# Config-integrity tests: a non-numeric env override must never abort a run.
#
# Every numeric knob is env-overridable and consumed in bash arithmetic. A
# value like CRON_RESTART_MAX_PER_HOUR=unlimited reaches (( count < ... )),
# bash resolves "unlimited" as a variable name, and under set -u/-e the whole
# script dies with "unbound variable" -- silently killing every cron monitor
# pass on a node whose operator merely wrote an intuitive config value. The
# stream manager now coerces all numeric env knobs to sane defaults at load.

setup() {
    TEST_DIR="$( cd "$( dirname "$BATS_TEST_FILENAME" )" && pwd )"
    PROJECT_ROOT="$( cd "$TEST_DIR/.." && pwd )"
    NE_TMP="$(mktemp -d)"
}

teardown() {
    rm -rf "$NE_TMP" 2>/dev/null || true
}

@test "CRON_RESTART_MAX_PER_HOUR=unlimited does not abort the restart-budget decision" {
    run env PROJECT_ROOT="$PROJECT_ROOT" \
        CRON_RESTART_MAX_PER_HOUR="unlimited" \
        CRON_RESTART_STATE_DIR="$NE_TMP/cron" \
        bash -c '
            set -euo pipefail
            source "$PROJECT_ROOT/lyrebird-stream-manager.sh" >/dev/null 2>&1
            log() { :; }
            is_cron_context() { return 0; }   # force the cron budget path
            rc=0
            should_restart_stream mic1 || rc=$?
            echo "DECIDED rc=$rc budget=$CRON_RESTART_MAX_PER_HOUR"
        '
    [ "$status" -eq 0 ]
    [[ "$output" == *"DECIDED rc=0"* ]]      # falls back to the default (6), allows restart
    [[ "$output" == *"budget=6"* ]]
}

@test "DEEP_HEALTH_MAX_STRIKES=lots does not abort the deep health probe" {
    run env PROJECT_ROOT="$PROJECT_ROOT" \
        DEEP_HEALTH_MAX_STRIKES="lots" \
        DEEP_HEALTH_STATE_DIR="$NE_TMP/strikes" \
        bash -c '
            set -euo pipefail
            source "$PROJECT_ROOT/lyrebird-stream-manager.sh" >/dev/null 2>&1
            log() { :; }
            rc=0
            deep_health_note mic1 notready || rc=$?
            echo "NOTED rc=$rc strikes=$DEEP_HEALTH_MAX_STRIKES"
        '
    [ "$status" -eq 0 ]
    [[ "$output" == *"NOTED"* ]]
    [[ "$output" == *"strikes=3"* ]]         # coerced to the default
}

@test "MAX_RESTART_DELAY=5min falls back to the numeric default (wrapper backoff stays sane)" {
    run env PROJECT_ROOT="$PROJECT_ROOT" MAX_RESTART_DELAY="5min" bash -c '
        set -euo pipefail
        source "$PROJECT_ROOT/lyrebird-stream-manager.sh" >/dev/null 2>&1
        echo "delay=$MAX_RESTART_DELAY"
    '
    [ "$status" -eq 0 ]
    [ "$output" = "delay=300" ]
}

@test "AUDIO_SILENCE_THRESHOLD_DB keeps a valid negative override and rejects garbage" {
    run env PROJECT_ROOT="$PROJECT_ROOT" AUDIO_SILENCE_THRESHOLD_DB="-45" bash -c '
        set -euo pipefail
        source "$PROJECT_ROOT/lyrebird-stream-manager.sh" >/dev/null 2>&1
        echo "db=$AUDIO_SILENCE_THRESHOLD_DB"
    '
    [ "$status" -eq 0 ]
    [ "$output" = "db=-45" ]

    run env PROJECT_ROOT="$PROJECT_ROOT" AUDIO_SILENCE_THRESHOLD_DB="quiet" bash -c '
        set -euo pipefail
        source "$PROJECT_ROOT/lyrebird-stream-manager.sh" >/dev/null 2>&1
        echo "db=$AUDIO_SILENCE_THRESHOLD_DB"
    '
    [ "$status" -eq 0 ]
    [ "$output" = "db=-60" ]
}

@test "a valid numeric override is preserved, not clobbered by coercion" {
    run env PROJECT_ROOT="$PROJECT_ROOT" CRON_RESTART_MAX_PER_HOUR="12" bash -c '
        set -euo pipefail
        source "$PROJECT_ROOT/lyrebird-stream-manager.sh" >/dev/null 2>&1
        echo "budget=$CRON_RESTART_MAX_PER_HOUR"
    '
    [ "$status" -eq 0 ]
    [ "$output" = "budget=12" ]
}
