# Remediation register — November 2026 review

Scope: every finding of an independent review of revision `5befe80` (finding IDs
`LB-01`…`LB-24`) plus the additional defects found while verifying them
(`X-01`…). Each finding was re-checked against the source, by executing the real
functions against stubs wherever that was possible, before any fix was planned.
Machine-readable status: [`remediation-status.json`](remediation-status.json),
checked by `tests/test_remediation_status.bats` (a finding may only be marked
`fixed` if every test it names exists).

Evidence labels used below: **R** = reproduced by running the real code,
**S** = source read only, **HW** = needs real hardware or a real systemd manager
to validate; those are fixed as far as software tests allow and listed in
"Validation that cannot be done in CI" at the end.

---

## 1. Binding design decisions

These resolve the choices the findings leave open. Every change follows them.

| # | Decision |
|---|----------|
| D1 | **One MediaMTX owner.** The stream manager owns MediaMTX *and* its FFmpeg children (single unit `lyrebird-stream-manager.service`). The standalone `mediamtx.service` stays supported for MediaMTX-only installs but is mutually exclusive: the manager unit has `Conflicts=mediamtx.service` and no `Wants=`/`PartOf=`; the manager refuses to start (`E_OWNERSHIP`) while `mediamtx.service` is active and never signals a process it did not start. |
| D2 | **Locks never unlink.** `flock` on a stable path; the file is opened `>>`, never truncated or removed. After the lock is won, the owner writes `pid starttime` (field 22 of `/proc/<pid>/stat`). No age-based or `comm`-based staleness: `flock` is released by the kernel when the holder dies. Lock FDs are closed in every spawned child. |
| D3 | **Config is data.** Device config (`DEVICE_<NAME>_<KEY>=value`) is parsed by an allowlist parser, never `source`d. Accepted value forms: bare, `'…'` or `"…"` literals without expansion. One parser serves `validate`, `start`, `restart` and `monitor`. Unknown keys, bad values and shell syntax are a structured error naming file, line and key. |
| D4 | **Truthful start.** `start` exit status: `0` = policy satisfied, non-zero otherwise. `LYREBIRD_START_POLICY=degraded` (default) requires ≥1 stream publishing; `strict` requires all. A status file (`/run/lyrebird/status.json`) records per-device outcome (`configured`, `process_alive`, `path_ready`, `bytes_flowing`) for every command that changes or checks state. |
| D5 | **Empty start.** With zero USB audio devices the manager still starts MediaMTX (`LYREBIRD_ALLOW_EMPTY_START=true` default), reports `waiting_for_devices`, exits 0 and the monitor reconciles 0→1→N devices with bounded retries. |
| D6 | **Silence/dead-mic checks read the published RTSP stream** (`ffmpeg -i rtsp://127.0.0.1:<port>/<path> … volumedetect`), never a second ALSA open. Reported as distinct signals: path ready, inbound bytes moving, level, prolonged silence. |
| D7 | **No unimplemented watchdog claims.** `HEARTBEAT_INTERVAL`, `HARDWARE_WATCHDOG_*`, `ENABLE_HARDWARE_WATCHDOG` and the `/dev/watchdog` code are removed (settings still parsed, with one deprecation warning). The monitor keeps a best-effort "last monitor run" heartbeat, named and documented as exactly that. Hardware watchdog = systemd `RuntimeWatchdogSec=` / a watchdog daemon, documented. |
| D8 | **`AUDIO_DISK_PERSIST` / `AUDIO_DISK_PATH` are removed** (deprecation warning when set). Recording is RAM-only by default and documented as such; durable recording is `AUDIO_RECORDING_PATH` on persistent storage. |
| D9 | **Secure-by-default listeners without breaking anyone.** API and metrics bind `127.0.0.1` (MediaMTX's default policy already refuses non-loopback API/metrics callers, so no working setup changes). RTSP stays `:8554`. SRT/MoQ/WebRTC/HLS/RTMP are disabled in every generated config (MoQ version-gated). Authentication is operator-owned (D10); documentation says so loudly. |
| D10 | **Config ownership.** Generated MediaMTX config carries a `# Managed by LyreBirdAudio` marker. The manager rewrites only marked files, writes atomically with fsync of file and directory, and keeps a timestamped backup when content changes. A file without the marker is operator-owned: used as-is, never overwritten, validated, with a warning. `--regenerate-config` overrides explicitly. |
| D11 | **Process control by identity, not by name.** Only PIDs recorded in the manager's own PID files, verified by `/proc/<pid>/stat` starttime, are signalled. `pkill`/`pgrep -f` patterns are removed from normal paths; `force-stop --kill-all --yes` is the only broad kill, with a printed preview. |
| D12 | **One unit template** (`config/lyrebird-stream-manager.service`) rendered by both the manager and the installer; modern `StartLimitIntervalSec=`/`StartLimitBurst=` under `[Unit]`; `ExecReload` only if a real `reload` exists; every written path covered by `StateDirectory=`/`RuntimeDirectory=`/`ReadWritePaths=`; verified by `systemd-analyze verify` in tests. |
| D13 | **One canonical stream name**, computed once (`canonical_stream_name`): lower-case, `[a-z0-9_-]`, starts with a letter or digit, ≤64 chars, reserved words rejected with a clear error. Used for YAML (quoted), publisher URL, PID file, status, validate, display and systemd `Environment=`. |
| D14 | **Durable atomic writes** go through one helper in `lyrebird-common.sh` (`atomic_write_file`: temp in same directory, fsync, rename, fsync directory). |
| D15 | **Ports are configuration**: `MEDIAMTX_RTSP_PORT`, `MEDIAMTX_API_PORT`, `MEDIAMTX_METRICS_PORT` are honoured everywhere (generator, readiness, probes, port checks, installer) so tests can run on private ports. |

## 2. Rules for every change

1. **Real code under test.** New tests source the real script (main-guard) and call the real functions. Re-implementing a function inside a test is forbidden for new tests.
2. **Regression test per fix, with a mutation check.** The test must fail on the pre-fix code. Prove it: revert only the production hunk, run the test, see it fail, restore. Record "mutation check" in the commit message.
3. **Never weaken a test, gate or assertion** to get green.
4. **Gates stay at zero:** `bash -n`, ShellCheck 0.11.0 `--severity=warning` (new code should also be clean at default severity unless a justified `# shellcheck disable=` is added), `shfmt -d -i 4 -bn -ci`, `bashate --ignore E001,E006,E040,E042,E043`, and the whole bats suite via `tests/check_tmp_leaks.sh`.
5. **No stubs/TODOs in delivered code;** no scope beyond the finding; no comment/doc churn in code you did not change.
6. **Docs:** do not edit `README.md`, `CHANGELOG.md`, `docs/*.html` or `SECURITY*.md`. Write what the docs pass must change to `docs/remediation/notes/<area>.md` (facts, exact new flags/exit codes/variables, removed settings). The docs pass reconciles them in one change.
7. **Commits:** one logical change per commit; message states the finding IDs, the reproducer, the mutation check and the verification run. End with the attribution trailers used in this repository's history.
8. **Ports for live tests.** Never bind the default ports (8554, 9997, 9998, 9100, 8890–8893) in worker tests. Use the private block assigned to you; the lead alone runs the default-port live suite.
9. **Safety.** No `pkill`, `systemctl start|stop`, or writes outside temp dirs on the host. Stub with PATH shims.
10. **Report honestly:** what was reproduced, what was only read, what needs hardware.

## 3. Finding register

Severity is the assessed severity after verification (the review's own rating
differs where noted in the commit that fixes it).

### Stream manager — locking and lifecycle

| ID | Sev | Verified defect | Required outcome |
|----|-----|-----------------|------------------|
| LB-05 | P1 | R. `acquire_lock` unlinks a lock it judges stale before `flock`; staleness includes lock age >300 s on `start`/`restart` regardless of a live owner, plain truncation of the PID by a waiting opener, and a `ps comm` check that can never match when the script is run directly (comm is the 15-char `lyrebird-stream`), so a live owner is always judged stale. `force_stop_mediamtx` and `cleanup_stale_processes` unlink lock paths. | D2. Concurrent start/stop/restart/monitor/force-stop never overlap; test with real processes holding the lock past any former threshold, and with direct execution. |
| X-02 | P1 | R. The lock FD is inherited by spawned MediaMTX/wrappers/ffmpeg children; after the parent exits the next `acquire_lock` sees a dead PID, unlinks and re-creates the file (inode split after every `start`); in-process `stop` waits the full timeout. | FD closed in every spawn site; test that no child holds the lock FD. |
| LB-01 | P1 | R. `start_mediamtx` runs `cleanup_stale_processes` in both branches before `is_mediamtx_running`; the "already running" guard is unreachable (cleanup deleted the PID file). Per-stream start is already idempotent. | Repeat `start` on a healthy node changes nothing: same PIDs, no stream restart, exit 0; dead streams are reconciled. Cleanup only for provably stale ownership or explicit restart. Test with a live MediaMTX and an RTSP reader recording byte continuity. |
| LB-02 | P1 | R. `mediamtx-audio.service` declares `Wants/After/PartOf=mediamtx.service` while `start_mediamtx` launches its own MediaMTX on the same config path; cleanup selects `mediamtx.service`'s process and rewrites the shared config before the port check. | D1. |
| LB-03 | P1 | R. Individual mode: `start_all_ffmpeg_streams` and `start_mediamtx` return 0 after `[FAIL]` lines (deliberate "best effort"); validation failures return 0 even in multiplex mode. | D4. |
| LB-07 / X-03 | P1 | R. With zero devices `start_mediamtx` exits 6 before launching MediaMTX; `wait_for_usb_stabilization` returns 0 for zero devices because the sha256 of empty input is non-empty; `monitor` returns 7 and never starts MediaMTX. | D5; stabilization treats zero devices as "not yet" until its deadline; test 0→1→N with fake sysfs/ALSA. |
| X-04 | P1 | R. `should_restart_stream` records a cron restart before `check_alsa_device_available`, so a detected-but-unavailable card burns the 6/hour budget. | Budget charged only for real restart attempts. |
| LB-10 | P2 | R. Broad `pkill -f`/`pgrep` patterns (`^ffmpeg.*rtsp://localhost:8554`, `^/usr/local/bin/mediamtx`, `pgrep -x mediamtx`) match other installations' processes; `stop` runs the broad ffmpeg pkill; the installer `pkill mediamtx` substring-matches. | D11 in manager and installer; two-instance isolation test with decoy processes. |
| X-25/26/27 | P3 | R/S. `cleanup_stale_processes` deletes all FFmpeg logs every start; `read_pid_safe` comm allowlist deletes the PID file of a live process with another basename; `start_all_ffmpeg_streams` silently skips devices without `/dev/snd/controlC<N>`. | Rotate logs; identity by starttime; log and report skipped devices. |

### Stream manager — configuration, naming, endpoints

| ID | Sev | Verified defect | Required outcome |
|----|-----|-----------------|------------------|
| LB-04 | P1 | R. Publisher uses `sanitize_path_name`, YAML key uses the raw `MULTIPLEX_STREAM_NAME`. `Studio Mix` makes MediaMTX 1.21.1 and 1.15.0 refuse to start; `Studio` loads but the publish is rejected (400, path not configured). A newline injects YAML (`runOnInit` executed); `status` looks for a PID file under the raw name. | D13; name matrix test against real MediaMTX. |
| LB-08 / X-09 | P1 | R. `validate_config` + `load_device_config` `source` the file: `exit 0` passes validation and ends the manager (start "succeeds" with nothing running); an unbound variable kills it under `set -u`; `restart` never validates; a `trap` line removes the cleanup trap. | D3. |
| LB-09 / X-10 / X-11 | P2 | R. Generated wrappers interpolate config values into double quotes: `"`, `$(…)`, backticks, `$VAR` and a trailing `\` execute or break the wrapper; individual mode has no `bash -n` before launch; wrappers are written in place; `Environment="MULTIPLEX_STREAM_NAME=…"` is written unquoted. | Fixed wrapper program receiving validated arguments/env, or `printf %q` + allowlist + `bash -n` + atomic rename; injection tests with a marker file. |
| X-01 | P1 | S+R(function level). `DEVICE_*` values are loaded only inside `generate_mediamtx_config`; `monitor`-triggered restarts call `start_ffmpeg_stream` without loading them, so per-device settings revert to defaults after the first monitor restart. | One loader used by every command; test a monitor restart with non-default device config. |
| LB-13 | P2 | R. `wait_for_mediamtx_ready` (`curl -s`, hard-coded `:9997`) treats 404/401/500/garbage as ready; `detect_mediamtx_api_version` likewise (v2/v1 fallback unreachable); against an authenticated API `probe_stream_ready` returns not-ready for a healthy stream and, after 3 strikes, restarts it. | Status+schema checked readiness through one helper; 401/403 = "unknown", never a strike. |
| LB-06 | P1 untrusted LAN | R. Generated and installer configs bind API `:9997` and metrics `:9998` on all interfaces with no authentication keys; the installer config leaves SRT and MoQ listening. Anonymous RTSP publish/read works from any address (MediaMTX default policy; API/metrics are refused off-loopback). | D9; deny-case tests against real MediaMTX. |
| LB-22 | P1 with LB-06 | R. `generate_mediamtx_config` rewrites the config on every `start` with no backup and before the port check; operator edits (auth, binds, `chmod 640`) are silently lost. Installer and manager generators differ. | D10; one shared generator. |
| LB-23 | P2 HW | S. mktemp+mv without fsync of file or directory in the manager (the mapper does sync). | D14. |
| LB-24 | P2 HW | S. Capture is assumed to be ALSA PCM 0 in `check_audio_device`, `check_audio_level` and both capture inputs (`plughw:N,0`). | Enumerate capture PCMs; carry the index; `DEVICE_<NAME>_PCM` override. |
| X-06 | P2 | R. `exec {fd}>file 2>/dev/null` in the main shell permanently redirects fd 2 (`generate_mediamtx_config`, `acquire_lock`). | No persistent redirection. |
| X-15 | P3 | R. `LOG_FILE` and `MEDIAMTX_LOG_FILE` read the same variable. | Separate variables. |
| X-19 | P2 | S. README documents `MEDIAMTX_*_PORT`; code hard-codes 8554/9997/9998 in the generator, readiness and port checks. | D15. |
| X-20 | P1 (HW for real layouts) | R/S. `amix=…:normalize=0` needs FFmpeg ≥4.4 while README minimums ship 4.2/4.3; README claims normalization the code disables; `amerge` + default opus fails for several channel counts (e.g. 2 stereo → 4.0, 5 stereo → 10 ch) on FFmpeg 6.1.1; resampling happens after the mix. | Feature-detect `normalize`; validate channel count against codec limits with a clear error; docs state real behaviour. |

### Stream manager — monitoring and units

| ID | Sev | Verified defect | Required outcome |
|----|-----|-----------------|------------------|
| LB-14 / X-05 | P2 | R. `check_all_audio_levels` has no caller anywhere; `AUDIO_LEVEL_CHECK_ENABLED=true` does nothing; rc=2 would be counted as silence; the only dead-mic mechanism today is the API `ready` flag. `tools/soak/README.md` says the manager's silence detection covers this. | D6. |
| LB-15 | P2 | R. `HEARTBEAT_INTERVAL` and `HARDWARE_WATCHDOG_TIMEOUT` are never used; `init_hardware_watchdog` only tests `-c`/`-w` and logs "initialized" without opening the device; `kick_hardware_watchdog` is unreachable from `monitor`; `LYREBIRD_WATCHDOG_*` in the sample unit are never read; docs claim a watchdog. | D7. |
| LB-16 | P2 | S. `AUDIO_DISK_PERSIST` only creates `AUDIO_DISK_PATH`; segments go to `/dev/shm`; both knobs default to false; only a code comment promises persistence. | D8. |
| LB-11 | P1 | R/S. Sample unit: `ExecReload=… reload` (no such command → exit 1); `ProtectSystem=strict` without `/var/lib/mediamtx-ffmpeg` (`setup_directories` `chmod` fails EROFS in the same sandbox model); `WorkingDirectory=/var/lib/lyrebird` never created; no `TimeoutStartSec`; `# User=mediamtx` hint breaks because the manager requires root. | D12. |
| LB-12 | P3 | R. `StartLimitInterval=`/`StartLimitBurst=` under `[Service]` are **accepted** by systemd 255 (only the new `…IntervalSec` spelling is rejected there); non-canonical placement, no functional bug. | D12 (canonical placement); test pins the placement. |
| X-12 | P2 | S. `ExecReload` signals (HUP in the sample, USR1 in the installer unit) are not handled by MediaMTX 1.21.1 (`core.go` registers only SIGINT/SIGTERM). | No unit sends a signal MediaMTX does not handle. |

### Other components

| ID | Sev | Verified defect | Required outcome |
|----|-----|-----------------|------------------|
| LB-17 | P2 | R. Dedup state has no lock: 5 parallel identical alerts → 5 deliveries; partial failure returns success and the failed destination is not retried inside the rate-limit window (logged, not silent); `cleanup_state` can shrink the rate limit. | Per-destination keys/state, flock-claimed before sending, explicit partial-failure result. |
| LB-18 / X-17 | P3/P2 | R. `--file` writes through a fixed `${file}.tmp` (loser of two writers exits 1); generation failure exits 0 (deliberate); `serve` binds all interfaces while logging "localhost", sends `Content-Length` from `${#metrics}`, uses `echo -e`, busy-loops when the port is taken, serves metrics generated before the wait, and its `pkill -f` pattern is broad. Docs show `serve --port 9100`, which the parser rejects. | Unique temp + atomic rename, non-zero on failure with last-good file kept, `scrape_success`/collector-error metrics, loopback-bound server with correct framing, docs match. |
| X-13 | P2 | R. `lyrebird_heartbeat_healthy` requires age <60 s but the only writer runs every 5 minutes; heartbeat is written while MediaMTX is down. | Threshold derived from the actual cadence; heartbeat semantics match D7. |
| LB-21 | P3/P2 | S. Wizard summary uses state refreshed before the start step; its success branch depends on `start`'s status (LB-03); menu `|| true` only masks the status after `execute_script` printed the error. | Wizard reads fresh state/`status.json`; documented exit taxonomy honoured. |
| X-14 | P3 | S. Storage cleanup globs miss `.aac`; emergency eviction has no zero-byte/truncated-segment tests. | Glob derived from supported codecs; tests. |
| X-21 | P2 | S. README documents `lyrebird-updater.sh --history` and `--rollback [vX]` (not implemented), recovery from `audio-devices.conf.bak` (never created), an install path (latest tag) that lacks the fixes on `main`; `SECURITY.md` lists only 2.x as supported while all tags are 1.x; CHANGELOG version table is stale. | Implement or correct; docs state the truth. |
| LB-19 / LB-20 / X-22 / X-16 | P3 | R/S. PR CI is path-filtered to `**.sh`; the summary job does not require live-MediaMTX/shfmt/bashate/security jobs; live matrix stops at 1.21.1 (1.21.3 is the newest tag); no Action is SHA-pinned; tool downloads unverified; `release.yml` validate skips the live job and the v1.3.0 publish step failed. | Broaden triggers; require every job; add latest-release canary; pin Actions by SHA with Dependabot; verify tool downloads; make release publishing idempotent. |
| X-18 | P3 | S. `tests/test_stream_manager.bats` re-defines functions inline and tests the copies; no test calls the real `start_mediamtx`, lock or cleanup functions. | Real-function tests for everything touched here; inline copies removed where they cover touched behaviour. |

### Documentation

`SECURITY-GUIDE.md`: Option 2 `"${MEDIAMTX_ADMIN_PASSWORD}"` is taken literally by MediaMTX 1.21.1 (R: 200 for the literal string, 401 for the environment value) — the documented admin password is the public string; regex path syntax needs the `~` prefix (R); "API: localhost only" is true for authorization, false for bind scope; WebRTC is described as open though the generated config disables it. README: watchdog, normalization, platform/ARMv6 claims, install-from-tag guidance, rollback commands, `.conf.bak`, `serve --port`. `tools/soak/README.md`: observer "Linux or macOS" vs "not run on macOS"; silence-detection claim.

## 4. Validation that cannot be done in CI

Recorded in the commit that fixes each item, and repeated in the final report: real power-cut durability (LB-23), second-open ALSA behaviour and real capture PCM layouts (LB-24), USB clock drift across independent mics (X-20), real systemd start-limit timing at boot with a late hub (LB-07), hardware watchdog drivers (LB-15), RTSP from a separate host, FFmpeg 4.3 runtime, ARM/armv6 binaries, branch-protection settings, release signing identity.
