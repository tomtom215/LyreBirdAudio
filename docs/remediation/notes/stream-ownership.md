# Stream manager process ownership notes (for the documentation pass)

Findings LB-01, LB-02, LB-10 (manager part), X-25, X-26, the refused-restart marker
defect; decisions D1 and D11. Code: `lyrebird-stream-manager.sh` ("Process ownership"
section, `start_mediamtx`, `stop_mediamtx`, `force_stop_mediamtx`, `restart_mediamtx`,
`cleanup_stale_processes`). Tests: `tests/test_stream_manager_ownership.bats` (43 tests,
new), the live test at the end of `tests/test_mediamtx_live.bats` (1 test, with its driver
`tests/lifecycle_e2e.bash`), changes to `tests/test_stream_manager_locks.bats` (two
assertions that expected `pkill` now expect none, and the MediaMTX stand-in is a copy of bash
at the configured path, because the manager now identifies MediaMTX by its executable and
argv[1], not by its `comm`) and `tests/process_decoys.bash` (`decoy_spawn_as`,
`DECOY_STDOUT`, and the guarded `kill` lets `kill -0` through: it sends no signal).
`tests/README.md` (not edited here, as for the lock work): add a row for
`test_stream_manager_ownership.bats` (43 tests), count the new live test under
`test_mediamtx_live.bats` (4 + 1 live becomes 4 + 2 live) and re-count the total with
`bats --count tests/`. The installer's own process handling (LB-10 installer part)
is described in `installer.md`; nothing here changes `install_mediamtx.sh`.

## What the documentation must now say

- **`start` is safe to repeat.** On a node where this manager's own MediaMTX is running
  (the PID in `/run/mediamtx-audio.pid` is alive, its start time matches the record next
  to the PID file, its executable is the configured MediaMTX binary and its first
  argument is the configuration file) `start` changes nothing that works: same
  MediaMTX PID, same wrapper PIDs, no outage, no USB settling wait, the configuration is
  not rewritten, no restart marker; exit status 0. It only starts a stream whose wrapper
  is missing (the existing per-stream "already running" check does the rest), so a dead
  wrapper is reconciled by the next `start`. Cleanup (`cleanup_stale_processes`, the USB
  wait) now runs only when the recorded ownership is not intact (PID dead, PID reused,
  not MediaMTX) or on a `restart`. Everything in the docs that says "`start` restarts
  everything", "run `start` again to fix streams" (it still fixes missing ones, without an
  outage) or implies a 15 s pause on repeat is out of date. The monitor's cron line and the
  systemd unit are unaffected.
- **New exit code 8, `E_OWNERSHIP`.** `start` and `restart` refuse, change nothing and exit
  8 when another owner has MediaMTX: `mediamtx.service` is active
  (`systemctl is-active mediamtx.service`), or a process runs the configured MediaMTX
  binary on the configured configuration file without being the process recorded in the
  manager's PID file (a manual run, another unit; its systemd unit is looked up through
  `/proc/<pid>/cgroup` and named when `systemctl is-active` says it is active). Messages:
  `Refusing to start: mediamtx.service is active and owns MediaMTX (stop it first ...)`,
  `Refusing to start: MediaMTX (PID n) is already running on <config> but was not started
  by this script`, `Refusing to restart: ...`. Add 8 to the exit-code tables
  (`README.md` "Exit Codes" near line 1583; `docs/components.html` near line 156; the
  stream manager's own `--help` already has it): `8 - Another MediaMTX owns the node
  (start/restart refused, nothing changed)`. systemd treats it like any failure; because
  nothing was started there is nothing to clean up (no cleanup marker is left).
- **Single owner (D1).** The manager owns MediaMTX and its FFmpeg children. It never
  signals a process it cannot prove it started: `stop`, `force-stop`, `restart`, the
  cleanup that `start` runs and the monitor act only on PIDs recorded in the manager's
  own PID files whose start time still matches and whose running image is the expected
  one (MediaMTX: executable = configured binary and argv[1] = configuration file; wrapper:
  a `bash` whose argv[1] is the stream's generated `<wrapper dir>/<stream>.sh`).
  `mediamtx.service`'s MediaMTX (same binary, same configuration), another installation's
  MediaMTX, an operator's `ffmpeg -i rtsp://localhost:8554/...` and an editor that has a
  wrapper script open are all left alone by every command except the explicit broad kill
  below. `mediamtx.service` and `mediamtx-audio.service` must not both run; the unit work
  adds `Conflicts=mediamtx.service` and drops `Wants=/PartOf=` (D1, D12). Until then the
  manager's refusal is what protects a node that has both enabled.
- **`force-stop` and the new broad kill.**
  - `force-stop` now sends SIGKILL at once to the wrappers (with their FFmpeg) and the
    MediaMTX recorded in the manager's PID files, each only while it is provably the process
    the manager started, and removes the PID files, the generated wrapper scripts and the
    markers. It no longer runs `pkill`.
  - `force-stop --kill-all` is the only broad kill. Without `--yes` it prints a preview and
    exits **1** without signalling anything (and without leaving the cleanup marker): every
    process whose executable is the configured MediaMTX binary (this includes another
    configuration's MediaMTX, `mediamtx.service`'s included), whose command line names a
    file in the wrapper directory (`/var/lib/mediamtx-ffmpeg/...`), an FFmpeg that writes its
    log into the wrapper directory (an FFmpeg orphaned by a dead wrapper), and the children
    of a listed wrapper, each with the reason it is listed. `force-stop --kill-all --yes`
    sends SIGKILL to exactly that list (each PID only while its start time is the one that
    was listed) and then does the normal `force-stop` file cleanup. `--yes` without
    `--kill-all` and any other option are errors (exit 1). With nothing to kill the preview
    says so and still exits 1.
  - `README.md` "Troubleshooting Uninstallation" (around line 2475) tells the operator to run
    `sudo pkill -9 mediamtx; sudo pkill -9 ffmpeg`. Replace it with
    `sudo ./lyrebird-stream-manager.sh force-stop` and, if something is left,
    `sudo ./lyrebird-stream-manager.sh force-stop --kill-all` (read the list) then
    `... --kill-all --yes`. `docs/troubleshooting.html` line 211 (`sudo pkill -f ffmpeg`
    "Clean up zombie FFmpeg processes") likewise: `pkill -f ffmpeg` kills every FFmpeg on the
    machine, including other recorders and readers; the replacement is `stop` or `force-stop`.
    The `force-stop` lines in `docs/components.html` ("Force kill all and clean stale
    files"), `docs/usage.html` and the README should say "kill the processes this manager
    started"; `--kill-all` is the emergency broad option.
- **`stop` no longer runs a pattern kill.** `stop` used to end with
  `pkill -f '^ffmpeg.*rtsp://localhost:8554'`, which also killed any FFmpeg that reads a
  stream. Each stream's wrapper is now stopped together with its FFmpeg (process group,
  then every descendant), SIGTERM first and SIGKILL after the timeout (10 s per stream,
  30 s for MediaMTX), as before. `stop` now exits 1 (and says so) if a wrapper or MediaMTX
  could not be stopped; it used to report success.
- **SIGTERM instead of SIGINT as the first signal.** `terminate_process_group` now sends
  SIGTERM (to the process group of a process that leads one and to every descendant), then
  SIGKILL after the timeout, instead of SIGINT then SIGKILL; the sequence is still
  graceful-then-KILL. Reason: a background job started by a non-interactive shell that has
  no SIGINT trap inherits "ignore SIGINT" (reproduced: `SigIgn 7`). The installed script
  sets such a trap, so its real wrappers do keep SIGINT (measured in the live test:
  `SigIgn 5`, and the old stop took 3 s for two streams plus MediaMTX), but a wrapper started
  from a sourced script could only be stopped by the SIGKILL after the whole timeout, having
  restarted the FFmpeg it had interrupted. The wrapper traps SIGTERM and stops its FFmpeg
  itself; MediaMTX and FFmpeg treat it like SIGINT. In the live test `stop` of two streams and
  MediaMTX now takes 0-1 s (3 s before; the old wait polled once a second, the new one every
  0.1 s).
- **PID files.** The PID file stays a plain PID (systemd's `PIDFile=` and
  `lyrebird-metrics.sh` read it). The manager also writes `<pid file>.id` beside every PID
  file it writes (`/run/mediamtx-audio.pid.id`,
  `/var/lib/mediamtx-ffmpeg/<stream>.pid.id`): `<pid> <starttime>` (field 22 of
  `/proc/<pid>/stat`). Do not delete `.pid` files by hand without it; `rm -f /run/mediamtx*.pid`
  in the README leaves the record behind, which is harmless (it is only read for a PID file
  that exists, and removed by the next cleanup) but incomplete: use `force-stop`. PID files
  written by older versions have no record; their process is accepted while the image check
  holds.
- **`read_pid_safe` (X-26).** A live process whose program name is not `mediamtx`, `bash`
  or `ffmpeg` no longer has its PID file deleted (the old allowlist did that, for example
  for MediaMTX started from a differently named binary). A PID that has been reused is
  recognised by its start time. A process whose `/proc` entry cannot be read (a run without
  root) is "unknown", not "dead": the PID file is kept and nothing is signalled. Non-root
  `status` still prints stream wrappers as "Not running" because `show_status` probes them
  with `kill -0`, which fails with EPERM for root's processes (not changed here).
- **FFmpeg logs (X-25).** Starting, stopping, force-stopping and cleaning up no longer delete
  `/var/lib/mediamtx-ffmpeg/<stream>.log` / `.log.old`. When a new wrapper is started, the
  previous run's `<stream>.log` becomes `<stream>.log.prev.1` and older ones move up to
  `.prev.<N>`; `FFMPEG_LOG_KEEP` (default 3, at most 20, non-numeric falls back to 3, 0 =
  keep none) bounds how many archives are kept. The archives are not named `*.log`, so the
  logrotate stanza `${FFMPEG_PID_DIR}/*.log` does not touch them. Document `FFMPEG_LOG_KEEP`
  in the configuration tables and the post-mortem recipe (`tail /var/lib/mediamtx-ffmpeg/<stream>.log*`).
  Disk use per stream is bounded by the live log, the wrapper's own `.log.old` and
  `FFMPEG_LOG_KEEP` archives.
- **Refused `restart` leaves no marker.** `restart` now takes the lifecycle lock first
  (`LOCK_ACQUISITION_TIMEOUT`, default 30 s) and only then writes `/run/mediamtx-audio.restart`.
  A restart that cannot get the lock exits 5 with `Refusing to restart: another lifecycle
  command holds the lock (<path>)`; before, it left the marker and the next `start` ran the
  cleanup and a stabilisation wait for 60 s. A restart refused for ownership (exit 8) leaves
  no marker either.
- **A leftover cleanup marker no longer tears down a healthy node.** If an earlier command
  exited abnormally and left `/run/mediamtx-audio.cleanup`, `start` used to run the full
  cleanup (kill everything, then restart). It now keeps a MediaMTX it owns and starts what is
  missing; the marker is still removed, and when the MediaMTX is not provably the
  manager's own the cleanup (by identity) runs as before. Note the wrappers still stop at
  the next loop iteration while the marker exists (unchanged wrapper behaviour).
- **The PID file of MediaMTX is written before the readiness wait** (it was written after).
  An interrupted start no longer leaves a running MediaMTX that no PID file names, which the
  manager would now (correctly) refuse to take over (`Refusing to start: ... was not started
  by this script`; the recovery is `force-stop --kill-all`, read the list, then `--yes`).

## Behaviour that operators will notice

- A second `start`, or `systemctl start` on a running node, logs
  `MediaMTX is already running (PID: n) and owned by this manager; leaving it and its streams
  alone` and prints the stream list; nothing restarts. The per-stream validation still waits
  `STREAM_VALIDATION_DELAY` (5 s) per stream before checking, as `validate_stream` always did.
- Upgrade: PID files written by the old version have no `.id` record and are accepted by
  image identity (a MediaMTX started by the old code is recognised as the manager's own and
  is kept by the first `start` after the upgrade; wrappers likewise). A MediaMTX that the old
  version launched but never recorded cannot be adopted (see above).
- `systemctl restart mediamtx-audio` is unaffected: `ExecStop` stops the owned processes,
  `ExecStart` finds nothing running and starts fresh.
- On a node that has both `mediamtx.service` and `mediamtx-audio.service` enabled (the
  shipped `config/mediamtx-audio.service` declares `Wants=/After=/PartOf=mediamtx.service`),
  `start` now fails with exit 8 instead of killing `mediamtx.service`'s process and rewriting
  the shared configuration. The unit work (D1, D12) removes the contradiction; until it
  lands, `README.md`'s "Requires mediamtx.service to be running first" advice (and the
  comment at the top of `config/mediamtx-audio.service`) is wrong for the manager.

## Removed / renamed / added internals (for anyone reading the code)

- Removed: `wait_for_pid_termination`; the `pgrep`/`pkill` pattern calls
  (`stop_all_ffmpeg_streams`, `force_stop_mediamtx`, `cleanup_stale_processes`,
  `is_restart_scenario`, `verify_cleanup_complete`, `check_resource_usage`,
  `check_memory_usage`, `validate_stream`, `monitor_streams`, `start_ffmpeg_stream`,
  `start_ffmpeg_multiplex_stream`); the host-wide `pgrep -x mediamtx` restart test; the
  deletion of FFmpeg logs. `SHORT_SLEEP` is kept with a justified `shellcheck disable`
  (no user left).
- Added: `proc_pgrp`, `proc_exe`, `proc_load_argv`, `proc_descendants`,
  `is_managed_mediamtx_pid`, `is_managed_wrapper_pid`, `pid_is_foreign_wrapper`,
  `pid_file_recorded_start`, `pid_file_remove`, `stop_recorded_process`,
  `owned_mediamtx_pid`, `foreign_mediamtx_owner`, `proc_systemd_unit`,
  `count_wrapper_processes`, `wrapper_descendant_pids`, `wrapper_has_ffmpeg_child`,
  `scan_instance_processes`, `print_kill_all_preview`, `kill_all_instance_processes`,
  `start_streams_and_report` (the tail of `start_mediamtx`, split out unchanged so a healthy
  start can reuse it), `rotate_ffmpeg_log`, `FFMPEG_LOG_KEEP`, `E_OWNERSHIP`, `COMMAND_ARGS`
  (arguments after the command), `terminate_process_group`'s optional third argument
  (the start time the PID must have).
- Changed signatures: `terminate_process_group PID [TIMEOUT] [START]` (SIGTERM first, only
  signals while the start time matches, 0 = SIGKILL at once, returns 1 only if something
  survives SIGKILL), `cleanup_stale_processes [TIMEOUT]`, `force_stop_mediamtx [--kill-all
  [--yes]]`.

## For the other workers and the unit/monitoring phases

- `monitor_streams`, `check_resource_usage`, `check_memory_usage` and `validate_stream`
  needed a one-line change each (their `pgrep -f` patterns became identity checks). The
  monitoring work that rewrites those functions must keep using `pid_is_foreign_wrapper` /
  `count_wrapper_processes` / `wrapper_descendant_pids`, not a name pattern.
- A wrapper's FFmpeg is started with its own `setsid` and therefore sits in a session of its
  own: stopping the wrapper's process group does not reach it. `terminate_process_group`
  finds it through the parent links (one scan of `/proc`) and signals it individually. If the
  wrapper generation drops that inner `setsid`, the group signal would reach it as well; the
  descendant walk would then be redundant but harmless. A wrapper that is SIGKILLed from
  outside (OOM killer) still leaves its FFmpeg publishing until MediaMTX goes away (the
  FFmpeg's session and the PID file no longer name it); `force-stop --kill-all` finds it by
  its log file, and `verify_cleanup_complete` reports it.
- `start_all_ffmpeg_streams` still skips, silently, devices without `/dev/snd/controlC<N>`
  (X-27, not part of this change). The live test works around the absence of sound hardware
  with an overlay of `/dev` inside its private namespace.
- CI: the live job runs `tests/test_mediamtx_live.bats`, which now ends with the lifecycle
  test (about 55 s per MediaMTX version); it needs root or passwordless `sudo` for
  `unshare --net --pid --fork --mount-proc` and `mount -t overlay`, and skips with a message
  otherwise. No workflow change is needed.
