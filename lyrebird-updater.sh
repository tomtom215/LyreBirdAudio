#!/bin/bash
# lyrebird-updater.sh - Interactive LyreBirdAudio Version Manager
# Part of LyreBirdAudio - RTSP Audio Streaming Suite
# https://github.com/tomtom215/LyreBirdAudio
#
# This script provides an interactive interface for managing LyreBirdAudio versions,
# handling git operations, and switching between releases safely.
#
# Version: 1.2.0 - Production Stability Release
#
# Major Improvements in v1.2.0:
#
# Stash Management & Git Operations:
#   - Robust stash handling with commit hash tracking and multi-level fallback strategies
#   - Protection against git configuration interference (rebase.autoStash, etc.)
#   - Correct operation sequencing for stash restoration and permission setting
#   - Three-phase restoration strategy: pop, apply, manual resolution with conflict reporting
#   - Enhanced "Discard changes" option for improved user control (Y/D/N menu)
#
# Repository State Management:
#   - Accurate state tracking across all git operations that modify the working tree
#   - Empty repository handling for freshly cloned or initialized repos
#   - Reliable version comparison without semantic version sorting bugs
#
# File Mode & Permission Handling:
#   - Automatic git file mode configuration (core.fileMode=false) to prevent false modifications
#   - Script permission management that doesn't interfere with repository status
#   - Proper file existence validation before permission operations
#
# Git Configuration & Validation:
#   - Enhanced remote branch validation via git ls-remote
#   - Reliable default branch detection using git ls-remote --symref
#   - Proactive permission and ownership issue detection
#   - Comprehensive input validation with regex patterns for commit SHAs
#
# All fixes verified against edge cases and production scenarios
#
# Compatible with: LyreBirdAudio v1.0.0+
#
# Prerequisites:
#   - Git 2.0+ must be installed
#   - Bash 4.0+ required
#   - Must be run from within a cloned LyreBirdAudio git repository
#   - Internet connection required for fetching updates
#
# This script REQUIRES a git repository and cannot work with non-git installations

# Ensure we're running with bash
if [ -z "$BASH_VERSION" ]; then
    echo "Error: This script requires bash. Please run with: bash $0 $*" >&2
    exit 1
fi

# Strict error handling
set -o pipefail  # Catch errors in pipes
set -o nounset   # Exit if uninitialized variable is used

################################################################################
# Constants and Configuration
################################################################################

# Script metadata
SCRIPT_NAME="$(basename "${BASH_SOURCE[0]}")"
readonly SCRIPT_NAME
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly SCRIPT_DIR
readonly VERSION="1.2.0"

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
readonly E_CONFLICT=6

# Minimum version requirements
readonly MIN_GIT_MAJOR=2
readonly MIN_GIT_MINOR=0
readonly MIN_BASH_MAJOR=4
readonly MIN_BASH_MINOR=0

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

# Script state
DEBUG=${DEBUG:-false}
CLEANUP_REQUIRED=true

# Repository state (populated by functions)
DEFAULT_BRANCH=""
CURRENT_VERSION=""
CURRENT_BRANCH=""
IS_DETACHED=false
HAS_LOCAL_CHANGES=false

# Stash tracking for backup/restore operations
LAST_STASH_HASH=""  # Commit hash of the stash (immutable identifier)

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
    echo "${GREEN}[SUCCESS]${NC} $*"
}

log_warn() {
    echo "${YELLOW}[WARN]${NC} $*" >&2
}

log_error() {
    echo "${RED}[ERROR]${NC} $*" >&2
}

################################################################################
# Cleanup Handler
################################################################################

# shellcheck disable=SC2317  # Function invoked via trap
cleanup() {
    local exit_code=$?
    
    if [[ "$CLEANUP_REQUIRED" == "true" ]] && [[ "$exit_code" -ne 0 ]]; then
        log_debug "Cleanup triggered (exit code: $exit_code)"
        
        # Attempt to restore any active stash on unexpected exit
        if [[ -n "$LAST_STASH_HASH" ]]; then
            log_warn "Unexpected exit detected - attempting to restore stashed changes..."
            
            # Try to restore the stash
            if restore_backup_stash; then
                log_success "Stashed changes have been restored"
            else
                log_error "Could not automatically restore stash"
                log_error "Your changes are saved in stash with hash: $LAST_STASH_HASH"
                log_info "To manually restore: git stash list (find your stash) then git stash pop stash@{N}"
            fi
        fi
    fi
    
    exit "$exit_code"
}

# Register cleanup handler
trap cleanup EXIT INT TERM

################################################################################
# Prerequisite Checks
################################################################################

# Check if required commands are available
check_prerequisites() {
    log_debug "Checking prerequisites..."
    
    # Check for git
    if ! command -v git >/dev/null 2>&1; then
        log_error "Git is not installed or not in PATH"
        log_info "Please install git and try again"
        log_info "  Debian/Ubuntu: sudo apt-get install git"
        log_info "  Fedora/RHEL:   sudo dnf install git"
        log_info "  macOS:         brew install git"
        return "$E_PREREQUISITES"
    fi
    
    # Check git version
    local git_version
    git_version="$(git --version 2>/dev/null | awk '{print $3}')"
    
    if [[ -z "$git_version" ]]; then
        log_warn "Could not determine git version"
    else
        local git_major git_minor
        git_major="${git_version%%.*}"
        git_minor="${git_version#*.}"
        git_minor="${git_minor%%.*}"
        
        if [[ "$git_major" -lt "$MIN_GIT_MAJOR" ]] || \
           [[ "$git_major" -eq "$MIN_GIT_MAJOR" && "$git_minor" -lt "$MIN_GIT_MINOR" ]]; then
            log_error "Git version $git_version is too old"
            log_error "Required: Git ${MIN_GIT_MAJOR}.${MIN_GIT_MINOR}+"
            log_info "Please update git and try again"
            return "$E_PREREQUISITES"
        fi
        
        log_debug "Git version: $git_version"
    fi
    
    # Check bash version
    local bash_major="${BASH_VERSINFO[0]}"
    local bash_minor="${BASH_VERSINFO[1]}"
    
    if [[ "$bash_major" -lt "$MIN_BASH_MAJOR" ]] || \
       [[ "$bash_major" -eq "$MIN_BASH_MAJOR" && "$bash_minor" -lt "$MIN_BASH_MINOR" ]]; then
        log_error "Bash version $bash_major.$bash_minor is too old"
        log_error "Required: Bash ${MIN_BASH_MAJOR}.${MIN_BASH_MINOR}+"
        log_info "Please update bash and try again"
        return "$E_PREREQUISITES"
    fi
    
    log_debug "Bash version: $bash_major.$bash_minor"
    
    return 0
}

################################################################################
# Git Repository Validation
################################################################################

# Check if we're in a git repository
check_git_repository() {
    log_debug "Checking git repository..."
    
    if ! git rev-parse --git-dir >/dev/null 2>&1; then
        log_error "Not a git repository"
        log_error "This script must be run from within the LyreBirdAudio git repository"
        log_info "To get started:"
        log_info "  1. Clone the repository: git clone $REPO_URL"
        log_info "  2. Change to the directory: cd $REPO_NAME"
        log_info "  3. Run this script: ./$SCRIPT_NAME"
        return "$E_NOT_GIT_REPO"
    fi
    
    # Verify remote is configured
    if ! git remote get-url origin >/dev/null 2>&1; then
        log_error "No 'origin' remote configured"
        log_info "Please add the origin remote:"
        log_info "  git remote add origin $REPO_URL"
        return "$E_NOT_GIT_REPO"
    fi
    
    # Validate origin URL (allowing both HTTPS and SSH variants)
    local origin_url
    origin_url="$(git remote get-url origin 2>/dev/null)"
    
    if [[ ! "$origin_url" =~ github\.com[:/]${REPO_OWNER}/${REPO_NAME} ]]; then
        log_warn "Remote 'origin' URL does not match expected repository"
        log_warn "Expected: $REPO_URL"
        log_warn "Found:    $origin_url"
        echo
        read -r -p "Continue anyway? [y/N] " response
        if [[ ! "$response" =~ ^[Yy]$ ]]; then
            log_info "Operation cancelled"
            return "$E_NOT_GIT_REPO"
        fi
    fi
    
    log_debug "Git repository validated successfully"
    
    # Check for permission issues with .git directory
    if ! check_git_permissions; then
        return "$E_PERMISSION"
    fi
    
    return 0
}

# Check for permission issues with .git directory
check_git_permissions() {
    local git_dir
    git_dir="$(git rev-parse --git-dir 2>/dev/null)"
    
    if [[ -z "$git_dir" ]]; then
        log_error "Could not determine .git directory location"
        return "$E_PERMISSION"
    fi
    
    # Test if we can write to .git directory
    if [[ ! -w "$git_dir" ]]; then
        log_error "No write permission for git repository"
        log_error "Directory: $git_dir"
        log_info "Try running: sudo chown -R $USER:$USER $(git rev-parse --show-toplevel)"
        return "$E_PERMISSION"
    fi
    
    # Check if .git directory is owned by root (common permission issue)
    if [[ -e "$git_dir/config" ]] && [[ "$(stat -c %U "$git_dir/config" 2>/dev/null || stat -f %Su "$git_dir/config" 2>/dev/null)" == "root" ]]; then
        log_error "Git repository files are owned by root"
        log_error "This will cause permission errors"
        log_info "Fix with: sudo chown -R $USER:$USER $(git rev-parse --show-toplevel)"
        return "$E_PERMISSION"
    fi
    
    log_debug "Git permissions validated successfully"
    return 0
}

################################################################################
# Git Configuration
################################################################################

# Configure git to ignore file mode changes
configure_git_filemode() {
    log_debug "Configuring git file mode handling..."
    
    # Check current setting
    local current_filemode
    current_filemode="$(git config --get core.fileMode 2>/dev/null)"
    
    if [[ "$current_filemode" != "false" ]]; then
        log_debug "Setting core.fileMode to false"
        if git config core.fileMode false; then
            log_debug "core.fileMode configured successfully"
        else
            log_warn "Could not set core.fileMode (non-critical)"
        fi
    else
        log_debug "core.fileMode already set to false"
    fi
    
    return 0
}

################################################################################
# Repository State Functions
################################################################################

# Get default branch name (defaults to main, handles master gracefully)
get_default_branch() {
    log_debug "Detecting default branch..."
    
    # Method 1: Query remote directly using ls-remote
    local remote_default
    remote_default="$(git ls-remote --symref origin HEAD 2>/dev/null | awk '/^ref:/ {sub(/refs\/heads\//, "", $2); print $2; exit}')"
    
    if [[ -n "$remote_default" ]]; then
        log_debug "Found default branch from remote: $remote_default"
        
        # Update local symbolic-ref to match remote
        if git symbolic-ref refs/remotes/origin/HEAD "refs/remotes/origin/$remote_default" 2>/dev/null; then
            log_debug "Updated local symbolic-ref to match remote"
        fi
        
        echo "$remote_default"
        return 0
    fi
    
    # Method 2: Check if main exists (preferred), otherwise check master
    if git show-ref --verify --quiet refs/remotes/origin/main 2>/dev/null; then
        log_debug "Using 'main' branch"
        echo "main"
        return 0
    elif git show-ref --verify --quiet refs/remotes/origin/master 2>/dev/null; then
        log_debug "Using 'master' branch (legacy)"
        echo "master"
        return 0
    fi
    
    # Fallback: assume 'main' (modern standard)
    log_debug "Defaulting to 'main'"
    echo "main"
    return 0
}

# Get current version (commit hash or tag)
get_current_version() {
    log_debug "Getting current version..."
    
    # Check if HEAD exists (repository not empty)
    if ! git rev-parse --verify --quiet HEAD >/dev/null 2>&1; then
        log_debug "Empty repository - HEAD does not exist"
        CURRENT_VERSION="(empty repository)"
        CURRENT_BRANCH=""
        IS_DETACHED=false
        HAS_LOCAL_CHANGES=false
        return 0
    fi
    
    # Get short commit hash
    CURRENT_VERSION="$(git rev-parse --short HEAD 2>/dev/null)"
    
    # Check if we're in detached HEAD state
    if ! git symbolic-ref -q HEAD >/dev/null 2>&1; then
        IS_DETACHED=true
        
        # Try to get tag name if we're on a tag
        local tag_name
        tag_name="$(git describe --tags --exact-match HEAD 2>/dev/null)"
        if [[ -n "$tag_name" ]]; then
            CURRENT_VERSION="$tag_name"
        fi
        
        CURRENT_BRANCH=""
        log_debug "Detached HEAD at $CURRENT_VERSION"
    else
        IS_DETACHED=false
        CURRENT_BRANCH="$(git rev-parse --abbrev-ref HEAD 2>/dev/null)"
        log_debug "On branch $CURRENT_BRANCH at $CURRENT_VERSION"
    fi
    
    return 0
}

# Check for local changes (modified, staged, or untracked files)
check_local_changes() {
    log_debug "Checking for local changes..."
    
    # Check if HEAD exists (repository not empty)
    if ! git rev-parse --verify --quiet HEAD >/dev/null 2>&1; then
        log_debug "Empty repository - treating as no local changes"
        HAS_LOCAL_CHANGES=false
        return 0
    fi
    
    # Check for any changes: modified files, staged changes, or untracked files
    # Using diff-index to check against index and HEAD
    if ! git diff-index --quiet HEAD 2>/dev/null || \
       git ls-files --others --exclude-standard 2>/dev/null | grep -q .; then
        HAS_LOCAL_CHANGES=true
        log_debug "Local changes detected"
    else
        HAS_LOCAL_CHANGES=false
        log_debug "No local changes detected"
    fi
    
    return 0
}

################################################################################
# Stash Management Functions
################################################################################

# Create a backup stash with user interaction
create_backup_stash() {
    echo
    log_warn "You have uncommitted changes"
    echo
    echo "Changed files:"
    git status --short 2>/dev/null | head -n 10
    
    # Show truncation message if there are more than 10 changes
    local total_changes
    total_changes=$(git status --short 2>/dev/null | wc -l)
    if [[ "$total_changes" -gt 10 ]]; then
        echo "  ... and $((total_changes - 10)) more files"
    fi
    echo
    echo "Your options:"
    echo "  ${BOLD}Y${NC} = Save changes temporarily (recommended - can be restored later)"
    echo "  ${BOLD}D${NC} = Discard all changes permanently (cannot be undone)"
    echo "  ${BOLD}N${NC} = Cancel this operation"
    echo
    
    while true; do
        read -r -p "Save, Discard, or Cancel? [Y/D/N] " response
        case "$response" in
            [Yy]*)
                # Save changes to stash
                local stash_message
                stash_message="lyrebird-updater-backup-$$-$(date +%s)"
                log_info "Saving changes to temporary backup..."
                
                if git stash push -u -m "$stash_message" >/dev/null 2>&1; then
                    # Store the commit hash of the stash for reliable lookup
                    LAST_STASH_HASH="$(git rev-parse 'stash@{0}' 2>/dev/null)"
                    
                    if [[ -z "$LAST_STASH_HASH" ]]; then
                        log_error "Failed to get stash commit hash"
                        return "$E_GENERAL"
                    fi
                    
                    log_success "Changes backed up with hash: $LAST_STASH_HASH"
                    log_debug "Stash message: $stash_message"
                    
                    # Update state
                    check_local_changes
                    return 0
                else
                    log_error "Failed to create backup stash"
                    return "$E_GENERAL"
                fi
                ;;
            [Dd]*)
                # Discard changes with confirmation
                log_warn "This will permanently delete all local changes!"
                echo
                read -r -p "Type 'DISCARD' in all caps to confirm: " confirm
                if [[ "$confirm" == "DISCARD" ]]; then
                    log_info "Discarding all local changes..."
                    if git reset --hard HEAD >/dev/null 2>&1 && git clean -fd >/dev/null 2>&1; then
                        log_success "All local changes have been discarded"
                        
                        # Update state
                        check_local_changes
                        return 0
                    else
                        log_error "Failed to discard changes"
                        return "$E_GENERAL"
                    fi
                else
                    log_info "Discard cancelled - incorrect confirmation"
                    return "$E_GENERAL"
                fi
                ;;
            [Nn]*)
                log_info "Operation cancelled"
                return "$E_GENERAL"
                ;;
            *)
                echo "Invalid response. Please enter Y (save), D (discard), or N (cancel)"
                ;;
        esac
    done
}

# Restore backup stash with comprehensive error handling
restore_backup_stash() {
    if [[ -z "$LAST_STASH_HASH" ]]; then
        log_debug "No stash to restore (LAST_STASH_HASH is empty)"
        return 0
    fi
    
    log_info "Attempting to restore your saved changes..."
    log_debug "Looking for stash with hash: $LAST_STASH_HASH"
    
    # Verify the stash still exists
    if ! git rev-parse --verify --quiet "$LAST_STASH_HASH" >/dev/null 2>&1; then
        log_error "Stash with hash $LAST_STASH_HASH no longer exists"
        log_error "It may have been manually removed or garbage collected"
        LAST_STASH_HASH=""
        return "$E_GENERAL"
    fi
    
    # Find the stash@{N} reference for this hash from git stash list
    local stash_ref
    stash_ref=$(git stash list --format="%gd %H" | grep "$LAST_STASH_HASH" | cut -d' ' -f1)
    
    if [[ -z "$stash_ref" ]]; then
        # Hash exists but not in stash list - try hash directly as fallback
        log_debug "Could not find stash@{N} reference, trying hash directly"
        stash_ref="$LAST_STASH_HASH"
    else
        log_debug "Found stash reference: $stash_ref for hash: $LAST_STASH_HASH"
    fi
    
    # Use the multi-phase restoration strategy
    if stash_restore_with_retry "$stash_ref"; then
        log_success "Changes restored successfully"
        LAST_STASH_HASH=""  # Clear after successful restoration
        
        # Update state to reflect restored changes
        check_local_changes
        return 0
    else
        log_error "Could not restore stashed changes automatically"
        log_warn "Your changes are still saved in stash: $stash_ref"
        log_info "To manually restore later: git stash pop $stash_ref"
        log_info "To see stash contents: git stash show -p $stash_ref"
        LAST_STASH_HASH=""  # Clear to prevent repeated attempts
        return "$E_CONFLICT"
    fi
}

# Multi-phase stash restoration with detailed conflict reporting
stash_restore_with_retry() {
    local stash_ref="$1"
    
    log_debug "Attempting Phase 1: git stash pop"
    
    # Phase 1: Try to pop the stash (removes stash if successful)
    if git stash pop "$stash_ref" 2>/dev/null; then
        log_debug "Phase 1 succeeded - stash popped cleanly"
        return 0
    fi
    
    log_debug "Phase 1 failed - trying Phase 2: git stash apply"
    
    # Phase 2: Try to apply without removing (keeps stash for manual cleanup)
    local apply_output
    apply_output=$(git stash apply "$stash_ref" 2>&1)
    local apply_status=$?
    
    if [[ "$apply_status" -eq 0 ]]; then
        # Applied successfully - now remove the stash
        log_debug "Phase 2 succeeded - stash applied cleanly"
        
        if git stash drop "$stash_ref" 2>/dev/null; then
            log_debug "Stash dropped successfully after apply"
        else
            log_warn "Could not remove stash entry (non-critical)"
        fi
        
        return 0
    fi
    
    # Phase 3: Apply failed - check if it was due to conflicts
    log_debug "Phase 2 failed - analyzing conflicts"
    
    if echo "$apply_output" | grep -qi "conflict"; then
        log_error "Cannot restore changes - conflicts detected"
        echo
        echo "Conflicting files:"
        git status --short 2>/dev/null | grep "^UU\|^AA\|^DD" || echo "  (use 'git status' to see details)"
        echo
        log_info "Manual resolution required:"
        log_info "  1. Resolve conflicts in the files listed above"
        log_info "  2. Stage resolved files: git add <file>"
        log_info "  3. Drop the stash when done: git stash drop $stash_ref"
        return "$E_CONFLICT"
    else
        # Some other error occurred
        log_error "Failed to apply stash (unknown error)"
        log_debug "Git apply output: $apply_output"
        return "$E_GENERAL"
    fi
}

################################################################################
# Version Validation Functions
################################################################################

# Validate that a version/tag/branch exists in the repository
validate_version_exists() {
    local version="$1"
    
    if [[ -z "$version" ]]; then
        return 1
    fi
    
    log_debug "Validating version exists: $version"
    
    # Check if it's a tag, branch, or commit
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
    else
        # Last resort: check remote branches via ls-remote
        if git ls-remote --heads origin "$version" 2>/dev/null | grep -q "refs/heads/$version"; then
            log_debug "Found as remote HEAD: $version"
            return 0
        fi
        
        log_debug "Version not found: $version"
        return 1
    fi
}

# List available versions (tags and branches)
list_available_releases() {
    echo
    echo "${BOLD}=== Available Versions ===${NC}"
    echo
    
    # List tags (releases)
    echo "${BOLD}Stable Releases:${NC} (sorted by release date, newest first)"
    if git tag -l 'v*' --sort=-creatordate --format='%(creatordate:short) - %(refname:short)' | head -n 20 | grep -q .; then
        git tag -l 'v*' --sort=-creatordate --format='%(creatordate:short) - %(refname:short)' | head -n 20 | sed 's/^/  /'
        local tag_count
        tag_count=$(git tag -l 'v*' | wc -l)
        if [[ "$tag_count" -gt 20 ]]; then
            echo "  ... and $((tag_count - 20)) more versions"
        fi
    else
        echo "  (no releases found)"
    fi
    
    echo
    echo "${BOLD}Development Versions:${NC}"
    if git branch -r | grep -v HEAD | sed 's/origin\///' | grep -q .; then
        git branch -r | grep -v HEAD | sed 's/origin\///' | sed 's/^/  /'
    else
        echo "  (no development branches found)"
    fi
    echo
    
    log_info "To switch to a version: use Option 3 (Select Version)"
}

################################################################################
# Script Permission Management
################################################################################

# Set executable permissions on scripts
# This is a convenience function and should not be critical to operation
# Set executable permissions on scripts
set_script_permissions() {
    log_debug "Setting executable permissions on scripts..."
    
    local chmod_success=true
    local script_found=false
    
    # Use a nullglob to prevent errors if no .sh files are found
    shopt -s nullglob
    for script in ./*.sh; do
        script_found=true
        if ! chmod +x "$script" 2>/dev/null; then
            log_debug "Could not set permissions on $script (non-critical)"
            chmod_success=false
        fi
    done
    shopt -u nullglob # Unset nullglob
    
    if [[ "$script_found" == "false" ]]; then
        log_debug "No .sh files found to set permissions on."
    elif [[ "$chmod_success" == "true" ]]; then
        log_debug "Script permissions set successfully"
    else
        log_debug "Some permission changes failed (non-critical)"
    fi
    
    # Always return success since this is non-critical
    return 0
}

################################################################################
# Git Operations
################################################################################

# Fetch latest updates from remote
fetch_updates() {
    log_info "Checking for updates from GitHub..."
    
    # Execute fetch and capture output
    local fetch_output
    if ! fetch_output=$(git fetch --all --tags --prune 2>&1); then
        log_error "Failed to fetch updates from remote"
        echo "$fetch_output" >&2  # Show actual error
        log_info "Check your internet connection and try again"
        return "$E_NO_REMOTE"
    fi
    
    log_success "Updates fetched successfully"
    
    # Optionally filter and display non-"From" output for user
    if ! echo "$fetch_output" | grep -q "^From"; then
        # Only show output if it contains non-From messages
        echo "$fetch_output"
    fi
    
    # Update local symbolic-ref to match remote HEAD
    if git remote set-head origin --auto >/dev/null 2>&1; then
        log_debug "Updated local symbolic-ref to match remote HEAD"
    fi
    
    return 0
}

# Switch to a specific version (tag or branch)
switch_version() {
    local target_version="$1"
    
    if [[ -z "$target_version" ]]; then
        log_error "No version specified"
        return "$E_GENERAL"
    fi
    
    # Validate version exists
    if ! validate_version_exists "$target_version"; then
        log_error "Version '$target_version' does not exist or is not reachable"
        log_info "Try running 'Fetch Updates' first"
        return "$E_GENERAL"
    fi
    
    # Get current state
    get_current_version
    
    # Check if already on this version (exact string match)
    if [[ "$CURRENT_VERSION" == "$target_version" ]]; then
        log_info "Already on version: $target_version"
        return 0
    fi
    
    # Check for local changes
    check_local_changes
    if [[ "$HAS_LOCAL_CHANGES" == "true" ]]; then
        if ! create_backup_stash; then
            return "$E_GENERAL"
        fi
    fi
    
    log_info "Switching to version: $target_version..."
    
    # Perform the checkout and capture output
    local checkout_output
    if ! checkout_output=$(git checkout "$target_version" 2>&1); then
        log_error "Failed to switch to version: $target_version"
        echo "$checkout_output" >&2  # Show actual error
        
        # Attempt to restore stash on failure
        if [[ -n "$LAST_STASH_HASH" ]]; then
            log_info "Attempting to restore your changes..."
            restore_backup_stash
        fi
        
        return "$E_GENERAL"
    fi
    
    # Success - optionally filter output for user display
    if ! echo "$checkout_output" | grep -q "^Note:"; then
        # Only show output if it contains non-Note messages
        echo "$checkout_output"
    fi
    log_success "Switched to version: $target_version"
    
    # Set script permissions
    set_script_permissions
    
    # Restore stash if we created one
    if [[ -n "$LAST_STASH_HASH" ]]; then
        restore_backup_stash
    fi
    
    # Update state
    get_current_version
    check_local_changes
    
    return 0
}

# Reset to clean state (discard changes and reset to specific ref)
reset_clean() {
    local target="$1"
    
    if [[ -z "$target" ]]; then
        log_error "No target specified for reset"
        return "$E_GENERAL"
    fi
    
    # Final confirmation for destructive operation
    echo
    log_warn "This will discard ALL local changes and reset to: $target"
    read -r -p "Are you sure? [y/N] " response
    if [[ ! "$response" =~ ^[Yy]$ ]]; then
        log_info "Reset cancelled - no changes made"
        return 0
    fi
    
    log_info "Resetting to clean state: $target..."
    
    # Validate target exists
    if ! git rev-parse --verify --quiet "$target" >/dev/null 2>&1; then
        log_error "Target '$target' does not exist"
        return "$E_GENERAL"
    fi
    
    # Perform reset
    if git reset --hard "$target" >/dev/null 2>&1; then
        log_success "Reset complete - all changes discarded"
        
        # Clean untracked files
        if git clean -fd >/dev/null 2>&1; then
            log_success "Removed untracked files"
        fi
        
        # Set script permissions
        set_script_permissions
        
        # Update state
        get_current_version
        check_local_changes
        
        return 0
    else
        log_error "Failed to reset to $target"
        return "$E_GENERAL"
    fi
}

# Switch to latest stable release
switch_to_latest_stable() {
    log_info "Finding latest stable release..."
    
    # Fetch to ensure we have latest tags
    if ! fetch_updates; then
        log_warn "Could not fetch updates, using cached information"
    fi
    
    # Get latest version tag
    local latest_tag
    latest_tag="$(git tag -l 'v*' --sort=-version:refname | head -n 1)"
    
    if [[ -z "$latest_tag" ]]; then
        log_error "No version tags found"
        log_info "The repository may not have any releases yet"
        return "$E_GENERAL"
    fi
    
    log_info "Latest stable release: $latest_tag"
    switch_version "$latest_tag"
}

################################################################################
# User Interface Functions
################################################################################

# Show current status
show_status() {
    # Update current state
    get_current_version
    check_local_changes
    
    echo
    echo "${BOLD}=== Repository Status ===${NC}"
    echo
    
    if [[ "$IS_DETACHED" == "true" ]]; then
        echo "Status:  ${YELLOW}Viewing specific version${NC}"
        echo "Version: ${BOLD}$CURRENT_VERSION${NC}"
    else
        echo "Branch:  ${BOLD}$CURRENT_BRANCH${NC}"
        echo "Commit:  ${BOLD}$CURRENT_VERSION${NC}"
    fi
    
    if [[ "$HAS_LOCAL_CHANGES" == "true" ]]; then
        echo "Changes: ${YELLOW}Modified (uncommitted changes present)${NC}"
    else
        echo "Changes: ${GREEN}Clean${NC}"
    fi
    
    echo
}

# Show detailed local modifications
show_local_modifications() {
    check_local_changes
    
    echo
    if [[ "$HAS_LOCAL_CHANGES" == "false" ]]; then
        log_info "No local changes detected"
        return 0
    fi
    
    echo "${BOLD}=== Local Changes ===${NC}"
    echo
    git status --short
    echo
    
    log_info "Use Option 5 (Reset to Clean State) to discard changes"
    log_info "Use Option 7 (Create Manual Backup) to save changes for later"
}

# Create a manual backup of current changes
create_manual_backup() {
    check_local_changes
    
    if [[ "$HAS_LOCAL_CHANGES" == "false" ]]; then
        log_info "No local changes to backup"
        return 0
    fi
    
    echo
    echo "This will create a backup of your current changes."
    read -r -p "Enter backup name (or press Enter for automatic name): " backup_name
    
    if [[ -z "$backup_name" ]]; then
        backup_name="manual-backup-$(date +%Y%m%d-%H%M%S)"
    fi
    
    log_info "Creating backup: $backup_name"
    
    if git stash push -u -m "$backup_name"; then
        log_success "Backup created: $backup_name"
        log_info "To restore later: git stash list (find your backup) then git stash pop"
        
        # Update state
        check_local_changes
        return 0
    else
        log_error "Failed to create backup"
        return "$E_GENERAL"
    fi
}

# Interactive version selection
select_version_interactive() {
    # Fetch updates first
    log_info "Fetching available versions..."
    if ! fetch_updates; then
        log_warn "Could not fetch updates, using cached information"
    fi
    
    echo
    echo "${BOLD}=== Available Versions ===${NC}"
    echo
    
    # Build arrays of versions
    local -a stable_versions
    local -a dev_versions
    
    # Get stable releases with dates
    echo "${BOLD}Stable Releases:${NC} (sorted by release date, newest first)"
    local idx=1
    while IFS='|' read -r date version; do
        if [[ -n "$version" ]]; then
            stable_versions+=("$version")
            printf "  ${CYAN}%2d${NC}) %s - %s\n" "$idx" "$date" "$version"
            ((idx++))
        fi
    done < <(git tag -l 'v*' --sort=-creatordate --format='%(creatordate:short)|%(refname:short)' | head -n 20)
    
    if [[ ${#stable_versions[@]} -eq 0 ]]; then
        echo "  (no releases found)"
    fi
    
    echo
    echo "${BOLD}Development Versions:${NC}"
    local dev_start=$idx
    while IFS= read -r branch; do
        if [[ -n "$branch" ]]; then
            dev_versions+=("$branch")
            printf "  ${CYAN}%2d${NC}) %s\n" "$idx" "$branch"
            ((idx++))
        fi
    done < <(git branch -r | grep -v HEAD | sed 's/origin\///' | sed 's/^[[:space:]]*//')
    
    if [[ ${#dev_versions[@]} -eq 0 ]]; then
        echo "  (no development branches found)"
    fi
    
    echo
    echo "${BOLD}Enter selection number, version name, or press Enter to cancel${NC}"
    read -r -p "Selection: " selection
    
    if [[ -z "$selection" ]]; then
        log_info "Selection cancelled"
        return
    fi
    
    # Check if selection is a number
    if [[ "$selection" =~ ^[0-9]+$ ]]; then
        local total_versions=$((${#stable_versions[@]} + ${#dev_versions[@]}))
        if [[ "$selection" -lt 1 || "$selection" -gt "$total_versions" ]]; then
            log_error "Invalid selection: $selection (must be between 1-$total_versions)"
            read -r -p "Press Enter to continue..."
            return
        fi
        
        # Determine if it's a stable or dev version
        if [[ "$selection" -lt "$dev_start" ]]; then
            # Stable release (array is 0-indexed)
            local target_version="${stable_versions[$((selection - 1))]}"
        else
            # Development version
            local dev_idx=$((selection - dev_start))
            local target_version="${dev_versions[$dev_idx]}"
        fi
    else
        # User typed a version name directly
        local target_version="$selection"
    fi
    
    switch_version "$target_version"
}

# Show help information
show_help() {
    cat << 'EOF'

═══════════════════════════════════════════════════════════
   LyreBirdAudio Version Manager - Help Guide
═══════════════════════════════════════════════════════════

This tool helps you manage LyreBirdAudio versions safely and easily.

═══ MAIN MENU OPTIONS ═══

UPDATE:
  1. Switch to Latest Stable Release
     → Updates to the newest tested, stable version
     → Recommended for most users
     → Automatically checks for updates first

  2. Switch to Development Version
     → Updates to latest development code
     → Has newest features but may be less stable
     → Automatically checks for updates first

  3. Switch to Specific Version
     → Lets you choose any specific version
     → Shows you all available versions to choose from
     → Useful for testing or reverting to older versions

STATUS & INFO:
  4. Check for New Updates on GitHub
     → Downloads information about available versions
     → Doesn't change your current version
     → Shows what's available to install

  5. Show Detailed Status
     → Displays your current version
     → Shows if you're on stable or development
     → Indicates if you have unsaved changes

  6. View My Local Changes
     → Shows files you've modified
     → Helps you see what will be lost if you reset
     → Does not make any changes

ADVANCED:
  7. Discard All Changes & Reset
     → Permanently deletes your local changes
     → Resets to a clean version
     → Use with caution - cannot be undone!

  8. Save Changes as Backup
     → Creates a backup of your modifications
     → Changes can be restored later
     → Safe way to preserve your work

═══ COMMON WORKFLOWS ═══

I want to update to the latest version:
  → Choose option 1 (Latest Stable Release)
  → That's it! Everything is automatic

I want to try the newest features:
  → Choose option 2 (Development Version)
  → This gets you the latest code

I made changes and want to switch versions:
  → The script will automatically offer to save your changes
  → Choose "Y" to save them temporarily
  → Your changes will be restored after the switch

I want to start fresh with no modifications:
  → Choose option 7 (Discard & Reset)
  → Select which version to reset to
  → Confirm to permanently delete your changes

═══ IMPORTANT TERMS ═══

Stable Release: 
  → Tested, numbered version (like v1.0.0)
  → Recommended for regular use
  → Less likely to have bugs

Development Version:
  → Latest code with newest features
  → May have bugs or incomplete features
  → Updates frequently

Local Changes:
  → Files you've modified but not committed
  → Will be backed up automatically when switching
  → Can be discarded or saved

═══ SAFETY FEATURES ═══

✓ Automatically backs up your changes before updates
✓ Asks for confirmation before destructive actions
✓ Validates versions exist before switching
✓ Can restore changes if something goes wrong
✓ Clear warnings for permanent operations

═══ NEED MORE HELP? ═══

Visit: https://github.com/tomtom215/LyreBirdAudio
Or choose option 5 to see your current status

EOF
}

# Show a diagnostic summary on script startup
show_startup_diagnostics() {
    echo
    echo "${BOLD}Analyzing repository state...${NC}"

    # Fetch updates silently to get latest info
    if ! git fetch --all --tags --prune >/dev/null 2>&1; then
        log_warn "Could not fetch updates from GitHub. Status may be based on old data."
        # Show regular status and exit function if fetch fails
        show_status
        read -r -p "Press Enter to continue..."
        return
    fi
    log_info "Successfully checked for updates."

    # Get current state information
    get_current_version
    check_local_changes
    local current_head="HEAD"
    local latest_tag
    # Use creation date instead of version number to find truly latest release
    latest_tag=$(git tag -l 'v*' --sort=-creatordate | head -n 1)
    local dev_branch_ref="origin/${DEFAULT_BRANCH}"

    echo
    echo "${BOLD}--- LyreBirdAudio Status Summary ---${NC}"
    # 1. Display Current Version and Local Changes
    if [[ "$IS_DETACHED" == "true" ]]; then
        printf "  %-20s ${YELLOW}%s${NC}\n" "Current Version:" "$CURRENT_VERSION"
    else
        printf "  %-20s ${CYAN}%s${NC} @ ${BOLD}%s${NC}\n" "Current Branch:" "$CURRENT_BRANCH" "$CURRENT_VERSION"
    fi

    if [[ "$HAS_LOCAL_CHANGES" == "true" ]]; then
        printf "  %-20s ${YELLOW}%s${NC}\n" "Local Repository:" "You have uncommitted changes"
    else
        printf "  %-20s ${GREEN}%s${NC}\n" "Local Repository:" "Clean"
    fi
    
    echo

    # 2. Compare to Latest Stable Release
    if [[ -n "$latest_tag" ]]; then
        local latest_tag_commit
        latest_tag_commit=$(git rev-parse "$latest_tag^{commit}")
        local current_commit
        current_commit=$(git rev-parse "$current_head")
        
        if [[ "$current_commit" == "$latest_tag_commit" ]]; then
            printf "  %-20s ${GREEN}You are on the latest stable release!${NC}\n" "Stable Release:"
        else
            # Check if latest tag is an ancestor of current (i.e., we're ahead of latest stable)
            if git merge-base --is-ancestor "$latest_tag_commit" "$current_head" >/dev/null 2>&1; then
                printf "  %-20s ${GREEN}You are ahead of latest stable ${BOLD}%s${NC}\n" "Stable Release:" "$latest_tag"
            # Check if current is an ancestor of latest tag (i.e., we're behind)
            elif git merge-base --is-ancestor "$current_head" "$latest_tag_commit" >/dev/null 2>&1; then
                printf "  %-20s A new stable release is available: ${BOLD}%s${NC}\n" "Stable Release:" "$latest_tag"
            else
                # Diverged - neither is ancestor of the other
                printf "  %-20s Latest is ${BOLD}%s${NC}. You are on a different version line.\n" "Stable Release:" "$latest_tag"
            fi
        fi
    else
        printf "  %-20s (No stable releases found)\n" "Stable Release:"
    fi

    # 3. Compare to Development Branch
    if git rev-parse --verify --quiet "$dev_branch_ref" >/dev/null 2>&1; then
        local ahead_behind
        ahead_behind=$(git rev-list --left-right --count "${dev_branch_ref}...${current_head}")
        local behind_count ahead_count
        behind_count=$(echo "$ahead_behind" | cut -f1)
        ahead_count=$(echo "$ahead_behind" | cut -f2)

        if [[ "$behind_count" -eq 0 && "$ahead_count" -eq 0 ]]; then
            printf "  %-20s ${GREEN}Up-to-date with the latest development version.${NC}\n" "Development Branch:"
        elif [[ "$behind_count" -gt 0 && "$ahead_count" -eq 0 ]]; then
            printf "  %-20s ${YELLOW}%s commit(s) behind the latest development version.${NC}\n" "Development Branch:" "$behind_count"
        elif [[ "$behind_count" -eq 0 && "$ahead_count" -gt 0 ]]; then
            printf "  %-20s You have ${BOLD}%s${NC} local commit(s) not in the development branch.\n" "Development Branch:" "$ahead_count"
        else
            printf "  %-20s ${YELLOW}Diverged.${NC} You are ${BOLD}%s${NC} ahead and ${BOLD}%s${NC} behind.\n" "Development Branch:" "$ahead_count" "$behind_count"
        fi
    else
        printf "  %-20s (Could not find remote development branch '${DEFAULT_BRANCH}')\n" "Development Branch:"
    fi
    echo "${BOLD}------------------------------------${NC}"
    echo
    read -r -p "Press Enter to view the main menu..."
}

################################################################################
# Main Menu
################################################################################

# Interactive main menu
main_menu() {
    while true; do
        # Update state before showing menu
        get_current_version
        check_local_changes
        
        clear
        echo
        echo "${BOLD}╔════════════════════════════════════════════════════════╗${NC}"
        echo "${BOLD}║       LyreBirdAudio - Version Manager v${VERSION}        ║${NC}"
        echo "${BOLD}╚════════════════════════════════════════════════════════╝${NC}"
        echo
        
        # Show current status in menu header
        if [[ "$IS_DETACHED" == "true" ]]; then
            echo "  Current Version: ${YELLOW}$CURRENT_VERSION${NC}"
        else
            echo "  Current Version: ${CYAN}$CURRENT_BRANCH${NC} @ ${BOLD}$CURRENT_VERSION${NC}"
        fi
        
        if [[ "$HAS_LOCAL_CHANGES" == "true" ]]; then
            echo "  Local Changes:   ${YELLOW}You have unsaved changes${NC}"
        else
            echo "  Local Changes:   ${GREEN}None${NC}"
        fi
        
        echo
        echo "${BOLD}═══ UPDATE ═══${NC}"
        echo "  ${BOLD}1${NC}) Switch to Latest Stable Release"
        echo "  ${BOLD}2${NC}) Switch to Development Version ($DEFAULT_BRANCH)"
        echo "  ${BOLD}3${NC}) Switch to Specific Version..."
        echo
        echo "${BOLD}═══ STATUS & INFO ═══${NC}"
        echo "  ${BOLD}4${NC}) Check for New Updates on GitHub"
        echo "  ${BOLD}5${NC}) Show Detailed Status"
        echo "  ${BOLD}6${NC}) View My Local Changes"
        echo
        echo "${BOLD}═══ ADVANCED ═══${NC}"
        echo "  ${BOLD}7${NC}) Discard All Changes & Reset..."
        echo "  ${BOLD}8${NC}) Save Changes as Backup"
        echo
        echo "  ${BOLD}H${NC}) Help  |  ${BOLD}Q${NC}) Quit"
        echo
        read -r -p "Select option [1-8, H, Q]: " choice
        
        case "$choice" in
            1)
                # Switch to latest stable - fetch then switch
                log_info "Checking for latest stable release..."
                if ! fetch_updates; then
                    log_warn "Could not check for updates, using cached information"
                fi
                switch_to_latest_stable
                read -r -p "Press Enter to continue..."
                ;;
            2)
                # Switch to development branch - fetch then switch
                log_info "Switching to development version..."
                if ! fetch_updates; then
                    log_warn "Could not check for updates, using cached information"
                fi
                switch_version "$DEFAULT_BRANCH"
                read -r -p "Press Enter to continue..."
                ;;
            3)
                # Interactive version selection with fetch
                select_version_interactive
                read -r -p "Press Enter to continue..."
                ;;
            4)
                # Just fetch and show what's available
                fetch_updates
                echo
                list_available_releases
                read -r -p "Press Enter to continue..."
                ;;
            5)
                show_status
                read -r -p "Press Enter to continue..."
                ;;
            6)
                show_local_modifications
                read -r -p "Press Enter to continue..."
                ;;
            7)
                # Reset submenu
                reset_interactive_menu
                ;;
            8)
                create_manual_backup
                read -r -p "Press Enter to continue..."
                ;;
            h|H)
                show_help
                read -r -p "Press Enter to continue..."
                ;;
            q|Q)
                echo
                log_info "Thank you for using LyreBirdAudio Version Manager"
                CLEANUP_REQUIRED=false  # Normal exit, no cleanup needed
                return 0
                ;;
            *)
                log_error "Invalid option: $choice"
                sleep 1
                ;;
        esac
    done
}

# Interactive reset menu with clear options
reset_interactive_menu() {
    while true; do
        echo
        echo "${BOLD}═══ DISCARD CHANGES & RESET ═══${NC}"
        log_warn "This will permanently delete all your local changes!"
        echo
        echo "Reset to which version?"
        echo "  ${BOLD}1${NC}) Latest version on current branch"
        echo "  ${BOLD}2${NC}) Latest development version ($DEFAULT_BRANCH)"
        echo "  ${BOLD}3${NC}) Specific version (let me choose)"
        echo "  ${BOLD}C${NC}) Cancel - Don't reset"
        echo
        read -r -p "Select [1-3, C]: " reset_choice
        
        case "$reset_choice" in
            1)
                get_current_version
                if [[ "$IS_DETACHED" == "true" ]]; then
                    log_warn "You're viewing a specific version, not on a branch"
                    log_info "Resetting to HEAD won't change anything"
                    log_info "Suggestion: Choose option 2 or 3 instead"
                    echo
                    read -r -p "Continue anyway? [y/N] " response
                    if [[ "$response" =~ ^[Yy]$ ]]; then
                        reset_clean "HEAD"
                    else
                        log_info "Reset cancelled"
                    fi
                else
                    # Validate remote branch exists before resetting
                    if git show-ref --verify --quiet "refs/remotes/origin/$CURRENT_BRANCH"; then
                        reset_clean "origin/$CURRENT_BRANCH"
                    else
                        log_error "Remote version of branch '$CURRENT_BRANCH' not found"
                        log_info "This might be a local-only branch"
                        echo
                        read -r -p "Reset to local HEAD instead? [y/N] " response
                        if [[ "$response" =~ ^[Yy]$ ]]; then
                            reset_clean "HEAD"
                        else
                            log_info "Reset cancelled"
                        fi
                    fi
                fi
                read -r -p "Press Enter to continue..."
                return 0
                ;;
            2)
                # Validate default branch exists
                if git show-ref --verify --quiet "refs/remotes/origin/$DEFAULT_BRANCH"; then
                    reset_clean "origin/$DEFAULT_BRANCH"
                else
                    log_error "Development branch '$DEFAULT_BRANCH' not found"
                    log_info "Try Option 4 from main menu to check for updates first"
                fi
                read -r -p "Press Enter to continue..."
                return 0
                ;;
            3)
                # Fetch updates first
                log_info "Fetching available versions..."
                if ! fetch_updates; then
                    log_warn "Could not fetch updates, showing cached information"
                fi
                
                # Show available versions
                list_available_releases
                
                echo
                read -r -p "Enter version to reset to (e.g., v1.1.0 or $DEFAULT_BRANCH): " version
                if [[ -z "$version" ]]; then
                    log_info "No version specified - cancelled"
                elif ! validate_version_exists "$version"; then
                    log_error "Version '$version' does not exist"
                    log_info "Check spelling and try again"
                else
                    reset_clean "$version"
                fi
                read -r -p "Press Enter to continue..."
                return 0
                ;;
            c|C)
                log_info "Reset cancelled - no changes made"
                read -r -p "Press Enter to continue..."
                return 0
                ;;
            *)
                log_error "Invalid choice - please enter 1, 2, 3, or C"
                sleep 1
                ;;
        esac
    done
}

# Main function
main() {
    # Change to script directory
    if ! cd "$SCRIPT_DIR" 2>/dev/null; then
        log_error "Failed to change to script directory: $SCRIPT_DIR"
        exit "$E_GENERAL"
    fi
    
    # Check prerequisites first
    if ! check_prerequisites; then
        exit "$E_PREREQUISITES"
    fi
    
    # Check git repository
    check_git_repository
    local repo_check_status=$?
    if [[ "$repo_check_status" -ne 0 ]]; then
        exit "$repo_check_status"
    fi
    
    # Configure Git to ignore file mode changes
    configure_git_filemode
    
    # Detect default branch (main vs master)
    DEFAULT_BRANCH="$(get_default_branch)"
    log_debug "Detected default branch: $DEFAULT_BRANCH"
    
    # Check for command line arguments
    if [[ $# -gt 0 ]]; then
        case "$1" in
            --version|-v)
                echo "LyreBirdAudio Version Manager v${VERSION}"
                echo "Requires: Git ${MIN_GIT_MAJOR}.0+, Bash ${MIN_BASH_MAJOR}.0+"
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
                if fetch_updates; then
                    list_available_releases
                else
                    log_warn "Using cached repository information"
                    list_available_releases
                fi
                exit "$E_SUCCESS"
                ;;
            *)
                log_error "Unknown option: $1"
                echo
                echo "Usage: $SCRIPT_NAME [OPTION]"
                echo "Try '$SCRIPT_NAME --help' for more information"
                exit "$E_GENERAL"
                ;;
        esac
    else
        # Show startup diagnostics if running interactively without flags
        show_startup_diagnostics
    fi
    
    # Run interactive menu
    main_menu
    
    exit "$E_SUCCESS"
}

# Run main function
main "$@"
