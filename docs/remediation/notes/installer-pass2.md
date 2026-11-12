# install_mediamtx.sh pass 2 notes (for the documentation pass)

Findings LB-06 and LB-22 (installer side), LB-02/X-12/LB-12 (the unit the installer writes),
the two defects pass 1 left (N-1, N-2) and the supply-chain question about MediaMTX's own
`--upgrade`; decisions D9, D10, D12, D14, D15. Code: `install_mediamtx.sh`,
`config/mediamtx.service` (the single template). Tests: `tests/test_install_mediamtx.bats`
(100 -> 132), the new `tests/test_install_mediamtx_live.bats` (5, real MediaMTX binaries,
skipped without `LYREBIRD_TEST_MEDIAMTX_BINS`) and the new helper
`tests/installer_fixture.bash`. Pass 1 notes: `installer.md`.

Evidence labels: **R** = reproduced by running the real code, **S** = source read only,
**HW** = needs a real systemd manager or real hardware.

## What was wrong, and what is true now

### The configuration `install` writes (LB-06, LB-22, N-2)

Was (R, real MediaMTX 1.21.1, `scratchpad/inst2/repro/old_config.sh`): a heredoc of its
own. API (`:9997`) and metrics (`:9998`) listened on **every interface**; SRT and, from
1.19, MoQ listened too; `paths: {}` made MediaMTX answer every publisher with `path 'mic1' is
not configured` (ffmpeg: `400 Bad Request`), so a MediaMTX the installer had configured could
publish nothing until the stream manager rewrote the file; no ownership marker; the three
port variables were written as given (`MEDIAMTX_API_PORT=abc` went into the YAML).

Now: `create_config` renders `lyrebird_render_mediamtx_config` (`lyrebird-common.sh`), the
generator the stream manager uses, so there is one generator. Checked on MediaMTX 1.15.0,
1.18.0, 1.19.0, 1.21.1, 1.21.2, 1.21.3 (R, `test_install_mediamtx_live.bats`): the file the
installer writes loads on all six; MediaMTX opens exactly RTSP (every interface), API and
metrics (loopback only), and the two UDP ports of RTSP, and nothing else (no SRT, MoQ, RTMP,
HLS, WebRTC); anonymous RTSP publish and read work from this machine; a connection to the
machine's own non-loopback address cannot reach the API or the metrics endpoint.

- The file is the renderer's output for the version of the **installed binary**
  (`mediamtx --version`; the release being installed if the binary will not say; with neither,
  the keys only newer versions have are left out and a warning says what that costs). `moq: no`
  is written for 1.19 and later only (older versions refuse to start with the key).
- Where MediaMTX has `--validate-conf` (1.21.1, 1.21.2, 1.21.3: checked with `--help`), the new
  binary validates the rendering before the file is replaced; a rejection stops `install`
  (exit **9**, not 7: the orchestrator's setup wizard reads the installer's exit 7 as "already
  installed" and carries on) with MediaMTX's own message and nothing is written. Older binaries have no such
  check.
- Written with `lyrebird_atomic_write` (temp file in the same directory, fsync, rename, fsync of
  the directory), mode 0644. The old `chown root:root` is gone: the installer runs as root, so
  the file is root's.
- Ports (N-2): `MEDIAMTX_RTSP_PORT`, `MEDIAMTX_API_PORT`, `MEDIAMTX_METRICS_PORT` must be decimal
  integers 1-65535 (leading zeros are fine and are not octal; an empty variable means the
  default). Anything else stops `install` with exit **10** and `MEDIAMTX_API_PORT must be an
  integer from 1 to 65535 (got: abc)`, and the three must differ (the generator's message is
  shown). This happens before anything is downloaded, installed or written. Only `install`
  validates (the other commands do not write the ports; `status` only looks at them).
- `install` and `create_config` need `lyrebird-common.sh` next to the installer (it holds the
  generator and the atomic writer); without it they stop at once with exit **4** and say so.
  `--no-config --no-service` needs no library. Run the installer from a checkout.

#### Who owns `/etc/mediamtx/mediamtx.yml` (D10), what the installer does

- The first line of a file LyreBirdAudio generated is exactly `# Managed by LyreBirdAudio`.
- **No file**: written. **A file with the marker** (the installer's own earlier output, or the
  stream manager's): an identical rendering leaves it untouched (same inode and mtime, no
  backup); a different one is replaced after a copy, `mediamtx.yml.backup.<YYYYmmdd-HHMMSS>`
  next to it (`cp -p`: mode and owner kept, so a 0640 file's copy is not world readable; a
  second backup in the same second gets `.1`, `.2`, ... instead of overwriting the first). The
  backup name is the one earlier versions used; there is no retention (the manager keeps the
  newest five of its own `.bak` files; this installer keeps them all, `install` over an existing
  file is rare). An empty file (what a power cut during the old non-durable write leaves) is
  replaced.
- **A file without the marker is the operator's.** Without `--force` `install` leaves it exactly
  as it is, with a warning that says why and how to replace it (when `install` runs at all: it
  refuses an existing installation without `--force`, so this happens when the binary is
  missing but the file is there, for example a pre-staged hardened file). **With `--force`** it
  saves the backup, replaces the file with the generated one and says so
  (`... was not generated by LyreBirdAudio: replacing it because --force was given`). The file
  the previous installer wrote is recognised by its first two lines and the message says what
  is wrong with it (every-interface API and metrics, SRT/MoQ on, no publisher accepted).
- **To take ownership of a generated file** (hand edits that must survive): delete the first
  line. From then on neither the installer (without `--force`) nor the stream manager rewrites it.
  `--force` on the installer, or `lyrebird-stream-manager.sh --regenerate-config start`, hands it
  back (a backup is saved first).
- **Existing nodes** keep what the old installer wrote until someone replaces it: that file has
  no marker, so it is treated as the operator's by the installer and by the stream manager; its
  API and metrics stay on every interface, SRT/MoQ stay on, and `paths: {}` still refuses every
  publisher (the stream manager's own start is what normally rewrites it, via
  `--regenerate-config`, see `mediamtx-config.md`). Standalone `mediamtx.service` nodes: run
  `sudo ./install_mediamtx.sh --force install` (this also reinstalls the latest binary; pin
  with `-V` to stay on the installed version; the old file is saved as `mediamtx.yml.backup.*`).
  `update` never touches the configuration or the unit.

### The unit `install` writes (LB-02 installer unit side, X-12, LB-12, D12)

Was (S/R): a heredoc with `ExecReload=/bin/kill -USR1 $MAINPID` (MediaMTX 1.21.1 ignores
USR1, R in `stream-monitoring-units.md`), `StartLimitInterval=60`/`StartLimitBurst=3` under
`[Service]` (accepted by systemd 255, non-canonical), no `Conflicts=`.

Now: `render_service_unit` takes `config/mediamtx.service` and replaces only the lines the
template's header lists: `ExecStart=` (binary and configuration file), the commented `# User=mediamtx`
and `# Group=mediamtx` (become `User=${SERVICE_USER}`, `Group=${SERVICE_GROUP}`, as before),
`WorkingDirectory=` (state directory), `ReadWritePaths=` (`/var/log`, state directory,
configuration directory) and `StandardOutput=`/`StandardError=` (`journal`, as before). Everything
else, comments included, is copied; a test pins that with default settings exactly those lines differ,
and with every setting changed only those keys differ. The result has `Conflicts=mediamtx-audio.service`,
`StartLimitIntervalSec=300` and `StartLimitBurst=5` in `[Unit]`, and no `ExecReload=` (MediaMTX
re-reads its file by itself; HUP ends it). `systemd-analyze verify` (systemd 255.4) finds nothing in
the rendered unit, alone or together with `config/mediamtx-audio.service`.

- The unit is written with `lyrebird_atomic_write` (0644), a copy of an existing unit is kept as
  `mediamtx.service.backup.<time>` (`cp -p`), `systemctl daemon-reload` runs last.
- Refused before anything is changed or downloaded (`install` checks first), exit **10**: a path
  (prefix, configuration directory, state directory) outside `A-Za-z0-9_./+-` (a space used to produce
  a broken unit), a service account name outside `A-Za-z0-9_.-` (a newline would start a new directive),
  a missing template and a template without one of the lines to replace (so template and installer
  cannot drift apart unnoticed). The template is `config/mediamtx.service` next to the installer.
- New environment variables read by the installer: `MEDIAMTX_SERVICE_DIR` (directory of the unit,
  default `/etc/systemd/system`, for packaging and tests) and `MEDIAMTX_UNIT_TEMPLATE`.
- **Differences between the unit nodes have and the unit new installs get** (the template wins; the
  stream manager's unit is untouched):

  | | old installer unit | rendered from the template |
  |---|---|---|
  | `Conflicts=` | none | `mediamtx-audio.service` (symmetric: the stream manager's unit already conflicted) |
  | start limit | `StartLimitInterval=60`, `StartLimitBurst=3` in `[Service]` | `StartLimitIntervalSec=300`, `StartLimitBurst=5` in `[Unit]` |
  | `ExecReload=` | `/bin/kill -USR1 $MAINPID` (a no-op) | none: `systemctl reload mediamtx` now says the unit cannot reload |
  | `RestartSec=` | 10 | 5 |
  | `Description=` | MediaMTX Media Server | MediaMTX RTSP Media Server |
  | `Environment="HOME=..."` | state directory | none (systemd sets `$HOME` from the account's passwd entry, S; the installer creates the account with the state directory as its home) |
  | `RuntimeDirectory=mediamtx` | yes | none (nothing in MediaMTX uses it, S) |
  | `ReadWritePaths=` | `/var/log`, state dir | `/var/log`, state dir, configuration dir |
  | `LimitNOFILE=` | 65536 | 65535 |
  | new | | `LimitCORE=0`, `MemoryMax=512M`, `MemoryHigh=400M`, `TimeoutStopSec=15`, `ProtectKernelTunables/Modules`, `ProtectControlGroups` |
  | unchanged | `Type=simple`, `User=`, `Group=`, `ExecStart=`, `Restart=always`, `StateDirectory=mediamtx`, `ProtectSystem=strict`, `ProtectHome`, `PrivateTmp`, `NoNewPrivileges`, journal logging, `SyslogIdentifier=mediamtx`, `After=`/`Wants=network-online.target` | |

  Decisions the lead should confirm: `MemoryMax=512M` is a cgroup kill threshold the installer unit never
  had (the manager's unit deliberately sets none); `RestartPreventExitStatus=SIGTERM SIGINT` was **removed
  from the template** (the old installer unit restarted after any exit, and the manager's unit dropped the
  same line: a SIGTERM from something other than systemd must not leave an unattended node down);
  `StateDirectory=mediamtx` was **added to the template** (the installer unit had it).
- `config/mediamtx.service` is still a complete unit that works copied by hand (as root, default
  paths); its header now says what the installer rewrites and why `StandardOutput=` differs.
- Nodes keep the unit they have until `install --force` writes a new one (`update` does not).
  Documentation that says `systemctl reload mediamtx` reloads MediaMTX: it never did (USR1 is ignored);
  the file is re-read by MediaMTX itself.

### `update`: MediaMTX's own `--upgrade` (supply chain), and N-1

**`--upgrade` bypassed the checksum (S, read; not executed, see below).** Without `-V`, `update`
ran the installed MediaMTX's own `mediamtx --upgrade`. Upstream's implementation
(`internal/upgrade/upgrade.go` at v1.21.3, fetched and read): it lists the repository's tags with
go-git, takes the newest `v1.x.y`, downloads
`https://github.com/bluenviron/mediamtx/releases/download/<tag>/mediamtx_<tag>_<os>_<arch>.<ext>`
with `http.Get` and applies the executable with `selfupdate.Apply(..., selfupdate.Options{})`: **no
checksum and no signature is checked**, `--force` or not, and "the latest tag" is not the "latest
release" the installer had asked GitHub for (a tag can exist before its release is published). The
installer compared the printed version only after the executable had been replaced, and then ran
the new executable (`--version`). Also **MIN_UPGRADE_VERSION=1.15.0 was wrong**: the real v1.15.0 has no
`--upgrade` flag (`--help` lists it from 1.18.0; checked on the six binaries; 1.16/1.17 not
available here, so where it first appeared is unknown). `--upgrade` was not run against a real
binary here (it would contact GitHub and replace the binary); the tests emulate it with a script.

Now: `update` always takes the path `install` takes: `get_release_info`, `download_mediamtx`
(tarball, `checksums.sha256`: a **mismatch is fatal even with `--force`**; `--force` skips the check
only when no checksum file or hash is available), extraction, `install -m 755` and an atomic
rename, with the previous binary kept as `mediamtx.backup.<time>` and restored on failure. `MIN_UPGRADE_VERSION` and
the `--upgrade` block are gone; `--help` says so (`version_compare` stays: eight tests pin it, the
script no longer calls it).

**N-1 (R).** `update` of a MediaMTX nobody supervises (mode `manual`) always ended rolled back, exit 7
(`start_mediamtx manual` only logs, then six seconds of waiting for a process). Now:
- after the new binary is in place, `mediamtx --version` must run (all modes; a binary that cannot
  print its version stops the update with exit 7 and rolls back to the previous binary; the old code
  left such a binary installed whenever nothing started it afterwards);
- in `manual` mode MediaMTX is **left stopped** (the installer stopped it), the exit status is 0, and
  three warnings say so and print the command, for example `/usr/local/bin/mediamtx
  /etc/mediamtx/mediamtx.yml`; `start_mediamtx manual` (also what a rollback prints) now includes the
  command;
- `systemd`, `stream-manager-service` and `stream-manager` modes verify exactly as before (start, then
  wait up to six seconds; failure -> exit 7, previous binary restored, a restart tried again).
  Tests with a `systemctl` stand-in and a manager stand-in pin that.

Real MediaMTX (live tests): started by hand on the installed binary and configuration, `update` stops
that process (and only that one: identity by exe path and argv[1], pass 1), installs the verified
binary, exits 0 and prints the command; started again with it, the new binary loads the old
configuration (checked on 1.15.0 ... 1.21.3). With a new binary that does not run, exit 7 and the real
old binary is back byte for byte and starts.

**New (found by this pass, R): an update across 1.19 re-opened MoQ; fixed by the lead after the merge.**
`install` of 1.18.0 then `update` to 1.21.3 left a configuration without `moq: no` (1.18 rejects the
key) and MediaMTX 1.21.3 on it listens on MoQ (8892 tcp and udp, 8893 udp, every interface;
`scratchpad/inst2/repro/update_across_moq.sh`). The worker only warned. Now `ensure_moq_off` (modes
other than the stream manager's, which renders its file at every start) adds the one line `moq: no`
after `srt: no` to a file whose first line is the managed marker, when the new binary is 1.19 or
later and the file has no `moq:` key. It does not render the file again (that could reset ports the
install was given through variables this run does not have), keeps the previous file as
`mediamtx.yml.backup.<time>`, validates the result with `--validate-conf` where the binary has it, and a
rolled-back update puts the previous file back (the older binary rejects the key). A file that is not ours,
or one MediaMTX rejects with the line added, is left alone, with a warning for the second case. Tests:
"update adds moq: no to a generated configuration when it crosses MediaMTX 1.19, and stays quiet when
there is nothing to add [LB-06 installer]", "update leaves a generated configuration as it is, and says
so, when MediaMTX rejects it with moq: no added [LB-06 installer]", "a rolled-back update puts the
generated configuration back: the older binary rejects the moq key it had added [LB-06 installer, N-1]";
all three fail with `ensure_moq_off` reduced to a no-op, and the first and third fail without the
backup.

**Changed by the lead after the merge: `update` downloads and verifies before it stops MediaMTX.** The
worker found MediaMTX was down for the whole download (the order was stop, back up, download). Now the
verified download (and the checksum check) comes first; a failed download or a mismatch leaves MediaMTX
running, untouched and not restarted (the rollback restarts only what the update stopped). Test:
"update downloads and verifies before it stops MediaMTX: a failed download or a wrong checksum leaves it
running, untouched and not restarted [availability]" (fails with the old order). The pass 1 test "update_mediamtx leaves the installed binary alone and stops when
MediaMTX cannot be stopped [LB-10 installer]" asserted that nothing was downloaded; its other assertions
(binary unchanged, no backup, no signal) are kept and it now asserts that the download came first.

## Documentation consequences

- `README.md` L206 ("Built-in upgrade support (v1.15.0+)") and L1894 ("Built-in upgrade support for
  MediaMTX 1.15.0+"), `docs/components.html` L373: remove. Say instead: `update` downloads the release
  tarball, verifies it against `checksums.sha256`, installs it atomically and restarts MediaMTX through
  its owner (systemd or the stream manager); a failed start rolls back to the previous binary; MediaMTX's
  own `--upgrade` is **not** used because it applies no checksum. A MediaMTX started by hand is stopped
  and **not** started again (the command is printed; exit 0).
- README "MediaMTX Installer" options: `-f, --force` also replaces a configuration file that is not
  LyreBirdAudio's (after a backup) and never accepts a checksum mismatch; `--no-config` skips the
  file; new variables `MEDIAMTX_SERVICE_DIR`, `MEDIAMTX_UNIT_TEMPLATE`, and (pass 1) `MEDIAMTX_STOP_TIMEOUT`,
  `MEDIAMTX_PID_FILE`; exit codes: 4 (no `lyrebird-common.sh`), 9 (MediaMTX rejects the generated
  configuration), 10 (a port, path or account name the configuration or the unit cannot carry). "Configuration file generation" and "Systemd service creation":
  the configuration is the shared generator's (marker first line, loopback API and metrics, every other
  protocol off) and the unit is rendered from `config/mediamtx.service`; the installer must run from a
  checkout.
- `docs/SECURITY-GUIDE.md` (not edited here), the paragraph before "Default behavior" (about L38-43): "The
  configuration written by `install_mediamtx.sh` disables WebRTC, HLS and RTMP but leaves MediaMTX's SRT
  (and, on 1.19+, MoQ) listeners at their defaults until the stream manager next regenerates the file" is no
  longer true for a node installed with this version; it is still true for a node installed with an earlier
  one until the file is replaced (see "Existing nodes" above). The table row "The listener accepts
  connections on all interfaces" for the API and metrics applies only to files an earlier release wrote.
  The "Option 1" note that the stream manager regenerates the file on every start is reconciled by
  `mediamtx-config.md`.
- README L981 and L2133 tell the reader to run `mediamtx --check`; MediaMTX has no such flag (the real one
  is `--validate-conf=FILE`, from 1.21.1; checked with `--help` on the six binaries). Found, not mine.
- `docs/troubleshooting.html` / README: `systemctl reload mediamtx` does nothing useful on a standalone
  install (no `ExecReload=`); MediaMTX picks up a changed file by itself.
- The `install_mediamtx.sh` header comment (v2.0.0 line) and `SCRIPT_VERSION` 2.0.1 were **not** changed;
  the lead decides the release number. The README lists the installer as 2.0.1.
- `tests/README.md`: `test_install_mediamtx.bats` is 132 tests (was 100: 66 in the table is stale); new
  `test_install_mediamtx_live.bats` (5 live tests, six MediaMTX versions each, ~2 minutes for the whole
  list, needs curl, ffmpeg, ffprobe, tar and python3, binds no default port), new helper
  `tests/installer_fixture.bash` (a local stand-in for GitHub's release downloads that leaves the
  installer's download, checksum, extraction and install code real). `bash-ci.yml`'s two live steps run the new file (one
  line appended to each).

## For docs/remediation-status.json (the lead edits it)

Suggested, by finding (test names exact; all in `tests/test_install_mediamtx.bats` unless a file is named):

- **LB-22**: the installer side is fixed; the manager side already was. Installer tests:
  "create_config writes the shared generator's configuration for the installed binary, byte for byte, marker first [LB-22 installer, LB-06 installer]",
  "create_config writes through lyrebird_atomic_write, and a write that fails leaves the old file as it was [LB-22 installer]",
  "a managed file whose rendering is unchanged is left untouched: same inode, same mtime, no backup [LB-22 installer]",
  "a managed file whose rendering changes is replaced after a timestamped backup of the old one [LB-22 installer]",
  "an operator-owned file is not overwritten without --force: bytes, mode and inode survive, and the message says how to replace it [LB-22 installer]",
  "--force replaces an operator-owned file after saving a backup with its mode, and says it is doing so [LB-22 installer]",
  "the generated configuration is validated by the binary that will run it, before the file is replaced [LB-22 installer]",
  "the stream manager takes the installer's file as its own: for the same settings the two generators agree, so a manager start leaves it untouched [LB-22 installer, D10]"
  (the two generators agree byte for byte, so the manager's first start on an installer-written file changes nothing and saves no backup).
- **LB-06**: installer side fixed, so the finding can close once the documentation pass has corrected
  the SECURITY-GUIDE. Tests: the live file's "install writes a configuration every MediaMTX version accepts and opens exactly the sockets it names: no SRT, MoQ, RTMP, HLS or WebRTC [LB-06 installer, LB-22 installer]",
  "through the installed configuration a publisher without credentials publishes and a client without credentials reads, from this machine [LB-06 installer]",
  "the API and the metrics endpoint of the installed configuration cannot be reached from a remote address, and answer on this machine's loopback address [LB-06 installer, D9]",
  and "create_config leaves the moq key to the installed binary's version, and says so when it cannot tell [LB-06 installer]",
  "update adds moq: no to a generated configuration when it crosses MediaMTX 1.19, and stays quiet when there is nothing to add [LB-06 installer]".
  Residual: nodes installed with an earlier installer keep their file until replaced (see above).
- **LB-02**: the unit the installer writes now conflicts with the manager's unit. Tests:
  "the rendered unit conflicts with the stream manager's unit, has the start limit in [Unit] and no ExecReload or signal, and the script writes no unit text of its own [LB-02 installer, X-12, LB-12]",
  "systemd accepts the rendered unit with no finding, alone and together with the stream manager's unit [LB-02 installer, LB-12, D12]",
  "the unit with the default settings is the template, with only the lines its header lists replaced [LB-02 installer, D12: no drift]".
  LB-02 can be `fixed` (the manager side was fixed earlier; the Conflicts=/After= transaction at boot still needs a real systemd manager: HW).
- **X-12** (installer unit): no `ExecReload=` any more; same three tests. **LB-12**: the installer's unit has the
  canonical placement. **LB-11**: "the installer-generated unit" note is closed; the HW items stay.
- **N-2** (port validation), new id suggested: "a port that is not an integer from 1 to 65535 stops create_config with a message that names the variable, and nothing is written [N-2]",
  "install checks the ports and the generator before it downloads or writes anything [N-2, LB-22 installer]",
  "ports with leading zeros are read as decimal, and an empty variable means the default [N-2, X-19 installer]".
  X-19: the installer part now validates as well.
- **N-1** (manual-mode update), new id suggested: "update in manual mode ends successfully with the new binary in place, MediaMTX stopped, and says how to start it, instead of rolling back [N-1]",
  "update rolls back, restoring the previous binary, when the new binary does not run: with MediaMTX stopped by hand, and with nothing running [N-1]",
  "update in service modes still verifies that the service came back: success when it is active, rollback with the previous binary when it is not [N-1, unchanged verification]",
  "update in stream-manager mode still verifies by identity that MediaMTX came back, and rolls back when it did not [N-1, unchanged verification]";
  live: "update in manual mode on a real MediaMTX stops it by identity, installs the verified binary, exits 0 and says how to start it; the new binary loads the old configuration [N-1]".
- **Supply chain** (`--upgrade`), new id suggested: "update never runs the installed MediaMTX's own --upgrade: the binary that ends up installed is the one from the verified tarball [supply chain]",
  "update with a wrong published checksum is fatal, exit 6, and leaves the previous binary installed; --force does not accept a mismatch [supply chain]",
  "the help says update is a verified download with rollback and does not claim a built-in upgrade [supply chain]".

## Two tests changed (they encoded the old behaviour)

`create_config writes the RTSP, API and metrics ports named by the environment [X-19 installer]` and
`create_config keeps the documented default ports when the variables are unset [X-19 installer]` asserted
`apiAddress: :PORT` and `metricsAddress: :PORT` (every interface). They now assert `127.0.0.1:PORT`; the
port assertions and the test names (the register names them) are unchanged.

## What was run

Gates on `install_mediamtx.sh` (`bash -n`, ShellCheck 0.11.0 at warning severity and at default severity,
`shfmt -d -i 4 -bn -ci`, `bashate`): no finding. The whole suite through `tests/check_tmp_leaks.sh`: **1496
tests, 1496 ok, 0 failed, 42 skipped** (the live files without `LYREBIRD_TEST_MEDIAMTX_BINS`, and the tests
that were skipped before), no temp file left behind; 1459 before this pass (+32 in `test_install_mediamtx.bats`,
+5 live). `tests/test_install_mediamtx_live.bats` with all six real MediaMTX binaries: 5 of 5, about 2.5 minutes.
Mutation checks are in the commit messages.

## Not verified here (HW) and residual risk

- No real systemd manager ran: the unit was parsed by `systemd-analyze verify` only. Not run: `Conflicts=`
  between the two units at boot or when one is started over the other, `StateDirectory=` creation and
  ownership with `User=mediamtx`, `ProtectSystem=strict` with the configuration directory writable,
  `StandardOutput=journal`, the start limit and `RestartSec=` timing, `MemoryMax=512M` with real traffic.
  `HOME` set from the passwd entry and `systemctl reload` of a unit with no `ExecReload=` are from systemd's
  documentation, not run.
- `useradd`/`adduser`, `userdel`, the real `/etc/systemd/system` and macOS/BSD were not touched or run (tests
  use the root account as the service user and `MEDIAMTX_SERVICE_DIR`/`MEDIAMTX_CONFIG_DIR` in temp dirs).
  Bash 4.2 itself was not run (the new code avoids what came after it: `${var@Q}`, `mapfile -d`, `declare -n`,
  `${var^^}`, negative array subscripts; it uses `mapfile`, `local -A` and the `${arr[@]+"${arr[@]}"}` idiom, all
  available in 4.0+).
- `update` downloads and verifies **after** it has stopped MediaMTX (pass 1 order, a pass 1 test pins it):
  on a slow uplink MediaMTX is down for the length of the download, up to the retry budget (3 attempts of
  up to 300 s). Moving the download before the stop would shorten the outage; it changes that test.
- `update` neither rewrites the configuration nor refreshes the unit; nodes keep both until `install --force`.
- A manual-mode update does not check that the new binary accepts the existing configuration (service modes
  find out by the start that follows); `--validate-conf` exists from 1.21.1 only. The operator sees the error
  when starting MediaMTX by hand.
- `install --force` over a file keeps every `mediamtx.yml.backup.*` and `mediamtx.service.backup.*` (no
  retention); `update` keeps three binary backups (unchanged).
- A node whose user already exists but whose state directory was removed: the unit's `WorkingDirectory=`
  and `ReadWritePaths=` name a missing directory when the state directory is not the default one (with the
  default, `StateDirectory=mediamtx` creates it). Unchanged by this pass (`create_user` only creates the
  directory when it creates the user).
