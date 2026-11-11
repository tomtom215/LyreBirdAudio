#!/usr/bin/env bats
# X-14 (recorder interaction): emergency cleanup of the segment ring buffer.
#
# The recorder (lyrebird-stream-manager.sh) writes AUDIO_RECORDING_PATH/<stream>/
# audio_NNN.<codec> through FFmpeg's tee + segment muxer and creates the stream
# directory once, when the stream starts. emergency_cleanup used to run
# `rm -rf "$BUFFER_DIR"/*`, which removes those directories: FFmpeg then logs
# "Failed to open segment ... No such file or directory, continuing with 1/2
# slaves", drops its recording leg and records nothing until the stream is
# restarted, while the RTSP leg keeps running, so nothing looks wrong.

load scratch_tmpdir
load storage_helper

setup() {
    scratch_setup
    storage_setup
}

teardown() {
    storage_teardown
    scratch_teardown
}

_age() { touch -d "${2:-2 hours ago}" "$1"; }

@test "emergency cleanup empties the ring buffer's files but keeps the stream directories [X-14 regression]" {
    mkdir -p "$ST_BUF/stream1" "$ST_BUF/stream2/nested"
    local f
    for f in stream1/audio_000.opus stream1/audio_001.opus stream2/audio_000.aac stream2/nested/x.raw top.mp3; do
        echo data >"$ST_BUF/$f"
        _age "$ST_BUF/$f"
    done
    run storage_run emergency_cleanup
    [ "$status" -eq 0 ]
    [[ "$output" == *"Deleted 5 buffer file(s)"* ]]
    [[ "$output" != *"FAILED"* ]]
    [ -d "$ST_BUF/stream1" ]
    [ -d "$ST_BUF/stream2/nested" ]
    run find "$ST_BUF" -type f
    [ -z "$output" ] || { echo "left: $output"; return 1; }
}

@test "emergency cleanup leaves the open ring-buffer segment alone [X-14 regression]" {
    mkdir -p "$ST_BUF/stream1"
    echo data >"$ST_BUF/stream1/audio_000.opus"
    _age "$ST_BUF/stream1/audio_000.opus"
    : >"$ST_BUF/stream1/audio_001.opus"                  # being written: 0 bytes, fresh
    run storage_run emergency_cleanup
    [ "$status" -eq 0 ]
    [ ! -e "$ST_BUF/stream1/audio_000.opus" ]
    [ -e "$ST_BUF/stream1/audio_001.opus" ]
    [[ "$output" == *"Left 1 buffer file(s) written in the last 900s alone"* ]]
}

@test "a dry run lists the buffer files it would delete and deletes nothing [X-14]" {
    mkdir -p "$ST_BUF/stream1"
    echo data >"$ST_BUF/stream1/audio_000.opus"
    _age "$ST_BUF/stream1/audio_000.opus"
    ST_ENV=(DRY_RUN=true)
    run storage_run emergency_cleanup
    [ "$status" -eq 0 ]
    [[ "$output" == *"Would delete emergency buffer file: $ST_BUF/stream1/audio_000.opus"* ]]
    [ -f "$ST_BUF/stream1/audio_000.opus" ]
}

@test "symlinks inside the buffer are not followed and their targets survive [X-14]" {
    mkdir -p "$ST_BUF/stream1"
    echo precious >"$ST_OUTSIDE/victim.opus"
    mkdir -p "$ST_OUTSIDE/dir"
    echo precious >"$ST_OUTSIDE/dir/old.opus"
    _age "$ST_OUTSIDE/victim.opus"
    _age "$ST_OUTSIDE/dir/old.opus"
    ln -s "$ST_OUTSIDE/victim.opus" "$ST_BUF/stream1/audio_000.opus"
    ln -s "$ST_OUTSIDE/dir" "$ST_BUF/linkdir"
    run storage_run emergency_cleanup
    [ "$status" -eq 0 ]
    [ -f "$ST_OUTSIDE/victim.opus" ]
    [ -f "$ST_OUTSIDE/dir/old.opus" ]
}

# The interaction itself, with a real FFmpeg: an emergency run in the middle of a
# recording must not stop the recording.
@test "FFmpeg keeps recording into the buffer after an emergency cleanup [X-14 regression]" {
    command -v ffmpeg >/dev/null 2>&1 || skip "ffmpeg not installed"
    ffmpeg -hide_banner -loglevel error -nostdin -f lavfi -i "sine=duration=0.2" -c:a libopus -f null - 2>/dev/null \
        || skip "this ffmpeg has no libopus"
    mkdir -p "$ST_BUF/s1"
    ffmpeg -hide_banner -loglevel error -nostdin -re -f lavfi -i "sine=frequency=440:duration=11" \
        -ar 48000 -ac 2 -c:a libopus -b:a 64k -application audio -f tee -map 0:a \
        "[f=segment:segment_time=3:segment_wrap=12:strftime=0]$ST_BUF/s1/audio_%03d.opus|[f=null]-" \
        2>"$ST_ROOT/ffmpeg.err" &
    local pid=$!
    sleep 4.5                                            # segment 000 closed, 001 open
    [ -s "$ST_BUF/s1/audio_000.opus" ]
    _age "$ST_BUF/s1/audio_000.opus"                     # a completed, idle segment

    run storage_run emergency_cleanup
    [ "$status" -eq 0 ]
    [ ! -e "$ST_BUF/s1/audio_000.opus" ]                 # the idle segment was evicted
    [ -d "$ST_BUF/s1" ]                                  # the directory FFmpeg writes into was not

    wait "$pid"
    [ -s "$ST_BUF/s1/audio_002.opus" ] || { cat "$ST_ROOT/ffmpeg.err"; ls -l "$ST_BUF/s1"; return 1; }
    [ -s "$ST_BUF/s1/audio_001.opus" ]                   # the open segment survived the cleanup
    ! grep -q 'Failed to open segment' "$ST_ROOT/ffmpeg.err" || false
}
