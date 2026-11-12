# lyrebird-orchestrator.sh notes (for the documentation pass)

Finding LB-21 (wizard and menu status semantics), the orchestrator side of X-21
(the updater's `--history` / `--rollback` in the menu), and defects found while
testing. Orchestrator version **2.2.0** (was 2.1.3). Code: `lyrebird-orchestrator.sh`
("Stream Outcome" section, `execute_script`, `describe_exit_code`,
`menu_quick_setup`, `wizard_summary`, `menu_streaming`, `menu_versions`,
`rollback_to_previous_version`). Nothing here has been edited into README.md,
CHANGELOG.md, docs/*.html or SECURITY*.md.

Evidence labels: **R** = reproduced by running the real code, **S** = source
read only, **HW** = needs real hardware or a real system manager.

## What was wrong

| # | Sev | Ev. | Defect |
|---|-----|-----|--------|
| 1 | P2 | R | The wizard's final summary read `MEDIAMTX_RUNNING` / `ACTIVE_STREAMS`, refreshed after step 2 (before the start of step 3) and refreshed again only after the summary. A good start on a fresh node ended in "Setup completed with warnings ... Your system may require a reboot before streams become available"; a **failed** start (exit 9) on a node that was already streaming ended in "Quick setup complete!" and "+ Your RTSP streams are now available!" (reproduced against the pre-fix script with stand-in delegated scripts: `tests/test_orchestrator_wizard.bats`). |
| 2 | P2 | R | The menu called `execute_script "stream_manager" start / restart || true`. `execute_script` printed `failed (exit code: N)` but the user never learned what N meant (9 = no stream is publishing, 5 = busy, 8 = another MediaMTX owns the node ...), which stream failed or why, or what to do. The installer's failures were not printed at all (only kept in `LAST_ERROR`, shown after the next screen clear). |
| 3 | P3 | R | `get_primary_ip` declared `local primary_ip` without a value: on a system without the `ip` command, `[[ -z "$primary_ip" ]]` is an unbound variable under `set -u`; `primary_ip="$(get_primary_ip)"` (menu "View Stream URLs", and the wizard's URL list) then ended the whole orchestrator. Found because this container has no `ip`. |
| 4 | P3 | S/R | The menu had no way to reach the updater's `--history` and `--rollback`. |

## What the orchestrator does now

### One exit status, one meaning

- `LAST_EXIT_CODE` (global): the real exit status of the script the last
  `execute_script` call delegated to; empty when it ran nothing (unknown key,
  integrity check failed). `execute_script`'s own return value is unchanged
  (0 / 1, the installer's real status, the diagnostics 0/1/2).
- The failure line, and `LAST_ERROR` (the "Last Error:" line of the next menu
  redraw), now read `<script> failed (exit code: N - <meaning>)` for the stream
  manager (1-10, 128+N) and the updater (1-11). A status without a documented
  meaning is shown as before (`failed (exit code: N)`).

  | stream manager | meaning shown |
  |---|---|
  | 1 | general error; see the message above and the stream manager log |
  | 2 | critical resource state (disk, memory or file descriptors) |
  | 3 | a required tool or the MediaMTX binary is missing |
  | 4 | invalid configuration (start policy, device configuration or MediaMTX configuration) |
  | 5 | another lifecycle command (start, stop or restart) is running; nothing was changed, try again shortly |
  | 6 | no USB audio device is detected and starting without one is disabled (LYREBIRD_ALLOW_EMPTY_START=false) |
  | 7 | MediaMTX is not running |
  | 8 | another MediaMTX owns this node (for example mediamtx.service); nothing was changed |
  | 9 | no stream is publishing, so the start policy was not met; what the start launched was stopped again |
  | 10 | some streams are not publishing (monitor) |
  | 128+N | terminated by signal N (SIGINT, SIGTERM, ...) |

  | updater | meaning shown |
  |---|---|
  | 1 | general error |
  | 2 | prerequisites not met |
  | 3 | not a git repository |
  | 4 | could not reach the remote (fetch failed) or no remote is configured |
  | 5 | permission problem: the repository is not writable or is owned by root, or the lock cannot be written |
  | 6 | that version is not available in this clone (a rollback never uses the network) |
  | 7 | another updater is running |
  | 8 | unusable git state (a merge or rebase is in progress, or the update journal is unreadable) |
  | 9 | cancelled (a prompt was declined, or the run was interrupted) |
  | 10 | the switch is done, but your saved changes conflict with the new version and were NOT re-applied; they are in the git stash |
  | 11 | the automatic rollback could not restore everything; the updater's message names the 'git checkout --force' command to run |

- MediaMTX menu (options 1-4): after an install / update / reinstall / uninstall
  that failed, one line right away: `MediaMTX <action> failed (installer exit code:
  N); see the installer's message above`; exit 7 (which the installer uses both
  for "already installed" and for several failed install steps) reads `The
  installer exited with code 7: MediaMTX is already installed (use Update or
  Reinstall), or an install step failed; the installer's message above says which`.
- The `|| true` that remain after `execute_script` (USB mapper, mic check, stop,
  status, URLs, monitor, the interactive updater, history) are failures that are
  not fatal for the menu **and** have already been printed, with their status and
  meaning, by `execute_script`. `tests/test_orchestrator_delegation.bats` has a
  test that fails if any delegated script's failure is neither shown nor recorded,
  and one that drives every delegating menu action with a failing script.

### Reading the real outcome of a start or restart

Menu 4 -> 1 (Start All Streams), 4 -> 3 (Restart All Streams) and the wizard's
step 3 run `run_stream_lifecycle`:

1. Keep the exit status (`LAST_EXIT_CODE`).
2. Read what the command left, in this order:
   - **the status file** (`LYREBIRD_STATUS_FILE`, else
     `LYREBIRD_STATE_DIR/status.json`, else `/run/lyrebird/status.json`: the
     manager's own precedence), **if its text differs from its text before the
     command** (so a refused start, exit 5 or 8, which writes nothing, never
     reports an earlier document as its own; judged by text, not by timestamps,
     so a clock step cannot fool it);
   - if the command exited 0 and left no usable file: the live
     `lyrebird-stream-manager.sh status --json` (no terminal, at most 60 s;
     costs the manager's flow sample, 3 s as shipped);
   - otherwise the exit status alone.
3. Classify and print: one line per stream with the manager's `last_error` for
   each stream that is not publishing, a headline, and the next step.

   | exit | document says | shown |
   |------|---------------|-------|
   | 0 | `overall: ok` | `[OK] All N stream(s) are publishing`, each stream `publishing, bytes flowing` |
   | 0 | `degraded` | `Degraded: k of N streams are publishing`, each stream with its reason, next steps |
   | 0 | `waiting_for_devices` | `MediaMTX is running and waiting for devices: no USB microphone is detected, so no stream is publishing yet`; next: plug one in; the monitor cron job (`/etc/cron.d/mediamtx-monitor`, every 5 minutes as shipped) starts its stream on its next run, or, when that file is absent, "no monitor cron job is installed ... nothing will start the stream by itself"; or Start All Streams to do it now |
   | 0 | `failed` / `stopped` / unknown | `The start reported success, but the stream manager now reports the node as '<overall>'` |
   | 0 | nothing readable | `The start reported success (exit code 0), but the stream state could not be read (<why>); whether streams are publishing is not confirmed here` |
   | 9 | `mediamtx.running: true` | `MediaMTX is up but no stream is publishing` + reasons |
   | 9 | `mediamtx.running: false` | `No stream is publishing, and MediaMTX was stopped again: a failed start takes down what it started` + reasons |
   | 9 | `policy: strict` | `Not every stream is publishing, and the start policy 'strict' requires every stream: what the start started was stopped again` |
   | 9 | nothing readable | `The start did not meet its start policy: no stream is publishing (exit code 9)` |
   | 1, 3, 4, 5, 6, 8, other | (not used for the headline) | the meaning line from `execute_script` plus a next step (3: install the missing tools or MediaMTX; 4: Validate Device Configuration and the manager log; 5: wait for the other command; 6: plug in a microphone; 8: stop the other MediaMTX first, e.g. `sudo systemctl stop mediamtx.service`; otherwise the manager log) |

   Per-stream wording: `publishing, bytes flowing`; `path ready, but no bytes
   are flowing`; `publishing (byte flow not measured)` (`bytes_flowing: null`);
   `not publishing`; `state unknown (the MediaMTX API did not answer)`
   (`path_ready: null`).

   **What the manager really leaves after exit 9** (verified by the contract test
   against the real `start_mediamtx`): a start that failed its policy takes down
   the MediaMTX it launched, so the document says `mediamtx.running: false` and
   `overall: failed`, each stream with its reason. Only when the stack was already
   running (the repeated start of LB-01, e.g. under `strict`) is MediaMTX still up.
   "MediaMTX is up but no stream is publishing" is therefore not what a fresh
   failed start looks like; the orchestrator says which it is.
4. The document is data from outside: needs `jq` (the manager's own dependency;
   without it the exit status alone is used); only `schema_version: 1` is read
   (anything else is "not readable"); `overall` / `policy` / `mediamtx.running`
   outside the documented values become `unknown`; control characters are
   removed; values are printed with `%s` (no escape or backslash is
   interpreted); at most 100 streams are listed (`... and N more`). The fields
   used: `overall`, `policy`, `mediamtx.running`, `streams[].path`,
   `.path_ready`, `.bytes_flowing`, `.last_error`. A manager that bumps
   `schema_version` makes the orchestrator fall back to the exit status until it is
   taught the new schema (the contract tests in
   `tests/test_orchestrator_manager_contract.bats` read documents written by the
   real manager and fail first).
5. Nothing in this path can fail the orchestrator: every failure to read degrades
   to the exit status alone. A line is logged to the orchestrator log: `stream
   manager start: exit status 9, verdict streams_failed, state failed (status
   file)`.

### The Quick Setup Wizard

Same four steps, same prompts, same numbers. Step 3 is the report above. The
final summary is decided by that outcome, not by `MEDIAMTX_RUNNING` /
`ACTIVE_STREAMS`; `refresh_system_state` is called after the start and the
diagnostics (it is still the basis for one case: exit 0 with nothing readable):

- `ok`: `Quick setup complete!`, `+ Your RTSP streams are now available!`, and the
  real URLs `rtsp://<primary ip>:<MEDIAMTX_RTSP_PORT or 8554>/<path>` of the streams
  that publish (instead of the invented `<device-name>` example);
- `degraded`: `Quick setup finished, but only k of N streams are publishing`,
  every stream with its reason, URLs of those that publish, next steps;
- `waiting_for_devices`: `Quick setup complete: MediaMTX is running.` / `No USB
  microphone is detected yet, so no stream is publishing.` and what to do (no failure,
  no reboot advice);
- exit 9, any other failing status, a start that could not be run, or a
  contradiction: `Quick setup did not finish: ...` with the reasons and the next
  step for that status;
- exit 0 with nothing readable: `Quick setup finished, but the stream state could
  not be confirmed`, then what the process list says now (MediaMTX and FFmpeg
  found after the start, or "probably not available").

"Reboot" advice is gone from the wizard: the mapper (>= 4.0.0) applies names
immediately; the wizard's own step 2 text already says so. Step 1's behaviour (an
installer exit 7 continues) is unchanged.

### Version Management (menu 6): history and rollback

`1) Launch Update Manager (Interactive)`, `2) Show Component Versions` and `0) Back`
keep their numbers; new:

- `3) Show Update History` runs `lyrebird-updater.sh --history` (local log; no
  network, lock or git).
- `4) Roll Back to a Previous Version`: shows `Before the last update this node ran:
  <tag or short hash> (<short hash>)` when the history has one (Enter selects it), or
  takes a typed release tag / commit hash already on the node; validates the typed
  text (letters, digits, `. _ / -`, not starting with `-` or `.`); asks `Continue?
  (y/n)` after `This will roll back LyreBirdAudio to: <version>`; runs
  `lyrebird-updater.sh --rollback [VERSION]` (Enter passes **no** version, so the
  updater goes to the exact commit its own history records; a typed version is passed
  as typed); refreshes the script integrity baseline afterwards (the updater rewrote
  the scripts, as for option 1); explains the updater's exit status (table above);
  says the updater finished only for exit 0, and then suggests restarting the
  orchestrator (it may have been replaced). Exit 6 adds a pointer to option 3.
- The "previous version" is read from `<git-dir>/lyrebird-updater/history.log` with
  the updater's own selection (`history_last_change`: the last record that is an
  `update`, `rollback` or `reset` with result `ok`), the directory derived as the
  updater does (a `.git` directory, or the directory named by a `.git` file in a
  linked worktree). The orchestrator does **not** honour `LYREBIRD_UPDATER_STATE_DIR`
  (the privilege-dropped updater is started with `env -i`, so it does not see it
  either). A test runs the real updater's `history_record` / `history_last_change`
  and the orchestrator against the same files and requires them to agree.
- The "Invalid option" message of the menu now says 0-4.

## Documentation consequences

- README "Using the Orchestrator" (about L329-352) and `docs/quick-start.html`
  ("Run the Setup Wizard"): the wizard has **four** steps (install MediaMTX, map USB
  devices, start streams, quick diagnostics). It does not generate a configuration
  and does not detect hardware capabilities (the README list says "Generate optimal
  configuration"; quick-start.html has a "Detect Hardware Capabilities" step): those
  are USB Device Management options 4-6. Say what the wizard ends with (above).
- README Main Menu list (about L433-439) and `docs/usage.html` (Main Menu table, row
  6 "Update scripts, check versions, rollback"): Version Management now has options
  1-4 as above (the usage.html row mentions rollback: it now has its own option).
  Audio Streaming Control: Start/Restart report the outcome per stream.
- README version table (about L1465): `lyrebird-orchestrator.sh | 2.2.0`.
- README "Orchestrator (lyrebird-orchestrator.sh)" Features list (about L1485): add
  "reads the stream manager's status document and reports each stream; explains the
  stream manager's and the updater's exit codes; update history and rollback".
- Wherever the stream manager's exit codes are documented (README "Exit Codes", about
  L1583; `docs/components.html`): the orchestrator is a consumer of 5, 8, 9 and 6.
- `tests/README.md` (not edited here): rows for `test_orchestrator_delegation.bats`
  (9 tests), `test_orchestrator_outcome.bats` (27), `test_orchestrator_wizard.bats` (9),
  `test_orchestrator_updater_menu.bats` (19), `test_orchestrator_manager_contract.bats`
  (6, uses the manager stage, about 50 s on a loaded machine);
  `test_lyrebird_orchestrator.bats` 48 -> 49 tests; the helper files
  `tests/orchestrator_helper.bash` and `tests/helpers/pty_run.py`; re-count the total
  with `bats --count tests/`. The orchestrator tests need `python3` (pty module) and
  `jq`; they run the real orchestrator against stand-ins for the six delegated
  scripts **on a pseudo-terminal**, because the orchestrator hands every delegated
  script `</dev/tty` (a CI runner has no controlling terminal).
- Register `docs/remediation-status.json` LB-21 (not edited here): the tests that
  prove it are, by name, in `tests/test_orchestrator_wizard.bats` (all),
  `tests/test_orchestrator_outcome.bats` (all), `tests/test_orchestrator_delegation.bats`
  (all), `tests/test_orchestrator_updater_menu.bats` (all, X-21 orchestrator side) and
  the `[LB-21]` test in `tests/test_lyrebird_orchestrator.bats` (get_primary_ip).

## Defects found, not fixed (out of scope or not mine)

| ID | Sev | Ev. | What |
|----|-----|-----|------|
| O-1 | P3 | S | The installer uses exit 7 for "already installed" **and** for "Failed to extract archive", "Binary not found in archive", "Failed to prepare/atomically install binary" (`install_mediamtx.sh` lines 1174, 1178, 1428, 1432). The wizard (unchanged) treats any 7 from `install` as "already installed; continuing", so a failed install would go on to steps 2-3 and fail at the start (the start's exit 3, "binary missing", is now explained). The menu says so honestly ("or an install step failed"); the wizard's step 1 still prints `MediaMTX is already installed; continuing with setup`. Fixing it means distinct installer exit codes (installer work). |
| O-2 | P3 | S | `refresh_system_state` (the header's `MediaMTX:` and `Active Streams:`) finds MediaMTX by process name `mediamtx` only and counts **every** `ffmpeg` process on the host as a stream; a MediaMTX started from a differently named binary shows as stopped, and any other FFmpeg shows as a stream. Now only the header and one fallback of the wizard use it. The status document has the truth (`mediamtx.running`, per-stream state); using it for the header would cost the manager's flow sample on every menu redraw. |
| O-3 | P3 | S | Menu 4 -> 5 "View Stream URLs" prints `rtsp://<ip>:8554/`, hard-coded (D15 makes the port configurable). The wizard's URLs honour `MEDIAMTX_RTSP_PORT` of the orchestrator's own environment (not the manager unit's `Environment=`). |
| O-4 | P3 | S | `lyrebird-updater.sh` menu option 1 ends the whole updater with the failing status when an action fails (U-18, updater.md), so an interactive session in which the user declined a prompt returns 9 and is shown as `failed (exit code: 9 - cancelled ...)`. Accurate but noisy; changing it is the updater's exit-code contract. |
| O-5 | P3 | S | Menu 4 -> 6 (Monitor Stream Health) shows the monitor's results 7 (MediaMTX not running) and 10 (streams degraded) as `failed (exit code: N - ...)`: they are results of a health check, not failures of the command. The meaning is right; the word "failed" is the generic execute_script wording. |
| O-6 | P3 | S | The wizard never runs the stream manager's `install` (the monitor cron job, `/etc/cron.d/mediamtx-monitor`, is written only by that command: `install_mediamtx.sh` mentions no cron file), so a node set up only by the wizard may have no monitor. That is why the "waiting for devices" next step checks for the file instead of promising that the monitor will pick the microphone up. Whether the wizard should install the unit and the cron job is a product decision (D1/D12 work), not made here. |

## Not verified here

- The privilege-dropped updater path (`sudo -u $SUDO_USER env -i ...`) was exercised
  through a `sudo` stand-in, not a real `sudo`; `--rollback` against a real clone is
  covered by the updater's own tests (`tests/test_lyrebird_updater_rollback.bats`), the
  orchestrator tests use a stand-in updater.
- The report was exercised against documents written by the real stream manager on its
  test stage (stand-in hardware, MediaMTX and FFmpeg), not against a real node.
- Bash 4.2 compatibility was reviewed (no namerefs, `${arr[@]+"${arr[@]}"}` for empty
  arrays, no `declare -g`, no 4.4+ features), not run on a 4.2 shell (this machine has
  5.2).
- The status document's `timestamp` / `timestamp_epoch` are not used: freshness is
  judged by comparing the file's text before and after the command.

## Internals (for anyone reading the code)

Added: `LAST_EXIT_CODE`, `describe_exit_code`, `delegated_failure_text`,
`report_installer_result`, `OUTCOME_*`, `LIFECYCLE_RC`, `LIFECYCLE_VERDICT`,
`STATUS_JQ_FILTER`, `OUTCOME_MAX_STREAMS`, `MONITOR_CRON_FILE` (a plain variable, not
an environment setting; the tests override it), `reset_outcome`, `status_file_path`,
`status_file_content`, `parse_status_document`, `query_status_document`,
`collect_lifecycle_outcome`, `describe_stream_state`, `print_outcome_streams`,
`classify_lifecycle`, `print_lifecycle_next_steps`, `report_lifecycle`,
`run_stream_lifecycle`, `print_stream_urls`, `wizard_summary`, `updater_state_dir`,
`updater_previous_version`, `ROLLBACK_FROM_COMMIT`, `ROLLBACK_FROM_LABEL`,
`rollback_to_previous_version`. Changed: `execute_script` (status kept, failure text),
`menu_quick_setup` (step 3, summary), `menu_streaming` (options 1 and 3),
`menu_mediamtx` (installer reports), `menu_versions` (options 3 and 4),
`get_primary_ip` (`local primary_ip=""`). Removed: the wizard's "Common causes: ...
(reboot may be needed)" text and its `MEDIAMTX_RUNNING` / `ACTIVE_STREAMS` verdict.
