# Test-suite host hygiene notes (X-35) for the documentation pass

Scope: the test suite wrote the real `/var/log` of the machine it ran on, and
nothing noticed. Two changes: the tests were pointed at scratch locations, and
`tests/check_tmp_leaks.sh` can now fail the run when host state changes. Nothing
here changes a shipped script or a setting; the docs below are `tests/README.md`
and `CONTRIBUTING.md` (testing section) only.

## How the writers were found (method, reproducible)

Each of the 66 `tests/*.bats` files was run alone, and then each `@test` of
every leaking file alone, in a private mount namespace (`unshare -m`) with
overlayfs mounted over `/etc /var /run /dev/shm /usr/local /root /srv /home /tmp`
(lower layer = the real directory, upper layer = a throwaway tmpfs; `TMPDIR` is a
real directory bind-mounted over the overlay because `git commit` signing in
some tests reads files from it outside the namespace). What a run wrote is
exactly the upper layer: a file there is a file the run created or opened for
writing, a whiteout is a delete. The host stays untouched, and writes by other
processes on a shared machine (other test runs here) cannot show up as the run's
own. Sketch (the real harness is two short scripts in the author's scratch):

```sh
unshare -m --propagation private bash -c '
  mount -t tmpfs tmpfs /mnt; mkdir -p /mnt/up /mnt/wk /mnt/low
  for d in etc var run dev/shm usr/local root srv home tmp; do
    n=${d//\//_}; mkdir -p /mnt/up/$n /mnt/wk/$n /mnt/low/$n
    mount --bind /$d /mnt/low/$n
    mount -t overlay overlay -o lowerdir=/mnt/low/$n,upperdir=/mnt/up/$n,workdir=/mnt/wk/$n /$d
  done
  TMPDIR=<a real dir under /tmp, bind-mounted back over the overlay> bats tests/some_file.bats
  find /mnt/up -type f -o -type c    # c = deleted
'
```

The harness was checked with a canary bats file that appends to an existing log,
creates files under `/var/log/lyrebird`, `/var/lib`, `/run`, `/dev/shm` and
`/tmp`, appends to a file in `/etc/mediamtx`, deletes a log and writes a relative
path: every one was reported (created, modified or deleted), and the host paths
were unchanged afterwards.

Run as root on the base commit `6f10415` (no `LYREBIRD_TEST_MEDIAMTX_BINS`, so
the live tests were skipped, as in the CI bats job).

## Every test that wrote the host, with the variable that fixes it

| Test file | Test (exact name) | Wrote | Fix | Status |
|-----------|-------------------|-------|-----|--------|
| `test_lyrebird_diagnostics.bats` | `get_tcp_timewait_connections returns a single value, never '0\\n0' [DIAG-3 regression]`; `get_disk_usage_percent parses a wrapped/long device name [DIAG-5 regression]`; `get_script_version matches each script's version variable` | `/var/log/lyrebird-diagnostics.log` | `DIAGNOSTIC_LOG_FILE` (set by `scratch_setup`, which the file now uses) | **fixed here** |
| `test_pipefail_aborts.bats` | `diagnostics: NTP offset probe survives an UNSYNCED ntpd (the normal pre-sync field state)`; `diagnostics: NTP offset probe survives chronyd not running`; `diagnostics: get_script_version on a script with NO version marker returns 'unknown'` | `/var/log/lyrebird-diagnostics.log` | `DIAGNOSTIC_LOG_FILE` (same) | **fixed here** |
| `test_mediamtx_json_compat.bats` | `validate_stream succeeds against a NEW-shape paths/get response` | `/var/log/lyrebird-stream-manager.log` and its `.lock` | `STREAM_MANAGER_LOG_FILE` (set by `scratch_setup`) | **fixed here** |
| `test_e2e_integration.bats` | `E2E: an alert is delivered to a mock webhook with a valid JSON body` | `/var/log/lyrebird/alerts.log` | `LYREBIRD_ALERT_LOG` (set by `scratch_setup`) | **fixed here** |
| `test_stream_manager.bats` | `cron resurrection is bounded per stream per hour [SM-2/H8 regression]` | `/var/log/lyrebird-stream-manager.log` and its `.lock` | `STREAM_MANAGER_LOG_FILE`: **already fixed by the `scratch_setup` change** (the file loads the helper); nothing to apply, verified by the post-fix scan | fixed by the helper |
| `test_stream_manager_unit.bats` | `render_systemd_unit refuses what the unit file cannot carry and prints no unit: a newline in the name, a bad mode or filter, a path with a space [LB-11, X-11]` | `/var/log/it"s.log` and its `.lock` (the test sets both log variables to that path; the manager logs its refusal there) | **lead to apply** (file not editable by this worker): in the line `run env MEDIAMTX_LOG_FILE='/var/log/it"s.log' STREAM_MANAGER_LOG_FILE='/var/log/it"s.log' bash -c ...` use `MEDIAMTX_LOG_FILE="$UN/it\"s.log" STREAM_MANAGER_LOG_FILE="$UN/it\"s.log"`; the test depends on the quote, not on `/var/log`. Tried on a scratch copy: the test passes and writes nothing | open |
| `test_install_mediamtx.bats` | `release_lock preserves the lock file, removes only the pid file [INST-8 regression]` | `/run/lock/mediamtx-installer.lock` (opened with `>`: mtime changes) and `/run/lock/mediamtx-installer.lock.pid` (created, then removed) | **needs a production hunk** in `install_mediamtx.sh` (not this worker's file): `readonly LOCK_FILE="/run/lock/mediamtx-installer.lock"` ignores the `LOCK_FILE` that the test's `setup()` already exports. With `readonly LOCK_FILE="${LOCK_FILE:-/run/lock/mediamtx-installer.lock}"` (or a dedicated variable that `setup()` exports) the whole file (100 tests) passes and writes nothing; tried on a scratch copy | open |
| `test_config_files.bats` `systemd-analyze verify reports no unknown/ignored keys [config]`; `test_stream_manager_unit.bats` `the template and the standalone unit load without a finding, together without an ordering cycle [LB-11, LB-12, D12]` and `the rendered unit is accepted by systemd with zero findings when ExecStart names an existing executable script [LB-11, LB-12]` | (same three) | `/run/systemd/systemd-units-load` (touched by `systemd-analyze verify` itself, 0 bytes, outside every LyreBird path) | none: a side effect of the tool, not of a LyreBird script; not watched by the gate | accepted |

The same per-file scan repeated after the change (all 66 files, same sandbox)
reports writes from exactly three files, the open and accepted rows above:
`test_stream_manager_unit.bats` (`/var/log/it"s.log`, `systemd-units-load`),
`test_install_mediamtx.bats` (`/run/lock/mediamtx-installer.lock`) and
`test_config_files.bats` (`systemd-units-load`). Every other file, including
`test_stream_manager.bats`, writes nothing.

The relative file `alerts.log` seen in a manual snapshot was not reproduced as a
file in the working directory: no test created one anywhere outside
`/var/log/lyrebird` (the overlay covered `/home` and `/tmp`). It is most likely
the entry name inside `/var/log/lyrebird` (not verified: the manual snapshot was
not available).

`test_lyrebird_alerts.bats`, `test_lyrebird_mic_check.bats`,
`test_lyrebird_common.bats` and `test_integration.bats` wrote nothing to the host.

## What changed in the suite

- `tests/scratch_tmpdir.bash`: `scratch_setup` now also exports
  `STREAM_MANAGER_LOG_FILE`, `DIAGNOSTIC_LOG_FILE`, `LYREBIRD_ALERT_LOG` and
  `LYREBIRD_ALERT_STATE_DIR`, each under the per-test scratch directory, next to
  the existing `LYREBIRD_STATE_DIR`. They are the scripts' own documented
  variables. A test that needs another location sets its own value (several
  already do). Every file that loads the helper is covered, including files other
  workers own. `test_lyrebird_diagnostics.bats` and `test_pipefail_aborts.bats`
  now load and use the helper.
- `tests/check_tmp_leaks.sh`: the host-state check below.
- `.github/workflows/bash-ci.yml`: the bats job sets `LYREBIRD_LEAK_CHECK_HOST: '1'`
  on the "Run bats test suite" step, nothing else.
- Counts: `bats --count tests/` is 1481 (1459 on the base): +17 in
  `test_suite_hygiene.bats` (now 18), +1 each in `test_lyrebird_diagnostics`,
  `test_pipefail_aborts`, `test_e2e_integration`, `test_mediamtx_json_compat`,
  `test_ci_config` (now 46).

## The host-state check (`LYREBIRD_LEAK_CHECK_HOST=1`)

For `tests/README.md` ("Run all tests and check for leaked temp files") and
`CONTRIBUTING.md` (Testing):

```bash
tests/check_tmp_leaks.sh                              # TMPDIR leaks only (default)
LYREBIRD_LEAK_CHECK_HOST=1 tests/check_tmp_leaks.sh   # also host state; CI's bats job does this
```

- **Values:** unset or `0` = off; `1` = on; anything else = exit 2 with a message
  (so a typo cannot disable the gate silently).
- **What it records** before and after the run (type, inode, size, mtime, mode,
  owner of every entry, recursively): `/var/log/lyrebird*` (including
  `/var/log/lyrebird/`), `/var/log/mediamtx*`, `/var/lib/lyrebird`,
  `/var/lib/mediamtx-ffmpeg`, `/run/lyrebird*`, `/run/mediamtx*`,
  `/etc/lyrebird`, `/etc/mediamtx`, `/etc/cron.d/mediamtx*`,
  `/etc/systemd/system/mediamtx*`, `/etc/logrotate.d/*`, `/dev/shm/lyrebird*`;
  the whole repository working tree except `.git`; and the entries directly in
  the current directory when it is outside the repository (a relative path a test
  writes lands there). The patterns are expanded again after the run, so a path
  that only exists afterwards is reported.
  `/var/log/mediamtx*` is an addition to the list the register asked for (the
  default MediaMTX output file); nothing wrote it in the scan.
- **Output and status:** each difference is printed as `created:`, `removed:` or
  `changed:` with the before and after values; exit 1. If bats itself fails, its
  status is kept and the diff is still printed. A TMPDIR leak and a host change
  are both reported.
- **Limitation, and how it is handled:** the window is the whole run, so anything
  else that writes these paths meanwhile (a service, a cron job, another test run
  as root on the same machine) is blamed on the suite. The check is meant for CI
  and disposable machines. It refuses to run (exit 2, message, nothing is run)
  where the machine looks like a LyreBird node: `mediamtx-audio.service` or
  `mediamtx.service` is `active`/`activating`/`reloading` according to
  `systemctl is-active`, or a `/etc/cron.d/mediamtx*` job is installed. Not
  detected: a hand-started manager without a unit, and a second suite run as root
  on the same machine. On this shared development host other workers' suites
  were writing the real `/var/log` while this one ran (observed: the mtimes of
  `/var/log/lyrebird/alerts.log`, `/var/log/it"s.log` and
  `/run/lock/mediamtx-installer.lock` moved several times during this work, at
  times when this worker's runs that could write them were in the sandbox; the
  one exception was a mutation run started outside it by mistake, which
  appended about 1.3 KB to `/var/log/lyrebird-diagnostics.log`), so a run on the
  real paths here is not a clean measurement of this suite alone. The full-suite
  runs reported in the final report were made in a private mount namespace with
  private copies of `/etc /var/log /var/lib /run /dev/shm`, so that neither
  other workers' writes nor the two unfixed writers above touch the result or
  the host.
- **Not covered:** `/run/lock/mediamtx*` (the installer's lock, see the open row
  above; add `"${host_root}/run/lock/mediamtx*"` to `host_patterns` in
  `tests/check_tmp_leaks.sh` once `install_mediamtx.sh` lets the test redirect
  it, otherwise the gate would fail on that test), `/run/systemd/*`, `/tmp`
  outside `TMPDIR` (a hard-coded `/tmp` path: none was found in the overlay
  scan), `$HOME`, `/usr/local/bin`, `/etc/udev/rules.d`, and the live
  MediaMTX tests (skipped without `LYREBIRD_TEST_MEDIAMTX_BINS`, which is how CI's
  bats job and the scans above ran them). The three live files that use private
  ports (`test_mediamtx_config_live`, `test_mediamtx_api_live`,
  `test_mediamtx_e2e_ports`: 14 tests) were run once in the sandbox against the
  checksum-pinned MediaMTX v1.21.3 and wrote nothing; `test_mediamtx_live`,
  `test_soak_live` and `test_soak_observer` bind the default ports and were not
  run (not verified).
  On a non-root CI runner the unwritable paths cannot change, so the gate there
  mostly watches the working tree, the current directory and world-writable
  places such as `/dev/shm`.
- `LYREBIRD_LEAK_HOST_ROOT=DIR` prefixes every watched absolute path; it exists
  only so `tests/test_suite_hygiene.bats` can test the check against a scratch
  tree. Leave it unset.

## Guidance for new tests (for `tests/README.md`, "Writing New Tests")

The example there sources `lyrebird-common.sh` and makes its own `mktemp -d`; it
should show `load scratch_tmpdir`, `scratch_setup` in `setup()` and
`scratch_teardown` in `teardown()`, and say why: a test that sources a script and
runs one of its functions writes that script's default log and state paths. When
a script gains a log or state variable with a default under `/var`, `/run` or
`/etc`, add it to `scratch_setup` (the hygiene test
`scratch_setup points the manager, diagnostics and alert logs and the alert state at the scratch directory [X-35]`
sources the real scripts and fails if a name there is not the one the script
reads).

## New defects found on the way (none fixed here: outside X-35)

1. **`usb-audio-mapper.sh` `card_usb_port` walks above `USB_AUDIO_MAPPER_SYSFS`.**
   Reproduced: `test_pipefail_aborts.bats` `usb-mapper: card_usb_port survives a
   platform (non-USB) sound card under pipefail` failed (`COMPLETED rc=0`, expected
   `rc=1`) when the test directory's ancestors contained a directory named like
   `1794448449-17248` (digits-dash-digits), because the upward walk past the fake
   sysfs root matched it as a USB `<bus>-<port>`. Real sysfs has no such ancestor
   above `/sys/devices`, so hardware is not affected; the test is sensitive to the
   path of `TMPDIR`. Severity P4 (test hermeticity).
2. **Tests that run `git commit` without isolating git's configuration.**
   `test_ci_config.bats` (3 commit sites) does not set
   `GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1` (the updater tests and
   `tests/updater_helper.bash` do). On a machine with `commit.gpgsign=true` every
   such commit runs the signer: on this host it calls an external signing service
   and fails when the file it is asked to sign is not visible to it (reproduced:
   `make_upstream` failed with status 128 inside the overlay sandbox when `TMPDIR`
   was not shared). On a developer machine with a passphrase prompt it can hang.
   Severity P4 (test hermeticity; not a write to host state).
3. **`test_stream_manager_unit.bats` `the manager installs its HUP/USR1 handlers
   only when it is not run by systemd, and sets no USR2 handler [LB-11, LB-15]`
   fails when the suite is started with SIGHUP ignored.** Reproduced:
   `nohup bats --filter 'installs its HUP/USR1 handlers only when' tests/test_stream_manager_unit.bats`
   fails at its `[ -z "$output" ]` (line 74) with the captured output
   `trap -- '' SIGHUP`; without `nohup` it passes. `nohup` (and some job
   runners) start the suite with SIGHUP ignored, the ignore is inherited by the
   manager copy the test runs, and `trap -p HUP` then reports it. This is what
   failed in this worker's first scans and in a full-suite run started with
   `nohup` (all re-runs without it passed). The test should not depend on how its
   own process was started (for example by comparing `trap -p` output only for
   handlers the script set, or by running the copy with `trap - HUP` first).
   Severity P4 (test fragility); file owned by another worker.
4. **`test_stream_manager_locks.bats` `a refused process names the real owner:
   pid, start time and command [D2]` failed once in a per-file scan** (two files
   at a time, 4-CPU host, load average 7-10 from other workers' suites) and
   passed in every re-run alone (also under `nohup`). Not reproduced, cause not
   found.
5. **`test_lyrebird_metrics.bats` `serve: GET / and GET /metrics are 200, other
   paths 404, other methods 405, malformed requests 400 [LB-18]` is flaky.**
   It failed in one of four full-suite runs and in one of 26 runs of the test
   alone (1 of the first 6, then 0 of 20). The captured output of the failed
   full-suite run: `_stop_server_term_ok` failed (test line 1154, called from
   line 1250), `server exit status 134`, and the server printed
   `*** longjmp causes uninitialized stack frame ***: terminated` (a glibc
   fortify abort; netcat: openbsd) instead of exiting on SIGTERM. Cause not
   investigated; file owned by another worker. A lead running the suite may see
   it as a red test that passes on re-run.

## Result (after the change; commit 28070f8 for the full-suite runs)

- Per-file scan of all 66 files: before, writers in 8 files (table above); after,
  3 files (the open and accepted rows). Per-test attribution used the same
  sandbox.
- Gate on the four fixed files (diagnostics, pipefail_aborts, json_compat,
  e2e_integration) in a private namespace with private copies of the host paths:
  base `6f10415` exit 1 with a 3-file diff (`lyrebird-diagnostics.log`
  38368 -> 39688, `lyrebird-stream-manager.log` 221973 -> 222098,
  `lyrebird/alerts.log` 2397 -> 2448), after the change exit 0.
- Full suite (1481 tests, 37 skipped) with `LYREBIRD_LEAK_CHECK_HOST=1
  tests/check_tmp_leaks.sh`, started in the same kind of namespace, four times:
  runs 3 and 4 passed 1481/1481 and printed `No temp files left behind.` and
  `No host-state changes.` (exit 0); run 2 passed 1480/1481 (the flaky test in
  item 5 above) and reported no host or TMPDIR finding; run 1 was started with
  `nohup` and failed 1 test (item 3 above) and its report listed only this notes
  file, which was edited while the run was going (the gate working as intended).

