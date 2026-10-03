#!/usr/bin/env bats
# Safety of tests/test_lyrebird_storage.bats itself. Its setup() used to export
# RECORDING_DIR/LOG_DIR/TEMP_DIR, which lyrebird-storage.sh overwrites with
# readonly defaults when sourced, so every test and the teardown's rm -rf hit
# the REAL /var/lib/mediamtx-ffmpeg/recordings, /var/log/lyrebird and /tmp.
# These checks live in their own file because a test inside
# test_lyrebird_storage.bats cannot fail: the sourced script replaces bats'
# EXIT trap (see docs/ENGINEERING-REVIEW-2026-07.md §9, U8).

setup() {
    PROJECT_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
}

# Run the storage test file's real setup() in a child shell and print the
# directories the storage script ends up using.
storage_setup_dirs() {
    local f="$PROJECT_ROOT/tests/test_lyrebird_storage.bats"
    bash -c '
        eval "$(sed -n "/^setup() {/,/^}/p" "$1")"
        BATS_TEST_FILENAME="$1"
        setup >/dev/null 2>&1
        trap - EXIT
        printf "%s\n%s\n%s\n" "$RECORDING_DIR" "$LOG_DIR" "$TEMP_DIR"
        rm -rf -- "$TEST_RECORDING_DIR" "$TEST_LOG_DIR" "$TEST_TEMP_DIR"
    ' _ "$f"
}

@test "storage tests run against private temp dirs, never system paths [suite data-loss regression]" {
    run storage_setup_dirs
    [ "$status" -eq 0 ]
    [ "${#lines[@]}" -eq 3 ]
    for d in "${lines[@]}"; do
        [[ "$d" == "${TMPDIR:-/tmp}"/tmp.* ]] || { echo "unsafe dir: [$d]"; return 1; }
    done
}

@test "lyrebird-storage.sh honours the LYREBIRD_* directory overrides" {
    run env LYREBIRD_TEMP_DIR=/var/tmp/x1 LYREBIRD_RECORDING_DIR=/var/tmp/x2 LYREBIRD_LOG_DIR=/var/tmp/x3 \
        bash -c 'source "$1" >/dev/null 2>&1; trap - EXIT; printf "%s %s %s\n" "$TEMP_DIR" "$RECORDING_DIR" "$LOG_DIR"' _ "$PROJECT_ROOT/lyrebird-storage.sh"
    [ "$output" = "/var/tmp/x1 /var/tmp/x2 /var/tmp/x3" ]
}
