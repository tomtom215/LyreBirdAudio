#!/usr/bin/env bats
# X-14: zero-byte, truncated and in-progress recording segments.
#
# What FFmpeg 6.1.1 really leaves (the manager's tee + segment muxer, measured):
#  - the segment being written is a 0-byte file whose mtime stays at its
#    creation time until the first 256 KiB chunk is flushed (16 s at 128 kb/s);
#  - a hard-killed FFmpeg (crash, power cut for the process) leaves that
#    in-progress segment at 0 bytes, or cut at a 256 KiB boundary: such a
#    truncated Opus file still decodes (15 s of a 16 s span in the probe);
#  - a muxer that refuses the stream (CODEC=flac/m4a/adts/wav on top of the
#    manager's libopus fallback) leaves audio_000.<ext> at 0 bytes (20 bytes
#    for wav) and the RTSP leg carries on.
# So an empty file is debris only once it has been idle for ACTIVE_SEGMENT_SECONDS;
# a younger one, and anything recently modified, is a live stream; a truncated
# non-empty segment is audio and is kept like any other recording.

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

_make() { # _make FILE AGE [BYTES]: file of BYTES (default 0) last modified AGE ago
    mkdir -p "$(dirname "$1")"
    if [ "${3:-0}" -gt 0 ]; then
        head -c "$3" /dev/zero | tr '\0' 'x' >"$1"
    else
        : >"$1"
    fi
    touch -d "$2" "$1"
}

# --- retention (cleanup_recordings) ---------------------------------------------

@test "retention removes an idle empty segment long before the retention period [X-14 regression]" {
    _make "$ST_REC/s1/audio_003.opus" "2 hours ago"
    _make "$ST_REC/s1/audio_004.aac" "2 days ago"
    _make "$ST_REC/s1/audio_005.opus" "2 hours ago" 2000     # same age, holds audio
    run storage_run cleanup_recordings
    [ "$status" -eq 0 ]
    [ ! -e "$ST_REC/s1/audio_003.opus" ]
    [ ! -e "$ST_REC/s1/audio_004.aac" ]
    [ -f "$ST_REC/s1/audio_005.opus" ]
    [[ "$output" == *"Removed 2 empty recording segment(s)"* ]]
}

@test "retention keeps an empty segment younger than ACTIVE_SEGMENT_SECONDS (it is being opened) [X-14]" {
    _make "$ST_REC/s1/audio_000.opus" "5 minutes ago"
    _make "$ST_REC/s1/audio_001.opus" "0 seconds ago"
    run storage_run cleanup_recordings
    [ "$status" -eq 0 ]
    [ -e "$ST_REC/s1/audio_000.opus" ]
    [ -e "$ST_REC/s1/audio_001.opus" ]
}

@test "the empty-segment grace period follows LYREBIRD_ACTIVE_SEGMENT_SECONDS and cannot be set below 60 s [X-14]" {
    _make "$ST_REC/a/audio_000.opus" "2 minutes ago"
    _make "$ST_REC/a/audio_001.opus" "20 seconds ago"
    ST_ENV=(LYREBIRD_ACTIVE_SEGMENT_SECONDS=90)
    run storage_run cleanup_recordings
    [ ! -e "$ST_REC/a/audio_000.opus" ]       # older than 90 s
    [ -e "$ST_REC/a/audio_001.opus" ]         # younger than 90 s

    _make "$ST_REC/b/audio_000.opus" "20 seconds ago"
    ST_ENV=(LYREBIRD_ACTIVE_SEGMENT_SECONDS=0)
    run storage_run cleanup_recordings
    [ -e "$ST_REC/b/audio_000.opus" ]         # 0 is floored to 60 s, not "no protection"

    ST_ENV=(LYREBIRD_ACTIVE_SEGMENT_SECONDS=banana)
    run storage_run cleanup_recordings
    [ -e "$ST_REC/b/audio_000.opus" ]         # non-numeric falls back to the 900 s default
}

@test "retention keeps an empty segment whose mtime predates the clock-sanity epoch (real age unknown) [X-14]" {
    _make "$ST_REC/s1/audio_000.opus" "@1000000"
    run storage_run cleanup_recordings
    [ "$status" -eq 0 ]
    [ -e "$ST_REC/s1/audio_000.opus" ]
}

@test "the empty-segment sweep waits for a sane clock like the rest of age-based cleanup [X-14]" {
    _make "$ST_REC/s1/audio_000.opus" "2 hours ago"
    mkdir -p "$ST_ROOT/bin"
    printf '#!/bin/bash\nif [[ "${1:-}" == "+%%s" ]]; then echo 1000; else exec /bin/date "$@"; fi\n' >"$ST_ROOT/bin/date"
    chmod +x "$ST_ROOT/bin/date"
    ST_ENV=(PATH="$ST_ROOT/bin:$PATH")
    run storage_run cleanup_recordings
    [ "$status" -eq 0 ]
    [ -e "$ST_REC/s1/audio_000.opus" ]
    [[ "$output" == *"skipping age-based"* ]]
}

@test "retention only removes empty files that are recordings [X-14]" {
    _make "$ST_REC/s1/.keep" "2 days ago"
    _make "$ST_REC/s1/audio.lock" "2 days ago"
    _make "$ST_REC/s1/audio_000.opus.part" "2 days ago"
    _make "$ST_REC/s1/audio_000.opus" "2 days ago"
    run storage_run cleanup_recordings
    [ "$status" -eq 0 ]
    [ -e "$ST_REC/s1/.keep" ]
    [ -e "$ST_REC/s1/audio.lock" ]
    [ -e "$ST_REC/s1/audio_000.opus.part" ]
    [ ! -e "$ST_REC/s1/audio_000.opus" ]
}

@test "a truncated, non-empty segment is kept by retention until it is genuinely old [X-14]" {
    # A killed FFmpeg leaves a prefix cut at a flush boundary; it still decodes.
    _make "$ST_REC/s1/audio_002.opus" "2 hours ago" 100
    _make "$ST_REC/s1/audio_003.aac" "20 days ago" 1
    _make "$ST_REC/s1/audio_004.mp3" "45 days ago" 100
    run storage_run cleanup_recordings
    [ "$status" -eq 0 ]
    [ -f "$ST_REC/s1/audio_002.opus" ]
    [ -f "$ST_REC/s1/audio_003.aac" ]
    [ ! -e "$ST_REC/s1/audio_004.mp3" ]       # past retention like any other recording
}

@test "a dry run lists the empty segments retention would remove and deletes nothing [X-14]" {
    _make "$ST_REC/s1/audio_003.opus" "2 hours ago"
    ST_ENV=(DRY_RUN=true)
    run storage_run cleanup_recordings
    [ "$status" -eq 0 ]
    [[ "$output" == *"Would delete empty recording segment"*"audio_003.opus"* ]]
    [ -e "$ST_REC/s1/audio_003.opus" ]
}

# --- emergency eviction -----------------------------------------------------------

@test "emergency eviction removes idle empty segments first, even when newer than every recording [X-14 regression]" {
    local i
    for i in $(seq 1 101); do
        _make "$ST_REC/s1/seg_$(printf '%03d' "$i").opus" "@$((1700000000 + i))" 10
    done
    _make "$ST_REC/s1/empty_a.opus" "2 days ago"
    _make "$ST_REC/s1/empty_b.aac" "3 hours ago"
    run storage_run emergency_cleanup
    [ "$status" -eq 0 ]
    [ ! -e "$ST_REC/s1/empty_a.opus" ]         # pre-fix: newer than the recordings, so kept
    [ ! -e "$ST_REC/s1/empty_b.aac" ]
    [[ "$output" == *"Deleted 2 empty segment(s)"* ]]
    [[ "$output" == *"Deleted 100 oldest recording(s)"* ]]
    [ -f "$ST_REC/s1/seg_101.opus" ]           # 101 recordings, 100 evicted: the newest stays
    [ ! -e "$ST_REC/s1/seg_100.opus" ]
}

@test "empty segments do not use up the eviction budget for recordings [X-14]" {
    local i
    for i in $(seq 1 101); do
        _make "$ST_REC/s1/empty_$(printf '%03d' "$i").opus" "2 hours ago"
    done
    for i in 1 2 3; do
        _make "$ST_REC/s1/data_$i.opus" "3 hours ago" 10
    done
    run storage_run emergency_cleanup
    [ "$status" -eq 0 ]
    [[ "$output" == *"Deleted 100 empty segment(s)"* ]]
    [[ "$output" == *"Deleted 3 oldest recording(s)"* ]]
    run find "$ST_REC" -type f -printf '.'
    [ "$output" = "." ]                          # one empty segment is left for the next run
}

@test "emergency eviction never touches files written within ACTIVE_SEGMENT_SECONDS [X-14 regression]" {
    # An active stream: completed older segments, the one being written (empty
    # until its first flush) and a just-flushed one.
    _make "$ST_REC/live/audio_000.opus" "40 minutes ago" 5000
    _make "$ST_REC/live/audio_001.opus" "20 minutes ago" 5000
    _make "$ST_REC/live/audio_002.opus" "30 seconds ago" 262144
    _make "$ST_REC/live/audio_003.opus" "10 seconds ago"
    run storage_run emergency_cleanup
    [ "$status" -eq 0 ]
    [ ! -e "$ST_REC/live/audio_000.opus" ]
    [ ! -e "$ST_REC/live/audio_001.opus" ]
    [ -f "$ST_REC/live/audio_002.opus" ]       # pre-fix: deleted while FFmpeg wrote to it
    [ -e "$ST_REC/live/audio_003.opus" ]
    [[ "$output" == *"Left 2 file(s) written in the last 900s alone"* ]]
}

@test "emergency eviction does evict the newest segment of a stream that has stopped [X-14]" {
    _make "$ST_REC/dead/audio_000.opus" "3 hours ago" 5000
    _make "$ST_REC/dead/audio_001.opus" "2 hours ago" 5000       # newest, but idle
    _make "$ST_REC/dead/audio_002.opus" "2 hours ago"            # crashed mid-open, idle
    run storage_run emergency_cleanup
    [ "$status" -eq 0 ]
    [ ! -e "$ST_REC/dead/audio_000.opus" ]
    [ ! -e "$ST_REC/dead/audio_001.opus" ]
    [ ! -e "$ST_REC/dead/audio_002.opus" ]
}

@test "the emergency protection window follows LYREBIRD_ACTIVE_SEGMENT_SECONDS [X-14]" {
    _make "$ST_REC/s1/audio_000.opus" "2 minutes ago" 100
    _make "$ST_REC/s1/audio_001.opus" "20 seconds ago" 100
    ST_ENV=(LYREBIRD_ACTIVE_SEGMENT_SECONDS=90)
    run storage_run emergency_cleanup
    [ ! -e "$ST_REC/s1/audio_000.opus" ]
    [ -e "$ST_REC/s1/audio_001.opus" ]
}

@test "a file stamped far in the future is not mistaken for an active write [X-14]" {
    # The clock was ahead when it was written and has since been corrected.
    _make "$ST_REC/s1/future.opus" "1 year" 100
    _make "$ST_REC/s1/soon.opus" "2 minutes" 100                 # within the window: live
    run storage_run emergency_cleanup
    [ "$status" -eq 0 ]
    [ ! -e "$ST_REC/s1/future.opus" ]
    [ -e "$ST_REC/s1/soon.opus" ]
}

@test "emergency eviction keeps truncated-but-non-empty segments until their turn in age order [X-14]" {
    _make "$ST_REC/s1/audio_000.opus" "9 hours ago" 262144       # cut at a flush boundary
    _make "$ST_REC/s1/audio_001.opus" "8 hours ago" 262144
    ST_ENV=(DRY_RUN=true)
    run storage_run emergency_cleanup
    [ "$status" -eq 0 ]
    [[ "$output" == *"Would delete emergency recording"*"audio_000.opus"* ]]
    [[ "$output" == *"Would delete emergency recording"*"audio_001.opus"* ]]
    ! grep -q 'Would delete emergency empty segment' <<<"$output" || false   # not classed as debris
}

@test "emergency eviction lists empty segments before recordings in a dry run [X-14]" {
    _make "$ST_REC/s1/audio_000.opus" "9 hours ago" 100
    _make "$ST_REC/s1/audio_001.opus" "2 hours ago"
    ST_ENV=(DRY_RUN=true)
    run storage_run emergency_cleanup
    [ "$status" -eq 0 ]
    local empty_line rec_line
    empty_line="$(grep -n 'Would delete emergency empty segment' <<<"$output" | head -n 1 | cut -d: -f1)"
    rec_line="$(grep -n 'Would delete emergency recording' <<<"$output" | head -n 1 | cut -d: -f1)"
    [ -n "$empty_line" ] && [ -n "$rec_line" ] && [ "$empty_line" -lt "$rec_line" ]
}

# --- status --------------------------------------------------------------------------

@test "status counts recordings and empty segments separately and ignores other files [X-14 regression]" {
    _make "$ST_REC/s1/audio_000.opus" "1 hour ago" 1000
    _make "$ST_REC/s1/audio_001.aac" "1 hour ago" 1000
    _make "$ST_REC/s1/audio_002.opus" "1 hour ago"
    _make "$ST_REC/s1/notes.txt" "1 hour ago" 10
    run storage_run cmd_status
    [ "$status" -eq 0 ]
    [[ "$output" == *"Files: 2"* ]]
    [[ "$output" == *"Empty segments: 1"* ]]
}

# --- what a real FFmpeg leaves behind -------------------------------------------------

@test "a hard-killed FFmpeg leaves a decodable truncated segment that retention keeps and an empty one it removes [X-14]" {
    command -v ffmpeg >/dev/null 2>&1 && command -v ffprobe >/dev/null 2>&1 || skip "ffmpeg/ffprobe not installed"
    ffmpeg -hide_banner -loglevel error -nostdin -f lavfi -i "sine=duration=0.2" -c:a libopus -f null - 2>/dev/null \
        || skip "this ffmpeg has no libopus"
    mkdir -p "$ST_REC/s1"
    ffmpeg -hide_banner -loglevel error -nostdin -re -f lavfi -i "sine=frequency=440:duration=60" \
        -ar 48000 -ac 2 -c:a libopus -b:a 510k -vbr off -application audio -f tee -map 0:a \
        "[f=segment:segment_time=60:segment_wrap=12:strftime=0]$ST_REC/s1/audio_%03d.opus" 2>/dev/null &
    local pid=$!
    sleep 7                       # the first 256 KiB chunk is flushed after ~4 s at 510 kb/s
    kill -9 "$pid"
    wait "$pid" 2>/dev/null || true
    [ -s "$ST_REC/s1/audio_000.opus" ]                                   # truncated, not empty
    ffprobe -v error -show_entries format=duration -of csv=p=0 "$ST_REC/s1/audio_000.opus" >/dev/null
    : >"$ST_REC/s1/audio_001.opus"                                       # an empty segment from an earlier crash
    find "$ST_REC" -type f -exec touch -d "2 hours ago" {} +

    run storage_run cleanup_recordings
    [ "$status" -eq 0 ]
    [ -s "$ST_REC/s1/audio_000.opus" ]                                   # the audio survives
    [ ! -e "$ST_REC/s1/audio_001.opus" ]                                 # the debris does not
    run ffmpeg -v error -nostdin -i "$ST_REC/s1/audio_000.opus" -f null -
    [ "$status" -eq 0 ]
    [ -z "$output" ]                                                     # and it still decodes cleanly
}
