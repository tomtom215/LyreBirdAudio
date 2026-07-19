#!/usr/bin/env bats
# Unit tests for lyrebird-storage.sh
# Run with: bats tests/test_lyrebird_storage.bats
# Install bats: sudo apt-get install bats

# Setup - source the storage script
setup() {
    # Get the directory of this test file
    TEST_DIR="$( cd "$( dirname "$BATS_TEST_FILENAME" )" && pwd )"
    PROJECT_ROOT="$( cd "$TEST_DIR/.." && pwd )"

    # Create temp directories for testing
    export RECORDING_DIR="$(mktemp -d)"
    export LOG_DIR="$(mktemp -d)"
    export TEMP_DIR="$(mktemp -d)"

    # Set conservative thresholds for testing
    export DISK_WARNING_PERCENT=80
    export DISK_CRITICAL_PERCENT=90
    export RECORDING_RETENTION_DAYS=30
    export LOG_RETENTION_DAYS=7
    export LOG_MAX_SIZE_MB=50

    # Source the storage script
    source "$PROJECT_ROOT/lyrebird-storage.sh"

    # The script enables `set -euo pipefail`, which leaks into the bats test
    # shell and turns failing assertions / unset-var reads into silent aborts
    # (bats loses control of errexit and stops emitting results). Restore bats'
    # own error handling so failures report as "not ok" instead of vanishing.
    set +euo pipefail
}

# Teardown - clean up temp directories
teardown() {
    rm -rf "$RECORDING_DIR" 2>/dev/null || true
    rm -rf "$LOG_DIR" 2>/dev/null || true
    rm -rf "$TEMP_DIR" 2>/dev/null || true
}

# ============================================================================
# Script Metadata Tests
# ============================================================================

@test "SCRIPT_VERSION is defined" {
    [ -n "$SCRIPT_VERSION" ]
    [[ "$SCRIPT_VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]
}

@test "SCRIPT_NAME is lyrebird-storage" {
    [ "$SCRIPT_NAME" = "lyrebird-storage" ]
}

# ============================================================================
# Configuration Tests
# ============================================================================

@test "DISK_WARNING_PERCENT has default value" {
    [ -n "$DISK_WARNING_PERCENT" ]
    [ "$DISK_WARNING_PERCENT" -ge 0 ]
    [ "$DISK_WARNING_PERCENT" -le 100 ]
}

@test "DISK_CRITICAL_PERCENT has default value" {
    [ -n "$DISK_CRITICAL_PERCENT" ]
    [ "$DISK_CRITICAL_PERCENT" -ge 0 ]
    [ "$DISK_CRITICAL_PERCENT" -le 100 ]
}

@test "DISK_CRITICAL_PERCENT is higher than DISK_WARNING_PERCENT" {
    [ "$DISK_CRITICAL_PERCENT" -ge "$DISK_WARNING_PERCENT" ]
}

@test "RECORDING_RETENTION_DAYS has default value" {
    [ -n "$RECORDING_RETENTION_DAYS" ]
    [ "$RECORDING_RETENTION_DAYS" -ge 1 ]
}

@test "LOG_RETENTION_DAYS has default value" {
    [ -n "$LOG_RETENTION_DAYS" ]
    [ "$LOG_RETENTION_DAYS" -ge 1 ]
}

# ============================================================================
# Logging Function Tests
# ============================================================================

@test "log function exists" {
    run type log
    [ "$status" -eq 0 ]
}

@test "log_info function exists" {
    run type log_info
    [ "$status" -eq 0 ]
}

@test "log_warn function exists" {
    run type log_warn
    [ "$status" -eq 0 ]
}

@test "log_error function exists" {
    run type log_error
    [ "$status" -eq 0 ]
}

@test "log_debug function exists" {
    run type log_debug
    [ "$status" -eq 0 ]
}

# ============================================================================
# format_bytes Tests
# ============================================================================

@test "format_bytes handles zero" {
    run format_bytes 0
    [ "$status" -eq 0 ]
    [[ "$output" =~ "0" ]]
}

@test "format_bytes handles bytes" {
    run format_bytes 500
    [ "$status" -eq 0 ]
    [[ "$output" =~ "B" ]]
}

@test "format_bytes handles kilobytes" {
    run format_bytes 2048
    [ "$status" -eq 0 ]
    [[ "$output" =~ "K" ]]
}

@test "format_bytes handles megabytes" {
    run format_bytes 5242880
    [ "$status" -eq 0 ]
    [[ "$output" =~ "M" ]]
}

@test "format_bytes handles gigabytes" {
    run format_bytes 5368709120
    [ "$status" -eq 0 ]
    [[ "$output" =~ "G" ]]
}

# ============================================================================
# get_disk_usage Tests
# ============================================================================

@test "get_disk_usage returns numeric value" {
    run get_disk_usage "/"
    [ "$status" -eq 0 ]
    [[ "$output" =~ ^[0-9]+$ ]]
}

@test "get_disk_usage returns value between 0 and 100" {
    usage=$(get_disk_usage "/")
    [ "$usage" -ge 0 ]
    [ "$usage" -le 100 ]
}

@test "get_disk_usage handles temp directory" {
    run get_disk_usage "$TEMP_DIR"
    [ "$status" -eq 0 ]
    [[ "$output" =~ ^[0-9]+$ ]]
}

# ============================================================================
# get_free_space_mb Tests
# ============================================================================

@test "get_free_space_mb returns numeric value" {
    run get_free_space_mb "/"
    [ "$status" -eq 0 ]
    [[ "$output" =~ ^[0-9]+$ ]]
}

@test "get_free_space_mb returns positive value" {
    space=$(get_free_space_mb "/")
    [ "$space" -ge 0 ]
}

# ============================================================================
# get_dir_size Tests
# ============================================================================

@test "get_dir_size returns numeric value for empty dir" {
    run get_dir_size "$TEMP_DIR"
    [ "$status" -eq 0 ]
    [[ "$output" =~ ^[0-9]+$ ]]
}

@test "get_dir_size returns correct size for file" {
    # Create a 1KB file
    dd if=/dev/zero of="$TEMP_DIR/testfile" bs=1024 count=1 2>/dev/null
    run get_dir_size "$TEMP_DIR"
    [ "$status" -eq 0 ]
    # Should be at least 1 (KB)
    [ "$output" -ge 1 ]
}

# ============================================================================
# count_files Tests
# ============================================================================

@test "count_files returns 0 for empty directory" {
    run count_files "$TEMP_DIR" "*.wav"
    [ "$status" -eq 0 ]
    [ "$output" -eq 0 ]
}

@test "count_files counts matching files" {
    touch "$TEMP_DIR/file1.wav" "$TEMP_DIR/file2.wav" "$TEMP_DIR/file3.txt"
    run count_files "$TEMP_DIR" "*.wav"
    [ "$status" -eq 0 ]
    [ "$output" -eq 2 ]
}

@test "count_files handles no matches" {
    touch "$TEMP_DIR/file1.txt" "$TEMP_DIR/file2.txt"
    run count_files "$TEMP_DIR" "*.wav"
    [ "$status" -eq 0 ]
    [ "$output" -eq 0 ]
}

# ============================================================================
# safe_delete Tests
# ============================================================================

@test "safe_delete removes file when safe" {
    local test_file="$TEMP_DIR/deleteme.txt"
    echo "test" > "$test_file"
    [ -f "$test_file" ]

    run safe_delete "$test_file"
    [ "$status" -eq 0 ]
    [ ! -f "$test_file" ]
}

@test "safe_delete handles nonexistent file" {
    run safe_delete "$TEMP_DIR/nonexistent_file_xyz"
    # Should not fail for nonexistent file
    [ "$status" -eq 0 ] || [ "$status" -eq 1 ]
}

# ============================================================================
# cleanup_recordings Tests
# ============================================================================

@test "cleanup_recordings function exists" {
    run type cleanup_recordings
    [ "$status" -eq 0 ]
}

@test "cleanup_recordings handles empty directory" {
    run cleanup_recordings
    [ "$status" -eq 0 ]
}

@test "cleanup_recordings respects retention days" {
    # Create a file that's old enough to delete
    local old_file="$RECORDING_DIR/old_recording.wav"
    touch -d "40 days ago" "$old_file" 2>/dev/null || touch "$old_file"

    # This should not fail
    run cleanup_recordings
    [ "$status" -eq 0 ]
}

# ============================================================================
# cleanup_logs Tests
# ============================================================================

@test "cleanup_logs function exists" {
    run type cleanup_logs
    [ "$status" -eq 0 ]
}

@test "cleanup_logs handles empty directory" {
    run cleanup_logs
    [ "$status" -eq 0 ]
}

# ============================================================================
# cleanup_temp Tests
# ============================================================================

@test "cleanup_temp function exists" {
    run type cleanup_temp
    [ "$status" -eq 0 ]
}

@test "cleanup_temp handles empty directory" {
    run cleanup_temp
    [ "$status" -eq 0 ]
}

# ============================================================================
# truncate_large_logs Tests
# ============================================================================

@test "truncate_large_logs function exists" {
    run type truncate_large_logs
    [ "$status" -eq 0 ]
}

@test "truncate_large_logs handles empty directory" {
    run truncate_large_logs
    [ "$status" -eq 0 ]
}

# ============================================================================
# emergency_cleanup Tests
# ============================================================================

@test "emergency_cleanup function exists" {
    run type emergency_cleanup
    [ "$status" -eq 0 ]
}

# ============================================================================
# Command Function Tests
# ============================================================================

@test "cmd_status function exists" {
    run type cmd_status
    [ "$status" -eq 0 ]
}

@test "cmd_status runs without error" {
    run cmd_status
    [ "$status" -eq 0 ]
}

@test "cmd_status outputs disk usage" {
    run cmd_status
    [ "$status" -eq 0 ]
    [[ "$output" =~ [Dd]isk ]] || [[ "$output" =~ [Uu]sage ]] || [[ "$output" =~ [Ss]torage ]]
}

@test "cmd_cleanup function exists" {
    run type cmd_cleanup
    [ "$status" -eq 0 ]
}

@test "cmd_monitor function exists" {
    run type cmd_monitor
    [ "$status" -eq 0 ]
}

@test "cmd_emergency function exists" {
    run type cmd_emergency
    [ "$status" -eq 0 ]
}

# ============================================================================
# Help and Main Tests
# ============================================================================

@test "show_help runs without error" {
    run show_help
    [ "$status" -eq 0 ]
    [[ "$output" =~ "USAGE" ]] || [[ "$output" =~ "Usage" ]]
}

@test "show_help displays available commands" {
    run show_help
    [ "$status" -eq 0 ]
    [[ "$output" =~ "status" ]]
    [[ "$output" =~ "cleanup" ]]
}

@test "main function exists" {
    run type main
    [ "$status" -eq 0 ]
}

# ============================================================================
# Regression tests (exercise the REAL functions with proper path overrides)
# ============================================================================

@test "cleanup_recordings survives a 0-byte recording under set -e [H1 regression]" {
    local rec; rec="$(mktemp -d)"
    : > "$rec/old.wav"                                   # 0-byte recording
    touch -d "400 days ago" "$rec/old.wav" 2>/dev/null || touch "$rec/old.wav"
    # ((freed_bytes += size)) returned exit 1 when the running total was still 0
    # and the file was 0 bytes; under set -e that aborted cleanup mid-run, so the
    # disk kept filling. Must now complete cleanly.
    run env PROJECT_ROOT="$PROJECT_ROOT" LYREBIRD_RECORDING_DIR="$rec" DRY_RUN=false \
        bash -c 'set -euo pipefail; source "$PROJECT_ROOT/lyrebird-storage.sh"; cleanup_recordings'
    rm -rf "$rec"
    [ "$status" -eq 0 ]
}

@test "emergency_cleanup does not delete unrelated system logs [H2 regression]" {
    local logdir; logdir="$(mktemp -d)"
    : > "$logdir/syslog.1.gz"           # unrelated system log
    : > "$logdir/mediamtx.out.1.gz"     # our own rotated log
    run env PROJECT_ROOT="$PROJECT_ROOT" MEDIAMTX_LOG="$logdir/mediamtx.out" \
        LYREBIRD_RECORDING_DIR="$(mktemp -d)" LYREBIRD_LOG_DIR="$(mktemp -d)" \
        LYREBIRD_BUFFER_DIR="$(mktemp -d)" DRY_RUN=false \
        bash -c 'source "$PROJECT_ROOT/lyrebird-storage.sh"; emergency_cleanup'
    local survived=0
    [ -f "$logdir/syslog.1.gz" ] && survived=1
    rm -rf "$logdir"
    [ "$survived" -eq 1 ]              # MEDIAMTX_LOG_DIR is /var/log in production
}

@test "emergency_cleanup with DRY_RUN deletes nothing [H3 regression]" {
    local logdir; logdir="$(mktemp -d)"; local buf; buf="$(mktemp -d)"
    : > "$logdir/mediamtx.out.1.gz"
    : > "$buf/chunk.raw"
    run env PROJECT_ROOT="$PROJECT_ROOT" MEDIAMTX_LOG="$logdir/mediamtx.out" \
        LYREBIRD_RECORDING_DIR="$(mktemp -d)" LYREBIRD_LOG_DIR="$(mktemp -d)" \
        LYREBIRD_BUFFER_DIR="$buf" DRY_RUN=true \
        bash -c 'source "$PROJECT_ROOT/lyrebird-storage.sh"; emergency_cleanup'
    local gz=0 raw=0
    [ -f "$logdir/mediamtx.out.1.gz" ] && gz=1
    [ -f "$buf/chunk.raw" ] && raw=1
    rm -rf "$logdir" "$buf"
    [ "$gz" -eq 1 ]
    [ "$raw" -eq 1 ]
}

# --- STORAGE-1: df misparse on wrapped/long device names -> false "OK" --------

# A fake `df` that mimics REAL GNU df with a long device name at 97% used /
# 30000 KB free: without -P it WRAPS the long name onto its own line (so the old
# `df | tail -1 | awk '{print $5}'` reads the mount point, not Use%); with -P it
# stays single-line (so the fixed code parses columns correctly). This is what
# makes the tests below fail against the pre-fix code and pass against the fix.
_write_fake_df() {
    local bin="$1"
    cat > "$bin/df" <<'DFEOF'
#!/bin/bash
posix=0
for a in "$@"; do [[ "$a" == -*P* ]] && posix=1; done
echo "Filesystem                              1024-blocks    Used Available Capacity Mounted on"
if [[ $posix -eq 1 ]]; then
    echo "/dev/mapper/vg--data-really--long--name     1000000  970000     30000      97% /"
else
    echo "/dev/mapper/vg--data-really--long--name"
    echo "                                            1000000  970000     30000      97% /"
fi
DFEOF
    chmod +x "$bin/df"
}

@test "get_disk_usage returns the percent, not the mount point, for a long device name [STORAGE-1 regression]" {
    local bin; bin="$(mktemp -d)"; _write_fake_df "$bin"
    run env PROJECT_ROOT="$PROJECT_ROOT" PATH="$bin:$PATH" \
        bash -c 'source "$PROJECT_ROOT/lyrebird-storage.sh"; get_disk_usage /'
    rm -rf "$bin"
    [ "$status" -eq 0 ]
    [ "$output" = "97" ]
}

@test "get_free_space_mb returns free MB, not the Use% column, for a long device name [STORAGE-1 regression]" {
    local bin; bin="$(mktemp -d)"; _write_fake_df "$bin"
    run env PROJECT_ROOT="$PROJECT_ROOT" PATH="$bin:$PATH" \
        bash -c 'source "$PROJECT_ROOT/lyrebird-storage.sh"; get_free_space_mb /'
    rm -rf "$bin"
    [ "$status" -eq 0 ]
    [ "$output" = "29" ]                 # 30000 KB / 1024
}

@test "cmd_monitor detects a full disk hidden behind a wrapped df name [STORAGE-1 regression]" {
    local bin; bin="$(mktemp -d)"; _write_fake_df "$bin"
    # DRY_RUN=true: the EMERGENCY log still fires but nothing is deleted.
    run env PROJECT_ROOT="$PROJECT_ROOT" PATH="$bin:$PATH" \
        LYREBIRD_RECORDING_DIR="$(mktemp -d)" LYREBIRD_LOG_DIR="$(mktemp -d)" \
        LYREBIRD_BUFFER_DIR="$(mktemp -d)" DRY_RUN=true \
        bash -c 'source "$PROJECT_ROOT/lyrebird-storage.sh"; cmd_monitor 2>&1'
    rm -rf "$bin"
    [ "$status" -eq 0 ]
    [[ "$output" =~ EMERGENCY ]]         # old code parsed usage as "/" -> "OK"
}

@test "cmd_monitor never runs emergency deletion on unparseable df [STORAGE-1 regression]" {
    local bin; bin="$(mktemp -d)"
    printf '#!/bin/bash\necho garbage-not-a-table\n' > "$bin/df"; chmod +x "$bin/df"
    local rec; rec="$(mktemp -d)"; : > "$rec/keep.wav"   # fresh recording
    run env PROJECT_ROOT="$PROJECT_ROOT" PATH="$bin:$PATH" LYREBIRD_RECORDING_DIR="$rec" \
        LYREBIRD_LOG_DIR="$(mktemp -d)" DRY_RUN=false \
        bash -c 'source "$PROJECT_ROOT/lyrebird-storage.sh"; cmd_monitor 2>&1'
    local kept=0; [ -f "$rec/keep.wav" ] && kept=1
    rm -rf "$rec" "$bin"
    [ "$status" -eq 0 ]
    [ "$kept" -eq 1 ]                    # emergency (age-blind) deletion must NOT run
    [[ "$output" =~ [Cc]ould\ not\ determine ]]
}

# --- STORAGE-2: empty-dir cleanup deleting the recording root ------------------

@test "cleanup_recordings keeps RECORDING_DIR itself after it empties [STORAGE-2 regression]" {
    local rec; rec="$(mktemp -d)"
    : > "$rec/old.wav"
    touch -d "400 days ago" "$rec/old.wav" 2>/dev/null || touch "$rec/old.wav"
    run env PROJECT_ROOT="$PROJECT_ROOT" LYREBIRD_RECORDING_DIR="$rec" DRY_RUN=false \
        bash -c 'source "$PROJECT_ROOT/lyrebird-storage.sh"; cleanup_recordings'
    local dir_exists=0 file_gone=0
    [ -d "$rec" ] && dir_exists=1
    [ ! -f "$rec/old.wav" ] && file_gone=1
    rm -rf "$rec"
    [ "$status" -eq 0 ]
    [ "$dir_exists" -eq 1 ]              # dir must survive so recording can resume
    [ "$file_gone" -eq 1 ]              # but the aged-out recording is removed
}

# --- STORAGE-3: in-place log truncation preserving the inode -------------------

@test "truncate_large_logs truncates in place, preserving the inode [STORAGE-3 regression]" {
    local logdir; logdir="$(mktemp -d)"; local log="$logdir/mediamtx.out"
    head -c 5000 /dev/zero | tr '\0' 'x' > "$log"
    local inode_before; inode_before=$(stat -c%i "$log")
    run env PROJECT_ROOT="$PROJECT_ROOT" MEDIAMTX_LOG="$log" MAX_LOG_SIZE=1024 \
        LYREBIRD_LOG_DIR="$(mktemp -d)" DRY_RUN=false \
        bash -c 'source "$PROJECT_ROOT/lyrebird-storage.sh"; truncate_large_logs'
    local inode_after; inode_after=$(stat -c%i "$log" 2>/dev/null || echo GONE)
    rm -rf "$logdir"
    [ "$status" -eq 0 ]
    [ "$inode_before" = "$inode_after" ]   # old `mv tmp log` changed the inode
}

# --- STORAGE-4: non-integer env values aborting the script at load ------------

@test "non-integer retention env does not abort the script at load [STORAGE-4 regression]" {
    run env PROJECT_ROOT="$PROJECT_ROOT" RECORDING_RETENTION_DAYS=none LOG_RETENTION_DAYS=unlimited \
        bash -c 'set -euo pipefail; source "$PROJECT_ROOT/lyrebird-storage.sh"; echo "rec=$RECORDING_RETENTION_DAYS log=$LOG_RETENTION_DAYS"'
    [ "$status" -eq 0 ]
    [[ "$output" =~ rec=30 ]]
    [[ "$output" =~ log=7 ]]
}

@test "leading-zero retention env is coerced base-10, not octal-broken [STORAGE-4 regression]" {
    run env PROJECT_ROOT="$PROJECT_ROOT" RECORDING_RETENTION_DAYS=08 \
        bash -c 'set -euo pipefail; source "$PROJECT_ROOT/lyrebird-storage.sh"; echo "rec=$RECORDING_RETENTION_DAYS"'
    [ "$status" -eq 0 ]
    [[ "$output" =~ rec=8 ]]
}
