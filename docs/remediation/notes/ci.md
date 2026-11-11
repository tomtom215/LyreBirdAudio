# CI and release automation notes (LB-19, LB-20, X-22, X-16)

For the documentation pass. Everything below is what the code now does (each
item is backed by a test in `tests/test_ci_config.bats` unless marked) and what
the docs must say. Nothing here was run on GitHub: see "What only a real run can
prove".

## What the pipeline does now

`.github/workflows/bash-ci.yml` ("Bash CI"):

- **Triggers:** `pull_request` to main/master, `push` to main/master, a weekly
  `schedule` (Monday 04:23 UTC, default branch), `workflow_dispatch` and
  `workflow_call`. **No `paths` filter anywhere.** Superseded runs are cancelled
  for pull requests only; a run on main or a tag always finishes. Token is
  `contents: read`; steps run with `bash -eo pipefail`.
- **Jobs, all required:** `discover-scripts`, `workflow-lint` (actionlint
  1.7.12, which also runs ShellCheck over every `run:` script), `bash-syntax`,
  `shellcheck` (0.11.0), `shfmt` (3.13.1, **blocking now**), `bashate` (2.1.1,
  **blocking now**), `security-scan`, `bats-tests`, and `live-mediamtx`, a
  matrix of v1.15.0, v1.18.0, v1.19.0, v1.21.1, v1.21.2, v1.21.3, one parallel
  job per version named after it (`Live MediaMTX v1.21.3`), `fail-fast: false`.
- **`CI Summary`** needs all of the above (not the canary) and fails unless
  every one finished as `success`: failed, cancelled and skipped all fail it, as
  does an empty result. It is the single check to require in branch protection.
- **`security-scan` is a heuristic pattern scan and still only warns.** "Required"
  means it must run and finish; its findings do not fail the pipeline. The step
  summary now reports what it found (it used to print a fixed table of "OK").
- **Advisory canary** `live-mediamtx-canary` ("advisory, non-blocking",
  `continue-on-error`, not in the summary, skipped for tag pushes): resolves the
  newest stable upstream tag at run time with `git ls-remote`, verifies the
  tarball against the `checksums.sha256` of that release, runs the same three
  live bats files, and writes the tested version to the step summary.
- **Downloaded tools are verified:** ShellCheck, shfmt and actionlint are fetched
  to `RUNNER_TEMP`, checked with `sha256sum -c` against a pin in the workflow
  `env`, then installed; a mismatch stops before install. bashate is installed
  from `.github/ci/requirements.txt` with `pip install --require-hashes`
  (bashate 2.1.1, pbr 7.1.3, setuptools 84.2.1, wheel and sdist hashes) in a venv.
  The runner image's own shellcheck is no longer used.
- **Every `uses:` is a full commit SHA with a `# vX.Y.Z` comment**;
  `.github/dependabot.yml` proposes weekly updates for `github-actions` (`/`)
  and `pip` (`/.github/ci`).
- No expression is interpolated into any `run:` script (all pass through `env:`).

`.github/workflows/release.yml` ("Release", on `vX.Y.Z` and `vX.Y.Z-*` tags):

- `validate` **calls `bash-ci.yml`** (`workflow_call`): the tagged commit passes
  every check a pull request passes, including the live matrix. The canary does
  not run for tags.
- `release` builds `LyreBirdAudio-<version>.tar.gz` with `git archive` of exactly
  the tagged commit (top directory `LyreBirdAudio-<version>/`, tracked files only,
  `gzip -n -9`) and `SHA256SUMS` (`<hash>  LyreBirdAudio-<version>.tar.gz`,
  verifiable with `sha256sum -c SHA256SUMS` next to the tarball). Rebuilding from
  the same commit gives the same bytes (checked on this repository: three builds,
  including from a fresh clone, identical).
- **Publishing is idempotent:** release exists -> `gh release edit` (title,
  pre-release flag, and the notes when `CHANGELOG.md` has a `## [<version>]`
  section; otherwise the existing notes are kept); missing -> `gh release create
  --verify-tag`; the create fails because the release appeared meanwhile -> the
  release is found and edited; the create fails and there is no release -> the
  step fails. Assets are uploaded with `--clobber`, so a re-run replaces them.
  Hyphenated tags (`v1.3.0-rc1`) are pre-releases, on create and on edit.
- Releases are **not signed or attested** (see "Needs maintainer decision").

`tests/fetch_mediamtx.sh`:

- Pins (sha256 of each release's `mediamtx_<v>_linux_amd64.tar.gz`, taken from
  its `checksums.sha256` and confirmed by hashing the downloaded tarball):
  v1.15.0, v1.18.0, v1.19.0, v1.21.1, **v1.21.2 (121be6e0...), v1.21.3 (0a2ea7eb...)**.
  The workflow matrix and the pin table must list the same versions (test).
- New version argument `latest`: newest stable `vX.Y.Z` tag (pre-release tags
  ignored) via `git ls-remote`, tarball verified against that release's checksum
  file (exactly one well-formed linux_amd64 line required); if the version is
  also pinned the pin wins and the checksum file must agree. It is never part of
  the default set. Exit statuses: 0 ok, 1 verification/resolution failure, 2 no
  pin / unsupported platform.
- Test-only environment variables: `LYREBIRD_MEDIAMTX_RELEASES_URL`,
  `LYREBIRD_MEDIAMTX_GIT_URL` (point it at a local tree).

## Documentation changes needed

- `tests/README.md`
  - "CI Integration": it says "On every push to main branch / On every pull
    request / Daily scheduled runs". Now: every pull request to main/master,
    every push to main/master, a **weekly** schedule, manual dispatch; no path
    filter; the required check is `CI Summary`.
  - Coverage table and "Test Files" table: add `test_ci_config.bats` (45 tests:
    workflow triggers, required jobs, pins, verified downloads, live matrix and
    canary, release assets and idempotent publish, `fetch_mediamtx.sh`).
    `bats --count tests/` is 723 on this branch before other workers' tests
    (the README's 664 was already stale).
  - The live-test section was updated by this change (six pinned versions, one
    version per run, `latest`).
- `README.md` "Validation" checklist (around line 2530): CI now blocks on
  `shfmt -d -i 4 -bn -ci` and `bashate --ignore E001,E006,E040,E042,E043` as well
  as `bash -n` and ShellCheck; add them. The live-test line can mention that CI
  runs each pinned MediaMTX version as its own job.
- `CONTRIBUTING.md`: "PRs must pass CI checks before merge" -> the `CI Summary`
  check (all jobs required); Development Setup lists only ShellCheck and bats:
  add shfmt and bashate (`bashate==2.1.1`) because their findings now block.
- Release guidance (README "install from tag", X-21): a release carries a source
  tarball and `SHA256SUMS`; say how to verify (`sha256sum -c SHA256SUMS`) and
  that this proves integrity against the published file only, not authorship
  (no signature).
- `lyrebird-stream-manager.sh` header (lines 14-16) says "compatible with MediaMTX
  v1.15.0 through at least v1.21.1" and lists four real binaries. The live suite
  (`test_mediamtx_live`, `test_soak_live`, `test_soak_observer`: 11/11) now also
  passes against **1.21.2 and 1.21.3** (run 2026-11-11 on this branch's code,
  inside a private network+pid namespace). That file belongs to another worker;
  update the sentence when their changes land.
- `docs/remediation-status.json` (lead-owned): the tests for LB-19/LB-20/X-22/
  X-16 are the `tests/test_ci_config.bats` names listed in the final report.

## How the pins were obtained, and how to bump them

- **Action SHAs** (2026-11-11): `git ls-remote --tags https://github.com/<owner>/<repo>.git`;
  take the commit of the moving major tag (an annotated tag's commit is on its
  `^{}` line; none of these four were annotated) and the `vX.Y.Z` tag at the same
  commit, which goes in the trailing comment. checkout v5 = v5.1.0 =
  fbc6f3992d24b796d5a048ff273f7fcc4a7b6c09; configure-pages v5 = v5.0.0 =
  983d7736d9b0ae728b81ab479565c72886d7745b; deploy-pages v4 = v4.0.5 =
  d6db90164ac5ed86f2b6aed7e0febac5b3c0c03e; upload-pages-artifact v3 = v3.0.1 =
  56afc609e74202658d3ffba0e8f6dda462b719fa. Majors are unchanged; newer majors
  exist (checkout v7, configure-pages v6, deploy-pages v5, upload-pages-artifact
  v5) and will arrive as Dependabot PRs.
- **ShellCheck v0.11.0** (`8c3be12b...`) and **shfmt v3.13.1** (`fb096c5d...`)
  publish no checksum file (the `.sha256` / `sha256sums.txt` URLs return 404), so
  the hashes were computed from the downloaded release assets; two independent
  downloads (this session and the earlier baseline) agree.
  **actionlint v1.7.12** (`8aca8db9...`) is the line for
  `actionlint_1.7.12_linux_amd64.tar.gz` in `actionlint_1.7.12_checksums.txt` of
  its release, and equals the computed hash.
  To bump: download the new asset, hash it (or take the release's checksum
  line), change `*_VERSION` and `*_SHA256` in the `env` of `bash-ci.yml` together.
  Dependabot does not see these.
- **bashate set** (`.github/ci/requirements.txt`): hashes from
  `https://pypi.org/pypi/<name>/<version>/json` (`urls[].digests.sha256`, wheel and
  sdist); checked by installing in a fresh venv with `--require-hashes`, and by
  confirming a copy with altered hashes is refused. Dependabot (pip) bumps it.
- **MediaMTX:** to add a version, download its `checksums.sha256` and tarball,
  confirm `sha256sum` equals the `linux_amd64` line, add the pin to
  `tests/fetch_mediamtx.sh` **and** the version to the matrix (the test requires
  both).

## Needs maintainer decision (not done: cannot be tested here)

- **Branch protection / ruleset:** require the `CI Summary` check (the job is built
  to fail on skipped/cancelled/failed needs) on main; require it up to date.
- **Release signing / attestation:** build-provenance attestation
  (`actions/attest-build-provenance`, needs `id-token: write` and
  `attestations: write`), a signing identity (Sigstore/cosign or GPG) and signed
  tags. The tarball and `SHA256SUMS` are produced by the same job and uploaded
  together, so they prove integrity, not authorship.
- **Release and tag controls:** a tag ruleset (who may push `v*`, only commits on
  main), GitHub's "immutable releases" setting; and whether the repository
  setting that requires Actions to be pinned to a full commit SHA should be
  turned on now that every `uses:` is.
- **Action major upgrades** proposed by Dependabot (see above).
- **Canary failures:** today a failing canary is visible on the run only. Decide
  whether a scheduled failure should open an issue or notify.
- **Tool pins without automation:** ShellCheck/shfmt/actionlint/MediaMTX pins are
  bumped by hand; decide whether to add a scheduled job or another updater.

## What only a real run can prove

Validated statically (actionlint 1.7.12 with ShellCheck 0.11.0 on every `run:`
script, zero findings on all three workflows; PyYAML parse; each step script
executed locally with stand-in `curl`/`sudo`/`gh`/linters; real downloads of every
pinned tool, the real pins checked, hash-verified pip install in a fresh venv):
not that GitHub accepts the workflow files, resolves the SHAs, schedules the
matrix, treats the canary's `continue-on-error` as non-failing, lets the
reusable-workflow call and `GITHUB_TOKEN` permissions work, or has `python3-venv`
/ `python3-yaml` / `jq` installable by `apt` on `ubuntu-latest`; nor `gh`'s real
behaviour (flags were checked against gh 2.89 `--help`). The live matrix legs run
timing-sensitive tests on shared runners for the first time as separate jobs; a
flaky leg fails the summary, so watch the first runs. Scheduled workflows are
disabled by GitHub after about 60 days without repository activity.

## Defects found on the way

- Security-scan step summary printed a fixed table of "OK" whatever the scan found
  (fixed).
- The ShellCheck job used whichever shellcheck the runner image had (fixed: pinned
  and verified).
- The old summary header labelled the live job "Required" while the gate ignored
  it (fixed).
- **Not fixed, outside the register:** the security scan's "hardcoded secrets"
  pattern `["\x27]` is passed to `grep -E`, where `\x27` is not an escape: the
  bracket matches the characters `\ x 2 7 "`, so `PASSWORD='abc123'` is never
  reported and values containing those characters are mishandled (reproduced with
  GNU grep 3.11). The scan only warns, so it is advisory either way.
- **Not fixed, trivial:** release.yml's CHANGELOG section lookup builds its regex
  from the version without escaping dots (`1.3.0` also matches `## [1x3y0]`).
