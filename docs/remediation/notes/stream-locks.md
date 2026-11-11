# Stream manager locking notes (for the documentation pass)

Findings LB-05 and X-02, decision D2. Code: `lyrebird-stream-manager.sh`
("Locking" section, `spawn_detached`). Tests: `tests/test_stream_manager_locks.bats`
(37 tests; two inline-copy lock tests were removed from `tests/test_stream_manager.bats`,
so the stream-manager row of `tests/README.md` goes from 39 to 37 tests and a new row
for `test_stream_manager_locks.bats` is needed).

## What the documentation must now say

- **Never delete a lock file.** `README.md` (the "Remove PID and lock files" block, about
  line 2385) and `docs/advanced.html` / `docs/troubleshooting.html` ("Remove stale lock
  file", `sudo rm -f /run/mediamtx-audio.lock ...`) tell the operator to remove
  `/run/mediamtx-audio.lock` and `/run/mediamtx-monitor.lock`. Removing a lock file that
  another process holds gives the next process a different lock, which is exactly the
  defect LB-05 fixes. There is no such thing as a stale lock any more: the kernel drops
  the `flock` when its holder exits, however it exits. Replace the advice with: read the
  "Failed to acquire lock" message, which names the holder (pid, start time, command),
  and stop that process or wait for it. `docs/ADR.md` line ~207 ("stale lock
  detection") and `docs/architecture.html` ("Stale locks possible after crash; cleanup
  logic required") describe the old design.
- **`LOCK_STALE_THRESHOLD` is removed.** If it is set in the environment the manager logs
  one WARN line per process ("LOCK_STALE_THRESHOLD is deprecated and ignored ...") and
  does nothing else with it. It was never in the README configuration tables; mention
  it only in the changelog.
- **Lock file contents.** `/run/mediamtx-audio.lock` (`MEDIAMTX_LOCK_FILE`) and
  `${MEDIAMTX_CONFIG_DIR}/.config.lock` hold one informational line,
  `<pid> <starttime>` padded with spaces to 64 characters, where `starttime` is field 22
  of `/proc/<pid>/stat` (clock ticks since boot). It is overwritten in place by whoever
  holds the lock, never truncated by anyone, and is never used to decide whether the lock
  is held. The files are created on first use and are never removed (not by `stop`, not by
  `force-stop`, not by the cleanup that `start` runs). `/run/mediamtx-monitor.lock` (the
  cron `flock -n` line) is unchanged.
- **New variable `STOP_LOCK_TIMEOUT`** (seconds, default `5`, non-numeric values fall back
  to 5): how long `stop` and `force-stop` wait for the lifecycle lock. `LOCK_ACQUISITION_TIMEOUT`
  (default 30, used by `start`/`restart`) is unchanged.
- **`stop` and `force-stop` now refuse instead of overlapping another command.** If the
  lock cannot be taken within `STOP_LOCK_TIMEOUT` seconds, `stop` (previously: "Could not
  acquire lock, proceeding with stop anyway") and `force-stop` (previously: no lock at all)
  log the holder, change nothing, and exit **5** (`E_LOCK_FAILED`, already in the exit-code
  table). Messages: `Refusing to stop: another lifecycle command holds the lock (<path>)`,
  `Refusing to force-stop: another lifecycle command holds the lock (<path>)`.
  `force-stop` has no override option in this change; the lifecycle work adds
  `--kill-all --yes`. `restart` takes the lock once and keeps it across its stop and its
  start (a second `acquire_lock` in the same process is a no-op).
- **A `start` that cannot get the lock exits 5 without leaving the cleanup marker.** It used
  to leave `/run/mediamtx-audio.cleanup`, which made the *next* `start` run
  `cleanup_stale_processes` and tear down the healthy stack that held the lock.
- **Failure messages** (stderr and the log): `Failed to acquire lock after N seconds`
  (unchanged) followed by `Lock <path> is held; PID <pid> (start time <t>): <command line>`
  or `... is held; last recorded owner PID <pid> (start time <t>) is not running` (the
  recorded PID is only believed when its start time still matches, so a recycled PID is
  never named as the owner) or `... is held; no owner recorded`, then
  `Processes with the lock file open: <pid>(<comm>) ...` (the real holders, found by scanning
  `/proc/*/fd`). Config lock: `Failed to acquire config lock` plus the same holder line.

## Behaviour that operators will notice

- **Upgrade from a release that leaked the lock descriptor.** Before this change MediaMTX,
  the wrappers and their FFmpeg children inherited the lock descriptor, so on a node that
  was started by the old code the lock is held by those children until the service is
  restarted. The first `stop`/`force-stop` after an in-place upgrade therefore waits
  `STOP_LOCK_TIMEOUT` seconds and refuses with the holder list
  (`Processes with the lock file open: <mediamtx pid>(mediamtx) ...`). Under systemd,
  `systemctl restart` still works (ExecStop fails, the cgroup is then killed, the new start
  gets a free lock); by hand, stop the listed processes once. Worth one sentence in the
  upgrade notes.
- After a SIGKILL of the manager the lock is free immediately, except for a few seconds if
  an external command the manager was running at that instant (`sleep`, `curl`, `flock`)
  still holds the descriptor: bash cannot open a descriptor close-on-exec.
- Every long-lived child (MediaMTX, per-stream and multiplex wrappers, and so their FFmpeg)
  is now started by `spawn_detached`, which closes every inherited descriptor above stderr.
  That also closes the monitor lock that `flock FILE -c ...` (the cron line in
  `create_systemd_service`) leaves open in whatever the monitor starts: before this change a
  monitor-driven stream restart left `/run/mediamtx-monitor.lock` held by the new wrapper
  for as long as it lived, and every later cron run logged "Monitor already running or
  locked" and did nothing (reproduced with `flock -n F -c '(sleep 2 &)'`: the background
  child holds the lock; `flock -o` closes it). Adding `-o` to that cron line is a possible
  extra hardening but is not needed any more.
- `X-06` (an `exec ... 2>/dev/null` silencing stderr for the rest of the process) is fixed for
  every lock path: after the first `release_lock` the old code lost every later error message
  on stderr, including "Failed to acquire lock".

## Removed / renamed internals (for anyone reading the code)

- Removed: `is_lock_stale`, `LOCK_STALE_THRESHOLD`, the variable `CURRENT_COMMAND` (its only
  reader was `is_lock_stale`).
- Added: `proc_starttime`, `lock_record_owner`, `lock_describe_holder`,
  `lock_list_open_holders`, `lock_open_and_acquire`, `lock_warn_deprecated_settings`,
  `acquire_config_lock`, `spawn_detached`, `STOP_LOCK_TIMEOUT`.
- `acquire_lock [timeout] [force]` keeps its signature and return codes (0/1) and error
  messages; `release_lock` and `release_lock_unsafe` keep theirs.

## Not done here (needs the owner of that area)

- `monitor` (the cron `monitor` command) still does not take the lifecycle lock, so a monitor
  cycle can still overlap a `start`/`stop`. The primitive is ready for it (`acquire_lock <short
  timeout>`, re-entrant, descriptor-safe); the call belongs at the top of `monitor_streams`
  (return `E_LOCK_FAILED` and log "lifecycle operation in progress" when it cannot be taken).
  This was left out on purpose: the monitoring work rewrites that function.
- A `restart` that is refused by the lock (exit 5, nothing stopped) still leaves
  `/run/mediamtx-audio.restart`: `restart_mediamtx` calls `mark_restart` before `stop_mediamtx`
  takes the lock (reproduced). For 60 s the next `start` then treats the node as being in a
  restart (cleanup plus the stabilisation wait). The fix is to take the lock first in
  `restart_mediamtx` (`acquire_lock`, exit 5 on failure, then `mark_restart`; `stop` and `start`
  keep the lock because `acquire_lock` is re-entrant); left to the lifecycle work, which owns
  that function.
- The installer and updater have their own lock helpers (`install_mediamtx.sh`,
  `lyrebird-updater.sh`, `usb-audio-mapper.sh`); they were not part of this change.
