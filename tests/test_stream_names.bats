#!/usr/bin/env bats
# One canonical stream name (register: LB-04; decision D13).
#
# MULTIPLEX_STREAM_NAME used to reach MediaMTX raw (the YAML path key) and the
# publisher sanitized: "Studio Mix" stopped MediaMTX from starting, "Studio"
# loaded but every publish was rejected, a newline injected YAML, and `status`
# looked for a PID file under a name that was never written. canonical_stream_name
# is applied once, right after the command line is parsed, and every consumer
# sees the result.
#
# Real code throughout: the real canonical_stream_name / resolve_multiplex_stream_
# name, the real CLI (`status`), the real start_ffmpeg_multiplex_stream (wrapper
# process stood in for) and, with LYREBIRD_TEST_MEDIAMTX_BINS set, the real
# generate_mediamtx_config plus real MediaMTX binaries and a real publisher in a
# private network namespace.

load scratch_tmpdir
load stream_definition_helper

setup() {
    sd_setup
}

teardown() {
    sd_teardown
}

# ---------------------------------------------------------------------------
# The canonicalizer
# ---------------------------------------------------------------------------

@test "the register's name matrix maps to canonical names [LB-04, D13]" {
    run sm '
        set +e
        for raw in "Studio Mix" "Studio" "studio" "a/b" "my.mix" "Étude" "9lives" "My-Mix_2" "all_mics" "  padded  " "_lead" "UPPER" "a   b"; do
            out="$(canonical_stream_name "$raw" 2>&1)" || out="REJECTED"
            printf "[%s] -> [%s]\n" "$raw" "$out"
        done'
    [ "$status" -eq 0 ]
    [ "${lines[0]}" = "[Studio Mix] -> [studio_mix]" ]
    [ "${lines[1]}" = "[Studio] -> [studio]" ]
    [ "${lines[2]}" = "[studio] -> [studio]" ]
    [ "${lines[3]}" = "[a/b] -> [a_b]" ]
    [ "${lines[4]}" = "[my.mix] -> [my_mix]" ]
    [ "${lines[5]}" = "[Étude] -> [tude]" ]
    [ "${lines[6]}" = "[9lives] -> [9lives]" ]
    [ "${lines[7]}" = "[My-Mix_2] -> [my-mix_2]" ]
    [ "${lines[8]}" = "[all_mics] -> [all_mics]" ]
    [ "${lines[9]}" = "[  padded  ] -> [padded_]" ]
    [ "${lines[10]}" = "[_lead] -> [lead]" ]
    [ "${lines[11]}" = "[UPPER] -> [upper]" ]
    [ "${lines[12]}" = "[a   b] -> [a_b]" ]
}

@test "reserved words are rejected with a message that names the word and the list [D13]" {
    run sm '
        set +e
        for raw in api API Stats control METRICS health all All_Others; do
            msg="$(canonical_stream_name "$raw" 2>&1 >/dev/null)"; rc=$?
            out="$(canonical_stream_name "$raw" 2>/dev/null)"
            printf "%s rc=%s stdout=[%s] msg=%s\n" "$raw" "$rc" "$out" "$msg"
        done'
    [ "$status" -eq 0 ]
    local line
    for line in "${lines[@]}"; do
        [[ "$line" == *"rc=1 stdout=[]"* ]] || { echo "not rejected: $line"; false; }
        [[ "$line" == *"is reserved (control, stats, api, metrics, health, all, all_others"* ]] || { echo "unclear message: $line"; false; }
    done
    [ "${#lines[@]}" -eq 8 ]
}

@test "names with no letters or digits and names that are too long are rejected [D13]" {
    run sm '
        set +e
        for raw in "" "///" "___" "---" "é"; do
            msg="$(canonical_stream_name "$raw" 2>&1 >/dev/null)"; rc=$?
            printf "rc=%s %s\n" "$rc" "$msg"
        done
        ok64="$(printf "a%.0s" {1..64})"; bad65="${ok64}a"; huge="$(head -c 300 /dev/zero | tr "\0" a)"
        canonical_stream_name "$ok64" >/dev/null; echo "64 chars rc=$?"
        msg="$(canonical_stream_name "$bad65" 2>&1 >/dev/null)"; echo "65 chars rc=$? $msg"
        msg="$(canonical_stream_name "$huge" 2>&1 >/dev/null)"; echo "300 chars rc=$? $msg"'
    [ "$status" -eq 0 ]
    [[ "${lines[0]}" == "rc=1 Stream name '' has no letters or digits"* ]]
    [[ "${lines[1]}" == "rc=1 Stream name '///' has no letters or digits"* ]]
    [[ "${lines[2]}" == "rc=1 Stream name '___' has no letters or digits"* ]]
    [[ "${lines[3]}" == "rc=1 Stream name '---' has no letters or digits"* ]]
    [[ "${lines[4]}" == "rc=1 Stream name '??' has no letters or digits"* ]]
    [ "${lines[5]}" = "64 chars rc=0" ]
    [[ "${lines[6]}" == "65 chars rc=1"*"too long (65 characters after normalisation; at most 64 are allowed)" ]]
    [[ "${lines[7]}" == "300 chars rc=1"*"too long (300 characters"* ]]
}

@test "a canonical name is returned unchanged and every result obeys MediaMTX's path rule [D13, property]" {
    # 300 pseudo-random strings (fixed seed): bytes 1-255, so control characters,
    # quotes, newlines, slashes, YAML syntax and invalid UTF-8 all occur
    run sm '
        set +e
        RANDOM=20261111
        bad=0; accepted=0; rejected=0
        for ((i = 0; i < 300; i++)); do
            len=$((RANDOM % 40 + 1)); raw=""
            for ((j = 0; j < len; j++)); do
                printf -v ch "\\x%02x" $((RANDOM % 255 + 1)); printf -v ch "$ch"
                raw+="$ch"
            done
            if out="$(canonical_stream_name "$raw" 2>/dev/null)"; then
                accepted=$((accepted + 1))
                [[ "$out" =~ ^[a-z0-9][a-z0-9_-]{0,63}$ ]] || { bad=$((bad + 1)); printf "BAD charset: %q -> %q\n" "$raw" "$out"; }
                again="$(canonical_stream_name "$out" 2>/dev/null)" || again="REJECTED"
                [[ "$again" == "$out" ]] || { bad=$((bad + 1)); printf "NOT idempotent: %q -> %q -> %q\n" "$raw" "$out" "$again"; }
            else
                rejected=$((rejected + 1))
            fi
        done
        printf "accepted=%s rejected=%s bad=%s\n" "$accepted" "$rejected" "$bad"'
    [ "$status" -eq 0 ]
    [[ "${lines[-1]}" == *"bad=0" ]] || { printf '%s\n' "${lines[@]}"; false; }
    # the sample is not degenerate: most random strings contain a letter or digit
    [[ "${lines[-1]}" =~ accepted=([0-9]+) ]]
    [ "${BASH_REMATCH[1]}" -gt 100 ]
}

@test "a name with a newline and YAML syntax becomes one harmless line [LB-04]" {
    export RAW=$'x:\n    runOnInit: touch /tmp/MARK\n  evil:'
    run sm 'canonical_stream_name "$RAW"'
    [ "$status" -eq 0 ]
    [ "$output" = "x_runoninit_touch_tmp_mark_evil_" ]
}

@test "visible_text makes an untrusted string safe for a log line [D13]" {
    run sm '
        set +e
        visible_text "$(printf "a\\\\nb\tc\033[31m")"; echo
        visible_text "$(head -c 200 /dev/zero | tr "\0" x)" 10; echo'
    [ "$status" -eq 0 ]
    [ "${lines[0]}" = "a?nb?c?[31m" ]
    [ "${lines[1]}" = "xxxxxxxxxx..." ]
}

# ---------------------------------------------------------------------------
# Applied once, when the name is parsed
# ---------------------------------------------------------------------------

@test "the environment name is canonicalised once and the change is logged once [D13]" {
    run sm '
        MULTIPLEX_STREAM_NAME="Studio Mix"
        resolve_multiplex_stream_name
        printf "name=%s\n" "$MULTIPLEX_STREAM_NAME"'
    [ "$status" -eq 0 ]
    [[ "$output" == *"name=studio_mix"* ]]
    [ "$(sd_count "$STREAM_MANAGER_LOG_FILE" "Multiplex stream name 'Studio Mix' is used as 'studio_mix'")" -eq 1 ]
}

@test "a name that is already canonical is not logged as a change [D13]" {
    run sm '
        MULTIPLEX_STREAM_NAME="studio_mix"
        resolve_multiplex_stream_name
        printf "name=%s\n" "$MULTIPLEX_STREAM_NAME"'
    [ "$status" -eq 0 ]
    [[ "$output" == *"name=studio_mix"* ]]
    [ "$(sd_count "$STREAM_MANAGER_LOG_FILE" "is used as")" -eq 0 ]
}

@test "the default name all_mics is canonical and unchanged [D13]" {
    run sm 'resolve_multiplex_stream_name; printf "name=%s\n" "$MULTIPLEX_STREAM_NAME"'
    [ "$status" -eq 0 ]
    [[ "$output" == *"name=all_mics"* ]]
}

@test "-n is canonicalised by the real command line: status finds the stream under the canonical name [LB-04]" {
    # Stand-in: a live process the status command can find through its PID file
    # (comm must be bash, as for a real wrapper)
    bash -c 'sleep 60; :' 3>&- &
    local pid=$!
    echo "$pid" >>"$SD_PIDS_FILE"
    echo "$pid" >"$SD/ff/studio_mix.pid"

    run bash "$LB_REAL_SCRIPT" -m multiplex -n 'Studio Mix' status
    [ "$status" -eq 0 ]
    [[ "$output" == *"Multiplex stream"* ]]
    [[ "$output" == *"rtsp://127.0.0.1:8554/studio_mix"* ]]
    [[ "$output" == *"Running"*"(PID: $pid)"* ]]
    [[ "$output" == *"Multiplex stream name 'Studio Mix' is used as 'studio_mix'"* ]]
}

@test "an unusable -n name stops a command before anything starts, with exit 4 and no cleanup marker [D13]" {
    # `start` is the command whose failed exit would leave the cleanup marker that
    # makes the next start tear the stack down; nothing of it has run yet
    run bash "$LB_REAL_SCRIPT" -m multiplex -n api start
    [ "$status" -eq 4 ]
    [[ "$output" == *"Invalid multiplex stream name: Stream name 'api' is reserved"* ]]
    [ ! -e "$MEDIAMTX_CLEANUP_MARKER" ]

    run bash "$LB_REAL_SCRIPT" -n '///' status
    [ "$status" -eq 4 ]
    [[ "$output" == *"has no letters or digits"* ]]
}

@test "an unusable environment name stops multiplex mode but not individual mode [D13]" {
    run env MULTIPLEX_STREAM_NAME=api STREAM_MODE=multiplex bash "$LB_REAL_SCRIPT" status
    [ "$status" -eq 4 ]
    [[ "$output" == *"Stream name 'api' is reserved"* ]]

    # Individual mode never uses the name: a stale environment value must not stop it
    run env MULTIPLEX_STREAM_NAME=api bash "$LB_REAL_SCRIPT" status
    [ "$status" -eq 0 ]
    [[ "$output" == *"Ignoring MULTIPLEX_STREAM_NAME (stream mode is not multiplex)"* ]]
    [[ "$output" == *"using 'all_mics'"* ]]
}

@test "help does not resolve or reject the name [D13]" {
    run bash "$LB_REAL_SCRIPT" -n api help
    [ "$status" -eq 0 ]
    [[ "$output" == *"Usage"* ]]
}

# ---------------------------------------------------------------------------
# Consumers
# ---------------------------------------------------------------------------

@test "the multiplex wrapper, its PID file and its stream path use the canonical name [LB-04]" {
    sd_fake_card 1 0c
    run sm "$SD_SPAWN_STUBS"'
        MULTIPLEX_STREAM_NAME="Studio Mix"; STREAM_MODE=multiplex
        resolve_multiplex_stream_name
        start_ffmpeg_multiplex_stream "usb-audio-fake:1"; echo "start rc=$?"
        ls "$MEDIAMTX_FFMPEG_DIR"'
    [ "$status" -eq 0 ]
    [[ "$output" == *"start rc=0"* ]]
    [ -f "$SD/ff/studio_mix.sh" ]
    [ -f "$SD/ff/studio_mix.pid" ]
    [ ! -e "$SD/ff/Studio Mix.sh" ]
    [ ! -e "$SD/ff/Studio Mix.pid" ]
    grep -E '^STREAM_PATH=' "$SD/ff/studio_mix.sh" | grep -q 'studio_mix'
    # the published URL is built from the wrapper's STREAM_PATH
    grep -qF 'rtsp://${MEDIAMTX_HOST}:${MEDIAMTX_RTSP_PORT}/${STREAM_PATH}' "$SD/ff/studio_mix.sh"
}

@test "the generated MediaMTX config has the same path name as the publisher [LB-04]" {
    run sm '
        MULTIPLEX_STREAM_NAME="Studio Mix"; STREAM_MODE=multiplex
        resolve_multiplex_stream_name
        generate_mediamtx_config >/dev/null 2>&1; echo "generate rc=$?"
        sed -n "/^paths:/,\$p" "$CONFIG_FILE"'
    [ "$status" -eq 0 ]
    [[ "$output" == *"generate rc=0"* ]]
    # one path, under the canonical name (quoted or not)
    [ "$(grep -cE "^  ['\"]?studio_mix['\"]?:\$" "$MEDIAMTX_CONFIG_FILE")" -eq 1 ]
    ! grep -qi 'Studio Mix' "$MEDIAMTX_CONFIG_FILE"
}

@test "a hostile name cannot add a YAML key to the generated config [LB-04]" {
    export RAW=$'x:\n    runOnInit: touch MARK\n  evil'
    run sm '
        MULTIPLEX_STREAM_NAME="$RAW"; STREAM_MODE=multiplex
        resolve_multiplex_stream_name
        generate_mediamtx_config >/dev/null 2>&1; echo "generate rc=$?"
        sed -n "/^paths:/,\$p" "$CONFIG_FILE"'
    [ "$status" -eq 0 ]
    [[ "$output" == *"generate rc=0"* ]]
    # exactly one path entry, and no runOnInit key anywhere
    [ "$(sed -n '/^paths:/,$p' "$MEDIAMTX_CONFIG_FILE" | grep -cE '^  [^ ]')" -eq 1 ]
    ! grep -qE '^[[:space:]]+runOnInit:' "$MEDIAMTX_CONFIG_FILE"
}

@test "start_ffmpeg_multiplex_stream refuses a name that was not canonicalised and writes nothing [D13]" {
    run sm "$SD_SPAWN_STUBS"'
        MULTIPLEX_STREAM_NAME="../evil name"; STREAM_MODE=multiplex
        rc=0; start_ffmpeg_multiplex_stream "usb-audio-fake:1" || rc=$?
        echo "start rc=$rc"'
    [ "$status" -eq 0 ]
    [[ "$output" == *"start rc=1"* ]]
    [[ "$output" == *"is not canonical"* ]]
    [ -z "$(ls -A "$SD/ff")" ]
    [ ! -e "$SD/evil name.sh" ]
}

@test "individual stream paths are unchanged for ordinary device names and reserved ones keep a prefix [D13]" {
    run sm '
        set +e
        for dev in usb-audio-Blue_Yeti-00 "usb-audio-USB Audio Device #1" usb-audio-1234 usb-audio-api Fifine_K669B; do
            printf "%s -> %s\n" "$dev" "$(generate_stream_path "$dev" "" 2>/dev/null)"
        done'
    [ "$status" -eq 0 ]
    [ "${lines[0]}" = "usb-audio-Blue_Yeti-00 -> blue_yeti_00" ]
    [ "${lines[1]}" = "usb-audio-USB Audio Device #1 -> usb_audio_device_1" ]
    [ "${lines[2]}" = "usb-audio-1234 -> stream_1234" ]
    [ "${lines[3]}" = "usb-audio-api -> stream_api" ]
    [ "${lines[4]}" = "Fifine_K669B -> fifine_k669b" ]
}

@test "monitor finds the multiplex stream under the canonical name, hyphen included, and does not restart it [LB-04]" {
    # The real pgrep: monitor identifies the wrapper by its command line
    rm -f "$SD/bin/pgrep"
    # Stand-ins for two live processes (comm "bash", as for a real wrapper and
    # for the PID check on MediaMTX): MediaMTX itself and the multiplex wrapper
    printf '#!/bin/bash\nsleep 300\n:\n' >"$SD/ff/my-mix.sh"
    chmod +x "$SD/ff/my-mix.sh"
    bash "$SD/ff/my-mix.sh" >/dev/null 2>&1 3>&- &
    local wrapper_pid=$!
    bash -c 'sleep 300; :' 3>&- &
    local mtx_pid=$!
    printf '%s\n%s\n' "$wrapper_pid" "$mtx_pid" >>"$SD_PIDS_FILE"
    echo "$wrapper_pid" >"$SD/ff/my-mix.pid"
    echo "$mtx_pid" >"$MEDIAMTX_PID_FILE"

    export STREAM_MODE=multiplex MULTIPLEX_STREAM_NAME=My-Mix DEEP_HEALTH_CHECK_ENABLED=false
    run sm '
        detect_audio_devices() { printf "mic1:1\n"; }
        start_ffmpeg_multiplex_stream() { echo restarted >>"$SD/restarts.log"; return 0; }
        resolve_multiplex_stream_name
        rc=0; monitor_streams || rc=$?
        echo "monitor rc=$rc name=$MULTIPLEX_STREAM_NAME"'
    [ "$status" -eq 0 ]
    [[ "$output" == *"monitor rc=0 name=my-mix"* ]]
    [ ! -e "$SD/restarts.log" ]
}

# ---------------------------------------------------------------------------
# Real MediaMTX (private network namespace)
# ---------------------------------------------------------------------------

# Script run inside the namespace: for each raw name, the real resolver, the real
# multiplex start (wrapper process stood in for), the real generator, a real
# MediaMTX and a real publisher to the path the wrapper publishes to.
_write_live_script() {
    # The multiplex start looks at a card: a fake one with a capture PCM
    sd_fake_card 98 0c
    cat >"$SD/live_names.sh" <<'LIVE'
#!/bin/bash
bin="$1"; shift
export MEDIAMTX_BINARY="$bin"
source "$LB_REAL_SCRIPT" || exit 99
set +e
cd "$SD" || exit 97
codec=aac
ffmpeg -hide_banner -encoders 2>/dev/null | grep -q libopus && codec=libopus
spawn_detached() {
    local fd
    for fd in 3 4 5 6 7 8 9; do eval "exec ${fd}>&-"; done
    command sleep 30
}
validate_stream() { return 0; }
for raw in "$@"; do
    rm -f "$MEDIAMTX_FFMPEG_DIR"/*
    STREAM_MODE=multiplex
    MULTIPLEX_STREAM_NAME="$raw"
    if ! canonical_stream_name "$raw" >/dev/null 2>&1; then
        printf 'RESULT|%q|REJECTED\n' "$raw"
        continue
    fi
    resolve_multiplex_stream_name 2>/dev/null
    start_ffmpeg_multiplex_stream "usb-audio-fake:98" >/dev/null 2>&1
    pidf="$(ls "$MEDIAMTX_FFMPEG_DIR"/*.pid 2>/dev/null | head -n 1)"
    pubpath="$(basename "${pidf:-/none.pid}" .pid)"
    generate_mediamtx_config >/dev/null 2>&1
    "$bin" "$CONFIG_FILE" >"$SD/mtx.log" 2>&1 &
    mp=$!
    for i in $(seq 1 50); do
        curl -sf --max-time 1 http://127.0.0.1:9997/v3/paths/list >/dev/null && break
        kill -0 "$mp" 2>/dev/null || break
        sleep 0.2
    done
    if ! kill -0 "$mp" 2>/dev/null; then
        printf 'RESULT|%q|%s|%s|MEDIAMTX-DIED %s\n' "$raw" "$MULTIPLEX_STREAM_NAME" "$pubpath" "$(grep -m1 -E 'ERR' "$SD/mtx.log" | cut -c1-120)"
        continue
    fi
    ffmpeg -nostdin -loglevel error -re -f lavfi -i "sine=frequency=440:sample_rate=48000" \
        -c:a "$codec" -f rtsp -rtsp_transport tcp "rtsp://127.0.0.1:8554/${pubpath}" >"$SD/pub.log" 2>&1 &
    fp=$!
    ready=no
    for i in $(seq 1 40); do
        if curl -sf --max-time 1 http://127.0.0.1:9997/v3/paths/list \
            | jq -e --arg n "$pubpath" '.items[] | select(.name == $n and .ready == true)' >/dev/null 2>&1; then
            ready=yes
            break
        fi
        sleep 0.2
    done
    printf 'RESULT|%q|%s|%s|ready=%s\n' "$raw" "$MULTIPLEX_STREAM_NAME" "$pubpath" "$ready"
    kill "$fp" "$mp" 2>/dev/null
    wait "$fp" "$mp" 2>/dev/null
done
LIVE
}

@test "every canonical name from the register's matrix loads in real MediaMTX and is published to [LB-04, live]" {
    sd_require_live
    _write_live_script
    local bin version
    while IFS= read -r bin; do
        version="$("$bin" --version 2>/dev/null | head -n 1)"
        echo "# MediaMTX $version" >&3
        run sd_ns_run "$SD/live_names.sh" "$bin" \
            'Studio Mix' 'Studio' 'studio' 'a/b' 'my.mix' 'Étude' '9lives' 'My-Mix_2' 'api'
        echo "$output" >&3
        [ "$status" -eq 0 ]
        [[ "$output" == *"RESULT|Studio\\ Mix|studio_mix|studio_mix|ready=yes"* ]]
        [[ "$output" == *"RESULT|Studio|studio|studio|ready=yes"* ]]
        [[ "$output" == *"RESULT|studio|studio|studio|ready=yes"* ]]
        [[ "$output" == *"RESULT|a/b|a_b|a_b|ready=yes"* ]]
        [[ "$output" == *"RESULT|my.mix|my_mix|my_mix|ready=yes"* ]]
        [[ "$output" == *"|tude|tude|ready=yes"* ]]
        [[ "$output" == *"RESULT|9lives|9lives|9lives|ready=yes"* ]]
        [[ "$output" == *"RESULT|My-Mix_2|my-mix_2|my-mix_2|ready=yes"* ]]
        [[ "$output" == *"RESULT|api|REJECTED"* ]]
        [ "$(grep -c '^RESULT|' <<<"$output")" -eq 9 ]
    done < <(sd_live_bins)
}

@test "a name with a newline and a runOnInit line starts MediaMTX without running the injected command [LB-04, live]" {
    sd_require_live
    _write_live_script
    local bin raw
    # MediaMTX runs from $SD (the live script changes into it), so MARK lands there
    raw=$'inj\n    runOnInit: touch MARK\n    runOnInitRestart: no'
    while IFS= read -r bin; do
        run sd_ns_run "$SD/live_names.sh" "$bin" "$raw"
        echo "$output" >&3
        [ "$status" -eq 0 ]
        [[ "$output" == *"ready=yes"* ]]
        [ ! -e "$SD/MARK" ]
    done < <(sd_live_bins)
}

# What the generator has to write for the names YAML would otherwise read as a
# boolean, null or number, and why "all" and "all_others" are reserved: both
# checked directly against MediaMTX with a hand-written config.
_write_handwritten_script() {
    cat >"$SD/live_handwritten.sh" <<'LIVE'
#!/bin/bash
bin="$1"; key="$2"; pubpath="$3"
codec=aac
ffmpeg -hide_banner -encoders 2>/dev/null | grep -q libopus && codec=libopus
cat >"$SD/hand.yml" <<YML
logLevel: info
api: yes
apiAddress: 127.0.0.1:9997
metrics: no
rtsp: yes
rtspAddress: 127.0.0.1:8554
rtspTransports: [tcp]
rtmp: no
hls: no
webrtc: no
srt: no
paths:
  '${key}':
    source: publisher
YML
"$bin" "$SD/hand.yml" >"$SD/hand.log" 2>&1 &
mp=$!
for i in $(seq 1 50); do
    curl -sf --max-time 1 http://127.0.0.1:9997/v3/paths/list >/dev/null && break
    kill -0 "$mp" 2>/dev/null || break
    sleep 0.2
done
ffmpeg -nostdin -loglevel error -re -f lavfi -i "sine=frequency=440:sample_rate=48000" \
    -c:a "$codec" -f rtsp -rtsp_transport tcp "rtsp://127.0.0.1:8554/${pubpath}" >"$SD/hand-pub.log" 2>&1 &
fp=$!
ready=no
for i in $(seq 1 40); do
    if curl -sf --max-time 1 http://127.0.0.1:9997/v3/paths/list \
        | jq -e --arg n "$pubpath" '.items[] | select(.name == $n and .ready == true)' >/dev/null 2>&1; then
        ready=yes
        break
    fi
    sleep 0.2
done
printf 'HAND|%s|%s|ready=%s\n' "$key" "$pubpath" "$ready"
kill "$fp" "$mp" 2>/dev/null
LIVE
}

@test "canonical names that YAML reads as null, bool or number load and publish when the key is quoted [D13, live]" {
    sd_require_live
    _write_handwritten_script
    local bin name
    while IFS= read -r bin; do
        for name in null yes 123; do
            run sd_ns_run "$SD/live_handwritten.sh" "$bin" "$name" "$name"
            [ "$status" -eq 0 ]
            [[ "$output" == *"HAND|$name|$name|ready=yes"* ]] || { echo "$name: $output"; false; }
        done
    done < <(sd_live_bins)
}

@test "all_others is a catch-all path in MediaMTX, which is why it is a reserved name [D13, live]" {
    sd_require_live
    _write_handwritten_script
    local bin
    while IFS= read -r bin; do
        # A publisher to a path that is NOT named all_others is accepted by it
        run sd_ns_run "$SD/live_handwritten.sh" "$bin" all_others somewhere_else
        [ "$status" -eq 0 ]
        [[ "$output" == *"HAND|all_others|somewhere_else|ready=yes"* ]] || { echo "$output"; false; }
        run sd_ns_run "$SD/live_handwritten.sh" "$bin" all somewhere_else
        [ "$status" -eq 0 ]
        [[ "$output" == *"HAND|all|somewhere_else|ready=yes"* ]] || { echo "$output"; false; }
    done < <(sd_live_bins)
}
