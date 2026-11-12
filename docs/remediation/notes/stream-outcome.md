# Stream manager start outcome, status file, empty start and reconcile notes (for the documentation pass)

Findings LB-03, LB-07, X-03, X-04, X-27, LB-05 (monitor part), the exit-trap
marker defect found by the ownership work; decisions D4 and D5. Code:
`lyrebird-stream-manager.sh` ("Start settings", "What a run has started",
"Stream outcome and status file" sections, `start_streams_and_report`,
`start_all_ffmpeg_streams`, `monitor_streams`, `monitor_cycle`,
`monitor_mediamtx_absent`, `cleanup`, `show_status`, `show_help`). Tests (all new
unless noted): `tests/test_stream_outcome.bats` (13), `tests/test_stream_status.bats`
(17), `tests/test_stream_reconcile.bats` (16), `tests/test_stream_monitor_lock.bats` (5),
the live test "start reports what publishes ..." at the end of
`tests/test_mediamtx_live.bats` with its driver `tests/outcome_e2e.bash`, the shared
stage `tests/manager_stage.bash`; changed: `tests/test_stream_manager_ownership.bats`
and `tests/test_stream_manager_locks.bats` (hardware/API seams only, see below),
`tests/lifecycle_e2e.bash` (two environment variables), `tests/scratch_tmpdir.bash`
(`LYREBIRD_STATE_DIR` into the scratch directory).
`tests/README.md` (not edited here): add rows for the four new `.bats` files (13, 17,
16 and 5 tests), count the new live test under `test_mediamtx_live.bats`
(4 + 3 live) and re-count the total with `bats --count tests/`.

## What the documentation must now say

### `start` tells the truth (D4)

- **Exit status of `start`** (and so of `restart`, the unit's `ExecStart`, the menu and
  the wizard): `0` = the start policy is met, **`9` (new, `E_STREAMS_FAILED`) = it is
  not**. "Met" means streams are *publishing*, i.e. MediaMTX's API says the path is
  ready after the stream was launched and given
  `STREAM_VALIDATION_ATTEMPTS x STREAM_VALIDATION_DELAY` seconds (default 15 s) to
  appear; a running FFmpeg or wrapper is not enough. Everything that says `start` is
  "best effort" or "returns 0 after printing `[FAIL]`" is out of date (README
  "Exit Codes" near line 1583, `docs/components.html` Exit Codes, the code comment
  "Best-effort return behavior for partial stream failures" in the v1.4.0 history entry).
- **`LYREBIRD_START_POLICY`** (environment): `degraded` (default) = exit 0 when at least
  one stream is publishing; `strict` = only when the stream of every detected device is.
  Any other value is refused before anything is touched: `Invalid LYREBIRD_START_POLICY
  '<v>': use degraded ... or strict ...`, exit `4`. With no device at all the start is
  successful under both (below).
- **A failed start cleans up after itself, and only after itself.** When the policy is not
  met `start` stops the stream wrappers and the MediaMTX *that run* launched (by identity,
  exactly like `stop`), records the outcome, and exits 9. A stack that was already running
  (the repeated `start` of LB-01) is never touched, even when the repeated start fails
  under `strict`: only wrappers that run launched are stopped. The desired-state marker
  stays (below), so the monitor may try again.
- **The output** of `start` keeps the `=== Available RTSP Streams ===` list with `[OK]` /
  `[FAIL]` per stream, and `[FAIL]` lines now carry the reason: `(failed: <last_error>)`.
  Log lines: `Started in degraded mode: k of n streams are publishing (policy degraded)`,
  `Start failed: k of n streams are publishing (policy strict)` followed by one
  `  <stream>: <reason>` line per stream that is not.
- **New dependency: `curl`** (`check_dependencies` now lists `ffmpeg jq arecord curl`,
  exit 3 `Missing dependencies: curl`). The installer already requires it; the
  README's dependency list for the manager should say so.

### The status file and `status --json` (D4, D5)

- **`/run/lyrebird/status.json`**, overridable with `LYREBIRD_STATUS_FILE`; its directory
  is `LYREBIRD_STATE_DIR` (default `/run/lyrebird`, mode 0755 when the manager creates
  it). The file is mode 0644, written atomically (temporary file in the same directory,
  renamed; no fsync: `/run` is a tmpfs) by `start`, `stop`, `force-stop`, `monitor` and
  `status`, so a reader never sees a partial document. An unwritable location (a run
  without root) never fails the command. The documented consumers (orchestrator, metrics,
  alerts) must treat a missing file as "unknown", and use `timestamp_epoch` for staleness:
  the file describes the node as of the last command that ran, the monitor refreshes it
  every cycle (5 min under the shipped cron line).
- **Schema (`schema_version` 1)**:
  ```json
  {"schema_version":1,"timestamp":"2026-11-11T22:10:44Z","timestamp_epoch":1788000000,
   "command":"monitor","overall":"degraded","policy":"degraded","stream_mode":"individual",
   "mediamtx":{"running":true,"pid":1234},
   "streams":[{"device":"usb-Blue_Yeti","card":"3","path":"yeti","configured":true,
               "process_alive":true,"path_ready":true,"bytes_flowing":true,"last_error":null},
              {"device":"usb-Mic2","card":"4","path":"mic2","configured":false,
               "process_alive":false,"path_ready":false,"bytes_flowing":false,
               "last_error":"no stream wrapper is running for this stream"}]}
  ```
  - `command`: the command that wrote the file (`start`, `stop`, `force-stop`, `monitor`,
    `status`). `policy`: `degraded`, `strict` (or `invalid` if the variable is wrong).
    `stream_mode`: `individual` or `multiplex` (multiplex when `-m multiplex` was given or
    a multiplex wrapper is running).
  - `overall`: `ok` (every expected stream is publishing), `degraded` (some are), `failed`
    (none is, **or** MediaMTX is down although the node is meant to run: `start` was run and
    `stop` was not), `waiting_for_devices` (MediaMTX is up, no device detected), `stopped`
    (down on purpose: no desired-state marker). `overall` does not depend on the policy; the
    policy only decides `start`'s exit status.
  - A stream is **expected** for every detected device (individual mode) or once for the
    set of devices (multiplex: `device` and `card` are comma-joined, `path` the sanitized
    multiplex name). A `stopped` node lists no stream. A `failed` node (meant to run, not
    running) still lists them, each with its reason.
  - `configured`: the stream's wrapper script exists and a wrapper was launched (PID file).
    `process_alive`: that wrapper is running and provably this manager's. `path_ready`:
    MediaMTX's API reports the path ready (`available`, else the deprecated `ready`).
    `bytes_flowing`: the path's inbound byte counter grew between two samples
    `LYREBIRD_FLOW_SAMPLE_SECONDS` apart (default 3; `0` skips the second sample and gives
    `null`). Each of the four is `true`, `false` or **`null` = not known** (the API did not
    answer: unreachable, 401/403, 5xx, empty body; `last_error` then says so). A path
    nobody publishes to is not instantiated by MediaMTX (404) and is `false`, not `null`.
  - `last_error`: `null` while the stream publishes with bytes flowing. Otherwise the reason
    the command that wrote the file found: a launch failure ("the stream could not be started
    (see .../<stream>.log and the manager log)"), a skipped device ("device node
    /dev/snd/controlC<N> does not exist", X-27), "MediaMTX is not running", "the MediaMTX
    API did not answer", "no stream wrapper is running for this stream", "the stream
    wrapper is running but its path is not ready in MediaMTX (nothing is publishing)", "the
    path is ready but its inbound byte counter did not grow in <n>s", or, after a failed
    start under `strict`, "was publishing; stopped again because the start failed under
    policy 'strict'". It is a string for a human, not an enumeration. (It is per command: a
    later `status` computes its own; there is no sticky error history.)
  - **The inbound counter's field name differs between MediaMTX versions**; checked on the
    real binaries: 1.15.0 reports `bytesReceived` only; 1.18.0, 1.19.0 and 1.21.1 report
    `inboundBytes` and `bytesReceived`. The manager reads `inboundBytes` first and falls
    back to `bytesReceived`. (`ready` is deprecated in favour of `available`; both are still
    emitted, the existing tolerant parser handles either.)
- **`status --json`** prints exactly this document (computed live, exit 0) and also
  rewrites the file. **`status`** (human) keeps its old output and appends the per-stream
  state (`<stream>: path ready, bytes flowing`, `path not ready, no bytes flowing`,
  `last error: ...`), `Overall: <state> (start policy: <policy>)` and `Status file: <path>`;
  an unknown option is exit 1. `status` still exits 0 whatever the state: use
  `status --json` or the file to decide. A `status` run costs `LYREBIRD_FLOW_SAMPLE_SECONDS`
  extra seconds when a stream is ready.
- **Desired-state marker**: `LYREBIRD_STATE_DIR/desired-running` (override
  `LYREBIRD_DESIRED_MARKER`), one line `<epoch> <pid> <command>`. Written by `start` once it
  has passed the lock and the ownership check (a start refused with exit 5 or 8 does not
  write it), kept across `restart`, removed by `stop` (before it stops anything, so an
  interrupted stop is not undone) and by `force-stop`. It is deliberately *not* removed by
  a failed start. A node that was started by a release without this marker has none until
  its next `start`, so until then the monitor does not restart a MediaMTX that dies.

### Empty start and reconcile (D5)

- **`LYREBIRD_ALLOW_EMPTY_START`** (default `true`; `true|yes|1|on`, `false|no|0|off`,
  anything else is exit 4): with no USB audio device `start` brings MediaMTX up with no
  stream, logs `... waiting for devices`, writes `overall: waiting_for_devices` and exits
  **0**; `false` keeps the old behaviour (exit **6**, MediaMTX not started). It applies to
  a fresh start and to a repeated start of a running MediaMTX. The README section "No USB
  Devices Found" (line ~835) and the troubleshooting text that says the service will not
  start without a device are out of date.
- **The USB settling wait no longer calls an empty list stable (X-03)**: it waits for the
  first device up to its deadline (`USB_STABILIZATION_DELAY`, `RESTART_STABILIZATION_DELAY`),
  then proceeds with none (empty start allowed) or fails (exit 6). A node whose hub shows up
  late therefore costs one settling window, not a failed unit.
- **The monitor reconciles 0 -> 1 -> N devices.** Zero devices with MediaMTX up is `waiting`:
  the monitor logs it and exits **0** (it used to exit 6; 6 now only with
  `LYREBIRD_ALLOW_EMPTY_START=false`). A device that appears, or whose wrapper died, gets a
  stream on the next cycle (the existing per-stream checks), bounded by the per-stream cron
  restart budget (`CRON_RESTART_MAX_PER_HOUR`, default 6/hour). **Multiplex mode:** a device
  that is *added* now restarts the multiplex stream (the wrapper captures the devices it was
  started with); the set it was started with is recorded in `<wrapper dir>/<stream>.devices`.
  A device that vanishes still ends the wrapper by itself and the monitor restarts it with
  the remaining ones.
- **The monitor brings MediaMTX back** when it is gone *and the desired-state marker is
  present* (`start` was run, `stop` was not): it re-runs the idempotent start under the
  lifecycle lock, logs `MediaMTX is not running although the node is meant to run ...;
  starting it again (n/6 restarts this hour before this one)` and exits 0 on success, 7 if
  that start failed. Bounded by the same budget as the streams, counted per hour under
  the key `_mediamtx` (`${CRON_RESTART_STATE_DIR}/_mediamtx.restarts`); when it is used up:
  `... restart budget (6/hour) is used up; not starting it`, exit 7. Without the marker
  (stopped on purpose, never started) nothing is started and the exit stays 7 with
  `MediaMTX is not running - skipping stream health check`. Under systemd the unit's own
  `Restart=on-failure` normally acts first (the manager is `Type=forking` with `PIDFile=`);
  the monitor is what remains when the unit's start limit is exhausted, or on a node
  without systemd. A MediaMTX started by the monitor lives in cron's cgroup, not the
  unit's; `stop`/`systemctl stop` still stop it (by PID file and identity), and a later
  `systemctl start` finds it running and leaves it alone (LB-01).

### The monitor takes the lifecycle lock (LB-05)

- `monitor` (the cron line) waits for the lifecycle lock `MONITOR_LOCK_TIMEOUT` seconds
  (default 5). If a `start`/`stop`/`restart`/`force-stop` holds it, it logs `Monitor: a
  lifecycle command ... is in progress, busy, skipping this cycle (PID n (start time t):
  <command>)` and **exits 0 without touching anything** (no restart, no status refresh).
  The lock is held only around the stream checks and restarts (`monitor_streams`) and
  released before the status refresh; the resource checks (disk, memory, network ping) run
  before it is taken. Corollary for the unit/monitoring phases: any long probe added to the
  monitor (the silence/level probe of D6, a ping) must run before `monitor_cycle` takes the
  lock or after it releases it, because a concurrent `stop` waits only `STOP_LOCK_TIMEOUT`
  (5 s) and then refuses with exit 5. The cron line's own `/run/mediamtx-monitor.lock` is
  unchanged. Remove the "monitor does not take the lifecycle lock" paragraph from
  `stream-locks.md`'s consolidated text.

### The cleanup marker (found by the ownership work)

- The exit trap used to create `/run/mediamtx-audio.cleanup` after **any** non-zero exit of
  `start`/`stop`/`restart`/`force-stop`. Every wrapper stops at its next loop iteration
  while that file exists, so a failed `start` (missing dependency, non-root user, bad
  setting, any refusal) on a node with a healthy stack ended its wrappers the next time an
  FFmpeg exited. Now the marker exists only when a run was interrupted (a signal, or an
  error under `set -e`) **and** could not take down what it had launched; the exit trap
  takes down exactly what *that run* launched first (and removes the marker when that
  worked). An ordinary failed command leaves no marker. Anything in the docs that says a
  failed command "leaves a cleanup marker that the next start handles" should say this.
- `INT`, `TERM` and `QUIT` now end the run with the conventional `128+N` status (130, 143,
  131). The old handler exited with the status of whatever command had run last, usually 0.

### Smaller changes

- **X-04**: the monitor checks that the card can be opened (`check_alsa_device_available`)
  *before* it charges the restart budget: a card that is detected but cannot be opened no
  longer uses up `CRON_RESTART_MAX_PER_HOUR`. (Multiplex has no such pre-check; it fails fast
  in `start_ffmpeg_multiplex_stream`, charged as before.)
- **X-27**: a detected device without `/dev/snd/controlC<N>` is no longer skipped silently:
  `Not starting <device> (card N): device node /dev/snd/controlC<N> does not exist`, the
  stream's `last_error`, and it counts as a stream that is not publishing (so `strict` fails
  and `degraded` is degraded). `Successfully started all 0/1` can no longer be printed.
- `start_all_ffmpeg_streams` still returns 0 whatever happened (it only logs the summary);
  what failed is recorded per stream (`STREAM_LAST_ERROR`) and what counts is what the API
  says is publishing, judged by `start_streams_and_report` under the policy.

### Complete exit-code table (`--help` carries the same; add to README "Exit Codes", `docs/components.html`)

| Code | Name | Meaning |
|------|------|---------|
| 0 | | Success. `start`: policy met, or no device and empty start allowed. `monitor`: healthy, waiting for devices, or skipped because a lifecycle command was running. `status`, `config`, `help`: always. |
| 1 | `E_GENERAL` | General error: `force-stop --kill-all` without `--yes`, unknown option, MediaMTX did not come up, port already in use, `stop` could not stop something, not run as root |
| 2 | `E_CRITICAL_RESOURCE` | Critical resource state (monitor; the cron line restarts the service) |
| 3 | `E_MISSING_DEPS` | Missing dependency (`ffmpeg jq arecord curl`, the MediaMTX binary) |
| 4 | `E_CONFIG_ERROR` | Invalid `LYREBIRD_START_POLICY` / `LYREBIRD_ALLOW_EMPTY_START`, invalid device configuration, configuration generation failed |
| 5 | `E_LOCK_FAILED` | Another lifecycle command holds the lock; nothing was changed. (The monitor skips a busy lock with exit 0; it returns 5 only when the lock file cannot be opened.) |
| 6 | `E_USB_NO_DEVICES` | No USB audio device: `start` or `monitor` with `LYREBIRD_ALLOW_EMPTY_START=false` |
| 7 | `E_MEDIAMTX_DOWN` | MediaMTX not running (monitor): not meant to run, restart budget used up, or the restart failed |
| 8 | `E_OWNERSHIP` | Another MediaMTX owns the node; `start`/`restart` refused, nothing changed |
| 9 | `E_STREAMS_FAILED` | **New.** `start` did not meet `LYREBIRD_START_POLICY`; what that run started was stopped |
| 10 | `E_MONITOR_DEGRADED` | Streams degraded (monitor) |
| 128+N | | Terminated by signal N (130 SIGINT, 143 SIGTERM, 131 SIGQUIT) |

The `--help` text's `monitor` line used to list the wrong codes (`3=MediaMTX down`,
`7=no devices`); it now matches this table.

## What the other areas must do (interfaces)

- **Orchestrator / wizard (LB-21)**: read `status --json` (or the file) instead of state
  captured before the start step; treat `start`'s `9` as "streams failed", `6` as "no devices
  (empty start disabled)", `8` as "another MediaMTX owns the node", `5` as "busy, try again".
  The menu's `execute_script ... start || true` still masks the code after the error was
  printed; the wizard's success branch can now trust it.
- **Unit work (D12)**: `/run/lyrebird` must be writable and should survive `stop`:
  `RuntimeDirectory=lyrebird` with `RuntimeDirectoryPreserve=yes` (otherwise systemd removes
  it when the unit stops and takes `status.json` and the cron restart budgets with it; the
  `desired-running` marker is removed by `stop` anyway). `ReadWritePaths=` already lists
  `/var/run`. The cron line's comment block in `create_systemd_service` (`Exit 6 ... LOG ONLY`,
  `Exit 7: MediaMTX not running - LOG ONLY`) should say that exit 6 is now only produced with
  `LYREBIRD_ALLOW_EMPTY_START=false`, that exit 7 means the monitor could not (or may not)
  bring MediaMTX back, and that the monitor restarts MediaMTX itself when the node is meant
  to run. If the unit is changed to exit non-zero for 9 under `Restart=on-failure`, the
  start-limit budget (5 starts / ~100 s in the sample unit) applies to failures of the policy
  as it did to the old exits; with the empty start the late-hub case no longer consumes it.
- **API/readiness work**: `mediamtx_path_info <path>` is the single function in this area
  that asks MediaMTX's API (a `curl -s --max-time 3 -w '\n%{http_code}'` on
  `<api base>/paths/get/<path>`; return 0 = object on stdout, 1 = 404, 2 = not known). Route it
  through the new helper; keep those three return values. `wait_path_ready` and
  `stream_outcome_probe` are its only callers (besides tests that stub it).
  `wait_for_mediamtx_ready` still probes `localhost:9997` itself (not changed here).
- **Naming work (D13)**: this area calls `generate_stream_path` (individual) and
  `multiplex_stream_path` (a small helper: `sanitize_path_name` of `MULTIPLEX_STREAM_NAME`
  plus the `stream_` prefix for a leading digit, as `start_ffmpeg_multiplex_stream` and the
  monitor compute it) to know a stream's path; when `canonical_stream_name` lands,
  `multiplex_stream_path` is the one place to redefine. `start_streams_and_report` used to
  validate the *raw* multiplex name (LB-04); it now uses the sanitized path.
- **Wrapper generation**: the wrapper's cleanup-marker check is unchanged (it stops at the
  next loop iteration while the marker exists), and `start_ffmpeg_stream`'s own validation
  and its bare `kill "$pid"` on failure are unchanged. Two consequences seen in the tests:
  a wrapper that `start_ffmpeg_stream` stopped for failing validation is still finishing its
  signal handler for up to a second after `start` returned, and it leaves its
  `<stream>.pid.id` record behind (harmless: `cleanup_stale_processes` removes records whose
  PID file is gone). The multiplex device-set record `<stream>.devices` is written by
  `start_multiplex_stream` (a wrapper around `start_ffmpeg_multiplex_stream`), not by the
  launcher itself.

## Behaviour that operators will notice

- `start` on a node whose microphone is broken now fails (exit 9) where it used to print
  `[FAIL]` and succeed. Under `Restart=on-failure` systemd will retry it; the node with one
  good and one broken microphone is unaffected (degraded, exit 0).
- `start` takes `STREAM_VALIDATION_ATTEMPTS x STREAM_VALIDATION_DELAY` seconds longer in the
  worst case (a stream that never shows up) and, when a stream is ready, one
  `LYREBIRD_FLOW_SAMPLE_SECONDS` sample. `status` and every monitor cycle likewise cost one
  sample when a stream is ready (the lock is not held during it).
- The monitor logs `waiting for devices` (INFO) instead of `No USB audio devices detected`
  (WARN, exit 6) on an empty node.
- After `systemctl stop`, `status.json` says `stopped`; after a crash it says `failed` with
  `mediamtx.running: false` until the monitor (or the unit) has restarted it.

## Removed / renamed / added internals (for anyone reading the code)

- Added: `E_STREAMS_FAILED`, `RUN_DIRTY`, `RUN_STARTED_MEDIAMTX`, `RUN_STARTED_STREAMS`,
  `STATUS_PENDING`, `on_terminate_signal`, `install_lifecycle_traps`, `rollback_failed_start`,
  `run_track_stream`, `stream_wrapper_alive`, `multiplex_stream_path`, `start_policy`,
  `allow_empty_start`, `start_settings_check`, `_bool_setting`, `mediamtx_path_info`,
  `mediamtx_json_inbound_bytes`, `device_node_exists`, `effective_stream_mode`,
  `stream_outcome_{reset,add,expect,probe,collect}`, `stream_derived_error`,
  `wait_path_ready`, `outcome_overall`, `json_string`, `json_string_or_null`,
  `status_document`, `state_file_write`, `status_publish`, `status_collect_live`,
  `status_refresh`, `status_print_json`, `status_print_summary`, `desired_{present,write,remove}`,
  `monitor_card_available`, `monitor_mediamtx_absent`, `monitor_cycle`,
  `multiplex_devices_signature`, `start_multiplex_stream`, `multiplex_set_changed`;
  settings `RUN_STATE_DIR`, `STATUS_FILE`, `DESIRED_MARKER`, `FLOW_SAMPLE_SECONDS`,
  `MONITOR_LOCK_TIMEOUT`.
- Changed: `cleanup` (marker semantics, rollback, failed-start status), `start_mediamtx`
  (settings check, desired marker, empty start), `start_streams_and_report` (outcome and
  policy), `start_all_ffmpeg_streams` (X-27, return value), `wait_for_usb_stabilization`
  (X-03), `monitor_streams` (absent MediaMTX, empty node, card check before the budget,
  multiplex set change), `show_status`/`stop_mediamtx`/`force_stop_mediamtx`/`restart_mediamtx`
  (status and desired marker), `check_dependencies` (curl), `show_help`, the `status` and
  `monitor` branches of `main` (one line each).
- `validate_stream` is unchanged and still used by `start_ffmpeg_stream`.

## Not done here / validation that needs hardware or a real systemd

- Not verified on hardware: the real USB hot-plug sequence (the tests plug and unplug a
  fake device tree and a file-backed device list), real ALSA behaviour of a card that is
  detected but busy (stand-in), `start` against a real hub that appears after the unit's
  start-limit budget is spent (LB-07's "real systemd start-limit timing at boot with a late
  hub" in the register's list), the interplay of the monitor-started MediaMTX with the
  unit's cgroup on a real systemd manager.
- A `SIGTERM` that arrives in the half second between a wrapper being spawned and its PID
  being recorded cannot be rolled back (the wrapper is not yet tracked); it is found by
  `force-stop --kill-all`. Not closed here because the spawn is in the wrapper-generation
  code.
- The multiplex branches of the monitor still charge the restart budget without an ALSA
  pre-check (X-04 is individual mode).
- No sticky `last_error`: a stream's reason is what the writing command observed.
- The script's version header (`1.5.1`) and its version-history comment are not bumped here
  (the other workers edit the same lines); the lead may do it at merge.
