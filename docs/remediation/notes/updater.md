# lyrebird-updater.sh notes (for the documentation pass)

Area: X-21 (updater part) and the failure-injection hardening that went with
it. Updater version **1.7.0**. Everything below is what the code does now;
nothing here has been edited into README.md, CHANGELOG.md, docs/*.html or
SECURITY*.md. IDs `U-01`... are this worker's own finding numbers (used in the
commit messages); X-21 is the register entry.

## Decision: `--rollback [VERSION]` and `--history`

**Implemented; safe to document.** In the order it mattered:

1. The updater already had the machinery a rollback needs (stash transaction,
   service stop/backup/restart, migrations, `--ff-only`, the lock released before
   exec), and a rollback to a tag already in the clone touches no network:
   `switch_version_safe` never fetches (its callers do) and the start-up no
   longer asks origin for the default branch for the commands that do not need
   it (U-09).
2. That machinery was **not** safe as found. The transaction rollback was a
   no-op for every tag-pinned (detached HEAD) install, destroyed uncommitted
   edits when the stash step was declined or failed, left conflict markers in
   tracked files after a failed stash pop, and an update killed halfway left no
   trace (U-01, U-02, U-08, U-06). Those are fixed and covered before the new
   commands were built on them; `--rollback` is the same transaction as an
   update, run to a version that is already in the clone.
3. `--history` reads a local append-only log: no network, no lock, no git.

Not verifiable here (needs the real thing): power-cut durability of the
journal/history (they use fsync of file and directory; whether the medium
honours it is up to the storage stack); a real systemd manager (the service
stop/reinstall/start/rollback path ran against a stateful `systemctl`
stand-in and a unit file in a re-rooted sysroot, so the systemd-specific
branches are read, not run on systemd); a journal that cannot be written at the
exact moment a transaction begins (`transaction_begin` refuses to start; no
test, it needs the disk to fill at that instant).

## README changes (exact)

* **"Rollback After Failed Update" (~L2301-2312)**: the commands are now real.
  `./lyrebird-updater.sh --history` lists past updates/rollbacks/resets and any
  update that did not finish (it does **not** list available versions: that is
  `--list`, which needs the network). `./lyrebird-updater.sh --rollback` returns
  to the version the last completed update came from; `--rollback v1.3.0` to
  that release tag or to a commit. Both work without network when the version
  is already in the clone. A branch name is refused.
* **Version table (~L1466)**: `lyrebird-updater.sh | 1.7.0`.
* **"Rollback" (~L1257-1269)**: add `--rollback`; replace "transaction logs:
  `git reflog`, `git stash list`" by the real state files (below).
* **"Update Behavior" (~L1214-1226)**: "Preserves executable permissions on all
  scripts" is now true (it was not: five names only, and a rollback left
  rewritten scripts non-executable). "Automatic rollback on failure" is now true
  for tag installs (it was a no-op for them). "Restores stashed changes ... with
  conflict detection": conflicts leave the working tree clean, the changes in
  the stash, exit status 10.
* **Version Manager (~L1513-1550)**: usage block gains `--history`,
  `--rollback [VERSION]`; exit codes (full list below). README lists
  "4: No remote configured"; the code returns 4 when `git fetch` fails (origin
  unreachable), so say "4: Could not reach the remote (fetch failed) or no
  remote configured".
* **Troubleshooting (~L955-965, "git stash")**: after an interrupted update the
  operator's edits may sit in a stash entry named `lyrebird-tx-...` (or
  `lyrebird-recovery-...`); the next run of the updater restores/reports it.
* **Emergency Field Recovery (No Internet) (~L2316-2324), the `.conf.bak`
  claim**: the updater does **not** create `/etc/mediamtx/audio-devices.conf.bak`
  and never touches `/etc/mediamtx`; no script creates that file. Do not attribute
  config backups to the updater. Config backups belong to the stream-manager
  worker (D10: a timestamped backup when generated MediaMTX config content
  changes); take the real file names from that worker's notes. What the updater
  gives an offline node: `--history` and `--rollback VERSION` (no network
  needed). Suggested step 2-3: "Configuration backups are made by the stream
  manager (see its section); the updater does not back up configuration."
* "Install from the latest tag" guidance: not part of this area.

## New commands

| Command | Behaviour |
|---|---|
| `lyrebird-updater.sh --history` | Prints `Update History` from `<git-dir>/lyrebird-updater/history.log` (newest 50, oldest first; WHEN (UTC), KIND, RESULT, FROM, TO, NOTE), then `Not finished: ...` if an update left a journal. No network, no lock, no git. Exit 0. |
| `lyrebird-updater.sh --rollback` | Back to the version the last completed update/rollback/reset came from (read from the history). Exit 6 when there is none or it is no longer in the clone. |
| `lyrebird-updater.sh --rollback VERSION` | VERSION: a release tag, or a commit (full or abbreviated) already in the clone. A branch name is refused (exit 1): a rollback is to an exact commit. Exit 6 when it is not in the clone, with the hint to fetch while online. |

`--rollback` is the update's own transaction: validates git state (merge/rebase
in progress -> 8), offers to stash local changes (declined or no answer -> 9,
nothing touched), stops/backs up the service, switches (with the integrity
check), hands over to the target's updater when it changed (and finishes in the
current process when the target's updater predates the hand-over, e.g. a
pre-1.5 release), runs migrations, restores the stash (conflict -> 10), starts
the service, journals, and records `rollback ok|rolled-back|interrupted`. Back
to the same version -> "Already on ..., nothing to do", exit 0, no history line.
After a self-update hand-over a rollback exits instead of opening the menu
(internal trailing option `--no-menu` on `--post-update-*`; not for users).
Rolling back to a release older than 1.7.0 replaces the updater by that
release's own updater: `--history`/`--rollback` do not exist there.

## Recovery (interrupted update)

For "the updater was killed / the node lost power during an update": the next
run with no arguments (or `--rollback`) finds the journal and **undoes** the
update: back to the recorded commit, stash restored, service restored from its
backup and started if it had been running. Anything uncommitted in the working
tree at that point is first saved in a stash entry named
`lyrebird-recovery-<time>` (edits made after the crash cannot be told from what
the interrupted checkout left). A self-update interrupted after the hand-over
(journal phase `handoff`) is **completed** instead. `--status`, `--list`,
`--history` only report it. An unreadable journal stops a changing run with
exit 8 and says what to check.

## State directory (new)

`<git-dir>/lyrebird-updater/` (a linked worktree's own git dir; override with
`LYREBIRD_UPDATER_STATE_DIR`):

| File | Content |
|---|---|
| `lock/` | the lock (directory with `pid`) -- **moved out of the working tree**. A lock directory left at `<repo>/.lyrebird-updater.lock` by an older updater is removed when its owner is dead and honoured (exit 7) while that updater runs |
| `history.log` | one tab-separated line per finished update, rollback, reset or recovery: UTC time, kind (`update`/`rollback`/`reset`), result (`ok`/`failed`/`rolled-back`/`interrupted`), from-commit, from-label, to-commit, to-label, note. Empty fields are `-`. Append-only, fsync'd; a torn last line is skipped on read and never glued to the next record. Cancelled switches are not recorded |
| `transaction` | the journal: exists only while an update is in flight (or was killed): kind, versions, stash message/hash, `head_changed`, `service_was_running`, phase (`begin`, `stashing`, `stashed`, `service-prepared`, `checkout`, `checked-out`, `handoff`, `rollback-failed`) |
| `core.fileMode.saved` | the value `core.fileMode` had before the updater set it to `false` for its run |

## Environment variables (new, all optional)

| Variable | Default | Effect |
|---|---|---|
| `LYREBIRD_UPDATER_STATE_DIR` | `<git-dir>/lyrebird-updater` | where lock, history, journal live |
| `LYREBIRD_UPDATER_SYSROOT` | empty | prefix for `/etc/systemd/system/mediamtx-audio.service`, `/etc/cron.d/mediamtx-monitor`, `/run/lyrebird-service-update.marker`, `/var/lib/lyrebird/migrations`, `/usr/local/bin`, `/var/log` (test suite) |
| `LYREBIRD_FETCH_TIMEOUT` | 30 | seconds per `git fetch` attempt |
| `LYREBIRD_FETCH_RETRIES` | 3 | fetch attempts |
| `LYREBIRD_FETCH_RETRY_DELAY` | 2 | seconds between attempts |
| `LYREBIRD_REMOTE_PROBE_TIMEOUT` | 10 | seconds for the "default branch" query of origin at start-up |
| `LYREBIRD_UPDATER_LOCK_WAIT` | 30 | seconds to wait for another updater |

A value that is not a whole number >= 1 falls back to the default. Removed
settings: none. The constants `FETCH_TIMEOUT`, `FETCH_RETRIES`,
`FETCH_RETRY_DELAY` and `LOCK_MAX_WAIT` are still the script's names for the
values.

## Exit codes (complete list)

0 success; 1 general error; 2 prerequisites not met; 3 not a git repository;
4 could not reach the remote (fetch failed; `--list` shows cached data and
exits 4) or no remote; 5 permission (repository not writable or owned by root;
the lock cannot be written -- these reached the caller only now, `main()` used
to turn them into 3 and 7); **6 requested or previous version not available
locally (new)**; 7 locked; 8 bad git state (also: unreadable journal);
9 user aborted (declined a prompt, SIGINT, SIGTERM, declined the root prompt --
that was 2); **10 switch done but the saved changes conflict with the new
version and were NOT re-applied; they are in the stash (new)**; **11 the
automatic rollback could not restore everything; the message names
`git checkout --force <sha>` (new)**.

Note: the interactive menu ends the whole run with the failing status when an
action fails (existing behaviour, see "Not fixed").

## Other user-visible behaviour changes

* The lock is no longer an untracked directory in the repository, so
  `git status` on a pristine clone is clean while the updater runs and a stash
  no longer sweeps the lock away.
* "You have local modifications" is no longer reported on a pristine clone
  (the updater used the stat-sensitive `git diff-index`).
* A switch verifies the files it wrote against the target's blobs; git can
  exit 0 after a write error on one file.
* Files an update rewrites keep the operator's umask modes (they were 0600/0700
  under the updater's own umask 077); every tracked `*.sh` is made executable.
* `core.fileMode=false` (set while the updater runs) is restored on exit,
  before a self-update re-exec and, after a kill, by the next run.
* Network access is bounded (default-branch probe 10 s, fetch 30 s x3);
  `--version`, `--help`, `--status`, `--migrate`, `--rollback`, `--history` never
  touch the network.

## Defects found (this area)

| ID | Sev | Status | What |
|---|---|---|---|
| U-01 | P1 | fixed (R) | Rollback was a no-op for detached-HEAD (tag) installs and left a fast-forwarded branch advanced: it ran `git checkout HEAD --force` |
| U-02 | P1 | fixed (R) | Declining "Save your changes temporarily?" (or a failing stash) destroyed uncommitted tracked edits via the same forced checkout |
| U-03 | P2 | fixed (R) | The lock was an untracked directory in the repo: every run "had local modifications", `git stash -u` swept the lock away for the whole checkout, and a self-update could never restore its stash (collision on the lock) |
| U-04 | P2 | fixed (R) | `git diff-index` (stale stat data) reported local modifications after the updater's own chmod |
| U-05 | P2 | fixed (R) | `stash@{0}` taken blindly: with nothing to stash the updater adopted and later popped the operator's own stash |
| U-06 | P1 | fixed (R) | SIGKILL/power cut mid-update left no trace: orphaned stash, half-switched tree, orphaned service marker |
| U-07 | P2 | fixed (R) | `core.fileMode=false` left behind after every self-update and after a kill; the restore also deleted an operator's own setting after an early exit |
| U-08 | P2 | fixed (R) | Conflicting stash pop: conflict markers in tracked files, exit 0, unusable instructions |
| U-09 | P1 | fixed (R) | Every command (even `--version`) hung with a black-holed origin: unbounded `git ls-remote` before argument handling |
| U-10 | P2 | fixed (R) | Executable bit lost for scripts not on the five-name list, and after every rollback |
| U-11 | P2 | fixed (R) | git exits 0 after a write error on a file (truncated file, HEAD moved); the updater only compared HEAD |
| U-12 | P3 | fixed (R) | umask 077 leaked into checked-out files (0600/0700 next to 0644) |
| U-13 | P3 | fixed (R) | `main()` collapsed start-up failure codes (5, 9 never reached the caller) |
| U-14 | P2 | fixed (R) | `acquire_lock` spun for ever when the pid file could not be written (full disk) |
| U-15 | P3 | fixed (R) | `clear` failing (TERM=dumb) ended the menu silently with status 1 |
| U-16 | P3 | fixed (R) | unset `$USER` crashed the "sudo chown" hints under `set -u` |
| U-17 | P2 | fixed (R) | Self-update re-exec'd into an updater that does not know `--post-update-*` (any pre-1.5 release, e.g. `--rollback v1.3.0`) would strand the stash and the stopped service |
| U-21 | P2 | fixed (R) | SIGTERM/SIGINT between `git stash push` and recording its hash left the operator's changes in an unreferenced stash entry with the journal cleared and nothing reported (the in-process rollback restored only a recorded stash) |
| U-18 | P3 | **not fixed** (S/R) | The interactive menu ends the whole updater with the failing status when an action fails (`select_version_interactive` etc. as plain statements under errexit), and exits 1 silently when stdin reaches EOF at a prompt (`read` under errexit). Exit codes of switches are observable because of it, and tests rely on that; changing it would change the exit-code contract |
| U-19 | P3 | **not fixed** (S) | The self-update path (`--post-update-*`) never runs `run_post_update_migrations`; migrations run only on a switch that does not re-exec, or with `--migrate` |
| U-20 | P3 | **not fixed** (S) | The lock's stale-removal is `kill -0` then `rm -rf` then `mkdir`: two updaters started in the same instant after a crash can both remove and re-create it (D2 would have it as an unlinking-free flock). Needs two updaters launched at the same moment; not reproduced |

Reproduced (R) means the real script was run against a real local git
repository with the failure injected (git wrapper, black-holed TCP server,
tmpfs, RLIMIT_FSIZE) and the wrong behaviour observed; S means read from the
source only.

## Test infrastructure added (not user-visible)

`tests/updater_helper.bash`; `tests/helpers/updater/bin/{git,stat,systemctl}`
(fault-injecting git wrapper, root-owner stand-in, stateful systemctl);
`tests/helpers/updater/hang_server.py` (accepts TCP connections, never answers);
`UPDATER_SCRIPT_SOURCE` makes the same tests run against another copy of the
script (used for the mutation checks). The updater tests use a private mount
namespace (`unshare -m`, or `unshare -Urm`) for the real-ENOSPC tests and skip
with a message where that is not permitted.
