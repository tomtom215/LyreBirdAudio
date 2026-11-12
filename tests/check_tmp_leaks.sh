#!/usr/bin/env bash
# Run the bats suite in a fresh TMPDIR and fail if the run leaves anything in
# it. Unattended nodes run some of these code paths for months; tests are
# where a temp-file leak is cheapest to catch.
#
# Usage: tests/check_tmp_leaks.sh [bats arguments...]   (default: tests/)
# Exit status: bats' status if the suite fails, 1 on leaks, 0 otherwise;
# 2 when the run was refused or misconfigured (see LYREBIRD_LEAK_CHECK_HOST).
#
# LYREBIRD_LEAK_CHECK_HOST=1 (opt in; unset or 0 = off; any other value is an
# error, so a typo cannot switch the check off silently) also fails the run
# when it changed host state outside TMPDIR. The suite is meant to touch only
# its own temp directories, but a test that does not point a script at a
# scratch location writes the real /var/log, /var/lib, /run or /etc of the
# machine it runs on: as root on a developer's node that pollutes the node's
# logs, on CI it is harmless and invisible. The check records, before and after
# the run, the type, inode, size, mtime, mode and owner of every entry under
#   /var/log/lyrebird*  (this includes /var/log/lyrebird/)    /var/log/mediamtx*
#   /var/lib/lyrebird   /var/lib/mediamtx-ffmpeg
#   /run/lyrebird*      /run/mediamtx*      /dev/shm/lyrebird*
#   /etc/lyrebird       /etc/mediamtx       /etc/cron.d/mediamtx*
#   /etc/systemd/system/mediamtx*           /etc/logrotate.d/*
# (the patterns are expanded again after the run, so a path that only exists
# then is reported as created), of the whole repository working tree except
# .git, and of the entries directly in the current directory when that is
# outside the repository (a relative path written by a test lands there). Any
# difference is printed as created / removed / changed with the before and
# after values, and the run fails.
#
# The window is the whole run, and anything on the machine that writes these
# paths meanwhile (a service, a cron job, another test run as root) would be
# reported as the suite's doing. The check is therefore meant for CI and
# disposable machines, and it refuses to run (exit 2, nothing is run) where
# the machine looks like a LyreBird node: mediamtx-audio.service or
# mediamtx.service is active, or a /etc/cron.d/mediamtx* job is installed.
# A hand-started manager without a unit is not detected.
#
# LYREBIRD_LEAK_HOST_ROOT=DIR (for tests/test_suite_hygiene.bats; leave unset)
# prefixes every absolute path above with DIR, so the check itself can be
# tested against a scratch tree instead of the real host.

set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
repo_root="$(dirname "$script_dir")"
host_root="${LYREBIRD_LEAK_HOST_ROOT:-}"
host_root="${host_root%/}"
tab=$'\t'

check_host=0
case "${LYREBIRD_LEAK_CHECK_HOST:-0}" in
    0) ;;
    1) check_host=1 ;;
    *)
        echo "LYREBIRD_LEAK_CHECK_HOST must be 0 or 1, not '${LYREBIRD_LEAK_CHECK_HOST}'" >&2
        exit 2
        ;;
esac

# The host paths watched, one glob per line.
host_patterns() {
    printf '%s\n' \
        "${host_root}/var/log/lyrebird*" \
        "${host_root}/var/log/mediamtx*" \
        "${host_root}/var/lib/lyrebird" \
        "${host_root}/var/lib/mediamtx-ffmpeg" \
        "${host_root}/run/lyrebird*" \
        "${host_root}/run/mediamtx*" \
        "${host_root}/etc/lyrebird" \
        "${host_root}/etc/mediamtx" \
        "${host_root}/etc/cron.d/mediamtx*" \
        "${host_root}/etc/systemd/system/mediamtx*" \
        "${host_root}/etc/logrotate.d/*" \
        "${host_root}/dev/shm/lyrebird*"
}

# Reasons this machine looks like a running LyreBird node, one per line.
node_markers() {
    local unit state cron
    if command -v systemctl >/dev/null 2>&1; then
        for unit in mediamtx-audio.service mediamtx.service; do
            state="$(systemctl is-active "$unit" 2>/dev/null || true)"
            case "$state" in
                active | activating | reloading) echo "systemd unit ${unit} is ${state}" ;;
            esac
        done
    fi
    while IFS= read -r cron; do
        echo "cron job ${cron} is installed"
    done < <(compgen -G "${host_root}/etc/cron.d/mediamtx*" || true)
}

# snapshot: one tab-separated line per entry (path, type, inode, size, mtime,
# mode, owner). The patterns are expanded afresh each time, so a path that
# only exists after the run shows up as an entry the first snapshot lacks.
snapshot() {
    local pattern path here fmt
    fmt='%p\t%y\t%i\t%s\t%T@\t%m\t%U:%G\n'
    while IFS= read -r pattern; do
        while IFS= read -r path; do
            find "$path" -printf "$fmt" 2>/dev/null || true
        done < <(compgen -G "$pattern" || true)
    done < <(host_patterns)
    # The repository working tree. .git is skipped (git refreshes its index
    # on a plain `git status`), and so is the run's own TMPDIR if it sits in
    # the tree.
    find "$repo_root" \( -path "${repo_root}/.git" -o -path "$run_tmp" \) -prune -o -printf "$fmt" 2>/dev/null || true
    here="$(pwd -P)"
    if [[ "$here" != "$repo_root" && "$here" != "$repo_root"/* && "$here" != / ]]; then
        find "$here" -maxdepth 1 -path "$run_tmp" -prune -o -printf "$fmt" 2>/dev/null || true
    fi
}

# report_diff BEFORE AFTER: what differs between two snapshots, sorted by path,
# one "created:", "removed:" or "changed:" entry each. Prints nothing when the
# snapshots agree.
report_diff() {
    awk -F'\t' '
        function show(rec, f) {
            split(rec, f, "\t")
            return sprintf("type=%s inode=%s size=%s mtime=%s mode=%s owner=%s", f[2], f[3], f[4], f[5], f[6], f[7])
        }
        FNR == 1 { fileno++ }
        fileno == 1 { before[$1] = $0 }
        fileno == 2 { after[$1] = $0 }
        END {
            for (p in after) {
                if (!(p in before)) {
                    print "created\t" p "\t\t" show(after[p])
                } else if (after[p] != before[p]) {
                    print "changed\t" p "\t" show(before[p]) "\t" show(after[p])
                }
            }
            for (p in before) {
                if (!(p in after)) {
                    print "removed\t" p "\t" show(before[p]) "\t"
                }
            }
        }' <(printf '%s\n' "$1") <(printf '%s\n' "$2") \
        | sort -t "$tab" -k2,2 \
        | awk -F'\t' '{
            print $1 ": " $2
            if ($3 != "") print "      was: " $3
            if ($4 != "") print "      now: " $4
        }'
}

if ((check_host)); then
    markers="$(node_markers)"
    if [[ -n "$markers" ]]; then
        {
            echo "LYREBIRD_LEAK_CHECK_HOST=1 refused: this machine looks like a LyreBird node:"
            printf '  %s\n' "${markers//$'\n'/$'\n'  }"
            echo "The check compares host paths before and after the run, so a running service"
            echo "would be reported as a leak of the suite. Run it on CI or a disposable machine,"
            echo "or leave LYREBIRD_LEAK_CHECK_HOST unset. Nothing was run."
        } >&2
        exit 2
    fi
fi

parent="${TMPDIR:-/tmp}"
run_tmp="$(mktemp -d "${parent%/}/bats-leakcheck.XXXXXX")"
export TMPDIR="$run_tmp"
export BATS_TMPDIR="$run_tmp"

host_before=""
if ((check_host)); then
    host_before="$(snapshot)"
fi

status=0
if (($#)); then
    bats "$@" || status=$?
else
    bats --print-output-on-failure --timing tests/ || status=$?
fi

host_changes=""
if ((check_host)); then
    host_changes="$(report_diff "$host_before" "$(snapshot)")"
fi

# bats removes its own bats-run-* directory; everything else is a leak.
leaks="$(find "$run_tmp" -mindepth 1 -maxdepth 1 ! -name 'bats-run-*' -printf '%f\n' | sort)"
chmod -R u+rwx -- "$run_tmp" 2>/dev/null || true
rm -rf -- "$run_tmp"

failed=0
if [[ -n "$leaks" ]]; then
    printf 'Test run left %d entries in TMPDIR:\n%s\n' "$(wc -l <<<"$leaks")" "$leaks" >&2
    failed=1
fi
if [[ -n "$host_changes" ]]; then
    printf 'Test run changed host state outside TMPDIR (%d paths):\n%s\n' \
        "$(grep -cE '^(created|removed|changed): ' <<<"$host_changes")" "$host_changes" >&2
    failed=1
fi

if ((status != 0)); then
    exit "$status"
fi
if ((failed)); then
    exit 1
fi
echo "No temp files left behind."
if ((check_host)); then
    echo "No host-state changes."
fi
