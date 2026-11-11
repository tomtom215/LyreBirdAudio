#!/usr/bin/env bats
# Generated wrapper scripts (register: LB-09, X-10, X-11 wrapper side).
#
# The manager writes a Bash wrapper per stream that restarts FFmpeg. Config values
# used to be pasted between double quotes in that generated source: a `"`, `$(...)`,
# a backtick, `$VAR` or a trailing backslash executed or broke the wrapper; the
# individual wrapper was never checked with `bash -n`; wrappers were written in
# place (a running bash reads its script as it goes); and the back-off code used two
# variables the header never defined.
#
# Chosen fix: the wrapper text stays generated, every value is written with
# printf %q (so it is a bash-quoted word, never code), the file is built beside its
# destination, checked with `bash -n` in both modes and renamed into place. A fixed
# wrapper program taking arguments would need another installed file and would break
# the per-stream command-line identity the monitor and the e2e tests use.
#
# Two layers are tested: the config parser rejects the hostile values (the generated
# wrapper then carries the defaults), and the generator's own quoting is tested
# separately with the validation layer stood in for (resolve_stream_settings returns
# the hostile value as every setting), so neither layer is trusted to protect the other.
# The real start_ffmpeg_stream / start_ffmpeg_multiplex_stream run (wrapper process
# stood in for); a generated wrapper's header is then executed for real and every
# variable compared with the value that went in; selected wrappers are run entirely.

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

# The vectors of the register (quote, $(...), backtick, $VAR, trailing backslash,
# newline) and the usual neighbours
_vectors() {
    VECTORS=(
        'a"b'
        '$(touch MARK)'
        '`touch MARK`'
        '$HOME'
        '${NO_SUCH_VARIABLE_FOR_THIS_TEST}'
        'trailing\'
        $'line1\nline2'
        '"; touch MARK; "'
        "it's"
        'a b'
        $'tab\there'
        '*'
        '$(sleep 5)'
        '\$(touch MARK)'
    )
}

# Execute the generated wrapper's header (everything before its fixed program) in a
# fresh bash that is allowed to run anything, and print "NAME:OK" or "NAME:BAD:<value>"
# for each NAME, comparing the variable with $EXPECTED. cwd is $SD, so a header that
# ran `touch MARK` would leave $SD/MARK.
# Usage: _header_round_trip WRAPPER NAME...
_header_round_trip() {
    local wrapper="$1"
    shift
    sed -n '1,/^# Create log file if it doesn/p' "$wrapper" | head -n -1 >"$SD/header.sh"
    (cd "$SD" && bash -c '
        source "$1"
        shift
        for name in "$@"; do
            if [[ "${!name}" == "$EXPECTED" ]]; then echo "$name:OK"; else printf "%s:BAD:%q\n" "$name" "${!name}"; fi
        done' _ "$SD/header.sh" "$@")
}

# ---------------------------------------------------------------------------
# Hostile values: the generator's own quoting
# ---------------------------------------------------------------------------

@test "every vector in every setting of an individual wrapper stays data: no code runs and each value round-trips [LB-09, X-10]" {
    _vectors
    local vec out
    for vec in "${VECTORS[@]}"; do
        rm -f "$SD/MARK" "$SD"/ff/* "$SD"/ff/.[!.]*
        export HOSTILE="$vec" EXPECTED="$vec"
        run smq "$SD_SPAWN_STUBS"'
            # stood in for: the validation layer, so the generator sees the hostile value itself
            resolve_stream_settings() {
                STREAM_SAMPLE_RATE="$HOSTILE"; STREAM_CHANNELS="$HOSTILE"; STREAM_CODEC="$HOSTILE"
                STREAM_BITRATE="$HOSTILE"; STREAM_THREAD_QUEUE="$HOSTILE"
            }
            rc=0; start_ffmpeg_stream "usb-audio-x" 98 "mic1" || rc=$?
            echo "start rc=$rc"'
        [ "$status" -eq 0 ]
        [[ "$output" == *"start rc=0"* ]] || { printf 'vector %q: %s\n' "$vec" "$output"; return 1; }
        bash -n "$SD/ff/mic1.sh"
        out="$(_header_round_trip "$SD/ff/mic1.sh" SAMPLE_RATE CHANNELS CODEC BITRATE THREAD_QUEUE)"
        [ "$out" = "$(printf 'SAMPLE_RATE:OK\nCHANNELS:OK\nCODEC:OK\nBITRATE:OK\nTHREAD_QUEUE:OK')" ] || { printf 'vector %q: %s\n' "$vec" "$out"; return 1; }
        [ ! -e "$SD/MARK" ] || { printf 'vector %q ran code\n' "$vec"; return 1; }
    done
}

@test "every vector in every setting of a multiplex wrapper stays data, device names and encoder arguments included [LB-09, X-10]" {
    _vectors
    local vec out
    for vec in "${VECTORS[@]}"; do
        rm -f "$SD/MARK" "$SD"/ff/* "$SD"/ff/.[!.]*
        export HOSTILE="$vec" EXPECTED="$vec"
        # a device name cannot hold the ":" that separates it from the card number, nor a newline
        export DEVNAME="${vec//:/_}"
        DEVNAME="${DEVNAME//$'\n'/_}"
        # Stood in for: the validation layer (resolve_stream_settings returns the hostile value
        # for every setting but the codec, which must be one that has encoder arguments) and the
        # check against FFmpeg (which would take the hostile channel count for a number)
        run smq "$SD_SPAWN_STUBS"'
            resolve_stream_settings() {
                STREAM_SAMPLE_RATE="$HOSTILE"; STREAM_CHANNELS="$HOSTILE"; STREAM_CODEC=opus
                STREAM_BITRATE="$HOSTILE"; STREAM_THREAD_QUEUE="$HOSTILE"
            }
            check_multiplex_encoding() { return 0; }
            resolve_multiplex_stream_name
            rc=0; start_ffmpeg_multiplex_stream "${DEVNAME}:98" "second:99" || rc=$?
            echo "start rc=$rc"'
        [ "$status" -eq 0 ]
        [[ "$output" == *"start rc=0"* ]] || { printf 'vector %q: %s\n' "$vec" "$output"; return 1; }
        bash -n "$SD/ff/all_mics.sh"
        out="$(_header_round_trip "$SD/ff/all_mics.sh" SAMPLE_RATE CHANNELS BITRATE THREAD_QUEUE)"
        [ "$out" = "$(printf 'SAMPLE_RATE:OK\nCHANNELS:OK\nBITRATE:OK\nTHREAD_QUEUE:OK')" ] || { printf 'vector %q: %s\n' "$vec" "$out"; return 1; }
        # the encoder arguments (-c:a libopus -b:a <hostile> -application audio) and the device
        # names are arrays in the header (the device list is one device per line, so a name
        # cannot hold a newline: it is the settings that carry it)
        export EXPECTED="$DEVNAME"
        out="$(sed -n '1,/^# Create log file if it doesn/p' "$SD/ff/all_mics.sh" | head -n -1 >"$SD/header.sh"; cd "$SD" \
            && HOSTILE="$vec" bash -c 'source "$1"
                [[ "${DEVICE_NAMES[0]}" == "$EXPECTED" && "${#DEVICE_NAMES[@]}" -eq 2 ]] || { printf "BAD name %q\n" "${DEVICE_NAMES[0]}"; exit 0; }
                [[ "${#ENCODER_ARGS[@]}" -eq 6 && "${ENCODER_ARGS[1]}" == libopus && "${ENCODER_ARGS[3]}" == "$HOSTILE" ]] || { printf "BAD encoder args %q\n" "${ENCODER_ARGS[*]}"; exit 0; }
                echo OK' _ "$SD/header.sh")"
        [ "$out" = "OK" ] || { printf 'vector %q: %s\n' "$vec" "$out"; return 1; }
        [ ! -e "$SD/MARK" ] || { printf 'vector %q ran code\n' "$vec"; return 1; }
    done
}

@test "a codec with no encoder arguments stops a multiplex start, whatever the validation layer let through [X-28, LB-09]" {
    export HOSTILE='$(touch MARK)'
    run smq "$SD_SPAWN_STUBS"'
        resolve_stream_settings() {
            STREAM_SAMPLE_RATE=48000; STREAM_CHANNELS=2; STREAM_CODEC="$HOSTILE"
            STREAM_BITRATE=128k; STREAM_THREAD_QUEUE=8192
        }
        resolve_multiplex_stream_name
        rc=0; start_ffmpeg_multiplex_stream "usb-audio-x:98" || rc=$?
        echo "start rc=$rc"'
    [[ "$output" == *"start rc=1"* ]]
    grep -qF "there are no encoder arguments for codec '\$(touch MARK)' (supported: opus, aac, mp3)" "$STREAM_MANAGER_LOG_FILE"
    [ -z "$(ls -A "$SD/ff")" ]
    [ ! -e "$SD/MARK" ]
}

@test "paths and names taken from the environment and the arguments stay data too [LB-09, X-10]" {
    # The values the wrapper header carries besides the settings: the stream path (and so the
    # PID, log and wrapper file names), the manager log, the cleanup marker, the host name and
    # the recording path. Each is set to code; none of it may run, in either mode.
    export MEDIAMTX_HOST='127.0.0.1"; touch MARK; "'
    export AUDIO_RECORDING_PATH="$SD"'/rec$(touch MARK)`touch MARK`'
    export MEDIAMTX_CLEANUP_MARKER="$SD"'/cleanup"$(touch MARK)'
    export STREAM_MANAGER_LOG_FILE="$SD"'/log$(touch MARK).txt'
    export HOSTILE='$(touch MARK)'
    run smq "$SD_SPAWN_STUBS"'
        rc=0; start_ffmpeg_stream "usb-audio-x" 98 "$HOSTILE" || rc=$?
        echo "individual rc=$rc"
        MULTIPLEX_STREAM_NAME=mix; resolve_multiplex_stream_name
        rc=0; start_ffmpeg_multiplex_stream "usb-audio-x:98" || rc=$?
        echo "multiplex rc=$rc"'
    [ "$status" -eq 0 ]
    [[ "$output" == *"individual rc=0"* && "$output" == *"multiplex rc=0"* ]]
    local wrapper out
    for wrapper in "$SD/ff/"'$(touch MARK).sh' "$SD/ff/mix.sh"; do
        bash -n "$wrapper"
        export EXPECTED="$MEDIAMTX_HOST"
        out="$(_header_round_trip "$wrapper" MEDIAMTX_HOST)"
        [ "$out" = "MEDIAMTX_HOST:OK" ]
        export EXPECTED="$MEDIAMTX_CLEANUP_MARKER"
        [ "$(_header_round_trip "$wrapper" CLEANUP_MARKER)" = "CLEANUP_MARKER:OK" ]
        export EXPECTED="$STREAM_MANAGER_LOG_FILE"
        [ "$(_header_round_trip "$wrapper" LOG_FILE)" = "LOG_FILE:OK" ]
    done
    export EXPECTED="$AUDIO_RECORDING_PATH"
    [ "$(_header_round_trip "$SD/ff/"'$(touch MARK).sh' AUDIO_RECORDING_PATH)" = "AUDIO_RECORDING_PATH:OK" ]
    export EXPECTED='$(touch MARK)'
    [ "$(_header_round_trip "$SD/ff/"'$(touch MARK).sh' STREAM_PATH)" = "STREAM_PATH:OK" ]
    [ ! -e "$SD/MARK" ]
}

@test "a wrapper generated from hostile values, run for real, runs none of them [LB-09, X-10]" {
    export HOSTILE='$(touch MARK)`touch MARK`"; touch MARK; "'
    local mode
    for mode in individual multiplex; do
        rm -f "$SD/MARK" "$SD"/ff/* "$SD"/ff/.[!.]*
        run smq "$SD_SPAWN_STUBS"'
            resolve_stream_settings() {
                STREAM_SAMPLE_RATE="$HOSTILE"; STREAM_CHANNELS="$HOSTILE"; STREAM_CODEC="$HOSTILE"
                STREAM_BITRATE="$HOSTILE"; STREAM_THREAD_QUEUE="$HOSTILE"
                # a multiplex codec must be one that has encoder arguments
                [[ "'"$mode"'" == multiplex ]] && STREAM_CODEC=opus
                return 0
            }
            check_multiplex_encoding() { return 0; }
            if [[ "'"$mode"'" == individual ]]; then
                start_ffmpeg_stream "usb-audio-x" 98 "mic1"
            else
                resolve_multiplex_stream_name
                start_ffmpeg_multiplex_stream "usb-audio-x:98"
            fi
            echo "start rc=$?"'
        [[ "$output" == *"start rc=0"* ]]
        local wrapper="$SD/ff/mic1.sh" pattern="Starting FFmpeg with device"
        if [ "$mode" = multiplex ]; then
            wrapper="$SD/ff/all_mics.sh"
            pattern="FFmpeg command:"
        fi
        sd_run_wrapper_until_logged "$wrapper" "$pattern"
        grep -qF "$pattern" "${wrapper%.sh}.log"
        [ ! -e "$SD/MARK" ] || { echo "$mode: the wrapper ran a value"; return 1; }
    done
}

# ---------------------------------------------------------------------------
# Hostile values: the parser layer
# ---------------------------------------------------------------------------

@test "hostile values in the device config never reach a wrapper: it carries the defaults, in both modes [LB-09, LB-08]" {
    printf '%s\n' \
        'DEVICE_MIC1_SAMPLE_RATE=$(touch MARK; echo 44100)' \
        'DEVICE_MIC1_CHANNELS="`touch MARK`"' \
        'DEVICE_MIC1_CODEC="aac"; touch MARK' \
        'DEVICE_MIC1_BITRATE=128k"' \
        'DEVICE_MIC1_THREAD_QUEUE=$HOME' \
        'DEVICE_ALL_MICS_SAMPLE_RATE=$(touch MARK)' \
        'DEVICE_ALL_MICS_BITRATE=192k\' >"$MEDIAMTX_DEVICE_CONFIG"
    run smq "$SD_SPAWN_STUBS"'
        start_ffmpeg_stream "usb-audio-x" 98 "mic1"; echo "individual rc=$?"
        resolve_multiplex_stream_name
        start_ffmpeg_multiplex_stream "usb-audio-x:98" "second:99"; echo "multiplex rc=$?"'
    [ "$status" -eq 0 ]
    [[ "$output" == *"individual rc=0"* && "$output" == *"multiplex rc=0"* ]]
    local wrapper out
    for wrapper in "$SD/ff/mic1.sh" "$SD/ff/all_mics.sh"; do
        bash -n "$wrapper"
        out="$(cd "$SD" && sed -n '1,/^# Create log file if it doesn/p' "$wrapper" | head -n -1 >"$SD/header.sh" \
            && bash -c 'source "$1"; echo "$SAMPLE_RATE $CHANNELS $CODEC $BITRATE $THREAD_QUEUE"' _ "$SD/header.sh")"
        [ "$out" = "48000 2 opus 128k 8192" ] || { echo "$wrapper: $out"; return 1; }
    done
    [ ! -e "$SD/MARK" ]
}

@test "ordinary settings from the config reach both wrappers unchanged [LB-09]" {
    printf '%s\n' 'DEVICE_MIC1_SAMPLE_RATE=96000' 'DEVICE_MIC1_CHANNELS=1' 'DEVICE_MIC1_CODEC=aac' \
        'DEVICE_MIC1_BITRATE=192k' 'DEVICE_MIC1_THREAD_QUEUE=4096' 'DEVICE_ALL_MICS_CODEC=mp3' >"$MEDIAMTX_DEVICE_CONFIG"
    run smq "$SD_SPAWN_STUBS"'
        start_ffmpeg_stream "usb-audio-x" 98 "mic1"; echo "individual rc=$?"
        resolve_multiplex_stream_name
        start_ffmpeg_multiplex_stream "usb-audio-x:98"; echo "multiplex rc=$?"'
    [[ "$output" == *"individual rc=0"* && "$output" == *"multiplex rc=0"* ]]
    local out
    out="$(sed -n '1,/^# Create log file if it doesn/p' "$SD/ff/mic1.sh" | head -n -1 >"$SD/header.sh" \
        && bash -c 'source "$1"; echo "$SAMPLE_RATE $CHANNELS $CODEC $BITRATE $THREAD_QUEUE $CARD_NUM $PCM_NUM"' _ "$SD/header.sh")"
    [ "$out" = "96000 1 aac 192k 4096 98 0" ]
    out="$(sed -n '1,/^# Create log file if it doesn/p' "$SD/ff/all_mics.sh" | head -n -1 >"$SD/header.sh" \
        && bash -c 'source "$1"; echo "$CODEC $NUM_DEVICES ${CARD_NUMBERS[*]}"' _ "$SD/header.sh")"
    [ "$out" = "mp3 1 98" ]
}

# ---------------------------------------------------------------------------
# Checked and installed atomically
# ---------------------------------------------------------------------------

@test "a wrapper that fails bash -n is refused in both modes: nothing is installed or started [X-10]" {
    # Stood in for: wrapper_assign, to simulate a generator bug that writes broken syntax
    run smq "$SD_SPAWN_STUBS"'
        wrapper_assign() { printf "FOO=(\n" >>"$1"; }
        rc=0; start_ffmpeg_stream "usb-audio-x" 98 "mic1" || rc=$?
        echo "individual rc=$rc"
        resolve_multiplex_stream_name
        rc=0; start_ffmpeg_multiplex_stream "usb-audio-x:98" || rc=$?
        echo "multiplex rc=$rc"'
    [ "$status" -eq 0 ]
    [[ "$output" == *"individual rc=1"* && "$output" == *"multiplex rc=1"* ]]
    [ "$(sd_count "$STREAM_MANAGER_LOG_FILE" "has syntax errors and is not used")" -eq 2 ]
    # no wrapper, no leftover temporary file, no process started
    [ -z "$(ls -A "$SD/ff")" ]
    [ ! -e "$SD/spawn.log" ]
}

@test "install_wrapper_script keeps the old wrapper when the new one is refused, and removes its temporary file [X-10]" {
    printf '#!/bin/bash\necho OLD\n' >"$SD/ff/mic1.sh"
    printf 'if then\n' >"$SD/ff/.mic1.sh.tmp"
    run smq 'rc=0; install_wrapper_script "$SD/ff/.mic1.sh.tmp" "$SD/ff/mic1.sh" || rc=$?; echo "rc=$rc"'
    [ "$output" = "rc=1" ]
    [ "$(cat "$SD/ff/mic1.sh")" = "$(printf '#!/bin/bash\necho OLD')" ]
    [ ! -e "$SD/ff/.mic1.sh.tmp" ]
}

@test "install_wrapper_script installs a good wrapper with mode 755 and leaves no temporary file [X-10]" {
    printf '#!/bin/bash\necho NEW\n' >"$SD/ff/.mic1.sh.tmp"
    run smq 'install_wrapper_script "$SD/ff/.mic1.sh.tmp" "$SD/ff/mic1.sh"; echo "rc=$?"'
    [ "$output" = "rc=0" ]
    [ "$(stat -c %a "$SD/ff/mic1.sh")" = "755" ]
    [ "$(bash "$SD/ff/mic1.sh")" = "NEW" ]
    [ -z "$(ls -A "$SD/ff" | grep '^\.')" ]
}

@test "start leaves only the wrapper behind: no temporary file, mode 755, in both modes [X-10]" {
    run smq "$SD_SPAWN_STUBS"'
        start_ffmpeg_stream "usb-audio-x" 98 "mic1"; echo "individual rc=$?"
        resolve_multiplex_stream_name
        start_ffmpeg_multiplex_stream "usb-audio-x:98"; echo "multiplex rc=$?"'
    [[ "$output" == *"individual rc=0"* && "$output" == *"multiplex rc=0"* ]]
    [ -z "$(ls -A "$SD/ff" | grep '^\.')" ]
    [ "$(stat -c %a "$SD/ff/mic1.sh")" = "755" ]
    [ "$(stat -c %a "$SD/ff/all_mics.sh")" = "755" ]
}

@test "regenerating a wrapper replaces the file by rename and leaves the one a running wrapper reads intact [X-10]" {
    # The wrapper is bash reading its script as it goes. Written in place, a regeneration
    # truncated and rewrote the very file the running process was reading.
    run smq "$SD_SPAWN_STUBS"'start_ffmpeg_stream "usb-audio-x" 98 "mic1"; echo "rc=$?"'
    [[ "$output" == *"rc=0"* ]]
    cp "$SD/ff/mic1.sh" "$SD/first.sh"
    # A wrapper that runs for real and idles in its back-off sleep (the real FFmpeg cannot
    # open the fake card, so the wrapper waits 20 s before the next attempt)
    setsid bash "$SD/ff/mic1.sh" >"$SD/wrapper.out" 2>&1 3>&- &
    local pid=$!
    echo "$pid" >>"$SD_PIDS_FILE"
    local i
    for ((i = 0; i < 300; i++)); do
        grep -qF 'Failed to start FFmpeg' "$SD/ff/mic1.log" 2>/dev/null && break
        sleep 0.05
    done
    grep -qF 'Failed to start FFmpeg' "$SD/ff/mic1.log"
    [[ "$(readlink "/proc/$pid/fd/255")" == "$SD/ff/mic1.sh" ]]

    # Regenerate with different settings while that process runs
    printf '%s\n' 'DEVICE_MIC1_SAMPLE_RATE=96000' >"$MEDIAMTX_DEVICE_CONFIG"
    rm -f "$SD/ff/mic1.pid"
    run smq "$SD_SPAWN_STUBS"'start_ffmpeg_stream "usb-audio-x" 98 "mic1"; echo "rc=$?"'
    [[ "$output" == *"rc=0"* ]]
    grep -qE '^SAMPLE_RATE=.?96000' "$SD/ff/mic1.sh"
    # The running process still holds the old file, complete, and it is the old inode
    [[ "$(readlink "/proc/$pid/fd/255")" == *"(deleted)" ]]
    cmp "/proc/$pid/fd/255" "$SD/first.sh"
}

# ---------------------------------------------------------------------------
# The back-off: variables the header never defined
# ---------------------------------------------------------------------------

@test "a generated wrapper whose FFmpeg fails waits and keeps running instead of dying on an unbound variable [X-10, new defect]" {
    # The header never defined MAX_RESTART_DELAY and INITIAL_RESTART_DELAY (the manager's
    # copies are readonly and, unless the operator exported them, not in the environment);
    # under the wrapper's set -u the first back-off after a failure ended it with
    # "MAX_RESTART_DELAY: unbound variable". FFmpeg (the real one) fails here because the
    # fake card cannot be opened. The delays are the defaults (10 s, doubled to 20 s), so
    # a wrapper that is alive a second after the failure is in its back-off sleep.
    unset INITIAL_RESTART_DELAY MAX_RESTART_DELAY
    local mode wrapper pid i
    for mode in individual multiplex; do
        rm -f "$SD"/ff/* "$SD"/ff/.[!.]*
        run smq "$SD_SPAWN_STUBS"'
            if [[ "'"$mode"'" == individual ]]; then
                start_ffmpeg_stream "usb-audio-x" 98 "mic1"
            else
                resolve_multiplex_stream_name
                start_ffmpeg_multiplex_stream "usb-audio-x:98"
            fi
            echo "start rc=$?"'
        [[ "$output" == *"start rc=0"* ]]
        wrapper="$SD/ff/mic1.sh"
        [ "$mode" = multiplex ] && wrapper="$SD/ff/all_mics.sh"
        setsid bash "$wrapper" >"$SD/wrapper.out" 2>&1 3>&- &
        pid=$!
        echo "$pid" >>"$SD_PIDS_FILE"
        for ((i = 0; i < 300; i++)); do
            grep -qF 'Failed to start FFmpeg' "${wrapper%.sh}.log" 2>/dev/null && break
            sleep 0.05
        done
        grep -qF 'Failed to start FFmpeg' "${wrapper%.sh}.log" || { echo "$mode: FFmpeg was never tried"; return 1; }
        sleep 1.5
        kill -0 "$pid" || { echo "$mode: the wrapper ended after the first failure"; cat "$SD/wrapper.out"; return 1; }
        ! grep -q 'unbound variable' "$SD/wrapper.out"
        kill -TERM "$pid" 2>/dev/null || true
        wait "$pid" 2>/dev/null || true
    done
}

@test "the back-off delays the manager runs with are the ones its wrappers use [X-10]" {
    # A failed start is retried after RESTART_DELAY doubled, capped at MAX_RESTART_DELAY
    # (the attempt number only counts runs that ended, so the "Starting FFmpeg" line repeats)
    export INITIAL_RESTART_DELAY=1 MAX_RESTART_DELAY=2
    local mode wrapper
    for mode in individual multiplex; do
        rm -f "$SD"/ff/* "$SD"/ff/.[!.]*
        run smq "$SD_SPAWN_STUBS"'
            if [[ "'"$mode"'" == individual ]]; then
                start_ffmpeg_stream "usb-audio-x" 98 "mic1"
            else
                resolve_multiplex_stream_name
                start_ffmpeg_multiplex_stream "usb-audio-x:98"
            fi
            echo "start rc=$?"'
        [[ "$output" == *"start rc=0"* ]]
        wrapper="$SD/ff/mic1.sh"
        [ "$mode" = multiplex ] && wrapper="$SD/ff/all_mics.sh"
        grep -qE '^INITIAL_RESTART_DELAY="?1"?$' "$wrapper"
        grep -qE '^MAX_RESTART_DELAY="?2"?$' "$wrapper"
        sd_run_wrapper_until_logged "$wrapper" "Starting FFmpeg (attempt" 2
        [ "$(grep -cF 'Starting FFmpeg (attempt' "${wrapper%.sh}.log")" -ge 2 ] || { echo "$mode: no second attempt"; cat "${wrapper%.sh}.log" "$SD/wrapper.out"; return 1; }
        ! grep -q 'unbound variable' "$SD/wrapper.out"
    done
}

@test "the wrapper header defines every variable the fixed program reads [X-10]" {
    # Run the generated wrapper's program text against its own header under set -u,
    # with a stand-in run_ffmpeg that always fails: it must reach the back-off and
    # the second attempt without an unbound variable
    run smq "$SD_SPAWN_STUBS"'start_ffmpeg_stream "usb-audio-x" 98 "mic1"; echo "rc=$?"'
    [[ "$output" == *"rc=0"* ]]
    local variable missing=""
    for variable in $(grep -oE '\$\{?[A-Z][A-Z0-9_]+' "$SD/ff/mic1.sh" | tr -d '${' | sort -u); do
        grep -qE "^${variable}=|^declare -a ${variable}=|^${variable}\+=" "$SD/ff/mic1.sh" && continue
        # variables the fixed program defines itself, or the environment
        case "$variable" in
            PATH | BASHPID | START_TIME | END_TIME | RUN_TIME | EXIT_CODE | RANDOM | HOME) continue ;;
        esac
        grep -qE "^ *(local )?${variable}=|^ *for ${variable} in|^ *${variable}=" "$SD/ff/mic1.sh" && continue
        missing+=" $variable"
    done
    [ -z "$missing" ] || { echo "variables used but never defined:$missing"; return 1; }
}
