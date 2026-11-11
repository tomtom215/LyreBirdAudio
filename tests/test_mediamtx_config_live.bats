#!/usr/bin/env bats
# The rendered MediaMTX configuration on real MediaMTX binaries
# (register: LB-06, LB-04, LB-22; decisions D9, D10).
#
# Runs only when LYREBIRD_TEST_MEDIAMTX_BINS names one or more MediaMTX
# binaries (space-separated; tests/fetch_mediamtx.sh downloads checksum-pinned
# releases). Needs curl, ffmpeg, ffprobe and python3. Every test runs the whole
# list. No default port is bound: each test starts MediaMTX on free ports and
# moves its other listeners away (tests/mediamtx_live_helper.bash).
#
# "Remote" below means a connection to this machine's own non-loopback address
# (hostname -I): MediaMTX sees a non-loopback source address, which is what an
# IP-restricted rule or its default API policy decides on. A machine without
# such an address skips those tests.

load scratch_tmpdir
load mediamtx_live_helper

# Skips here, not in setup(): a setup() that skips would also skip the failing
# canary test_suite_can_fail.bats appends to every file.
require_live() {
    [[ -n "${LYREBIRD_TEST_MEDIAMTX_BINS:-}" ]] || skip "set LYREBIRD_TEST_MEDIAMTX_BINS to run"
    local tool
    for tool in curl ffmpeg ffprobe python3; do
        command -v "$tool" >/dev/null || skip "$tool not installed"
    done
}

require_remote_address() {
    REMOTE="$(nonloopback_addr)" || skip "this machine has no non-loopback IPv4 address"
}

setup() {
    scratch_setup
    PROJECT_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
    # shellcheck source=../lyrebird-common.sh
    source "$PROJECT_ROOT/lyrebird-common.sh"
    mtx_ports_setup
}

teardown() {
    mtx_cleanup
    [[ -n "${TEST_SCRATCH:-}" ]] && scratch_teardown
    return 0
}

# Print which binary a failure belongs to, and give each one fresh ports
each_binary_begin() {
    echo "# MediaMTX $(mtx_version "$1")" >&3
    mtx_ports_setup
}

# The sockets a default rendered configuration opens, sorted
default_listeners() {
    printf '%s\n' "tcp 0.0.0.0:${P_RTSP}" "tcp 127.0.0.1:${P_API}" "tcp 127.0.0.1:${P_METRICS}" \
        "udp 0.0.0.0:${P_RTCP}" "udp 0.0.0.0:${P_RTP}" | sort
}

@test "the default configuration starts on every MediaMTX version and opens exactly the sockets it names, no SRT, MoQ, RTMP, HLS or WebRTC [LB-06]" {
    require_live
    local bin actual
    for bin in $LYREBIRD_TEST_MEDIAMTX_BINS; do
        each_binary_begin "$bin"
        mtx_render "$bin"
        mtx_start "$bin" "$TEST_SCRATCH/mediamtx.yml"
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

@test "a publisher without credentials can publish and a client without credentials can read, from this machine [LB-06]" {
    require_live
    local bin
    for bin in $LYREBIRD_TEST_MEDIAMTX_BINS; do
        each_binary_begin "$bin"
        mtx_render "$bin"
        mtx_start "$bin" "$TEST_SCRATCH/mediamtx.yml"
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

@test "RTSP is open by default: an anonymous remote client can publish and read. Asserted so that a change is deliberate [LB-06]" {
    require_live
    require_remote_address
    local bin
    for bin in $LYREBIRD_TEST_MEDIAMTX_BINS; do
        each_binary_begin "$bin"
        mtx_render "$bin"
        mtx_start "$bin" "$TEST_SCRATCH/mediamtx.yml"
        mtx_publish "rtsp://${REMOTE}:${P_RTSP}/mic1"
        mtx_wait_path_ready mic1 || {
            cat "$TEST_SCRATCH/publisher.log"
            false
        }
        mtx_can_read "rtsp://${REMOTE}:${P_RTSP}/mic1" || {
            cat "$TEST_SCRATCH/read.err"
            false
        }
        mtx_unpublish
        mtx_stop
    done
}

@test "the API and the metrics endpoint cannot be reached from a remote address; bound to every interface they answer 401 there, 200 here [LB-06, D9]" {
    require_live
    require_remote_address
    local bin
    for bin in $LYREBIRD_TEST_MEDIAMTX_BINS; do
        each_binary_begin "$bin"
        # as rendered by default: bound to the loopback address, so a remote
        # connection is refused before MediaMTX sees it
        mtx_render "$bin"
        mtx_start "$bin" "$TEST_SCRATCH/mediamtx.yml"
        [ "$(mtx_http_status "http://127.0.0.1:${P_API}/v3/paths/list")" = 200 ]
        [ "$(mtx_http_status "http://127.0.0.1:${P_METRICS}/metrics")" = 200 ]
        [ "$(mtx_http_status "http://${REMOTE}:${P_API}/v3/paths/list")" = 000 ]
        [ "$(mtx_http_status "http://${REMOTE}:${P_METRICS}/metrics")" = 000 ]
        mtx_stop
        # an operator who binds them to every interface is still refused by
        # MediaMTX's own default policy (loopback callers only)
        mtx_render "$bin" --api-bind "" --metrics-bind ""
        mtx_start "$bin" "$TEST_SCRATCH/mediamtx.yml"
        [ "$(mtx_http_status "http://127.0.0.1:${P_API}/v3/paths/list")" = 200 ]
        [ "$(mtx_http_status "http://127.0.0.1:${P_METRICS}/metrics")" = 200 ]
        [ "$(mtx_http_status "http://${REMOTE}:${P_API}/v3/paths/list")" = 401 ]
        [ "$(mtx_http_status "http://${REMOTE}:${P_METRICS}/metrics")" = 401 ]
        mtx_stop
    done
}

@test "multiplex configuration: the named path accepts a publisher and every other path is refused [LB-04]" {
    require_live
    local bin
    for bin in $LYREBIRD_TEST_MEDIAMTX_BINS; do
        each_binary_begin "$bin"
        mtx_render "$bin" --stream-name all_mics
        mtx_start "$bin" "$TEST_SCRATCH/mediamtx.yml"
        mtx_publish_once "rtsp://127.0.0.1:${P_RTSP}/all_mics" || {
            cat "$TEST_SCRATCH/publish-once.log"
            false
        }
        ! mtx_publish_once "rtsp://127.0.0.1:${P_RTSP}/mic1"
        mtx_stop
    done
}

@test "names within MediaMTX's path syntax work quoted; one outside it is refused by MediaMTX itself, never read as YAML [LB-04]" {
    require_live
    local bin name rc
    for bin in $LYREBIRD_TEST_MEDIAMTX_BINS; do
        each_binary_begin "$bin"
        for name in studio a.b-c_d/e 0lead; do
            mtx_render "$bin" --stream-name "$name"
            mtx_start "$bin" "$TEST_SCRATCH/mediamtx.yml"
            mtx_publish_once "rtsp://127.0.0.1:${P_RTSP}/${name}" || {
                echo "name [$name]"
                cat "$TEST_SCRATCH/publish-once.log"
                false
            }
            mtx_stop
        done
        mtx_render "$bin" --stream-name "Studio Mix"
        rc=0
        (cd "$TEST_SCRATCH" && timeout 10 "$bin" "$TEST_SCRATCH/mediamtx.yml") >"$TEST_SCRATCH/refused.log" 2>&1 3>&- || rc=$?
        [ "$rc" -ne 0 ] || {
            echo "MediaMTX accepted a path name with a space"
            false
        }
        [ "$rc" -ne 124 ] || {
            echo "MediaMTX kept running with a path name with a space"
            false
        }
        grep -q 'Studio Mix' "$TEST_SCRATCH/refused.log"
    done
}

# A users file for RTSP_AUTH_MODE=local-only-publish: arguments are user:password
make_users_file() {
    local pair
    : >"$TEST_SCRATCH/users.conf"
    for pair in "$@"; do
        printf '%s:sha256:%s\n' "${pair%%:*}" "$(printf '%s' "${pair#*:}" | openssl dgst -sha256 -binary | base64)" >>"$TEST_SCRATCH/users.conf"
    done
}

@test "RTSP_AUTH_MODE=local-only-publish: this machine needs no credentials, a remote client needs a listed user, who can read but not publish [LB-06]" {
    require_live
    require_remote_address
    local bin
    for bin in $LYREBIRD_TEST_MEDIAMTX_BINS; do
        each_binary_begin "$bin"
        make_users_file alice:alice-pw carol:Pa55w0rd-x
        rm -rf "$TEST_SCRATCH/mg"
        manager_generate "$TEST_SCRATCH/mg" "$bin" RTSP_AUTH_MODE=local-only-publish RTSP_USERS_FILE="$TEST_SCRATCH/users.conf" >"$TEST_SCRATCH/gen.out" || {
            cat "$TEST_SCRATCH/gen.out"
            false
        }
        [ "$(stat -c %a "$TEST_SCRATCH/mg/cfg/mediamtx.yml")" = "640" ]
        mtx_start "$bin" "$TEST_SCRATCH/mg/cfg/mediamtx.yml"

        # this machine: publish, read and call the API with no credentials
        mtx_publish "rtsp://127.0.0.1:${P_RTSP}/mic1"
        mtx_wait_path_ready mic1 || {
            cat "$TEST_SCRATCH/publisher.log" "$TEST_SCRATCH/mediamtx.log"
            false
        }
        mtx_can_read "rtsp://127.0.0.1:${P_RTSP}/mic1"

        # a remote client without credentials: neither read nor publish
        ! mtx_can_read "rtsp://${REMOTE}:${P_RTSP}/mic1"
        grep -q '401' "$TEST_SCRATCH/read.err"
        ! mtx_publish_once "rtsp://${REMOTE}:${P_RTSP}/other"
        grep -q '401' "$TEST_SCRATCH/publish-once.log"

        # a listed user reads, with the password the hash was made from
        mtx_can_read "rtsp://alice:alice-pw@${REMOTE}:${P_RTSP}/mic1" || {
            cat "$TEST_SCRATCH/read.err"
            false
        }
        mtx_can_read "rtsp://carol:Pa55w0rd-x@${REMOTE}:${P_RTSP}/mic1"

        # wrong password, another user's password, an unknown user, the hash
        # itself: 401
        local url
        for url in "alice:wrong" "alice:Pa55w0rd-x" "mallory:alice-pw" "alice:sha256"; do
            ! mtx_can_read "rtsp://${url}@${REMOTE}:${P_RTSP}/mic1"
            grep -q '401' "$TEST_SCRATCH/read.err"
        done

        # a read-only user cannot publish, here or from anywhere else
        ! mtx_publish_once "rtsp://alice:alice-pw@${REMOTE}:${P_RTSP}/other"
        grep -q '401' "$TEST_SCRATCH/publish-once.log"

        # the API is not reachable from outside (bound to loopback)
        [ "$(mtx_http_status "http://${REMOTE}:${P_API}/v3/paths/list")" = 000 ]
        [ "$(mtx_http_status "http://127.0.0.1:${P_API}/v3/paths/list")" = 200 ]
        mtx_unpublish
        mtx_stop
    done
}

@test "RTSP_AUTH_MODE=local-only-publish: the manager's own readiness and stream probes keep working on every version, with no credentials [LB-06, LB-13]" {
    require_live
    local bin rc
    for bin in $LYREBIRD_TEST_MEDIAMTX_BINS; do
        each_binary_begin "$bin"
        make_users_file alice:alice-pw
        rm -rf "$TEST_SCRATCH/mg"
        manager_generate "$TEST_SCRATCH/mg" "$bin" RTSP_AUTH_MODE=local-only-publish RTSP_USERS_FILE="$TEST_SCRATCH/users.conf" >/dev/null
        mtx_start "$bin" "$TEST_SCRATCH/mg/cfg/mediamtx.yml"
        mtx_publish "rtsp://127.0.0.1:${P_RTSP}/mic1"
        mtx_wait_path_ready mic1
        run env MEDIAMTX_HOST=127.0.0.1 MEDIAMTX_API_PORT="$P_API" MEDIAMTX_LOG_FILE="$TEST_SCRATCH/sm.log" MEDIAMTX_API_TIMEOUT=5 \
            bash -c 'source "$1" >/dev/null 2>&1; set +e; wait_for_mediamtx_ready "$2"' _ "$PROJECT_ROOT/lyrebird-stream-manager.sh" "$MTX_PID"
        [ "$status" -eq 0 ]
        ! grep -q 'requires credentials' "$TEST_SCRATCH/sm.log"
        rc=0
        env MEDIAMTX_HOST=127.0.0.1 MEDIAMTX_API_PORT="$P_API" MEDIAMTX_LOG_FILE="$TEST_SCRATCH/sm.log" \
            bash -c 'source "$1" >/dev/null 2>&1; set +e; probe_stream_ready mic1' _ "$PROJECT_ROOT/lyrebird-stream-manager.sh" || rc=$?
        [ "$rc" -eq 0 ]
        mtx_unpublish
        mtx_stop
    done
}

@test "an API bound to every interface under local-only-publish still answers 401 to a remote caller, the local machine keeps its access [LB-06]" {
    require_live
    require_remote_address
    local bin
    for bin in $LYREBIRD_TEST_MEDIAMTX_BINS; do
        each_binary_begin "$bin"
        make_users_file alice:alice-pw
        rm -rf "$TEST_SCRATCH/mg"
        manager_generate "$TEST_SCRATCH/mg" "$bin" RTSP_AUTH_MODE=local-only-publish RTSP_USERS_FILE="$TEST_SCRATCH/users.conf" \
            MEDIAMTX_API_BIND= MEDIAMTX_METRICS_BIND= >/dev/null
        mtx_start "$bin" "$TEST_SCRATCH/mg/cfg/mediamtx.yml"
        [ "$(mtx_http_status "http://127.0.0.1:${P_API}/v3/paths/list")" = 200 ]
        [ "$(mtx_http_status "http://127.0.0.1:${P_METRICS}/metrics")" = 200 ]
        [ "$(mtx_http_status "http://${REMOTE}:${P_API}/v3/paths/list")" = 401 ]
        # even a listed RTSP user has no right to the API or the metrics
        [ "$(mtx_http_status "http://${REMOTE}:${P_API}/v3/paths/list" -u alice:alice-pw --max-time 15)" = 401 ]
        [ "$(mtx_http_status "http://${REMOTE}:${P_METRICS}/metrics" -u alice:alice-pw --max-time 15)" = 401 ] || {
            echo "metrics from ${REMOTE} as alice: $(mtx_http_status "http://${REMOTE}:${P_METRICS}/metrics" -u alice:alice-pw --max-time 15)"
            grep -n 'metricsAddress' "$TEST_SCRATCH/mg/cfg/mediamtx.yml"
            false
        }
        mtx_stop
    done
}

# Run the real generate_mediamtx_config (the manager's own validation, with
# this binary) in a private configuration directory $1; $2... are environment
# assignments. Prints its messages; the status is generate's.
manager_generate() {
    local dir="$1" bin="$2"
    shift 2
    mkdir -p "$dir/cfg" "$dir/ff"
    env "$@" MEDIAMTX_BINARY="$bin" MEDIAMTX_CONFIG_DIR="$dir/cfg" MEDIAMTX_FFMPEG_DIR="$dir/ff" \
        MEDIAMTX_PID_FILE="$dir/p" MEDIAMTX_LOCK_FILE="$dir/l" MEDIAMTX_LOG_FILE="$dir/log" \
        MEDIAMTX_RTSP_PORT="$P_RTSP" MEDIAMTX_API_PORT="$P_API" MEDIAMTX_METRICS_PORT="$P_METRICS" \
        bash -c 'source "$1" >/dev/null 2>&1; set +e; generate_mediamtx_config' _ "$PROJECT_ROOT/lyrebird-stream-manager.sh" 2>&1
}

@test "the manager validates a configuration with MediaMTX's own check where the binary has one, and says what the structural check cannot see [LB-22]" {
    require_live
    local bin dir validates
    for bin in $LYREBIRD_TEST_MEDIAMTX_BINS; do
        each_binary_begin "$bin"
        dir="$TEST_SCRATCH/mg"
        rm -rf "$dir"
        validates=false
        "$bin" --help 2>&1 | grep -q -- '--validate-conf' && validates=true

        # what it renders is accepted, and is the file MediaMTX then runs on
        manager_generate "$dir" "$bin" >"$TEST_SCRATCH/gen.out" || {
            cat "$TEST_SCRATCH/gen.out"
            false
        }
        [ "$(head -n 1 "$dir/cfg/mediamtx.yml")" = "# Managed by LyreBirdAudio" ]
        if $validates; then
            "$bin" --validate-conf="$dir/cfg/mediamtx.yml" >/dev/null
        fi
        mtx_start "$bin" "$dir/cfg/mediamtx.yml"
        mtx_stop

        # a path name MediaMTX refuses: stopped before the file is replaced where
        # the binary can say so; otherwise MediaMTX refuses at start
        rm -rf "$dir"
        if $validates; then
            ! manager_generate "$dir" "$bin" STREAM_MODE=multiplex MULTIPLEX_STREAM_NAME="Studio Mix" >"$TEST_SCRATCH/gen.out"
            grep -q "invalid path name 'Studio Mix'" "$TEST_SCRATCH/gen.out" || {
                cat "$TEST_SCRATCH/gen.out"
                false
            }
            [ ! -e "$dir/cfg/mediamtx.yml" ]
        else
            manager_generate "$dir" "$bin" STREAM_MODE=multiplex MULTIPLEX_STREAM_NAME="Studio Mix" >/dev/null
            ! (cd "$TEST_SCRATCH" && timeout 10 "$bin" "$dir/cfg/mediamtx.yml") >/dev/null 2>&1
        fi

        # an operator's file with a key MediaMTX does not know
        rm -rf "$dir"
        mkdir -p "$dir/cfg"
        printf 'logLevel: info\nbogusKey: 1\n' >"$dir/cfg/mediamtx.yml"
        if $validates; then
            ! manager_generate "$dir" "$bin" >"$TEST_SCRATCH/gen.out"
            grep -q 'unknown field "bogusKey"' "$TEST_SCRATCH/gen.out"
        else
            # no validator in this MediaMTX: the structural check passes it, and
            # MediaMTX itself refuses to start on it
            manager_generate "$dir" "$bin" >/dev/null
            ! (cd "$TEST_SCRATCH" && timeout 10 "$bin" "$dir/cfg/mediamtx.yml") >/dev/null 2>&1
        fi
    done
}

@test "every option of the renderer produces a configuration MediaMTX accepts and honours [LB-22]" {
    require_live
    local bin
    for bin in $LYREBIRD_TEST_MEDIAMTX_BINS; do
        each_binary_begin "$bin"

        # API and metrics off: nothing listens on their ports
        mtx_render "$bin" --api no --metrics no
        MTX_WAIT_PORT="$P_RTSP" mtx_start "$bin" "$TEST_SCRATCH/mediamtx.yml"
        [ "$(mtx_listeners "$MTX_PID" | grep -c "tcp ")" -eq 1 ]
        mtx_stop

        # RTSP on the loopback address only
        mtx_render "$bin" --rtsp-bind 127.0.0.1
        mtx_start "$bin" "$TEST_SCRATCH/mediamtx.yml"
        mtx_listeners "$MTX_PID" | grep -qx "tcp 127.0.0.1:${P_RTSP}"
        mtx_stop

        # every log level, timeouts in each unit, an explicit all-interface API
        local level
        for level in error warn info debug; do
            mtx_render "$bin" --log-level "$level" --read-timeout 500ms --write-timeout 2m --api-bind 0.0.0.0
            mtx_start "$bin" "$TEST_SCRATCH/mediamtx.yml"
            mtx_listeners "$MTX_PID" | grep -qx "tcp 0.0.0.0:${P_API}"
            mtx_stop
        done

        # IPv6 literals, where the machine has IPv6
        if python3 -I -c 'import socket; socket.socket(socket.AF_INET6).bind(("::1", 0))' 2>/dev/null; then
            mtx_render "$bin" --api-bind ::1 --metrics-bind ::1
            mtx_start "$bin" "$TEST_SCRATCH/mediamtx.yml"
            [ "$(mtx_http_status "http://[::1]:${P_API}/v3/paths/list")" = 200 ]
            mtx_stop
        fi
    done
}
