#!/usr/bin/env bats
# The recording path in the tee muxer argument (register: X-33).
#
# The individual wrapper with AUDIO_LOCAL_RECORDING=true records next to the RTSP
# stream through FFmpeg's tee muxer:
#   -f tee "[f=rtsp:...]rtsp://host/stream|[f=segment:...]<AUDIO_RECORDING_PATH>/<stream>/audio_%03d.<codec>"
# The path went into that argument unescaped. Measured with the real FFmpeg 6.1.1
# (see "What each character does" below), `|` ends the recording slave and starts a
# second output, `\` and `'` are consumed as the tee muxer's escape and quote, and `%`
# starts a pattern of the segment filename; so the recording went into another
# directory, or FFmpeg refused to start. `[` `]` and `:` in the path, which the
# register also names, change nothing (the options of the slave end at the first `]`,
# before the filename), and a path that is relative with a colon in its first
# component is read as a protocol name. The manager now escapes the directory
# (tee_segment_dir) and the wrapper receives the escaped form as RECORDING_TEE_DIR; the
# raw path stays AUDIO_RECORDING_PATH, which the wrapper creates the directory from.
#
# Real code: the real manager, the real wrapper it generates (run for real) and the
# real ffmpeg. Stood in for, and only that: the capture input (the wrapper's
# `-f alsa -i plughw:N,0` is rewritten to a lavfi sine source, since there is no
# sound card) and the RTSP half of the tee argument (to the null muxer, since there is
# no RTSP server). The recording half, the part under test, is untouched.

load scratch_tmpdir
load stream_definition_helper

setup() {
    sd_setup
    cd "$SD"
    # a wrapper that has to stop sits out its current back-off sleep first: keep it short
    export INITIAL_RESTART_DELAY=1 MAX_RESTART_DELAY=2
    if ! command -v ffmpeg >/dev/null 2>&1; then
        REAL_FFMPEG=""
    else
        REAL_FFMPEG=1
    fi
}

teardown() {
    sd_teardown
}

require_ffmpeg_opus() {
    [ -n "$REAL_FFMPEG" ] || skip "ffmpeg is not installed"
    ffmpeg -hide_banner -loglevel error -nostdin -f lavfi -i "sine=duration=0.1" -c:a libopus -f null - 2>/dev/null \
        || skip "this ffmpeg has no libopus"
    ffmpeg -hide_banner -loglevel error -nostdin -f lavfi -i "sine=duration=0.1" -c:a libopus -f tee -map 0:a "[f=null]-" 2>/dev/null \
        || skip "this ffmpeg has no tee muxer"
}

# Generate the individual wrapper of stream mic1 (card 98) for recording path $1, rewrite
# its capture input to a lavfi source and its RTSP slave to the null muxer, run it until
# FFmpeg has exited once, and stop it. Leaves the recordings under $1. The source is read
# at its own speed (-re) for 1.5 s: at full speed FFmpeg would be done before the wrapper's
# 0.2 s "did FFmpeg start" look and the wrapper would treat the finished run as a failure
# to start and wait out its back-off.
record_with_wrapper() {
    local recpath="$1"
    rm -rf "$SD"/ff/* "$SD"/ff/.[!.]*
    AUDIO_LOCAL_RECORDING=true AUDIO_RECORDING_PATH="$recpath" run smq "$SD_SPAWN_STUBS"'
        rc=0; start_ffmpeg_stream "usb-audio-x" 98 "mic1" || rc=$?
        echo "start rc=$rc"'
    [[ "$output" == *"start rc=0"* ]] || {
        echo "$output"
        return 1
    }
    local wrapper="$SD/ff/mic1.sh"
    cp "$wrapper" "$SD/wrapper.orig"
    sed -i -e 's#^        -f alsa$#        -re\n        -f lavfi#' \
        -e '/^        -ar "\${SAMPLE_RATE}"$/d' \
        -e '/^        -ac "\${CHANNELS}"$/d' \
        -e 's#-i "\${audio_device}"#-i "sine=frequency=440:duration=1.5:sample_rate=48000"#' \
        -e 's#"\[f=rtsp:rtsp_transport=tcp\]rtsp://\${MEDIAMTX_HOST}:\${MEDIAMTX_RTSP_PORT}/\${STREAM_PATH}|#"[f=null]-|#' \
        "$wrapper"
    # all five rewrites happened (a changed wrapper text must fail loudly here, not pass vacuously)
    [ "$(diff "$SD/wrapper.orig" "$wrapper" | grep -c '^<')" -eq 5 ] || {
        diff "$SD/wrapper.orig" "$wrapper"
        return 1
    }
    sd_run_wrapper_until_logged "$wrapper" "FFmpeg exited with code"
}

# ---------------------------------------------------------------------------
# What each character does (FFmpeg 6.1.1, the unescaped argument)
# ---------------------------------------------------------------------------

@test "tee_segment_dir escapes exactly the characters that change what the tee muxer writes [X-33]" {
    run smq '
        for dir in "/rec/mic1" "/mnt/my usb/mic1" "/mnt/a:b/mic1" "/mnt/a[b]c/mic1" "/rec/a|b/mic1" "/rec/a\b/mic1" "/rec/Tom'"'"'s/mic1" \
            "/rec/50%/mic1" "/rec/%03d/mic1" "rec/mic1" "rec:x/mic1" "./rec/mic1" "/a|b\c'"'"'d%e/mic1"; do
            printf "%s => %s\n" "$dir" "$(tee_segment_dir "$dir")"
        done'
    [ "$status" -eq 0 ]
    [ "${lines[0]}" = '/rec/mic1 => /rec/mic1' ]
    # a space, a colon and square brackets need nothing
    [ "${lines[1]}" = '/mnt/my usb/mic1 => /mnt/my usb/mic1' ]
    [ "${lines[2]}" = '/mnt/a:b/mic1 => /mnt/a:b/mic1' ]
    [ "${lines[3]}" = '/mnt/a[b]c/mic1 => /mnt/a[b]c/mic1' ]
    # | \ ' get a backslash, % is doubled
    [ "${lines[4]}" = '/rec/a|b/mic1 => /rec/a\|b/mic1' ]
    [ "${lines[5]}" = '/rec/a\b/mic1 => /rec/a\\b/mic1' ]
    [ "${lines[6]}" = "/rec/Tom's/mic1 => /rec/Tom\\'s/mic1" ]
    [ "${lines[7]}" = '/rec/50%/mic1 => /rec/50%%/mic1' ]
    [ "${lines[8]}" = '/rec/%03d/mic1 => /rec/%%03d/mic1' ]
    # a relative path is anchored, so that "word:" is not read as a protocol
    [ "${lines[9]}" = 'rec/mic1 => ./rec/mic1' ]
    [ "${lines[10]}" = 'rec:x/mic1 => ./rec:x/mic1' ]
    [ "${lines[11]}" = './rec/mic1 => ./rec/mic1' ]
    [ "${lines[12]}" = "/a|b\\c'd%e/mic1 => /a\\|b\\\\c\\'d%%e/mic1" ]
}

@test "the wrapper header carries the raw recording path and the escaped directory, and the segment spec uses the escaped one [X-33]" {
    sd_fake_card 98 0c
    AUDIO_LOCAL_RECORDING=true AUDIO_RECORDING_PATH="$SD/rec/a|b" run smq "$SD_SPAWN_STUBS"'
        start_ffmpeg_stream "usb-audio-x" 98 "mic1"; echo "rc=$?"'
    [[ "$output" == *"rc=0"* ]]
    # raw: what the wrapper creates the directory from; escaped: what the tee muxer is given
    [ "$(grep -c '^AUDIO_RECORDING_PATH=' "$SD/ff/mic1.sh")" -eq 1 ]
    bash -c "source <(grep -E '^(AUDIO_RECORDING_PATH|RECORDING_TEE_DIR)=' \"$SD/ff/mic1.sh\"); printf '%s\n%s\n' \"\$AUDIO_RECORDING_PATH\" \"\$RECORDING_TEE_DIR\"" >"$SD/header.out"
    [ "$(sed -n 1p "$SD/header.out")" = "$SD/rec/a|b" ]
    [ "$(sed -n 2p "$SD/header.out")" = "$SD/rec/a\\|b/mic1" ]
    grep -qF 'strftime=0]${RECORDING_TEE_DIR}/audio_%03d.${CODEC}' "$SD/ff/mic1.sh"
    ! grep -qF 'strftime=0]${AUDIO_RECORDING_PATH}' "$SD/ff/mic1.sh"
}

# ---------------------------------------------------------------------------
# End to end with the real FFmpeg
# ---------------------------------------------------------------------------

@test "a recording path with any of | [ ] : \\ ' % or a space records into exactly that directory, and nowhere else [X-33]" {
    require_ffmpeg_opus
    sd_fake_card 98 0c
    local name n=0 base
    for name in "plain" "a b" "a:b" "a[b" "a]b" "a[b]c" "a|b" 'a\b' "a'b" "a%b" 'a%03db' 'x|[]:\'"'"'%y z' "a|b|c"; do
        n=$((n + 1))
        base="$SD/rec$n"
        rm -rf "$base"
        mkdir -p "$base"
        record_with_wrapper "$base/$name"
        [ -s "$base/$name/mic1/audio_000.opus" ] || {
            echo "nothing recorded for path '$name':"
            find "$base" | head -20
            tail -n 8 "$SD/ff/mic1.log"
            false
        }
        # and no recording anywhere else under the base (a '|' used to start a second output and
        # a '\' or ''' used to be eaten, so the segments went into a different directory)
        [ "$(find "$base" -type f | wc -l)" -eq 1 ] || {
            echo "recordings outside '$name':"
            find "$base" -type f
            false
        }
    done
}

@test "a relative recording path whose first component has a colon is a directory, not a protocol [X-33]" {
    require_ffmpeg_opus
    sd_fake_card 98 0c
    record_with_wrapper "rtmp:rec"
    [ -s "$SD/rtmp:rec/mic1/audio_000.opus" ] || {
        find "$SD" -maxdepth 3 | head -20
        tail -n 8 "$SD/ff/mic1.log"
        false
    }
    ! grep -qi 'rtmp @\|Failed to resolve hostname' "$SD/ff/mic1.log"
}

@test "recording to a plain path still produces the segments the storage code looks for [X-33]" {
    require_ffmpeg_opus
    sd_fake_card 98 0c
    record_with_wrapper "$SD/plainrec"
    [ -s "$SD/plainrec/mic1/audio_000.opus" ]
    grep -qF "Local recording enabled: $SD/plainrec/mic1" "$SD/ff/mic1.log"
}
