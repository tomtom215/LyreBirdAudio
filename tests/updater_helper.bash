# shellcheck shell=bash
# Real git repositories for the updater tests: a bare "origin", an authoring
# clone ("work") and the node under test ("repo", a clone that carries the
# lyrebird-updater.sh under test and is what gets updated).
#
# The origin lives under .../github.com/tomtom215/LyreBirdAudio.git so the
# updater's "is this the expected remote" check accepts it without a prompt.
# Nothing here touches the host: system paths are re-rooted under the node's
# sysroot (LYREBIRD_UPDATER_SYSROOT) and git talks to local paths only.
#
# Load after scratch_tmpdir. Once per file:  setup_file() { updater_template_build; }
# Per test (after scratch_setup):             updater_node_setup
#
# Tags in the fixture history:
#   v1.0.0  base                                   (scripts tracked 644, mapper 755)
#   v1.1.0  stream manager and config.txt change
#   v1.2.0  stream manager and diagnostics change, adds added-in-1.2.0.txt
#   v1.3.0  the updater itself changes             (forces the self-update re-exec)

UPDATER_HELPER_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
UPDATER_PROJECT_ROOT="$(cd "$UPDATER_HELPER_DIR/.." && pwd)"
# Mutation checks run the same tests against another copy of the script (a
# directory holding lyrebird-updater.sh and lyrebird-common.sh).
UPDATER_SCRIPT_SOURCE="${UPDATER_SCRIPT_SOURCE:-$UPDATER_PROJECT_ROOT}"

updater_git_env() {
    export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 GIT_TERMINAL_PROMPT=0
    export GIT_AUTHOR_NAME=fixture GIT_AUTHOR_EMAIL=fixture@example.invalid
    export GIT_COMMITTER_NAME=fixture GIT_COMMITTER_EMAIL=fixture@example.invalid
}

# updater_template_build: build the shared fixture once (call from setup_file).
# Sets UPDATER_TEMPLATE; a test file that needs a different history builds on
# top of it per test with the work clone.
updater_template_build() {
    local base origin work
    updater_git_env
    export UPDATER_TEMPLATE="$BATS_FILE_TMPDIR/template"
    base="$UPDATER_TEMPLATE"
    origin="$base/github.com/tomtom215/LyreBirdAudio.git"
    work="$base/work"
    (
        umask 022
        mkdir -p "$(dirname "$origin")"
        git init -q --bare -b main "$origin"
        git clone -q "$origin" "$work" 2>/dev/null
        cp "$UPDATER_SCRIPT_SOURCE/lyrebird-updater.sh" "$UPDATER_SCRIPT_SOURCE/lyrebird-common.sh" "$work/"
        chmod 644 "$work/lyrebird-updater.sh"
        chmod 755 "$work/lyrebird-common.sh"
        local name
        for name in lyrebird-stream-manager lyrebird-orchestrator lyrebird-diagnostics; do
            printf '#!/bin/bash\necho %s v1.0.0\n' "$name" >"$work/$name.sh"
            chmod 644 "$work/$name.sh"
        done
        printf '#!/bin/bash\necho installer v1.0.0\n' >"$work/install_mediamtx.sh"
        chmod 644 "$work/install_mediamtx.sh"
        printf '#!/bin/bash\necho mapper v1.0.0\n' >"$work/usb-audio-mapper.sh"
        chmod 755 "$work/usb-audio-mapper.sh"
        printf 'config v1.0.0\n' >"$work/config.txt"
        git -C "$work" add -A
        git -C "$work" commit -qm "v1.0.0"
        git -C "$work" tag v1.0.0

        printf '#!/bin/bash\necho lyrebird-stream-manager v1.1.0\n' >"$work/lyrebird-stream-manager.sh"
        printf 'config v1.1.0\n' >"$work/config.txt"
        git -C "$work" commit -qam "v1.1.0"
        git -C "$work" tag v1.1.0

        printf '#!/bin/bash\necho lyrebird-stream-manager v1.2.0\n' >"$work/lyrebird-stream-manager.sh"
        printf '#!/bin/bash\necho lyrebird-diagnostics v1.2.0\n' >"$work/lyrebird-diagnostics.sh"
        printf 'added in v1.2.0\n' >"$work/added-in-1.2.0.txt"
        git -C "$work" add added-in-1.2.0.txt
        git -C "$work" commit -qam "v1.2.0"
        git -C "$work" tag v1.2.0

        printf '\n# v1.3.0 marker comment\n' >>"$work/lyrebird-updater.sh"
        printf '#!/bin/bash\necho lyrebird-stream-manager v1.3.0\n' >"$work/lyrebird-stream-manager.sh"
        git -C "$work" commit -qam "v1.3.0"
        git -C "$work" tag v1.3.0

        git -C "$work" push -q origin main --tags 2>/dev/null
        git clone -q "$origin" "$base/repo" 2>/dev/null
    )
}

# updater_node_setup: a private copy of the template for this test.
# Sets NODE, ORIGIN, WORK, REPO, SYSROOT, SHIMS, and exports the environment
# updater_run needs. The repo starts on main (at v1.3.0).
updater_node_setup() {
    updater_git_env
    NODE="$TEST_SCRATCH/node"
    cp -a "$UPDATER_TEMPLATE" "$NODE"
    ORIGIN="$NODE/github.com/tomtom215/LyreBirdAudio.git"
    WORK="$NODE/work"
    REPO="$NODE/repo"
    SYSROOT="$NODE/sysroot"
    SHIMS="$NODE/shims"
    FAULT_LOG="$NODE/fault.log"
    # the directories a real system has; there is no service unit, cron job or
    # old script in them unless a test puts one there
    mkdir -p "$SYSROOT/usr/local/bin" "$SYSROOT/var/log" "$SYSROOT/var/lib" "$SYSROOT/run" \
        "$SYSROOT/etc/systemd/system" "$SYSROOT/etc/cron.d" "$SHIMS"
    git -C "$REPO" remote set-url origin "$ORIGIN"
    git -C "$WORK" remote set-url origin "$ORIGIN"
    cp "$UPDATER_HELPER_DIR/helpers/updater/bin/git" "$UPDATER_HELPER_DIR/helpers/updater/bin/stat" "$SHIMS/"
    FAULT_REAL_GIT="$(command -v git)"
    export NODE ORIGIN WORK REPO SYSROOT SHIMS FAULT_LOG FAULT_REAL_GIT
    export LYREBIRD_UPDATER_SYSROOT="$SYSROOT"
    export LYREBIRD_FETCH_TIMEOUT=5 LYREBIRD_FETCH_RETRIES=2 LYREBIRD_FETCH_RETRY_DELAY=1
    export TERM=xterm USER=fixture
    export FAULT_STATE="$NODE/fault.count"
    unset http_proxy https_proxy HTTP_PROXY HTTPS_PROXY ALL_PROXY all_proxy
    export no_proxy='*' NO_PROXY='*'
    if [[ "$EUID" -eq 0 ]]; then
        export UPDATER_FAKE_OWNER=fixture
    fi
    updater_checkout "${1:-main}"
}

# updater_checkout REF: move the node to REF (a tag or branch) quietly.
updater_checkout() {
    git -C "$REPO" checkout -q "$1" 2>/dev/null
}

# updater_inject ON WHEN ACT [SKIP]: arm the git fault shim for the next run(s).
updater_inject() {
    export FAULT_ON="$1" FAULT_WHEN="$2" FAULT_ACT="$3" FAULT_SKIP="${4:-0}"
    : >"$FAULT_STATE"
    : >"$FAULT_LOG"
}

updater_inject_clear() {
    unset FAULT_ON FAULT_WHEN FAULT_ACT FAULT_SKIP
}

# updater_stdin LINES...: what the next updater_run sees on stdin. A leading
# "y" answers the root/sudo prompt when the suite runs as root.
updater_stdin() {
    local line
    UPDATER_INPUT=""
    if [[ "$EUID" -eq 0 ]]; then
        UPDATER_INPUT=$'y\n'
    fi
    for line in "$@"; do
        UPDATER_INPUT+="$line"$'\n'
    done
}

# updater_run [ARGS...]: run the real script from the node's clone with the
# fixture PATH (git fault shim, stat shim), feeding UPDATER_INPUT (see
# updater_stdin; just the root answer when unset) on stdin.
# Sets bats' $status and $output (stdout and stderr).
updater_run() {
    [[ -n "${UPDATER_INPUT+set}" ]] || updater_stdin
    run env "${UPDATER_SIGNAL_ARGS[@]}" PATH="$SHIMS:$PATH" bash "$REPO/lyrebird-updater.sh" "$@" <<<"${UPDATER_INPUT%$'\n'}"
    unset UPDATER_INPUT
}

# A script started from a background job inherits an ignored SIGINT, which it
# can no longer trap. The signal tests need the default disposition, so the
# updater is started through `env --default-signal` where coreutils has it.
UPDATER_SIGNAL_ARGS=()
if env --default-signal=INT,TERM true 2>/dev/null; then
    UPDATER_SIGNAL_ARGS=(--default-signal=INT,TERM)
fi

# updater_head: abbreviated HEAD of the node (tag name when on one).
updater_head() {
    git -C "$REPO" describe --tags --exact-match HEAD 2>/dev/null || git -C "$REPO" rev-parse --short HEAD
}

updater_mode() {
    stat -c '%a' "$REPO/$1"
}

# updater_make_diverged_dev: origin has a branch "dev" and the node's local dev
# has a commit origin does not (so a switch to dev cannot fast-forward).
updater_make_diverged_dev() {
    git -C "$WORK" checkout -q -b dev
    echo "dev 1" >"$WORK/dev.txt"
    git -C "$WORK" add dev.txt
    git -C "$WORK" commit -qm "dev 1"
    git -C "$WORK" push -q origin dev 2>/dev/null
    git -C "$REPO" fetch -q origin
    git -C "$REPO" checkout -q -b dev origin/dev 2>/dev/null
    echo "local only" >"$REPO/local-only.txt"
    git -C "$REPO" add local-only.txt
    git -C "$REPO" commit -qm "local commit on dev"
    echo "dev 2" >>"$WORK/dev.txt"
    git -C "$WORK" commit -qam "dev 2"
    git -C "$WORK" push -q origin dev 2>/dev/null
    git -C "$REPO" fetch -q origin
}

# updater_make_old_updater_tag: origin gets v0.9.0, whose lyrebird-updater.sh
# predates the self-update hand-over: it knows no --post-update-* option.
updater_make_old_updater_tag() {
    git -C "$WORK" checkout -q v1.0.0
    printf '#!/bin/bash\n# an old updater: no hand-over options\necho "old updater: unknown option: $1" >&2\nexit 1\n' >"$WORK/lyrebird-updater.sh"
    echo "config v0.9.0" >"$WORK/config.txt"
    git -C "$WORK" commit -qam "v0.9.0 (old updater)"
    git -C "$WORK" tag v0.9.0
    git -C "$WORK" push -q origin v0.9.0 2>/dev/null
    git -C "$WORK" checkout -q main
    git -C "$REPO" fetch -q origin --tags
}

# updater_make_big_tag: origin gets v1.4.0, whose checkout writes a small file
# (aa-first.txt) and then a 900 KB one (big.bin); the node fetches it.
updater_make_big_tag() {
    echo "first" >"$WORK/aa-first.txt"
    head -c 900000 /dev/urandom >"$WORK/big.bin"
    git -C "$WORK" add aa-first.txt big.bin
    git -C "$WORK" commit -qm "v1.4.0 (big)"
    git -C "$WORK" tag v1.4.0
    git -C "$WORK" push -q origin main --tags 2>/dev/null
    git -C "$REPO" fetch -q origin --tags
}

# updater_unshare_cmd: set UNSHARE_CMD to a command that runs its argument in a
# private mount namespace (so a size-limited tmpfs can be mounted and vanishes
# with the process). Returns 1 where that is not permitted.
updater_unshare_cmd() {
    local candidate
    for candidate in "unshare -m" "unshare -Urm"; do
        # shellcheck disable=SC2206
        UNSHARE_CMD=($candidate)
        if "${UNSHARE_CMD[@]}" true 2>/dev/null; then
            return 0
        fi
    done
    return 1
}

# updater_git_clean: no content changes in the node's working tree (file modes
# are ignored, as they are by the updater).
updater_git_clean() {
    [ -z "$(git -C "$REPO" -c core.fileMode=false status --porcelain)" ]
}
