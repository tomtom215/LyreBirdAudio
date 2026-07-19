#!/usr/bin/env bats
# Unit tests for lyrebird-updater.sh
# Run with: bats tests/test_lyrebird_updater.bats
# Install bats: sudo apt-get install bats

# Setup - source the updater script
setup() {
    # Get the directory of this test file
    TEST_DIR="$( cd "$( dirname "$BATS_TEST_FILENAME" )" && pwd )"
    PROJECT_ROOT="$( cd "$TEST_DIR/.." && pwd )"

    # Create temp directories for testing
    export LOCK_FILE="$(mktemp)"
    export BACKUP_DIR="$(mktemp -d)"
    export SERVICE_BACKUP_DIR="$(mktemp -d)"

    # Disable actual git operations
    export DRY_RUN=true
    export FORCE_MODE=false

    # Source the updater script
    source "$PROJECT_ROOT/lyrebird-updater.sh"

    # The script enables errexit, which leaks into the bats shell and turns
    # failing assertions into silent aborts. Restore bats' own error handling.
    set +euo pipefail
}

# Teardown - clean up temp files
teardown() {
    rm -f "$LOCK_FILE" 2>/dev/null || true
    rm -rf "$BACKUP_DIR" 2>/dev/null || true
    rm -rf "$SERVICE_BACKUP_DIR" 2>/dev/null || true
}

# ============================================================================
# Script Metadata Tests
# ============================================================================

@test "SCRIPT_VERSION is defined" {
    [ -n "$SCRIPT_VERSION" ]
    [[ "$SCRIPT_VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]
}

@test "SCRIPT_NAME is defined" {
    [ -n "$SCRIPT_NAME" ]
}

# ============================================================================
# Logging Function Tests
# ============================================================================

@test "log_debug function exists" {
    run type log_debug
    [ "$status" -eq 0 ]
}

@test "log_info function exists" {
    run type log_info
    [ "$status" -eq 0 ]
}

@test "log_success function exists" {
    run type log_success
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

@test "log_step function exists" {
    run type log_step
    [ "$status" -eq 0 ]
}

@test "log_step outputs step format" {
    run log_step 1 5 "Testing step"
    [ "$status" -eq 0 ]
    [[ "$output" =~ "1/5" ]] || [[ "$output" =~ "Testing" ]]
}

# ============================================================================
# Lock Function Tests
# ============================================================================

@test "acquire_lock function exists" {
    run type acquire_lock
    [ "$status" -eq 0 ]
}

@test "release_lock function exists" {
    run type release_lock
    [ "$status" -eq 0 ]
}

# ============================================================================
# Service Detection Tests
# ============================================================================

@test "detect_systemd_service function exists" {
    run type detect_systemd_service
    [ "$status" -eq 0 ]
}

@test "detect_service_customizations function exists" {
    run type detect_service_customizations
    [ "$status" -eq 0 ]
}

# ============================================================================
# Backup Function Tests
# ============================================================================

@test "backup_service_files function exists" {
    run type backup_service_files
    [ "$status" -eq 0 ]
}

@test "restore_service_from_backup function exists" {
    run type restore_service_from_backup
    [ "$status" -eq 0 ]
}

@test "cleanup_service_backups function exists" {
    run type cleanup_service_backups
    [ "$status" -eq 0 ]
}

# ============================================================================
# Service State Tests
# ============================================================================

@test "save_service_state_to_marker function exists" {
    run type save_service_state_to_marker
    [ "$status" -eq 0 ]
}

@test "load_service_state_from_marker function exists" {
    run type load_service_state_from_marker
    [ "$status" -eq 0 ]
}

@test "check_pending_service_update function exists" {
    run type check_pending_service_update
    [ "$status" -eq 0 ]
}

# ============================================================================
# Git Config Tests
# ============================================================================

@test "save_git_config function exists" {
    run type save_git_config
    [ "$status" -eq 0 ]
}

@test "restore_git_config function exists" {
    run type restore_git_config
    [ "$status" -eq 0 ]
}

# ============================================================================
# Prerequisites Tests
# ============================================================================

@test "check_prerequisites function exists" {
    run type check_prerequisites
    [ "$status" -eq 0 ]
}

@test "check_git_repository function exists" {
    run type check_git_repository
    [ "$status" -eq 0 ]
}

# ============================================================================
# Git State Tests
# ============================================================================

@test "detect_git_state function exists" {
    run type detect_git_state
    [ "$status" -eq 0 ]
}

@test "validate_clean_state function exists" {
    run type validate_clean_state
    [ "$status" -eq 0 ]
}

@test "get_default_branch function exists" {
    run type get_default_branch
    [ "$status" -eq 0 ]
}

@test "get_current_version function exists" {
    run type get_current_version
    [ "$status" -eq 0 ]
}

@test "check_local_changes function exists" {
    run type check_local_changes
    [ "$status" -eq 0 ]
}

# ============================================================================
# Confirmation Tests
# ============================================================================

@test "confirm_action function exists" {
    run type confirm_action
    [ "$status" -eq 0 ]
}

@test "confirm_destructive_action function exists" {
    run type confirm_destructive_action
    [ "$status" -eq 0 ]
}

# ============================================================================
# Transaction Tests
# ============================================================================

@test "transaction_begin function exists" {
    run type transaction_begin
    [ "$status" -eq 0 ]
}

@test "transaction_stash_changes function exists" {
    run type transaction_stash_changes
    [ "$status" -eq 0 ]
}

@test "transaction_commit function exists" {
    run type transaction_commit
    [ "$status" -eq 0 ]
}

@test "transaction_rollback function exists" {
    run type transaction_rollback
    [ "$status" -eq 0 ]
}

# ============================================================================
# Update Functions Tests
# ============================================================================

@test "fetch_updates_safe function exists" {
    run type fetch_updates_safe
    [ "$status" -eq 0 ]
}

@test "validate_version_exists function exists" {
    run type validate_version_exists
    [ "$status" -eq 0 ]
}

@test "switch_version_safe function exists" {
    run type switch_version_safe
    [ "$status" -eq 0 ]
}

# ============================================================================
# Reset and Permissions Tests
# ============================================================================

@test "reset_to_clean_state function exists" {
    run type reset_to_clean_state
    [ "$status" -eq 0 ]
}

@test "set_script_permissions function exists" {
    run type set_script_permissions
    [ "$status" -eq 0 ]
}

# ============================================================================
# Release Functions Tests
# ============================================================================

@test "list_available_releases function exists" {
    run type list_available_releases
    [ "$status" -eq 0 ]
}

@test "select_version_interactive function exists" {
    run type select_version_interactive
    [ "$status" -eq 0 ]
}

@test "switch_to_latest_stable function exists" {
    run type switch_to_latest_stable
    [ "$status" -eq 0 ]
}

@test "switch_to_development function exists" {
    run type switch_to_development
    [ "$status" -eq 0 ]
}

# ============================================================================
# Status and Help Tests
# ============================================================================

@test "show_status function exists" {
    run type show_status
    [ "$status" -eq 0 ]
}

@test "show_startup_diagnostics function exists" {
    run type show_startup_diagnostics
    [ "$status" -eq 0 ]
}

@test "show_help function exists" {
    run type show_help
    [ "$status" -eq 0 ]
}

@test "show_help outputs usage information" {
    run show_help
    [ "$status" -eq 0 ]
    [[ "$output" =~ "Usage" ]] || [[ "$output" =~ "USAGE" ]] || [[ "$output" =~ "usage" ]]
}

# ============================================================================
# Menu Functions Tests
# ============================================================================

@test "main_menu function exists" {
    run type main_menu
    [ "$status" -eq 0 ]
}

@test "reset_menu function exists" {
    run type reset_menu
    [ "$status" -eq 0 ]
}

@test "main function exists" {
    run type main
    [ "$status" -eq 0 ]
}

# ============================================================================
# Cleanup Tests
# ============================================================================

@test "cleanup function exists" {
    run type cleanup
    [ "$status" -eq 0 ]
}

# ============================================================================
# Regression tests for self-update lock handling (C7)
# ============================================================================

@test "self-update releases the lock immediately before exec [C7 regression]" {
    # exec keeps the same PID and does NOT fire the EXIT trap, so the lock must be
    # released explicitly before exec or the re-exec'd process deadlocks on its
    # own live-PID lock and every self-update fails with E_LOCKED.
    run grep -B6 -F 'exec "$script_path" "${restart_args[@]}"' "$PROJECT_ROOT/lyrebird-updater.sh"
    [ "$status" -eq 0 ]
    [[ "$output" == *"release_lock"* ]]
}

@test "release_lock removes a lock owned by the current PID [C7 regression]" {
    mkdir -p "$LOCKFILE"
    echo "$$" > "$LOCKFILE/pid"
    [ -d "$LOCKFILE" ]
    release_lock
    [ ! -d "$LOCKFILE" ]
    rm -rf "$LOCKFILE" 2>/dev/null || true
}

# ============================================================================
# Regression tests for version switching / self-update resume (UPD-H5 / UPD-5)
# ============================================================================

# Build a repo whose local 'main' is one commit BEHIND origin/main (the exact
# post-fetch state that made a plain `git checkout main` a stale no-op).
_setup_stale_repo() {
    local base; base="$(mktemp -d)"
    git init -q --bare "$base/origin.git"
    git clone -q "$base/origin.git" "$base/work" 2>/dev/null
    git -C "$base/work" config user.email t@t; git -C "$base/work" config user.name t
    echo v1 > "$base/work/f"; git -C "$base/work" add f; git -C "$base/work" commit -qm c1
    git -C "$base/work" branch -M main; git -C "$base/work" push -q origin main
    echo v2 > "$base/work/f"; git -C "$base/work" commit -qam c2; git -C "$base/work" push -q origin main
    git clone -q "$base/origin.git" "$base/local" 2>/dev/null
    git -C "$base/local" config user.email t@t; git -C "$base/local" config user.name t
    git -C "$base/local" reset -q --hard HEAD~1     # local main -> c1, origin/main stays c2
    printf '%s' "$base/local"
}

@test "fast_forward_branch_to_origin advances a stale local branch [UPD-H5 regression]" {
    local repo; repo="$(_setup_stale_repo)"
    local origin_head; origin_head=$(git -C "$repo" rev-parse origin/main)
    [ "$(git -C "$repo" rev-parse HEAD)" != "$origin_head" ]   # precondition: behind
    ( cd "$repo" && fast_forward_branch_to_origin main ); local rc=$?
    local after; after=$(git -C "$repo" rev-parse HEAD)
    rm -rf "$(dirname "$repo")"
    [ "$rc" -eq 0 ]
    [ "$after" = "$origin_head" ]                              # fast-forwarded to origin
}

@test "fast_forward_branch_to_origin is a no-op (success) for a tag target [UPD-H5 regression]" {
    local repo; repo="$(_setup_stale_repo)"
    ( cd "$repo" && git tag v9.9.9 && fast_forward_branch_to_origin v9.9.9 ); local rc=$?
    rm -rf "$(dirname "$repo")"
    [ "$rc" -eq 0 ]
}

@test "fast_forward_branch_to_origin fails (does not silently ignore) a diverged branch [UPD-H5 regression]" {
    local repo; repo="$(_setup_stale_repo)"
    ( cd "$repo" && echo l > lf && git add lf && git commit -qm local )   # diverge from origin
    ( cd "$repo" && fast_forward_branch_to_origin main ); local rc=$?
    rm -rf "$(dirname "$repo")"
    [ "$rc" -ne 0 ]
}

@test "check_prerequisites skips the root/sudo prompt when resuming a self-update [UPD-5 regression]" {
    # SUDO_USER set makes the prompt fire; with no stdin the pre-fix code would
    # EOF and return E_USER_ABORT. The resume flag must bypass the prompt.
    SUDO_USER=someone RESUMED_POST_UPDATE=true run check_prerequisites </dev/null
    [ "$status" -ne "$E_USER_ABORT" ]
}

@test "check_prerequisites still prompts (and aborts on EOF) when NOT resuming [UPD-5 regression]" {
    SUDO_USER=someone RESUMED_POST_UPDATE=false run check_prerequisites </dev/null
    [ "$status" -eq "$E_USER_ABORT" ]
}
