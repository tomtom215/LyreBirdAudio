#!/usr/bin/env bats
# The multiplex audio graph (register: X-20).
#
#  - amix=...:normalize=0 needs FFmpeg 4.4; README minimums ship 4.2/4.3 (Ubuntu
#    20.04, Debian 11), where the option is unknown and the stream never starts.
#    The option is now feature-detected once (ffmpeg -h filter=amix) and left out
#    where it is missing.
#  - amerge + libopus fails for several channel counts (2 stereo inputs -> 4.0,
#    5 stereo -> 10 channels, 3 or 4 mono inputs); the stream used to start, fail in
#    its wrapper and give up. The exact graph and encoder arguments are now run
#    against FFmpeg itself for a tenth of a second (silent lavfi inputs of the same
#    channel count) before the wrapper is written, and a combination FFmpeg refuses
#    is an error that names inputs x channels and the way out.
#
# The counts below were measured with the FFmpeg 6.1.1 on this machine; no older
# FFmpeg was available, so the 4.2/4.3 side is tested with a stand-in `ffmpeg`
# that prints an amix help text without `normalize` (stated in those tests), and
# nothing here says how FFmpeg 4.3 behaves at run time. Real ALSA channel layouts
# need hardware.

load scratch_tmpdir
load stream_definition_helper

setup() {
    sd_setup
    sd_fake_card 98 0c
    sd_fake_card 99 0c
    cd "$SD"
}

teardown() {
    sd_teardown
}

# Skip unless the real ffmpeg has libopus, libmp3lame, aac and lavfi's anullsrc
_require_real_ffmpeg() {
    command -v ffmpeg >/dev/null || skip "ffmpeg not installed"
    local encoders
    encoders="$(ffmpeg -hide_banner -encoders 2>/dev/null)"
    [[ "$encoders" == *libopus* && "$encoders" == *libmp3lame* ]] || skip "ffmpeg lacks libopus or libmp3lame"
    ffmpeg -hide_banner -filters 2>/dev/null | grep -q anullsrc || skip "ffmpeg lacks lavfi anullsrc"
}

# ---------------------------------------------------------------------------
# normalize: feature detection
# ---------------------------------------------------------------------------

@test "the real FFmpeg's amix is detected as having normalize [X-20]" {
    _require_real_ffmpeg
    ffmpeg -hide_banner -h filter=amix 2>&1 | grep -qw normalize || skip "this ffmpeg's amix has no normalize"
    run smq 'if amix_supports_normalize; then echo YES; else echo NO; fi'
    [ "$output" = "YES" ]
}

# The value of a variable in a generated wrapper's header, as bash reads it (the
# header is executed in a subshell; the values are bash-quoted words)
_header_value() {
    sed -n '1,/^# Create log file if it doesn/p' "$1" | head -n -1 >"$SD/header.sh"
    (cd "$SD" && bash -c 'source "$1"; printf "%s" "${!2}"' _ "$SD/header.sh" "$2")
}

# A stand-in for an FFmpeg older than 4.4: its amix help has no `normalize`, and
# any other invocation succeeds quietly (it cannot run a graph). Not a measurement of
# 4.3; it only provides the help text the detection reads.
_old_ffmpeg_stand_in() {
    printf '%s\n' '#!/bin/bash' \
        'printf "%s\n" "$*" >>"'"$SD"'/ffmpeg.calls"' \
        'if [[ "$*" == *"-h filter=amix"* ]]; then' \
        '    printf "Filter amix\n  Audio mixing.\namix AVOptions:\n   inputs            <int>        ..F.A...... Number of inputs. (from 1 to 32767) (default 2)\n   duration          <int>        ..F.A...... How to determine the end-of-stream. (from 0 to 2) (default longest)\n   dropout_transition <float>      ..F.A...... Transition time, in seconds, for volume renormalization when an input stream ends. (from 0 to INT_MAX) (default 2)\n"' \
        'fi' \
        'exit 0' >"$SD/bin/ffmpeg"
    chmod +x "$SD/bin/ffmpeg"
    : >"$SD/ffmpeg.calls"
}

@test "an FFmpeg whose amix has no normalize option is detected, and the answer is cached [X-20]" {
    _old_ffmpeg_stand_in
    run smq '
        amix_supports_normalize || echo "first: no"
        amix_supports_normalize || echo "second: no"
        amix_supports_normalize || echo "third: no"'
    [ "$status" -eq 0 ]
    [ "${lines[0]}" = "first: no" ]
    [ "${lines[2]}" = "third: no" ]
    # ffmpeg was asked once, not three times
    [ "$(grep -c -- '-h filter=amix' "$SD/ffmpeg.calls")" -eq 1 ]
}

@test "without normalize support the multiplex graph is the amix default and says why; with it, normalize=0 as before [X-20]" {
    _old_ffmpeg_stand_in
    run smq "$SD_SPAWN_STUBS"'
        resolve_multiplex_stream_name
        start_ffmpeg_multiplex_stream "usb-audio-one:98" "usb-audio-two:99"; echo "start rc=$?"'
    [ "$status" -eq 0 ]
    [[ "$output" == *"start rc=0"* ]]
    [ "$(_header_value "$SD/ff/all_mics.sh" FILTER_COMPLEX)" = "[0:a][1:a]amix=inputs=2:duration=longest,aresample=async=1:first_pts=0" ]
    grep -qF "amix has no normalize option (it is older than 4.4)" "$STREAM_MANAGER_LOG_FILE"

    # the real FFmpeg here has it (the stand-in is taken off the PATH first)
    rm -f "$SD/bin/ffmpeg" "$SD"/ff/*
    _require_real_ffmpeg
    ffmpeg -hide_banner -h filter=amix 2>&1 | grep -qw normalize || skip "this ffmpeg's amix has no normalize"
    run smq "$SD_SPAWN_STUBS"'
        resolve_multiplex_stream_name
        start_ffmpeg_multiplex_stream "usb-audio-one:98" "usb-audio-two:99"; echo "start rc=$?"'
    [[ "$output" == *"start rc=0"* ]]
    [ "$(_header_value "$SD/ff/all_mics.sh" FILTER_COMPLEX)" = "[0:a][1:a]amix=inputs=2:duration=longest:normalize=0,aresample=async=1:first_pts=0" ]
}

@test "normalize=0 mixes two equal inputs about 6 dB louder than amix's default, which is what the README's wording hides [X-20]" {
    _require_real_ffmpeg
    ffmpeg -hide_banner -h filter=amix 2>&1 | grep -qw normalize || skip "this ffmpeg's amix has no normalize"
    local loud quiet
    loud="$(ffmpeg -hide_banner -nostdin -f lavfi -i "sine=f=440:d=1" -f lavfi -i "sine=f=440:d=1" \
        -filter_complex "[0:a][1:a]amix=inputs=2:duration=longest:normalize=0,volumedetect" -f null - 2>&1 | sed -n 's/.*mean_volume: \(-\?[0-9.]*\) dB.*/\1/p')"
    quiet="$(ffmpeg -hide_banner -nostdin -f lavfi -i "sine=f=440:d=1" -f lavfi -i "sine=f=440:d=1" \
        -filter_complex "[0:a][1:a]amix=inputs=2:duration=longest,volumedetect" -f null - 2>&1 | sed -n 's/.*mean_volume: \(-\?[0-9.]*\) dB.*/\1/p')"
    echo "normalize=0: $loud dB, default: $quiet dB" >&3
    python3 -I -c 'import sys; loud, quiet = float(sys.argv[1]), float(sys.argv[2]); d = loud - quiet; sys.exit(0 if 5.0 < d < 7.0 else 1)' "$loud" "$quiet"
}

# ---------------------------------------------------------------------------
# The graph and the encoder arguments
# ---------------------------------------------------------------------------

@test "multiplex_filter_complex builds the graph the wrapper used to build itself [X-20]" {
    run smq '
        multiplex_filter_complex amix 2 ":normalize=0"; echo
        multiplex_filter_complex amix 3; echo
        multiplex_filter_complex amerge 2; echo
        multiplex_filter_complex amerge 4 ":normalize=0"; echo
        rc=0; multiplex_filter_complex other 2 || rc=$?; echo "other rc=$rc"'
    [ "${lines[0]}" = "[0:a][1:a]amix=inputs=2:duration=longest:normalize=0,aresample=async=1:first_pts=0" ]
    [ "${lines[1]}" = "[0:a][1:a][2:a]amix=inputs=3:duration=longest,aresample=async=1:first_pts=0" ]
    [ "${lines[2]}" = "[0:a][1:a]amerge=inputs=2,aresample=async=1:first_pts=0" ]
    [ "${lines[3]}" = "[0:a][1:a][2:a][3:a]amerge=inputs=4,aresample=async=1:first_pts=0" ]
    [ "${lines[4]}" = "other rc=1" ]
}

@test "multiplex_encoder_args gives each supported codec its arguments and refuses any other [X-20, X-28]" {
    run smq '
        for c in opus aac mp3; do multiplex_encoder_args "$c" 96k; echo "$c: ${MULTIPLEX_ENCODER_ARGS[*]}"; done
        multiplex_encoder_args opus "two words"; echo "words: ${#MULTIPLEX_ENCODER_ARGS[@]}"
        rc=0; multiplex_encoder_args pcm_s16le 96k || rc=$?; echo "pcm_s16le rc=$rc elements=${#MULTIPLEX_ENCODER_ARGS[@]}"'
    [ "${lines[0]}" = "opus: -c:a libopus -b:a 96k -application audio" ]
    [ "${lines[1]}" = "aac: -c:a aac -b:a 96k" ]
    [ "${lines[2]}" = "mp3: -c:a libmp3lame -b:a 96k" ]
    # a bitrate with a space stays one word
    [ "${lines[3]}" = "words: 6" ]
    [ "${lines[4]}" = "pcm_s16le rc=1 elements=0" ]
}

# ---------------------------------------------------------------------------
# Channel counts against the codec, tested with FFmpeg itself
# ---------------------------------------------------------------------------

# Run the real check for FILTER INPUTS CHANNELS CODEC; prints ok or REFUSED
_check_graph() {
    FILTER="$1" INPUTS="$2" CHANNELS="$3" CODEC="$4" smq '
        graph="$(multiplex_filter_complex "$FILTER" "$INPUTS" ":normalize=0")"
        multiplex_encoder_args "$CODEC" 128k
        if check_multiplex_encoding "$FILTER" "$INPUTS" "$CHANNELS" 48000 "$CODEC" "$graph" "${MULTIPLEX_ENCODER_ARGS[@]}"; then echo ok; else echo REFUSED; fi'
}

@test "amerge with opus: FFmpeg 6.1.1 refuses 2 stereo (4.0), 5 stereo (10 ch), 3 and 4 mono; accepts 4 stereo, 2 and 5 mono [X-20]" {
    _require_real_ffmpeg
    local result
    # the counts of the register, as measured with the real FFmpeg
    for spec in "2 2 REFUSED" "5 2 REFUSED" "6 2 REFUSED" "3 1 REFUSED" "4 1 REFUSED" "4 2 ok" "2 1 ok" "5 1 ok" "1 2 ok" "3 2 ok"; do
        set -- $spec
        result="$(_check_graph amerge "$1" "$2" opus | tail -n 1)"
        [ "$result" = "$3" ] || { echo "amerge opus, $1 inputs x $2 channels: got $result, want $3"; return 1; }
    done
}

@test "amix never produces a channel count libopus, aac or libmp3lame cannot take [X-20]" {
    _require_real_ffmpeg
    local codec n ch result
    for codec in opus aac mp3; do
        for ch in 1 2; do
            for n in 1 2 3 5; do
                result="$(_check_graph amix "$n" "$ch" "$codec" | tail -n 1)"
                [ "$result" = "ok" ] || { echo "amix $codec, $n inputs x $ch channels: $result"; return 1; }
            done
        done
    done
}

@test "amerge with aac: 10 and 12 channels are refused, 4 and 6 accepted [X-20]" {
    _require_real_ffmpeg
    [ "$(_check_graph amerge 5 2 aac | tail -n 1)" = "REFUSED" ]
    [ "$(_check_graph amerge 6 2 aac | tail -n 1)" = "REFUSED" ]
    [ "$(_check_graph amerge 2 2 aac | tail -n 1)" = "ok" ]
    [ "$(_check_graph amerge 3 2 aac | tail -n 1)" = "ok" ]
}

@test "a refused combination stops the multiplex start with an error that names inputs x channels and the way out, and writes nothing [X-20]" {
    _require_real_ffmpeg
    export MULTIPLEX_FILTER_TYPE=amerge
    run smq "$SD_SPAWN_STUBS"'
        resolve_multiplex_stream_name
        rc=0; start_ffmpeg_multiplex_stream "usb-audio-one:98" "usb-audio-two:99" || rc=$?
        echo "start rc=$rc"'
    [ "$status" -eq 0 ]
    [[ "$output" == *"start rc=1"* ]]
    grep -qE 'Multiplex stream not started: FFmpeg cannot encode 2 inputs x 2 channels as opus with amerge \(4 channels\): ' "$STREAM_MANAGER_LOG_FILE"
    grep -qF 'Use MULTIPLEX_FILTER_TYPE=amix (mixes the inputs down to 2 channels)' "$STREAM_MANAGER_LOG_FILE"
    [ -z "$(ls -A "$SD/ff")" ]
    [ ! -e "$SD/spawn.log" ]
}

@test "an accepted combination starts: amerge of 2 mono inputs with opus, amix of 2 stereo inputs [X-20]" {
    _require_real_ffmpeg
    printf '%s\n' 'DEVICE_ALL_MICS_CHANNELS=1' >"$MEDIAMTX_DEVICE_CONFIG"
    export MULTIPLEX_FILTER_TYPE=amerge
    run smq "$SD_SPAWN_STUBS"'
        resolve_multiplex_stream_name
        start_ffmpeg_multiplex_stream "usb-audio-one:98" "usb-audio-two:99"; echo "amerge mono rc=$?"'
    [[ "$output" == *"amerge mono rc=0"* ]]
    rm -f "$MEDIAMTX_DEVICE_CONFIG" "$SD"/ff/*
    export MULTIPLEX_FILTER_TYPE=amix
    run smq "$SD_SPAWN_STUBS"'
        resolve_multiplex_stream_name
        start_ffmpeg_multiplex_stream "usb-audio-one:98" "usb-audio-two:99"; echo "amix stereo rc=$?"'
    [[ "$output" == *"amix stereo rc=0"* ]]
}

@test "a check that cannot be made does not stop the stream: no lavfi, or a timeout [X-20]" {
    # Stood in for: ffmpeg, which says it has no lavfi (and then, in the second run,
    # `timeout` is stood in for by a command that reports 124)
    printf '%s\n' '#!/bin/bash' \
        'if [[ "$*" == *"-h filter=amix"* ]]; then exit 0; fi' \
        'echo "Unknown input format: lavfi" >&2' \
        'exit 1' >"$SD/bin/ffmpeg"
    chmod +x "$SD/bin/ffmpeg"
    run smq '
        graph="$(multiplex_filter_complex amerge 2)"
        rc=0; check_multiplex_encoding amerge 2 2 48000 opus "$graph" -c:a libopus || rc=$?
        echo "no lavfi rc=$rc"'
    [[ "$output" == *"no lavfi rc=0"* ]]
    grep -qF 'Could not check whether FFmpeg can encode the multiplex graph' "$STREAM_MANAGER_LOG_FILE"

    printf '%s\n' '#!/bin/bash' 'exit 124' >"$SD/bin/timeout"
    chmod +x "$SD/bin/timeout"
    : >"$STREAM_MANAGER_LOG_FILE"
    run smq '
        graph="$(multiplex_filter_complex amerge 2)"
        rc=0; check_multiplex_encoding amerge 2 2 48000 opus "$graph" -c:a libopus || rc=$?
        echo "timeout rc=$rc"'
    [[ "$output" == *"timeout rc=0"* ]]
    grep -qF 'Could not check whether FFmpeg can encode the multiplex graph (rc=124)' "$STREAM_MANAGER_LOG_FILE"
}

# ---------------------------------------------------------------------------
# What the wrapper runs is what was checked
# ---------------------------------------------------------------------------

@test "the wrapper runs exactly the graph and the encoder arguments the check used, for every codec [X-20]" {
    _require_real_ffmpeg
    local codec encoder_line graph line
    for codec in opus aac mp3; do
        rm -f "$SD"/ff/* "$SD"/ff/.[!.]*
        printf '%s\n' "DEVICE_ALL_MICS_CODEC=$codec" 'DEVICE_ALL_MICS_BITRATE=96k' >"$MEDIAMTX_DEVICE_CONFIG"
        run smq "$SD_SPAWN_STUBS"'
            resolve_multiplex_stream_name
            start_ffmpeg_multiplex_stream "usb-audio-one:98" "usb-audio-two:99"; echo "start rc=$?"'
        [[ "$output" == *"start rc=0"* ]]
        sd_run_wrapper_until_logged "$SD/ff/all_mics.sh" "FFmpeg command:"
        line="$(grep -F 'FFmpeg command:' "$SD/ff/all_mics.log")"
        encoder_line="$(smq 'multiplex_encoder_args "'"$codec"'" 96k; echo "${MULTIPLEX_ENCODER_ARGS[*]} "')"
        [[ "$line" == *"${encoder_line% } -f rtsp"* ]] || { echo "$codec: $line (encoder: $encoder_line)"; return 1; }
        graph="$(smq 'multiplex_filter_complex amix 2 ":normalize=0"')"
        [[ "$line" == *"-filter_complex $graph "* ]] || { echo "$codec: $line (graph: $graph)"; return 1; }
    done
}
