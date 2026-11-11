#!/usr/bin/env bats
# X-14: the storage script must clean every recording the stream manager can
# write. lyrebird-stream-manager.sh records through FFmpeg's segment muxer to
# `audio_%03d.${CODEC}` (CODEC may be opus, aac or mp3), but the cleanup globs
# used to cover only wav/mp3/flac/opus/ogg, so CODEC=aac recordings were never
# retention-cleaned or evicted. These tests read the codec list from the manager
# itself, so a codec added there cannot silently miss retention again.

load scratch_tmpdir
load storage_helper

setup() {
    scratch_setup
    storage_setup
    MANAGER="$PROJECT_ROOT/lyrebird-stream-manager.sh"
}

teardown() {
    storage_teardown
    scratch_teardown
}

# Case labels of every `case "${CODEC}" in` block in the manager (one per line,
# the catch-all `*` excluded).
manager_codecs() {
    awk '
        /case "\$\{CODEC\}" in/ { incase = 1; next }
        incase && /^[[:space:]]*esac/ { incase = 0; next }
        incase && /^[[:space:]]*[A-Za-z0-9_|*-]+\)[[:space:]]*$/ {
            label = $0
            gsub(/^[[:space:]]+|\)[[:space:]]*$/, "", label)
            n = split(label, parts, "|")
            for (i = 1; i <= n; i++) if (parts[i] != "*") print parts[i]
        }
    ' "$MANAGER" | sort -u
}

@test "the manager's codec list is found (guards the parser used by the tests below)" {
    run manager_codecs
    [ "$status" -eq 0 ]
    [ "${#lines[@]}" -ge 1 ]
}

@test "every CODEC the stream manager accepts has its recording extension in RECORDING_EXTENSIONS [X-14 regression]" {
    local exts codec missing=""
    exts="$(storage_value RECORDING_EXTENSIONS)"
    while IFS= read -r codec; do
        grep -qxF -- "$codec" <<<"$exts" || missing+=" $codec"
    done < <(manager_codecs)
    [ -z "$missing" ] || { echo "CODEC(s) the manager accepts but RECORDING_EXTENSIONS lacks:$missing"; return 1; }
}

@test "the manager names recording segments with the CODEC value as the extension" {
    # The coverage test above equates CODEC with file extension; this pins that
    # equation to the manager's actual segment file name.
    local names
    names="$(grep -o 'audio_%03d\.[^" ]*' "$MANAGER" | sort -u)"
    [ "$names" = 'audio_%03d.${CODEC}' ] || { echo "segment names: $names"; return 1; }
}

@test "every extension in RECORDING_EXTENSIONS is retention-cleaned and emergency-evicted [X-14 regression]" {
    # Per extension: a recording with audio and an empty segment, each aged, so
    # every place that matches extensions (retention, its empty-segment sweep,
    # emergency eviction of empties and of recordings) is exercised.
    local ext
    while IFS= read -r ext; do
        mkdir -p "$ST_REC/age" "$ST_REC/emerg"
        echo data >"$ST_REC/age/audio_000.$ext"
        : >"$ST_REC/age/empty_001.$ext"
        echo data >"$ST_REC/emerg/audio_000.$ext"
        : >"$ST_REC/emerg/empty_001.$ext"
    done < <(storage_value RECORDING_EXTENSIONS)
    find "$ST_REC/age" -type f -exec touch -d "45 days ago" {} +
    find "$ST_REC/emerg" -type f -exec touch -d "2 days ago" {} +
    # Fresh files must survive retention (control).
    touch "$ST_REC/age/keep.aac"

    run storage_run cleanup_recordings
    [ "$status" -eq 0 ]
    run find "$ST_REC/age" -type f
    [ "$output" = "$ST_REC/age/keep.aac" ] || { echo "left after retention: $output"; return 1; }

    run storage_run emergency_cleanup
    [ "$status" -eq 0 ]
    run find "$ST_REC/emerg" -type f
    [ -z "$output" ] || { echo "left after emergency: $output"; return 1; }
}

@test "aged .aac recordings are deleted by retention cleanup [X-14 regression]" {
    mkdir -p "$ST_REC/stream1"
    echo data >"$ST_REC/stream1/audio_000.aac"
    touch -d "45 days ago" "$ST_REC/stream1/audio_000.aac"
    run storage_run cleanup_recordings
    [ "$status" -eq 0 ]
    [ ! -e "$ST_REC/stream1/audio_000.aac" ]
}

@test "files that are not recordings are never deleted by retention or emergency cleanup" {
    local f
    for f in notes.txt audio_000.aac.part audio_000.aacx README .keep recording.opus.bak; do
        echo data >"$ST_REC/$f"
        touch -d "400 days ago" "$ST_REC/$f"
    done
    run storage_run cleanup_recordings
    [ "$status" -eq 0 ]
    run storage_run emergency_cleanup
    [ "$status" -eq 0 ]
    for f in notes.txt audio_000.aac.part audio_000.aacx README .keep recording.opus.bak; do
        [ -f "$ST_REC/$f" ] || { echo "deleted a non-recording: $f"; return 1; }
    done
}

# End to end with a real FFmpeg: write a short segment per manager CODEC through
# the manager's own encoder options and segment spec, age it, and let the real
# storage cleanup judge it. Verified with ffmpeg 6.1.1: opus -> audio_000.opus
# (Ogg Opus), aac -> audio_000.aac (ADTS), mp3 -> audio_000.mp3.
@test "a real FFmpeg recording per manager CODEC is covered by retention cleanup [X-14 regression]" {
    command -v ffmpeg >/dev/null 2>&1 || skip "ffmpeg not installed"
    local codec opts_line seg_tmpl spec ran=0 n
    seg_tmpl="$(grep -o '\[f=segment[^"]*' "$MANAGER" | head -n 1)"
    [ -n "$seg_tmpl" ]
    while IFS= read -r codec; do
        # codec_opts line of this codec's arm in the manager's recorder.
        opts_line="$(awk -v c="$codec" '
            /case "\$\{CODEC\}" in/ { incase = 1; next }
            incase && /^[[:space:]]*esac/ { incase = 0 }
            incase && $0 ~ "^[[:space:]]*" c "\\)" { arm = 1; next }
            incase && /^[[:space:]]*;;/ { arm = 0 }
            arm && /codec_opts=\(/ { print; exit }
        ' "$MANAGER")"
        [ -n "$opts_line" ] || { echo "no codec_opts for $codec in the manager"; return 1; }
        local codec_opts=() BITRATE=64k AUDIO_RECORDING_PATH="$ST_REC" STREAM_PATH=s1 CODEC="$codec"
        local AUDIO_RECORDING_SEGMENT_TIME=1 AUDIO_RECORDING_SEGMENTS=12
        eval "$opts_line"
        # Skip a codec whose encoder this ffmpeg build lacks (checked by trying it).
        ffmpeg -hide_banner -loglevel error -nostdin -f lavfi -i "sine=duration=0.2" "${codec_opts[@]}" \
            -f null - 2>/dev/null || continue
        mkdir -p "$ST_REC/s1"
        eval "spec=\"$seg_tmpl\""
        run ffmpeg -hide_banner -loglevel error -nostdin -f lavfi -i "sine=frequency=440:duration=2.5" \
            -ar 48000 -ac 2 "${codec_opts[@]}" -f tee -map 0:a "$spec"
        [ "$status" -eq 0 ] || { echo "ffmpeg failed for CODEC=$codec: $output"; return 1; }
        [ -s "$ST_REC/s1/audio_000.$codec" ] || { echo "no audio_000.$codec produced"; return 1; }
        ran=$((ran + 1))
    done < <(manager_codecs)
    [ "$ran" -ge 1 ] || skip "this ffmpeg build has none of the manager's encoders"

    find "$ST_REC" -type f -exec touch -d "45 days ago" {} +
    run storage_run cleanup_recordings
    [ "$status" -eq 0 ]
    n="$(find "$ST_REC" -type f | wc -l)"
    [ "$n" -eq 0 ] || { echo "recordings left after retention: $(find "$ST_REC" -type f)"; return 1; }
}
