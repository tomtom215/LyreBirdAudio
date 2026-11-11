#!/usr/bin/env bats
# X-14: a deletion that fails (permission, immutable bit, read-only filesystem)
# must be counted, logged with rm's reason and reflected in the exit status.
# Before: safe_delete's `rm -rf` failed under `set -e`, which aborted the whole
# run at the first stuck file (nothing after it was cleaned, no summary), and
# emergency_cleanup's `find -delete 2>/dev/null || true` / `rm -rf ... || true`
# ignored failures outright, so a disk that stayed full looked like a clean run.

load scratch_tmpdir
load storage_helper

setup() {
    scratch_setup
    storage_setup
    ST_SHIM="$ST_ROOT/bin"
    mkdir -p "$ST_SHIM"
}

teardown() {
    storage_teardown
    scratch_teardown
}

# rm that refuses any path containing "stuck" (as an immutable file or a
# read-only filesystem would) and removes the rest. Every call is recorded.
_shim_rm() {
    cat >"$ST_SHIM/rm" <<EOF
#!/bin/bash
echo "\$*" >>"$ST_ROOT/rm.calls"
rc=0
paths=()
for a in "\$@"; do
    case "\$a" in
        --) ;;
        -*) ;;
        *) paths+=("\$a") ;;
    esac
done
for p in "\${paths[@]}"; do
    if [[ \$p == *stuck* ]]; then
        echo "rm: cannot remove '\$p': Operation not permitted" >&2
        rc=1
    else
        /bin/rm -rf -- "\$p" || rc=1
    fi
done
exit \$rc
EOF
    chmod +x "$ST_SHIM/rm"
    ST_ENV=(PATH="$ST_SHIM:$PATH")
}

# df for a 100 GB filesystem with blocks at $1% and inodes at $2% (free space
# stays above MIN_FREE_SPACE_MB, so only the percentages decide).
_shim_df() {
    cat >"$ST_SHIM/df" <<EOF
#!/bin/bash
for a in "\$@"; do
    case "\$a" in
        -*i*) echo "Filesystem Inodes IUsed IFree IUse% Mounted on"
              echo "/dev/root 1000000 $(($2 * 10000)) $(((100 - $2) * 10000)) $2% /"
              exit 0 ;;
    esac
done
echo "Filesystem 1024-blocks Used Available Capacity Mounted on"
echo "/dev/root 100000000 $(($1 * 1000000)) $(((100 - $1) * 1000000)) $1% /"
EOF
    chmod +x "$ST_SHIM/df"
}

_age() { touch -d "${2:-45 days ago}" "$1"; }

@test "a refused deletion is counted and logged, and cleanup carries on past it [X-14 regression]" {
    _shim_rm
    echo data >"$ST_REC/a-stuck.wav"
    echo data >"$ST_REC/z-fine.wav"
    _age "$ST_REC/a-stuck.wav"
    _age "$ST_REC/z-fine.wav"

    run storage_run cleanup_recordings
    [ "$status" -eq 0 ]                              # pre-fix: set -e aborted here with rm's status
    [[ "$output" == *"Cannot delete recording"*"a-stuck.wav"*"Operation not permitted"* ]]
    [[ "$output" == *"1 deletion(s) FAILED"* ]]
    [ -f "$ST_REC/a-stuck.wav" ]                     # still there, and reported
    [ ! -e "$ST_REC/z-fine.wav" ]                    # the rest was cleaned
}

@test "cmd_cleanup runs every step after a stuck file and exits EXIT_DELETE_FAILED [X-14 regression]" {
    _shim_rm
    echo data >"$ST_REC/stuck.wav"
    _age "$ST_REC/stuck.wav"
    echo data >"$ST_LOGS/old.log"
    _age "$ST_LOGS/old.log" "30 days ago"
    echo data >"$ST_TEMP/lyrebird-old.tmp"
    _age "$ST_TEMP/lyrebird-old.tmp" "3 days ago"

    run storage_run cmd_cleanup
    [ "$status" -eq 3 ]
    [[ "$output" == *"Run finished with 1 failed deletion(s)"* ]]
    [ -f "$ST_REC/stuck.wav" ]
    [ ! -e "$ST_LOGS/old.log" ]                      # cleanup_logs still ran
    [ ! -e "$ST_TEMP/lyrebird-old.tmp" ]             # cleanup_temp still ran
    [[ "$output" != *"Cleanup completed"* ]]         # not reported as a clean run
}

@test "a clean cmd_cleanup exits 0 and says so (control)" {
    _shim_rm
    echo data >"$ST_REC/old.wav"
    _age "$ST_REC/old.wav"
    run storage_run cmd_cleanup
    [ "$status" -eq 0 ]
    [[ "$output" == *"Cleanup completed"* ]]
    [[ "$output" != *"FAILED"* ]]
}

@test "the command line exits EXIT_DELETE_FAILED when a deletion failed [X-14 regression]" {
    _shim_rm
    echo data >"$ST_REC/stuck.opus"
    _age "$ST_REC/stuck.opus"
    run env PATH="$ST_SHIM:$PATH" LYREBIRD_RECORDING_DIR="$ST_REC" LYREBIRD_LOG_DIR="$ST_LOGS" \
        LYREBIRD_TEMP_DIR="$ST_TEMP" LYREBIRD_BUFFER_DIR="$ST_BUF" MEDIAMTX_LOG="$ST_LOGS/mediamtx.out" \
        bash "$PROJECT_ROOT/lyrebird-storage.sh" cleanup
    [ "$status" -eq 3 ]
    [[ "$output" == *"stuck.opus"* ]]
}

@test "emergency cleanup counts refused evictions, evicts the rest and exits EXIT_DELETE_FAILED [X-14 regression]" {
    _shim_rm
    echo data >"$ST_REC/stuck.aac"
    echo data >"$ST_REC/z-fine.aac"
    _age "$ST_REC/stuck.aac" "3 days ago"
    _age "$ST_REC/z-fine.aac" "2 days ago"

    run storage_run cmd_emergency
    [ "$status" -eq 3 ]
    [[ "$output" == *"Cannot delete emergency recording"*"stuck.aac"* ]]
    [[ "$output" == *"Emergency: Deleted 1 oldest recording(s); 1 deletion(s) FAILED"* ]]
    [ -f "$ST_REC/stuck.aac" ]
    [ ! -e "$ST_REC/z-fine.aac" ]
}

@test "emergency cleanup reports refused rotated-log, temp-file and buffer deletions [X-14 regression]" {
    _shim_rm
    echo data >"$ST_LOGS/stuck.log.1.gz"
    echo data >"$ST_TEMP/lyrebird-stuck.tmp"
    echo data >"$ST_BUF/stuck.opus"
    echo data >"$ST_BUF/audio_000.opus"
    _age "$ST_BUF/stuck.opus" "2 hours ago"          # idle: not an open segment
    _age "$ST_BUF/audio_000.opus" "2 hours ago"

    run storage_run cmd_emergency
    [ "$status" -eq 3 ]
    [[ "$output" == *"Cannot delete rotated log"*"stuck.log.1.gz"* ]]
    [[ "$output" == *"Cannot delete temp"*"lyrebird-stuck.tmp"* ]]
    [[ "$output" == *"Cannot delete emergency buffer file"*"stuck.opus"* ]]
    [ -f "$ST_LOGS/stuck.log.1.gz" ]
    [ -f "$ST_BUF/stuck.opus" ]
}

@test "a dry run never calls rm and never reports a failure" {
    _shim_rm
    echo data >"$ST_REC/stuck.wav"
    _age "$ST_REC/stuck.wav"
    ST_ENV+=(DRY_RUN=true)
    run storage_run cmd_cleanup
    [ "$status" -eq 0 ]
    # (the EXIT trap's own `rm -f /tmp/lyrebird-storage-*.tmp` is recorded too)
    ! grep -qF -- "$ST_REC" "$ST_ROOT/rm.calls" || false
    [ -f "$ST_REC/stuck.wav" ]
}

@test "a deletion that errors but leaves nothing behind (already gone) is not a failure" {
    cat >"$ST_SHIM/rm" <<'EOF'
#!/bin/bash
# Another run won the race: the file is gone, yet this rm reports an error.
for a in "$@"; do [[ $a == -* ]] || /bin/rm -f -- "$a"; done
echo "rm: transient error" >&2
exit 1
EOF
    chmod +x "$ST_SHIM/rm"
    ST_ENV=(PATH="$ST_SHIM:$PATH")
    echo data >"$ST_REC/raced.wav"
    _age "$ST_REC/raced.wav"
    run storage_run cmd_cleanup
    [ "$status" -eq 0 ]
    [[ "$output" != *"Cannot delete"* ]]
}

@test "monitor at CRITICAL usage exits EXIT_DELETE_FAILED when retention cannot delete [X-14 regression]" {
    _shim_rm
    _shim_df 91 10
    echo data >"$ST_REC/stuck.wav"
    _age "$ST_REC/stuck.wav"
    run storage_run cmd_monitor
    [ "$status" -eq 3 ]
    [[ "$output" == *"CRITICAL"* ]]
}

@test "monitor at EMERGENCY usage exits EXIT_DELETE_FAILED when eviction cannot delete [X-14 regression]" {
    _shim_rm
    _shim_df 97 10
    echo data >"$ST_REC/stuck.flac"
    _age "$ST_REC/stuck.flac" "2 days ago"
    run storage_run cmd_monitor
    [ "$status" -eq 3 ]
    [[ "$output" == *"EMERGENCY"* ]]
    [[ "$output" == *"Cannot delete emergency recording"* ]]
}

@test "monitor with an unparseable df still runs retention and reports its failures [X-14 regression]" {
    _shim_rm
    printf '#!/bin/bash\necho garbage-not-a-table\n' >"$ST_SHIM/df"
    chmod +x "$ST_SHIM/df"
    echo data >"$ST_REC/stuck.mp3"
    _age "$ST_REC/stuck.mp3"
    run storage_run cmd_monitor
    [ "$status" -eq 3 ]
    [[ "$output" == *"Could not determine disk usage"* ]]
}

@test "monitor at WARNING usage exits EXIT_DELETE_FAILED when a temp file cannot be deleted [X-14 regression]" {
    _shim_rm
    _shim_df 82 10
    echo data >"$ST_TEMP/lyrebird-stuck.tmp"
    _age "$ST_TEMP/lyrebird-stuck.tmp" "3 days ago"
    run storage_run cmd_monitor
    [ "$status" -eq 3 ]
    [[ "$output" == *"WARNING"* ]]
}

# The real thing, no shim: an immutable file refuses unlink() even for root.
# Needs a filesystem and privileges that support chattr +i (skipped otherwise).
@test "an immutable file (chattr +i) is reported, not silently skipped, and the run exits EXIT_DELETE_FAILED" {
    command -v chattr >/dev/null 2>&1 || skip "chattr not installed"
    echo data >"$ST_REC/pinned.wav"
    _age "$ST_REC/pinned.wav"
    chattr +i "$ST_REC/pinned.wav" 2>/dev/null || skip "chattr +i not supported here (needs root and ext4/xfs/btrfs)"
    echo data >"$ST_REC/free.wav"
    _age "$ST_REC/free.wav"

    run storage_run cmd_cleanup
    chattr -i "$ST_REC/pinned.wav"
    [ "$status" -eq 3 ]
    [[ "$output" == *"Cannot delete recording"*"pinned.wav"*"Operation not permitted"* ]]
    [ -f "$ST_REC/pinned.wav" ]
    [ ! -e "$ST_REC/free.wav" ]
}

@test "--help states the exit statuses, the active-segment variable and the recording extensions" {
    run env LYREBIRD_BUFFER_DIR="$ST_BUF" bash "$PROJECT_ROOT/lyrebird-storage.sh" --help
    [ "$status" -eq 0 ]
    [[ "$output" == *"Exit status:"* ]]
    [[ "$output" == *"3  finished, but at least one deletion failed"* ]]
    [[ "$output" == *"LYREBIRD_ACTIVE_SEGMENT_SECONDS"* ]]
    # The extension line is built from the one list, not typed a second time.
    [[ "$output" == *"Recordings are files ending in: $(storage_value RECORDING_EXTENSIONS | tr '\n' ' ' | sed 's/ $//')"* ]]
}
