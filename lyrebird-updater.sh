#!/bin/bash
# lyrebird-updater.sh - Production-Ready Version Manager
# Part of LyreBirdAudio - RTSP Audio Streaming Suite
# https://github.com/tomtom215/LyreBirdAudio
#
# Version: 1.4.0 - Production Hardening Release
#
# This script provides safe, reliable version management with:
#   - Atomic operations with automatic rollback on failure
#   - Comprehensive git state validation and recovery
#   - Lock file protection against concurrent execution
#   - Transaction-based stash management
#   - Progressive error recovery with user guidance
#   - Simplified UX for non-technical users
#   - Network resilience with retries
#
# Prerequisites:
#   - Git 2.0+ and Bash 4.0+
#   - Must be run from within a cloned LyreBirdAudio git repository

# Ensure bash is being used
if [ -z "$BASH_VERSION" ]; then
    echo "Error: This script requires bash. Please run with: bash $0 $*" >&2
    exit 1
fi

# Strict error handling
set -o errexit   # Exit on any command failure
set -o pipefail  # Catch errors in pipes
set -o nounset   # Exit if uninitialized variable is used
set -o errtrace  # Inherit ERR trap in functions

################################################################################
# Constants and Configuration
################################################################################

# Script metadata
SCRIPT_NAME="$(basename "${BASH_SOURCE[0]}")"
readonly SCRIPT_NAME
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly SCRIPT_DIR
readonly VERSION="1.4.0"
LOCKFILE="${SCRIPT_DIR}/.lyrebird-updater.lock"
readonly LOCKFILE

# Repository configuration
readonly REPO_OWNER="tomtom215"
readonly REPO_NAME="LyreBirdAudio"
readonly REPO_URL="https://github.com/${REPO_OWNER}/${REPO_NAME}.git"

# Exit codes
readonly E_SUCCESS=0
readonly E_GENERAL=1
readonly E_PREREQUISITES=2
readonly E_NOT_GIT_REPO=3
readonly E_NO_REMOTE=4
readonly E_PERMISSION=5
readonly E_LOCKED=7
readonly E_BAD_STATE=8
readonly E_USER_ABORT=9

# Version requirements
readonly MIN_GIT_MAJOR=2
readonly MIN_GIT_MINOR=0
readonly MIN_BASH_MAJOR=4
readonly MIN_BASH_MINOR=0

# Operation timeouts and retries
readonly FETCH_TIMEOUT=30
readonly FETCH_RETRIES=3
readonly FETCH_RETRY_DELAY=2

# Colors for output (using tput for portability)
if command -v tput >/dev/null 2>&1 && [[ -t 1 ]]; then
    RED=$(tput setaf 1)
    readonly RED
    GREEN=$(tput setaf 2)
    readonly GREEN
    YELLOW=$(tput setaf 3)
    readonly YELLOW
    BLUE=$(tput setaf 4)
    readonly BLUE
    CYAN=$(tput setaf 6)
    readonly CYAN
    BOLD=$(tput bold)
    readonly BOLD
    NC=$(tput sgr0)
    readonly NC
else
    readonly RED=""
    readonly GREEN=""
    readonly YELLOW=""
    readonly BLUE=""
    readonly CYAN=""
    readonly BOLD=""
    readonly NC=""
fi

################################################################################
# Global State Variables
################################################################################

# Debug mode
DEBUG="${DEBUG:-false}"

# Repository state (populated and validated by functions)
DEFAULT_BRANCH=""
CURRENT_VERSION=""
CURRENT_BRANCH=""
IS_DETACHED=false
HAS_LOCAL_CHANGES=false
GIT_STATE="unknown"  # clean, dirty, merge, rebase, cherry-pick, bisect

# Transaction state for rollback capability
declare -A TRANSACTION_STATE=(
    [active]=false
    [stash_hash]=""
    [original_ref]=""
    [original_head]=""
    [operation]=""
)

# Available versions array
declare -a AVAILABLE_VERSIONS=()

################################################################################
# Logging Functions
################################################################################

log_debug() {
    if [[ "$DEBUG" == "true" ]]; then
        echo "${CYAN}[DEBUG]${NC} $*" >&2
    fi
}

log_info() {
    echo "${BLUE}[INFO]${NC} $*"
}

log_success() {
    echo "${GREEN}[✓]${NC} $*"
}

log_warn() {
    echo "${YELLOW}[!]${NC} $*" >&2
}

log_error() {
    echo "${RED}[✗]${NC} $*" >&2
}

log_step() {
    echo "${BOLD}▸${NC} $*"
}

################################################################################
# Lock File Management
################################################################################

acquire_lock() {
    local max_wait=30
    local waited=0
    
    while [[ -f "$LOCKFILE" ]]; do
        if [[ $waited -ge $max_wait ]]; then
            log_error "Another instance of this script is running"
            log_error "If you're sure no other instance is running, remove: $LOCKFILE"
            return "$E_LOCKED"
        fi
        
        log_info "Waiting for other instance to finish..."
        sleep 2
        waited=$((waited + 2))
    done
    
    # Create lock file with PID
    echo "$$" > "$LOCKFILE"
    log_debug "Lock acquired (PID: $$)"
    return 0
}

# shellcheck disable=SC2317  # Function invoked indirectly via cleanup
release_lock() {
    if [[ -f "$LOCKFILE" ]]; then
        local lock_pid
        lock_pid=$(cat "$LOCKFILE" 2>/dev/null || echo "")
        
        if [[ "$lock_pid" == "$$" ]]; then
            rm -f "$LOCKFILE"
            log_debug "Lock released"
        else
            log_debug "Lock file not owned by this process (PID: $$, lock: $lock_pid)"
        fi
    fi
}

################################################################################
# Cleanup and Error Handlers
################################################################################

# shellcheck disable=SC2317  # Function invoked indirectly via trap
cleanup() {
    local exit_code=$?
    
    log_debug "Cleanup triggered (exit code: $exit_code)"
    
    # If we're in an active transaction and exiting with error, attempt rollback
    if [[ "${TRANSACTION_STATE[active]}" == "true" ]] && [[ $exit_code -ne 0 ]]; then
        log_error "Operation failed - attempting automatic rollback..."
        transaction_rollback
    fi
    
    # Release lock file
    release_lock
    
    # Don't override the exit code
    exit "$exit_code"
}

# Trap all exit conditions
trap cleanup EXIT
trap 'log_error "Script interrupted by user"; exit $E_USER_ABORT' INT TERM

################################################################################
# Prerequisite Checks
################################################################################

check_prerequisites() {
    log_debug "Checking prerequisites..."
    
    # Check for git
    if ! command -v git >/dev/null 2>&1; then
        log_error "Git is not installed or not in PATH"
        log_info "Installation instructions:"
        log_info "  Debian/Ubuntu: sudo apt-get install git"
        log_info "  Fedora/RHEL:   sudo dnf install git"
        log_info "  macOS:         brew install git"
        return "$E_PREREQUISITES"
    fi
    
    # Check git version
    local git_version
    if ! git_version="$(git --version 2>/dev/null | awk '{print $3}')"; then
        log_error "Could not determine git version"
        return "$E_PREREQUISITES"
    fi
    
    local git_major git_minor
    git_major="${git_version%%.*}"
    git_minor="${git_version#*.}"
    git_minor="${git_minor%%.*}"
    
    if [[ "$git_major" -lt "$MIN_GIT_MAJOR" ]] || \
       [[ "$git_major" -eq "$MIN_GIT_MAJOR" && "$git_minor" -lt "$MIN_GIT_MINOR" ]]; then
        log_error "Git version $git_version is too old (required: ${MIN_GIT_MAJOR}.${MIN_GIT_MINOR}+)"
        return "$E_PREREQUISITES"
    fi
    
    log_debug "Git version: $git_version ✓"
    
    # Check bash version
    local bash_major="${BASH_VERSINFO[0]}"
    local bash_minor="${BASH_VERSINFO[1]}"
    
    if [[ "$bash_major" -lt "$MIN_BASH_MAJOR" ]] || \
       [[ "$bash_major" -eq "$MIN_BASH_MAJOR" && "$bash_minor" -lt "$MIN_BASH_MINOR" ]]; then
        log_error "Bash version $bash_major.$bash_minor is too old (required: ${MIN_BASH_MAJOR}.${MIN_BASH_MINOR}+)"
        return "$E_PREREQUISITES"
    fi
    
    log_debug "Bash version: $bash_major.$bash_minor ✓"
    
    return 0
}

################################################################################
# Git Repository Validation
################################################################################

check_git_repository() {
    log_debug "Validating git repository..."
    
    # Check if we're in a git repository
    if ! git rev-parse --git-dir >/dev/null 2>&1; then
        log_error "Not a git repository"
        log_error "This script must be run from within the LyreBirdAudio repository"
        echo
        log_info "To get started:"
        log_info "  1. Clone: git clone $REPO_URL"
        log_info "  2. Enter:  cd $REPO_NAME"
        log_info "  3. Run:    ./$SCRIPT_NAME"
        return "$E_NOT_GIT_REPO"
    fi
    
    # Verify remote is configured
    local origin_url
    if ! origin_url="$(git remote get-url origin 2>/dev/null)"; then
        log_error "No 'origin' remote configured"
        log_info "To fix: git remote add origin $REPO_URL"
        return "$E_NOT_GIT_REPO"
    fi
    
    # Validate origin URL
    if [[ ! "$origin_url" =~ github\.com[:/]${REPO_OWNER}/${REPO_NAME} ]]; then
        log_warn "Remote 'origin' URL does not match expected repository"
        log_warn "Expected: $REPO_URL"
        log_warn "Found:    $origin_url"
        echo
        if ! confirm_action "Continue anyway?"; then
            return "$E_NOT_GIT_REPO"
        fi
    fi
    
    # Check git permissions
    local git_dir
    if ! git_dir="$(git rev-parse --git-dir 2>/dev/null)"; then
        log_error "Could not determine .git directory location"
        return "$E_PERMISSION"
    fi
    
    if [[ ! -w "$git_dir" ]]; then
        log_error "No write permission for git repository: $git_dir"
        log_info "To fix: sudo chown -R $USER:$USER $(git rev-parse --show-toplevel)"
        return "$E_PERMISSION"
    fi
    
    # Check if git directory is owned by root (common issue)
    if [[ -e "$git_dir/config" ]]; then
        local owner
        owner="$(stat -c %U "$git_dir/config" 2>/dev/null || stat -f %Su "$git_dir/config" 2>/dev/null || echo "$USER")"
        
        if [[ "$owner" == "root" ]]; then
            log_error "Git repository files are owned by root"
            log_info "To fix: sudo chown -R $USER:$USER $(git rev-parse --show-toplevel)"
            return "$E_PERMISSION"
        fi
    fi
    
    log_debug "Git repository validated ✓"
    return 0
}

################################################################################
# Git State Detection and Validation
################################################################################

detect_git_state() {
    log_debug "Detecting git state..."
    
    local git_dir
    git_dir="$(git rev-parse --git-dir 2>/dev/null)"
    
    # Check for ongoing operations
    if [[ -f "$git_dir/MERGE_HEAD" ]]; then
        GIT_STATE="merge"
        log_debug "Git state: merge in progress"
        return 0
    elif [[ -d "$git_dir/rebase-merge" ]] || [[ -d "$git_dir/rebase-apply" ]]; then
        GIT_STATE="rebase"
        log_debug "Git state: rebase in progress"
        return 0
    elif [[ -f "$git_dir/CHERRY_PICK_HEAD" ]]; then
        GIT_STATE="cherry-pick"
        log_debug "Git state: cherry-pick in progress"
        return 0
    elif [[ -f "$git_dir/BISECT_LOG" ]]; then
        GIT_STATE="bisect"
        log_debug "Git state: bisect in progress"
        return 0
    fi
    
    # Check for local changes
    check_local_changes
    
    if [[ "$HAS_LOCAL_CHANGES" == "true" ]]; then
        GIT_STATE="dirty"
        log_debug "Git state: dirty (uncommitted changes)"
    else
        GIT_STATE="clean"
        log_debug "Git state: clean"
    fi
    
    return 0
}

validate_clean_state() {
    detect_git_state
    
    case "$GIT_STATE" in
        merge)
            log_error "Git merge in progress"
            log_info "You must complete or abort the merge first:"
            log_info "  To complete: git merge --continue"
            log_info "  To abort:    git merge --abort"
            return "$E_BAD_STATE"
            ;;
        rebase)
            log_error "Git rebase in progress"
            log_info "You must complete or abort the rebase first:"
            log_info "  To complete: git rebase --continue"
            log_info "  To abort:    git rebase --abort"
            return "$E_BAD_STATE"
            ;;
        cherry-pick)
            log_error "Git cherry-pick in progress"
            log_info "You must complete or abort the cherry-pick first:"
            log_info "  To complete: git cherry-pick --continue"
            log_info "  To abort:    git cherry-pick --abort"
            return "$E_BAD_STATE"
            ;;
        bisect)
            log_error "Git bisect in progress"
            log_info "You must complete the bisect first:"
            log_info "  To finish: git bisect reset"
            return "$E_BAD_STATE"
            ;;
        clean|dirty)
            # These are valid states
            return 0
            ;;
        *)
            log_warn "Unknown git state detected"
            return 0
            ;;
    esac
}

################################################################################
# Repository State Functions
################################################################################

get_default_branch() {
    log_debug "Detecting default branch..."
    
    # Try to get from remote HEAD
    local remote_default
    if remote_default="$(git ls-remote --symref origin HEAD 2>/dev/null | awk '/^ref:/ {sub(/refs\/heads\//, "", $2); print $2; exit}')"; then
        if [[ -n "$remote_default" ]]; then
            log_debug "Default branch from remote: $remote_default"
            echo "$remote_default"
            return 0
        fi
    fi
    
    # Check if main exists
    if git show-ref --verify --quiet refs/remotes/origin/main 2>/dev/null; then
        log_debug "Default branch: main"
        echo "main"
        return 0
    fi
    
    # Check if master exists
    if git show-ref --verify --quiet refs/remotes/origin/master 2>/dev/null; then
        log_debug "Default branch: master"
        echo "master"
        return 0
    fi
    
    # Fallback to main
    log_debug "Default branch: main (fallback)"
    echo "main"
    return 0
}

get_current_version() {
    log_debug "Getting current version..."
    
    # Check if HEAD exists
    if ! git rev-parse --verify --quiet HEAD >/dev/null 2>&1; then
        CURRENT_VERSION="(empty repository)"
        CURRENT_BRANCH=""
        IS_DETACHED=false
        return 0
    fi
    
    # Get short commit hash
    CURRENT_VERSION="$(git rev-parse --short HEAD 2>/dev/null)"
    
    # Check if detached HEAD
    if ! git symbolic-ref -q HEAD >/dev/null 2>&1; then
        IS_DETACHED=true
        CURRENT_BRANCH=""
        
        # Try to get tag name
        local tag_name
        if tag_name="$(git describe --tags --exact-match HEAD 2>/dev/null)"; then
            CURRENT_VERSION="$tag_name"
        fi
        
        log_debug "Detached HEAD at $CURRENT_VERSION"
    else
        IS_DETACHED=false
        CURRENT_BRANCH="$(git rev-parse --abbrev-ref HEAD 2>/dev/null)"
        log_debug "On branch $CURRENT_BRANCH at $CURRENT_VERSION"
    fi
    
    return 0
}

check_local_changes() {
    log_debug "Checking for local changes..."
    
    # Check if HEAD exists
    if ! git rev-parse --verify --quiet HEAD >/dev/null 2>&1; then
        HAS_LOCAL_CHANGES=false
        return 0
    fi
    
    # Check for any changes
    if ! git diff-index --quiet HEAD 2>/dev/null || \
       git ls-files --others --exclude-standard 2>/dev/null | grep -q .; then
        HAS_LOCAL_CHANGES=true
        log_debug "Local changes detected"
    else
        HAS_LOCAL_CHANGES=false
        log_debug "No local changes"
    fi
    
    return 0
}

################################################################################
# User Interaction Helpers
################################################################################

confirm_action() {
    local prompt="$1"
    local default="${2:-N}"
    local response
    
    if [[ "$default" == "Y" ]]; then
        read -r -p "${prompt} [Y/n] " response
        response="${response:-Y}"
    else
        read -r -p "${prompt} [y/N] " response
        response="${response:-N}"
    fi
    
    [[ "$response" =~ ^[Yy]$ ]]
}

################################################################################
# Transaction Management (for atomic operations with rollback)
################################################################################

transaction_begin() {
    local operation="$1"
    
    if [[ "${TRANSACTION_STATE[active]}" == "true" ]]; then
        log_error "Transaction already active: ${TRANSACTION_STATE[operation]}"
        return "$E_GENERAL"
    fi
    
    log_debug "Transaction begin: $operation"
    
    # Save current state
    TRANSACTION_STATE[active]=true
    TRANSACTION_STATE[operation]="$operation"
    TRANSACTION_STATE[original_head]="$(git rev-parse HEAD 2>/dev/null || echo "")"
    
    if ! git symbolic-ref -q HEAD >/dev/null 2>&1; then
        TRANSACTION_STATE[original_ref]="HEAD"  # Detached
    else
        TRANSACTION_STATE[original_ref]="$(git rev-parse --abbrev-ref HEAD 2>/dev/null)"
    fi
    
    return 0
}

transaction_stash_changes() {
    if [[ "${TRANSACTION_STATE[active]}" != "true" ]]; then
        log_error "No active transaction"
        return "$E_GENERAL"
    fi
    
    log_debug "Creating transaction stash..."
    
    local stash_message
    stash_message="lyrebird-tx-${TRANSACTION_STATE[operation]}-$$-$(date +%s)"
    
    if ! git stash push -u -m "$stash_message" >/dev/null 2>&1; then
        log_error "Failed to stash changes"
        return "$E_GENERAL"
    fi
    
    # Verify stash was created and get its hash
    local stash_hash
    if ! stash_hash="$(git rev-parse 'stash@{0}' 2>/dev/null)"; then
        log_error "Failed to get stash commit hash"
        return "$E_GENERAL"
    fi
    
    TRANSACTION_STATE[stash_hash]="$stash_hash"
    log_debug "Transaction stash created: $stash_hash"
    
    return 0
}

transaction_commit() {
    if [[ "${TRANSACTION_STATE[active]}" != "true" ]]; then
        log_error "No active transaction"
        return "$E_GENERAL"
    fi
    
    log_debug "Transaction commit: ${TRANSACTION_STATE[operation]}"
    
    # Clear transaction state
    TRANSACTION_STATE[active]=false
    TRANSACTION_STATE[stash_hash]=""
    TRANSACTION_STATE[original_ref]=""
    TRANSACTION_STATE[original_head]=""
    TRANSACTION_STATE[operation]=""
    
    return 0
}

transaction_rollback() {
    if [[ "${TRANSACTION_STATE[active]}" != "true" ]]; then
        log_debug "No active transaction to rollback"
        return 0
    fi
    
    log_warn "Rolling back: ${TRANSACTION_STATE[operation]}"
    
    # Attempt to return to original ref
    if [[ -n "${TRANSACTION_STATE[original_ref]}" ]]; then
        log_debug "Restoring original ref: ${TRANSACTION_STATE[original_ref]}"
        if ! git checkout "${TRANSACTION_STATE[original_ref]}" --force >/dev/null 2>&1; then
            log_error "Could not restore original ref"
            # Try to at least get to original HEAD
            if [[ -n "${TRANSACTION_STATE[original_head]}" ]]; then
                git checkout "${TRANSACTION_STATE[original_head]}" --force >/dev/null 2>&1 || true
            fi
        fi
    fi
    
    # Restore stashed changes if any
    if [[ -n "${TRANSACTION_STATE[stash_hash]}" ]]; then
        log_debug "Restoring stashed changes: ${TRANSACTION_STATE[stash_hash]}"
        
        # Find stash ref from hash
        local stash_ref
        stash_ref=$(git stash list --format="%gd %H" | grep "${TRANSACTION_STATE[stash_hash]}" | cut -d' ' -f1 || echo "")
        
        if [[ -n "$stash_ref" ]]; then
            if git stash pop "$stash_ref" >/dev/null 2>&1; then
                log_success "Stashed changes restored"
            else
                log_warn "Could not restore stashed changes automatically"
                log_info "Your changes are saved in: $stash_ref"
                log_info "To restore: git stash pop $stash_ref"
            fi
        else
            log_warn "Could not find stash reference"
        fi
    fi
    
    # Clear transaction state
    TRANSACTION_STATE[active]=false
    TRANSACTION_STATE[stash_hash]=""
    TRANSACTION_STATE[original_ref]=""
    TRANSACTION_STATE[original_head]=""
    TRANSACTION_STATE[operation]=""
    
    log_warn "Rollback complete"
    
    return 0
}

################################################################################
# Git Operations with Validation
################################################################################

fetch_updates_safe() {
    log_step "Checking for updates from GitHub..."
    
    local attempt=1
    local fetch_output
    local fetch_succeeded=false
    
    while [[ $attempt -le $FETCH_RETRIES ]]; do
        if [[ $attempt -gt 1 ]]; then
            log_info "Retry attempt $attempt of $FETCH_RETRIES (waiting ${FETCH_RETRY_DELAY}s...)"
            sleep "$FETCH_RETRY_DELAY"
        fi
        
        # Try fetch with timeout if available
        if command -v timeout >/dev/null 2>&1; then
            if fetch_output=$(timeout "$FETCH_TIMEOUT" git fetch --all --tags --prune 2>&1); then
                fetch_succeeded=true
                break
            fi
        else
            # No timeout command, try without it
            if fetch_output=$(git fetch --all --tags --prune 2>&1); then
                fetch_succeeded=true
                break
            fi
        fi
        
        log_debug "Fetch attempt $attempt failed"
        attempt=$((attempt + 1))
    done
    
    if [[ "$fetch_succeeded" != "true" ]]; then
        log_error "Failed to fetch updates after $FETCH_RETRIES attempts"
        log_error "Please check your internet connection"
        log_debug "Last error: $fetch_output"
        return "$E_NO_REMOTE"
    fi
    
    # Update remote HEAD reference
    git remote set-head origin --auto >/dev/null 2>&1 || true
    
    log_success "Updates fetched successfully"
    return 0
}

validate_version_exists() {
    local version="$1"
    
    if [[ -z "$version" ]]; then
        return 1
    fi
    
    log_debug "Validating version: $version"
    
    # Check various ref types
    if git rev-parse --verify --quiet "refs/tags/$version" >/dev/null 2>&1; then
        log_debug "Found as tag: $version"
        return 0
    elif git rev-parse --verify --quiet "refs/heads/$version" >/dev/null 2>&1; then
        log_debug "Found as local branch: $version"
        return 0
    elif git rev-parse --verify --quiet "refs/remotes/origin/$version" >/dev/null 2>&1; then
        log_debug "Found as remote branch: $version"
        return 0
    elif git rev-parse --verify --quiet "$version^{commit}" >/dev/null 2>&1; then
        log_debug "Found as commit: $version"
        return 0
    fi
    
    log_debug "Version not found: $version"
    return 1
}

switch_version_safe() {
    local target_version="$1"
    
    if [[ -z "$target_version" ]]; then
        log_error "No version specified"
        return "$E_GENERAL"
    fi
    
    # Validate we're in a clean state for the operation
    if ! validate_clean_state; then
        return "$E_BAD_STATE"
    fi
    
    # Validate target exists
    if ! validate_version_exists "$target_version"; then
        log_error "Version '$target_version' does not exist"
        log_info "Try running 'Check for Updates' first (option 4)"
        return "$E_GENERAL"
    fi
    
    # Get current state
    get_current_version
    
    # Check if already on this version
    if [[ "$CURRENT_VERSION" == "$target_version" ]]; then
        log_info "Already on version: $target_version"
        return 0
    fi
    
    # Begin transaction
    if ! transaction_begin "switch to $target_version"; then
        return "$E_GENERAL"
    fi
    
    # Handle local changes
    check_local_changes
    if [[ "$HAS_LOCAL_CHANGES" == "true" ]]; then
        echo
        log_warn "You have uncommitted changes"
        echo
        git status --short 2>/dev/null | head -n 15
        
        local total_changes
        total_changes=$(git status --short 2>/dev/null | wc -l)
        if [[ "$total_changes" -gt 15 ]]; then
            echo "  ... and $((total_changes - 15)) more files"
        fi
        echo
        
        log_info "Your changes must be saved before switching versions"
        echo
        if ! confirm_action "Save your changes temporarily? (recommended)"; then
            log_info "Operation cancelled"
            transaction_rollback
            return "$E_USER_ABORT"
        fi
        
        if ! transaction_stash_changes; then
            transaction_rollback
            return "$E_GENERAL"
        fi
        
        log_success "Changes saved temporarily"
    fi
    
    # Check if script itself will be modified (self-update)
    local script_will_change=false
    if ! git diff --quiet HEAD "$target_version" -- "$SCRIPT_NAME" 2>/dev/null; then
        script_will_change=true
        log_info "The updater script itself will be updated"
        log_info "The process will restart automatically after the update"
        echo
        sleep 2
    fi
    
    # Perform the checkout
    log_step "Switching to version: $target_version"
    
    local checkout_output
    if ! checkout_output=$(git checkout "$target_version" 2>&1); then
        log_error "Failed to switch to version: $target_version"
        echo "$checkout_output" >&2
        transaction_rollback
        return "$E_GENERAL"
    fi
    
    # Verify we actually switched to the target
    local new_head
    new_head="$(git rev-parse HEAD 2>/dev/null)"
    local target_head
    target_head="$(git rev-parse "$target_version" 2>/dev/null)"
    
    if [[ "$new_head" != "$target_head" ]]; then
        log_error "Checkout completed but HEAD does not match target"
        log_error "This indicates a git state inconsistency"
        transaction_rollback
        return "$E_GENERAL"
    fi
    
    log_success "Switched to version: $target_version"
    
    # Set executable permissions on known scripts
    set_script_permissions
    
    # Handle self-update scenario
    if [[ "$script_will_change" == "true" ]]; then
        log_info "Restarting with updated version..."
        
        # Make sure new script is executable
        chmod +x "./$SCRIPT_NAME" 2>/dev/null || true
        
        # Prepare restart arguments
        local restart_args=()
        if [[ -n "${TRANSACTION_STATE[stash_hash]}" ]]; then
            restart_args=("--post-update-restore" "${TRANSACTION_STATE[stash_hash]}")
        else
            restart_args=("--post-update-complete")
        fi
        
        # Mark transaction as committed before exec (we're transferring responsibility)
        transaction_commit
        
        # Replace this process with the new script
        # shellcheck disable=SC2093  # exec is intentional here for self-update
        exec "./$SCRIPT_NAME" "${restart_args[@]}"
        
        # This line only reached if exec fails
        log_error "Failed to restart with new version"
        return "$E_GENERAL"
    fi
    
    # Restore stashed changes (if not self-updating)
    if [[ -n "${TRANSACTION_STATE[stash_hash]}" ]]; then
        echo
        log_step "Restoring your saved changes..."
        
        local stash_ref
        stash_ref=$(git stash list --format="%gd %H" | grep "${TRANSACTION_STATE[stash_hash]}" | cut -d' ' -f1 || echo "")
        
        if [[ -z "$stash_ref" ]]; then
            log_warn "Could not find stashed changes"
            log_info "Your changes may have been lost (stash hash: ${TRANSACTION_STATE[stash_hash]})"
        else
            # Try to pop the stash
            if git stash pop "$stash_ref" >/dev/null 2>&1; then
                log_success "Changes restored successfully"
            else
                # Pop failed, try apply
                if git stash apply "$stash_ref" >/dev/null 2>&1; then
                    log_success "Changes restored (with manual stash cleanup needed)"
                    log_info "To remove the stash: git stash drop $stash_ref"
                else
                    log_warn "Could not restore changes automatically (conflicts detected)"
                    log_info "Your changes are saved in: $stash_ref"
                    log_info "To restore manually: git stash pop $stash_ref"
                    log_info "You may need to resolve conflicts first"
                fi
            fi
        fi
    fi
    
    # Commit transaction
    transaction_commit
    
    # Update state
    get_current_version
    check_local_changes
    
    echo
    log_success "Version switch complete!"
    
    return 0
}

reset_to_clean_state() {
    local target="$1"
    
    if [[ -z "$target" ]]; then
        log_error "No target specified for reset"
        return "$E_GENERAL"
    fi
    
    # Validate we're not in a bad state
    if ! validate_clean_state; then
        return "$E_BAD_STATE"
    fi
    
    # Validate target exists
    if ! git rev-parse --verify --quiet "$target" >/dev/null 2>&1; then
        log_error "Target '$target' does not exist"
        return "$E_GENERAL"
    fi
    
    # Final confirmation
    echo
    log_warn "This will PERMANENTLY delete all local changes and reset to: $target"
    echo
    if ! confirm_action "Are you absolutely sure?"; then
        log_info "Reset cancelled"
        return 0
    fi
    
    log_step "Resetting to clean state: $target"
    
    # Perform reset
    if ! git reset --hard "$target" >/dev/null 2>&1; then
        log_error "Failed to reset to $target"
        return "$E_GENERAL"
    fi
    
    # Clean untracked files
    if ! git clean -fd >/dev/null 2>&1; then
        log_warn "Could not remove all untracked files"
    fi
    
    log_success "Reset complete - all changes discarded"
    
    # Set script permissions
    set_script_permissions
    
    # Update state
    get_current_version
    check_local_changes
    
    return 0
}

set_script_permissions() {
    log_debug "Setting executable permissions on scripts..."
    
    local scripts=(
        "install_mediamtx.sh"
        "lyrebird-orchestrator.sh"
        "lyrebird-updater.sh"
        "mediamtx-stream-manager.sh"
        "usb-audio-mapper.sh"
    )
    
    for script in "${scripts[@]}"; do
        if [[ -f "$script" ]]; then
            chmod +x "$script" 2>/dev/null || true
        fi
    done
    
    return 0
}

################################################################################
# Version Listing and Selection
################################################################################

list_available_releases() {
    AVAILABLE_VERSIONS=()
    
    echo
    echo "${BOLD}═══ Available Versions ═══${NC}"
    echo
    
    # List stable releases (tags)
    echo "${BOLD}Stable Releases (newest first):${NC}"
    
    if git tag -l 'v*' --sort=-creatordate | head -n 20 | grep -q .; then
        local counter=1
        while IFS= read -r tag; do
            local tag_date
            tag_date=$(git log -1 --format=%ai "$tag" 2>/dev/null | cut -d' ' -f1 || echo "unknown")
            printf "  %2d) %-15s (created: %s)\n" "$counter" "$tag" "$tag_date"
            
            AVAILABLE_VERSIONS+=("$tag")
            ((counter++))
        done < <(git tag -l 'v*' --sort=-creatordate | head -n 20)
        
        local tag_count
        tag_count=$(git tag -l 'v*' | wc -l)
        if [[ "$tag_count" -gt 20 ]]; then
            echo "      ... and $((tag_count - 20)) more (not shown)"
        fi
    else
        echo "  (no stable releases found)"
    fi
    
    echo
    echo "${BOLD}Development Branches:${NC}"
    
    local branch_counter=$((${#AVAILABLE_VERSIONS[@]} + 1))
    if git branch -r | grep -v HEAD | sed 's/origin\///' | sed 's/^[[:space:]]*//' | grep -q .; then
        while IFS= read -r branch; do
            printf "  %2d) %s\n" "$branch_counter" "$branch"
            AVAILABLE_VERSIONS+=("$branch")
            ((branch_counter++))
        done < <(git branch -r | grep -v HEAD | sed 's/origin\///' | sed 's/^[[:space:]]*//')
    else
        echo "  (no development branches found)"
    fi
    
    echo
}

select_version_interactive() {
    # Fetch updates first
    if ! fetch_updates_safe; then
        log_warn "Could not fetch updates - using cached information"
        echo
    fi
    
    # Show available versions
    list_available_releases
    
    echo "You can enter:"
    echo "  - A number from the list (e.g., 1)"
    echo "  - A version name directly (e.g., v1.2.0 or main)"
    echo "  - Press Enter to cancel"
    echo
    read -r -p "Your selection: " selection
    
    if [[ -z "$selection" ]]; then
        log_info "Selection cancelled"
        return 0
    fi
    
    local target_version=""
    
    # Check if input is a number
    if [[ "$selection" =~ ^[0-9]+$ ]]; then
        local index=$((selection - 1))
        
        if [[ "$index" -ge 0 ]] && [[ "$index" -lt "${#AVAILABLE_VERSIONS[@]}" ]]; then
            target_version="${AVAILABLE_VERSIONS[$index]}"
            log_info "Selected: $target_version"
        else
            log_error "Invalid selection: $selection"
            log_info "Please choose between 1 and ${#AVAILABLE_VERSIONS[@]}"
            return "$E_GENERAL"
        fi
    else
        # Direct version name
        target_version="$selection"
    fi
    
    switch_version_safe "$target_version"
}

switch_to_latest_stable() {
    log_step "Finding latest stable release..."
    
    # Fetch first
    if ! fetch_updates_safe; then
        log_warn "Using cached version information"
    fi
    
    # Get latest tag by creation date
    local latest_tag
    if ! latest_tag="$(git tag -l 'v*' --sort=-creatordate | head -n 1)"; then
        log_error "No stable releases found"
        return "$E_GENERAL"
    fi
    
    if [[ -z "$latest_tag" ]]; then
        log_error "No version tags found in repository"
        log_info "The repository may not have any releases yet"
        return "$E_GENERAL"
    fi
    
    log_info "Latest stable release: $latest_tag"
    switch_version_safe "$latest_tag"
}

switch_to_development() {
    log_step "Switching to development version..."
    
    # Fetch first
    if ! fetch_updates_safe; then
        log_warn "Using cached version information"
    fi
    
    switch_version_safe "$DEFAULT_BRANCH"
}

################################################################################
# Status Display Functions
################################################################################

show_status() {
    get_current_version
    check_local_changes
    detect_git_state
    
    echo
    echo "${BOLD}═══ Repository Status ═══${NC}"
    echo
    
    # Current position
    if [[ "$IS_DETACHED" == "true" ]]; then
        echo "${BOLD}Current State:${NC}"
        echo "  Status:     ${YELLOW}Detached HEAD (viewing specific version)${NC}"
        echo "  Version:    ${BOLD}$CURRENT_VERSION${NC}"
        
        local tags_here
        tags_here=$(git tag --points-at HEAD 2>/dev/null | tr '\n' ' ')
        if [[ -n "$tags_here" ]]; then
            echo "  Tags:       $tags_here"
        fi
    else
        echo "${BOLD}Current Branch:${NC}"
        echo "  Branch:     ${BOLD}$CURRENT_BRANCH${NC}"
        echo "  Commit:     ${BOLD}$CURRENT_VERSION${NC}"
        
        # Check if on a tag
        local current_tag
        current_tag=$(git describe --exact-match --tags HEAD 2>/dev/null || echo "")
        if [[ -n "$current_tag" ]]; then
            echo "  Tag:        ${GREEN}$current_tag${NC}"
        fi
        
        # Show relationship to remote
        if git show-ref --verify --quiet "refs/remotes/origin/$CURRENT_BRANCH" 2>/dev/null; then
            local ahead behind
            ahead=$(git rev-list --count "origin/$CURRENT_BRANCH..HEAD" 2>/dev/null || echo "0")
            behind=$(git rev-list --count "HEAD..origin/$CURRENT_BRANCH" 2>/dev/null || echo "0")
            
            if [[ "$ahead" -gt 0 ]] && [[ "$behind" -gt 0 ]]; then
                echo "  Remote:     ${YELLOW}Diverged ($ahead ahead, $behind behind)${NC}"
            elif [[ "$ahead" -gt 0 ]]; then
                echo "  Remote:     ${YELLOW}$ahead commit(s) ahead${NC}"
            elif [[ "$behind" -gt 0 ]]; then
                echo "  Remote:     ${YELLOW}$behind commit(s) behind${NC}"
            else
                echo "  Remote:     ${GREEN}In sync${NC}"
            fi
        else
            echo "  Remote:     ${YELLOW}No remote tracking${NC}"
        fi
    fi
    
    echo
    echo "${BOLD}Working Directory:${NC}"
    
    case "$GIT_STATE" in
        clean)
            echo "  Status:     ${GREEN}Clean (no changes)${NC}"
            ;;
        dirty)
            echo "  Status:     ${YELLOW}Modified (uncommitted changes)${NC}"
            echo
            git status --short | head -n 10 | sed 's/^/    /'
            
            local change_count
            change_count=$(git status --short | wc -l)
            if [[ "$change_count" -gt 10 ]]; then
                echo "    ... and $((change_count - 10)) more"
            fi
            ;;
        merge|rebase|cherry-pick|bisect)
            echo "  Status:     ${RED}${GIT_STATE^^} IN PROGRESS${NC}"
            ;;
    esac
    
    echo
    echo "${BOLD}Repository Info:${NC}"
    
    local repo_remote
    repo_remote=$(git remote get-url origin 2>/dev/null || echo "none")
    echo "  Remote:     $repo_remote"
    
    local last_fetch="never"
    if [[ -f ".git/FETCH_HEAD" ]]; then
        if command -v stat >/dev/null 2>&1; then
            last_fetch=$(stat -c %y ".git/FETCH_HEAD" 2>/dev/null | cut -d'.' -f1 || \
                        stat -f %Sm ".git/FETCH_HEAD" 2>/dev/null || echo "unknown")
        fi
    fi
    echo "  Last fetch: $last_fetch"
    
    echo
}

show_startup_diagnostics() {
    get_current_version
    check_local_changes
    
    echo
    echo "${BOLD}═══ LyreBirdAudio Version Manager v${VERSION} ═══${NC}"
    echo
    
    # Current version
    if [[ "$IS_DETACHED" == "true" ]]; then
        echo "Current:  ${YELLOW}Viewing version ${BOLD}$CURRENT_VERSION${NC}"
    else
        echo "Current:  ${GREEN}Branch ${BOLD}$CURRENT_BRANCH${NC} @ $CURRENT_VERSION"
    fi
    
    if [[ "$HAS_LOCAL_CHANGES" == "true" ]]; then
        echo "Changes:  ${YELLOW}You have uncommitted changes${NC}"
    else
        echo "Changes:  ${GREEN}Clean working directory${NC}"
    fi
    
    echo
    log_step "Checking for updates..."
    
    # Quick fetch (with short timeout)
    local fetch_ok=false
    if command -v timeout >/dev/null 2>&1; then
        if timeout 5 git fetch --all --tags --prune --quiet 2>/dev/null; then
            fetch_ok=true
        fi
    else
        if git fetch --all --tags --prune --quiet 2>/dev/null; then
            fetch_ok=true
        fi
    fi
    
    if [[ "$fetch_ok" == "true" ]]; then
        echo -e "          ${GREEN}✓${NC} Connected to GitHub"
    else
        echo -e "          ${YELLOW}!${NC} Could not connect (using cached data)"
    fi
    
    # Check for stable releases
    local latest_tag
    latest_tag="$(git tag -l 'v*' --sort=-creatordate 2>/dev/null | head -n 1)"
    
    if [[ -n "$latest_tag" ]]; then
        local current_tag
        current_tag="$(git describe --exact-match --tags HEAD 2>/dev/null || echo "")"
        
        if [[ -n "$current_tag" ]] && [[ "$current_tag" == "$latest_tag" ]]; then
            echo "Stable:   ${GREEN}You're on latest: $latest_tag${NC}"
        else
            echo "Stable:   ${YELLOW}Update available: $latest_tag${NC}"
            echo "          ${CYAN}→ Select option 1 to update${NC}"
        fi
    fi
    
    # Check development branch
    if [[ "$IS_DETACHED" == "false" ]]; then
        local behind
        behind=$(git rev-list --count "HEAD..origin/$CURRENT_BRANCH" 2>/dev/null || echo "0")
        
        if [[ "$behind" -gt 0 ]]; then
            echo "Dev:      ${YELLOW}$behind commit(s) behind origin/$CURRENT_BRANCH${NC}"
            echo "          ${CYAN}→ Select option 2 to update${NC}"
        else
            echo "Dev:      ${GREEN}Up to date with origin/$CURRENT_BRANCH${NC}"
        fi
    fi
    
    echo
    read -r -p "Press Enter to continue..."
}

################################################################################
# Help and Menu Functions
################################################################################

show_help() {
    cat << 'EOF'

═══════════════════════════════════════════════════════════
   LyreBirdAudio Version Manager - Help Guide
═══════════════════════════════════════════════════════════

SIMPLE UPDATE WORKFLOW:
  For most users: Just select option 1
  This updates you to the latest stable, tested version

═══ MAIN OPTIONS ═══

1) Switch to Latest Stable Release
   → Most recently released version
   → Recommended for production use
   → Automatically checks for updates

2) Switch to Development Version
   → Latest code with newest features
   → May have bugs or incomplete features
   → For testing and development

3) Switch to Specific Version
   → Choose any version from a list
   → Useful for testing or rollback

4) Check for New Updates
   → Downloads version information
   → Doesn't change your current version
   → Shows what's available

5) Show Detailed Status
   → Your current version
   → Local modifications
   → Sync status with remote

6) Discard All Changes & Reset
   → PERMANENTLY deletes local changes
   → Resets to a clean version
   → Use with caution!

═══ SAFETY FEATURES ═══

✓ Automatic backup of your changes
✓ Confirmation required for destructive actions
✓ Automatic rollback if operations fail
✓ Clear warnings before permanent actions
✓ Transaction-based operations

═══ COMMON QUESTIONS ═══

Q: What happens to my changes when I update?
A: They're automatically saved and restored after the update

Q: Can I undo an update?
A: Yes, use option 3 to switch back to any previous version

Q: What if something goes wrong?
A: The script automatically rolls back failed operations

Q: How do I start fresh with no modifications?
A: Use option 6 to reset to a clean state

═══ MORE HELP ═══

Visit: https://github.com/tomtom215/LyreBirdAudio

EOF
}

main_menu() {
    while true; do
        get_current_version
        check_local_changes
        
        clear
        echo
        echo "${BOLD}╔════════════════════════════════════════════════════════╗${NC}"
        echo "${BOLD}║     LyreBirdAudio - Version Manager v${VERSION}      ║${NC}"
        echo "${BOLD}╚════════════════════════════════════════════════════════╝${NC}"
        echo
        
        # Status header
        if [[ "$IS_DETACHED" == "true" ]]; then
            echo "  Current:  ${YELLOW}$CURRENT_VERSION${NC}"
        else
            echo "  Current:  ${CYAN}$CURRENT_BRANCH${NC} @ ${BOLD}$CURRENT_VERSION${NC}"
        fi
        
        if [[ "$HAS_LOCAL_CHANGES" == "true" ]]; then
            echo "  Changes:  ${YELLOW}Uncommitted changes${NC}"
        else
            echo "  Changes:  ${GREEN}None${NC}"
        fi
        
        echo
        echo "${BOLD}═══ UPDATE ═══${NC}"
        echo "  ${BOLD}1${NC}) Switch to Latest Stable Release"
        echo "  ${BOLD}2${NC}) Switch to Development Version ($DEFAULT_BRANCH)"
        echo "  ${BOLD}3${NC}) Switch to Specific Version..."
        echo
        echo "${BOLD}═══ INFO ═══${NC}"
        echo "  ${BOLD}4${NC}) Check for New Updates"
        echo "  ${BOLD}5${NC}) Show Detailed Status"
        echo
        echo "${BOLD}═══ ADVANCED ═══${NC}"
        echo "  ${BOLD}6${NC}) Discard All Changes & Reset..."
        echo
        echo "  ${BOLD}H${NC}) Help  |  ${BOLD}Q${NC}) Quit"
        echo
        read -r -p "Select [1-6, H, Q]: " choice
        
        case "$choice" in
            1)
                switch_to_latest_stable
                read -r -p "Press Enter to continue..."
                ;;
            2)
                switch_to_development
                read -r -p "Press Enter to continue..."
                ;;
            3)
                select_version_interactive
                read -r -p "Press Enter to continue..."
                ;;
            4)
                if fetch_updates_safe; then
                    list_available_releases
                fi
                read -r -p "Press Enter to continue..."
                ;;
            5)
                show_status
                read -r -p "Press Enter to continue..."
                ;;
            6)
                reset_menu
                ;;
            h|H)
                show_help
                read -r -p "Press Enter to continue..."
                ;;
            q|Q)
                echo
                log_info "Thank you for using LyreBirdAudio Version Manager"
                return 0
                ;;
            *)
                log_error "Invalid option: $choice"
                sleep 1
                ;;
        esac
    done
}

reset_menu() {
    while true; do
        echo
        echo "${BOLD}═══ DISCARD CHANGES & RESET ═══${NC}"
        log_warn "This will PERMANENTLY delete all your local changes!"
        echo
        echo "Reset to:"
        echo "  ${BOLD}1${NC}) Latest remote version of current branch"
        echo "  ${BOLD}2${NC}) Latest development version ($DEFAULT_BRANCH)"
        echo "  ${BOLD}3${NC}) Specific version (let me choose)"
        echo "  ${BOLD}C${NC}) Cancel"
        echo
        read -r -p "Select [1-3, C]: " choice
        
        case "$choice" in
            1)
                get_current_version
                if [[ "$IS_DETACHED" == "true" ]]; then
                    log_warn "You're viewing a specific version (detached HEAD)"
                    log_info "Resetting to HEAD won't change anything"
                    log_info "Choose option 2 or 3 instead"
                    read -r -p "Press Enter to continue..."
                else
                    if git show-ref --verify --quiet "refs/remotes/origin/$CURRENT_BRANCH"; then
                        reset_to_clean_state "origin/$CURRENT_BRANCH"
                    else
                        log_error "Remote branch not found: origin/$CURRENT_BRANCH"
                    fi
                fi
                read -r -p "Press Enter to continue..."
                return 0
                ;;
            2)
                if git show-ref --verify --quiet "refs/remotes/origin/$DEFAULT_BRANCH"; then
                    reset_to_clean_state "origin/$DEFAULT_BRANCH"
                else
                    log_error "Development branch not found: origin/$DEFAULT_BRANCH"
                    log_info "Try option 4 from main menu to fetch updates"
                fi
                read -r -p "Press Enter to continue..."
                return 0
                ;;
            3)
                log_step "Fetching available versions..."
                if ! fetch_updates_safe; then
                    log_warn "Using cached information"
                fi
                
                list_available_releases
                echo
                read -r -p "Enter version to reset to: " version
                
                if [[ -z "$version" ]]; then
                    log_info "Cancelled"
                elif ! validate_version_exists "$version"; then
                    log_error "Version '$version' does not exist"
                else
                    reset_to_clean_state "$version"
                fi
                read -r -p "Press Enter to continue..."
                return 0
                ;;
            c|C)
                log_info "Cancelled"
                read -r -p "Press Enter to continue..."
                return 0
                ;;
            *)
                log_error "Invalid choice"
                sleep 1
                ;;
        esac
    done
}

################################################################################
# Main Entry Point
################################################################################

main() {
    # Change to script directory
    if ! cd "$SCRIPT_DIR" 2>/dev/null; then
        log_error "Failed to change to script directory: $SCRIPT_DIR"
        exit "$E_GENERAL"
    fi
    
    # Check prerequisites
    if ! check_prerequisites; then
        exit "$E_PREREQUISITES"
    fi
    
    # Acquire lock
    if ! acquire_lock; then
        exit "$E_LOCKED"
    fi
    
    # Validate git repository
    if ! check_git_repository; then
        exit "$E_NOT_GIT_REPO"
    fi
    
    # Configure git
    git config core.fileMode false 2>/dev/null || true
    
    # Detect default branch
    DEFAULT_BRANCH="$(get_default_branch)"
    log_debug "Default branch: $DEFAULT_BRANCH"
    
    # Handle command line arguments
    if [[ $# -gt 0 ]]; then
        case "$1" in
            --post-update-restore)
                if [[ -z "${2:-}" ]]; then
                    log_error "Missing stash hash argument"
                    exit "$E_GENERAL"
                fi
                
                echo
                log_success "Updater has been updated!"
                log_step "Restoring your saved changes..."
                
                local stash_hash="$2"
                local stash_ref
                stash_ref=$(git stash list --format="%gd %H" | grep "$stash_hash" | cut -d' ' -f1 || echo "")
                
                if [[ -n "$stash_ref" ]]; then
                    if git stash pop "$stash_ref" >/dev/null 2>&1; then
                        log_success "Changes restored successfully"
                    else
                        log_warn "Could not restore changes automatically"
                        log_info "Your changes are in: $stash_ref"
                        log_info "To restore: git stash pop $stash_ref"
                    fi
                else
                    log_warn "Could not find stashed changes"
                fi
                
                echo
                read -r -p "Press Enter to continue..."
                ;;
                
            --post-update-complete)
                echo
                log_success "Updater has been updated successfully!"
                echo
                read -r -p "Press Enter to continue..."
                ;;
                
            --version|-v)
                echo "LyreBirdAudio Version Manager v${VERSION}"
                exit "$E_SUCCESS"
                ;;
                
            --help|-h)
                show_help
                exit "$E_SUCCESS"
                ;;
                
            --status|-s)
                show_status
                exit "$E_SUCCESS"
                ;;
                
            --list|-l)
                fetch_updates_safe || true
                list_available_releases
                exit "$E_SUCCESS"
                ;;
                
            *)
                log_error "Unknown option: $1"
                echo "Try '$SCRIPT_NAME --help' for more information"
                exit "$E_GENERAL"
                ;;
        esac
    fi
    
    # Show startup diagnostics
    show_startup_diagnostics
    
    # Run interactive menu
    main_menu
    
    exit "$E_SUCCESS"
}

# Run main function
main "$@"
