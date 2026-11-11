#!/usr/bin/env bats
# X-14: the storage run must stay inside its configured directories.
#
# Cleanup runs unattended as root, so every way out of a directory is tested:
# symlinks inside the trees, `..` and symlinks in the configured buffer path,
# and file names that look like options or contain separators. The other
# direction matters as much: a configured directory that is itself a symlink
# (/var/lib/.../recordings -> /mnt/usb) is a normal setup, and `find` without
# -H saw only the link and reported nothing, so retention silently did nothing.

load scratch_tmpdir
load storage_helper

setup() {
    scratch_setup
    storage_setup
    # A decoy tree outside every configured directory, with old files of every
    # kind the script deletes.
    mkdir -p "$ST_OUTSIDE/tree/stream1"
    local f
    for f in tree/old.opus tree/old.aac tree/stream1/audio_000.mp3 old.log lyrebird-old.tmp tree/empty.opus; do
        echo precious >"$ST_OUTSIDE/$f"
    done
    : >"$ST_OUTSIDE/tree/empty.opus"
    find "$ST_OUTSIDE" -type f -exec touch -d "400 days ago" {} +
}

teardown() {
    storage_teardown
    scratch_teardown
}

_age() { touch -d "${2:-45 days ago}" "$1"; }

_decoys_intact() {
    local f
    for f in tree/old.opus tree/old.aac tree/stream1/audio_000.mp3 old.log lyrebird-old.tmp tree/empty.opus; do
        [ -e "$ST_OUTSIDE/$f" ] || { echo "outside file deleted: $f"; return 1; }
    done
}

# --- the run never leaves the configured directories ---------------------------

@test "a full cleanup and an emergency run delete nothing outside the configured directories" {
    echo data >"$ST_REC/old.opus"
    _age "$ST_REC/old.opus"
    run storage_run cmd_cleanup
    [ "$status" -eq 0 ]
    run storage_run cmd_emergency
    [ "$status" -eq 0 ]
    [ ! -e "$ST_REC/old.opus" ]                    # inside: cleaned
    _decoys_intact
}

@test "symlinked recordings and directories inside the trees are not followed [X-14]" {
    # A link to an outside recording, and a link to an outside directory full of them.
    ln -s "$ST_OUTSIDE/tree/old.opus" "$ST_REC/audio_000.opus"
    ln -s "$ST_OUTSIDE/tree" "$ST_REC/linkdir"
    ln -s "$ST_OUTSIDE/tree" "$ST_BUF/linkdir"
    ln -s "$ST_OUTSIDE/tree/old.aac" "$ST_BUF/audio_000.aac"
    ln -s "$ST_OUTSIDE/old.log" "$ST_LOGS/old.log"
    ln -s "$ST_OUTSIDE/lyrebird-old.tmp" "$ST_TEMP/lyrebird-old.tmp"
    ln -s . "$ST_REC/loop"                          # a cycle must not hang or recurse
    local l
    for l in "$ST_REC/audio_000.opus" "$ST_REC/linkdir" "$ST_BUF/linkdir" "$ST_BUF/audio_000.aac" \
        "$ST_LOGS/old.log" "$ST_TEMP/lyrebird-old.tmp"; do
        touch -h -d "400 days ago" "$l"
    done

    run storage_run cmd_cleanup
    [ "$status" -eq 0 ]
    run storage_run cmd_emergency
    [ "$status" -eq 0 ]
    _decoys_intact
    # The links themselves are not recordings and stay as they were.
    [ -L "$ST_REC/audio_000.opus" ]
    [ -L "$ST_REC/linkdir" ]
    [ -L "$ST_BUF/linkdir" ]
    [ -L "$ST_REC/loop" ]
}

@test "symlinks are not followed when a retention run empties directories either [X-14]" {
    mkdir -p "$ST_REC/real" "$ST_OUTSIDE/tree/emptysub"
    ln -s "$ST_OUTSIDE/tree" "$ST_REC/real/escape"
    run storage_run cleanup_recordings
    [ "$status" -eq 0 ]
    [ -d "$ST_OUTSIDE/tree/stream1" ]
    [ -d "$ST_OUTSIDE/tree/emptysub" ]               # an empty directory out there is not swept
    [ -L "$ST_REC/real/escape" ]
    _decoys_intact
}

@test "a relative recording directory with awkward file names is handled inside it [X-14]" {
    mkdir -p "$ST_CWD/rel/-dashdir"
    echo data >"$ST_CWD/rel/-dashdir/-rf.opus"
    echo data >"$ST_CWD/rel/two words.aac"
    echo keep >"$ST_CWD/outside.opus"
    find "$ST_CWD" -type f -exec touch -d "400 days ago" {} +
    ST_ENV=(LYREBIRD_RECORDING_DIR=rel)
    run storage_run cmd_cleanup
    [ "$status" -eq 0 ]
    [ ! -e "$ST_CWD/rel/-dashdir/-rf.opus" ]
    [ ! -e "$ST_CWD/rel/two words.aac" ]
    [ -f "$ST_CWD/outside.opus" ]                     # the cwd itself is not the recording directory
}

# --- `..` and symlinks in the configured buffer path ---------------------------

@test "a BUFFER_DIR that escapes the allowed parents through .. is refused at load [X-14]" {
    # /tmp/<x>/../../var/lib/... resolves outside /dev/shm, /tmp, /var/tmp and /run.
    local target="/var/lib/lyrebird-test-nonexistent-$$"
    run env PROJECT_ROOT="$PROJECT_ROOT" LYREBIRD_BUFFER_DIR="$ST_BUF/../../..$target" \
        bash -c 'source "$PROJECT_ROOT/lyrebird-storage.sh"'
    [ "$status" -eq 1 ]
    [[ "$output" == *"is not under allowed directories"* ]]
}

@test "a BUFFER_DIR symlink that points outside the allowed parents is refused at load [X-14]" {
    local link="/tmp/lyrebird-test-bufferlink.$$"
    ln -s "/var/lib/lyrebird-test-nonexistent-$$" "$link"
    run env PROJECT_ROOT="$PROJECT_ROOT" LYREBIRD_BUFFER_DIR="$link" \
        bash -c 'source "$PROJECT_ROOT/lyrebird-storage.sh"'
    rm -f "$link"
    [ "$status" -eq 1 ]
    [[ "$output" == *"is not under allowed directories"* ]]
}

@test "a BUFFER_DIR with .. that stays inside an allowed parent is accepted and resolved [X-14]" {
    mkdir -p "$ST_BUF/a" "$ST_BUF/b"
    echo data >"$ST_BUF/b/seg.opus"
    _age "$ST_BUF/b/seg.opus" "2 hours ago"
    ST_ENV=(LYREBIRD_BUFFER_DIR="$ST_BUF/a/../b")
    run storage_run emergency_cleanup
    [ "$status" -eq 0 ]
    [ ! -e "$ST_BUF/b/seg.opus" ]
}

# --- a configured directory that is itself a symlink ---------------------------------

@test "retention works when the recording directory is a symlink to the real directory [X-14 regression]" {
    mkdir -p "$ST_ROOT/real-recordings"
    echo data >"$ST_ROOT/real-recordings/old.opus"
    echo data >"$ST_ROOT/real-recordings/new.opus"
    : >"$ST_ROOT/real-recordings/idle.aac"
    _age "$ST_ROOT/real-recordings/old.opus" "45 days ago"
    _age "$ST_ROOT/real-recordings/idle.aac" "2 hours ago"
    ln -s "$ST_ROOT/real-recordings" "$ST_ROOT/recordings-link"
    ST_ENV=(LYREBIRD_RECORDING_DIR="$ST_ROOT/recordings-link")
    run storage_run cleanup_recordings
    [ "$status" -eq 0 ]
    [ ! -e "$ST_ROOT/real-recordings/old.opus" ]    # pre-fix: untouched, find saw only the link
    [ ! -e "$ST_ROOT/real-recordings/idle.aac" ]
    [ -e "$ST_ROOT/real-recordings/new.opus" ]
    [ -L "$ST_ROOT/recordings-link" ]               # the link and the directory are never removed
    [ -d "$ST_ROOT/real-recordings" ]
}

@test "emergency eviction works when the recording directory is a symlink [X-14 regression]" {
    mkdir -p "$ST_ROOT/real-recordings"
    echo data >"$ST_ROOT/real-recordings/old.opus"
    _age "$ST_ROOT/real-recordings/old.opus" "3 hours ago"
    ln -s "$ST_ROOT/real-recordings" "$ST_ROOT/recordings-link"
    ST_ENV=(LYREBIRD_RECORDING_DIR="$ST_ROOT/recordings-link")
    run storage_run emergency_cleanup
    [ "$status" -eq 0 ]
    [ ! -e "$ST_ROOT/real-recordings/old.opus" ]
}

@test "the buffer is cleared when BUFFER_DIR is a symlink to a real directory under an allowed parent [X-14 regression]" {
    local real link
    real="$(mktemp -d /tmp/lyrebird-test-realbuf.XXXXXX)"
    link="/tmp/lyrebird-test-buflink.$$"
    ln -s "$real" "$link"
    echo data >"$real/seg.opus"
    _age "$real/seg.opus" "3 hours ago"
    ST_ENV=(LYREBIRD_BUFFER_DIR="$link")
    run storage_run emergency_cleanup
    local gone=0
    [ ! -e "$real/seg.opus" ] && gone=1
    rm -rf "$real" "$link"
    [ "$status" -eq 0 ]
    [ "$gone" -eq 1 ]
}

@test "status reports the real size and file count of a symlinked recording directory [X-14 regression]" {
    mkdir -p "$ST_ROOT/real-recordings"
    head -c 100000 /dev/zero >"$ST_ROOT/real-recordings/a.opus"
    ln -s "$ST_ROOT/real-recordings" "$ST_ROOT/recordings-link"
    ST_ENV=(LYREBIRD_RECORDING_DIR="$ST_ROOT/recordings-link")
    run storage_run cmd_status
    [ "$status" -eq 0 ]
    [[ "$output" == *"Files: 1"* ]]
    # ~100KB of data, not the few bytes of the link itself
    [[ "$output" =~ Size:\ ([0-9]+)\.[0-9]+KB ]] || { echo "$output"; return 1; }
    [ "${BASH_REMATCH[1]}" -ge 90 ]
}

@test "temp cleanup also reaches the buffer through a BUFFER_DIR symlink [X-14 regression]" {
    local real link
    real="$(mktemp -d /tmp/lyrebird-test-realbuf.XXXXXX)"
    link="/tmp/lyrebird-test-buflink.$$"
    ln -s "$real" "$link"
    echo data >"$real/seg.opus"
    _age "$real/seg.opus" "3 days ago"
    ST_ENV=(LYREBIRD_BUFFER_DIR="$link")
    run storage_run cleanup_temp
    local gone=0
    [ ! -e "$real/seg.opus" ] && gone=1
    rm -rf "$real" "$link"
    [ "$status" -eq 0 ]
    [ "$gone" -eq 1 ]
}
