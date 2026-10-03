# shellcheck shell=bash
# Per-test private TMPDIR, removed in teardown.
#
# Tests often pass temp paths inline to a child process
# (`run env PID_FILE="$(mktemp)" ...`) and never delete them; each run then
# left files behind in $TMPDIR. With TMPDIR pointing at a per-test directory,
# every mktemp made during the test (by the test or by the script under test)
# lands inside it and is removed with it.
#
# Usage: call scratch_setup first in setup() and scratch_teardown in teardown().

scratch_setup() {
    _SCRATCH_SAVED_TMPDIR="${TMPDIR-}"
    _SCRATCH_HAD_TMPDIR="${TMPDIR+set}"
    TEST_SCRATCH="$(mktemp -d)"
    export TMPDIR="$TEST_SCRATCH"
}

scratch_teardown() {
    if [[ -n "${TEST_SCRATCH:-}" && -d "$TEST_SCRATCH" ]]; then
        # A test may leave read-only directories behind; make them removable.
        chmod -R u+rwx -- "$TEST_SCRATCH" 2>/dev/null || true
        rm -rf -- "$TEST_SCRATCH"
    fi
    if [[ -n "${_SCRATCH_HAD_TMPDIR:-}" ]]; then
        export TMPDIR="$_SCRATCH_SAVED_TMPDIR"
    else
        unset TMPDIR
    fi
}
