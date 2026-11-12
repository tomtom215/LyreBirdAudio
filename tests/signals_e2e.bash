# shellcheck shell=bash
# The stream manager's audio level signals against a REAL MediaMTX and real
# FFmpeg publishers, in a private network namespace (tests/test_mediamtx_live.bats
# runs this file).
#
# It runs inside
#   unshare --net --pid --fork --mount-proc bash tests/signals_e2e.bash
# as root, so the default ports (8554, 9997, 9998) are bound in a namespace of
# their own and the host's are never touched; every process started here dies
# with the namespace's init.
#
# Environment: PROJECT_ROOT (the checkout), BIN (a MediaMTX binary), WORK (an
# empty scratch directory), OWNER (optional "uid:gid" the files go back to).
#
# What is real: MediaMTX with the configuration the manager generates, the
# manager's probe_stream_level / probe_stream_ready / monitor_signals (each call
# in a fresh process, as the monitor runs them) and the FFmpeg that measures.
# What stands in for the hardware: FFmpeg publishers fed by lavfi sources (a
# 440 Hz tone, digital silence), and one long-lived `sleep` per stream as the
# wrapper whose PID file makes the manager treat the stream as its own.
#
# Prints "E2E: ..." progress lines and, on the first violated expectation,
# "E2E-FAIL: ..." and exits 1.

set -u
fail() {
    echo "E2E-FAIL: $*"
    exit 1
}
note() { echo "E2E: $*"; }

trap '[[ -z "${OWNER:-}" ]] || chown -R "$OWNER" "$WORK" 2>/dev/null' EXIT

# --- loopback up (no `ip` needed) -------------------------------------------
python3 -I - <<'PY' || fail "cannot bring the loopback interface up"
import fcntl, socket, struct
s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
flags = struct.unpack('16sH', fcntl.ioctl(s.fileno(), 0x8913, struct.pack('16sH', b'lo', 0)))[1]
fcntl.ioctl(s.fileno(), 0x8914, struct.pack('16sH', b'lo', flags | 1))
PY

REAL_FFMPEG="$(command -v ffmpeg)"
mkdir -p "$WORK"/{cfg,ff,bin,state}
CODEC=aac
"$REAL_FFMPEG" -hide_banner -encoders 2>/dev/null | grep -q libopus && CODEC=libopus

# An ffmpeg first on the manager's PATH that records its arguments, then runs
# the real one: the arguments of every probe are checked at the end
cat >"$WORK/bin/ffmpeg" <<SHIM
#!/bin/bash
printf '%s\n' "\$*" >>"$WORK/ffmpeg.calls"
exec "$REAL_FFMPEG" "\$@"
SHIM
chmod +x "$WORK/bin/ffmpeg"
: >"$WORK/ffmpeg.calls"

export MEDIAMTX_BINARY="$BIN" MEDIAMTX_CONFIG_DIR="$WORK/cfg" MEDIAMTX_FFMPEG_DIR="$WORK/ff"
export MEDIAMTX_PID_FILE="$WORK/mtx.pid" MEDIAMTX_LOCK_FILE="$WORK/run.lock" MEDIAMTX_LOG_FILE="$WORK/sm.log"
export MEDIAMTX_RESTART_MARKER="$WORK/restart.marker" MEDIAMTX_CLEANUP_MARKER="$WORK/cleanup.marker"
export SILENCE_STATE_DIR="$WORK/state" CRON_RESTART_STATE_DIR="$WORK/cron" DEEP_HEALTH_STATE_DIR="$WORK/deep"
export HEARTBEAT_FILE="$WORK/heartbeat"
export MEDIAMTX_HOST=127.0.0.1 PROJECT_ROOT WORK
# One second of sound per probe; DEAD MIC after four seconds of silence; every
# monitor run probes (the interval rule has its own unit tests)
export AUDIO_LEVEL_CHECK_ENABLED=true AUDIO_LEVEL_SAMPLE_DURATION=1 AUDIO_LEVEL_PROBE_GRACE=8
export AUDIO_LEVEL_CHECK_INTERVAL=0 AUDIO_SILENCE_WARN_DURATION=4 AUDIO_SILENCE_THRESHOLD_DB=-60

# One call of the real script in a fresh process (as the monitor runs it)
sig() {
    PATH="$WORK/bin:$PATH" bash -c 'source "$PROJECT_ROOT/lyrebird-stream-manager.sh"; "$@"' _ "$@" 2>>"$WORK/sig.err"
}

count_log() { grep -c -- "$1" "$WORK/sm.log" 2>/dev/null || true; }

# --- MediaMTX with the manager's generated configuration -------------------------
sig generate_mediamtx_config >/dev/null || {
    cat "$WORK/sig.err"
    fail "the manager could not generate the MediaMTX configuration"
}
"$BIN" "$WORK/cfg/mediamtx.yml" >"$WORK/mtx.log" 2>&1 &
MTX=$!
for _ in $(seq 100); do
    curl -s --max-time 1 http://127.0.0.1:9997/v3/paths/list >/dev/null && break
    kill -0 "$MTX" 2>/dev/null || {
        cat "$WORK/mtx.log"
        fail "MediaMTX did not start"
    }
    sleep 0.1
done
note "MediaMTX is up ($("$BIN" --version 2>/dev/null | head -n 1))"

# wrapper NAME: the long-lived process whose PID file marks NAME as a stream of this manager
wrapper() {
    sleep 3000 &
    echo "$!" >"$WORK/ff/$1.pid"
}
# pub NAME SOURCE: an FFmpeg publisher for NAME fed by the lavfi source SOURCE
pub() {
    "$REAL_FFMPEG" -nostdin -loglevel error -re -f lavfi -i "$2" -c:a "$CODEC" \
        -f rtsp -rtsp_transport tcp "rtsp://127.0.0.1:8554/$1" >>"$WORK/pub.log" 2>&1 &
    echo "$!" >"$WORK/pub.$1"
}
unpub() {
    local pid
    pid="$(cat "$WORK/pub.$1" 2>/dev/null)" || return 0
    kill "$pid" 2>/dev/null
    wait "$pid" 2>/dev/null
    rm -f "$WORK/pub.$1"
}
# wait_ready NAME RC: probe_stream_ready NAME returns RC (at most 15 s)
wait_ready() {
    local i rc
    for ((i = 0; i < 60; i++)); do
        rc=0
        sig probe_stream_ready "$1" >/dev/null || rc=$?
        [[ "$rc" == "$2" ]] && return 0
        sleep 0.25
    done
    return 1
}
TONE="sine=frequency=440:sample_rate=48000"
SILENCE="anullsrc=r=48000:cl=stereo"

# --- (a) a tone is ok, (b) digital silence is silent ---------------------------------
wrapper tone
pub tone "$TONE"
wait_ready tone 0 || fail "the tone stream never became ready"
V="$(sig probe_stream_level tone)"
note "tone    -> $V"
[[ "$V" == ok\ * ]] || fail "a 440 Hz tone was classified '$V', expected ok"

wrapper quiet
pub quiet "$SILENCE"
wait_ready quiet 0 || fail "the silent stream never became ready"
V="$(sig probe_stream_level quiet)"
note "silence -> $V"
[[ "$V" == silent\ * ]] || fail "digital silence was classified '$V', expected silent"
[[ "$V" == "silent -91.0 -91.0"* ]] || note "(silence measured differently from -91.0 on this FFmpeg: $V)"

# --- (d) a stream nobody publishes is unreachable, never silent ----------------------
unpub tone
wait_ready tone 1 || fail "the stopped publisher's path stayed ready"
V="$(sig probe_stream_level tone)"
note "stopped -> $V"
[[ "$V" == unreachable\ * ]] || fail "a stream with no publisher was classified '$V', expected unreachable"
V="$(sig probe_stream_level nosuchstream)"
[[ "$V" == unreachable\ * ]] || fail "an unknown path was classified '$V', expected unreachable"
: >"$WORK/ffmpeg.calls"
sig monitor_signals
! grep -q "tone" "$WORK/ffmpeg.calls" || fail "monitor_signals opened a reader on a path that is not ready"
unpub quiet
rm -f "$WORK/state"/*.state "$WORK/ff/quiet.pid" "$WORK/ff/tone.pid"

# --- (c) tone, then silence, then the tone again ---------------------------------------
: >"$WORK/sm.log"
wrapper mix
pub mix "$TONE"
wait_ready mix 0 || fail "mix never became ready (tone)"
sig monitor_signals
[[ "$(count_log 'Silence detected on mix')" == 0 ]] || fail "silence was reported for a tone"
note "mix: tone, no silence reported"

unpub mix
pub mix "$SILENCE"
wait_ready mix 0 || fail "mix never became ready again (silence)"
sig monitor_signals
[[ "$(count_log 'Silence detected on mix')" == 1 ]] || fail "the first silent probe did not start an episode"
[[ "$(count_log 'DEAD MIC: mix')" == 0 ]] || fail "DEAD MIC was raised before the silence lasted AUDIO_SILENCE_WARN_DURATION"
note "mix: silence episode started, no DEAD MIC yet"
sleep 5
sig monitor_signals
[[ "$(count_log 'DEAD MIC: mix')" == 1 ]] || {
    cat "$WORK/sm.log"
    fail "DEAD MIC was not raised after the silence lasted longer than AUDIO_SILENCE_WARN_DURATION"
}
sig monitor_signals
sig monitor_signals
[[ "$(count_log 'DEAD MIC: mix')" == 1 ]] || fail "DEAD MIC was raised more than once for one episode"
note "mix: DEAD MIC raised once for the episode"

# (d) again, inside the episode: the publisher drops out; the episode is neither ended nor alerted again
unpub mix
wait_ready mix 1 || fail "mix stayed ready after its publisher stopped"
sig monitor_signals
[[ "$(count_log 'DEAD MIC: mix')" == 1 && "$(count_log 'Audio recovered on mix')" == 0 ]] || fail "an unreachable stream ended or repeated the episode"

pub mix "$TONE"
wait_ready mix 0 || fail "mix never became ready again (tone)"
sig monitor_signals
[[ "$(count_log 'Audio recovered on mix')" == 1 ]] || {
    cat "$WORK/sm.log"
    fail "the tone's return did not end the episode"
}
note "mix: the tone's return ended the episode"

unpub mix
pub mix "$SILENCE"
wait_ready mix 0 || fail "mix never became ready again (silence, second episode)"
sig monitor_signals
sleep 5
sig monitor_signals
[[ "$(count_log 'DEAD MIC: mix')" == 2 ]] || fail "a second episode did not raise its own DEAD MIC (got $(count_log 'DEAD MIC: mix') in total)"
note "mix: the second episode raised its own DEAD MIC"
unpub mix

# --- (e) a failing measurement is probe_error and is never counted as silence -------------
mkdir -p "$WORK/badbin"
cat >"$WORK/badbin/ffmpeg" <<'SHIM'
#!/bin/bash
echo "Segmentation garbage ::: not an ffmpeg report"
exit 3
SHIM
chmod +x "$WORK/badbin/ffmpeg"
: >"$WORK/sm.log"
wrapper shimmed
pub shimmed "$SILENCE"
wait_ready shimmed 0 || fail "shimmed never became ready"
V="$(PATH="$WORK/badbin:$PATH" bash -c 'source "$PROJECT_ROOT/lyrebird-stream-manager.sh"; probe_stream_level shimmed' 2>/dev/null)"
note "garbage ffmpeg -> $V"
[[ "$V" == probe_error\ * ]] || fail "a failing ffmpeg was classified '$V', expected probe_error"
for _ in 1 2 3; do
    PATH="$WORK/badbin:$PATH" bash -c 'source "$PROJECT_ROOT/lyrebird-stream-manager.sh"; monitor_signals' 2>/dev/null
    sleep 2
done
[[ "$(count_log 'Silence detected on shimmed')" == 0 && "$(count_log 'DEAD MIC: shimmed')" == 0 ]] || {
    cat "$WORK/sm.log"
    fail "a failing probe tool was counted as silence"
}
[[ "$(count_log 'failed, not counted as silence')" -ge 1 ]] || fail "the failing probe was not reported"
sig monitor_signals
[[ "$(count_log 'Silence detected on shimmed')" == 1 ]] || fail "the real probe did not see the silence after the failing ones"
note "shimmed: probe_error is reported and never counted; the real probe still sees the silence"
unpub shimmed

# --- the probe never opens an ALSA device -----------------------------------------------
! grep -E -q 'alsa|plughw|hw:|/dev/snd' "$WORK/ffmpeg.calls" || {
    grep -E 'alsa|plughw|hw:|/dev/snd' "$WORK/ffmpeg.calls"
    fail "a probe opened an ALSA device"
}
grep -q "rtsp://127.0.0.1:8554/" "$WORK/ffmpeg.calls" || fail "no probe read the stream over RTSP"
grep -q -- "-af volumedetect" "$WORK/ffmpeg.calls" || fail "no probe used volumedetect"
note "$(grep -c rtsp "$WORK/ffmpeg.calls") probe(s) read RTSP; none opened an ALSA device"

kill "$MTX" 2>/dev/null
note "DONE"
