#!/usr/bin/env bats
# The capture PCM is not always 0 (register: LB-24).
#
# check_audio_device, check_audio_level, check_alsa_device_available and both
# wrappers (the FFmpeg input `plughw:CARD,0` and the "device still exists" check
# on /dev/snd/pcmCnD0c) assumed that a USB card captures on ALSA PCM device 0.
# A card that captures on device 1, or has playback on 0 and capture only on 1,
# was reported "not accessible" and never streamed. The capture PCMs of a card are
# now enumerated from /proc/asound/card<N>/pcm<M>c, the first one is the default,
# DEVICE_<NAME>_PCM overrides it, and the index is carried to every site.
#
# Everything runs over a fake ALSA tree (ASOUND_PROC_ROOT and DEV_SND_ROOT point at
# it; the defaults are the real /proc/asound and /dev/snd) built by sd_fake_card.
# Stood in for: `arecord -l` (it lists the fake cards), the wrapper process in the
# start tests (the wrapper is written, not run) and, where a wrapper really runs, the
# `ffmpeg` binary (it records its arguments and idles). Nothing here shows how a real
# USB card lays out its PCMs: that needs hardware (see the notes).

load scratch_tmpdir
load stream_definition_helper

setup() {
    sd_setup
}

teardown() {
    sd_teardown
}

# ---------------------------------------------------------------------------
# Enumeration
# ---------------------------------------------------------------------------

@test "alsa_capture_pcms lists a card's capture PCMs only, ascending [LB-24]" {
    sd_fake_card 1 0p
    sd_fake_card 2 0c 0p
    sd_fake_card 3 0p 1c
    sd_fake_card 4 10c 0c 2c 2p
    run smq '
        for card in 1 2 3 4 5 x ""; do
            printf "card [%s]: %s\n" "$card" "$(alsa_capture_pcms "$card" | tr "\n" " ")"
        done'
    [ "$status" -eq 0 ]
    [ "${lines[0]}" = "card [1]: " ]
    [ "${lines[1]}" = "card [2]: 0 " ]
    [ "${lines[2]}" = "card [3]: 1 " ]
    [ "${lines[3]}" = "card [4]: 0 2 10 " ]
    [ "${lines[4]}" = "card [5]: " ]
    [ "${lines[5]}" = "card [x]: " ]
    [ "${lines[6]}" = "card []: " ]
}

@test "without PCM directories in /proc/asound the capture device nodes are used [LB-24]" {
    mkdir -p "$ASOUND_PROC_ROOT/card6"
    : >"$DEV_SND_ROOT/pcmC6D1c"
    : >"$DEV_SND_ROOT/pcmC6D0p"
    : >"$DEV_SND_ROOT/pcmC6D3c"
    run smq 'alsa_capture_pcms 6 | tr "\n" " "'
    [ "$output" = "1 3 " ]
}

@test "the roots default to the real /proc/asound and /dev/snd [LB-24]" {
    run env -u ASOUND_PROC_ROOT -u DEV_SND_ROOT bash -c 'source "$LB_REAL_SCRIPT"; echo "$ASOUND_PROC_ROOT $DEV_SND_ROOT"'
    [ "$status" -eq 0 ]
    [ "$output" = "/proc/asound /dev/snd" ]
}

# ---------------------------------------------------------------------------
# Choice
# ---------------------------------------------------------------------------

@test "resolve_capture_pcm takes the first capture PCM, whichever device number it has [LB-24]" {
    sd_fake_card 2 0c 1c
    sd_fake_card 3 0p 1c
    run smq '
        resolve_capture_pcm 2 "usb-audio-two" two && echo "card 2: $STREAM_PCM"
        resolve_capture_pcm 3 "usb-audio-three" three && echo "card 3: $STREAM_PCM"'
    [ "$status" -eq 0 ]
    [ "${lines[0]}" = "card 2: 0" ]
    [ "${lines[1]}" = "card 3: 1" ]
}

@test "DEVICE_<NAME>_PCM chooses among the capture PCMs, by stream name or by device name [LB-24]" {
    sd_fake_card 2 0c 2c
    printf '%s\n' 'DEVICE_TWO_PCM=2' 'DEVICE_USB_AUDIO_OTHER_PCM="2"' >"$MEDIAMTX_DEVICE_CONFIG"
    run smq '
        resolve_capture_pcm 2 "usb-audio-two" two && echo "by stream name: $STREAM_PCM"
        resolve_capture_pcm 2 "usb-audio-other" nothing_set && echo "by device name: $STREAM_PCM"
        resolve_capture_pcm 2 "usb-audio-third" third && echo "not set: $STREAM_PCM"'
    [ "$status" -eq 0 ]
    [ "${lines[0]}" = "by stream name: 2" ]
    [ "${lines[1]}" = "by device name: 2" ]
    [ "${lines[2]}" = "not set: 0" ]
}

@test "a PCM setting that is not a capture PCM of the card is an error and the first capture PCM is used [LB-24]" {
    sd_fake_card 3 0p 1c
    printf '%s\n' 'DEVICE_THREE_PCM=0' >"$MEDIAMTX_DEVICE_CONFIG"
    run smq 'resolve_capture_pcm 3 "usb-audio-three" three && echo "chosen: $STREAM_PCM"'
    [ "$status" -eq 0 ]
    [ "$output" = "chosen: 1" ]
    grep -qF 'PCM 0 set for three is not a capture PCM of card 3 (capture PCMs: 1); using 1' "$STREAM_MANAGER_LOG_FILE"
}

@test "a card with no capture PCM is left out with a log line [LB-24]" {
    sd_fake_card 1 0p
    run smq 'rc=0; resolve_capture_pcm 1 "usb-audio-speaker" speaker || rc=$?; echo "rc=$rc pcm=[$STREAM_PCM]"'
    [ "$status" -eq 0 ]
    [ "$output" = "rc=1 pcm=[]" ]
    grep -qF 'Card 1 (usb-audio-speaker) has no capture PCM (a playback-only card?); it is not used for streaming' "$STREAM_MANAGER_LOG_FILE"
}

@test "PCM is a setting the parser accepts from 0 to 255 and rejects otherwise [LB-24, D3]" {
    run smq '
        for v in 0 1 07 255 256 -1 x "" 1.5 "1 2"; do
            if device_setting_check PCM "$v"; then printf "[%s] -> %s\n" "$v" "$DS_VALUE"; else printf "[%s] -> REJECT\n" "$v"; fi
        done'
    [ "$status" -eq 0 ]
    [ "${lines[0]}" = "[0] -> 0" ]
    [ "${lines[1]}" = "[1] -> 1" ]
    [ "${lines[2]}" = "[07] -> 7" ]
    [ "${lines[3]}" = "[255] -> 255" ]
    [ "${lines[4]}" = "[256] -> REJECT" ]
    [ "${lines[5]}" = "[-1] -> REJECT" ]
    [ "${lines[6]}" = "[x] -> REJECT" ]
    [ "${lines[7]}" = "[] -> REJECT" ]
    [ "${lines[8]}" = "[1.5] -> REJECT" ]
    [ "${lines[9]}" = "[1 2] -> REJECT" ]
}

# ---------------------------------------------------------------------------
# The checks
# ---------------------------------------------------------------------------

@test "check_audio_device accepts a card whose capture is on device 1 and refuses a playback-only card [LB-24]" {
    sd_fake_card 2 0c
    sd_fake_card 3 0p 1c
    sd_fake_card 1 0p
    run smq '
        for card in 1 2 3 7; do
            rc=0; check_audio_device "$card" || rc=$?
            printf "card %s: %s\n" "$card" "$rc"
        done
        rc=0; check_audio_device 3 1 || rc=$?; echo "card 3 pcm 1: $rc"
        rc=0; check_audio_device 3 0 || rc=$?; echo "card 3 pcm 0: $rc"'
    [ "$status" -eq 0 ]
    [ "${lines[0]}" = "card 1: 1" ]
    [ "${lines[1]}" = "card 2: 0" ]
    [ "${lines[2]}" = "card 3: 0" ]
    [ "${lines[3]}" = "card 7: 1" ]
    [ "${lines[4]}" = "card 3 pcm 1: 0" ]
    [ "${lines[5]}" = "card 3 pcm 0: 1" ]
}

@test "check_audio_device refuses a capture PCM whose device node has gone [LB-24]" {
    sd_fake_card 3 0p 1c
    rm -f "$DEV_SND_ROOT/pcmC3D1c"
    run smq 'rc=0; check_audio_device 3 || rc=$?; echo "rc=$rc"'
    [ "$output" = "rc=1" ]
}

@test "check_alsa_device_available looks at the capture device node, not at device 0 [LB-24]" {
    sd_fake_card 3 0p 1c
    run smq '
        rc=0; check_alsa_device_available 3 || rc=$?; echo "present: $rc"
        rm -f "$DEV_SND_ROOT/pcmC3D1c"
        rc=0; check_alsa_device_available 3 || rc=$?; echo "node gone: $rc"
        rc=0; check_alsa_device_available 9 || rc=$?; echo "no card: $rc"'
    [ "$status" -eq 0 ]
    [ "${lines[0]}" = "present: 0" ]
    [ "${lines[1]}" = "node gone: 1" ]
    [ "${lines[2]}" = "no card: 1" ]
}

@test "check_audio_level records from the capture PCM, not from device 0 [LB-24]" {
    sd_fake_card 3 0p 1c
    sd_fake_card 4 0c 1c
    # Stood in for: ffmpeg, which records its arguments and reports a normal level
    printf '%s\n' '#!/bin/bash' \
        'printf "%s\n" "$*" >>"'"$SD"'/ffmpeg.calls"' \
        'echo "[Parsed_volumedetect_0 @ 0x1] max_volume: -20.0 dB"' >"$SD/bin/ffmpeg"
    chmod +x "$SD/bin/ffmpeg"
    : >"$SD/ffmpeg.calls"
    run smq '
        check_audio_level 3 pcmtest_a; echo "default for card 3: $?"
        check_audio_level 4 pcmtest_b; echo "default for card 4: $?"
        check_audio_level 4 pcmtest_c 1; echo "explicit 1 on card 4: $?"
        check_audio_level 1 pcmtest_d || echo "no capture PCM: $?"'
    [ "$status" -eq 0 ]
    [ "$(sed -n 1p "$SD/ffmpeg.calls")" = "-f alsa -i plughw:3,1 -t 3 -af volumedetect -f null /dev/null" ]
    [ "$(sed -n 2p "$SD/ffmpeg.calls")" = "-f alsa -i plughw:4,0 -t 3 -af volumedetect -f null /dev/null" ]
    [ "$(sed -n 3p "$SD/ffmpeg.calls")" = "-f alsa -i plughw:4,1 -t 3 -af volumedetect -f null /dev/null" ]
    [ "$(wc -l <"$SD/ffmpeg.calls")" -eq 3 ]
    [[ "$output" == *"no capture PCM: 2"* ]]
}

# ---------------------------------------------------------------------------
# The streams
# ---------------------------------------------------------------------------

@test "an individual stream of a card that captures on device 1 starts and records from plughw:CARD,1 [LB-24]" {
    sd_fake_card 3 0p 1c
    run smq "$SD_SPAWN_STUBS"'
        rc=0; start_ffmpeg_stream "usb-audio-usbmic" 3 "usbmic" || rc=$?
        echo "start rc=$rc"'
    [ "$status" -eq 0 ]
    [[ "$output" == *"start rc=0"* ]]
    [ -f "$SD/ff/usbmic.sh" ]
    grep -qE '^PCM_NUM="?1"?$' "$SD/ff/usbmic.sh"
    sd_run_wrapper_until_logged "$SD/ff/usbmic.sh" "Starting FFmpeg with device"
    grep -qF 'Starting FFmpeg with device: plughw:3,1' "$SD/ff/usbmic.log"
}

@test "DEVICE_<NAME>_PCM selects the capture PCM a stream records from, end to end [LB-24]" {
    sd_fake_card 98 0c 2c
    printf '%s\n' 'DEVICE_MIC1_PCM=2' >"$MEDIAMTX_DEVICE_CONFIG"
    run smq "$SD_SPAWN_STUBS"'
        start_ffmpeg_stream "usb-audio-mic1" 98 "mic1"; echo "rc=$?"'
    [[ "$output" == *"rc=0"* ]]
    sd_run_wrapper_until_logged "$SD/ff/mic1.sh" "Starting FFmpeg with device"
    grep -qF 'Starting FFmpeg with device: plughw:98,2' "$SD/ff/mic1.log"

    # the same card without the setting records from its first capture PCM
    rm -f "$MEDIAMTX_DEVICE_CONFIG" "$SD/ff/mic1.sh" "$SD/ff/mic1.pid" "$SD/ff/mic1.log"
    run smq "$SD_SPAWN_STUBS"'
        start_ffmpeg_stream "usb-audio-mic1" 98 "mic1"; echo "rc=$?"'
    [[ "$output" == *"rc=0"* ]]
    sd_run_wrapper_until_logged "$SD/ff/mic1.sh" "Starting FFmpeg with device"
    grep -qF 'Starting FFmpeg with device: plughw:98,0' "$SD/ff/mic1.log"
}

@test "a playback-only card gets no stream: start refuses it with a log line and writes nothing [LB-24]" {
    sd_fake_card 1 0p
    run smq "$SD_SPAWN_STUBS"'
        rc=0; start_ffmpeg_stream "usb-audio-speaker" 1 "speaker" || rc=$?
        echo "start rc=$rc"'
    [ "$status" -eq 0 ]
    [[ "$output" == *"start rc=1"* ]]
    [ -z "$(ls -A "$SD/ff")" ]
    grep -qF 'Card 1 (usb-audio-speaker) has no capture PCM' "$STREAM_MANAGER_LOG_FILE"
}

@test "the wrapper checks the capture PCM's device node, so it runs when only device 0 is missing and stops when device 1 is [LB-24]" {
    sd_fake_card 3 0p 1c
    run smq "$SD_SPAWN_STUBS"'
        start_ffmpeg_stream "usb-audio-usbmic" 3 "usbmic"; echo "rc=$?"'
    [[ "$output" == *"rc=0"* ]]
    # There is no pcmC3D0c at all and the wrapper runs: it looks for pcmC3D1c
    [ ! -e "$DEV_SND_ROOT/pcmC3D0c" ]
    sd_run_wrapper_until_logged "$SD/ff/usbmic.sh" "Starting FFmpeg with device"
    grep -qF 'Starting FFmpeg with device: plughw:3,1' "$SD/ff/usbmic.log"

    # The capture node goes away (a USB unplug): the wrapper stops instead of starting FFmpeg
    rm -f "$DEV_SND_ROOT/pcmC3D1c" "$SD/ff/usbmic.log"
    run timeout 10 bash "$SD/ff/usbmic.sh"
    grep -qF 'Device card 3 no longer exists' "$SD/ff/usbmic.log"
    ! grep -qF 'Starting FFmpeg with device' "$SD/ff/usbmic.log"
}

@test "a multiplex stream gives each device its own capture PCM and leaves out a card that cannot capture [LB-24]" {
    sd_fake_card 3 0p 1c
    sd_fake_card 4 0c
    sd_fake_card 5 0p
    printf '%s\n' 'DEVICE_ALL_MICS_SAMPLE_RATE=44100' >"$MEDIAMTX_DEVICE_CONFIG"
    run smq "$SD_SPAWN_STUBS"'
        resolve_multiplex_stream_name
        start_ffmpeg_multiplex_stream "usb-audio-one:3" "usb-audio-two:4" "usb-audio-speaker:5"; echo "start rc=$?"'
    [ "$status" -eq 0 ]
    [[ "$output" == *"start rc=0"* ]]
    grep -qF 'Card 5 (usb-audio-speaker) has no capture PCM' "$STREAM_MANAGER_LOG_FILE"
    grep -qE '^NUM_DEVICES=2$' "$SD/ff/all_mics.sh"
    sd_run_wrapper_until_logged "$SD/ff/all_mics.sh" "FFmpeg command:"
    local call
    call="$(grep -F 'FFmpeg command:' "$SD/ff/all_mics.log")"
    [[ "$call" == *"-i plughw:3,1 "* ]]
    [[ "$call" == *"-i plughw:4,0 "* ]]
    [[ "$call" != *"plughw:5"* ]]
}

@test "a multiplex stream with no card that can capture does not start [LB-24]" {
    sd_fake_card 5 0p
    run smq "$SD_SPAWN_STUBS"'
        resolve_multiplex_stream_name
        rc=0; start_ffmpeg_multiplex_stream "usb-audio-speaker:5" || rc=$?
        echo "start rc=$rc"'
    [[ "$output" == *"start rc=1"* ]]
    grep -qF 'No valid audio devices available for multiplex stream' "$STREAM_MANAGER_LOG_FILE"
}

@test "no capture path in the script assumes PCM device 0 any more [LB-24]" {
    ! grep -nE 'pcmC\$\{[A-Za-z_]+\}D0c|plughw:\$\{[A-Za-z_]+\},0[^0-9]|/dev/snd/pcmC' "$LB_REAL_SCRIPT"
}
