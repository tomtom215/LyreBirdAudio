#!/bin/bash
# lyrebird-updater.sh - Production-Ready Version Manager
# Part of LyreBirdAudio - RTSP Audio Streaming Suite
# https://github.com/tomtom215/LyreBirdAudio
#
# Author: Tom F (https://github.com/tomtom215)
# Copyright: Tom F and LyreBirdAudio contributors
# License: Apache 2.0
#
# Version: 1.8.0
#
# NEW in v1.8.0:
#   - The updater lock is a flock(2) lock on a file that is never removed or
#     truncated (decision D2); a dead holder releases it by dying, so there is
#     no stale-lock removal. The lock descriptor is closed in every git and
#     systemctl the updater starts and before a self-update re-exec
#   - A switch or reset that fails in the menu no longer ends the run: it is
#     reported and the menu stays open (Q leaves with that status). End of input
#     at a prompt leaves with exit status 12 and a message instead of a silent 1
#
# v1.7.0:
#   - --rollback [VERSION]: back to the previous version (or a tag/commit already
#     in the clone) with the update's own transaction, no network needed
#   - --history: past updates, failures and rollbacks (local append-only log)
#   - Crash-safe updates: a journal in the git directory; an update killed halfway
#     is undone (or, after a self-update hand-over, completed) by the next run
#   - The automatic rollback now returns to the original commit (it was a no-op
#     for tag installs) and never discards uncommitted work
#   - The lock moved out of the working tree; saved changes that conflict with the
#     new version stay in the stash instead of leaving conflict markers
#   - Bounded network access (no hang on a dead uplink); --list exits 4 offline
#
# v1.6.0:
#   - Automatic post-update migrations for breaking changes
#   - Handles script renames (mediamtx-stream-manager.sh -> lyrebird-stream-manager.sh)
#   - Updates systemd services, cron jobs, and /usr/local/bin installations
#   - Log file migration with backward-compatible symlinks
#   - Manual migration via: ./lyrebird-updater.sh --migrate
#
# v1.5.1 features:
#   - Pre-exec syntax validation for self-updates
#   - Protection against broken script deployment
#   - Enhanced error reporting for syntax failures
#
# v1.5.0 features:
#   - Automatic systemd service detection and update handling
#   - Pre-checkout service stop with state preservation
#   - Post-checkout service reinstallation and restart
#   - User customization detection and preservation
#   - Rollback support for failed service updates
#   - Self-update coordination with service updates
#   - Cron job update handling
#
# This script provides safe, reliable version management with:
#   - Atomic operations with automatic rollback on failure
#   - Comprehensive git state validation and recovery
#   - Lock file protection against concurrent execution
#   - Transaction-based stash management
#   - Progressive error recovery with user guidance
#   - Clear, non-technical UX for non-git-expert users
#   - Network resilience with retries
#   - Systemd service lifecycle management
#   - Self-update syntax validation
#
# Prerequisites:
#   - Git 2.0+ and Bash 4.0+
#   - Must be run from within a cloned LyreBirdAudio git repository

# Ensure bash is being used
if [ -z "$BASH_VERSION" ]; then
    echo "Error: This script requires bash. Please run with: bash $0 $*" >&2
    exit 1
fi

# Strict error handling and security
export LC_ALL=C # Ensure consistent sorting and string handling
# The updater's own files (lock, journal, history, backups) are owner-only, but
# the files git writes into the working tree must get the modes the operator's
# umask gives every other file in the repository. Under umask 077 an update used
# to leave the files it rewrote 0600/0700 and the rest 0644: ORIGINAL_UMASK is
# applied to those operations (git_worktree, set_script_permissions).
ORIGINAL_UMASK="$(umask)"
umask 077 # Secure file creation (owner-only by default)

set -o errexit  # Exit on any command failure
set -o pipefail # Catch errors in pipes
set -o nounset  # Exit if uninitialized variable is used
set -o errtrace # Inherit ERR trap in functions

# USER is only used in "to fix: sudo chown" hints, but unset (cron, systemd,
# some containers) it crashed the updater under nounset instead of printing them
: "${USER:=$(id -un 2>/dev/null || echo user)}"

# Source shared library if available (backward compatible)
# Provides: colors, logging, command_exists, compute_hash, exit codes
# Falls back gracefully if library not present - all functions defined locally below
_LYREBIRD_COMMON="${BASH_SOURCE[0]%/*}/lyrebird-common.sh"
# shellcheck source=lyrebird-common.sh
[[ -f "$_LYREBIRD_COMMON" ]] && source "$_LYREBIRD_COMMON" || true
unset _LYREBIRD_COMMON

################################################################################
# Constants and Configuration
################################################################################

# Script metadata
SCRIPT_NAME="$(basename "${BASH_SOURCE[0]}")"
readonly SCRIPT_NAME
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly SCRIPT_DIR
readonly VERSION="1.8.0"

# Updater state: the lock, the update history and the transaction journal live
# in a directory INSIDE the git directory, never in the working tree. A lock in
# the working tree is an untracked file: every run then reported "local
# modifications", `git stash -u` removed the lock for the whole checkout, and
# a stash created by one process could not be restored by the re-exec'd one
# (it collided with the new process's own lock). LYREBIRD_UPDATER_STATE_DIR
# overrides the location (used by the test suite).
_updater_git_dir() {
    local dot_git="${SCRIPT_DIR}/.git" line gitdir
    if [[ -d "$dot_git" ]]; then
        printf '%s' "$dot_git"
    elif [[ -f "$dot_git" ]] && IFS= read -r line <"$dot_git" && [[ "$line" == "gitdir: "* ]]; then
        # Linked worktree or submodule: ".git" is a file naming the real directory
        gitdir="${line#gitdir: }"
        [[ "$gitdir" == /* ]] || gitdir="${SCRIPT_DIR}/${gitdir}"
        printf '%s' "$gitdir"
    else
        return 1
    fi
}
if [[ -n "${LYREBIRD_UPDATER_STATE_DIR:-}" ]]; then
    UPDATER_STATE_DIR="$LYREBIRD_UPDATER_STATE_DIR"
elif _updater_state_git_dir="$(_updater_git_dir)"; then
    UPDATER_STATE_DIR="${_updater_state_git_dir}/lyrebird-updater"
else
    # Not a git repository: check_git_repository reports that; the directory
    # only has to exist for the lock until then.
    UPDATER_STATE_DIR="${SCRIPT_DIR}/.lyrebird-updater"
fi
unset _updater_state_git_dir
readonly UPDATER_STATE_DIR
# The lock: a flock(2) lock on this file, which is never removed or truncated.
# (Updaters up to 1.7.0 used a directory named "lock" next to it, see
# OLD_STATE_LOCKDIR; the new file has another name so that a 1.7.0 updater,
# e.g. after a rollback, can still create its own.)
readonly LOCKFILE="${UPDATER_STATE_DIR}/updater.lock"
readonly OLD_STATE_LOCKDIR="${UPDATER_STATE_DIR}/lock"
readonly HISTORY_FILE="${UPDATER_STATE_DIR}/history.log"
readonly JOURNAL_FILE="${UPDATER_STATE_DIR}/transaction"
readonly GIT_CONFIG_SAVED_FILE="${UPDATER_STATE_DIR}/core.fileMode.saved"
# Where updaters before 1.7.0 kept the lock (an untracked directory in the repo)
readonly LEGACY_LOCKFILE="${SCRIPT_DIR}/.lyrebird-updater.lock"

# Repository configuration
readonly REPO_OWNER="tomtom215"
readonly REPO_NAME="LyreBirdAudio"
readonly REPO_URL="https://github.com/${REPO_OWNER}/${REPO_NAME}.git"

# Exit codes
readonly E_SUCCESS=0
readonly E_GENERAL=1
readonly E_PREREQUISITES=2
readonly E_NOT_GIT_REPO=3
readonly E_NO_REMOTE=4
readonly E_PERMISSION=5
readonly E_NOT_FOUND=6 # requested/previous version is not available locally
readonly E_LOCKED=7
readonly E_BAD_STATE=8
readonly E_USER_ABORT=9
readonly E_RESTORE_CONFLICT=10 # switch done, but your saved changes could not be re-applied (kept in the stash)
readonly E_ROLLBACK_FAILED=11  # the automatic rollback could not restore everything; see the messages
readonly E_INPUT_EOF=12        # standard input ended (Ctrl-D, closed pipe) while a menu waited for an answer

# Version requirements
readonly MIN_GIT_MAJOR=2
readonly MIN_GIT_MINOR=0
readonly MIN_BASH_MAJOR=4
readonly MIN_BASH_MINOR=0

# Operation timeouts and retries. Slow or metered uplinks can raise these (and
# the test suite lowers them) through LYREBIRD_FETCH_TIMEOUT, LYREBIRD_FETCH_RETRIES,
# LYREBIRD_FETCH_RETRY_DELAY, LYREBIRD_REMOTE_PROBE_TIMEOUT and
# LYREBIRD_UPDATER_LOCK_WAIT (whole seconds / counts, at least 1; anything else
# falls back to the default).
_updater_positive_int() {
    local value="${1:-}" default="$2"
    if [[ "$value" =~ ^[0-9]+$ ]] && ((10#$value >= 1)); then
        printf '%s' "$((10#$value))"
    else
        printf '%s' "$default"
    fi
}
FETCH_TIMEOUT="$(_updater_positive_int "${LYREBIRD_FETCH_TIMEOUT:-}" 30)"
readonly FETCH_TIMEOUT
FETCH_RETRIES="$(_updater_positive_int "${LYREBIRD_FETCH_RETRIES:-}" 3)"
readonly FETCH_RETRIES
FETCH_RETRY_DELAY="$(_updater_positive_int "${LYREBIRD_FETCH_RETRY_DELAY:-}" 2)"
readonly FETCH_RETRY_DELAY
REMOTE_PROBE_TIMEOUT="$(_updater_positive_int "${LYREBIRD_REMOTE_PROBE_TIMEOUT:-}" 10)"
readonly REMOTE_PROBE_TIMEOUT
LOCK_MAX_WAIT="$(_updater_positive_int "${LYREBIRD_UPDATER_LOCK_WAIT:-}" 30)"
readonly LOCK_MAX_WAIT
readonly TAG_LIST_LIMIT=20

# Every absolute system path the updater touches (service unit, cron job,
# /run marker, migration state, /usr/local/bin, /var/log) can be re-rooted
# under LYREBIRD_UPDATER_SYSROOT. Unset (the normal case) it is empty and the
# paths are the real ones. The test suite points it at a temp directory so a
# full update can run without writing to the host.
UPDATER_SYSROOT="${LYREBIRD_UPDATER_SYSROOT:-}"
UPDATER_SYSROOT="${UPDATER_SYSROOT%/}"
readonly UPDATER_SYSROOT

# Service update configuration
readonly SERVICE_NAME="mediamtx-audio"
readonly SERVICE_FILE="${UPDATER_SYSROOT}/etc/systemd/system/${SERVICE_NAME}.service"
readonly SERVICE_CRON_FILE="${UPDATER_SYSROOT}/etc/cron.d/mediamtx-monitor"
readonly SERVICE_SCRIPT="lyrebird-stream-manager.sh"
readonly SERVICE_UPDATE_MARKER="${UPDATER_SYSROOT}/run/lyrebird-service-update.marker"
readonly SERVICE_STOP_TIMEOUT=30
readonly SERVICE_START_TIMEOUT=10

# Migration configuration
readonly MIGRATION_MARKER_DIR="${UPDATER_SYSROOT}/var/lib/lyrebird/migrations"
readonly OLD_STREAM_MANAGER="mediamtx-stream-manager.sh"
readonly OLD_STREAM_MANAGER_LOG="${UPDATER_SYSROOT}/var/log/mediamtx-stream-manager.log"
readonly NEW_STREAM_MANAGER_LOG="${UPDATER_SYSROOT}/var/log/lyrebird-stream-manager.log"
readonly STREAM_MANAGER_BIN_DIR="${UPDATER_SYSROOT}/usr/local/bin"

# Colors for output (using tput for portability)
if command -v tput >/dev/null 2>&1 && [[ -t 1 ]]; then
    RED=$(tput setaf 1)
    readonly RED
    GREEN=$(tput setaf 2)
    readonly GREEN
    YELLOW=$(tput setaf 3)
    readonly YELLOW
    BLUE=$(tput setaf 4)
    readonly BLUE
    CYAN=$(tput setaf 6)
    readonly CYAN
    BOLD=$(tput bold)
    readonly BOLD
    NC=$(tput sgr0)
    readonly NC
else
    readonly RED=""
    readonly GREEN=""
    readonly YELLOW=""
    readonly BLUE=""
    readonly CYAN=""
    readonly BOLD=""
    readonly NC=""
fi

################################################################################
# Global State Variables
################################################################################

# Debug mode
DEBUG="${DEBUG:-false}"
export DEBUG # Export so child processes inherit

# Repository state (populated and validated by functions)
DEFAULT_BRANCH=""
CURRENT_VERSION=""
CURRENT_BRANCH=""
IS_DETACHED=false
HAS_LOCAL_CHANGES=false
GIT_STATE="unknown" # clean, dirty, merge, rebase, revert, cherry-pick, bisect, sequencer

# Transaction state for rollback capability
declare -A TRANSACTION_STATE=(
    [active]=false
    [stash_hash]=""
    [original_ref]=""
    [original_head]=""
    [operation]=""
    [target]=""
    [target_head]=""
    [head_changed]=false
    [kind]=""
    [original_label]=""
    [stash_message]=""
    [service_was_running]=false
    [recovering]=false
    [note]=""
    [phase]=""
    [started]=""
    [pid]=""
)

# Exit status of a run that otherwise ended normally (E_RESTORE_CONFLICT when a
# self-update could not re-apply the operator's saved changes)
EXIT_STATUS="$E_SUCCESS"

# Available versions array
declare -a AVAILABLE_VERSIONS=()

# Git configuration backup for restoration
declare -A ORIGINAL_GIT_CONFIG=()

# Service update state
declare -A SERVICE_STATE=(
    [installed]=false
    [was_running]=false
    [was_enabled]=false
    [has_customizations]=false
    [service_file]=""
    [cron_file]=""
    [backup_service_file]=""
    [backup_cron_file]=""
)

# Custom environment variables from service file
declare -a SERVICE_CUSTOM_ENV=()

################################################################################
# Logging Functions
################################################################################

log_debug() {
    if [[ "$DEBUG" == "true" ]]; then
        echo "${CYAN}[DEBUG]${NC} $*" >&2
    fi
}

log_info() {
    echo "${BLUE}[INFO]${NC} $*"
}

log_success() {
    echo "${GREEN}[[OK]]${NC} $*"
}

log_warn() {
    echo "${YELLOW}[!]${NC} $*" >&2
}

log_error() {
    echo "${RED}[[X]]${NC} $*" >&2
}

log_step() {
    echo "${BOLD}>${NC} $*"
}

################################################################################
# Durable State: update history and transaction journal
################################################################################

# Both live in UPDATER_STATE_DIR (inside the git directory), are written with
# fsync, and are readable without network or git. The history log is
# append-only (one line per finished update, rollback or recovery); the
# journal exists only while a transaction is in flight, so a copy that is still
# there at the next start means the updater was killed (SIGKILL, OOM, power).

# Flush FILE or DIR to stable storage (coreutils >= 8.24 syncs just that path;
# older systems fall back to a global sync)
updater_fsync() {
    if declare -F lyrebird_fsync_path >/dev/null 2>&1; then
        lyrebird_fsync_path "$1"
    else
        sync -- "$1" 2>/dev/null || sync
    fi
}

# Replace DEST with stdin atomically and durably: temp file in DEST's
# directory, fsync, rename, fsync of the directory. lyrebird_atomic_write when
# the shared library is loaded, an equivalent local copy otherwise (the updater
# must keep working in a tree where the library is missing).
# Usage: updater_atomic_write DEST [MODE] < content
updater_atomic_write() {
    local dest="$1" mode="${2:-0600}"
    local dir base tmp
    if declare -F lyrebird_atomic_write >/dev/null 2>&1; then
        lyrebird_atomic_write "$dest" "$mode"
        return
    fi
    dir="$(dirname -- "$dest")"
    base="$(basename -- "$dest")"
    tmp="$(mktemp "${dir}/.${base}.XXXXXX")" || return 1
    if ! cat >"$tmp" \
        || ! chmod "$mode" -- "$tmp" \
        || ! updater_fsync "$tmp" \
        || ! mv -f -- "$tmp" "$dest"; then
        rm -f -- "$tmp"
        return 1
    fi
    updater_fsync "$dir"
}

# One line of text: tabs and newlines would break the TSV history and the
# key=value journal
_updater_oneline() {
    local value="$1"
    value="${value//$'\t'/ }"
    value="${value//$'\r'/ }"
    printf '%s' "${value//$'\n'/ }"
}

# A history field: one line, and "-" when empty so that fields never collapse
_updater_field() {
    local value
    value="$(_updater_oneline "$1")"
    printf '%s' "${value:--}"
}

# Human label of a commit: its tag, else FALLBACK (a branch name), else the short hash
commit_label() {
    local commit="$1" fallback="${2:-}" tag=""
    if [[ -z "$commit" ]]; then
        printf '%s' "(none)"
        return 0
    fi
    tag="$(git describe --tags --exact-match "$commit" 2>/dev/null)" || tag=""
    tag="${tag%%$'\n'*}"
    if [[ -n "$tag" ]]; then
        printf '%s' "$tag"
    elif [[ -n "$fallback" && "$fallback" != "HEAD" ]]; then
        printf '%s' "$fallback"
    else
        git rev-parse --short "$commit" 2>/dev/null || printf '%s' "${commit:0:7}"
    fi
}

# Append one record to the history log.
#   ts  kind  result  from_commit  from_label  to_commit  to_label  note
# kind: update | rollback | reset;  result: ok | failed | rolled-back | interrupted
# Usage: history_record KIND RESULT FROM_COMMIT FROM_LABEL TO_COMMIT TO_LABEL [NOTE]
history_record() {
    local kind="$1" result="$2" from_commit="$3" from_label="$4" to_commit="$5" to_label="$6" note="${7:-}"
    local ts line
    ts="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    line="${ts}"$'\t'"$(_updater_field "$kind")"$'\t'"$(_updater_field "$result")"
    line+=$'\t'"$(_updater_field "$from_commit")"$'\t'"$(_updater_field "$from_label")"
    line+=$'\t'"$(_updater_field "$to_commit")"$'\t'"$(_updater_field "$to_label")"
    line+=$'\t'"$(_updater_field "$note")"
    # A power cut can leave the last line unterminated; start a new line so the
    # next record is not glued to that fragment
    if [[ -s "$HISTORY_FILE" && -n "$(tail -c 1 "$HISTORY_FILE" 2>/dev/null)" ]]; then
        line=$'\n'"$line"
    fi
    if ! mkdir -p "$UPDATER_STATE_DIR" 2>/dev/null \
        || ! printf '%s\n' "$line" >>"$HISTORY_FILE" 2>/dev/null; then
        log_warn "Could not record this in the update history: $HISTORY_FILE"
        return 1
    fi
    updater_fsync "$HISTORY_FILE" || true
    updater_fsync "$UPDATER_STATE_DIR" || true
    return 0
}

# The most recent record of a completed version change (an update, rollback or
# reset that finished with result ok), as the raw TSV line; empty if none
history_last_change() {
    [[ -f "$HISTORY_FILE" ]] || return 0
    awk -F'\t' '$3 == "ok" && ($2 == "update" || $2 == "rollback" || $2 == "reset") {line = $0} END {if (line != "") print line}' \
        "$HISTORY_FILE" 2>/dev/null || true
}

# Journal of the transaction in flight (key=value, one per line)
declare -A JOURNAL=()

# Persist the in-memory transaction. Returns 1 when it could not be written.
# Usage: journal_write [PHASE]
journal_write() {
    local key
    if [[ -n "${1:-}" ]]; then
        TRANSACTION_STATE[phase]="$1"
    fi
    mkdir -p "$UPDATER_STATE_DIR" 2>/dev/null || return 1
    {
        echo "version=1"
        for key in kind operation target target_head original_ref original_head original_label \
            stash_hash stash_message head_changed service_was_running phase started pid; do
            printf '%s=%s\n' "$key" "$(_updater_oneline "${TRANSACTION_STATE[$key]:-}")"
        done
    } | updater_atomic_write "$JOURNAL_FILE" 0600
}

# Load the journal into JOURNAL. 0 = loaded, 1 = no journal, 2 = unreadable.
journal_load() {
    local key value
    JOURNAL=()
    [[ -e "$JOURNAL_FILE" ]] || return 1
    while IFS='=' read -r key value || [[ -n "$key" ]]; do
        if [[ "$key" =~ ^[a-z_]+$ ]]; then
            JOURNAL["$key"]="$value"
        fi
    done <"$JOURNAL_FILE" 2>/dev/null || return 2
    [[ "${JOURNAL[version]:-}" == "1" && -n "${JOURNAL[phase]:-}" && -n "${JOURNAL[kind]:-}" ]] || return 2
    return 0
}

journal_clear() {
    rm -f -- "$JOURNAL_FILE" 2>/dev/null || true
    updater_fsync "$UPDATER_STATE_DIR" || true
}

# Describe the loaded JOURNAL in one line
journal_summary() {
    printf '%s to %s (started %s, interrupted at phase "%s")' \
        "${JOURNAL[kind]:-update}" "${JOURNAL[target]:-?}" "${JOURNAL[started]:-?}" "${JOURNAL[phase]:-?}"
}

################################################################################
# Lock File Management
################################################################################

# The updater lock is a plain flock(2) lock on LOCKFILE (decision D2):
#
#   - The file is opened read-write WITHOUT truncation and is never removed. A
#     removed-and-recreated path is a different lock, and two updaters could
#     then both believe they hold "the" lock.
#   - The kernel drops the flock when its holder dies, however it dies (exit,
#     SIGKILL, OOM, power cut). A held lock is held and a released one is free:
#     there is no stale lock, so there is no lock-age test, no process-name test
#     and no removal step that two updaters started in the same instant could
#     race on.
#   - After winning the lock the owner overwrites the first line of the file in
#     place with "<pid> <starttime>" (starttime = field 22 of /proc/<pid>/stat).
#     The record is informational (it names the holder to an updater that has to
#     give up); it is never used to decide whether the lock is held.
#   - A flock belongs to an open file description, which every child inherits.
#     A child that kept the descriptor would hold the lock after this updater
#     exited (a detached `git gc --auto` does exactly that), so the descriptor is
#     closed in every git and systemctl the updater starts (the git and systemctl
#     functions below, run_unlocked) and before the self-update re-exec.

# The descriptor holding the lock; -1 while it is not held
UPDATER_LOCK_FD=-1

# Run a command with the lock descriptor closed: "$@" is executed as given, so
# a function or builtin runs in this shell with the descriptor closed only
# around the call. The descriptor number is validated as an integer first (bash
# 4.2 has no {var}>&- close form, hence the eval).
# Usage: run_unlocked COMMAND [ARGS...]
run_unlocked() {
    local fd="$UPDATER_LOCK_FD"
    if [[ "$fd" =~ ^[0-9]+$ ]] && ((fd > 2)); then
        eval '"$@" '"${fd}"'>&-'
    else
        "$@"
    fi
}

# Every git and systemctl the updater runs goes through these two functions, so
# a call added later cannot forget to close the descriptor. (Anything that
# looks for the programs themselves uses `type -P`: `command -v` also finds a
# function.)
git() {
    run_unlocked command git "$@"
}

systemctl() {
    run_unlocked command systemctl "$@"
}

# Print the start time (clock ticks since boot, field 22 of /proc/<pid>/stat)
# of a process. PID plus start time identify one process for the life of the
# machine; a recycled PID has a different start time.
# Returns 1 when the process does not exist or the value cannot be read.
updater_proc_starttime() {
    local pid="$1" stat="" rest
    local -a fields
    [[ "$pid" =~ ^[0-9]+$ ]] || return 1
    # Read the whole file: the command name (field 2) may contain spaces,
    # parentheses and even a newline, so the fields are counted from the last ")".
    { IFS= read -r -d '' stat <"/proc/${pid}/stat"; } 2>/dev/null || [[ -n "$stat" ]] || return 1
    [[ "$stat" == *") "* ]] || return 1
    rest="${stat##*) }"
    read -ra fields <<<"$rest"
    [[ "${fields[19]:-}" =~ ^[0-9]+$ ]] || return 1
    printf '%s\n' "${fields[19]}"
}

# Record this process as the owner of the lock held on descriptor $1: overwrite
# the first line in place (the descriptor is at offset 0 and the line has a
# fixed width, so the file never shrinks and is never empty while it is read).
# Returns 1 when the record cannot be written (disk full, read-only).
updater_lock_record_owner() {
    local fd="$1" start
    start="$(updater_proc_starttime "$$")" || start=0
    { printf '%-64s\n' "$$ ${start}" >&"${fd}"; } 2>/dev/null
}

# Print a one-line description of the owner recorded in the lock file. The
# recorded PID is only believed when its start time still matches, so a PID
# that has been recycled by an unrelated process is never blamed.
updater_lock_describe_holder() {
    local rec_pid="" rec_start="" now_start="" cmdline=""
    { IFS=' ' read -r rec_pid rec_start _ <"$LOCKFILE"; } 2>/dev/null || true
    if ! [[ "$rec_pid" =~ ^[0-9]+$ ]] || ! [[ "$rec_start" =~ ^[0-9]+$ ]]; then
        printf 'another process (no owner recorded)'
        return 0
    fi
    now_start="$(updater_proc_starttime "$rec_pid")" || now_start=""
    if [[ "$now_start" != "$rec_start" ]]; then
        printf 'another process (the last recorded owner, process %s, start time %s, is not running)' "$rec_pid" "$rec_start"
        return 0
    fi
    cmdline="$(tr '\0' ' ' 2>/dev/null <"/proc/${rec_pid}/cmdline")" || cmdline=""
    printf 'process %s (start time %s): %s' "$rec_pid" "$rec_start" "${cmdline:0:200}"
}

# Print "PID(comm)" for every other process that has the lock file open: the
# real holders, whatever the record says (a child that inherited the descriptor
# from an updater of an earlier version shows up here).
updater_lock_list_open_holders() {
    local entry pid comm out=""
    [[ -e "$LOCKFILE" ]] || return 0
    for entry in /proc/[0-9]*/fd/*; do
        [[ "$entry" -ef "$LOCKFILE" ]] || continue
        pid="${entry#/proc/}"
        pid="${pid%%/*}"
        [[ "$pid" == "$$" || "$pid" == "${BASHPID}" ]] && continue
        [[ " $out " == *" ${pid}("* ]] && continue
        comm="$(tr -d '\n' 2>/dev/null <"/proc/${pid}/comm")" || comm="?"
        out+="${out:+ }${pid}(${comm})"
    done
    printf '%s' "$out"
}

# True (0) while an updater older than 1.8.0 still holds its mkdir lock: the
# directory kept in the working tree by updaters before 1.7.0 (LEGACY_LOCKFILE)
# or the one in the state directory of 1.7.0 (OLD_STATE_LOCKDIR). Those updaters
# know nothing of flock, so their own protocol is honoured here (a pid file and
# a check that the process is an updater). A lock directory left by a dead one
# is removed: it would otherwise block a 1.7.0 updater started later (after a
# rollback) and, in the working tree, show up as a local modification for ever.
# Sets LEGACY_LOCK_HELD_DIR to the directory that is held.
LEGACY_LOCK_HELD_DIR=""
legacy_lock_held() {
    local dir legacy_pid legacy_cmdline
    LEGACY_LOCK_HELD_DIR=""
    for dir in "$LEGACY_LOCKFILE" "$OLD_STATE_LOCKDIR"; do
        [[ -d "$dir" ]] || continue
        legacy_pid="" legacy_cmdline=""
        if [[ -f "${dir}/pid" ]]; then
            legacy_pid="$(cat "${dir}/pid" 2>/dev/null || true)"
        fi
        if [[ "$legacy_pid" =~ ^[0-9]+$ && "$legacy_pid" != "$$" ]] && kill -0 "$legacy_pid" 2>/dev/null; then
            legacy_cmdline="$(tr '\0' ' ' <"/proc/${legacy_pid}/cmdline" 2>/dev/null || true)"
            if [[ "$legacy_cmdline" == *"lyrebird-updater"* ]]; then
                LEGACY_LOCK_HELD_DIR="$dir"
                return 0
            fi
        fi
        rm -rf "$dir" 2>/dev/null || true
    done
    return 1
}

# True (0) when this process already holds the lock
updater_lock_held_by_us() {
    [[ "$UPDATER_LOCK_FD" =~ ^[0-9]+$ ]] && ((UPDATER_LOCK_FD > 2)) \
        && [[ "/proc/self/fd/${UPDATER_LOCK_FD}" -ef "$LOCKFILE" ]]
}

# Take the lock, waiting at most LOCK_MAX_WAIT seconds for another updater.
# Returns 0 (held), E_LOCKED (another updater holds it) or E_PERMISSION (the
# lock file cannot be opened or written).
acquire_lock() {
    local waited=0 fd=-1

    # Already ours (a second call in the same process must not wait for itself)
    if updater_lock_held_by_us; then
        return 0
    fi

    # The lock lives in the updater state directory (inside the git directory)
    if ! mkdir -p "$UPDATER_STATE_DIR" 2>/dev/null || [[ ! -w "$UPDATER_STATE_DIR" ]]; then
        log_error "Cannot write to updater state directory: $UPDATER_STATE_DIR"
        log_info "The lock file, update history and transaction journal are kept there"
        log_info "Permission denied or directory is read-only"
        return "$E_PERMISSION"
    fi

    # Created if absent; never truncated, never removed
    if ! { exec {fd}<>"$LOCKFILE"; } 2>/dev/null; then
        log_error "Cannot open the lock file: $LOCKFILE"
        log_info "Permission denied or the file system is read-only"
        return "$E_PERMISSION"
    fi

    while true; do
        # An old updater (< 1.8.0) running at the same time holds its own lock
        if legacy_lock_held; then
            if [[ $waited -ge $LOCK_MAX_WAIT ]]; then
                log_error "Another (older) updater instance is running: $LEGACY_LOCK_HELD_DIR"
                eval "exec ${fd}>&-"
                return "$E_LOCKED"
            fi
            [[ $waited -eq 0 ]] && log_info "Waiting for other instance to finish..."
            sleep 1
            ((waited++)) || true
            continue
        fi

        if flock -n "$fd" 2>/dev/null; then
            break
        fi

        if [[ $waited -ge $LOCK_MAX_WAIT ]]; then
            log_error "Lock held by $(updater_lock_describe_holder)"
            local open_holders
            open_holders="$(updater_lock_list_open_holders)"
            if [[ -n "$open_holders" ]]; then
                log_error "Processes with the lock file open: $open_holders"
            fi
            log_info "Wait for it to finish or stop that process: the lock is released when it exits."
            log_info "Nothing needs to be deleted ($LOCKFILE is never removed)."
            eval "exec ${fd}>&-"
            return "$E_LOCKED"
        fi

        [[ $waited -eq 0 ]] && log_info "Waiting for other instance to finish..."
        # up to a second, and back the moment the holder is gone
        if flock -w 1 "$fd" 2>/dev/null; then
            break
        fi
        ((waited++)) || true
    done

    if ! updater_lock_record_owner "$fd"; then
        # The record is only informational, but a disk that cannot take 64 bytes
        # cannot take the journal or the history either: say so now instead of
        # failing half way through an update.
        log_error "Cannot write the lock file in $UPDATER_STATE_DIR (disk full or read-only?)"
        eval "exec ${fd}>&-"
        return "$E_PERMISSION"
    fi
    UPDATER_LOCK_FD="$fd"
    log_debug "Lock acquired (PID: $$)"
    return 0
}

# Give the lock up: close the descriptor. The file stays. Must run before the
# self-update re-exec (the new image would inherit the descriptor and then wait
# for a lock its own earlier open file description holds).
# shellcheck disable=SC2317  # Function invoked indirectly via cleanup
release_lock() {
    local fd="$UPDATER_LOCK_FD"
    UPDATER_LOCK_FD=-1
    if [[ "$fd" =~ ^[0-9]+$ ]] && ((fd > 2)); then
        eval "exec ${fd}>&-" 2>/dev/null || true
        log_debug "Lock released"
    fi
}

################################################################################
# Systemd Service Detection and State Management
################################################################################

# Detect if systemd service is installed and capture its state
detect_systemd_service() {
    log_debug "Detecting systemd service installation..."

    # Reset state
    SERVICE_STATE[installed]=false
    SERVICE_STATE[was_running]=false
    SERVICE_STATE[was_enabled]=false
    SERVICE_STATE[has_customizations]=false
    SERVICE_STATE[service_file]="$SERVICE_FILE"
    SERVICE_STATE[cron_file]="$SERVICE_CRON_FILE"
    SERVICE_STATE[backup_service_file]=""
    SERVICE_STATE[backup_cron_file]=""
    SERVICE_CUSTOM_ENV=()

    # Check if service file exists
    if [[ ! -f "$SERVICE_FILE" ]]; then
        log_debug "No systemd service file found at: $SERVICE_FILE"
        return 1
    fi

    SERVICE_STATE[installed]=true
    log_debug "Detected installed systemd service: $SERVICE_NAME"

    # Check if service is running
    if systemctl is-active --quiet "$SERVICE_NAME" 2>/dev/null; then
        SERVICE_STATE[was_running]=true
        log_debug "Service is currently running"
    fi

    # Check if service is enabled
    if systemctl is-enabled --quiet "$SERVICE_NAME" 2>/dev/null; then
        SERVICE_STATE[was_enabled]=true
        log_debug "Service is enabled for boot"
    fi

    # Detect customizations
    detect_service_customizations

    return 0
}

# Detect custom environment variables in service file
detect_service_customizations() {
    local service_file="$SERVICE_FILE"

    # Known default environment variables that the script generates
    local -A default_vars=(
        ["HOME"]="/root"
        ["PATH"]="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
        ["USB_STABILIZATION_DELAY"]="10"
        ["STREAM_MODE"]="individual"
        ["MULTIPLEX_FILTER_TYPE"]="amix"
        ["MULTIPLEX_STREAM_NAME"]="all_mics"
        ["INVOCATION_ID"]="systemd"
        ["LYREBIRD_UNDER_SYSTEMD"]="1"
    )

    # Extract Environment= lines from service file
    local env_lines
    env_lines=$(grep "^Environment=" "$service_file" 2>/dev/null || true)

    if [[ -z "$env_lines" ]]; then
        log_debug "No environment variables found in service file"
        return 0
    fi

    # Check each environment line for customizations
    while IFS= read -r line; do
        if [[ -z "$line" ]]; then
            continue
        fi

        # Extract variable name and value
        # Format: Environment="VAR=value" or Environment=VAR=value
        local var_full="${line#Environment=}"
        var_full="${var_full#\"}"
        var_full="${var_full%\"}"

        local var_name="${var_full%%=*}"
        local var_value="${var_full#*=}"

        # Check if this is a customized value
        if [[ -n "${default_vars[$var_name]+isset}" ]]; then
            # Known variable - check if value differs from default
            if [[ "${default_vars[$var_name]}" != "$var_value" ]]; then
                SERVICE_STATE[has_customizations]=true
                SERVICE_CUSTOM_ENV+=("$line")
                log_debug "Detected custom environment: $var_name=$var_value (default: ${default_vars[$var_name]})"
            fi
        else
            # Unknown variable - definitely custom
            SERVICE_STATE[has_customizations]=true
            SERVICE_CUSTOM_ENV+=("$line")
            log_debug "Detected custom environment variable: $var_name=$var_value"
        fi
    done <<<"$env_lines"

    if [[ "${SERVICE_STATE[has_customizations]}" == "true" ]]; then
        log_debug "Found ${#SERVICE_CUSTOM_ENV[@]} custom environment variable(s)"
    fi
}

# Backup service and cron files for rollback
backup_service_files() {
    log_debug "Backing up service files..."

    local service_file="${SERVICE_STATE[service_file]}"
    local cron_file="${SERVICE_STATE[cron_file]}"

    # Backup service file
    if [[ -f "$service_file" ]]; then
        local backup_service
        backup_service="$(mktemp "${service_file}.backup.XXXXXX")"

        if ! cp -a "$service_file" "$backup_service" 2>/dev/null; then
            log_error "Failed to backup service file"
            rm -f "$backup_service" 2>/dev/null || true
            return 1
        fi

        SERVICE_STATE[backup_service_file]="$backup_service"
        log_debug "Backed up service file to: $backup_service"
    fi

    # Backup cron file if it exists
    if [[ -f "$cron_file" ]]; then
        local backup_cron
        backup_cron="$(mktemp "${cron_file}.backup.XXXXXX")"

        if ! cp -a "$cron_file" "$backup_cron" 2>/dev/null; then
            log_warn "Failed to backup cron file (non-critical)"
            rm -f "$backup_cron" 2>/dev/null || true
            # Don't fail - cron backup is non-critical
        else
            SERVICE_STATE[backup_cron_file]="$backup_cron"
            log_debug "Backed up cron file to: $backup_cron"
        fi
    fi

    return 0
}

# Stop service safely with timeout
stop_service_safe() {
    if [[ "${SERVICE_STATE[was_running]}" != "true" ]]; then
        log_debug "Service was not running, skipping stop"
        return 0
    fi

    log_step "Stopping $SERVICE_NAME service..."

    # Try graceful stop
    if systemctl stop "$SERVICE_NAME" 2>/dev/null; then
        # Wait for service to actually stop
        local elapsed=0
        while systemctl is-active --quiet "$SERVICE_NAME" 2>/dev/null && [[ $elapsed -lt $SERVICE_STOP_TIMEOUT ]]; do
            sleep 1
            ((elapsed++)) || true
        done

        if systemctl is-active --quiet "$SERVICE_NAME" 2>/dev/null; then
            log_warn "Service did not stop gracefully within ${SERVICE_STOP_TIMEOUT}s, forcing..."
            systemctl kill "$SERVICE_NAME" 2>/dev/null || true
            sleep 2
        else
            log_success "Service stopped successfully"
            return 0
        fi
    else
        log_warn "Failed to stop service gracefully, forcing..."
        systemctl kill "$SERVICE_NAME" 2>/dev/null || true
        sleep 2
    fi

    # Verify stopped
    if systemctl is-active --quiet "$SERVICE_NAME" 2>/dev/null; then
        log_error "Failed to stop service after force kill"
        return 1
    fi

    log_success "Service stopped (forced)"
    return 0
}

# Reinstall service definition while preserving customizations
reinstall_service_with_customizations() {
    local script_path="$1"

    log_step "Reinstalling service definition..."

    # Verify script exists and is executable
    if [[ ! -f "$script_path" ]]; then
        log_error "Service manager script not found: $script_path"
        return 1
    fi

    if [[ ! -x "$script_path" ]]; then
        log_debug "Making script executable: $script_path"
        chmod +x "$script_path" 2>/dev/null || {
            log_error "Cannot make script executable: $script_path"
            return 1
        }
    fi

    # Call install command to regenerate service file
    # Capture output but suppress expected informational messages
    local install_output
    if ! install_output=$(run_unlocked "$script_path" install 2>&1); then
        log_error "Failed to reinstall service definition"
        if [[ -n "$install_output" ]]; then
            log_debug "Install output: $install_output"
        fi
        return 1
    fi

    log_success "Service definition reinstalled"

    # If there were customizations, merge them back in
    if [[ "${SERVICE_STATE[has_customizations]}" == "true" ]]; then
        log_step "Restoring custom environment variables..."

        local service_file="${SERVICE_STATE[service_file]}"

        if [[ ! -f "$service_file" ]]; then
            log_error "Service file not found after reinstall: $service_file"
            return 1
        fi

        # Create temporary file for merging
        local temp_service
        temp_service="$(mktemp)"

        # Strategy: Insert custom env vars after the last Environment= line
        # This preserves the structure and ensures custom values override defaults
        local last_env_line_num
        last_env_line_num=$(grep -n "^Environment=" "$service_file" | tail -n1 | cut -d: -f1) || true

        if [[ -z "$last_env_line_num" ]]; then
            # No Environment= lines found - insert after WorkingDirectory
            local working_dir_line
            working_dir_line=$(grep -n "^WorkingDirectory=" "$service_file" | tail -n1 | cut -d: -f1) || true

            if [[ -n "$working_dir_line" ]]; then
                # Insert after WorkingDirectory
                head -n "$working_dir_line" "$service_file" >"$temp_service"
                for custom_env in "${SERVICE_CUSTOM_ENV[@]}"; do
                    echo "$custom_env" >>"$temp_service"
                    log_debug "Restored: $custom_env"
                done
                tail -n +"$((working_dir_line + 1))" "$service_file" >>"$temp_service"
            else
                log_warn "Could not find insertion point for custom variables"
                cp "$service_file" "$temp_service"
            fi
        else
            # Insert after last Environment= line
            head -n "$last_env_line_num" "$service_file" >"$temp_service"
            for custom_env in "${SERVICE_CUSTOM_ENV[@]}"; do
                echo "$custom_env" >>"$temp_service"
                log_debug "Restored: $custom_env"
            done
            tail -n +"$((last_env_line_num + 1))" "$service_file" >>"$temp_service"
        fi

        # Atomically replace service file
        if ! mv -f "$temp_service" "$service_file" 2>/dev/null; then
            log_error "Failed to restore customizations to service file"
            rm -f "$temp_service"
            return 1
        fi

        log_success "Custom environment variables restored (${#SERVICE_CUSTOM_ENV[@]} variable(s))"
    fi

    return 0
}

# Start service safely with verification
start_service_safe() {
    if [[ "${SERVICE_STATE[was_running]}" != "true" ]]; then
        log_debug "Service was not running before update, not starting"
        return 0
    fi

    log_step "Starting $SERVICE_NAME service..."

    # Start service
    local start_output
    if ! start_output=$(systemctl start "$SERVICE_NAME" 2>&1); then
        log_error "Failed to start service"
        if [[ -n "$start_output" ]]; then
            log_debug "Start output: $start_output"
        fi
        log_info "Check status: systemctl status $SERVICE_NAME"
        log_info "Check logs: journalctl -u $SERVICE_NAME -n 50 --no-pager"
        return 1
    fi

    # Wait for service to fully start
    local elapsed=0
    while ! systemctl is-active --quiet "$SERVICE_NAME" 2>/dev/null && [[ $elapsed -lt $SERVICE_START_TIMEOUT ]]; do
        sleep 1
        ((elapsed++)) || true
    done

    # Verify service is running
    if ! systemctl is-active --quiet "$SERVICE_NAME" 2>/dev/null; then
        log_error "Service failed to start within ${SERVICE_START_TIMEOUT}s"
        log_info "Check status: systemctl status $SERVICE_NAME"
        log_info "Check logs: journalctl -u $SERVICE_NAME -n 50 --no-pager"
        return 1
    fi

    log_success "Service started successfully"
    return 0
}

# Restore service files from backup
restore_service_from_backup() {
    log_warn "Restoring service files from backup..."

    local service_file="${SERVICE_STATE[service_file]}"
    local backup_service="${SERVICE_STATE[backup_service_file]}"
    local cron_file="${SERVICE_STATE[cron_file]}"
    local backup_cron="${SERVICE_STATE[backup_cron_file]}"

    local restore_failed=false

    # Restore service file
    if [[ -f "$backup_service" ]]; then
        if cp -a "$backup_service" "$service_file" 2>/dev/null; then
            log_debug "Service file restored from backup"
        else
            log_error "Failed to restore service file from backup"
            restore_failed=true
        fi
    fi

    # Restore cron file
    if [[ -f "$backup_cron" ]]; then
        if cp -a "$backup_cron" "$cron_file" 2>/dev/null; then
            log_debug "Cron file restored from backup"
        else
            log_warn "Failed to restore cron file from backup (non-critical)"
        fi
    fi

    # Reload systemd to pick up restored service file
    systemctl daemon-reload 2>/dev/null || true

    if [[ "$restore_failed" == "true" ]]; then
        return 1
    fi

    log_info "Service files restored from backup"
    return 0
}

# Clean up backup files
cleanup_service_backups() {
    log_debug "Cleaning up service backup files..."

    local backup_service="${SERVICE_STATE[backup_service_file]}"
    local backup_cron="${SERVICE_STATE[backup_cron_file]}"

    if [[ -f "$backup_service" ]]; then
        rm -f "$backup_service" 2>/dev/null || true
        log_debug "Removed service backup file"
    fi

    if [[ -f "$backup_cron" ]]; then
        rm -f "$backup_cron" 2>/dev/null || true
        log_debug "Removed cron backup file"
    fi
}

# Save service state to marker file for post-exec restoration
save_service_state_to_marker() {
    log_debug "Saving service state to marker file..."

    local marker="$SERVICE_UPDATE_MARKER"
    local temp_marker
    temp_marker="$(mktemp)"

    # Write state as simple key=value format for easy sourcing
    cat >"$temp_marker" <<EOF
# Service update state - automatically generated
INSTALLED=${SERVICE_STATE[installed]}
WAS_RUNNING=${SERVICE_STATE[was_running]}
WAS_ENABLED=${SERVICE_STATE[was_enabled]}
HAS_CUSTOMIZATIONS=${SERVICE_STATE[has_customizations]}
SERVICE_FILE=${SERVICE_STATE[service_file]}
CRON_FILE=${SERVICE_STATE[cron_file]}
BACKUP_SERVICE_FILE=${SERVICE_STATE[backup_service_file]}
BACKUP_CRON_FILE=${SERVICE_STATE[backup_cron_file]}
EOF

    # Append custom environment lines with indices
    if [[ ${#SERVICE_CUSTOM_ENV[@]} -gt 0 ]]; then
        echo "CUSTOM_ENV_COUNT=${#SERVICE_CUSTOM_ENV[@]}" >>"$temp_marker"
        local i=0
        for env_line in "${SERVICE_CUSTOM_ENV[@]}"; do
            # Escape quotes for safe storage
            local escaped_line="${env_line//\"/\\\"}"
            echo "CUSTOM_ENV_${i}=\"${escaped_line}\"" >>"$temp_marker"
            ((i++)) || true
        done
    else
        echo "CUSTOM_ENV_COUNT=0" >>"$temp_marker"
    fi

    # Atomic move with restricted permissions
    if ! mv -f "$temp_marker" "$marker" 2>/dev/null; then
        log_error "Failed to save service state marker"
        rm -f "$temp_marker"
        return 1
    fi

    chmod 600 "$marker" 2>/dev/null || true
    log_debug "Service state saved to: $marker"
    return 0
}

# Load service state from marker file
load_service_state_from_marker() {
    local marker="$SERVICE_UPDATE_MARKER"

    if [[ ! -f "$marker" ]]; then
        log_debug "No service state marker file found"
        return 1
    fi

    log_debug "Loading service state from marker file..."

    # Reset state
    SERVICE_STATE=()
    SERVICE_CUSTOM_ENV=()

    # Parse marker file safely without source (prevents code injection)
    local line key value
    local -A marker_vars=()
    while IFS='=' read -r key value; do
        # Skip comments and empty lines
        [[ -z "$key" || "$key" =~ ^[[:space:]]*# ]] && continue
        # Strip leading/trailing whitespace from key
        key="${key#"${key%%[![:space:]]*}"}"
        key="${key%"${key##*[![:space:]]}"}"
        # Only accept known safe key patterns
        if [[ "$key" =~ ^[A-Z_][A-Z_0-9]*$ ]]; then
            # Strip surrounding quotes from value
            value="${value#\"}"
            value="${value%\"}"
            marker_vars["$key"]="$value"
        fi
    done <"$marker" || {
        log_error "Failed to read service state marker"
        return 1
    }

    # Reconstruct SERVICE_STATE associative array
    SERVICE_STATE[installed]="${marker_vars[INSTALLED]:-false}"
    SERVICE_STATE[was_running]="${marker_vars[WAS_RUNNING]:-false}"
    SERVICE_STATE[was_enabled]="${marker_vars[WAS_ENABLED]:-false}"
    SERVICE_STATE[has_customizations]="${marker_vars[HAS_CUSTOMIZATIONS]:-false}"
    SERVICE_STATE[service_file]="${marker_vars[SERVICE_FILE]:-}"
    SERVICE_STATE[cron_file]="${marker_vars[CRON_FILE]:-}"
    SERVICE_STATE[backup_service_file]="${marker_vars[BACKUP_SERVICE_FILE]:-}"
    SERVICE_STATE[backup_cron_file]="${marker_vars[BACKUP_CRON_FILE]:-}"

    # Reconstruct SERVICE_CUSTOM_ENV array
    local custom_env_count="${marker_vars[CUSTOM_ENV_COUNT]:-0}"
    local i
    for ((i = 0; i < custom_env_count; i++)); do
        local env_value="${marker_vars[CUSTOM_ENV_${i}]:-}"
        # Unescape quotes
        env_value="${env_value//\\\"/\"}"
        SERVICE_CUSTOM_ENV+=("$env_value")
    done

    log_debug "Service state loaded: installed=${SERVICE_STATE[installed]}, was_running=${SERVICE_STATE[was_running]}, customizations=${SERVICE_STATE[has_customizations]}"
    return 0
}

# Check if there's a pending service update
check_pending_service_update() {
    if [[ -f "$SERVICE_UPDATE_MARKER" ]]; then
        log_debug "Detected pending service update marker"
        return 0
    fi
    return 1
}

# Complete a pending service update (called after script restart)
complete_pending_service_update() {
    if ! load_service_state_from_marker; then
        log_debug "No pending service update found"
        return 0
    fi

    echo
    log_info "Completing pending service update from previous operation..."
    echo

    # Complete the service update
    if ! post_checkout_service_update; then
        log_error "Failed to complete pending service update"
        log_warn "Service may need manual intervention"
        log_info "Try: systemctl status $SERVICE_NAME"
        return 1
    fi

    # Remove marker on success
    rm -f "$SERVICE_UPDATE_MARKER"

    echo
    log_success "Service update completed successfully"
    return 0
}

################################################################################
# Service Update Handler (Pre-Checkout)
################################################################################

# Handle service update preparation before git checkout
handle_systemd_service_update() {
    local target_version="$1"

    # Detect if service is installed
    if ! detect_systemd_service; then
        log_debug "No systemd service installed, skipping service update handling"
        return 0
    fi

    log_info "Detected installed systemd service: $SERVICE_NAME"

    # Show service status
    echo
    echo "${BOLD}Systemd Service Status:${NC}"
    echo "  Service file: ${SERVICE_STATE[service_file]}"
    echo "  Currently running: ${SERVICE_STATE[was_running]}"
    echo "  Enabled at boot: ${SERVICE_STATE[was_enabled]}"

    if [[ "${SERVICE_STATE[has_customizations]}" == "true" ]]; then
        echo "  ${YELLOW}Custom environment variables: ${#SERVICE_CUSTOM_ENV[@]}${NC}"
        echo
        echo "${YELLOW}Detected customizations:${NC}"
        for env_line in "${SERVICE_CUSTOM_ENV[@]}"; do
            echo "    ${env_line}"
        done
        echo
        log_info "These customizations will be preserved during the update"
    fi

    echo
    log_info "The service will be stopped during the update and restarted afterwards"
    echo

    # Confirm if customizations exist
    if [[ "${SERVICE_STATE[has_customizations]}" == "true" ]]; then
        if ! confirm_action "Continue with service update?"; then
            log_info "Service update cancelled by user"
            return "$E_USER_ABORT"
        fi
        echo
    fi

    # Backup service files
    if ! backup_service_files; then
        log_error "Failed to backup service files"
        return "$E_GENERAL"
    fi

    # Stop service if running
    if ! stop_service_safe; then
        log_error "Failed to stop service - cannot proceed with update"
        # Cleanup backups since we're aborting
        cleanup_service_backups
        return "$E_GENERAL"
    fi

    # Save state to marker file (for post-exec completion if updater restarts)
    if ! save_service_state_to_marker; then
        log_error "Failed to save service state"
        # Try to restart service since we're aborting
        if [[ "${SERVICE_STATE[was_running]}" == "true" ]]; then
            systemctl start "$SERVICE_NAME" 2>/dev/null || true
        fi
        cleanup_service_backups
        return "$E_GENERAL"
    fi

    log_debug "Service update preparation completed"
    return 0
}

################################################################################
# Service Update Handler (Post-Checkout)
################################################################################

# Complete service update after successful git checkout
post_checkout_service_update() {
    local script_path="./${SERVICE_SCRIPT}"

    # Verify service was installed
    if [[ "${SERVICE_STATE[installed]}" != "true" ]]; then
        log_debug "Service not installed, skipping post-checkout service update"
        return 0
    fi

    # Check if service script exists in new version
    if [[ ! -f "$script_path" ]]; then
        log_error "Service script not found after checkout: $script_path"
        log_error "This indicates the service script was removed or renamed"
        return 1
    fi

    # Check if the service script actually changed
    local script_changed=false
    if ! git diff --quiet "${TRANSACTION_STATE[original_head]}" HEAD -- "$script_path" 2>/dev/null; then
        script_changed=true
        log_info "Service script changed, reinstalling service definition..."
    else
        log_debug "Service script unchanged, skipping reinstallation"
    fi

    # If script changed, reinstall service
    if [[ "$script_changed" == "true" ]]; then
        if ! reinstall_service_with_customizations "$script_path"; then
            log_error "Failed to reinstall service definition"
            return 1
        fi

        # Reload systemd daemon to pick up new service definition
        log_step "Reloading systemd daemon..."
        if ! systemctl daemon-reload 2>/dev/null; then
            log_error "Failed to reload systemd daemon"
            return 1
        fi
        log_success "Systemd daemon reloaded"
    fi

    # Start service if it was running before
    if ! start_service_safe; then
        log_error "Service update failed - service did not start"
        log_warn "Attempting to restore service from backup..."

        # Attempt rollback
        restore_service_from_backup
        systemctl daemon-reload 2>/dev/null || true
        systemctl start "$SERVICE_NAME" 2>/dev/null || true

        return 1
    fi

    # Success - cleanup backups
    cleanup_service_backups

    log_success "Service update completed successfully"
    return 0
}

################################################################################
# Migration Handler (Post-Checkout)
################################################################################

# Run migrations after successful update
# Migrations are idempotent and track completion via marker files
run_post_update_migrations() {
    log_step "Checking for pending migrations..."

    # Ensure migration marker directory exists
    if [[ ! -d "$MIGRATION_MARKER_DIR" ]]; then
        mkdir -p "$MIGRATION_MARKER_DIR" 2>/dev/null || {
            log_warn "Could not create migration marker directory: $MIGRATION_MARKER_DIR"
            log_warn "Migrations may re-run on next update"
        }
    fi

    local migrations_run=0

    # Migration: mediamtx-stream-manager.sh -> lyrebird-stream-manager.sh rename
    if ! migration_stream_manager_rename; then
        log_warn "Stream manager rename migration encountered issues"
        # Don't fail the update for migration issues
    else
        ((migrations_run++)) || true
    fi

    if [[ $migrations_run -gt 0 ]]; then
        log_success "Migrations completed: $migrations_run"
    else
        log_debug "No pending migrations"
    fi

    return 0
}

# Migration: Handle mediamtx-stream-manager.sh -> lyrebird-stream-manager.sh rename
# This migration:
#   1. Updates systemd service file if it references the old script name
#   2. Removes old script from /usr/local/bin if present
#   3. Installs new script to /usr/local/bin
#   4. Creates symlink from old log to new log for continuity
#   5. Updates cron job if present
migration_stream_manager_rename() {
    local marker_file="${MIGRATION_MARKER_DIR}/stream-manager-rename-v1"

    # Check if migration already completed
    if [[ -f "$marker_file" ]]; then
        log_debug "Migration 'stream-manager-rename' already completed"
        return 0
    fi

    log_step "Running migration: stream-manager-rename..."

    local changes_made=0
    local errors=0

    # 1. Check and update systemd service file
    if [[ -f "$SERVICE_FILE" ]]; then
        if grep -q "$OLD_STREAM_MANAGER" "$SERVICE_FILE" 2>/dev/null; then
            log_info "  Updating systemd service file..."
            if sed -i "s|${OLD_STREAM_MANAGER}|${SERVICE_SCRIPT}|g" "$SERVICE_FILE" 2>/dev/null; then
                log_success "  Updated service file references"
                ((changes_made++)) || true
            else
                log_warn "  Could not update service file (permission denied?)"
                ((errors++)) || true
            fi
        fi
    fi

    # 2. Handle /usr/local/bin installation
    local old_bin="${STREAM_MANAGER_BIN_DIR}/${OLD_STREAM_MANAGER}"
    local new_bin="${STREAM_MANAGER_BIN_DIR}/${SERVICE_SCRIPT}"

    if [[ -f "$old_bin" ]] || [[ -L "$old_bin" ]]; then
        log_info "  Removing old script from ${STREAM_MANAGER_BIN_DIR}..."
        if rm -f "$old_bin" 2>/dev/null; then
            log_success "  Removed $old_bin"
            ((changes_made++)) || true
        else
            log_warn "  Could not remove $old_bin (permission denied?)"
            ((errors++)) || true
        fi
    fi

    # Install new script if we have it and it's not already there
    if [[ -f "./${SERVICE_SCRIPT}" ]] && [[ ! -f "$new_bin" ]]; then
        log_info "  Installing new script to /usr/local/bin..."
        if cp "./${SERVICE_SCRIPT}" "$new_bin" && chmod +x "$new_bin" 2>/dev/null; then
            log_success "  Installed $new_bin"
            ((changes_made++)) || true
        else
            log_warn "  Could not install to /usr/local/bin (permission denied?)"
            ((errors++)) || true
        fi
    fi

    # 3. Handle log file migration (create symlink for continuity)
    if [[ -f "$OLD_STREAM_MANAGER_LOG" ]] && [[ ! -L "$OLD_STREAM_MANAGER_LOG" ]]; then
        log_info "  Migrating log file..."
        # Move old log to new location, create symlink back
        if mv "$OLD_STREAM_MANAGER_LOG" "$NEW_STREAM_MANAGER_LOG" 2>/dev/null; then
            if ln -sf "$NEW_STREAM_MANAGER_LOG" "$OLD_STREAM_MANAGER_LOG" 2>/dev/null; then
                log_success "  Log file migrated with backward-compatible symlink"
                ((changes_made++)) || true
            else
                log_warn "  Could not create backward-compatible symlink"
            fi
        else
            log_warn "  Could not migrate log file (permission denied?)"
            ((errors++)) || true
        fi
    fi

    # 4. Update cron job if present
    if [[ -f "$SERVICE_CRON_FILE" ]]; then
        if grep -q "$OLD_STREAM_MANAGER" "$SERVICE_CRON_FILE" 2>/dev/null; then
            log_info "  Updating cron job..."
            if sed -i "s|${OLD_STREAM_MANAGER}|${SERVICE_SCRIPT}|g" "$SERVICE_CRON_FILE" 2>/dev/null; then
                log_success "  Updated cron job references"
                ((changes_made++)) || true
            else
                log_warn "  Could not update cron job (permission denied?)"
                ((errors++)) || true
            fi
        fi
    fi

    # 5. Reload systemd if we made service changes
    if [[ $changes_made -gt 0 ]] && [[ -f "$SERVICE_FILE" ]]; then
        log_info "  Reloading systemd daemon..."
        systemctl daemon-reload 2>/dev/null || log_warn "  Could not reload systemd"
    fi

    # Mark migration complete if no critical errors
    if [[ $errors -eq 0 ]]; then
        echo "$(date -Iseconds)" >"$marker_file" 2>/dev/null || true
        if [[ $changes_made -gt 0 ]]; then
            log_success "Migration 'stream-manager-rename' completed ($changes_made changes)"
        else
            log_debug "Migration 'stream-manager-rename' - no changes needed"
            echo "$(date -Iseconds) - no changes needed" >"$marker_file" 2>/dev/null || true
        fi
        return 0
    else
        log_warn "Migration 'stream-manager-rename' completed with $errors errors"
        log_warn "Some manual steps may be required (see documentation)"
        return 1
    fi
}

################################################################################
# Cleanup and Error Handlers
################################################################################

# shellcheck disable=SC2317  # Function invoked indirectly via cleanup
cleanup() {
    local exit_code=$?

    log_debug "Cleanup triggered (exit code: $exit_code)"

    # CRITICAL: Disable traps to prevent recursion
    trap - EXIT INT TERM

    # If we're in an active transaction and exiting with error, attempt rollback
    if [[ "${TRANSACTION_STATE[active]}" == "true" ]] && [[ $exit_code -ne 0 ]]; then
        log_error "Operation failed - attempting automatic rollback..."
        if [[ -n "$INTERRUPT_SIGNAL" ]]; then
            transaction_rollback "interrupted by ${INTERRUPT_SIGNAL}" || true
        else
            transaction_rollback "stopped with exit status ${exit_code}" || true
        fi
    fi

    # Restore git configuration
    restore_git_config

    # Release lock file
    release_lock

    # Exit without re-triggering trap
    exit "$exit_code"
}

# Trap all exit conditions
# SIGINT/SIGTERM end the run with E_USER_ABORT; EXIT then rolls back any open
# transaction (cleanup). INTERRUPT_SIGNAL says why, for the history record.
INTERRUPT_SIGNAL=""
# shellcheck disable=SC2317  # Invoked through the INT/TERM traps
on_interrupt_signal() {
    INTERRUPT_SIGNAL="$1"
    log_error "Script interrupted by user"
    exit "$E_USER_ABORT"
}
install_signal_traps() {
    trap cleanup EXIT
    trap 'on_interrupt_signal SIGINT' INT
    trap 'on_interrupt_signal SIGTERM' TERM
}
install_signal_traps

# Run a git command that writes working-tree files with the operator's umask
git_worktree() {
    (
        umask "$ORIGINAL_UMASK"
        git "$@"
    )
}

################################################################################
# Git Configuration Management
################################################################################

# core.fileMode is switched off for the length of a run: the scripts are
# tracked as 644 but made executable on disk, which git would otherwise report
# as local modifications. The value it had is written to GIT_CONFIG_SAVED_FILE
# BEFORE the change, so a run that is killed (or exec'd into the new updater,
# which skips the EXIT trap) cannot leave "false" behind for good: whoever
# starts next restores the saved value first.
save_git_config() {
    log_debug "Saving git configuration..."

    if [[ -f "$GIT_CONFIG_SAVED_FILE" ]]; then
        log_warn "An earlier run ended before restoring core.fileMode; restoring it now"
        restore_git_config
    fi

    # Save core.fileMode setting
    local current_filemode
    current_filemode="$(git config --local core.fileMode 2>/dev/null || true)"
    ORIGINAL_GIT_CONFIG["core.fileMode"]="$current_filemode"
    ORIGINAL_GIT_CONFIG["saved"]="true"

    if ! printf '%s\n' "${current_filemode:-<unset>}" | updater_atomic_write "$GIT_CONFIG_SAVED_FILE" 0600; then
        log_warn "Could not record the current core.fileMode in $GIT_CONFIG_SAVED_FILE"
        log_warn "If this run is killed, restore it by hand: git config --local core.fileMode ${current_filemode:-true}"
    fi

    # Apply our temporary setting
    git config --local core.fileMode false 2>/dev/null || true

    log_debug "Git config saved (core.fileMode: ${current_filemode:-<unset>})"
}

# shellcheck disable=SC2317  # Function invoked indirectly via cleanup
restore_git_config() {
    log_debug "Restoring git configuration..."

    # Only put back what was saved: by this run, or by an earlier one that died.
    # (Run unconditionally, an early exit -- the lock is held, not a repository --
    # deleted an operator's own core.fileMode.)
    local value=""
    if [[ "${ORIGINAL_GIT_CONFIG["saved"]:-}" == "true" ]]; then
        value="${ORIGINAL_GIT_CONFIG["core.fileMode"]:-}"
    elif [[ -f "$GIT_CONFIG_SAVED_FILE" ]]; then
        IFS= read -r value <"$GIT_CONFIG_SAVED_FILE" || true
        if [[ "$value" == "<unset>" ]]; then
            value=""
        fi
    else
        log_debug "core.fileMode was not changed; nothing to restore"
        return 0
    fi

    # Restore core.fileMode
    if [[ -n "$value" ]]; then
        git config --local core.fileMode "$value" 2>/dev/null || true
    else
        git config --unset --local core.fileMode 2>/dev/null || true
    fi
    rm -f -- "$GIT_CONFIG_SAVED_FILE" 2>/dev/null || true
    ORIGINAL_GIT_CONFIG["saved"]="false"

    log_debug "Git config restored"
}

################################################################################
# Prerequisite Checks
################################################################################

check_prerequisites() {
    log_debug "Checking prerequisites..."

    # IMPORTANT: Warn if running with sudo or as root — but NOT when resuming a
    # self-update (--post-update-*): the service is stopped and blocking on this
    # prompt there risks stranding it down.
    if { [[ "${SUDO_USER:-}" != "" ]] || [[ "$EUID" -eq 0 ]]; } && [[ "${RESUMED_POST_UPDATE:-false}" != "true" ]]; then
        log_warn "[!]  WARNING: This script is running with root/sudo privileges"
        log_warn "This may change file ownership in the repository"
        echo

        if [[ "${SUDO_USER:-}" != "" ]]; then
            log_info "You used: sudo ./lyrebird-updater.sh"
            log_info "This is usually NOT needed. Try running without sudo"
        else
            log_warn "Running directly as root is not recommended"
        fi
        echo

        if ! confirm_action "Continue anyway? (may modify file ownership)"; then
            log_error "Cancelled by user"
            return "$E_USER_ABORT"
        fi
        echo
    fi

    # Check for git
    if ! type -P git >/dev/null 2>&1; then
        log_error "Git is not installed or not in PATH"
        log_info "Installation instructions:"
        log_info "  Debian/Ubuntu: sudo apt-get install git"
        log_info "  Fedora/RHEL:   sudo dnf install git"
        log_info "  macOS:         brew install git"
        return "$E_PREREQUISITES"
    fi

    # Check git version
    local git_version
    if ! git_version="$(git --version 2>/dev/null | awk '{print $3}')"; then
        log_error "Could not determine git version"
        return "$E_PREREQUISITES"
    fi

    local git_major git_minor
    git_major="${git_version%%.*}"
    git_minor="${git_version#*.}"
    git_minor="${git_minor%%.*}"

    if [[ "$git_major" -lt "$MIN_GIT_MAJOR" ]] \
        || [[ "$git_major" -eq "$MIN_GIT_MAJOR" && "$git_minor" -lt "$MIN_GIT_MINOR" ]]; then
        log_error "Git version $git_version is too old (required: ${MIN_GIT_MAJOR}.${MIN_GIT_MINOR}+)"
        return "$E_PREREQUISITES"
    fi

    log_debug "Git version: $git_version [OK]"

    # Check bash version
    local bash_major="${BASH_VERSINFO[0]}"
    local bash_minor="${BASH_VERSINFO[1]}"

    if [[ "$bash_major" -lt "$MIN_BASH_MAJOR" ]] \
        || [[ "$bash_major" -eq "$MIN_BASH_MAJOR" && "$bash_minor" -lt "$MIN_BASH_MINOR" ]]; then
        log_error "Bash version $bash_major.$bash_minor is too old (required: ${MIN_BASH_MAJOR}.${MIN_BASH_MINOR}+)"
        return "$E_PREREQUISITES"
    fi

    log_debug "Bash version: $bash_major.$bash_minor [OK]"

    # Check for required external utilities
    local required_utils=("awk" "sed" "grep" "tput" "flock")
    local missing_utils=()

    for util in "${required_utils[@]}"; do
        if ! command -v "$util" >/dev/null 2>&1; then
            missing_utils+=("$util")
        fi
    done

    if [[ ${#missing_utils[@]} -gt 0 ]]; then
        log_error "Required utilities not found: ${missing_utils[*]}"
        log_info "Please install these utilities and try again"
        log_info "(flock is part of util-linux)"
        return "$E_PREREQUISITES"
    fi

    # Check for systemctl (for service management)
    if ! type -P systemctl >/dev/null 2>&1; then
        log_debug "systemctl not found - service update features will be limited"
    fi

    # Check for stat (different syntax on different systems)
    if ! command -v stat >/dev/null 2>&1; then
        log_warn "Warning: 'stat' command not found"
        log_info "Some features may not work properly"
    fi

    # Check for timeout (optional but recommended)
    if ! command -v timeout >/dev/null 2>&1; then
        # Try gtimeout on macOS
        if [[ "$OSTYPE" == "darwin"* ]] && command -v gtimeout >/dev/null 2>&1; then
            log_debug "Using gtimeout (macOS coreutils)"
            # Create function alias for compatibility
            # shellcheck disable=SC2329  # called through run_unlocked
            timeout() { gtimeout "$@"; }
            export -f timeout
        else
            log_debug "Note: 'timeout' command not available (fetch operations may hang)"
        fi
    fi

    log_debug "All prerequisites checked [OK]"
    return 0
}

################################################################################
# Git Repository Validation
################################################################################

check_git_repository() {
    log_debug "Validating git repository..."

    # Check if we're in a git repository
    if ! git rev-parse --git-dir >/dev/null 2>&1; then
        log_error "Not a git repository"
        log_error "This script must be run from within the LyreBirdAudio repository"
        echo
        log_info "To get started:"
        log_info "  1. Clone: git clone $REPO_URL"
        log_info "  2. Enter:  cd $REPO_NAME"
        log_info "  3. Run:    ./$SCRIPT_NAME"
        return "$E_NOT_GIT_REPO"
    fi

    # Verify remote is configured
    local origin_url
    if ! origin_url="$(git remote get-url origin 2>/dev/null)"; then
        log_error "No 'origin' remote configured"
        log_info "To fix: git remote add origin $REPO_URL"
        return "$E_NOT_GIT_REPO"
    fi

    # Validate origin URL
    if [[ ! "$origin_url" =~ github\.com[:/]${REPO_OWNER}/${REPO_NAME} ]]; then
        log_warn "Remote 'origin' URL does not match expected repository"
        log_warn "Expected: $REPO_URL"
        log_warn "Found:    $origin_url"
        echo
        if ! confirm_action "Continue anyway?"; then
            return "$E_NOT_GIT_REPO"
        fi
    fi

    # Check git permissions
    local git_dir
    if ! git_dir="$(git rev-parse --git-dir 2>/dev/null)"; then
        log_error "Could not determine .git directory location"
        return "$E_PERMISSION"
    fi

    if [[ ! -w "$git_dir" ]]; then
        log_error "No write permission for git repository: $git_dir"
        log_info "To fix: sudo chown -R $USER:$USER $(git rev-parse --show-toplevel)"
        return "$E_PERMISSION"
    fi

    # Check if git directory is owned by root (common issue)
    if [[ -e "$git_dir/config" ]] && command -v stat >/dev/null 2>&1; then
        local owner
        owner="$(stat -c %U "$git_dir/config" 2>/dev/null || stat -f %Su "$git_dir/config" 2>/dev/null || echo "$USER")"

        if [[ "$owner" == "root" ]]; then
            log_error "Git repository files are owned by root"
            log_info "To fix: sudo chown -R $USER:$USER $(git rev-parse --show-toplevel)"
            return "$E_PERMISSION"
        fi
    fi

    log_debug "Git repository validated [OK]"
    return 0
}

################################################################################
# Git State Detection and Validation
################################################################################

detect_git_state() {
    log_debug "Detecting git state..."

    local git_dir
    git_dir="$(git rev-parse --git-dir 2>/dev/null)"

    # Check for ongoing operations (order matters - check most specific first)
    if [[ -f "$git_dir/MERGE_HEAD" ]]; then
        GIT_STATE="merge"
        log_debug "Git state: merge in progress"
        return 0
    elif [[ -d "$git_dir/rebase-merge" ]] || [[ -d "$git_dir/rebase-apply" ]]; then
        GIT_STATE="rebase"
        log_debug "Git state: rebase in progress"
        return 0
    elif [[ -f "$git_dir/REVERT_HEAD" ]]; then
        GIT_STATE="revert"
        log_debug "Git state: revert in progress"
        return 0
    elif [[ -f "$git_dir/CHERRY_PICK_HEAD" ]]; then
        GIT_STATE="cherry-pick"
        log_debug "Git state: cherry-pick in progress"
        return 0
    elif [[ -f "$git_dir/BISECT_LOG" ]]; then
        GIT_STATE="bisect"
        log_debug "Git state: bisect in progress"
        return 0
    elif [[ -d "$git_dir/sequencer" ]]; then
        GIT_STATE="sequencer"
        log_debug "Git state: sequencer operation in progress (interactive rebase/revert)"
        return 0
    fi

    # Check for local changes
    check_local_changes

    if [[ "$HAS_LOCAL_CHANGES" == "true" ]]; then
        GIT_STATE="dirty"
        log_debug "Git state: dirty (local modifications)"
    else
        GIT_STATE="clean"
        log_debug "Git state: clean"
    fi

    return 0
}

validate_clean_state() {
    detect_git_state

    case "$GIT_STATE" in
        merge)
            log_error "Git merge in progress"
            log_info "You must complete or abort the merge first:"
            log_info "  To continue merge:  git merge --continue"
            log_info "  To cancel merge:    git merge --abort"
            return "$E_BAD_STATE"
            ;;
        rebase)
            log_error "Git rebase in progress"
            log_info "You must complete or abort the rebase first:"
            log_info "  To continue rebase: git rebase --continue"
            log_info "  To cancel rebase:   git rebase --abort"
            return "$E_BAD_STATE"
            ;;
        revert)
            log_error "Git revert in progress"
            log_info "You must complete or abort the revert first:"
            log_info "  To continue:        git revert --continue"
            log_info "  To cancel:          git revert --abort"
            return "$E_BAD_STATE"
            ;;
        cherry-pick)
            log_error "Git cherry-pick in progress"
            log_info "You must complete or abort the cherry-pick first:"
            log_info "  To continue:        git cherry-pick --continue"
            log_info "  To cancel:          git cherry-pick --abort"
            return "$E_BAD_STATE"
            ;;
        bisect)
            log_error "Git bisect in progress"
            log_info "You must finish the bisect first:"
            log_info "  To complete: git bisect reset"
            return "$E_BAD_STATE"
            ;;
        sequencer)
            log_error "Git sequencer operation in progress"
            log_info "You must complete or abort the current operation first"
            log_info "Check 'git status' for details"
            return "$E_BAD_STATE"
            ;;
        clean | dirty)
            # These are valid states
            return 0
            ;;
        *)
            log_warn "Unknown git state detected"
            return 0
            ;;
    esac
}

################################################################################
# Repository State Functions
################################################################################

# Ask origin which branch its HEAD points to. Bounded: on a dead uplink
# `git ls-remote` waits for ever, and this ran at the start of every command
# (even --version and --help), so a node that had lost its network could not
# be asked anything, nor rolled back.
query_remote_default_branch() {
    local out
    if command -v timeout >/dev/null 2>&1; then
        out="$(GIT_HTTP_LOW_SPEED_LIMIT=1000 GIT_HTTP_LOW_SPEED_TIME="$REMOTE_PROBE_TIMEOUT" \
            run_unlocked timeout "$REMOTE_PROBE_TIMEOUT" git ls-remote --symref origin HEAD 2>/dev/null)" || return 1
    else
        out="$(GIT_HTTP_LOW_SPEED_LIMIT=1000 GIT_HTTP_LOW_SPEED_TIME="$REMOTE_PROBE_TIMEOUT" \
            git ls-remote --symref origin HEAD 2>/dev/null)" || return 1
    fi
    awk '/^ref:/ {sub(/refs\/heads\//, "", $2); print $2; exit}' <<<"$out"
}

# Usage: get_default_branch [offline]
# With "offline" the network is not asked at all: the answer comes from what is
# already in the clone (the cached refs/remotes/origin/HEAD, then the branches).
get_default_branch() {
    local offline="${1:-}"
    log_debug "Detecting default branch..."

    # Special handling for git-flow: if both main and develop exist, develop is development branch
    local has_develop=false
    local has_main=false
    local remote_head=""

    # Check what branches exist
    if git show-ref --verify --quiet refs/remotes/origin/develop 2>/dev/null; then
        has_develop=true
        log_debug "Found develop branch"
    fi

    if git show-ref --verify --quiet refs/remotes/origin/main 2>/dev/null; then
        has_main=true
        log_debug "Found main branch"
    fi

    # Git-flow pattern: both main and develop exist -> develop is development
    if [[ "$has_develop" == "true" && "$has_main" == "true" ]]; then
        log_debug "Git-flow detected (both main and develop exist) -> using develop as development branch"
        echo "develop"
        return 0
    fi

    # Try to get remote HEAD (but only use if not in git-flow pattern)
    if [[ "$offline" != "offline" ]]; then
        if remote_head="$(query_remote_default_branch)" && [[ -n "$remote_head" ]]; then
            log_debug "Remote HEAD points to: $remote_head"
            echo "$remote_head"
            return 0
        fi
    fi

    # What the last successful fetch recorded (git remote set-head origin --auto)
    remote_head="$(git symbolic-ref -q --short refs/remotes/origin/HEAD 2>/dev/null || true)"
    remote_head="${remote_head#origin/}"
    if [[ -n "$remote_head" ]]; then
        log_debug "Cached remote HEAD points to: $remote_head"
        echo "$remote_head"
        return 0
    fi

    log_debug "Remote HEAD detection failed, checking local branches..."

    # Check for develop (single develop branch without main)
    if [[ "$has_develop" == "true" ]]; then
        log_debug "Default branch: develop (git-flow single)"
        echo "develop"
        return 0
    fi

    # Check for main (GitHub modern)
    if [[ "$has_main" == "true" ]]; then
        log_debug "Default branch: main (GitHub)"
        echo "main"
        return 0
    fi

    # Check for master (legacy)
    if git show-ref --verify --quiet refs/remotes/origin/master 2>/dev/null; then
        log_debug "Default branch: master (legacy)"
        echo "master"
        return 0
    fi

    # Fallback
    log_debug "No standard branches found, using fallback: main"
    echo "main"
    return 0
}

get_current_version() {
    log_debug "Getting current version..."

    # Check if HEAD exists
    if ! git rev-parse --verify --quiet HEAD >/dev/null 2>&1; then
        CURRENT_VERSION="(empty repository)"
        CURRENT_BRANCH=""
        IS_DETACHED=false
        return 0
    fi

    # Get short commit hash
    CURRENT_VERSION="$(git rev-parse --short HEAD 2>/dev/null)"

    # Check if detached HEAD
    if ! git symbolic-ref -q HEAD >/dev/null 2>&1; then
        IS_DETACHED=true
        CURRENT_BRANCH=""

        # Try to get tag name
        local tag_name
        if tag_name="$(git describe --tags --exact-match HEAD 2>/dev/null)"; then
            CURRENT_VERSION="$tag_name"
        fi

        log_debug "Viewing specific version: $CURRENT_VERSION"
    else
        IS_DETACHED=false
        CURRENT_BRANCH="$(git rev-parse --abbrev-ref HEAD 2>/dev/null)"
        log_debug "On branch $CURRENT_BRANCH at $CURRENT_VERSION"
    fi

    return 0
}

check_local_changes() {
    log_debug "Checking for local changes..."

    # Check if HEAD exists
    if ! git rev-parse --verify --quiet HEAD >/dev/null 2>&1; then
        HAS_LOCAL_CHANGES=false
        return 0
    fi

    # Check for any changes. `git status` (not the plumbing `git diff-index`)
    # because it refreshes stale stat data first: after the updater's own chmod
    # of the scripts every one of them looked modified to diff-index, so a
    # pristine clone reported "local modifications" and offered to stash
    # nothing. A failing status is treated as "dirty" (the safe answer).
    local porcelain=""
    if ! porcelain="$(git status --porcelain 2>/dev/null)" || [[ -n "$porcelain" ]]; then
        HAS_LOCAL_CHANGES=true
        log_debug "Local modifications detected"
    else
        HAS_LOCAL_CHANGES=false
        log_debug "No local modifications"
    fi

    return 0
}

################################################################################
# User Interaction Helpers
################################################################################

confirm_action() {
    local prompt="$1"
    local default="${2:-N}"
    local response

    if [[ "$default" == "Y" ]]; then
        if ! read -r -p "${prompt} [Y/n] " response; then
            # EOF - return false for safety
            echo
            return 1
        fi
        response="${response:-Y}"
    else
        if ! read -r -p "${prompt} [y/N] " response; then
            # EOF - return false for safety
            echo
            return 1
        fi
        response="${response:-N}"
    fi

    [[ "$response" =~ ^[Yy]$ ]]
}

# Require explicit "yes" confirmation for destructive operations
confirm_destructive_action() {
    local prompt="$1"
    local response

    if ! read -r -p "${prompt} " response; then
        # EOF - return false for safety
        echo
        return 1
    fi
    [[ "$response" == "yes" ]]
}

################################################################################
# Transaction Management
################################################################################

transaction_begin() {
    local operation="$1"
    local target="${2:-}"
    local target_head="${3:-}"
    local kind="${4:-update}"

    if [[ "${TRANSACTION_STATE[active]}" == "true" ]]; then
        log_error "Transaction already active: ${TRANSACTION_STATE[operation]}"
        return "$E_GENERAL"
    fi

    log_debug "Transaction begin: $operation"

    # Save current state
    TRANSACTION_STATE[active]=true
    TRANSACTION_STATE[kind]="$kind"
    TRANSACTION_STATE[operation]="$operation"
    TRANSACTION_STATE[target]="$target"
    TRANSACTION_STATE[target_head]="$target_head"
    TRANSACTION_STATE[head_changed]=false
    TRANSACTION_STATE[stash_hash]=""
    TRANSACTION_STATE[stash_message]=""
    TRANSACTION_STATE[service_was_running]=false
    TRANSACTION_STATE[recovering]=false
    TRANSACTION_STATE[note]=""
    TRANSACTION_STATE[started]="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    TRANSACTION_STATE[pid]="$$"
    TRANSACTION_STATE[original_head]="$(git rev-parse HEAD 2>/dev/null || echo "")"

    if ! git symbolic-ref -q HEAD >/dev/null 2>&1; then
        TRANSACTION_STATE[original_ref]="HEAD" # Detached
    else
        TRANSACTION_STATE[original_ref]="$(git rev-parse --abbrev-ref HEAD 2>/dev/null)"
    fi
    TRANSACTION_STATE[original_label]="$(commit_label "${TRANSACTION_STATE[original_head]}" "${TRANSACTION_STATE[original_ref]}")"

    # The journal is what lets the next run undo a half-finished update after
    # a kill or a power cut. Do not start changing anything that could not be
    # recovered.
    if ! journal_write begin; then
        log_error "Cannot write the transaction journal in $UPDATER_STATE_DIR (disk full or read-only?)"
        log_info "Nothing has been changed."
        transaction_reset_state
        return "$E_GENERAL"
    fi

    return 0
}

# Record how far the transaction has got. A journal that cannot be written
# here only means a crash would be diagnosed from an earlier phase (recovery
# also looks at git itself), so it is not fatal.
transaction_phase() {
    journal_write "$1" || log_debug "Could not write the transaction journal (phase $1)"
}

transaction_stash_changes() {
    if [[ "${TRANSACTION_STATE[active]}" != "true" ]]; then
        log_error "No active transaction"
        return "$E_GENERAL"
    fi

    log_debug "Creating transaction stash..."

    # Use nanoseconds + random for better uniqueness
    local stash_nonce
    stash_nonce="$(date +%s.%N 2>/dev/null || date +%s)-$$-$RANDOM"

    local stash_message
    stash_message="lyrebird-tx-${TRANSACTION_STATE[operation]}-${stash_nonce}"

    # Name the stash in the journal BEFORE creating it: if the updater is killed
    # in between, the next run can still find the stash by its message.
    TRANSACTION_STATE[stash_message]="$stash_message"
    if ! journal_write stashing; then
        log_error "Cannot write the transaction journal in $UPDATER_STATE_DIR (disk full or read-only?)"
        return "$E_GENERAL"
    fi

    # `git stash push` exits 0 without creating anything when there is nothing
    # to save, so refs/stash must be compared before and after: taking
    # `stash@{0}` blindly would adopt (and later pop) a stash the operator made
    # earlier.
    local stash_before="" stash_after="" stash_hash=""
    stash_before="$(git rev-parse --verify --quiet refs/stash 2>/dev/null || true)"

    if ! git stash push -u -m "$stash_message" >/dev/null 2>&1; then
        log_error "Failed to save your changes"
        return "$E_GENERAL"
    fi

    stash_after="$(git rev-parse --verify --quiet refs/stash 2>/dev/null || true)"
    if [[ -z "$stash_after" || "$stash_after" == "$stash_before" ]]; then
        log_debug "Nothing to stash (no stash entry was created)"
        TRANSACTION_STATE[stash_hash]=""
        transaction_phase stashed
        return 0
    fi
    stash_hash="$stash_after"

    TRANSACTION_STATE[stash_hash]="$stash_hash"
    log_debug "Transaction stash created: $stash_hash"
    transaction_phase stashed

    return 0
}

# Forget the transaction (nothing left to roll back)
transaction_reset_state() {
    TRANSACTION_STATE[active]=false
    TRANSACTION_STATE[kind]=""
    TRANSACTION_STATE[stash_hash]=""
    TRANSACTION_STATE[stash_message]=""
    TRANSACTION_STATE[original_ref]=""
    TRANSACTION_STATE[original_head]=""
    TRANSACTION_STATE[original_label]=""
    TRANSACTION_STATE[operation]=""
    TRANSACTION_STATE[target]=""
    TRANSACTION_STATE[target_head]=""
    TRANSACTION_STATE[head_changed]=false
    TRANSACTION_STATE[service_was_running]=false
    TRANSACTION_STATE[recovering]=false
    TRANSACTION_STATE[note]=""
    TRANSACTION_STATE[phase]=""
    TRANSACTION_STATE[started]=""
    TRANSACTION_STATE[pid]=""
}

# Label for the version the transaction was asked to go to
_transaction_target_label() {
    local target="${TRANSACTION_STATE[target]}" head="$1"
    if [[ -n "$target" ]] \
        && { git show-ref --verify --quiet "refs/tags/${target}" 2>/dev/null \
            || git show-ref --verify --quiet "refs/heads/${target}" 2>/dev/null; }; then
        printf '%s' "$target"
    else
        commit_label "$head" ""
    fi
}

transaction_commit() {
    if [[ "${TRANSACTION_STATE[active]}" != "true" ]]; then
        log_error "No active transaction"
        return "$E_GENERAL"
    fi

    log_debug "Transaction commit: ${TRANSACTION_STATE[operation]}"

    local to_head to_label
    to_head="$(git rev-parse HEAD 2>/dev/null || true)"
    to_label="$(_transaction_target_label "$to_head")"

    # The journal goes first: a kill between the two steps then loses one
    # history line instead of rolling back an update that had completed
    journal_clear
    history_record "${TRANSACTION_STATE[kind]}" ok \
        "${TRANSACTION_STATE[original_head]}" "${TRANSACTION_STATE[original_label]}" \
        "$to_head" "$to_label" "${TRANSACTION_STATE[note]}" || true

    transaction_reset_state

    return 0
}

# Hand the first half of a self-update to the re-exec'd updater. The journal
# (phase "handoff") stays: the new process completes the restore and records
# the result, or -- if it is killed -- the next run does.
transaction_handoff() {
    journal_write handoff || log_warn "Could not update the transaction journal before restarting"
    transaction_reset_state
}

# The transaction's stash may have been created without its hash being recorded
# yet: the updater was stopped (SIGTERM, SIGINT, or killed and recovered later)
# between `git stash push` and the next line. The stash message was written to
# the journal before the push, so the entry can still be found by it.
adopt_transaction_stash() {
    local found
    if [[ -z "${TRANSACTION_STATE[stash_hash]}" && -n "${TRANSACTION_STATE[stash_message]}" ]]; then
        found="$(git stash list --format='%H %gs' 2>/dev/null | awk -v m="${TRANSACTION_STATE[stash_message]}" 'index($0, m) {print $1; exit}')" || found=""
        TRANSACTION_STATE[stash_hash]="$found"
    fi
}

# After a checkout, confirm the files on disk are the target's. git can report
# success after a write error on a single file (it prints "unable to write
# file X", leaves X truncated and exits 0), so for every file the switch added
# or changed the content on disk is compared with the blob in the target tree.
# Prints the offending paths and returns 1 on any difference.
verify_checkout_integrity() {
    local from_head="$1" to_head="$2"
    local path expected actual bad=0
    while IFS= read -r -d '' path; do
        if [[ -L "$path" ]]; then
            continue # symlinks carry no content of their own to compare
        fi
        expected="$(git rev-parse --verify --quiet "${to_head}:${path}" 2>/dev/null || true)"
        if [[ ! -f "$path" ]]; then
            log_error "Missing after checkout: $path"
            bad=1
            continue
        fi
        actual="$(git hash-object -- "$path" 2>/dev/null || true)"
        if [[ -z "$expected" || "$actual" != "$expected" ]]; then
            log_error "Differs from the target version after checkout: $path"
            bad=1
        fi
    done < <(git diff --name-only -z --diff-filter=AM "$from_head" "$to_head" 2>/dev/null || true)
    [[ "$bad" -eq 0 ]]
}

# Print the stash reference (stash@{n}) of the stash commit HASH, if it is still in the list
find_stash_ref() {
    local hash="$1"
    git stash list --format="%gd %H" 2>/dev/null | awk -v h="$hash" '$2 == h {print $1; exit}' || true
}

# Tell the operator where their changes are and how to get them back
report_kept_stash() {
    local ref="$1"
    log_warn "Your saved changes could not be re-applied to this version and were NOT lost:"
    log_info "  They are kept in:   $ref"
    log_info "  To look at them:    git stash show -p $ref"
    log_info "  To re-apply:        git stash apply $ref   (resolve any conflicts, then: git stash drop $ref)"
}

# After a failed `git stash pop` the working tree holds conflict markers and
# possibly part of the stash. Called only when the tree was clean before the
# pop, so everything modified or untracked now came from the failed pop:
# discard it and leave the clean version the operator switched to.
abandon_failed_stash_apply() {
    local ref="$1"
    local path
    git_worktree reset --hard HEAD >/dev/null 2>&1 || true
    # Untracked files stored in the stash (its third parent) that the failed
    # apply may already have restored. A path that is tracked in HEAD is the
    # version's own file (the stash held an untracked file of the same name): keep it.
    if git rev-parse --verify --quiet "${ref}^3" >/dev/null 2>&1; then
        while IFS= read -r -d '' path; do
            [[ -e "$path" || -L "$path" ]] || continue
            if git ls-files --error-unmatch -- "$path" >/dev/null 2>&1; then
                continue
            fi
            rm -f -- "$path" 2>/dev/null || true
        done < <(git ls-tree -r -z --name-only "${ref}^3" 2>/dev/null || true)
    fi
}

# Re-apply the transaction stash HASH onto the working tree.
#   0                   restored; the stash entry is dropped
#   1                   the stash entry is gone, nothing to restore
#   E_RESTORE_CONFLICT  conflicts: the working tree is left clean (the version
#                       that was switched to) and the changes stay in the stash
# `git stash pop` on conflicts leaves markers in tracked files and exits
# non-zero; the old code then reported success, so the markers could end up in
# a script the service runs.
restore_saved_changes() {
    local hash="$1" ref clean_before=false
    ref="$(find_stash_ref "$hash")"
    if [[ -z "$ref" ]]; then
        log_warn "Could not find your saved changes (stash $hash)"
        return 1
    fi

    if [[ -z "$(git status --porcelain 2>/dev/null || echo unknown)" ]]; then
        clean_before=true
    fi

    if git_worktree stash pop "$ref" >/dev/null 2>&1; then
        return 0
    fi

    if [[ "$clean_before" == "true" ]]; then
        abandon_failed_stash_apply "$ref"
    else
        log_warn "The working tree was not clean, so the partial result is left in place for you to inspect"
    fi
    report_kept_stash "$ref"
    return "$E_RESTORE_CONFLICT"
}

# Delete files the failed switch added to the working tree: present in the
# target version, absent from the original one, and untracked once HEAD is
# back. (`git checkout` of the original version does not remove them.)
remove_target_leftovers() {
    local orig_head="${TRANSACTION_STATE[original_head]}"
    local target_head="${TRANSACTION_STATE[target_head]}"
    local leftover
    [[ -n "$target_head" && "$target_head" != "$orig_head" ]] || return 0
    while IFS= read -r -d '' leftover; do
        [[ -e "$leftover" || -L "$leftover" ]] || continue
        if git ls-files --error-unmatch -- "$leftover" >/dev/null 2>&1; then
            continue
        fi
        rm -f -- "$leftover" 2>/dev/null || true
    done < <(git diff --name-only -z --diff-filter=A "$orig_head" "$target_head" 2>/dev/null || true)
}

# Put HEAD and the working tree back where the transaction started.
# Returns 0 when they are there, 1 when they could not be restored.
#
# A forced checkout discards uncommitted changes, so it is only done when this
# transaction actually moved HEAD (head_changed): by then the operator's
# changes are in the transaction stash. Before that -- the operator declined to
# stash, or the stash failed -- the tree still holds their work and is not
# touched.
#
# When recovering from a crash (the updater was killed, then run again) the
# working tree may also hold edits made after the crash, which cannot be told
# from what the interrupted checkout left behind: anything uncommitted is first
# saved in a recovery stash instead of being discarded.
restore_original_head() {
    local orig_ref="${TRANSACTION_STATE[original_ref]}"
    local orig_head="${TRANSACTION_STATE[original_head]}"
    local cur_head=""

    # Empty repository: there is no commit to return to
    [[ -n "$orig_head" ]] || return 0

    cur_head="$(git rev-parse HEAD 2>/dev/null || true)"
    if [[ "${TRANSACTION_STATE[head_changed]}" != "true" && "$cur_head" == "$orig_head" ]]; then
        log_debug "HEAD never moved; leaving the working tree alone"
        return 0
    fi

    if [[ "${TRANSACTION_STATE[recovering]}" == "true" ]] \
        && [[ -n "$(git status --porcelain 2>/dev/null || echo unknown)" ]]; then
        local safety_message safety_before safety_after
        safety_message="lyrebird-recovery-$(date +%s)-$$"
        safety_before="$(git rev-parse --verify --quiet refs/stash 2>/dev/null || true)"
        if ! git stash push -u -m "$safety_message" >/dev/null 2>&1; then
            log_error "The working tree has uncommitted differences and they could not be saved first"
            return 1
        fi
        safety_after="$(git rev-parse --verify --quiet refs/stash 2>/dev/null || true)"
        if [[ "$safety_after" != "$safety_before" ]]; then
            log_warn "Uncommitted differences in the working tree were saved first, in the stash entry named: $safety_message"
            log_info "They are what the interrupted update left behind, plus any edit made since;"
            log_info "inspect with: git stash list   /   git stash show -p <entry>"
        fi
    fi

    log_debug "Restoring original position: ${orig_ref} @ ${orig_head}"
    # First delete what the failed switch added: on a full disk those partially
    # written files occupy the space the restore needs.
    remove_target_leftovers
    if [[ "$orig_ref" != "HEAD" ]]; then
        # Started on a branch: back on it, and back to where its tip was
        # (fast_forward_branch_to_origin may have advanced the branch)
        git_worktree checkout --force "$orig_ref" >/dev/null 2>&1 || return 1
        if [[ "$(git rev-parse HEAD 2>/dev/null || true)" != "$orig_head" ]]; then
            git_worktree reset --hard "$orig_head" >/dev/null 2>&1 || return 1
        fi
    else
        # Started on a tag or commit (detached HEAD): `git checkout HEAD` would
        # re-check-out the version we are trying to leave
        git_worktree checkout --force --detach "$orig_head" >/dev/null 2>&1 || return 1
    fi

    [[ "$(git rev-parse HEAD 2>/dev/null || true)" == "$orig_head" ]]
}

# Usage: transaction_rollback [REASON] [quiet]
# quiet: do not record the rollback in the history (the operator cancelled)
transaction_rollback() {
    local reason="${1:-failed}" quiet="${2:-}"

    if [[ "${TRANSACTION_STATE[active]}" != "true" ]]; then
        log_debug "No active transaction to rollback"
        return 0
    fi

    log_warn "Rolling back: ${TRANSACTION_STATE[operation]} (${reason})"

    # The rollback must run to completion: a second Ctrl-C or SIGTERM in the
    # middle of it would leave the repository between the two versions.
    trap - EXIT
    trap '' INT TERM

    local rollback_ok=true
    local head_restored=true

    if ! restore_original_head; then
        log_error "Could not restore the original version"
        log_info "To return by hand: git checkout --force ${TRANSACTION_STATE[original_head]}"
        rollback_ok=false
        head_restored=false
    else
        set_script_permissions
    fi

    # Restore stashed changes if any -- only onto the original version again
    adopt_transaction_stash
    if [[ -n "${TRANSACTION_STATE[stash_hash]}" ]]; then
        log_debug "Restoring saved changes: ${TRANSACTION_STATE[stash_hash]}"

        local stash_ref
        stash_ref="$(find_stash_ref "${TRANSACTION_STATE[stash_hash]}")"

        if [[ -z "$stash_ref" ]]; then
            log_warn "Could not find your saved changes"
        elif [[ "$head_restored" != "true" ]]; then
            log_warn "Your changes are saved in: $stash_ref"
            log_info "Once the version is back: git stash pop $stash_ref"
        elif restore_saved_changes "${TRANSACTION_STATE[stash_hash]}"; then
            log_success "Your changes were restored"
        else
            TRANSACTION_STATE[note]="saved changes kept in the stash"
        fi
    fi

    # Restore service files if update was in progress
    if [[ -f "$SERVICE_UPDATE_MARKER" ]]; then
        log_warn "Rolling back service update..."
        if load_service_state_from_marker; then
            restore_service_from_backup

            # Reload systemd and attempt to restart service
            if [[ "${SERVICE_STATE[was_running]}" == "true" ]]; then
                systemctl daemon-reload 2>/dev/null || true
                systemctl start "$SERVICE_NAME" 2>/dev/null || {
                    log_warn "Could not restart service after rollback"
                    log_info "Manual intervention may be required"
                    log_info "Check: systemctl status $SERVICE_NAME"
                }
            fi

            cleanup_service_backups
        fi
        rm -f "$SERVICE_UPDATE_MARKER"
    elif [[ "${TRANSACTION_STATE[service_was_running]}" == "true" ]] \
        && [[ "${TRANSACTION_STATE[recovering]}" == "true" ]] \
        && type -P systemctl >/dev/null 2>&1 \
        && ! systemctl is-active --quiet "$SERVICE_NAME" 2>/dev/null; then
        # recovering after the marker is gone (reboot): the service was running
        # when the update began and is not now
        log_info "Starting $SERVICE_NAME again (it was running when the update began)..."
        systemctl start "$SERVICE_NAME" 2>/dev/null || log_warn "Could not start $SERVICE_NAME: systemctl status $SERVICE_NAME"
    fi

    # Record the outcome, then forget the transaction. The journal survives a
    # rollback that could not finish, so the next run tries again.
    local result="failed"
    if [[ "${TRANSACTION_STATE[recovering]}" == "true" ]]; then
        result="interrupted"
    elif [[ "${TRANSACTION_STATE[head_changed]}" == "true" ]]; then
        result="rolled-back"
    fi
    local note="$reason"
    if [[ "$rollback_ok" != "true" ]]; then
        note="$reason; rollback incomplete"
    elif [[ -n "${TRANSACTION_STATE[note]}" ]]; then
        note="$reason; ${TRANSACTION_STATE[note]}"
    fi
    if [[ "$rollback_ok" == "true" ]]; then
        journal_clear
    else
        transaction_phase rollback-failed
    fi
    if [[ "$quiet" != "quiet" ]]; then
        history_record "${TRANSACTION_STATE[kind]:-update}" "$result" \
            "${TRANSACTION_STATE[original_head]}" "${TRANSACTION_STATE[original_label]}" \
            "${TRANSACTION_STATE[target_head]}" "${TRANSACTION_STATE[target]}" "$note" || true
    fi

    # Clear transaction state
    transaction_reset_state

    # Restore traps (direct re-installation avoids eval of arbitrary strings)
    install_signal_traps

    if [[ "$rollback_ok" == "true" ]]; then
        log_warn "Rollback complete"
        return 0
    fi
    log_error "Rollback incomplete: the repository may be between versions"
    return 1
}

# Roll back and return CODE (the reason the transaction failed), or
# E_ROLLBACK_FAILED when the rollback itself could not restore everything.
# A third argument "quiet" keeps it out of the history (the operator cancelled).
# Use as: transaction_abort "why" "$E_GENERAL" || return $?
transaction_abort() {
    local reason="$1" code="$2" quiet="${3:-}"
    transaction_rollback "$reason" "$quiet" || return "$E_ROLLBACK_FAILED"
    return "$code"
}

################################################################################
# Recovery from an interrupted run, and the update history
################################################################################

# Read-only: say whether an earlier run left a transaction behind.
# Returns 0 (and says so) when one is there, 1 when not.
report_interrupted_transaction() {
    local rc=0
    journal_load || rc=$?
    if [[ $rc -eq 1 ]]; then
        return 1
    fi
    if [[ $rc -eq 2 ]]; then
        log_warn "The transaction journal exists but cannot be read: $JOURNAL_FILE"
        log_info "Check 'git status' and 'git stash list', then remove that file."
        return 0
    fi
    log_warn "An earlier $(journal_summary) did not finish."
    log_info "Run ${SCRIPT_NAME} without arguments to recover; nothing is changed until you do."
    return 0
}

# A self-update whose first half ran in the previous updater process: take the
# transaction over from the journal so the service update that follows knows
# which version it came from.
handoff_load_journal() {
    if journal_load && [[ "${JOURNAL[phase]}" == "handoff" ]]; then
        TRANSACTION_STATE[original_head]="${JOURNAL[original_head]:-}"
        return 0
    fi
    return 1
}

# Close the journal of a handed-over self-update and record the result.
# Usage: handoff_finish [NOTE]
handoff_finish() {
    local note="${1:-}" to_head
    to_head="$(git rev-parse HEAD 2>/dev/null || true)"
    if journal_load && [[ "${JOURNAL[phase]}" == "handoff" ]]; then
        journal_clear
        history_record "${JOURNAL[kind]:-update}" ok "${JOURNAL[original_head]:-}" "${JOURNAL[original_label]:-(unknown)}" \
            "$to_head" "${JOURNAL[target]:-$(commit_label "$to_head" "")}" "$note" || true
    elif [[ ! -e "$JOURNAL_FILE" ]]; then
        # started by an updater that kept no journal
        history_record update ok "" "(unknown)" "$to_head" "$(commit_label "$to_head" "")" \
            "self-update started by an older updater${note:+; $note}" || true
    fi
    TRANSACTION_STATE[original_head]=""
}

# The first half of a self-update ran and the new updater never finished it
# (killed, or the machine lost power). The checkout was verified and the new
# updater syntax-checked, so this rolls forward: re-apply the saved changes and
# complete the service update.
recover_handoff() {
    local stash_hash="${JOURNAL[stash_hash]:-}" restore_status=0 note=""
    local head
    head="$(git rev-parse HEAD 2>/dev/null || true)"

    if [[ -n "${JOURNAL[target_head]:-}" && "$head" != "${JOURNAL[target_head]}" ]]; then
        log_warn "HEAD is no longer at the version that update switched to; leaving it where it is"
    fi

    if [[ -n "$stash_hash" ]] && [[ -n "$(find_stash_ref "$stash_hash")" ]]; then
        log_step "Restoring your saved changes..."
        restore_saved_changes "$stash_hash" || restore_status=$?
        if [[ $restore_status -eq 0 ]]; then
            log_success "Changes restored successfully"
        elif [[ $restore_status -eq $E_RESTORE_CONFLICT ]]; then
            note="saved changes kept in the stash"
            EXIT_STATUS="$E_RESTORE_CONFLICT"
        fi
    fi

    TRANSACTION_STATE[original_head]="${JOURNAL[original_head]:-}"
    if check_pending_service_update; then
        complete_pending_service_update || log_error "Service update completion failed; check: systemctl status $SERVICE_NAME"
    fi

    handoff_finish "completed after an interruption${note:+; $note}"
    log_success "The interrupted self-update was completed."
    return 0
}

# Undo an update that an earlier run left half done. The journal tells what
# the transaction was; git decides how far it got. Returns 0 when nothing was
# pending or it was rolled back, E_ROLLBACK_FAILED / E_BAD_STATE when not.
recover_interrupted_transaction() {
    local rc=0 key
    journal_load || rc=$?
    if [[ $rc -eq 1 ]]; then
        return 0
    fi
    if [[ $rc -eq 2 ]]; then
        log_error "The transaction journal exists but cannot be read: $JOURNAL_FILE"
        log_info "Check 'git status' and 'git stash list', then remove that file to continue."
        return "$E_BAD_STATE"
    fi

    echo
    log_warn "An earlier $(journal_summary)."
    log_info "The updater was stopped before it finished (killed, crashed or powered off)."

    if [[ "${JOURNAL[phase]}" == "handoff" ]]; then
        recover_handoff
        return $?
    fi

    # Take the journal over as the active transaction and roll it back
    for key in kind operation target target_head original_ref original_head original_label \
        stash_hash stash_message head_changed service_was_running started pid; do
        TRANSACTION_STATE[$key]="${JOURNAL[$key]:-}"
    done
    TRANSACTION_STATE[active]=true
    TRANSACTION_STATE[recovering]=true
    TRANSACTION_STATE[note]=""
    if [[ "$(git rev-parse HEAD 2>/dev/null || true)" != "${JOURNAL[original_head]:-}" ]]; then
        TRANSACTION_STATE[head_changed]=true
    fi
    # (a stash created but not recorded before the kill is found by its message in transaction_rollback)
    if transaction_rollback "interrupted run recovered at phase ${JOURNAL[phase]}"; then
        log_success "The interrupted ${JOURNAL[kind]:-update} was rolled back."
        return 0
    fi
    log_error "Recovery could not finish; see the messages above."
    return "$E_ROLLBACK_FAILED"
}

# Show the update history (the log is local: no network, no git needed)
readonly HISTORY_SHOW_LIMIT=50
show_history() {
    local ts kind result from_commit from_label to_commit to_label note
    local skipped=0 total=0

    echo
    echo "${BOLD}=== Update History ===${NC}"
    echo "  Log: $HISTORY_FILE"
    echo

    if [[ ! -s "$HISTORY_FILE" ]]; then
        echo "  No updates recorded yet."
    else
        total="$(wc -l <"$HISTORY_FILE" | tr -d '[:space:]')"
        printf '  %-20s  %-8s  %-11s  %-22s  %-22s  %s\n' "WHEN (UTC)" "KIND" "RESULT" "FROM" "TO" "NOTE"
        while IFS=$'\t' read -r ts kind result from_commit from_label to_commit to_label note || [[ -n "$ts" ]]; do
            if [[ -z "$ts" || -z "$kind" || -z "$result" ]]; then
                skipped=$((skipped + 1))
                continue
            fi
            printf '  %-20s  %-8s  %-11s  %-22s  %-22s  %s\n' "${ts/T/ }" "$kind" "$result" \
                "${from_label:-?} (${from_commit:0:7})" "${to_label:-?} (${to_commit:0:7})" "$note"
        done < <(tail -n "$HISTORY_SHOW_LIMIT" "$HISTORY_FILE")
        if [[ $total -gt $HISTORY_SHOW_LIMIT ]]; then
            echo
            echo "  (newest ${HISTORY_SHOW_LIMIT} of ${total} records; the full log is the file above)"
        fi
        if [[ $skipped -gt 0 ]]; then
            echo "  ($skipped unreadable line(s) skipped)"
        fi
    fi

    local rc=0
    journal_load || rc=$?
    if [[ $rc -eq 0 ]]; then
        echo
        echo "  ${YELLOW}Not finished:${NC} $(journal_summary)"
        echo "  Run ${SCRIPT_NAME} without arguments to recover."
    elif [[ $rc -eq 2 ]]; then
        echo
        echo "  ${YELLOW}Not finished:${NC} an update left an unreadable journal: $JOURNAL_FILE"
    fi
    echo
}

################################################################################
# Git Operations with Validation
################################################################################

fetch_updates_safe() {
    log_step "Checking for updates from GitHub..."

    local attempt=1
    local fetch_output
    local fetch_succeeded=false

    while [[ $attempt -le $FETCH_RETRIES ]]; do
        if [[ $attempt -gt 1 ]]; then
            log_info "Retry attempt $attempt of $FETCH_RETRIES (waiting ${FETCH_RETRY_DELAY}s...)"
            sleep "$FETCH_RETRY_DELAY"
        fi

        # Try fetch with timeout if available (the low-speed limits also bound a
        # stalled http transfer where there is no timeout command)
        if command -v timeout >/dev/null 2>&1; then
            if fetch_output=$(GIT_HTTP_LOW_SPEED_LIMIT=1000 GIT_HTTP_LOW_SPEED_TIME="$FETCH_TIMEOUT" \
                run_unlocked timeout "$FETCH_TIMEOUT" git fetch --all --tags --prune 2>&1); then
                fetch_succeeded=true
                break
            fi
        else
            # No timeout command, try without it
            if fetch_output=$(GIT_HTTP_LOW_SPEED_LIMIT=1000 GIT_HTTP_LOW_SPEED_TIME="$FETCH_TIMEOUT" \
                git fetch --all --tags --prune 2>&1); then
                fetch_succeeded=true
                break
            fi
        fi

        log_debug "Fetch attempt $attempt failed"
        attempt=$((attempt + 1))
    done

    if [[ "$fetch_succeeded" != "true" ]]; then
        log_error "Failed to fetch updates after $FETCH_RETRIES attempts"
        log_error "Please check your internet connection"
        # what git said (its first line: "Could not resolve host", "timed out", ...)
        log_info "git said: ${fetch_output%%$'\n'*}"
        return "$E_NO_REMOTE"
    fi

    # Update remote HEAD reference (this asks the remote again: bounded too)
    if command -v timeout >/dev/null 2>&1; then
        run_unlocked timeout "$FETCH_TIMEOUT" git remote set-head origin --auto >/dev/null 2>&1 || true
    else
        git remote set-head origin --auto >/dev/null 2>&1 || true
    fi

    log_success "Updates fetched successfully"
    return 0
}

validate_version_exists() {
    local version="$1"

    if [[ -z "$version" ]]; then
        return 1
    fi

    log_debug "Validating version: $version"

    # Check various ref types
    if git rev-parse --verify --quiet "refs/tags/$version" >/dev/null 2>&1; then
        log_debug "Found as tag: $version"
        return 0
    elif git rev-parse --verify --quiet "refs/heads/$version" >/dev/null 2>&1; then
        log_debug "Found as local branch: $version"
        return 0
    elif git rev-parse --verify --quiet "refs/remotes/origin/$version" >/dev/null 2>&1; then
        log_debug "Found as remote branch: $version"
        return 0
    elif git rev-parse --verify --quiet "$version^{commit}" >/dev/null 2>&1; then
        log_debug "Found as commit: $version"
        return 0
    fi

    log_debug "Version not found: $version"
    return 1
}

# If TARGET is a local branch that also exists on origin, fast-forward it to
# origin/TARGET. `git fetch` advances only refs/remotes/origin/*, so after a
# plain `git checkout <branch>` the working tree sits on the STALE local tip;
# this brings it up to the fetched remote. Returns 0 when the branch is
# fast-forwarded OR when TARGET is not a fast-forwardable branch (a tag/commit —
# nothing to do). Returns 1 ONLY when TARGET is a branch that has DIVERGED from
# origin (local commits the caller must be told about, not silently ignored).
fast_forward_branch_to_origin() {
    local target="$1"
    # Not a local branch (tag/commit/detached target) -> nothing to fast-forward.
    git show-ref --verify --quiet "refs/heads/${target}" || return 0
    # No remote-tracking counterpart -> local-only branch, leave as-is.
    git show-ref --verify --quiet "refs/remotes/origin/${target}" || return 0
    git_worktree merge --ff-only "origin/${target}" >/dev/null 2>&1
}

# True when the updater script at COMMIT can resume after a self-update re-exec
# (it understands --post-update-restore / --post-update-complete). Releases
# before 1.5 do not: re-exec'ing into one strands the stash and the service.
updater_supports_handoff() {
    local commit="$1" content
    content="$(git show "${commit}:${SCRIPT_NAME}" 2>/dev/null)" || return 1
    [[ "$content" == *"--post-update-restore"* && "$content" == *"--post-update-complete"* ]]
}

# Usage: switch_version_safe TARGET [KIND]   (KIND: update | rollback, for the journal and history)
switch_version_safe() {
    local target_version="$1"
    local kind="${2:-update}"

    if [[ -z "$target_version" ]]; then
        log_error "No version specified"
        return "$E_GENERAL"
    fi

    # Validate we're in a clean state for the operation
    if ! validate_clean_state; then
        return "$E_BAD_STATE"
    fi

    # Validate target exists
    if ! validate_version_exists "$target_version"; then
        log_error "Version '$target_version' does not exist"
        log_info "Try running 'Check for Updates' first (option 4)"
        return "$E_GENERAL"
    fi

    # Get current state
    get_current_version

    # Check if already on this version
    if [[ "$CURRENT_VERSION" == "$target_version" ]]; then
        log_info "Already on version: $target_version"
        return 0
    fi

    # Begin transaction
    local target_head
    target_head="$(git rev-parse --verify --quiet "${target_version}^{commit}" 2>/dev/null || true)"
    if ! transaction_begin "switch to $target_version" "$target_version" "$target_head" "$kind"; then
        return "$E_GENERAL"
    fi

    # Handle local changes
    check_local_changes
    if [[ "$HAS_LOCAL_CHANGES" == "true" ]]; then
        echo
        log_warn "You have local modifications"
        echo
        git status --short 2>/dev/null | head -n 15

        local total_changes
        total_changes=$(git status --short 2>/dev/null | wc -l)
        if [[ "$total_changes" -gt 15 ]]; then
            echo "  ... and $((total_changes - 15)) more files"
        fi
        echo

        log_info "Your changes must be saved before switching versions"
        echo
        if ! confirm_action "Save your changes temporarily? (recommended)"; then
            log_info "Operation cancelled"
            transaction_abort "cancelled by the operator" "$E_USER_ABORT" quiet || return $?
        fi

        if ! transaction_stash_changes; then
            transaction_abort "could not save local changes" "$E_GENERAL" || return $?
        fi

        log_success "Your changes have been saved and will be restored after the update"
    fi

    # Handle systemd service update (pre-checkout)
    local service_update_result=0
    handle_systemd_service_update "$target_version" || service_update_result=$?
    if [[ $service_update_result -eq 0 ]]; then
        log_debug "Service update preparation successful"
        if [[ "${SERVICE_STATE[installed]}" == "true" ]]; then
            TRANSACTION_STATE[service_was_running]="${SERVICE_STATE[was_running]}"
            transaction_phase service-prepared
        fi
    else
        if [[ $service_update_result -eq $E_USER_ABORT ]]; then
            log_info "Operation cancelled by user during service update"
            transaction_abort "cancelled during service update" "$E_USER_ABORT" quiet || return $?
        else
            log_error "Service update preparation failed"
            transaction_abort "service update preparation failed" "$E_GENERAL" || return $?
        fi
    fi

    # Check if script itself will be modified (self-update)
    local script_will_change=false
    if ! git diff --quiet HEAD "$target_version" -- "$SCRIPT_NAME" 2>/dev/null; then
        if updater_supports_handoff "${TRANSACTION_STATE[target_head]}"; then
            script_will_change=true
            log_info "The updater script itself will be updated"
            log_info "The process will restart automatically after the update"
            echo
            sleep 2
        else
            # Re-exec'ing into an updater that does not know --post-update-* would
            # strand the saved changes and the stopped service: finish here with
            # the copy already loaded (git replaces the file; this process keeps
            # reading the old one).
            log_warn "The updater in $target_version is older and cannot resume an update"
            log_info "Finishing this update with the current updater; start it again afterwards"
        fi
    fi

    # Perform the checkout
    log_step "Switching to version: $target_version"

    # Verify write permissions to working directory before checkout
    local repo_root
    repo_root="$(git rev-parse --show-toplevel 2>/dev/null)"
    if [[ -z "$repo_root" ]]; then
        log_error "Could not determine repository root"
        transaction_abort "repository root unknown" "$E_GENERAL" || return $?
    fi

    if [[ ! -w "$repo_root" ]]; then
        log_error "No write permission for working directory: $repo_root"
        log_info "To fix: sudo chown -R $USER:$USER $repo_root"
        transaction_abort "working directory not writable" "$E_PERMISSION" || return $?
    fi

    # From here on HEAD and the working tree may change: a rollback must put
    # them back (and may then discard whatever the failed checkout left behind).
    # This phase is written to the journal before git is allowed to touch the tree.
    TRANSACTION_STATE[head_changed]=true
    if ! journal_write checkout; then
        log_error "Cannot write the transaction journal in $UPDATER_STATE_DIR (disk full or read-only?)"
        transaction_abort "transaction journal not writable" "$E_GENERAL" || return $?
    fi

    local checkout_output
    if ! checkout_output=$(git_worktree checkout "$target_version" 2>&1); then
        log_error "Failed to switch to version: $target_version"
        echo "$checkout_output" >&2
        transaction_abort "checkout failed" "$E_GENERAL" || return $?
    fi

    # Fast-forward a branch target to origin (a plain checkout lands on the stale
    # local tip). Without this, "Switch to Development / Latest" no-ops while
    # reporting success and the box stays N commits behind forever.
    if ! fast_forward_branch_to_origin "$target_version"; then
        log_error "Cannot fast-forward ${target_version} to origin/${target_version}: local history has diverged"
        log_info "To discard local commits and match the remote exactly, use the reset option in the menu."
        transaction_abort "local branch has diverged from origin" "$E_GENERAL" || return $?
    fi

    # Verify we actually switched to the target
    local new_head
    new_head="$(git rev-parse HEAD 2>/dev/null)"
    local target_head
    target_head="$(git rev-parse "$target_version" 2>/dev/null)"

    if [[ "$new_head" != "$target_head" ]]; then
        log_error "Checkout completed but HEAD does not match target"
        log_error "This indicates a git state inconsistency"
        transaction_abort "HEAD does not match the target after checkout" "$E_GENERAL" || return $?
    fi

    if ! verify_checkout_integrity "${TRANSACTION_STATE[original_head]}" "$new_head"; then
        log_error "The files on disk do not match version $target_version (disk full or a write error?)"
        transaction_abort "files on disk differ from the target after checkout" "$E_GENERAL" || return $?
    fi

    transaction_phase checked-out
    log_success "Switched to version: $target_version"

    # Set executable permissions on known scripts
    set_script_permissions

    # Handle self-update scenario
    if [[ "$script_will_change" == "true" ]]; then
        log_info "Restarting with updated version..."

        # Compute absolute path for robustness
        local script_path
        if command -v realpath >/dev/null 2>&1; then
            script_path="$(realpath "$SCRIPT_NAME" 2>/dev/null)"
        elif command -v readlink >/dev/null 2>&1; then
            script_path="$(readlink -f "$SCRIPT_NAME" 2>/dev/null)"
        else
            # Fallback to constructing absolute path
            script_path="${SCRIPT_DIR}/${SCRIPT_NAME}"
        fi

        # Ensure script is executable
        if [[ ! -x "$script_path" ]]; then
            if ! chmod +x "$script_path" 2>/dev/null; then
                log_error "Failed to make new script executable: $script_path"
                log_error "Self-update cannot proceed"
                transaction_abort "new updater is not executable" "$E_PERMISSION" || return $?
            fi
        fi

        # CRITICAL: Validate syntax before committing transaction
        log_debug "Validating new script syntax..."
        if ! bash -n "$script_path" 2>/dev/null; then
            log_error "New script has syntax errors!"
            log_error "Cannot safely restart with broken script"
            echo >&2
            log_error "Syntax validation errors:"
            bash -n "$script_path" 2>&1 | head -10 | sed 's/^/  /' >&2
            echo >&2
            log_error "Rolling back to previous version..."
            transaction_abort "new updater has syntax errors" "$E_GENERAL" || return $?
        fi
        log_debug "Syntax validation passed [OK]"

        # Prepare restart arguments
        local restart_args=()
        if [[ -n "${TRANSACTION_STATE[stash_hash]}" ]]; then
            restart_args=("--post-update-restore" "${TRANSACTION_STATE[stash_hash]}")
        else
            restart_args=("--post-update-complete")
        fi
        # --rollback is a command, not a menu session: the re-exec'd updater
        # must finish it and exit, not open the interactive menu on stdin
        if [[ "$kind" == "rollback" ]]; then
            restart_args+=("--no-menu")
        fi

        # NOW safe to hand the transaction over (syntax validated). The journal
        # stays, phase "handoff", until the new process has restored the saved
        # changes and recorded the result.
        transaction_handoff

        # Service update marker remains for post-exec completion
        # No need to cleanup - new script will handle it

        # exec skips the EXIT trap, so put core.fileMode back here; the new
        # process saves and sets it again. (Left out, the new process saved the
        # temporary "false" as the operator's own value and kept it for good.)
        restore_git_config

        # Release our lock BEFORE exec. exec keeps the process, and with it the
        # open lock descriptor, and does NOT fire the EXIT trap. The new image
        # would then wait LOCK_MAX_WAIT for a lock that its own inherited
        # descriptor holds and abort with E_LOCKED, which made every self-update
        # fail (and orphaned the stash and the service-update marker).
        release_lock

        # Replace this process with the new script
        # shellcheck disable=SC2093  # exec is intentional here for self-update
        exec "$script_path" "${restart_args[@]}"

        # This line only reached if exec fails (kernel-level failure)
        log_error "Failed to restart with new version (exec failed)"
        log_error "This is a critical error - manual intervention required"
        log_error "The new version is checked out but not running"
        log_error "Try running manually: $script_path"
        exit "$E_GENERAL"
    fi

    # Complete service update (post-checkout)
    if ! post_checkout_service_update; then
        log_error "Service update failed after checkout"
        transaction_abort "service update failed after checkout" "$E_GENERAL" || return $?
    fi

    # Remove service update marker on success
    rm -f "$SERVICE_UPDATE_MARKER"

    # Run post-update migrations (handles breaking changes like renames)
    run_post_update_migrations

    # Restore stashed changes (if not self-updating)
    local restore_status=0
    if [[ -n "${TRANSACTION_STATE[stash_hash]}" ]]; then
        echo
        log_step "Restoring your saved changes..."
        restore_saved_changes "${TRANSACTION_STATE[stash_hash]}" || restore_status=$?
        if [[ $restore_status -eq 0 ]]; then
            log_success "Changes restored successfully"
        elif [[ $restore_status -ne $E_RESTORE_CONFLICT ]]; then
            log_info "Your changes may have been lost (stash hash: ${TRANSACTION_STATE[stash_hash]})"
            restore_status=0
        fi
    fi

    # Commit transaction
    if [[ $restore_status -eq $E_RESTORE_CONFLICT ]]; then
        TRANSACTION_STATE[note]="saved changes kept in the stash"
    fi
    transaction_commit

    # Update state
    get_current_version
    check_local_changes

    echo
    if [[ $restore_status -eq $E_RESTORE_CONFLICT ]]; then
        log_warn "Version switch complete, but your saved changes were NOT re-applied (see above)"
        return "$E_RESTORE_CONFLICT"
    fi
    log_success "Version switch complete!"

    return 0
}

reset_to_clean_state() {
    local target="$1"

    if [[ -z "$target" ]]; then
        log_error "No target specified for reset"
        return "$E_GENERAL"
    fi

    # Validate we're not in a bad state
    if ! validate_clean_state; then
        return "$E_BAD_STATE"
    fi

    # Validate target exists
    if ! git rev-parse --verify --quiet "$target" >/dev/null 2>&1; then
        log_error "Target '$target' does not exist"
        return "$E_GENERAL"
    fi

    # Show what will be deleted before confirmation
    echo
    log_warn "WARNING: This action CANNOT be undone!"
    echo
    log_warn "The following changes will be PERMANENTLY deleted:"
    echo
    git status --short 2>/dev/null || echo "  (no changes)"
    echo
    log_warn "Reset target: $target"
    echo

    # Require explicit "yes" confirmation
    if ! confirm_destructive_action "Type 'yes' (case-sensitive) to confirm reset, or anything else to cancel: "; then
        log_info "Reset cancelled"
        return 0
    fi

    log_step "Resetting to clean state: $target"

    # A reset changes the installed version like an update does: it goes into the
    # history (and --rollback can return to where it started)
    local from_head from_label reset_note=""
    from_head="$(git rev-parse HEAD 2>/dev/null || true)"
    from_label="$(commit_label "$from_head" "$(git symbolic-ref -q --short HEAD 2>/dev/null || true)")"
    if [[ -n "$(git status --porcelain 2>/dev/null || true)" ]]; then
        reset_note="uncommitted changes discarded"
    fi

    # Perform reset
    if ! git_worktree reset --hard "$target" >/dev/null 2>&1; then
        log_error "Failed to reset to $target"
        history_record reset failed "$from_head" "$from_label" "$from_head" "$target" "git reset failed" || true
        return "$E_GENERAL"
    fi

    # Clean untracked files
    if ! git clean -fd >/dev/null 2>&1; then
        log_warn "Could not remove all untracked files"
    fi

    log_success "Reset complete. Your changes are gone. Repository is clean."
    history_record reset ok "$from_head" "$from_label" "$(git rev-parse HEAD 2>/dev/null || true)" "$target" "$reset_note" || true

    # Set script permissions
    set_script_permissions

    # Update state
    get_current_version
    check_local_changes

    return 0
}

set_script_permissions() {
    log_debug "Setting executable permissions on scripts..."

    # The known scripts plus every shell script the repository tracks. git
    # writes a changed file with the mode recorded in the repository (644 for
    # most of the scripts) and core.fileMode is off while the updater runs, so
    # after a switch or a rollback whatever is not marked here is no longer
    # executable -- the diagnostics and mic-check scripts were not on the old
    # list of five.
    local -a scripts=(
        "install_mediamtx.sh"
        "lyrebird-orchestrator.sh"
        "lyrebird-updater.sh"
        "lyrebird-stream-manager.sh"
        "usb-audio-mapper.sh"
    )
    local tracked script
    while IFS= read -r -d '' tracked; do
        scripts+=("$tracked")
    done < <(git ls-files -z -- '*.sh' 2>/dev/null || true)

    for script in "${scripts[@]}"; do
        if [[ -f "$script" ]]; then
            if ! (
                umask "$ORIGINAL_UMASK"
                chmod +x "$script"
            ) 2>/dev/null; then
                log_warn "Could not set executable permission on $script (permission denied)"
                log_debug "This may cause issues when running $script"
            fi
        fi
    done

    return 0
}

################################################################################
# Rollback Command
################################################################################

# lyrebird-updater.sh --rollback [VERSION]
# Goes back to a version that is already in this clone, as the same
# transaction an update is (stash, service handling, migrations, journal,
# history), and without any network access.
#   no VERSION  the version the last completed update, rollback or reset left
#   VERSION     a release tag, or a commit; a branch name is refused (a
#               rollback is to an exact commit, not to "the latest of a branch")
# Exit status: that of the switch (0, 1, 5, 8, 9, 10, 11), 6 when the version is
# not in the clone.
rollback_command() {
    local requested="${1:-}"
    local commit="" target="" label=""

    if [[ -n "$requested" ]]; then
        if [[ ! "$requested" =~ ^[a-zA-Z0-9._/-]+$ ]]; then
            log_error "Invalid version: $requested"
            return "$E_GENERAL"
        fi
        if git show-ref --verify --quiet "refs/tags/${requested}"; then
            target="$requested"
        elif git show-ref --verify --quiet "refs/heads/${requested}" \
            || git show-ref --verify --quiet "refs/remotes/origin/${requested}"; then
            log_error "'${requested}' is a branch. A rollback goes back to a release tag or to a commit."
            log_info "To follow a branch, use option 3 of the menu."
            return "$E_GENERAL"
        fi
        if ! commit="$(git rev-parse --verify --quiet "${requested}^{commit}" 2>/dev/null)"; then
            log_error "Version '${requested}' is not available in this repository"
            log_info "A rollback never uses the network. For a release that has not been fetched yet,"
            log_info "run '${SCRIPT_NAME} --list' while online (or: git fetch --tags), then try again."
            log_info "Releases in this clone: git tag -l 'v*'    What was installed: ${SCRIPT_NAME} --history"
            return "$E_NOT_FOUND"
        fi
        [[ -n "$target" ]] || target="$commit"
        label="$requested"
    else
        local line from_commit from_label to_commit
        line="$(history_last_change)"
        if [[ -z "$line" ]]; then
            log_error "There is no previous version to go back to: no completed update is recorded."
            log_info "Name the version instead: ${SCRIPT_NAME} --rollback v1.2.3"
            log_info "What this node has had: ${SCRIPT_NAME} --history    Releases here: git tag -l 'v*'"
            return "$E_NOT_FOUND"
        fi
        IFS=$'\t' read -r _ _ _ from_commit from_label to_commit _ <<<"$line"
        if [[ "$from_commit" == "-" ]]; then
            log_error "The last update did not record the version it came from (an older updater started it)."
            log_info "Name the version instead: ${SCRIPT_NAME} --rollback v1.2.3"
            return "$E_NOT_FOUND"
        fi
        if ! commit="$(git rev-parse --verify --quiet "${from_commit}^{commit}" 2>/dev/null)"; then
            log_error "The previous version (${from_label}, ${from_commit:0:7}) is no longer in this clone."
            log_info "Name another one: ${SCRIPT_NAME} --rollback VERSION    Releases here: git tag -l 'v*'"
            return "$E_NOT_FOUND"
        fi
        if [[ "$(git rev-parse HEAD 2>/dev/null || true)" != "$to_commit" ]]; then
            log_warn "This node is not at the version the last update recorded; going back to ${from_label} anyway."
        fi
        label="$from_label"
        target="$commit"
        # a release tag that still names that commit reads better in the output
        if [[ "$from_label" != "-" ]] && [[ "$(git rev-parse --verify --quiet "refs/tags/${from_label}^{commit}" 2>/dev/null || true)" == "$commit" ]]; then
            target="$from_label"
        fi
    fi

    if [[ "$(git rev-parse HEAD 2>/dev/null || true)" == "$commit" ]]; then
        log_info "Already on ${label} (${commit:0:7}); nothing to do."
        return 0
    fi

    log_info "Rolling back to ${label} (${commit:0:7}); the network is not used."
    switch_version_safe "$target" rollback
}

################################################################################
# Version Listing and Selection
################################################################################

list_available_releases() {
    AVAILABLE_VERSIONS=()

    echo
    echo "${BOLD}=== Available Versions ===${NC}"
    echo

    # List stable releases (tags)
    echo "${BOLD}Stable Releases (numbered versions, tested and stable):${NC}"

    if git tag -l 'v*' --sort=-v:refname | head -n "$TAG_LIST_LIMIT" | grep -q .; then
        local counter=1
        while IFS= read -r tag; do
            local tag_date
            tag_date=$(git log -1 --format=%ai "$tag" 2>/dev/null | cut -d' ' -f1 || echo "unknown")
            printf "  %2d) %-15s (created: %s)\n" "$counter" "$tag" "$tag_date"

            AVAILABLE_VERSIONS+=("$tag")
            ((counter++)) || true
        done < <(git tag -l 'v*' --sort=-v:refname | head -n "$TAG_LIST_LIMIT")

        local tag_count
        tag_count=$(git tag -l 'v*' | wc -l)
        if [[ "$tag_count" -gt "$TAG_LIST_LIMIT" ]]; then
            echo "      ... and $((tag_count - TAG_LIST_LIMIT)) more (not shown)"
        fi
    else
        echo "  (no stable releases found)"
    fi

    echo
    echo "${BOLD}Development & Feature Branches (select any to switch):${NC}"
    echo "  The '${DEFAULT_BRANCH}' branch is where active development happens."
    echo

    local branch_counter=$((${#AVAILABLE_VERSIONS[@]} + 1))
    local git_branches
    git_branches=$(git branch -r | grep -v HEAD | sed 's/origin\///' | sed 's/^[[:space:]]*//') || true

    if [[ -n "$git_branches" ]]; then
        while IFS= read -r branch; do
            if [[ "$branch" == "$DEFAULT_BRANCH" ]]; then
                printf "  %2d) %s %s\n" "$branch_counter" "$branch" "(development)"
            else
                printf "  %2d) %s\n" "$branch_counter" "$branch"
            fi
            AVAILABLE_VERSIONS+=("$branch")
            ((branch_counter++)) || true
        done <<<"$git_branches"
    else
        echo "  (no development branches found)"
    fi

    echo
    echo "${CYAN}Tip: You can also enter any commit hash or branch name directly${NC}"
    echo
}

select_version_interactive() {
    # Fetch updates first
    if ! fetch_updates_safe; then
        log_warn "Could not fetch updates - using cached information"
        echo
    fi

    # Show available versions
    list_available_releases

    echo "You can enter:"
    echo "  - A number from the list (e.g., 1, 5)"
    echo "  - A tag directly (e.g., v1.2.0)"
    echo "  - A branch name (e.g., ${DEFAULT_BRANCH}, feature/streaming)"
    echo "  - A commit hash (e.g., abc1234)"
    echo "  - Press Enter to cancel"
    echo
    local selection=""
    menu_read selection "Your selection: "

    if [[ -z "$selection" ]]; then
        log_info "Selection cancelled"
        return 0
    fi

    local target_version=""

    # Check if input is a number
    if [[ "$selection" =~ ^[0-9]+$ ]]; then
        local index=$((selection - 1))

        if [[ "$index" -ge 0 ]] && [[ "$index" -lt "${#AVAILABLE_VERSIONS[@]}" ]]; then
            target_version="${AVAILABLE_VERSIONS[$index]}"
            log_info "Selected: $target_version"
        else
            log_error "Invalid selection: $selection"
            log_info "Please choose between 1 and ${#AVAILABLE_VERSIONS[@]}"
            return "$E_GENERAL"
        fi
    else
        # Validate direct version name input against whitelist
        if [[ ! "$selection" =~ ^[a-zA-Z0-9._/-]+$ ]]; then
            log_error "Invalid version format"
            log_error "Only alphanumeric characters, dots, underscores, slashes, and hyphens are allowed"
            return "$E_GENERAL"
        fi

        target_version="$selection"
    fi

    # Additional validation - verify version exists
    if ! validate_version_exists "$target_version"; then
        log_error "Version '$target_version' does not exist"
        log_info "Try running 'Check for Updates' first (option 4)"
        return "$E_GENERAL"
    fi

    switch_version_safe "$target_version"
}

switch_to_latest_stable() {
    log_step "Finding latest stable release..."

    # Fetch first
    if ! fetch_updates_safe; then
        log_warn "Using cached version information"
    fi

    # Get latest tag by creation date
    local latest_tag
    if ! latest_tag="$(git tag -l 'v*' --sort=-v:refname | head -n 1)"; then
        log_error "No stable releases found"
        return "$E_GENERAL"
    fi

    if [[ -z "$latest_tag" ]]; then
        log_error "No version tags found in repository"
        log_info "The repository may not have any releases yet"
        return "$E_GENERAL"
    fi

    log_info "Latest stable release: $latest_tag"
    switch_version_safe "$latest_tag"
}

switch_to_development() {
    log_step "Switching to development version..."

    # Fetch first
    if ! fetch_updates_safe; then
        log_warn "Using cached version information"
    fi

    switch_version_safe "$DEFAULT_BRANCH"
}

################################################################################
# Status Display Functions
################################################################################

show_status() {
    get_current_version
    check_local_changes
    detect_git_state

    echo
    echo "${BOLD}=== Repository Status ===${NC}"
    echo

    # Current position
    if [[ "$IS_DETACHED" == "true" ]]; then
        echo "${BOLD}Current State:${NC}"
        echo "  Status:     ${YELLOW}Viewing a Specific Release (not on a branch)${NC}"
        echo "  Version:    ${BOLD}$CURRENT_VERSION${NC}"

        local tags_here
        tags_here=$(git tag --points-at HEAD 2>/dev/null | tr '\n' ' ')
        if [[ -n "$tags_here" ]]; then
            echo "  Tags:       $tags_here"
        fi
    else
        echo "${BOLD}Current Branch:${NC}"
        echo "  Branch:     ${BOLD}$CURRENT_BRANCH${NC}"
        echo "  Commit:     ${BOLD}$CURRENT_VERSION${NC}"

        # Show branch type
        if [[ "$CURRENT_BRANCH" == "$DEFAULT_BRANCH" ]]; then
            echo "  Type:       ${CYAN}Development (where new features are added)${NC}"
        else
            echo "  Type:       Feature/Release branch"
        fi

        # Check if on a tag
        local current_tag
        current_tag=$(git describe --exact-match --tags HEAD 2>/dev/null || echo "")
        if [[ -n "$current_tag" ]]; then
            echo "  Tag:        ${GREEN}$current_tag${NC}"
        fi

        # Show relationship to remote
        if git show-ref --verify --quiet "refs/remotes/origin/$CURRENT_BRANCH" 2>/dev/null; then
            local ahead behind
            ahead=$(git rev-list --count "origin/$CURRENT_BRANCH..HEAD" 2>/dev/null || echo "0")
            behind=$(git rev-list --count "HEAD..origin/$CURRENT_BRANCH" 2>/dev/null || echo "0")

            if [[ "$ahead" -gt 0 ]] && [[ "$behind" -gt 0 ]]; then
                echo "  Remote:     ${YELLOW}Diverged ($ahead ahead, $behind behind)${NC}"
            elif [[ "$ahead" -gt 0 ]]; then
                echo "  Remote:     ${YELLOW}$ahead commit(s) ahead${NC}"
            elif [[ "$behind" -gt 0 ]]; then
                echo "  Remote:     ${YELLOW}$behind commit(s) behind${NC}"
            else
                echo "  Remote:     ${GREEN}In sync${NC}"
            fi
        else
            echo "  Remote:     ${YELLOW}No remote tracking${NC}"
        fi
    fi

    echo
    echo "${BOLD}Working Directory:${NC}"

    case "$GIT_STATE" in
        clean)
            echo "  Status:     ${GREEN}Ready (no local modifications)${NC}"
            ;;
        dirty)
            echo "  Status:     ${YELLOW}Has Local Modifications${NC}"
            echo
            echo "  File Status Legend:  M=modified  A=added  D=deleted  ?=untracked"
            echo
            git status --short | head -n 10 | sed 's/^/    /'

            local change_count
            change_count=$(git status --short | wc -l)
            if [[ "$change_count" -gt 10 ]]; then
                echo "    ... and $((change_count - 10)) more"
            fi
            ;;
        merge | rebase | revert | cherry-pick | bisect | sequencer)
            echo "  Status:     ${RED}${GIT_STATE^^} IN PROGRESS${NC}"
            ;;
    esac

    echo
    echo "${BOLD}Repository Info:${NC}"

    local repo_remote
    repo_remote=$(git remote get-url origin 2>/dev/null || echo "none")
    echo "  Remote:     $repo_remote"

    local last_fetch="never"
    if [[ -f ".git/FETCH_HEAD" ]] && command -v stat >/dev/null 2>&1; then
        last_fetch=$(stat -c %y ".git/FETCH_HEAD" 2>/dev/null | cut -d'.' -f1 \
            || stat -f %Sm ".git/FETCH_HEAD" 2>/dev/null || echo "unknown")
        # Ensure last_fetch is not empty
        [[ -z "$last_fetch" ]] && last_fetch="unknown"
    fi
    echo "  Last fetch: $last_fetch"

    # Show systemd service status if installed
    if [[ -f "$SERVICE_FILE" ]]; then
        echo
        echo "${BOLD}Systemd Service:${NC}"
        echo "  Service:    $SERVICE_NAME"

        if systemctl is-active --quiet "$SERVICE_NAME" 2>/dev/null; then
            echo "  Status:     ${GREEN}Running${NC}"
        else
            echo "  Status:     ${YELLOW}Stopped${NC}"
        fi

        if systemctl is-enabled --quiet "$SERVICE_NAME" 2>/dev/null; then
            echo "  Enabled:    ${GREEN}Yes${NC}"
        else
            echo "  Enabled:    ${YELLOW}No${NC}"
        fi
    fi

    echo
}

show_startup_diagnostics() {
    get_current_version
    check_local_changes

    echo
    echo "${BOLD}=== LyreBirdAudio Version Manager v${VERSION} ===${NC}"
    echo

    # Current version
    if [[ "$IS_DETACHED" == "true" ]]; then
        echo "Current:  ${YELLOW}Viewing Release: ${BOLD}$CURRENT_VERSION${NC}${YELLOW} (not tracking a branch)${NC}"
    else
        if [[ "$CURRENT_BRANCH" == "$DEFAULT_BRANCH" ]]; then
            echo "Current:  ${GREEN}Development Branch ${BOLD}$CURRENT_BRANCH${NC} @ $CURRENT_VERSION"
        else
            echo "Current:  ${CYAN}Branch ${BOLD}$CURRENT_BRANCH${NC} @ $CURRENT_VERSION"
        fi
    fi

    if [[ "$HAS_LOCAL_CHANGES" == "true" ]]; then
        echo "Changes:  ${YELLOW}You have local modifications${NC}"
    else
        echo "Changes:  ${GREEN}Clean working directory${NC}"
    fi

    echo
    log_step "Checking for updates..."

    # Quick fetch (with short timeout)
    local fetch_ok=false
    if command -v timeout >/dev/null 2>&1; then
        if run_unlocked timeout 5 git fetch --all --tags --prune --quiet 2>/dev/null; then
            fetch_ok=true
        fi
    else
        if git fetch --all --tags --prune --quiet 2>/dev/null; then
            fetch_ok=true
        fi
    fi

    if [[ "$fetch_ok" == "true" ]]; then
        echo "          ${GREEN}[OK]${NC} Connected to GitHub"
    else
        echo "          ${YELLOW}!${NC} Could not connect (using cached data)"
    fi

    # Check for stable releases
    local latest_tag
    latest_tag="$(git tag -l 'v*' --sort=-v:refname 2>/dev/null | head -n 1)"

    if [[ -n "$latest_tag" ]]; then
        local current_tag
        current_tag="$(git describe --exact-match --tags HEAD 2>/dev/null || echo "")"

        if [[ -n "$current_tag" ]] && [[ "$current_tag" == "$latest_tag" ]]; then
            echo "Stable:   ${GREEN}You're on latest: $latest_tag${NC}"
        else
            echo "Stable:   ${YELLOW}Update available: $latest_tag${NC}"
            echo "          ${CYAN}^ Select option 1 to update${NC}"
        fi
    fi

    # Check development branch
    if [[ "$IS_DETACHED" == "false" ]]; then
        local behind
        behind=$(git rev-list --count "HEAD..origin/$CURRENT_BRANCH" 2>/dev/null || echo "0")

        if [[ "$behind" -gt 0 ]]; then
            echo "Dev:      ${YELLOW}$behind commit(s) behind origin/$CURRENT_BRANCH${NC}"
            echo "          ${CYAN}^ Select option 2 to update${NC}"
        else
            echo "Dev:      ${GREEN}Up to date with origin/$CURRENT_BRANCH${NC}"
        fi
    fi

    echo

    # Only prompt if stdin is a terminal
    if [[ -t 0 ]]; then
        menu_pause
    fi
}

################################################################################
# Help and Menu Functions
################################################################################

show_help() {
    # Get default branch dynamically
    local help_default_branch="${DEFAULT_BRANCH:-develop}"

    cat <<EOF

================================================================================
   LyreBirdAudio Version Manager - Help Guide
================================================================================

USAGE:
  ${SCRIPT_NAME}              Interactive menu (described below)
  ${SCRIPT_NAME} --status     Show current version, branch and sync status (-s)
  ${SCRIPT_NAME} --list       Fetch and list available versions (-l)
  ${SCRIPT_NAME} --history    Show past updates, failures and rollbacks (no network needed)
  ${SCRIPT_NAME} --rollback [VERSION]
                              Go back to the previous version, or to a release tag or
                              commit already in this clone (no network needed)
  ${SCRIPT_NAME} --migrate    Run post-update migrations
  ${SCRIPT_NAME} --version    Print the updater version (-v)
  ${SCRIPT_NAME} --help       Show this help (-h)

BRANCH TYPES:
  - Stable Releases (tags like v1.2.0)
    - Tested, production-ready versions
    - Recommended for most users
    - Updates released periodically

  - Development Branch (${help_default_branch})
    - Latest code with new features
    - Where active development happens
    - May contain bugs or incomplete features
    - Good for testing new functionality

=== MAIN OPTIONS ===

1) Switch to Latest Stable Release
   ^ Newest tested version
   ^ Recommended for production use
   ^ Automatically checks for updates
   ^ Your changes will be saved temporarily
   ^ Systemd services automatically updated

2) Switch to Development Version (${help_default_branch})
   ^ Latest code with newest features
   ^ Where new features are actively developed
   ^ May have bugs or incomplete features
   ^ For testing and development
   ^ Your changes will be saved temporarily
   ^ Systemd services automatically updated

3) Switch to Specific Version or Branch
   ^ Choose any stable release (tag), development branch, or feature branch
   ^ Full list shows all available options
   ^ Can input version name directly (v1.2.0, develop, feature/xyz)
   ^ Useful for testing, switching between branches, or rollback
   ^ Your changes will be saved temporarily
   ^ Systemd services automatically updated

4) Check for New Updates
   ^ Downloads version information from GitHub
   ^ Doesn't change your current version
   ^ Shows what's available

5) Show Detailed Status
   ^ Your current version and branch
   ^ What type of branch you're on
   ^ Local modifications status
   ^ Sync status with remote
   ^ Repository information
   ^ Systemd service status

6) Discard All Changes & Reset
   ^ PERMANENTLY deletes local modifications
   ^ Resets to a clean version
   ^ Use with caution!

=== SYSTEMD SERVICE INTEGRATION ===

The updater now automatically handles systemd service updates:

  [OK] Detects if mediamtx-audio.service is installed
  [OK] Stops service before version switch
  [OK] Preserves custom environment variables
  [OK] Reinstalls service definition if script changed
  [OK] Restarts service after successful update
  [OK] Rolls back service on failure

Your custom service configuration (e.g., STREAM_MODE, MULTIPLEX_FILTER_TYPE)
will be preserved during updates.

=== SAFETY FEATURES ===

[OK] Your changes are automatically saved before updating
[OK] Service configurations are preserved across updates
[OK] Confirmation required for destructive actions
[OK] Automatic rollback if operations fail
[OK] Clear warnings before permanent actions
[OK] Service restoration on update failure
[OK] Syntax validation for self-updates

=== COMMON QUESTIONS ===

Q: What happens to my changes when I update?
A: They're automatically saved and will be restored after the update

Q: What happens to my systemd service?
A: It's automatically stopped, updated, and restarted with your custom config

Q: Can I undo an update?
A: Yes. '${SCRIPT_NAME} --rollback' returns to the previous version, '--rollback v1.3.0'
   to a release already in this clone; '--history' shows what was installed. Option 3
   of the menu also switches to any version (it can fetch new ones first).

Q: The updater was killed or the power failed in the middle of an update.
A: Run '${SCRIPT_NAME}' again: it finds the unfinished update and undoes it (or, for a
   self-update, completes it). Your uncommitted changes are never discarded.

Q: What if something goes wrong?
A: The script automatically tries to recover, including service restoration

Q: How do I start fresh with no modifications?
A: Use option 6 to reset to a clean state

Q: What's the difference between stable and development?
A: Stable = tested releases (v1.2.0). Development = latest code (${help_default_branch})

Q: Will my custom service variables be lost?
A: No, custom environment variables are automatically preserved

Q: What if the updater itself has errors?
A: Syntax validation prevents deployment of broken scripts

=== EXIT STATUS OF THE MENU ===

A switch or reset that fails is reported and the menu stays open. Q leaves the
menu with the status of the last switch or reset you ran (0 when it worked;
the status table is in the documentation). End of input at a prompt (Ctrl-D, a
closed pipe) leaves with status ${E_INPUT_EOF}, never with a silent 1.

=== MORE HELP ===

Visit: https://github.com/tomtom215/LyreBirdAudio

EOF
}

# Exit status of the last switch or reset run from the menu. Q ends the run
# with it (see main), so a script that feeds the menu through stdin can read
# whether what it asked for worked.
MENU_LAST_STATUS=0

# Standard input ended while a menu waited for an answer (Ctrl-D, a closed
# pipe, /dev/null). Not an error of the operator's and not a silent failure
# either: say what happened and leave with the status of its own.
menu_input_ended() {
    echo
    log_warn "Input ended (end of file) at a prompt: leaving the version manager."
    if [[ "$MENU_LAST_STATUS" -ne 0 ]]; then
        log_warn "The last action ended with exit status ${MENU_LAST_STATUS}."
    fi
    log_info "Exit status ${E_INPUT_EOF} means the input ended; Q leaves the menu normally."
    exit "$E_INPUT_EOF"
}

# Read one line of the menu's input into the variable named $1 (discarded when
# $1 is empty). A last line without a newline still counts; end of input with
# nothing read ends the run (menu_input_ended). (A plain `read` that fails under
# errexit ended the run silently with status 1.)
# Usage: menu_read VARIABLE PROMPT
menu_read() {
    local __menu_target="$1" __menu_prompt="$2" __menu_line=""
    if ! read -r -p "$__menu_prompt" __menu_line && [[ -z "$__menu_line" ]]; then
        menu_input_ended
    fi
    if [[ -n "$__menu_target" ]]; then
        printf -v "$__menu_target" '%s' "$__menu_line"
    fi
}

menu_pause() {
    menu_read "" "Press Enter to continue..."
}

# Run one menu action. When it fails the menu does not end: the failure is
# reported and the status is kept for Q (MENU_LAST_STATUS). The action runs in
# a `||` context, where errexit is off: a statement that fails inside it no
# longer ends the whole run, the action's own checks decide, and those already
# roll the transaction back for every failure they know about
# (transaction_abort); the check below is the net under that.
# Usage: menu_run COMMAND [ARGS...]
menu_run() {
    local rc=0
    "$@" || rc=$?
    # An action never returns with a transaction open. If one ever did, every
    # later action would refuse with "Transaction already active": roll it back.
    if [[ "${TRANSACTION_STATE[active]}" == "true" ]]; then
        log_error "The action ended with its transaction still open: rolling it back"
        if ! transaction_rollback "the menu action ended with its transaction open"; then
            rc="$E_ROLLBACK_FAILED"
        elif [[ $rc -eq 0 ]]; then
            rc="$E_GENERAL"
        fi
    fi
    MENU_LAST_STATUS="$rc"
    if [[ $rc -ne 0 ]]; then
        echo
        log_warn "That did not complete (exit status ${rc}). The menu is still open."
    fi
    return 0
}

# A read-only choice (check, status, help): reported when it fails, but it does
# not replace the status of the last switch or reset
menu_view() {
    local previous="$MENU_LAST_STATUS"
    menu_run "$@"
    MENU_LAST_STATUS="$previous"
}

menu_check_for_updates() {
    if fetch_updates_safe; then
        list_available_releases
    fi
}

main_menu() {
    local choice=""
    while true; do
        get_current_version
        check_local_changes

        clear 2>/dev/null || true # exits 1 on TERM=dumb or without terminfo: not a reason to end the menu
        echo
        echo "${BOLD}+---------------------------------------------------------+${NC}"
        echo "${BOLD}|     LyreBirdAudio - Version Manager v${VERSION}      |${NC}"
        echo "${BOLD}+---------------------------------------------------------+${NC}"
        echo

        # Status header
        if [[ "$IS_DETACHED" == "true" ]]; then
            echo "  Current:  ${YELLOW}$CURRENT_VERSION${NC}"
        else
            if [[ "$CURRENT_BRANCH" == "$DEFAULT_BRANCH" ]]; then
                echo "  Current:  ${GREEN}$CURRENT_BRANCH${NC} (development) @ ${BOLD}$CURRENT_VERSION${NC}"
            else
                echo "  Current:  ${CYAN}$CURRENT_BRANCH${NC} @ ${BOLD}$CURRENT_VERSION${NC}"
            fi
        fi

        if [[ "$HAS_LOCAL_CHANGES" == "true" ]]; then
            echo "  Changes:  ${YELLOW}Has local modifications${NC}"
        else
            echo "  Changes:  ${GREEN}None${NC}"
        fi

        # Show service status if installed
        if [[ -f "$SERVICE_FILE" ]]; then
            if systemctl is-active --quiet "$SERVICE_NAME" 2>/dev/null; then
                echo "  Service:  ${GREEN}Running${NC}"
            else
                echo "  Service:  ${YELLOW}Stopped${NC}"
            fi
        fi

        echo
        echo "${BOLD}=== UPDATE ===${NC}"
        echo "  ${BOLD}1${NC}) Switch to Latest Stable Release"
        echo "     (Newest tested version-recommended)"
        echo "  ${BOLD}2${NC}) Switch to Development Version (${DEFAULT_BRANCH})"
        echo "     (Latest code with new features-where active development happens)"
        echo "  ${BOLD}3${NC}) Switch to Specific Version or Branch"
        echo "     (Any release tag, branch, or commit-full flexibility)"
        echo
        echo "${BOLD}=== INFO ===${NC}"
        echo "  ${BOLD}4${NC}) Check for New Updates"
        echo "  ${BOLD}5${NC}) Show Detailed Status"
        echo
        echo "${BOLD}=== DANGER ZONE ===${NC}"
        echo "  ${BOLD}6${NC}) Discard All Changes & Reset..."
        echo
        echo "  ${BOLD}H${NC}) Help  |  ${BOLD}Q${NC}) Quit"
        echo
        menu_read choice "Select [1-6, H, Q]: "

        case "$choice" in
            1)
                menu_run switch_to_latest_stable
                menu_pause
                ;;
            2)
                menu_run switch_to_development
                menu_pause
                ;;
            3)
                menu_run select_version_interactive
                menu_pause
                ;;
            4)
                menu_view menu_check_for_updates
                menu_pause
                ;;
            5)
                menu_view show_status
                menu_pause
                ;;
            6)
                menu_run reset_menu
                ;;
            h | H)
                menu_view show_help
                menu_pause
                ;;
            q | Q)
                echo
                log_info "Thank you for using LyreBirdAudio Version Manager"
                return 0
                ;;
            *)
                log_error "Invalid option: $choice"
                sleep 1
                ;;
        esac
    done
}

# Returns the status of the reset it ran (0 when the operator cancelled)
reset_menu() {
    local reset_status=0 choice="" version=""
    while true; do
        echo
        echo "${BOLD}=== DISCARD CHANGES & RESET ===${NC}"
        log_warn "This will PERMANENTLY delete all your local modifications!"
        echo
        echo "Reset to:"
        echo "  ${BOLD}1${NC}) Latest remote version of current branch"
        echo "     (Only available if you're tracking a branch)"
        echo "  ${BOLD}2${NC}) Latest development version (${DEFAULT_BRANCH})"
        echo "  ${BOLD}3${NC}) Specific version (let me choose)"
        echo "  ${BOLD}C${NC}) Cancel"
        echo
        menu_read choice "Select [1-3, C]: "

        case "$choice" in
            1)
                get_current_version
                if [[ "$IS_DETACHED" == "true" ]]; then
                    log_warn "You're viewing a specific version (not tracking a branch)"
                    log_info "Resetting to HEAD won't change anything"
                    log_info "Choose option 2 or 3 instead"
                    menu_pause
                else
                    if git show-ref --verify --quiet "refs/remotes/origin/$CURRENT_BRANCH"; then
                        reset_to_clean_state "origin/$CURRENT_BRANCH" || reset_status=$?
                    else
                        log_error "Remote branch not found: origin/$CURRENT_BRANCH"
                    fi
                fi
                menu_pause
                return "$reset_status"
                ;;
            2)
                if git show-ref --verify --quiet "refs/remotes/origin/${DEFAULT_BRANCH}"; then
                    reset_to_clean_state "origin/${DEFAULT_BRANCH}" || reset_status=$?
                else
                    log_error "Development branch not found: origin/${DEFAULT_BRANCH}"
                    log_info "Try option 4 from main menu to fetch updates"
                fi
                menu_pause
                return "$reset_status"
                ;;
            3)
                log_step "Fetching available versions..."
                if ! fetch_updates_safe; then
                    log_warn "Using cached information"
                fi

                list_available_releases
                echo
                menu_read version "Enter version to reset to: "

                if [[ -z "$version" ]]; then
                    log_info "Cancelled"
                elif ! validate_version_exists "$version"; then
                    log_error "Version '$version' does not exist"
                else
                    reset_to_clean_state "$version" || reset_status=$?
                fi
                menu_pause
                return "$reset_status"
                ;;
            c | C)
                log_info "Cancelled"
                menu_pause
                return 0
                ;;
            *)
                log_error "Invalid choice"
                sleep 1
                ;;
        esac
    done
}

################################################################################
# Main Entry Point
################################################################################

main() {
    # Change to script directory
    if ! cd "$SCRIPT_DIR" 2>/dev/null; then
        log_error "Failed to change to script directory: $SCRIPT_DIR"
        exit "$E_GENERAL"
    fi

    # The history is a local file: readable with no network, no lock and no git
    if [[ "${1:-}" == "--history" ]]; then
        show_history
        exit "$E_SUCCESS"
    fi

    # A self-update re-exec resumes here with --post-update-* . At that point the
    # service is already stopped and only the completion/restore half remains.
    # Mark the run as resumed so check_prerequisites skips the interactive
    # root/ownership prompt: a non-interactive or walked-away re-exec would
    # otherwise hit EOF on that prompt, abort, and leave the service down.
    case "${1:-}" in
        --post-update-complete | --post-update-restore) RESUMED_POST_UPDATE=true ;;
    esac

    # Check prerequisites. The checks return the documented code themselves (2
    # missing tool, 9 operator declined the root prompt); main() used to
    # replace every one of them with a single code, so 5, 9 and 3-vs-5 never
    # reached the caller.
    local startup_status=0
    check_prerequisites || startup_status=$?
    if [[ $startup_status -ne 0 ]]; then
        exit "$startup_status"
    fi

    # Acquire lock (7 held by another updater, 5 cannot be written)
    acquire_lock || startup_status=$?
    if [[ $startup_status -ne 0 ]]; then
        exit "$startup_status"
    fi

    # Validate git repository (3 not a repository, 5 not writable or owned by root)
    check_git_repository || startup_status=$?
    if [[ $startup_status -ne 0 ]]; then
        exit "$startup_status"
    fi

    # Save and configure git settings
    save_git_config

    # Detect default branch (CRITICAL: Must be done early and consistently used)
    # Only the commands that fetch (the menu, --list) ask the remote; the rest
    # must work with the network down.
    local branch_probe=""
    case "${1:-}" in
        --version | -v | --help | -h | --status | -s | --migrate | --rollback | --post-update-complete | --post-update-restore)
            branch_probe="offline"
            ;;
    esac
    DEFAULT_BRANCH="$(get_default_branch "$branch_probe")"
    log_debug "Default branch: $DEFAULT_BRANCH"

    # An update that an earlier run did not finish (killed, crashed, power cut):
    # a run that changes things undoes it first; the read-only commands only say
    # so. --post-update-* is the continuation of an update, not a new one.
    case "${1:-}" in
        "" | --rollback)
            local recovery_status=0
            recover_interrupted_transaction || recovery_status=$?
            if [[ $recovery_status -ne 0 ]]; then
                exit "$recovery_status"
            fi
            ;;
        --post-update-complete | --post-update-restore) ;;
        *) report_interrupted_transaction || true ;;
    esac

    # Handle command line arguments
    local post_update_no_menu=false
    if [[ $# -gt 0 ]]; then
        case "$1" in
            --post-update-restore)
                if [[ -z "${2:-}" ]]; then
                    log_error "Missing stash hash argument"
                    exit "$E_GENERAL"
                fi

                echo
                log_success "Updater has been updated!"
                log_step "Restoring your saved changes..."

                local restore_status=0 handoff_note=""
                [[ "${3:-}" == "--no-menu" ]] && post_update_no_menu=true
                handoff_load_journal || true
                restore_saved_changes "$2" || restore_status=$?
                if [[ $restore_status -eq 0 ]]; then
                    log_success "Changes restored successfully"
                elif [[ $restore_status -eq $E_RESTORE_CONFLICT ]]; then
                    EXIT_STATUS="$E_RESTORE_CONFLICT"
                    handoff_note="saved changes kept in the stash"
                fi
                # an old updater's lock directory comes back with the stash
                legacy_lock_held || true

                # Check for pending service update
                if check_pending_service_update; then
                    if ! complete_pending_service_update; then
                        log_error "Service update completion failed"
                        log_info "You may need to manually check the service status"
                    fi
                fi
                handoff_finish "$handoff_note"

                if [[ "$post_update_no_menu" == "true" ]]; then
                    exit "$EXIT_STATUS"
                fi
                echo
                read -r -p "Press Enter to continue..." || true
                ;;

            --post-update-complete)
                echo
                log_success "Updater has been updated successfully!"

                [[ "${2:-}" == "--no-menu" ]] && post_update_no_menu=true
                handoff_load_journal || true
                # Check for pending service update
                if check_pending_service_update; then
                    if ! complete_pending_service_update; then
                        log_error "Service update completion failed"
                        log_info "You may need to manually check the service status"
                    fi
                fi
                handoff_finish

                if [[ "$post_update_no_menu" == "true" ]]; then
                    exit "$EXIT_STATUS"
                fi
                echo
                read -r -p "Press Enter to continue..." || true
                ;;

            --version | -v)
                echo "LyreBirdAudio Version Manager v${VERSION}"
                exit "$E_SUCCESS"
                ;;

            --help | -h)
                show_help
                exit "$E_SUCCESS"
                ;;

            --status | -s)
                show_status
                exit "$E_SUCCESS"
                ;;

            --list | -l)
                # Cached data is still listed, but the exit status says it is not fresh
                local list_status="$E_SUCCESS"
                fetch_updates_safe || list_status=$?
                list_available_releases
                if [[ $list_status -ne 0 ]]; then
                    log_warn "The list above is from the last successful fetch: origin could not be reached."
                fi
                exit "$list_status"
                ;;

            --migrate)
                echo
                echo "${BOLD}=== Running Migrations ===${NC}"
                echo
                run_post_update_migrations
                exit "$E_SUCCESS"
                ;;

            --rollback)
                if [[ $# -gt 2 ]]; then
                    log_error "Usage: ${SCRIPT_NAME} --rollback [VERSION]"
                    exit "$E_GENERAL"
                fi
                local rollback_status=0
                rollback_command "${2:-}" || rollback_status=$?
                exit "$rollback_status"
                ;;

            *)
                log_error "Unknown option: $1"
                echo "Try '$SCRIPT_NAME --help' for more information"
                exit "$E_GENERAL"
                ;;
        esac
    fi

    # Check for pending service update (in case of abnormal termination)
    if check_pending_service_update; then
        log_warn "Detected incomplete service update from previous run"
        if confirm_action "Complete the pending service update now?"; then
            if ! complete_pending_service_update; then
                log_error "Failed to complete pending service update"
                log_info "You may need to manually check the service"
            fi
        else
            log_info "Service update will be attempted on next version switch"
        fi
        echo
    fi

    # Show startup diagnostics
    show_startup_diagnostics

    # Run interactive menu
    main_menu

    # Left with Q: the status of the last switch or reset that was run from the
    # menu if it failed, else the run's own (E_RESTORE_CONFLICT after a
    # self-update that could not re-apply the saved changes, else 0)
    if [[ "$MENU_LAST_STATUS" -ne 0 ]]; then
        exit "$MENU_LAST_STATUS"
    fi
    exit "$EXIT_STATUS"
}

# Run main function
# Only execute when run directly, not when sourced (e.g. by the test suite)
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi
