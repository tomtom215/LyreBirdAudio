#!/usr/bin/env bats
# Exit status 7 of install_mediamtx.sh (register: X-57).
#
# The installer used 7 for "MediaMTX is already installed" (install), "is not installed"
# (update, uninstall) and "could not be stopped", and also for a failed extraction, a
# missing binary in the archive and a binary that could not be put in place. The
# orchestrator's Quick Setup wizard reads any 7 from `install` as "already installed:
# carry on", so a corrupt download ended in "continuing with setup" on a node without
# MediaMTX. The binary steps now exit 11 (the next free number); 7 keeps the meaning the
# wizard assumes.
#
# The real installer runs its real download, checksum, extraction and installation code
# against a local release (tests/installer_fixture.bash); the wizard is the real
# orchestrator on a pseudo-terminal with stand-ins for the delegated scripts.

load scratch_tmpdir
load installer_fixture
load orchestrator_helper

setup() {
    scratch_setup
    orch_setup
    PROJECT_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
    export MEDIAMTX_PREFIX="$TEST_SCRATCH/prefix" MEDIAMTX_CONFIG_DIR="$TEST_SCRATCH/etc"
    export MEDIAMTX_STATE_DIR="$TEST_SCRATCH/state" MEDIAMTX_USER=root MEDIAMTX_GROUP=root
    export MEDIAMTX_SERVICE_DIR="$TEST_SCRATCH/systemd" MEDIAMTX_INSTALLER_LOCK_FILE="$TEST_SCRATCH/installer.lock"
    export FIXTURE_DIR="$TEST_SCRATCH/release" PROJECT_ROOT
    mkdir -p "$FIXTURE_DIR" "$TEST_SCRATCH/bin"
    # a MediaMTX that runs and has no --validate-conf
    FAKE="$TEST_SCRATCH/bin/mediamtx"
    printf '#!/bin/bash\ncase "${1:-}" in --version) echo v9.9.9 ;; --help) echo usage ;; esac\n' >"$FAKE"
    chmod +x "$FAKE"
    PREAMBLE="$(installer_fixture_preamble)"$'\nSKIP_SERVICE=true'
    export PREAMBLE
}

teardown() {
    scratch_teardown
}

# the real `install` of the installer (extra shell code in $1, run after the stand-ins)
run_install() {
    export EXTRA="${1:-}"
    run bash -c 'source "$PROJECT_ROOT/install_mediamtx.sh"; eval "$PREAMBLE"; eval "$EXTRA"; install_mediamtx'
}

# Replace the release's archive by FILE (with the checksum the release then publishes)
publish_archive() {
    local tarball="$FIXTURE_DIR/mediamtx_v9.9.9_linux_amd64.tar.gz"
    cp "$1" "$tarball"
    printf '%s  %s\n' "$(sha256sum "$tarball" | awk '{print $1}')" "$(basename "$tarball")" >"$FIXTURE_DIR/checksums.sha256"
}

@test "install: an archive that cannot be extracted exits 11, not the 7 of 'already installed' [X-57]" {
    installer_release_fixture "$FIXTURE_DIR" v9.9.9 "$FAKE"
    printf 'this is not a tarball\n' >"$TEST_SCRATCH/garbage"
    publish_archive "$TEST_SCRATCH/garbage"
    run_install
    [ "$status" -eq 11 ] || {
        echo "status $status: $output"
        false
    }
    [[ "$output" == *"Failed to extract archive"* ]]
    [ ! -e "$MEDIAMTX_PREFIX/bin/mediamtx" ]
}

@test "install: an archive without the binary exits 11 [X-57]" {
    installer_release_fixture "$FIXTURE_DIR" v9.9.9 "$FAKE"
    mkdir -p "$TEST_SCRATCH/stage2"
    echo "not mediamtx" >"$TEST_SCRATCH/stage2/README"
    tar -czf "$TEST_SCRATCH/other.tar.gz" -C "$TEST_SCRATCH/stage2" README
    publish_archive "$TEST_SCRATCH/other.tar.gz"
    run_install
    [ "$status" -eq 11 ] || {
        echo "status $status: $output"
        false
    }
    [[ "$output" == *"Binary not found in archive"* ]]
}

@test "install: a binary that cannot be put in place exits 11, at the copy and at the move [X-57]" {
    installer_release_fixture "$FIXTURE_DIR" v9.9.9 "$FAKE"
    run_install 'install() { return 1; }'
    [ "$status" -eq 11 ] || {
        echo "status $status: $output"
        false
    }
    [[ "$output" == *"Failed to prepare binary for installation"* ]]
    run_install 'mv() { return 1; }'
    [ "$status" -eq 11 ] || {
        echo "status $status: $output"
        false
    }
    [[ "$output" == *"Failed to atomically install binary"* ]]
}

@test "install: 7 still means 'already installed' and nothing else; update and uninstall of what is not installed keep 7 [X-57]" {
    installer_release_fixture "$FIXTURE_DIR" v9.9.9 "$FAKE"
    run_install
    [ "$status" -eq 0 ] || {
        echo "status $status: $output"
        false
    }
    [ -x "$MEDIAMTX_PREFIX/bin/mediamtx" ]
    run_install
    [ "$status" -eq 7 ]
    [[ "$output" == *"MediaMTX is already installed"* ]]
    rm -f "$MEDIAMTX_PREFIX/bin/mediamtx"
    run bash -c 'source "$PROJECT_ROOT/install_mediamtx.sh"; eval "$PREAMBLE"; update_mediamtx'
    [ "$status" -eq 7 ]
    [[ "$output" == *"MediaMTX is not installed"* ]]
}

@test "the installer's help lists its exit codes: 7 for already installed, not installed and could not be stopped, 11 for the binary steps [X-57]" {
    run bash "$PROJECT_ROOT/install_mediamtx.sh" --help
    [ "$status" -eq 0 ]
    local line
    line="$(grep -E '^ +7 ' <<<"$output")"
    [[ "$line" == *"already installed"* && "$line" == *"not installed"* && "$line" == *"stopped"* ]]
    [[ "$line" != *"extract"* ]]
    line="$(grep -E '^ +11 ' <<<"$output")"
    [[ "$line" == *"extract"* && "$line" == *"binary"* ]]
    # and the others the code uses are there too
    local code
    for code in 0 1 2 3 4 5 6 8 9 10; do
        grep -qE "^ +${code} " <<<"$output" || {
            echo "no line for exit code $code"
            false
        }
    done
}

@test "wizard: a failed binary installation (the status the real installer gave for a corrupt archive) stops at step 1 instead of carrying on [X-57]" {
    command -v jq >/dev/null || skip "jq is needed"
    # the status of the real installer for an archive that does not extract
    installer_release_fixture "$FIXTURE_DIR" v9.9.9 "$FAKE"
    printf 'this is not a tarball\n' >"$TEST_SCRATCH/garbage"
    publish_archive "$TEST_SCRATCH/garbage"
    run_install
    local real_status="$status"
    [ "$real_status" -ne 0 ]
    [ "$real_status" -ne 7 ]

    export STUB_RC_installer_install="$real_status"
    orch_run \
        --step 'Continue with quick setup\? \(y/n\)' 'y' \
        --step 'Press Enter to continue' '\n' \
        'menu_quick_setup'
    [[ "$output" == *"Failed to install MediaMTX"* ]] || {
        echo "$output"
        false
    }
    [[ "$output" != *"MediaMTX is already installed; continuing with setup"* ]]
    [[ "$output" != *"Step 2/4"* ]]
    # nothing after the installer was run
    ! grep -q '^usb_mapper' "$ORCH_CALLS"
    ! grep -q '^stream_manager' "$ORCH_CALLS"
}

@test "the orchestrator explains installer exit 7 without calling it a failed install step, and 11 as a failed binary installation [X-57]" {
    export STUB_RC_installer_install=7
    orch_run 'execute_script installer install || true; report_installer_result install'
    [[ "$output" == *"The installer exited with code 7: MediaMTX is already installed (use Update or Reinstall)"* ]]
    [[ "$output" != *"an install step failed"* ]]
    export STUB_RC_installer_install=11
    orch_run 'execute_script installer install || true; report_installer_result install'
    [[ "$output" == *"MediaMTX install failed (installer exit code: 11 - the MediaMTX binary could not be extracted or installed)"* ]]
}
