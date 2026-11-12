#!/usr/bin/env bats
# install_mediamtx.sh against real MediaMTX binaries
# (register: LB-06 and LB-22 installer side, LB-02/X-12 installer unit side,
# N-1; decisions D9, D10, D12).
#
# Runs only when LYREBIRD_TEST_MEDIAMTX_BINS names one or more MediaMTX
# binaries (space-separated; tests/fetch_mediamtx.sh downloads checksum-pinned
# releases). Needs curl, ffmpeg, ffprobe, tar and python3. Every test runs the
# whole list. No default port is bound: each test starts MediaMTX on free ports
# and moves its other listeners away (tests/mediamtx_live_helper.bash).
#
# The installer's own install code runs against a local stand-in for GitHub
# (tests/installer_fixture.bash): the real binary is packed into a release
# tarball with its checksum, and get_release_info, download_mediamtx,
# verify_checksum, the extraction and the atomic install are the installer's.
# The service user is root (it exists, so nothing is created on this machine)
# and the systemd unit is not written here (see test_install_mediamtx.bats).

load scratch_tmpdir
load mediamtx_live_helper
load installer_fixture

# Skips here, not in setup(): a setup() that skips would also skip the failing
# canary test_suite_can_fail.bats appends to every file.
require_live() {
    [[ -n "${LYREBIRD_TEST_MEDIAMTX_BINS:-}" ]] || skip "set LYREBIRD_TEST_MEDIAMTX_BINS to run"
    local tool
    for tool in curl ffmpeg ffprobe python3 tar; do
        command -v "$tool" >/dev/null || skip "$tool not installed"
    done
}

require_remote_address() {
    REMOTE="$(nonloopback_addr)" || skip "this machine has no non-loopback IPv4 address"
}

setup() {
    scratch_setup
    PROJECT_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
    mtx_ports_setup
}

teardown() {
    mtx_cleanup
    [[ -n "${TEST_SCRATCH:-}" ]] && scratch_teardown
    return 0
}

each_binary_begin() {
    echo "# MediaMTX $(mtx_version "$1")" >&3
    mtx_ports_setup
    rm -rf "$TEST_SCRATCH/prefix" "$TEST_SCRATCH/etc" "$TEST_SCRATCH/state" "$TEST_SCRATCH/release"
}

# The installer's environment for this test: private prefix, configuration and
# state directories, this test's ports, the root account as the service user
installer_environment() {
    export MEDIAMTX_PREFIX="$TEST_SCRATCH/prefix" MEDIAMTX_CONFIG_DIR="$TEST_SCRATCH/etc"
    export MEDIAMTX_STATE_DIR="$TEST_SCRATCH/state" MEDIAMTX_USER=root MEDIAMTX_GROUP=root
    export MEDIAMTX_RTSP_PORT="$P_RTSP" MEDIAMTX_API_PORT="$P_API" MEDIAMTX_METRICS_PORT="$P_METRICS"
    export FIXTURE_DIR="$TEST_SCRATCH/release" PROJECT_ROOT
    PREAMBLE="$(installer_fixture_preamble)"$'\nSKIP_SERVICE=true'
    export PREAMBLE
}

# Run the installer's `install` for BINARY (a real MediaMTX) as a release of its version
run_install() {
    local bin="$1"
    installer_environment
    installer_release_fixture "$FIXTURE_DIR" "$(mtx_version "$bin")" "$bin"
    run bash -c 'source "$PROJECT_ROOT/install_mediamtx.sh"; eval "$PREAMBLE"; install_mediamtx'
}

# The sockets the installed configuration opens, sorted
default_listeners() {
    printf '%s\n' "tcp 0.0.0.0:${P_RTSP}" "tcp 127.0.0.1:${P_API}" "tcp 127.0.0.1:${P_METRICS}" \
        "udp 0.0.0.0:${P_RTCP}" "udp 0.0.0.0:${P_RTP}" | sort
}

@test "install writes a configuration every MediaMTX version accepts and opens exactly the sockets it names: no SRT, MoQ, RTMP, HLS or WebRTC [LB-06 installer, LB-22 installer]" {
    require_live
    local bin actual
    for bin in $LYREBIRD_TEST_MEDIAMTX_BINS; do
        each_binary_begin "$bin"
        run_install "$bin"
        [ "$status" -eq 0 ] || {
            echo "$output"
            false
        }
        [ "$(head -n 1 "$MEDIAMTX_CONFIG_DIR/mediamtx.yml")" = "# Managed by LyreBirdAudio" ]
        # MediaMTX's own check, where the binary has one (1.21 and later)
        if "$bin" --help 2>&1 | grep -q -- '--validate-conf'; then
            "$bin" "--validate-conf=$MEDIAMTX_CONFIG_DIR/mediamtx.yml" || {
                echo "MediaMTX $(mtx_version "$bin") rejects the installed configuration"
                false
            }
        fi
        mtx_start "$MEDIAMTX_PREFIX/bin/mediamtx" "$MEDIAMTX_CONFIG_DIR/mediamtx.yml"
        actual="$(mtx_listeners "$MTX_PID")"
        [ "$actual" = "$(default_listeners)" ] || {
            echo "listeners of $(mtx_version "$bin"):"
            echo "$actual"
            echo "expected:"
            default_listeners
            false
        }
        ! grep -q 'ERR' "$TEST_SCRATCH/mediamtx.log" || {
            cat "$TEST_SCRATCH/mediamtx.log"
            false
        }
        ! grep -qE '\[(MoQ|SRT|RTMP|HLS|WebRTC)\]' "$TEST_SCRATCH/mediamtx.log" || {
            grep -E '\[(MoQ|SRT|RTMP|HLS|WebRTC)\]' "$TEST_SCRATCH/mediamtx.log"
            false
        }
        mtx_stop
    done
}

@test "through the installed configuration a publisher without credentials publishes and a client without credentials reads, from this machine [LB-06 installer]" {
    require_live
    local bin
    for bin in $LYREBIRD_TEST_MEDIAMTX_BINS; do
        each_binary_begin "$bin"
        run_install "$bin"
        [ "$status" -eq 0 ]
        mtx_start "$MEDIAMTX_PREFIX/bin/mediamtx" "$MEDIAMTX_CONFIG_DIR/mediamtx.yml"
        mtx_publish "rtsp://127.0.0.1:${P_RTSP}/mic1"
        mtx_wait_path_ready mic1 || {
            cat "$TEST_SCRATCH/publisher.log" "$TEST_SCRATCH/mediamtx.log"
            false
        }
        mtx_can_read "rtsp://127.0.0.1:${P_RTSP}/mic1" || {
            cat "$TEST_SCRATCH/read.err"
            false
        }
        mtx_unpublish
        mtx_stop
    done
}

@test "the API and the metrics endpoint of the installed configuration cannot be reached from a remote address, and answer on this machine's loopback address [LB-06 installer, D9]" {
    require_live
    require_remote_address
    local bin
    for bin in $LYREBIRD_TEST_MEDIAMTX_BINS; do
        each_binary_begin "$bin"
        run_install "$bin"
        [ "$status" -eq 0 ]
        mtx_start "$MEDIAMTX_PREFIX/bin/mediamtx" "$MEDIAMTX_CONFIG_DIR/mediamtx.yml"
        [ "$(mtx_http_status "http://127.0.0.1:${P_API}/v3/paths/list")" = 200 ]
        [ "$(mtx_http_status "http://127.0.0.1:${P_METRICS}/metrics")" = 200 ]
        # bound to the loopback address: refused before MediaMTX sees the request (no HTTP status at all)
        [ "$(mtx_http_status "http://${REMOTE}:${P_API}/v3/paths/list")" = 000 ]
        [ "$(mtx_http_status "http://${REMOTE}:${P_METRICS}/metrics")" = 000 ]
        mtx_stop
    done
}

# Run the installer's `update` (forced, so that a release of the same version is
# an update too) from a release fixture of BINARY, a real MediaMTX or a stand-in
run_update() {
    local bin="$1" version="$2"
    installer_environment
    export MEDIAMTX_PID_FILE="$TEST_SCRATCH/no-such.pid"
    installer_release_fixture "$FIXTURE_DIR" "$version" "$bin"
    PREAMBLE="$(installer_fixture_preamble)"$'\nSKIP_SERVICE=true\nFORCE_MODE=true'
    export PREAMBLE
    run bash -c 'source "$PROJECT_ROOT/install_mediamtx.sh"; eval "$PREAMBLE"; update_mediamtx'
}

@test "update in manual mode on a real MediaMTX stops it by identity, installs the verified binary, exits 0 and says how to start it; the new binary loads the old configuration [N-1]" {
    require_live
    local bin
    for bin in $LYREBIRD_TEST_MEDIAMTX_BINS; do
        each_binary_begin "$bin"
        run_install "$bin"
        [ "$status" -eq 0 ]
        # started by hand, the way an operator without systemd would: the installed binary on the installed configuration
        mtx_start "$MEDIAMTX_PREFIX/bin/mediamtx" "$MEDIAMTX_CONFIG_DIR/mediamtx.yml"
        local running_pid="$MTX_PID"
        run_update "$bin" "$(mtx_version "$bin")"
        [ "$status" -eq 0 ] || {
            echo "$output"
            false
        }
        # the installer stopped that process (and only that one) ...
        ! kill -0 "$running_pid" 2>/dev/null || {
            echo "MediaMTX (PID $running_pid) is still running"
            false
        }
        [[ "$output" == *"MediaMTX is NOT running"* ]]
        [[ "$output" == *"  $MEDIAMTX_PREFIX/bin/mediamtx $MEDIAMTX_CONFIG_DIR/mediamtx.yml"* ]]
        [[ "$output" != *"rollback"* ]]
        # ... and the verified binary is installed: the release's file, running
        cmp "$bin" "$MEDIAMTX_PREFIX/bin/mediamtx"
        [ "$(mtx_version "$MEDIAMTX_PREFIX/bin/mediamtx")" = "$(mtx_version "$bin")" ]
        # started again the way the notice says, it loads the configuration it had
        mtx_start "$MEDIAMTX_PREFIX/bin/mediamtx" "$MEDIAMTX_CONFIG_DIR/mediamtx.yml"
        [ "$(mtx_http_status "http://127.0.0.1:${P_API}/v3/paths/list")" = 200 ]
        mtx_stop
    done
}

@test "update in manual mode on a real MediaMTX restores the previous binary, exit 7, when the new one does not run [N-1]" {
    require_live
    local bin
    for bin in $LYREBIRD_TEST_MEDIAMTX_BINS; do
        each_binary_begin "$bin"
        run_install "$bin"
        [ "$status" -eq 0 ]
        mtx_start "$MEDIAMTX_PREFIX/bin/mediamtx" "$MEDIAMTX_CONFIG_DIR/mediamtx.yml"
        local running_pid="$MTX_PID"
        mkdir -p "$TEST_SCRATCH/broken"
        printf '#!/bin/bash\necho "cannot execute binary file" >&2\nexit 126\n' >"$TEST_SCRATCH/broken/mediamtx"
        chmod +x "$TEST_SCRATCH/broken/mediamtx"
        run_update "$TEST_SCRATCH/broken/mediamtx" "$(mtx_version "$bin")"
        [ "$status" -eq 7 ]
        [[ "$output" == *"does not run"* ]]
        ! kill -0 "$running_pid" 2>/dev/null || false
        # the real binary is back, byte for byte, and runs
        cmp "$bin" "$MEDIAMTX_PREFIX/bin/mediamtx"
        mtx_start "$MEDIAMTX_PREFIX/bin/mediamtx" "$MEDIAMTX_CONFIG_DIR/mediamtx.yml"
        mtx_stop
    done
}
