# LyreBirdAudio Test Suite

Tests for LyreBirdAudio with the [Bats](https://github.com/bats-core/bats-core) framework. They run the real
scripts (sourced for their functions, or executed as commands) against fake sysfs and ALSA trees, decoy
processes, stand-in `systemctl` and `curl`, real git repositories, and, for the live files, real MediaMTX
binaries. Nothing here needs USB hardware, a real systemd manager or the network (the live files need the
MediaMTX tarballs, see below).

**1926 tests in 102 files** (`bats --count tests/`). The table below is generated from those counts;
`tests/test_docs_tests_readme.bats` fails when a file or a total in it is out of date.

## What is tested

| Area | What it covers | Files (tests) | Tests |
|------|----------------|---------------|-------|
| Shared library and repository | lyrebird-common.sh, how scripts find it, file modes, the Bash features the scripts use | `test_lyrebird_common` (49), `test_library_lookup` (6), `test_script_modes` (3), `test_bash_features` (3), `test_version_help` (3) | 64 |
| Stream manager: locks, ownership, lifecycle | lyrebird-stream-manager.sh: flock locks, process identity, start, stop, reload, signals, the monitor | `test_stream_manager` (29), `test_stream_manager_locks` (37), `test_stream_monitor_lock` (6), `test_stream_manager_ownership` (43), `test_stream_manager_reload` (13), `test_stream_manager_sighup` (5), `test_stream_manager_signals` (25), `test_stream_manager_removed_features` (14), `test_stream_manager_residuals` (13), `test_stream_reconcile` (16), `test_deep_health_check` (6) | 207 |
| Stream manager: outcome, status, configuration | what start reports and why, the status document, device configuration as data, stream names, generated wrappers, capture PCMs | `test_stream_outcome` (13), `test_stream_status` (17), `test_stream_status_nonroot` (3), `test_stream_device_config` (51), `test_device_config_durable` (10), `test_config_crash_safety` (4), `test_numeric_env_hardening` (5), `test_monotonic_timing` (3), `test_stream_names` (23), `test_stream_wrappers` (15), `test_stream_capture_pcm` (19), `test_stream_playback_only` (11), `test_stream_multiplex_graph` (13), `test_stream_recording_path` (5), `test_stream_log_variables` (5), `test_ffmpeg_log_dir` (9), `test_port_variables` (5), `test_process_identity_display` (7), `test_pipefail_aborts` (12) | 230 |
| Stream manager: systemd unit and cron | the rendered unit and cron file, the settings install carries, the shipped sample files | `test_stream_manager_unit` (25), `test_install_settings` (10), `test_config_files` (7) | 42 |
| MediaMTX configuration and API | the one configuration renderer, who owns mediamtx.yml, ports, readiness and health probes; the *_live files run real MediaMTX binaries | `test_mediamtx_config_render` (25), `test_mediamtx_config_ownership` (41), `test_mediamtx_config_versions` (4), `test_mediamtx_config_live` (12), `test_mediamtx_ports` (20), `test_mediamtx_api_probe` (26), `test_mediamtx_api_live` (2), `test_mediamtx_json_compat` (13), `test_mediamtx_live` (6), `test_mediamtx_e2e_ports` (1) | 150 |
| Installer | install_mediamtx.sh: download and checksum, configuration, unit, update and rollback, exit codes | `test_install_mediamtx` (136), `test_install_mediamtx_live` (5), `test_installer_exit_codes` (7) | 148 |
| Updater | lyrebird-updater.sh against real git repositories: lock, failures, history, rollback, menu, migrations | `test_lyrebird_updater` (60), `test_lyrebird_updater_failures` (55), `test_lyrebird_updater_history` (12), `test_lyrebird_updater_rollback` (19), `test_lyrebird_updater_lock` (22), `test_lyrebird_updater_menu` (11), `test_lyrebird_updater_migrations` (8) | 187 |
| Orchestrator | lyrebird-orchestrator.sh: menus, exit status of delegated scripts, the wizard, what it tells the user after a start | `test_lyrebird_orchestrator` (49), `test_orchestrator_delegation` (9), `test_orchestrator_outcome` (27), `test_orchestrator_wizard` (9), `test_orchestrator_updater_menu` (19), `test_orchestrator_manager_contract` (6) | 119 |
| Metrics | lyrebird-metrics.sh: collectors, exposition format, the HTTP server, process identity, the API time budget | `test_lyrebird_metrics` (98), `test_metrics_process_identity` (14), `test_metrics_api_budget` (7) | 119 |
| Storage | lyrebird-storage.sh: cleanup, retention, eviction, failed deletions, the command line and its configuration file | `test_lyrebird_storage` (59), `test_storage_suite_safety` (2), `test_storage_buffer` (5), `test_storage_clock_sanity` (4), `test_storage_codecs` (7), `test_storage_delete_failures` (14), `test_storage_eviction` (9), `test_storage_inodes` (4), `test_storage_path_safety` (12), `test_storage_segments` (18), `test_storage_scan` (13), `test_storage_cli` (9), `test_storage_config` (9) | 165 |
| Alerts, diagnostics, microphone check, USB mapper | lyrebird-alerts.sh, lyrebird-diagnostics.sh, lyrebird-mic-check.sh, usb-audio-mapper.sh | `test_lyrebird_alerts` (87), `test_lyrebird_diagnostics` (38), `test_lyrebird_mic_check` (45), `test_mic_check_cli` (5), `test_usb_audio_mapper` (56) | 231 |
| End to end | several components together, without hardware | `test_e2e_integration` (6), `test_e2e_stream_wrapper` (3), `test_integration` (10) | 19 |
| Soak harness | tools/soak: the harness against a fake node, then real MediaMTX and the outside observer | `test_soak` (31), `test_soak_live` (1), `test_soak_observer` (9) | 41 |
| The suite itself, CI and documentation | guards on how tests are written, the CI workflows, the register, and what the documents claim | `test_suite_hygiene` (18), `test_suite_can_fail` (1), `test_ci_config` (46), `test_remediation_status` (3), `test_docs_claims` (5), `test_docs_readme` (22), `test_docs_html` (34), `test_docs_security` (24), `test_docs_release` (34), `test_docs_node_facts` (15), `test_docs_tests_readme` (2) | 204 |

## What the suite cannot show

It runs on Linux with Bash 5.2, with FFmpeg 6.1.1 where a test needs one and six real MediaMTX versions for the
live files. It does not run on real USB hardware (real capture PCM layouts, second opens of a busy device, clock
drift between microphones), under a real systemd manager (boot ordering, `Conflicts=` at boot, start-limit timing,
`ProtectSystem=strict` with a real mount namespace; `systemd-analyze verify` is run on the units), on ARM, on
Bash older than 5.2, on another distribution, or through a power cut (durability of `fsync` ordering is tested by
call order, not by cutting power). A GitHub Actions run of the workflows is not something the suite can do either:
`test_ci_config.bats` checks the workflow files statically. The same list, with the reasons, is in
`docs/REMEDIATION-2026-11.md` section 4.

## Prerequisites

`bats`, `jq` and `python3` (the tests of the workflows read them with `python3-yaml`), `curl`, `ffmpeg` and
`ffprobe` for the tests that use a real FFmpeg, `shellcheck`, `shfmt` and `bashate` for the static gates
(CONTRIBUTING lists the versions CI pins). Install Bats from your distribution (`sudo apt-get install bats`) or from
source (`git clone https://github.com/bats-core/bats-core.git`, then `sudo ./install.sh /usr/local`).

## Running the tests

```bash
bats tests/                           # everything (about 30 minutes)
tests/check_tmp_leaks.sh              # what CI runs: also fails if the run leaves temp files behind
LYREBIRD_LEAK_CHECK_HOST=1 tests/check_tmp_leaks.sh   # also fails if it changes the host paths it lists (CI sets this)
bats tests/test_lyrebird_common.bats  # one file
bats tests/ --filter "validation"     # tests whose name matches
```

`check_tmp_leaks.sh` with `LYREBIRD_LEAK_CHECK_HOST=1` refuses to run (exit 2) on a machine that looks like a node
(an active `mediamtx-audio.service` or `mediamtx.service`, an installed `/etc/cron.d/mediamtx*`), because it
would report the node's own writes as the suite's.

**Live tests against real MediaMTX** (checksum-pinned 1.15.0, 1.18.0, 1.19.0, 1.21.1, 1.21.2 and 1.21.3 for
linux amd64, fetched into `.cache/mediamtx`; they need ffmpeg, curl, jq, openssl and python3). Without
`LYREBIRD_TEST_MEDIAMTX_BINS` the live tests are skipped. The `test_mediamtx_*` live files, `test_install_mediamtx_live`,
`test_stream_names` and `test_docs_security` bind no default port: each test takes free ports and moves MediaMTX's other
listeners to spare ports (`tests/mediamtx_live_helper.bash`; `LYREBIRD_TEST_PORT_BASE=N` pins the block `N`..`N+12`).
`test_soak_live` and `test_soak_observer` need the default ports 8554 and 9997 and an otherwise idle machine: they
refuse to run while another MediaMTX or RTSP ffmpeg is running, and they kill MediaMTX and FFmpeg by name.

```bash
LYREBIRD_TEST_MEDIAMTX_BINS="$(tests/fetch_mediamtx.sh)" \
    bats tests/test_mediamtx_live.bats tests/test_mediamtx_config_live.bats tests/test_mediamtx_api_live.bats \
         tests/test_mediamtx_e2e_ports.bats tests/test_install_mediamtx_live.bats tests/test_stream_names.bats \
         tests/test_docs_security.bats
```

One version only: `tests/fetch_mediamtx.sh .cache/mediamtx v1.21.3` (CI runs each pinned version as its own job).
The newest upstream release, as the advisory CI canary does it (resolved with `git ls-remote`, verified against the
checksums published with that release): `tests/fetch_mediamtx.sh .cache/mediamtx latest`. Only the pinned versions
are blocking.

## Writing tests

The rules (real code under test, a proof by mutation for every fix, the fixtures every test needs so that nothing
reaches the host: `scratch_setup`, `STREAM_MANAGER_LOG_FILE` next to `MEDIAMTX_LOG_FILE`, fake ALSA trees, the
process decoys, the pty helper) are in [CONTRIBUTING.md](../CONTRIBUTING.md#testing). Start a new file like this:

```bash
#!/usr/bin/env bats

load scratch_tmpdir

setup() {
    scratch_setup                       # a private TMPDIR and the log and state variables pointed at it
    PROJECT_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
}

teardown() {
    scratch_teardown
}

@test "what is being tested, in one sentence [register id]" {
    run bash "$PROJECT_ROOT/some-script.sh" --some-option
    [ "$status" -eq 0 ]
    [[ "$output" == *"expected text"* ]]
}
```

A test that cannot fail is not a test: every file must be able to fail (`test_suite_can_fail.bats` checks it), and a
bare `! grep ...` in the middle of a test never fails it (use `grep ... && false` or a helper that returns).

## CI

`.github/workflows/bash-ci.yml` runs the static gates, the suite through `tests/check_tmp_leaks.sh` with the host check
on, and the live files once per pinned MediaMTX version; `release.yml` publishes from a tag. CONTRIBUTING describes
what each job does and what none of them can prove.
