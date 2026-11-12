# Metrics and storage residuals (X-30, X-29, DOC-05): notes for the documentation pass

`lyrebird-metrics.sh` 1.3.0 -> **1.4.0**, `lyrebird-storage.sh` 1.2.0 -> **1.3.0**
(README component table, CHANGELOG, `docs/components.html`, `docs/changelog.html`).
This closes the "defects found, not fixed" list of `metrics.md` (items 1-3) and the
"Not fixed (residual, low)" list of `storage.md` (first three items); delete those
lists when the notes are consolidated. Evidence labels: **R** = reproduced by running
the real script, **S** = source read only.

New test files: `tests/test_metrics_process_identity.bats` (14),
`tests/test_metrics_api_budget.bats` (7), `tests/test_storage_scan.bats` (13),
`tests/test_storage_cli.bats` (9), `tests/test_storage_config.bats` (9); new helper
`tests/helpers/mediamtx/slow_api.py`; `tests/test_lyrebird_metrics.bats` 95 -> 96
(one test replaced in place, one added). `bats --count tests/` is **1512** (was 1459).
`tests/README.md` (not edited here): add the five files to the test-file table, change
the metrics row to 96 tests and `lyrebird-storage.sh` to its five test files, re-count
the total. `docs/contributing.html` says `test_lyrebird_storage.bats` has 42 tests; it
has 59 (plus the `test_storage_*.bats` files).

---

## lyrebird-metrics.sh (X-30)

### Which process is MediaMTX (R, X-30 a)

A process is this installation's MediaMTX when its **executable is `MEDIAMTX_BINARY`**
(default `/usr/local/bin/mediamtx`, symlinks resolved, a binary replaced by an upgrade,
`/proc/PID/exe` = `<path> (deleted)`, still recognised) and its **first argument is the
configuration file** (`MEDIAMTX_CONFIG_FILE`, else `MEDIAMTX_CONFIG_DIR/mediamtx.yml`):
the identity the stream manager uses (`is_managed_mediamtx_pid`). The exporter looks:

1. at the process in the manager's PID file (`PID_FILE`, else `MEDIAMTX_PID_FILE`, the
   variable the manager reads; default `/run/mediamtx-audio.pid`) together with its
   `<pid file>.id` start-time record;
2. if that does not verify (no file, a dead PID, a PID that names a look-alike, a reused
   PID): an exact-identity scan of `/proc` (argv[1] first, then the executable). This is
   what finds a stand-alone MediaMTX under `mediamtx.service`.

The scan costs about 15 ms per scrape with 167 processes (measured, while the test suite
was running).
No name or command-line pattern is used any more and `pgrep` is no longer a dependency
(a decoy such as an editor on `mediamtx.yml`, `mediamtx-exporter`, `tail -f
/var/log/mediamtx.log` or another installation's MediaMTX used to give
`lyrebird_mediamtx_up 1` with ITS memory, CPU, descriptors and uptime). README / `docs/monitoring.html`
that say "reports whether a process named mediamtx exists" must say "this installation's
MediaMTX (configured binary on the configured configuration)". New settings to document:
`MEDIAMTX_BINARY`, `MEDIAMTX_CONFIG_FILE`, `MEDIAMTX_CONFIG_DIR` and `MEDIAMTX_PID_FILE`
(the same variables as the stream manager), and `PID_FILE` (which still wins over
`MEDIAMTX_PID_FILE`).

### Liveness without signals, and what an unprivileged exporter sees (R, X-30 b)

`kill -0` is gone. A stream wrapper / the manager's PID is "running" when
`/proc/PID/stat` exists, is not a zombie, and, if the manager's `<pid file>.id` record
names this PID, started at the recorded time (a reused PID is not the stream). No record
(older versions) = existence is all there is to go by. **A zombie now reads as down**
(`kill -0` said up). `lyrebird_stream_up`, `lyrebird_active_streams` and
`lyrebird_stream_manager_up` therefore no longer read 0 for a live root-owned process when
the exporter runs as another user (reproduced as uid 65534).

What cannot be seen from another user is **unknown, not 0**: the metric is left out and the
collector's `lyrebird_collector_success` is 0 (and `lyrebird_scrape_success`, exit status 3),
with one stderr line each:

| unprivileged exporter, root's processes | result |
|---|---|
| manager-started MediaMTX with the `.id` record | `mediamtx_up 1` (identity by record + argv[1]), memory, CPU, uptime present, **`mediamtx_open_fds` omitted** (it used to be published as `0`: `/proc/PID/fd` cannot be listed) and the mediamtx collector fails |
| stand-alone MediaMTX / PID file without a record | `mediamtx_up` omitted, mediamtx collector fails ("cannot tell whether MediaMTX ... is running ... run as root") |
| nothing runs that configuration | `mediamtx_up 0`, collector ok (argv[1] is world-readable) |
| `/proc` mounted with `hidepid=1` | stream samples, `active_streams`, `stream_manager_up` omitted, collectors fail (tested in a private pid + mount namespace) |

Say in the docs: **run the exporter as root** (cron or a root unit) for a complete scrape;
an unprivileged exporter works but is reported as degraded (`scrape_success 0`, exit 3) for
MediaMTX details. Alert rules `lyrebird_mediamtx_up == 0` do not fire for an unknown
state; `lyrebird_scrape_success == 0` does. With `hidepid=2` (processes invisible) a
process cannot be told from a dead one: keep the exporter's user in the `gid=` of that
mount, or run it as root. A MediaMTX in another PID namespace (a container) is not seen.

### Time spent on the MediaMTX API (R, X-30 c)

* Measured, API port with no listener (refused at once): **1025 / 1028 / 1024 ms** per
  scrape before (two attempts with `sleep 1` between), **20 / 19 / 35 ms** after. In
  `--serve` mode that second was added to every response.
* An API that accepts the connection and never answers made the collector **never return**
  (curl had `--connect-timeout` only; found while measuring; the scrape / `--file` cron
  job hangs and cron jobs pile up). Now bounded: 2.2 s with `LYREBIRD_API_TIMEOUT=2`,
  5.2 s with 5.
* **`LYREBIRD_API_TIMEOUT`** (new; positive whole seconds, default **5**; an invalid value
  warns and uses 5): the time ALL API requests of one scrape may take together, enforced
  with curl `--max-time`; counted in whole seconds, so a scrape may overrun by up to 1 s.
  Keep it below the Prometheus `scrape_timeout` (10 s by default).
* A refused or unresolvable connection is final at once (one request, no pause); other
  failures (reset, empty reply, timeout) are retried once after 0.2 s if budget is left.
  `/v3/info` unanswered = `lyrebird_api_up 0` as before. A list endpoint unanswered
  (budget exhausted, reset) leaves its metrics out, **`lyrebird_api_total_connections` is
  then not published** (a total over missing lists would be made up) and the api collector
  fails with "the MediaMTX API did not answer every request within Ns".

### Large `/v3/info` (R, X-30 d)

`echo "$json" | grep -q` under `pipefail` made a live API read as down (`api_up 0`) when
the body was large (2.6 MB over many lines, "version" early: 3/3 runs; SIGPIPE of the echo,
status 141). It is a bash pattern match now.

### Other changes found on the way

* An empty list body (HTTP 200, no bytes, or a failed request now that failures leave a
  list empty) made the collector abort with "unbound variable" at the connection total
  (`set -u`); fixed in the same commit as the budget.
* `--help` has an "Environment" section.

### Test change a reviewer must know about

`tests/test_lyrebird_metrics.bats`: "without pgrep the mediamtx collector fails visibly and
no false lyrebird_mediamtx_up 0 is published [LB-18]" pinned the dependency on `pgrep`,
the defect's mechanism. It is **replaced in place** by "the mediamtx collector needs no
pgrep: without it the scrape is complete and no tool is reported missing [LB-18, X-30]"; the
"cannot tell, say so" behaviour is pinned by "without readlink the executable of a process
that runs MediaMTX's configuration cannot be checked: the collector fails visibly and no
false lyrebird_mediamtx_up 0 is published [X-30]". `docs/remediation-status.json` lists
the old title under **LB-18 and X-17**: replace it by the new title or
`tests/test_remediation_status.bats` fails.

---

## lyrebird-storage.sh (X-29, DOC-05)

### Command line and exit status (exact)

```
lyrebird-storage.sh [-n|--dry-run] [-d|--debug] [-q|--quiet] [--once] status|cleanup|monitor|emergency
```

| status | meaning |
|---|---|
| 0 | success |
| 1 | usage error (unknown option, no command, `--quiet` with `status`/`emergency`, `--once` with anything but `monitor`) |
| 3 | finished, but a deletion failed **or a directory could not be listed** (the meaning widened) |
| 4 | **new**: finished, but lines of the configuration file were ignored (3 wins when both apply) |

Add 4 (and the widened 3) wherever the storage exit codes are listed.

### `--quiet`, `--once`, `--interval` (DOC-05)

Decision per documented item:

| documented | decision | reason |
|---|---|---|
| `cleanup --quiet` (README, `monitoring.html`, `components.html`) | **implemented** (also `-q`, also `monitor --quiet`) | cheap and safe; cron needs it |
| `monitor --once` (README, `components.html`) | **implemented**, as what monitor always is | `monitor` is one check per invocation; the flag only has to be accepted |
| `monitor --interval 300` ("Monitor mode (continuous)") | **not implemented; documentation correction** | monitor does not loop and a supervisor-less loop duplicates cron / a timer; the option is still "Unknown option" (exit 1) |
| `/etc/lyrebird/storage.conf` | **implemented** (below) | |
| `RECORDING_DIR=` / `LOG_DIR=` in that file | **implemented as aliases, in the file only** | below |
| `RECORDING_DIR=` / `LOG_DIR=` as *environment variables* ("Environment variables or storage.conf") | **not implemented; documentation correction** | below |
| README "Integration with alerting system" | n/a: the script has no reference to `lyrebird-alerts.sh` (grep) | remove the bullet |

`--quiet`: this script logs to **stderr** (there is no log file of its own) and writes to
stdout only for `status`. `--quiet` drops the INFO lines and keeps **warnings, errors and
one summary line** per run; nothing goes to stdout. (Deviation from "only errors and the
summary": WARN is kept, because the monitor's threshold messages are warnings and a node at
92% disk must not go mute.) Summary lines (INFO, `[Y-m-d H:M:S] [INFO] ...`):

```
Cleanup completed: removed N file(s), X freed                  (dry run: "would remove")
Cleanup incomplete: removed N file(s), X freed; F deletion(s) FAILED; S listing(s) FAILED
Monitor: disk U% used, inodes I%, F MB free (warning|critical|emergency): <same totals>
Monitor: disk usage of / unknown (df unparseable); standard cleanup only: <same totals>
```

`monitor` prints **nothing while the disk is fine**, with or without `--quiet` (so the
documented `*/15` line does not mail every run); with `--quiet` a run that acts prints its
WARN/ERROR line and the one summary instead of the step-by-step lines. Without `--quiet`
the step lines are as before; the last line of `cleanup` is now "Cleanup completed: ...
totals" (the words "Cleanup completed" are kept), and a `monitor` that acts ends in its
own "Monitor: ..." summary instead of "Cleanup completed".
Suggested cron lines (the output of a run is its log; redirect it if mail is not wanted):

```
0 3 * * *    root /path/to/lyrebird-storage.sh cleanup --quiet >>/var/log/lyrebird-storage.log 2>&1
*/15 * * * * root /path/to/lyrebird-storage.sh monitor --once  >>/var/log/lyrebird-storage.log 2>&1
```

(`/var/log/lyrebird-storage.log` is outside `LYREBIRD_LOG_DIR`, which the script cleans.)
Documentation corrections: the usage block of README "Storage Management" and of
`docs/components.html` (Storage Management, "Usage"): `monitor --interval 300  # Monitor
mode (continuous)` -> "run `monitor` from cron or a timer; it checks once and exits"; keep
the two cron lines (README, `docs/components.html`; `docs/monitoring.html` has the
`cleanup --quiet` line), which now work as written.

### Configuration file (DOC-05)

* Path `/etc/lyrebird/storage.conf`; `LYREBIRD_STORAGE_CONFIG=FILE` names another one;
  `LYREBIRD_STORAGE_CONFIG=` (empty) means none. A missing default file is fine, a missing
  named file is a reported problem. `status` prints `Config file: PATH|none`.
* **Data, never sourced.** KEY=value lines, `#` comments, blank lines; value bare,
  `'single-quoted'` or `"double-quoted"`, literal (`$`, backticks, backslashes in double
  quotes are refused, in single quotes they are text), optional `# comment` after it (the
  documented block has inline comments, so they must work); BOM and CRLF accepted; 64 KiB,
  4096 characters per line, 100 problems at most. Same forms and messages as the stream
  manager's device-config parser (D3).
* **Keys (allowlist)**: `LYREBIRD_RECORDING_DIR` (alias `RECORDING_DIR`), `LYREBIRD_LOG_DIR`
  (alias `LOG_DIR`), `LYREBIRD_TEMP_DIR`, `LYREBIRD_BUFFER_DIR`, `MEDIAMTX_LOG`,
  `RECORDING_RETENTION_DAYS`, `LOG_RETENTION_DAYS`, `TEMP_RETENTION_HOURS`,
  `DISK_WARNING_PERCENT`, `DISK_CRITICAL_PERCENT`, `DISK_EMERGENCY_PERCENT`,
  `MIN_FREE_SPACE_MB`, `MAX_LOG_SIZE`, `LYREBIRD_CLOCK_SANE_EPOCH`,
  `LYREBIRD_ACTIVE_SEGMENT_SECONDS`: every setting the script has, by the name of its
  environment variable (the documented block uses six of them). Anything else (`PATH`, `IFS`,
  `DRY_RUN`, `LD_PRELOAD`, `export X=...`, shell commands) is reported as
  `FILE:LINE: KEY: unknown setting (expected: one of ...)` and ignored.
* Values are validated like the environment's (whole numbers for numbers, then the script's
  existing clamps and defaults; directories made absolute). In the **file** a directory must
  be absolute (a file under /etc has no working directory); relative values stay valid in the
  environment.
* **Precedence: environment > file > default**; in the file `LYREBIRD_RECORDING_DIR`
  beats `RECORDING_DIR` whichever line is first.
* **Deviation from the brief**: `RECORDING_DIR` / `LOG_DIR` are aliases **in the file only**,
  not environment variable names. A variable called `LOG_DIR` or `RECORDING_DIR` in the
  environment of some other program must not become a directory a deletion tool works in (the
  U8 history in `docs/ENGINEERING-REVIEW-2026-07.md`). README "Configuration: Environment
  variables or `/etc/lyrebird/storage.conf`" followed by one block must say: the block is the
  file; as environment variables use `LYREBIRD_RECORDING_DIR` / `LYREBIRD_LOG_DIR`
  (and the other names unchanged).
* A file that is **writable by everyone, or owned by a user other than root (or the user
  running the script), is not read** (it decides what is deleted): reported, exit 4.
* A line that is not accepted is reported (stderr, with file and line), ignored, the run goes
  on with the other lines and the defaults, and finishes with status 4 and "Finished, but N
  line(s) of FILE were not accepted and ignored".
* **Upgrade**: an `/etc/lyrebird/storage.conf` written from the old documentation was ignored
  until now; it takes effect with this version (its `RECORDING_DIR` is now managed, its
  retention applies). Say so in the CHANGELOG.
* The test suite sets `LYREBIRD_STORAGE_CONFIG=` (empty) in `scratch_setup` and
  `storage_helper.bash`, so it never reads the host's file.

### X-29 (R)

* **Symlinked directories.** `LYREBIRD_LOG_DIR`, `LYREBIRD_TEMP_DIR` and the directory of
  `MEDIAMTX_LOG` may be symlinks (a log directory moved to another volume,
  `/var/log -> /var/volatile/log`): every `find` now uses `-H` like the recording and buffer
  sites. Symlinks inside the trees are still not followed.
* **Relative directories.** The five paths are made absolute when the script loads (a
  relative value is relative to the start directory, as before), so
  `LYREBIRD_RECORDING_DIR=-rec` is no longer read as a `find` option ("Cleaned 0 recording
  file(s)" with a 45-day-old file left, exit 0). `MEDIAMTX_LOG_DIR` of a log named without a
  directory was the file name itself.
* **A listing that fails is counted** (`find ... 2>/dev/null` is gone): find's own message
  stays on stderr, the log gets `Cannot list DIR completely: find exited with status N`, the
  run ends with `Run finished with N directory listing(s) that failed ...` and **status 3**;
  the readable part of the tree is still cleaned. `-ignore_readdir_race` keeps a segment that
  the recorder removes mid-listing from counting as a failure (not testable
  deterministically). A configured temp / log / MediaMTX-log directory that does not exist
  is skipped (nothing to clean), not a failure. `status` prints the same messages, an
  "(incomplete: ...)" line, and no longer stops after "Recordings:" when a subdirectory is
  unreadable (see below).
* **Stale `*.tmp` files** (`truncate_large_logs`) go through `safe_delete` (counted, logged
  with rm's reason, listed in a dry run), files and symlinks as `-delete` removed them.
  A line "Removed N stale temp file(s)" is logged when any.

### Defects found while doing this (all P3, all fixed with a test unless noted)

* `--dry-run cleanup` **removed empty directories** (`rec/stream1`, ...) of the recording
  tree: the sweep did not look at `DRY_RUN` (R; commit "--dry-run no longer removes empty
  directories"). A dry run now lists them.
* `--dry-run` also **deleted stale `*.tmp` files** (`find -delete`; R). Fixed with the
  `safe_delete` change.
* `status` run as a user that cannot read a subdirectory of the recording tree **exited 1
  right after "Recordings:"**, printing nothing more (`du` under `pipefail`+`errexit`; R as
  uid 65534). Fixed.
* `MEDIAMTX_LOG_DIR` for a log named without a slash was the name itself (R). Fixed.

### Not fixed (residual)

* `truncate_large_logs` still truncates in place with `cat tmp >log 2>/dev/null || true` and
  `rm -f tmp || true`: a refused truncation is not counted (not part of X-29).
* The empty-directory sweep can still remove a stream directory in the instant between the
  wrapper's `mkdir -p` and FFmpeg's first segment (as in `storage.md`); the sweep's own
  failure (for example `ENOTEMPTY` from that very race) now counts as a listing failure.
* No lock between concurrent storage runs (as in `storage.md`).
* `status` prints one error pair per listing (two listings of the recording tree): the same
  unreadable directory is reported twice.

---

## Defects found in other areas (not fixed here)

* **`lyrebird-metrics.sh --serve`: "serve: requests that follow each other are all answered,
  each by a freshly armed listener [LB-18]" is flaky on the unchanged script**: 3 of 40
  runs alone fail, either bash 5.2.21 aborting on SIGTERM with
  `*** longjmp causes uninitialized stack frame ***` (server exit status 134) or the first
  request getting no answer (`status=none`). Measured on the pre-change script. P3 for the
  tests, possibly a real server shutdown crash (bash bug in `read -t` interrupted by the
  `exit 0` trap); the metrics owner should look (re-run the test alone before calling it a
  regression).
* **Metrics and the manager name the stream directory differently**: the exporter reads
  `FFMPEG_PID_DIR` only, the manager `MEDIAMTX_FFMPEG_DIR` (README, `docs/configuration.html`);
  an operator who moves the manager's directory gets no stream metrics, silently (P3, not
  fixed: not part of X-30). `PID_FILE` now falls back to the manager's `MEDIAMTX_PID_FILE`.
* `lyrebird_stream_manager_up` is the state of the **MediaMTX PID the manager recorded**
  (`/run/mediamtx-audio.pid`), not of the manager script; the name is historical (docs:
  say what it is).

---

## Register (`docs/remediation-status.json`), for the lead

X-30, X-29, DOC-05: status `fixed`; tests (exact titles):

X-30:
* a large /v3/info body that names the version early still reads as an API that is up: no SIGPIPE of echo into grep -q under pipefail [X-30]
* the mediamtx collector needs no pgrep: without it the scrape is complete and no tool is reported missing [LB-18, X-30]
* every test of `tests/test_metrics_process_identity.bats` and `tests/test_metrics_api_budget.bats` (21 titles, all ending in `[X-30]`)

X-29: the 13 tests of `tests/test_storage_scan.bats` (all end in `[X-29]`).
DOC-05: the 9 tests of `tests/test_storage_cli.bats` and the 9 of `tests/test_storage_config.bats` (all end in `[DOC-05]`).

LB-18 and X-17 name "without pgrep the mediamtx collector fails visibly and no false
lyrebird_mediamtx_up 0 is published [LB-18]", which no longer exists: replace it by the
"the mediamtx collector needs no pgrep ..." title above.
