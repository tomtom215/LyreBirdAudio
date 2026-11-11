# install_mediamtx.sh notes (for the documentation pass)

Pass 1: LB-10 (installer part, D11) and X-19 (installer part, D15). The
generated MediaMTX config and the generated systemd unit are untouched in this
pass (shared generator and single unit template come later).

## Behaviour changes the docs must describe

### Process control (LB-10, D11)

The installer no longer selects processes by name or command-line pattern.
`pkill mediamtx`, `pkill -9 mediamtx`, `pkill -f 'ffmpeg.*rtsp://localhost'`,
`pgrep -f` and `pgrep -x mediamtx` are gone from `install_mediamtx.sh`.

- A process counts as "the installed MediaMTX" only if `/proc/<pid>/exe`
  resolves to the installed binary (`<prefix>/bin/mediamtx`, symlinks resolved;
  a running image whose file was replaced by an update, shown by the kernel as
  `... (deleted)`, still counts) **and** argv[1] equals the installed config
  path (`<config dir>/mediamtx.yml`) exactly. Same name, same binary with
  another config, another binary with the installed config: none of these
  match.
- Stopping goes through the owner of the process:
  - `mediamtx.service` active: `systemctl stop mediamtx`.
  - `mediamtx-audio.service` (the stream manager unit) active:
    `systemctl stop mediamtx-audio` (this stops the manager's FFmpeg children
    too, through the manager's own `ExecStop`).
  - MediaMTX started by the stream manager without the unit (its PID file
    names a verified process): `lyrebird-stream-manager.sh stop`.
  - Anything still running afterwards that is provably the installed MediaMTX
    gets SIGTERM, a bounded wait (`MEDIAMTX_STOP_TIMEOUT`, default 10 s), then
    SIGKILL, each signal sent to one PID after re-checking identity and start
    time (field 22 of `/proc/<pid>/stat`).
  - If systemd cannot stop an active unit, the installer reports it and
    **stops** (exit 7 from `update`/`uninstall`) instead of killing the unit's
    process behind systemd's back; the installed binary is left alone.
- The installer never signals FFmpeg. If the stream manager's `stop` fails or
  the manager script is missing, the installer says that FFmpeg streams were
  **not** touched and how to stop them.
- `status`/mode detection use unit state plus the identity check. A new mode
  name, `stream-manager-service`, appears in `status` output as
  "Running (stream manager service)". A MediaMTX with another config or from
  another installation is no longer reported as "Running (manual)": for this
  installation it is "Not running". Run as non-root, `status` cannot read
  `/proc/<pid>/exe` of root's processes, so for a MediaMTX started outside
  systemd it prints "Not detected (run as root to identify ...)".
- Platforms without `/proc` (macOS, BSD): nothing can be proven, so the
  installer signals nothing there and relies on the operator stopping MediaMTX.
- New environment variables read by the installer: `MEDIAMTX_STOP_TIMEOUT`
  (seconds, default 10) and `MEDIAMTX_PID_FILE` (the stream manager's PID file,
  default `/run/mediamtx-audio.pid`; only used to label the mode
  `stream-manager`, never to select a process to signal).

### Ports (X-19, D15), installer part

No defect found in the installer: `MEDIAMTX_RTSP_PORT`, `MEDIAMTX_API_PORT` and
`MEDIAMTX_METRICS_PORT` were already read once at start-up (defaults 8554,
9997, 9998) and used by the config it writes and by the `status` port check;
it makes no health probe. This pass pins that with tests and lists the
variables in `--help`. The generator in `lyrebird-stream-manager.sh` and its
readiness checks are the remaining part of X-19. Values are not validated
(`MEDIAMTX_API_PORT=abc` is written into the config as given); that belongs
with the shared generator.

## README / docs corrections

- README "Troubleshooting Uninstallation" (about L2477-2478) tells users to run
  `sudo pkill -9 mediamtx` and `sudo pkill -9 ffmpeg`. That is the broad kill
  D11 removes: it kills every process with `mediamtx` in its name and every
  FFmpeg, including other installations'. Replace with: stop through systemd
  (`sudo systemctl stop mediamtx mediamtx-audio`) and, once it exists, the
  stream manager's `force-stop --kill-all --yes` (prints a preview). Remove
  the "kill all FFmpeg" advice from `docs/troubleshooting.html` (about L211,
  `sudo pkill -f ffmpeg`) for the same reason.
- README "MediaMTX Installer" section: say that `update` and `uninstall` stop
  MediaMTX through systemd or the stream manager, never by process name; that
  FFmpeg is never killed by the installer; the new exit-7 abort when MediaMTX
  cannot be stopped; and the two new environment variables above.
- README lists the installer as version 2.0.1. This pass did not bump
  `SCRIPT_VERSION`; the lead decides the release number.
- `tests/README.md`: `test_install_mediamtx.bats` goes from 66 to 100 tests (30
  tagged `[LB-10 installer]`, 4 tagged `[X-19 installer]`) and there is a new
  helper, `tests/process_decoys.bash` (decoy processes, systemctl/pkill/pgrep
  shims and a guarded `kill`; reusable for the stream manager's two-instance
  isolation test). The table counts in that file are already stale
  (`bats --count tests/` was 678 before this pass, 712 after); recompute them
  once all areas have landed.

## For docs/remediation-status.json (the lead edits it)

- LB-10 stays `open`: the installer part is done, the stream manager part is
  not. When the manager part lands, the installer tests to name are the
  `[LB-10 installer]` ones, in particular: "stop_mediamtx (manual) signals only
  the exact-identity process and no name-based tool runs [LB-10 installer]",
  "stop_mediamtx (stream-manager) falls back to the verified process only,
  never to FFmpeg, when the manager's stop fails [LB-10 installer]",
  "detect_management_mode reports none while only look-alikes run [LB-10
  installer]" and "update_mediamtx leaves the installed binary alone and stops
  when MediaMTX cannot be stopped [LB-10 installer]".
- X-19 stays `open` (generator, readiness and port checks in the stream manager
  remain). The installer's own X-19 guards are the four `[X-19 installer]`
  tests.

## Residual risk of this pass

- Identity is proven by exe path and argv[1] only. Another process that runs
  the installed binary on the installed config is, by definition, the managed
  MediaMTX and is stopped too.
- A MediaMTX started with a relative config path, no config argument, or from a
  symlinked path whose `readlink -f` differs from the kernel's view is not
  recognised and is therefore never signalled (the safe direction); `update`
  then replaces the binary underneath it and tells the operator nothing about
  that process.
- Between the final identity check and `kill` there is a window of
  microseconds; the start-time check makes a PID reuse inside the grace period
  harmless but not impossible in that window.
- `lyrebird-stream-manager.sh stop` is still the manager's own command and, at
  this revision, still contains its broad `pkill` patterns; the installer
  delegates to it for a manager-started MediaMTX. Its D11 fix is the stream
  manager worker's.
- Not run: a real systemd manager, Bash 4.2 itself, macOS/BSD (no `/proc`).

## Found while working (not fixed in this pass)

- `update` in `manual` mode (a MediaMTX nobody supervises) cannot restart the
  server: `start_mediamtx manual` only prints "Please manually restart
  MediaMTX", then `verify_service_started` waits 6 s for a process, fails, and
  the EXIT-trap rollback restores the old binary and exits 7. A manual-mode
  update therefore always ends rolled back unless the operator restarts
  MediaMTX within six seconds. Reproduced with decoys against the new code
  (stop, replace, "Please manually restart MediaMTX", "did not come back up",
  rollback, exit 7); the old code takes the same path by reading
  (`start_mediamtx manual` only logs; `verify_service_started` polled
  `pgrep -x mediamtx`). Unchanged by this pass: the check now looks for the
  installed MediaMTX by identity instead of any process named mediamtx.
  Needs a product decision (leave stopped with the new binary installed and say
  so, or skip verification in manual mode).
- Port variables are not validated before they are written into the config.
