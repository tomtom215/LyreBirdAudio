#!/usr/bin/env bash
# Run the bats suite in a fresh TMPDIR and fail if the run leaves anything in
# it. Unattended nodes run some of these code paths for months; tests are
# where a temp-file leak is cheapest to catch.
#
# Usage: tests/check_tmp_leaks.sh [bats arguments...]   (default: tests/)
# Exit status: bats' status if the suite fails, 1 on leaks, 0 otherwise.

set -euo pipefail

parent="${TMPDIR:-/tmp}"
run_tmp="$(mktemp -d "${parent%/}/bats-leakcheck.XXXXXX")"
export TMPDIR="$run_tmp"
export BATS_TMPDIR="$run_tmp"

status=0
if (($#)); then
    bats "$@" || status=$?
else
    bats --print-output-on-failure --timing tests/ || status=$?
fi

# bats removes its own bats-run-* directory; everything else is a leak.
leaks="$(find "$run_tmp" -mindepth 1 -maxdepth 1 ! -name 'bats-run-*' -printf '%f\n' | sort)"
chmod -R u+rwx -- "$run_tmp" 2>/dev/null || true
rm -rf -- "$run_tmp"

if ((status != 0)); then
    exit "$status"
fi
if [[ -n "$leaks" ]]; then
    printf 'Test run left %d entries in TMPDIR:\n%s\n' "$(wc -l <<<"$leaks")" "$leaks" >&2
    exit 1
fi
echo "No temp files left behind."
