#!/usr/bin/env bats
# --version everywhere, and an updater whose --help and --version answer first
# (register: X-61 --version missing on the stream manager and alerts; X-62 the
# updater asked for the root confirmation, took its lock and checked the network
# before it printed its help).

load scratch_tmpdir

setup() {
    scratch_setup
    PROJECT_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
}

teardown() {
    scratch_teardown
}

script_version() {
    grep -m1 -E '^readonly (SCRIPT_)?VERSION=' "$PROJECT_ROOT/$1" | sed -E 's/.*="([^"]+)".*/\1/'
}

@test "the stream manager and alerts print their version and exit 0 for --version and -V [X-61]" {
    local want opt
    want="$(script_version lyrebird-stream-manager.sh)"
    [ -n "$want" ]
    for opt in --version -V; do
        run bash "$PROJECT_ROOT/lyrebird-stream-manager.sh" "$opt"
        [ "$status" -eq 0 ]
        [[ "$output" == *"version $want" ]] || {
            echo "manager $opt: $output"
            false
        }
    done
    want="$(script_version lyrebird-alerts.sh)"
    [ -n "$want" ]
    for opt in --version -V version; do
        run bash "$PROJECT_ROOT/lyrebird-alerts.sh" "$opt"
        [ "$status" -eq 0 ]
        [[ "$output" == *"version $want" ]] || {
            echo "alerts $opt: $output"
            false
        }
    done
}

@test "the help of the stream manager and alerts lists the version option [X-61]" {
    run bash "$PROJECT_ROOT/lyrebird-stream-manager.sh" --help
    [[ "$output" == *"--version"* ]]
    run bash "$PROJECT_ROOT/lyrebird-alerts.sh" help
    [[ "$output" == *"--version"* ]]
}

@test "updater --help and --version answer at once for a sudo user without a terminal: no root prompt, no lock, exit 0 [X-62]" {
    local lockdir opt out
    lockdir="$(git -C "$PROJECT_ROOT" rev-parse --git-dir 2>/dev/null || echo "$PROJECT_ROOT/.git")/lyrebird-updater"
    [[ "$lockdir" == /* ]] || lockdir="$PROJECT_ROOT/$lockdir"
    for opt in --help -h --version -v; do
        rm -rf "$lockdir"
        # SUDO_USER makes the updater ask "Continue anyway?"; with no terminal that answer
        # was "no" (exit 9, "Cancelled by user") before the help was printed
        run env SUDO_USER=someone bash "$PROJECT_ROOT/lyrebird-updater.sh" "$opt" </dev/null
        out="$output"
        [ "$status" -eq 0 ] || {
            echo "$opt: status $status: $out"
            false
        }
        [[ "$out" != *"Cancelled by user"* && "$out" != *"Continue anyway"* ]]
        [ ! -e "$lockdir" ] || {
            echo "$opt created $lockdir"
            false
        }
    done
    run env SUDO_USER=someone bash "$PROJECT_ROOT/lyrebird-updater.sh" --version </dev/null
    [[ "$output" == *"v$(script_version lyrebird-updater.sh)"* ]]
    run env SUDO_USER=someone bash "$PROJECT_ROOT/lyrebird-updater.sh" --help </dev/null
    [[ "$output" == *"Help Guide"* ]]
}
