#!/usr/bin/env bats
# Inode-exhaustion detection tests (resource-exhaustion domain).
#
# A recorder writing many small files exhausts INODES long before blocks: every
# write fails ENOSPC while block-based monitoring still reports the disk "OK",
# so cleanup never runs -- silent recording failure on an unattended node.
# cmd_monitor must treat inode pressure like block pressure.

setup() {
    TEST_DIR="$( cd "$( dirname "$BATS_TEST_FILENAME" )" && pwd )"
    PROJECT_ROOT="$( cd "$TEST_DIR/.." && pwd )"
    IN_TMP="$(mktemp -d)"
    mkdir -p "$IN_TMP/bin" "$IN_TMP/rec" "$IN_TMP/logs"
    IN_BUF="$(mktemp -d /tmp/lyrebird-inode-buffer.XXXXXX)"
}

teardown() {
    rm -rf "$IN_TMP" "$IN_BUF" 2>/dev/null || true
}

# Fake df: blocks at $1%, inodes at $2%.
_write_df() {
    local block_pct="$1" inode_pct="$2"
    cat > "$IN_TMP/bin/df" <<EOF
#!/bin/bash
for a in "\$@"; do
    case "\$a" in
        -*i*) echo "Filesystem Inodes IUsed IFree IUse% Mounted on"
              echo "/dev/root 1000000 $((inode_pct * 10000)) $(( (100 - inode_pct) * 10000 )) ${inode_pct}% /"
              exit 0 ;;
    esac
done
echo "Filesystem 1024-blocks Used Available Capacity Mounted on"
echo "/dev/root 1000000 $((block_pct * 10000)) $(( (100 - block_pct) * 10000 )) ${block_pct}% /"
EOF
    chmod +x "$IN_TMP/bin/df"
}

_run_monitor() {
    env PROJECT_ROOT="$PROJECT_ROOT" PATH="$IN_TMP/bin:$PATH" \
        LYREBIRD_RECORDING_DIR="$IN_TMP/rec" LYREBIRD_LOG_DIR="$IN_TMP/logs" \
        LYREBIRD_BUFFER_DIR="$IN_BUF" DRY_RUN=true \
        bash -c 'set -euo pipefail; source "$PROJECT_ROOT/lyrebird-storage.sh"; cmd_monitor 2>&1'
}

@test "monitor detects inode exhaustion even when block usage looks healthy" {
    _write_df 40 99
    run _run_monitor
    [ "$status" -eq 0 ]
    [[ "$output" == *"EMERGENCY"* ]]
    [[ "$output" == *"inodes 99%"* ]]
}

@test "monitor escalates to CRITICAL on high inode usage" {
    _write_df 40 91
    run _run_monitor
    [ "$status" -eq 0 ]
    [[ "$output" == *"CRITICAL"* ]]
}

@test "monitor stays quiet when both blocks and inodes are healthy" {
    _write_df 40 20
    run _run_monitor
    [ "$status" -eq 0 ]
    [[ "$output" != *"EMERGENCY"* ]]
    [[ "$output" != *"CRITICAL"* ]]
    [[ "$output" != *"WARNING"* ]]
}

@test "unknown inode accounting (btrfs '-') is treated as no pressure, not an emergency" {
    cat > "$IN_TMP/bin/df" <<'EOF'
#!/bin/bash
for a in "$@"; do
    case "$a" in
        -*i*) echo "Filesystem Inodes IUsed IFree IUse% Mounted on"
              echo "/dev/root 0 0 0 - /"
              exit 0 ;;
    esac
done
echo "Filesystem 1024-blocks Used Available Capacity Mounted on"
echo "/dev/root 1000000 400000 600000 40% /"
EOF
    chmod +x "$IN_TMP/bin/df"
    run _run_monitor
    [ "$status" -eq 0 ]
    [[ "$output" != *"EMERGENCY"* ]]
    [[ "$output" != *"CRITICAL"* ]]
}
