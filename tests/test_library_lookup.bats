#!/usr/bin/env bats
# Where a script looks for lyrebird-common.sh (register: X-50).
#
# Every script that needs the library used to build its path as
# "${BASH_SOURCE[0]%/*}/lyrebird-common.sh". When a script is started by its bare
# name from its own directory (bash lyrebird-stream-manager.sh config) there is no
# slash in BASH_SOURCE[0], the expansion leaves the script's own name unchanged and
# the path became "lyrebird-stream-manager.sh/lyrebird-common.sh": the library was
# never found, silently, and the manager's "config" stopped with "lyrebird-common.sh
# with lyrebird_atomic_write is required next to lyrebird-stream-manager.sh".
#
# The real scripts run in a scratch directory next to a copy of the real library
# with one line appended that prints a marker when the library is loaded: the marker
# is what says "the library was found", whatever the script then does.

load scratch_tmpdir

# The scripts that load the library at the top, and a harmless option for each
# (name:option). The updater is started as root in these tests and exits at its own
# prompt; the marker is printed long before that.
SCRIPTS_WITH_LIBRARY=(
    "install_mediamtx.sh:--help"
    "lyrebird-diagnostics.sh:--help"
    "lyrebird-mic-check.sh:--help"
    "lyrebird-orchestrator.sh:--help"
    "lyrebird-stream-manager.sh:--help"
    "lyrebird-updater.sh:--help"
)

setup() {
    scratch_setup
    PROJECT_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
    export PROJECT_ROOT
    BARE="$TEST_SCRATCH/bare"
    mkdir -p "$BARE"
    local entry
    for entry in "${SCRIPTS_WITH_LIBRARY[@]}"; do
        cp "$PROJECT_ROOT/${entry%%:*}" "$BARE/"
    done
    cp "$PROJECT_ROOT/lyrebird-common.sh" "$BARE/"
    printf '%s\n' 'echo "LIBRARY-LOADED-MARKER $(dirname -- "${BASH_SOURCE[0]}")" >&2' >>"$BARE/lyrebird-common.sh"
}

teardown() {
    scratch_teardown
}

# start NAME [ARGS...] from DIR by bare name, nothing on stdin
bare_run() {
    local dir="$1" name="$2"
    shift 2
    run bash -c 'cd "$1" && shift && exec bash "$@" </dev/null' _ "$dir" "$name" "$@"
}

@test "every script that needs the library finds it when started by its bare name from its own directory [X-50]" {
    local entry name opt missing=""
    for entry in "${SCRIPTS_WITH_LIBRARY[@]}"; do
        name="${entry%%:*}"
        opt="${entry#*:}"
        bare_run "$BARE" "$name" "$opt"
        if [[ "$output" != *"LIBRARY-LOADED-MARKER"* ]]; then
            missing+=" $name"
        fi
    done
    [ -z "$missing" ] || {
        echo "library not found when started by bare name:$missing"
        false
    }
}

@test "the stream manager started by its bare name in the repository writes the default device configuration [X-50]" {
    # the reproducer of the finding, with the real checkout as the directory
    local cfg="$TEST_SCRATCH/cfg"
    mkdir -p "$cfg"
    run bash -c 'cd "$PROJECT_ROOT" && exec env MEDIAMTX_CONFIG_DIR="$1" MEDIAMTX_DEVICE_CONFIG="$1/a.conf" bash lyrebird-stream-manager.sh config </dev/null' _ "$cfg"
    [[ "$output" != *"is required next to"* ]]
    [ "$status" -eq 0 ]
    [ -s "$cfg/a.conf" ]
}

@test "started by its bare name the stream manager still verifies the library hash [X-50]" {
    # LYREBIRD_COMMON_EXPECTED_HASH is checked against the library the script
    # sourced: a wrong value must stop it (exit 1), the right one lets it run
    local good
    good="$(sha256sum "$BARE/lyrebird-common.sh" | cut -d' ' -f1)"
    run bash -c 'cd "$1" && exec env LYREBIRD_COMMON_EXPECTED_HASH=0000 bash lyrebird-stream-manager.sh --help </dev/null' _ "$BARE"
    [ "$status" -eq 1 ]
    [[ "$output" == *"integrity check failed"* ]]
    [[ "$output" != *"LIBRARY-LOADED-MARKER"* ]]

    run bash -c 'cd "$1" && exec env LYREBIRD_COMMON_EXPECTED_HASH="$2" bash lyrebird-stream-manager.sh --help </dev/null' _ "$BARE" "$good"
    [ "$status" -eq 0 ]
    [[ "$output" == *"LIBRARY-LOADED-MARKER"* ]]
    [[ "$output" != *"integrity check failed"* ]]
}

@test "a script started through a symlink finds the library beside the file the link points at, and one beside the link first [X-50]" {
    local linkdir="$TEST_SCRATCH/links"
    mkdir -p "$linkdir"
    ln -s "$BARE/lyrebird-diagnostics.sh" "$linkdir/lyrebird-diagnostics.sh"

    # by path, and by bare name from the directory that holds the link
    run bash "$linkdir/lyrebird-diagnostics.sh" --help </dev/null
    [[ "$output" == *"LIBRARY-LOADED-MARKER $BARE"* ]]
    bare_run "$linkdir" lyrebird-diagnostics.sh --help
    [[ "$output" == *"LIBRARY-LOADED-MARKER $BARE"* ]]

    # a library beside the link is the one used, as before
    cp "$PROJECT_ROOT/lyrebird-common.sh" "$linkdir/lyrebird-common.sh"
    printf '%s\n' 'echo "LIBRARY-LOADED-MARKER BESIDE-THE-LINK" >&2' >>"$linkdir/lyrebird-common.sh"
    bare_run "$linkdir" lyrebird-diagnostics.sh --help
    [[ "$output" == *"LIBRARY-LOADED-MARKER BESIDE-THE-LINK"* ]]
    [[ "$output" != *"LIBRARY-LOADED-MARKER $BARE"* ]]
}

@test "a script sourced by its bare name loads the library [X-50]" {
    local entry name missing=""
    for entry in "${SCRIPTS_WITH_LIBRARY[@]}"; do
        name="${entry%%:*}"
        # sourcepath off: source reads the file in the current directory, not one of
        # the same name that PATH happens to hold
        run bash -c 'cd "$1" && shopt -u sourcepath && source "$2" >/dev/null 2>&1 </dev/null; printf "loaded=%s\n" "${_LYREBIRD_COMMON_LOADED:-no}"' _ "$BARE" "$name"
        if [[ "$output" != *"loaded=true"* ]]; then
            missing+=" $name"
        fi
    done
    [ -z "$missing" ] || {
        echo "library not loaded when sourced by bare name:$missing"
        false
    }
}

@test "no script builds the library path with a slash-stripping expansion of BASH_SOURCE [X-50]" {
    local f hits=""
    for f in "$PROJECT_ROOT"/*.sh "$PROJECT_ROOT"/tools/*/*.sh; do
        if grep -v '^[[:space:]]*#' "$f" | grep -qF '${BASH_SOURCE[0]%/*}'; then
            hits+=" ${f#"$PROJECT_ROOT"/}"
        fi
    done
    [ -z "$hits" ] || {
        echo "still uses \${BASH_SOURCE[0]%/*} (wrong for a bare name):$hits"
        false
    }
}
