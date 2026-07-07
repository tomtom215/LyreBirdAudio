# LyreBirdAudio Engineering Excellence Review — July 2026

Full line-by-line correctness/reliability audit of every script and every test,
driven by static analysis (`bash -n`, ShellCheck, shfmt, checkbashisms) plus
deep manual review of all ~22,000 lines of Bash and ~4,500 lines of tests, with
a current MediaMTX compatibility pass.

**Status legend:** ✅ verified (read + executed) · 🔎 verified by reading ·
🧪 reproduced empirically · ⬜ fix pending · ✔️ fixed

---

## 1. Executive summary

The suite is thoughtfully engineered in many places (atomic PID/config writes,
PID-recycle-aware locking, bounded `curl` timeouts, defensive common library).
However, the review found **multiple independently-verified defects in core
features**, several of which mean a headline capability silently does not work:

| # | Severity | Component | One-line impact |
|---|----------|-----------|-----------------|
| C1 | CRITICAL | usb-audio-mapper | Every generated udev rule is commented out → USB persistent naming never works |
| C2 | CRITICAL | stream-manager | `wait` under `set -e` kills the wrapper on FFmpeg's first non-zero exit → no auto-restart |
| C3 | CRITICAL | stream-manager | Wrapper exits when the transient launcher PID dies (`MAIN_SCRIPT_PID=$$`) → no auto-restart |
| C4 | CRITICAL | mic-check ↔ stream-manager | Device config written mixed-case, read UPPER-case → every per-device setting ignored; `--validate` falsely PASSes |
| C5 | CRITICAL | lyrebird-alerts | ntfy/Pushover configs silently drop **every** alert and report "sent successfully" |
| C6 | CRITICAL | lyrebird-metrics | Duplicate `# HELP`/`# TYPE` lines → Prometheus rejects the entire scrape |
| C7 | CRITICAL | lyrebird-updater | Self-update dead-locks on its own lock after `exec` → self-update always fails |
| C8 | CRITICAL | lyrebird-orchestrator | Delegated interactive scripts get `stdin=/dev/null` → Quick Setup Wizard can't map devices |
| C9 | CRITICAL | test suite / CI | bats never runs in CI; 3 test files executed 0 tests; `set -e` leak silently hid failures |

Plus ~15 HIGH and ~20 MEDIUM/LOW findings (below).

### Cross-cutting root cause: `set -euo pipefail` + Bash idioms → silent aborts

Nearly every script sets `set -euo pipefail`. Combined with common Bash idioms
this produces **silent mid-run aborts** — found independently in four files:

- `wait "$pid"` (non-zero child) → errexit kills the supervisor (stream-manager C2).
- `((x += y))` returns exit 1 when the result is 0 → errexit aborts the loop
  (storage cleanup; the same file uses the *safe* `((++count))` elsewhere).
- `$(… | grep -c PAT || echo 0)` emits `0\n0` → arithmetic syntax error under
  errexit, or `[[ 0\n0 -gt 0 ]]` noise (diagnostics, metrics).
- Sourcing a `set -e` script into bats leaks errexit/nounset into the test
  shell → failing assertions vanish instead of reporting `not ok` (test suite).

This class is the highest-leverage thing to fix and to guard with tests.

---

## 2. Test-suite state (before this review)

CI (`bash-ci.yml`) runs `bash -n`, ShellCheck (`--severity=warning`, the only
gate), shfmt, bashate, and a grep security scan — but **never runs the bats
tests**. Running them locally revealed:

- **3 files executed 0 of their tests** (`test_install_mediamtx` 0/60,
  `test_lyrebird_storage` 0/48, `test_lyrebird_updater` 0/51 = **159 hidden
  tests**) because those scripts ended with a bare `main "$@"`; bats' `source`
  ran `main`, which called `exit`, aborting the file. ✔️ Fixed: added a
  `[[ "${BASH_SOURCE[0]}" == "${0}" ]]` guard to all 7 unguarded scripts.
- After the guard, several files still under-executed because the sourced
  script's `set -euo pipefail` leaked into the bats shell and turned failing
  assertions / unset-var reads into silent aborts. ✔️ Being fixed by restoring
  bats' error handling (`set +euo pipefail`) in each affected `setup()`.
- Genuine stale-test bugs surfaced: e.g. storage/updater tests assert
  `$SCRIPT_VERSION` but the scripts define `VERSION`; installer tests assert
  `$PLATFORM`/`DRY_RUN`/`version_compare`-prints-to-stdout against an API the
  2.0.1 script no longer has.
- ShellCheck at `--severity=warning` is clean; at style level only 3 style + a
  batch of `SC2317` (unreachable — false positives from dispatch/trap) remain.

---

## 3. CRITICAL findings

### C1 — usb-audio-mapper: udev rules are emitted as a comment 🧪⬜
`usb-audio-mapper.sh:625` builds the comment with a **literal** `\n`
(`"# USB Sound Card: …\n"` — Bash does not expand `\n` in double quotes), and
`:645`/`:686` print it with `printf '%s'` (no escape processing). Comment and
rule collapse onto **one `#`-prefixed physical line**, so udev ignores the whole
rule. Verified by running the real function: `grep -vc '^#'` = **0** active
rules. `ATTR{id}` is never set → `/dev/snd/by-id/<name>` never created → devices
are not persistently named across reboot. Present since 2025-09-03. The mapper
still prints "Rules written successfully".
**Fix:** emit a real newline (`printf '# USB Sound Card: %s\n%s\n' …`).

### C2 — stream-manager: bare `wait` under `set -e` defeats restart 🔎⬜
Generated wrapper runs `set -euo pipefail` (`:3733`, `:3300`); the restart loop
does a bare `wait "${FFMPEG_PID}" 2>/dev/null` (`:4003`, `:3601`) before
`exit_code=$?`. FFmpeg exits non-zero on essentially every real failure (USB
glitch, MediaMTX blip, signal) → errexit kills the wrapper before the
exponential-backoff/restart code runs. The self-healing engine is dead on every
failure path.
**Fix:** `local ec=0; wait "${FFMPEG_PID}" 2>/dev/null || ec=$?` (do **not** use
`|| true` — the code needs the code).

### C3 — stream-manager: wrapper tied to transient launcher PID 🔎⬜
`MAIN_SCRIPT_PID="$$"` (`:3761`, `:3341`) captures the `start` process PID at
generation time; wrappers are launched `nohup setsid bash wrapper &` (`:3660`)
and `start` then returns/exits (systemd `Type=forking`). `check_parent_alive`
(`:3941`, called `:3958`/`:4034`) then sees the launcher dead and `break`s — so
even with C2 fixed, the wrapper exits instead of restarting.
**Fix:** drop the `check_parent_alive` gating (the `CLEANUP_MARKER` check already
handles graceful stop), or monitor the MediaMTX PID instead.

### C4 — mic-check ↔ stream-manager: device-config key case mismatch ✅⬜
`generate_config` writes `DEVICE_${safe_name}_…` case-preserving
(`mic-check:421`, `:1777`), but `get_device_config` reads
`DEVICE_${name^^}_…` upper-cased (`stream-manager:3062`, `:3073`). For any
device id not already all-caps (`Yeti`, `Blue Yeti`, `Device`), **every**
generated setting (sample rate, channels, bitrate, codec) is dropped and
defaults are used. `mic-check --validate` still reports PASS (it checks its own
mixed-case names). A "high quality / 192 kHz" mic silently streams at 48000/2/128k.
**Fix:** upper-case the emitted names in `generate_config`/`validate_config`.

### C5 — lyrebird-alerts: ntfy/Pushover silently drop every alert 🔎⬜
`send_alert` early-returns 0 unless `LYREBIRD_WEBHOOK_URL(_S)` is set (`:614`),
but the ntfy/Pushover setup paths never populate it (`:958`), so no alert is
ever sent — and `cmd_test`/setup print "Test alert sent successfully!" (`:1026`,
`:1083`) because the guard returned 0. Two of five documented webhook types are
fully non-functional and fail silently *with a success message*.
**Fix:** make the "destination configured?" check type-aware; distinguish
"skipped, nothing sent" from real delivery in `cmd_test`.

### C6 — lyrebird-metrics: duplicate HELP/TYPE breaks the whole scrape 🧪⬜
`emit_metric` prints `# HELP`/`# TYPE` on every call; it is called in loops for
the same metric family (disk over `/`,`/var`,`/tmp` at `:237`; per-stream at
`:454`/`:462`/`:470`). The Prometheus text format allows one HELP/TYPE per
family; the reference parser rejects the **entire** response, so the target
shows DOWN. Happens on every host, every scrape.
**Fix:** emit HELP/TYPE once per family, before the loop.

### C7 — lyrebird-updater: self-update dead-locks on its own lock 🧪⬜
Self-update `exec`s the new script without releasing the lock first (`:2088`);
the re-exec'd process has the same PID, sees the lock "held" by that PID, the
PID-recycle staleness check doesn't fire (it *is* that PID), it waits
`LOCK_MAX_WAIT` and exits `E_LOCKED`. `--post-update-restore` never runs; the
stash and service-update marker are orphaned. Reproduced by the reviewer.
**Fix:** `release_lock` immediately before the `exec`.

### C8 — orchestrator: interactive delegations get stdin=/dev/null 🔎⬜
`execute_script` runs children as `"${script_path}" "${args[@]}" &` then `wait`
(`:691`, `:713`, `:743`). With job control off (a script), a backgrounded
command's stdin is redirected from `/dev/null`, so interactive children (USB
mapper `read`, updater menu) read EOF. Quick Setup Wizard Step 2 (device
mapping), USB menu option 1, and "Launch Update Manager" cannot receive input;
"Uninstall" hits EOF on its confirm *after* removing the binary.
**Fix:** run interactive delegations in the foreground, or append `</dev/tty`.

### C9 — CI never runs the tests; test rot invisible ✅✔️/⬜
See §2. Guards added; harness stabilization + a CI bats job pending.

---

## 4. HIGH findings

- **H1 storage — cleanup aborts on a 0-byte file** 🧪 `((freed_bytes += size))`
  (`:230`,`:253`,`:264`,`:284`,`:294`) returns exit 1 when the sum is 0; under
  `set -e` the first 0-byte `.wav` halts cleanup → disk fills on a 24/7 recorder.
  **Fix:** `freed_bytes=$((freed_bytes + size))`.
- **H2 storage — emergency deletes all `/var/log/*.gz`** 🔎 `MEDIAMTX_LOG_DIR`
  resolves to `/var/log`; `find "$MEDIAMTX_LOG_DIR" -name "*.gz" -delete`
  (`:362-363`, plus `*.tmp` at `:306`) wipes unrelated system logs during an
  incident. **Fix:** scope to `-maxdepth 1 -name 'mediamtx*.out*.gz'`.
- **H3 storage — `--dry-run emergency` actually deletes** 🔎 `find -delete`/`rm -rf`
  in `emergency_cleanup` (`:362-370`) bypass `DRY_RUN`. **Fix:** gate on `DRY_RUN`.
- **H4 diagnostics — `debug` aborts on a healthy system** 🧪
  `$(( $(… grep -ic error || echo 0) ))` (`:2159`,`:2161`) receives `0\n0` →
  arithmetic syntax error → `set -e` kills the run mid-diagnostic. **Fix:** drop
  the redundant `|| echo 0`.
- **H5 updater — branch switch never fast-forwards** 🔎 `git checkout <branch>`
  (`:2007`) lands on the stale local tip; "Switch to Development" no-ops while
  reporting success. **Fix:** `git merge --ff-only origin/<branch>` for branch targets.
- **H6 updater — `update -V <ver>` overridden to latest** 🔎 built-in `--upgrade`
  path (`install_mediamtx.sh:1300-1323`) ignores the pinned target and only
  checks `new != current`. **Fix:** only use `--upgrade` when target == latest;
  verify `new == RELEASE_VERSION`.
- **H7 usb-mapper — udev rule injection via unsanitized name** 🧪
  `tr -cd '[:alnum:] \t-_.'` (`:622`) parses `\t-_` as the range 0x09–0x5F,
  permitting `"`, `$`, `;`, `=`, newline; `device_name` (`-d`) is unvalidated
  (`:929`) → an embedded newline yields an active root `RUN+=` line. **Fix:**
  `tr -cd '[:alnum:] ._-'` + strip newlines; validate `device_name`.
- **H8 stream-manager — no resurrection of a dead stream** 🔎 cron `monitor` is
  report-only (`CRON=1` ⇒ `allow_restart=false`, exit 10); only
  `E_CRITICAL_RESOURCE` triggers a full-service restart. With C2/C3, a dead
  stream stays down forever. **Fix:** give cron a bounded per-stream restart path.
- **H9 stream-manager — health check only verifies the bash PID** 🔎
  `monitor_streams` (`:2535`,`:2622`) checks the wrapper process exists, never
  MediaMTX `ready:true` or an FFmpeg child → a mid-backoff/silent-mic stream
  reports healthy. **Fix:** also query `/v3/paths/get/<name>`.
- **H10 alerts/mic-check — invalid JSON drops webhooks** 🧪 `json_escape`
  (`alerts:342`) misses control chars (`\b`,`\f`,ESC,0x00–0x1F); mic-check
  `output_json` (`:2261`) escapes `"` but not `\` first → a device name with `\`
  or an ANSI code produces invalid JSON → webhook 400 / `jq` failure. **Fix:**
  escape `\` first, then `"`, then control chars (or shell to `jq -Rs .`).

---

## 5. MEDIUM / LOW findings (abridged register)

metrics: empty `stream_cpu_percent` value (`:469`), bare `0` line from
`grep -c … || echo 0` (`:180`), pagination `itemCount` ignored (`:331`+), label
values unescaped (`:453`). storage: `df|tail -1` misparses wrapped device names
(`:169`/`:175`) → full disk read as OK; timeout clamp before config load; ntfy
colon-in-title truncation (`:536`); rate-limit TOCTOU. common: spinner leaks an
orphan process / hides cursor with no EXIT trap (`:568-624`); `run_with_timeout`
swallows stderr. diagnostics: `is_device_busy`/`hw_params` sentinel `closed`
mis-read; `df` not POSIX (`:1020`); inotify %="watches vs instances" (`:1338`);
`nc -zv` BusyBox; long-uptime false "recent crash" (`:2558`); `^64` perms accepts
646/647 (`:2443`). mic-check: `low` tier emits unsupported channel count
(`:1226`); `restore_config_backup` doesn't back up current first. usb-mapper:
synthetic `busX-devY` → dead `KERNELS` rule; cross-fs `mv` not atomic (`:696`);
VID:PID-only rule renames all identical mics; `SYMLINK+=` on whole `sound`
subsystem (no `KERNEL==` gate). orchestrator: in-session update trips the
integrity check (`:647`); announces `/dev/snd/by-usb-port/` that nothing creates
(`:951`,`:1234`); Quick Setup not idempotent (installer exit 7 fatal); diagnostics
export bypasses integrity check (`:1676`). install: GNU-only `-printf`/`head -n -3`
backup prune no-ops on BSD; INT/TERM handler `return`s and gates rollback on `$?`;
`flock`+unlink race in `release_lock`.

---

## 6. MediaMTX modernization (current latest: v1.19.2, 2026-06-28)

- API prefix still `/v3/`; **all endpoints the suite uses remain valid.** Asset
  naming and `checksums.sha256` unchanged. Dynamic version fetch means no
  hardcoded-version breakage.
- **Good news:** the suite emits **no** removed config keys (`fallback`,
  `authJWTInHTTPQuery`) — verified. (MediaMTX ≥1.16 refuses to start on unknown
  keys, so this would have been fatal.)
- **To modernize:** bump the supported/target string to v1.19.x; the JSON status
  fields parsed by grep (`"ready":true` in stream-manager ×4 + metrics ×1) are
  now *deprecated* (still returned) in favour of `available`/`online`/
  `inboundBytes`/`outboundBytes`/`tracks2` — migrate before a future major drop.
  Consider `/v3/info` for a light version/health probe.

---

## 7. Remediation plan (priority order)

1. **Test harness + CI** (safety net): source guards ✔️, `set +e` in affected
   setups, fix stale-test bugs, add a bats CI job, keep ShellCheck gate.
2. **CRITICALs** C1–C8, each with a regression test that fails before / passes after.
3. **HIGH** H1–H10 with tests.
4. **MEDIUM/LOW** as capacity allows.
5. **MediaMTX** version bump + tolerant status parsing.
6. **Hardware-free E2E harness**: PATH-shim fakes for `ffmpeg`, `arecord`,
   `lsusb`, `udevadm`, `systemctl`, and a stub MediaMTX HTTP API, driving
   install→map→configure→stream→monitor→alert with no real hardware.
7. Docs/CHANGELOG updates.

Every fix is verified against the actual code; line numbers are from the state
at review time and may shift as fixes land.
