# shellcheck shell=bash
# Shared setup for tests/test_storage_*.bats: run the REAL lyrebird-storage.sh
# functions in a child shell whose every directory is private to the test.
#
# The script's own defaults are the real /var/log, /dev/shm/lyrebird-buffer and
# /tmp. Emergency cleanup wipes the buffer, and cleanup_logs / truncate_large_logs
# look at MEDIAMTX_LOG_DIR (/var/log by default), so every knob that names a
# directory is overridden here; a test that forgets one would act on the host.
#
# Usage:
#   load scratch_tmpdir
#   load storage_helper
#   setup()    { scratch_setup; storage_setup; }
#   teardown() { storage_teardown; scratch_teardown; }
#   @test "..." { run storage_run cleanup_recordings; ... }
#
# Extra environment for one call: set the ST_ENV array first, e.g.
#   ST_ENV=(PATH="$shim:$PATH" LYREBIRD_ACTIVE_SEGMENT_SECONDS=60)

storage_setup() {
    PROJECT_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
    ST_ROOT="$(mktemp -d)"
    ST_REC="$ST_ROOT/rec"
    ST_LOGS="$ST_ROOT/logs"
    ST_TEMP="$ST_ROOT/tmp"
    ST_OUTSIDE="$ST_ROOT/outside"
    ST_CWD="$ST_ROOT/cwd"
    mkdir -p "$ST_REC" "$ST_LOGS" "$ST_TEMP" "$ST_OUTSIDE" "$ST_CWD"
    # The script only accepts a buffer under /dev/shm, /tmp, /var/tmp or /run,
    # wherever TMPDIR points (CI: the runner's work directory).
    ST_BUF="$(mktemp -d /tmp/lyrebird-test-buffer.XXXXXX)"
    ST_ENV=()
}

storage_teardown() {
    # chattr +i / read-only directories made by a test must not outlive it.
    if [[ -n "${ST_ROOT:-}" && -d "$ST_ROOT" ]]; then
        chattr -R -i "$ST_ROOT" 2>/dev/null || true
        chmod -R u+rwx "$ST_ROOT" 2>/dev/null || true
        rm -rf -- "$ST_ROOT"
    fi
    if [[ -n "${ST_BUF:-}" && "$ST_BUF" == /tmp/lyrebird-test-buffer.* ]]; then
        chattr -R -i "$ST_BUF" 2>/dev/null || true
        rm -rf -- "$ST_BUF"
    fi
}

# storage_run FUNCTION [ARGS...] -- source the real script (set -euo pipefail, as
# in production), call FUNCTION, merge stderr into stdout. Runs from $ST_CWD so
# a deletion that escapes through a cwd-relative path hits a known directory.
storage_run() {
    (
        cd "$ST_CWD" || exit 99
        env PROJECT_ROOT="$PROJECT_ROOT" \
            LYREBIRD_RECORDING_DIR="$ST_REC" \
            LYREBIRD_LOG_DIR="$ST_LOGS" \
            LYREBIRD_TEMP_DIR="$ST_TEMP" \
            LYREBIRD_BUFFER_DIR="$ST_BUF" \
            MEDIAMTX_LOG="$ST_LOGS/mediamtx.out" \
            DRY_RUN=false \
            ${ST_ENV[@]+"${ST_ENV[@]}"} \
            bash -c 'set -euo pipefail; source "$PROJECT_ROOT/lyrebird-storage.sh"; "$@" 2>&1' _ "$@"
    )
}

# Value of a variable after sourcing the real script (arrays: one element per line).
storage_value() {
    env PROJECT_ROOT="$PROJECT_ROOT" LYREBIRD_BUFFER_DIR="${ST_BUF:-/tmp}" \
        bash -c 'source "$PROJECT_ROOT/lyrebird-storage.sh"; trap - EXIT; v="$1[@]"; printf "%s\n" "${!v}"' _ "$1"
}
