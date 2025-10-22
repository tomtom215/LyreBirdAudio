#!/bin/bash
# lyrebird-updater.sh - Interactive LyreBirdAudio Version Manager
# Part of LyreBirdAudio - RTSP Audio Streaming Suite
# https://github.com/tomtom215/LyreBirdAudio
#
# This script provides an interactive interface for managing LyreBirdAudio versions,
# handling git operations, and switching between releases safely.
#
# Version: 1.1.0 - Comprehensive Stability and Reliability Update
#
# Changelog v1.1.0 (2025-10-22):
#
# CRITICAL FIXES - Stash Management:
#   - Fixed stash restoration failure when pulled changes conflict with stashed files
#   - Implemented three-phase stash restoration strategy: pop → apply → manual resolution
#   - Added stash_restore_with_retry() for robust restoration with detailed conflict reporting
#   - Fixed stash reference lookup to match actual git stash list format
#   - Fixed potential race condition where wrong stash could be popped by finding exact stash by reference
#   - Added validation to ensure stash exists before restoration attempts
#   - Improved error messages to clearly distinguish between pull conflicts and stash conflicts
#
# CRITICAL FIXES - Empty Repository Handling:
#   - Fixed get_current_version() to handle empty repos with no HEAD
#   - Fixed check_local_changes() to handle missing HEAD safely
#   - Improved safety for freshly cloned or empty repositories
#   - Prevents crashes when HEAD doesn't exist
#
# CRITICAL FIXES - Version Comparison:
#   - Fixed switch_version() to use exact string match instead of flawed normalize_version
#   - Eliminated version-sorting bugs (e.g., v1.10.0 vs v1.2.0 comparison issues)
#   - More reliable detection of "already on version" state
#
# Git Operations & Permissions:
#   - Fixed get_default_branch() to use git ls-remote --symref for reliable detection
#   - Enhanced validate_version_exists() to check remote branches via git ls-remote
#   - Added proactive root ownership detection in check_git_repository()
#   - Added check_git_permissions() function for early permission issue detection
#   - Fixed set_script_permissions() to be truly non-critical (no return 1)
#   - Improved error messages for permission issues with actionable solutions
#
# Security & Validation:
#   - Added regex validation for commit SHA format
#   - Enhanced input validation throughout
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

set -euo pipefail

# Script identification
SCRIPT_NAME="$(basename "${BASH_SOURCE[0]}")"
readonly SCRIPT_NAME
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly SCRIPT_DIR

# Version
readonly VERSION="1.1.0"

# Repository information
readonly REPO_URL="https://github.com/tomtom215/LyreBirdAudio.git"
readonly REPO_OWNER="tomtom215"
readonly REPO_NAME="LyreBirdAudio"

# Minimum required versions
readonly MIN_BASH_MAJOR=4
readonly MIN_GIT_MAJOR=2

# Initialize color codes (set before readonly)
if [[ -t 1 ]] && command -v tput >/dev/null 2>&1 && tput colors &>/dev/null 2>&1; then
    RED="$(tput setaf 1 2>/dev/null || echo "")"
    GREEN="$(tput setaf 2 2>/dev/null || echo "")"
    YELLOW="$(tput setaf 3 2>/dev/null || echo "")"
    BLUE="$(tput setaf 4 2>/dev/null || echo "")"
    CYAN="$(tput setaf 6 2>/dev/null || echo "")"
    BOLD="$(tput bold 2>/dev/null || echo "")"
    NC="$(tput sgr0 2>/dev/null || echo "")"
else
    RED=""
    GREEN=""
    YELLOW=""
    BLUE=""
    CYAN=""
    BOLD=""
    NC=""
fi
readonly RED GREEN YELLOW BLUE CYAN BOLD NC

# Exit codes
readonly E_SUCCESS=0
readonly E_GENERAL=1
readonly E_NOT_GIT_REPO=2
readonly E_GIT_ERROR=3
readonly E_USER_ABORT=4
readonly E_NETWORK_ERROR=5
readonly E_MERGE_CONFLICT=6
readonly E_PREREQUISITES=7
readonly E_PERMISSION=8

# Global state
CURRENT_VERSION=""
CURRENT_BRANCH=""
IS_DETACHED=false
HAS_LOCAL_CHANGES=false
STASH_CREATED=false
LAST_STASH_NAME=""
CLEANUP_REQUIRED=false
DEFAULT_BRANCH=""

# Required scripts that should be executable (add/remove as needed for your project)
readonly -a REQUIRED_EXECUTABLE_SCRIPTS=(
    "install_mediamtx.sh"
    "usb-audio-mapper.sh"
    "mediamtx-stream-manager.sh"
    "lyrebird-updater.sh"
)

# Logging functions
log_info() {
    echo -e "${GREEN}[INFO]${NC} $*"
}

log_warn() {
    echo -e "${YELLOW}[WARN]${NC} $*"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $*" >&2
}

log_success() {
    echo -e "${GREEN}[SUCCESS]${NC} $*"
}

log_header() {
    echo
    echo -e "${CYAN}${BOLD}=== $* ===${NC}"
    echo
}

log_debug() {
    if [[ "${DEBUG:-0}" == "1" ]]; then
        echo -e "${BLUE}[DEBUG]${NC} $*" >&2
    fi
}

# Cleanup handler for graceful exit
# shellcheck disable=SC2317  # Invoked via trap on EXIT, not directly called
cleanup_on_exit() {
    local exit_code=$?
    
    if [[ "$CLEANUP_REQUIRED" == "true" ]]; then
        # Only show warning message if exit was due to error or interruption
        # (not for user abort or intentional stash retention)
        if [[ "$exit_code" -ne 0 && "$exit_code" -ne "$E_USER_ABORT" ]]; then
            log_warn "Script interrupted or failed during operation"
        fi
        
        if [[ "$STASH_CREATED" == "true" && -n "$LAST_STASH_NAME" ]]; then
            echo
            log_info "Your local changes are saved in stash: $LAST_STASH_NAME"
            log_info "To restore them later:"
            log_info "  git stash list              # View all stashes"
            log_info "  git stash apply stash@{N}   # Apply specific stash"
            log_info "  git stash pop               # Apply and remove latest stash"
        fi
    fi
    
    exit "$exit_code"
}

# Set up signal handlers
trap cleanup_on_exit EXIT
trap 'log_error "Received SIGINT, exiting..."; exit 130' INT
trap 'log_error "Received SIGTERM, exiting..."; exit 143' TERM

# Offer assistance with cloning the repository
# This is called when the script is run from a non-git directory
offer_clone_assistance() {
    log_header "Clone Repository Assistant"
    
    local default_clone_dir="$HOME/LyreBirdAudio"
    local current_dir
    current_dir="$(pwd)"
    
    echo "I'll help you clone the LyreBirdAudio repository."
    echo
    echo "Current directory (with WIP files): ${CYAN}${current_dir}${NC}"
    echo "Suggested clone location: ${CYAN}${default_clone_dir}${NC}"
    echo
    
    read -r -p "Enter clone directory [${default_clone_dir}]: " clone_dir
    clone_dir="${clone_dir:-$default_clone_dir}"
    
    # Expand tilde
    clone_dir="${clone_dir/#\~/$HOME}"
    
    # Check if directory already exists
    if [[ -e "$clone_dir" ]]; then
        log_error "Directory already exists: $clone_dir"
        
        if [[ -d "$clone_dir/.git" ]]; then
            log_info "This appears to be a git repository already."
            echo
            read -r -p "Switch to this directory and run the script? [Y/n] " response
            if [[ ! "$response" =~ ^[Nn]$ ]]; then
                log_info "Run these commands:"
                echo "  cd \"$clone_dir\""
                echo "  ./lyrebird-updater.sh"
            fi
        else
            log_warn "Please choose a different directory or remove/rename the existing one"
        fi
        return "$E_GENERAL"
    fi
    
    # Create parent directory if needed
    local parent_dir
    parent_dir="$(dirname "$clone_dir")"
    if [[ ! -d "$parent_dir" ]]; then
        log_info "Creating parent directory: $parent_dir"
        if ! mkdir -p "$parent_dir" 2>/dev/null; then
            log_error "Failed to create parent directory: $parent_dir"
            log_error "You may need to use sudo or choose a different location"
            return "$E_GENERAL"
        fi
    fi
    
    # Clone the repository
    log_info "Cloning repository to: $clone_dir"
    echo
    
    if git clone "$REPO_URL" "$clone_dir"; then
        log_success "Repository cloned successfully!"
        echo
        log_info "Next steps:"
        echo "  1. Switch to the cloned directory:"
        echo "     ${CYAN}cd \"$clone_dir\"${NC}"
        echo
        echo "  2. Run the version manager:"
        echo "     ${CYAN}./lyrebird-updater.sh${NC}"
        echo
        echo "  3. If you have custom changes in: ${CYAN}${current_dir}${NC}"
        echo "     Review and copy them carefully to avoid overwriting repository files"
        echo
        log_warn "Keep your WIP directory separate to avoid confusion!"
        return 0
    else
        log_error "Failed to clone repository"
        log_error "Please check:"
        echo "  - Internet connection"
        echo "  - GitHub access"
        echo "  - Write permissions for: $clone_dir"
        return "$E_GIT_ERROR"
    fi
}

# Check if command exists
command_exists() {
    command -v "$1" &>/dev/null
}

# Check prerequisites
check_prerequisites() {
    local errors=0
    
    # Check bash version
    local bash_version
    bash_version="$(echo "$BASH_VERSION" | cut -d'.' -f1)"
    
    if [[ "$bash_version" -lt "$MIN_BASH_MAJOR" ]]; then
        log_error "Bash version $MIN_BASH_MAJOR.0+ required (found: $BASH_VERSION)"
        ((++errors))
    else
        log_debug "Bash version check passed: $BASH_VERSION"
    fi
    
    # Check git
    if ! command_exists git; then
        log_error "Git is not installed or not in PATH"
        log_error "Please install Git $MIN_GIT_MAJOR.0+ to use this script"
        ((++errors))
    else
        local git_version
        git_version="$(git --version 2>/dev/null | grep -oE '[0-9]+\.[0-9]+' | head -n1 | cut -d'.' -f1)"
        
        if [[ -z "$git_version" ]]; then
            log_warn "Could not determine Git version"
        elif [[ "$git_version" -lt "$MIN_GIT_MAJOR" ]]; then
            log_error "Git version $MIN_GIT_MAJOR.0+ required (found: $(git --version))"
            ((++errors))
        else
            log_debug "Git version check passed: $(git --version)"
        fi
    fi
    
    if [[ "$errors" -gt 0 ]]; then
        log_error "Prerequisites check failed with $errors error(s)"
        return 1
    fi
    
    log_debug "All prerequisites satisfied"
    return 0
}

# Check if we're in a git repository
check_git_repository() {
    if ! git rev-parse --git-dir &>/dev/null; then
        log_error "Not a git repository"
        log_error "This script must be run from within a git-cloned LyreBirdAudio repository"
        echo
        echo "You have two options:"
        echo "  1. Clone the repository using this script's assistant"
        echo "  2. Clone manually: git clone $REPO_URL"
        echo
        read -r -p "Would you like help cloning the repository now? [Y/n] " response
        
        if [[ ! "$response" =~ ^[Nn]$ ]]; then
            offer_clone_assistance
            return "$E_NOT_GIT_REPO"
        else
            log_info "To clone manually, run:"
            echo "  git clone $REPO_URL"
            echo "  cd LyreBirdAudio"
            echo "  ./lyrebird-updater.sh"
            return "$E_NOT_GIT_REPO"
        fi
    fi
    
    # Proactive permission check to catch issues early
    if ! check_git_permissions; then
        return "$E_PERMISSION"
    fi
    
    # Verify it's the correct repository
    local remote_url
    remote_url="$(git config --get remote.origin.url 2>/dev/null || echo "")"
    
    if [[ -z "$remote_url" ]]; then
        log_warn "No remote origin configured"
        log_info "Expected repository: $REPO_URL"
        echo
        read -r -p "Continue anyway? [y/N] " response
        if [[ ! "$response" =~ ^[Yy]$ ]]; then
            return "$E_NOT_GIT_REPO"
        fi
    elif [[ ! "$remote_url" =~ $REPO_OWNER/$REPO_NAME ]]; then
        log_warn "This doesn't appear to be the LyreBirdAudio repository"
        log_warn "Current remote: $remote_url"
        log_warn "Expected: $REPO_URL"
        echo
        read -r -p "Continue anyway? [y/N] " response
        if [[ ! "$response" =~ ^[Yy]$ ]]; then
            return "$E_NOT_GIT_REPO"
        fi
    fi
    
    log_debug "Git repository check passed"
    return 0
}

# Check for root-owned files in .git directory
# This is a common issue when git commands are run with sudo
check_git_permissions() {
    log_debug "Checking .git directory permissions..."
    
    # Check if .git directory exists
    if [[ ! -d ".git" ]]; then
        log_debug ".git directory not found (will be checked later)"
        return 0
    fi
    
    # Check for root-owned files
    local root_owned_files
    root_owned_files=$(find .git -user root 2>/dev/null | wc -l)
    
    if [[ "$root_owned_files" -gt 0 ]]; then
        log_error "CRITICAL: $root_owned_files files in .git/ are owned by root"
        log_error "This will prevent git operations from working correctly"
        echo
        log_error "ROOT CAUSE: Git commands were likely run with 'sudo' previously"
        echo
        echo "SOLUTION: Fix file ownership with one of these commands:"
        echo
        echo "  ${CYAN}# Option 1: Fix ownership for current user${NC}"
        echo "  sudo chown -R \$USER:\$USER .git/"
        echo
        echo "  ${CYAN}# Option 2: Use the fix-git-permissions.sh script if available${NC}"
        echo "  sudo ./fix-git-permissions.sh"
        echo
        log_warn "After fixing permissions, run this script again"
        echo
        
        # Show some example problematic files
        echo "Example root-owned files:"
        find .git -user root 2>/dev/null | head -n 5 | sed 's/^/  /'
        if [[ "$root_owned_files" -gt 5 ]]; then
            echo "  ... and $((root_owned_files - 5)) more files"
        fi
        echo
        
        return "$E_PERMISSION"
    fi
    
    # Check if .git directory is writable
    if [[ ! -w ".git" ]]; then
        log_error ".git directory is not writable by current user"
        log_error "Current permissions:"
        stat -c "  %A %U:%G %n" .git 2>/dev/null || stat -f "  %Sp %Su:%Sg %N" .git 2>/dev/null || echo "  (unable to determine)"
        echo
        echo "Fix with:"
        echo "  chmod u+w .git"
        return "$E_PERMISSION"
    fi
    
    log_debug "Git permissions check passed"
    return 0
}

# Detect the default branch (main or master)
get_default_branch() {
    local branch
    
    # First, try local symbolic-ref (fastest, if available)
    branch="$(git symbolic-ref refs/remotes/origin/HEAD 2>/dev/null | sed 's@^refs/remotes/origin/@@')"
    
    if [[ -n "$branch" ]]; then
        log_debug "Default branch from local symbolic-ref: $branch"
        echo "$branch"
        return 0
    fi
    
    # If not available locally, check remote directly using git ls-remote --symref
    # This is the definitive way to determine the remote's default branch
    if git ls-remote --exit-code --symref origin HEAD &>/dev/null; then
        branch="$(git ls-remote --symref origin HEAD 2>/dev/null | awk '/^ref:/ {print $2}' | sed 's@refs/heads/@@' | head -n1)"
        
        if [[ -n "$branch" ]]; then
            log_debug "Default branch from remote symref: $branch"
            echo "$branch"
            return 0
        fi
    fi
    
    # Fallback: check which remote branch exists locally
    if git show-ref --verify --quiet refs/remotes/origin/main 2>/dev/null; then
        branch="main"
    elif git show-ref --verify --quiet refs/remotes/origin/master 2>/dev/null; then
        branch="master"
    else
        # Last resort: default to main
        branch="main"
        log_debug "Using default fallback: $branch"
    fi
    
    echo "$branch"
}

# Get current version/commit
get_current_version() {
    # Determine if we're on a branch or in detached HEAD
    if ! git rev-parse --verify --quiet HEAD >/dev/null 2>&1; then
        # Empty repository or no commits
        IS_DETACHED=false
        CURRENT_BRANCH=""
        CURRENT_VERSION="no-commits"
        log_debug "No HEAD found in repository"
        return
    fi
    
    local current_ref
    current_ref="$(git symbolic-ref -q HEAD 2>/dev/null || echo "")"
    
    if [[ -n "$current_ref" ]]; then
        # We're on a branch
        IS_DETACHED=false
        CURRENT_BRANCH="${current_ref#refs/heads/}"
        CURRENT_VERSION="$(git rev-parse --short HEAD 2>/dev/null || echo "unknown")"
    else
        # Detached HEAD - check if we're at a tag
        IS_DETACHED=true
        CURRENT_BRANCH=""
        
        local tag
        tag="$(git describe --exact-match --tags HEAD 2>/dev/null || echo "")"
        
        if [[ -n "$tag" ]]; then
            CURRENT_VERSION="$tag"
        else
            CURRENT_VERSION="$(git rev-parse --short HEAD 2>/dev/null || echo "unknown")"
        fi
    fi
    
    log_debug "Current version: $CURRENT_VERSION (detached: $IS_DETACHED)"
}

# Check for local modifications
check_local_changes() {
    if ! git rev-parse --verify --quiet HEAD >/dev/null 2>&1; then
        # No HEAD, consider all untracked files as "changes"
        HAS_LOCAL_CHANGES=true
        return
    fi
    
    if git diff-index --quiet HEAD -- 2>/dev/null && [[ -z "$(git ls-files --others --exclude-standard 2>/dev/null)" ]]; then
        HAS_LOCAL_CHANGES=false
    else
        HAS_LOCAL_CHANGES=true
    fi
    
    log_debug "Local changes: $HAS_LOCAL_CHANGES"
}

# Normalize version string for comparison
normalize_version() {
    local version="$1"
    # Remove 'v' prefix and any trailing commit hash
    version="${version#v}"
    version="${version%%-*}"
    echo "$version"
}

# Create backup stash
create_backup_stash() {
    log_warn "You have local changes that need to be saved"
    echo
    echo "Local changes detected. These will be temporarily saved (stashed)"
    echo "and can be restored after the operation completes."
    echo
    echo "Changed files:"
    git status --short 2>/dev/null | sed 's/^/  /' || echo "  (unable to list)"
    echo
    
    read -r -p "Save these changes and continue? [Y/n] " response
    if [[ "$response" =~ ^[Nn]$ ]]; then
        log_info "Operation cancelled"
        return "$E_USER_ABORT"
    fi
    
    local stash_name
    stash_name="auto-backup-$(date +%Y%m%d-%H%M%S)-$$"
    local stash_output
    
    if stash_output=$(git stash push -u -m "$stash_name" 2>&1); then
        STASH_CREATED=true
        LAST_STASH_NAME="$stash_name"
        CLEANUP_REQUIRED=true
        log_success "Local changes saved: $stash_name"
        return 0
    else
        log_error "Failed to save local changes"
        log_error "Git output: $stash_output"
        return "$E_GIT_ERROR"
    fi
}

# Restore from stash with intelligent conflict handling
# Returns: 0 on success, 1 on failure with stash preserved
stash_restore_with_retry() {
    if [[ "$STASH_CREATED" != "true" ]]; then
        log_debug "No stash to restore (STASH_CREATED=false)"
        return 0
    fi
    
    # Verify stash still exists
    # Note: We just check if there's ANY stash since we just created one
    # The message is stored but git stash list shows it in a different format
    if ! git stash list 2>/dev/null | head -n1 | grep -q .; then
        log_warn "Stash '$LAST_STASH_NAME' not found in stash list"
        STASH_CREATED=false
        CLEANUP_REQUIRED=false
        return 0
    fi
    
    log_info "Restoring local changes from backup..."

    # Find the exact stash reference by message
    local stash_ref
    # git stash list format: stash@{0}: On main: auto-backup-...
    stash_ref=$(git stash list 2>/dev/null | grep -F ": $LAST_STASH_NAME" | head -n1 | cut -d: -f1)
    
    if [[ -z "$stash_ref" ]]; then
        log_warn "Stash '$LAST_STASH_NAME' not found in stash list"
        STASH_CREATED=false
        CLEANUP_REQUIRED=false
        return 0
    fi

    log_debug "Found stash reference: $stash_ref"

    local pop_output
    local pop_status=0
    
    # Phase 1: Try git stash pop on the exact stash
    pop_output=$(git stash pop "$stash_ref" 2>&1) || pop_status=$?
    
    if [[ "$pop_status" -eq 0 ]]; then
        log_success "Local changes restored successfully"
        STASH_CREATED=false
        CLEANUP_REQUIRED=false
        return 0
    fi
    
    # Phase 2: Pop failed, check if it's due to conflicts
    if echo "$pop_output" | grep -qi "conflict\|CONFLICT"; then
        log_warn "Cannot automatically restore changes due to conflicts with pulled updates"
        echo
        log_warn "The following files have conflicts between your local changes and the update:"
        
        # Try to extract conflicted files from the error message
        if git diff --name-only --diff-filter=U 2>/dev/null | grep -q .; then
            git diff --name-only --diff-filter=U 2>/dev/null | sed 's/^/  /'
        else
            echo "$pop_output" | grep -i "conflict" | sed 's/^/  /'
        fi
        
        echo
        log_info "Your changes are safely preserved in stash: $LAST_STASH_NAME"
        log_info "Options to resolve this:"
        echo
        echo "  ${CYAN}Option 1: Keep the updated versions (discard your local changes)${NC}"
        echo "    git reset --hard HEAD"
        echo "    # Your stash is still available if you need it later"
        echo
        echo "  ${CYAN}Option 2: Manually merge your changes${NC}"
        echo "    # The stash is already partially applied with conflict markers"
        echo "    # Edit the conflicted files to resolve conflicts"
        echo "    git add <resolved-files>"
        echo "    git stash drop  # Remove the stash after resolving"
        echo
        echo "  ${CYAN}Option 3: Abort and restore previous state${NC}"
        echo "    git reset --hard HEAD"
        echo "    git stash apply stash@{0}  # Re-apply your changes"
        echo
        
        # Keep the stash and cleanup flags set so user knows it's still there
        return 1
    fi
    
    # Phase 3: Failed for other reasons, try apply instead of pop
    log_warn "Could not automatically restore with 'git stash pop'"
    log_debug "Pop output: $pop_output"
    log_info "Attempting alternative restoration method..."
    
    local apply_output
    local apply_status=0
    
    apply_output=$(git stash apply 2>&1) || apply_status=$?
    
    if [[ "$apply_status" -eq 0 ]]; then
        log_success "Local changes restored using 'git stash apply'"
        log_info "The stash is preserved in case you need it again"
        log_info "To remove it: git stash drop"
        # Keep STASH_CREATED=true so cleanup message shows
        return 0
    else
        log_warn "Could not automatically restore local changes"
        log_warn "Git output: $apply_output"
        echo
        log_warn "Your changes are still safely stored in stash: $LAST_STASH_NAME"
        log_info "To restore manually:"
        log_info "  git stash list              # Find your stash"
        log_info "  git stash apply stash@{N}   # Apply specific stash"
        log_info "  git diff                    # Review any conflicts"
        return 1
    fi
}

# Legacy function for backward compatibility
# shellcheck disable=SC2317  # Invoked indirectly via multiple call sites
restore_backup_stash() {
    stash_restore_with_retry
}

# Check network connectivity to GitHub
check_network_connectivity() {
    log_debug "Testing network connectivity to GitHub..."
    
    if ! git ls-remote --exit-code origin HEAD &>/dev/null; then
        log_warn "Cannot reach GitHub repository"
        log_warn "Please check your internet connection"
        return "$E_NETWORK_ERROR"
    fi
    
    return 0
}

# Fetch latest repository information with improved error handling
fetch_updates() {
    log_info "Fetching latest repository information..."
    
    # Check network first
    if ! check_network_connectivity; then
        log_error "Cannot fetch updates: No network connectivity"
        return "$E_NETWORK_ERROR"
    fi
    
    local fetch_output
    local fetch_status=0
    
    # Try to fix .git/FETCH_HEAD permissions if it exists
    if [[ -f ".git/FETCH_HEAD" ]] && [[ ! -w ".git/FETCH_HEAD" ]]; then
        log_debug "Attempting to fix FETCH_HEAD permissions..."
        if chmod u+w ".git/FETCH_HEAD" 2>/dev/null; then
            log_debug "Fixed FETCH_HEAD permissions"
        else
            log_warn "Could not fix FETCH_HEAD permissions (may require sudo)"
        fi
    fi
    
    fetch_output=$(git fetch --tags --prune origin 2>&1) || fetch_status=$?
    
    if [[ "$fetch_status" -ne 0 ]]; then
        # Check if it's a permission error
        if echo "$fetch_output" | grep -qi "permission denied"; then
            log_error "Failed to fetch updates from repository"
            log_error "Git output: $fetch_output"
            log_error ""
            log_error "Permission issue detected."
            echo
            
            # Check if the issue is root ownership
            local root_owned_files
            root_owned_files=$(find .git -user root 2>/dev/null | wc -l)
            
            if [[ "$root_owned_files" -gt 0 ]]; then
                log_error "ROOT CAUSE: $root_owned_files files in .git/ are owned by root"
                log_error "This typically happens when git commands were run with 'sudo'"
                echo
                echo "SOLUTION: Fix file ownership with:"
                echo "  sudo chown -R \$USER:\$USER .git/"
                echo
                echo "Or run the fix script:"
                echo "  ./fix-git-permissions.sh"
                echo
                echo "Then try again."
            else
                echo "Possible solutions:"
                echo "  1. Check file permissions in .git directory:"
                echo "     ls -la .git/"
                echo "  2. Fix permissions:"
                echo "     chmod -R u+w .git/"
                echo "  3. If running in a shared directory, ensure you have write access"
            fi
            return "$E_GIT_ERROR"
        else
            log_error "Failed to fetch updates from repository"
            log_error "Git output: $fetch_output"
            return "$E_GIT_ERROR"
        fi
    fi
    
    log_success "Repository information updated"
    log_debug "Fetch output: $fetch_output"
    return 0
}

# Get latest stable release by CREATION DATE (not version number)
# This ensures we get the most recently published release, even if version numbers don't sort chronologically
get_latest_stable_release() {
    local latest
    
    # Get all version tags sorted by creation date (most recent first)
    # Filter out pre-release tags (alpha, beta, rc, pre, dev)
    latest="$(git tag -l 'v*' --sort=-creatordate 2>/dev/null | grep -vE '\-?(alpha|beta|rc|pre|dev)' | head -n1)"
    
    if [[ -z "$latest" ]]; then
        log_error "No stable releases found in repository"
        return "$E_GENERAL"
    fi
    
    echo "$latest"
    return 0
}

# Check for merge conflicts
check_merge_conflicts() {
    if git ls-files -u 2>/dev/null | grep -q .; then
        return 0  # Conflicts exist
    else
        return 1  # No conflicts
    fi
}

# Handle merge conflicts
handle_merge_conflicts() {
    log_error "Merge conflict detected"
    echo
    log_error "Files in conflict:"
    git diff --name-only --diff-filter=U 2>/dev/null | sed 's/^/  /' || echo "  (unable to list conflicted files)"
    echo
    log_error "Please resolve conflicts manually using one of these methods:"
    echo
    echo "  Option 1: Abort the merge and restore previous state"
    echo "    git merge --abort"
    echo
    echo "  Option 2: Reset to clean state (DESTRUCTIVE)"
    echo "    git reset --hard HEAD"
    echo "    git clean -fd"
    echo
    echo "  Option 3: Resolve conflicts manually"
    echo "    - Edit conflicted files"
    echo "    - git add <resolved-files>"
    echo "    - git commit"
    echo
    return "$E_MERGE_CONFLICT"
}

# List available releases with proper date-based sorting
list_available_releases() {
    log_header "Available Releases"
    
    # Get all tags sorted by creation date (most recent first)
    local tags
    tags="$(git tag -l 'v*' --sort=-creatordate 2>/dev/null || echo "")"
    
    if [[ -n "$tags" ]]; then
        echo "Stable Releases (sorted by release date, newest first):"
        echo
        
        local count=0
        while IFS= read -r tag; do
            [[ -z "$tag" ]] && continue
            ((++count))
            
            # Get tag date
            local tag_date
            tag_date="$(git log -1 --format=%ai "$tag" 2>/dev/null | cut -d' ' -f1)"
            
            # Get tag message or commit message
            local tag_message
            tag_message="$(git tag -l --format='%(contents:subject)' "$tag" 2>/dev/null | head -c 60)"
            
            # Check if this is the current version
            local marker=""
            if [[ "$(normalize_version "$CURRENT_VERSION")" == "$(normalize_version "$tag")" ]]; then
                marker=" ${GREEN}(current)${NC}"
            fi
            
            # Show tag with description if available
            if [[ -n "$tag_message" ]]; then
                printf "  ${CYAN}%-12s${NC} - %s - %s%s\n" "$tag" "$tag_date" "${tag_message:0:40}" "$marker"
            else
                printf "  ${CYAN}%-12s${NC} - %s%s\n" "$tag" "$tag_date" "$marker"
            fi
        done <<< "$tags"
        
        echo
        if [[ "$count" -eq 0 ]]; then
            log_warn "No version tags found"
        else
            echo "Total releases: $count"
        fi
        echo
    else
        log_warn "No release tags found in repository"
        echo
    fi
    
    echo "Development Branch:"
    local branch_marker=""
    if [[ "$CURRENT_BRANCH" == "$DEFAULT_BRANCH" ]]; then
        branch_marker=" ${GREEN}(current)${NC}"
    fi
    echo -e "  ${YELLOW}${DEFAULT_BRANCH}${NC}      - Latest development code (may be unstable)${branch_marker}"
    echo
}

# Show current status
show_status() {
    log_header "Current Status"
    
    get_current_version
    check_local_changes
    
    echo "Repository Information:"
    echo -e "  Location: ${CYAN}${SCRIPT_DIR}${NC}"
    
    local remote_url
    remote_url="$(git config --get remote.origin.url 2>/dev/null || echo 'not configured')"
    echo -e "  Remote:   ${CYAN}${remote_url}${NC}"
    echo
    
    echo "Version Information:"
    if [[ "$IS_DETACHED" == "true" ]]; then
        echo -e "  State:    ${YELLOW}Detached HEAD (viewing specific version)${NC}"
        echo -e "  Version:  ${CYAN}${CURRENT_VERSION}${NC}"
    else
        echo -e "  Branch:   ${CYAN}${CURRENT_BRANCH}${NC}"
        echo -e "  Commit:   ${CYAN}${CURRENT_VERSION}${NC}"
    fi
    echo
    
    echo "Local Changes:"
    if [[ "$HAS_LOCAL_CHANGES" == "true" ]]; then
        echo -e "  Status:   ${YELLOW}Modified files detected${NC}"
        echo
        echo "  Modified files:"
        git status --short 2>/dev/null | sed 's/^/    /' || echo "    (unable to list changes)"
    else
        echo -e "  Status:   ${GREEN}Clean (no modifications)${NC}"
    fi
    echo
    
    # Check if we're behind remote (only for branches)
    if [[ "$IS_DETACHED" == "false" ]]; then
        local behind_count ahead_count
        behind_count="$(git rev-list HEAD..origin/"$CURRENT_BRANCH" --count 2>/dev/null || echo "?")"
        ahead_count="$(git rev-list origin/"$CURRENT_BRANCH"..HEAD --count 2>/dev/null || echo "?")"
        
        if [[ "$behind_count" != "?" && "$ahead_count" != "?" ]]; then
            if [[ "$behind_count" -gt 0 ]]; then
                echo -e "Update Status: ${YELLOW}$behind_count commit(s) behind remote${NC}"
                if [[ "$ahead_count" -gt 0 ]]; then
                    echo -e "               ${YELLOW}$ahead_count commit(s) ahead of remote${NC}"
                fi
            elif [[ "$ahead_count" -gt 0 ]]; then
                echo -e "Update Status: ${YELLOW}$ahead_count commit(s) ahead of remote${NC}"
            else
                echo -e "Update Status: ${GREEN}Up to date${NC}"
            fi
        fi
    fi
}

# Set executable permissions on required scripts
# This is now truly non-critical and never returns error status
set_script_permissions() {
    log_debug "Setting script permissions..."
    
    local script
    local errors=0
    local -a failed_scripts=()
    
    for script in "${REQUIRED_EXECUTABLE_SCRIPTS[@]}"; do
        if [[ -f "$script" ]]; then
            if ! chmod +x "$script" 2>/dev/null; then
                log_warn "Could not set execute permission on: $script"
                ((++errors))
                failed_scripts+=("$script")
            else
                log_debug "Set executable: $script"
            fi
        else
            log_debug "Script not found (skipping): $script"
        fi
    done
    
    if [[ "$errors" -gt 0 ]]; then
        log_warn "Failed to set permissions on $errors script(s)"
        log_debug "Failed scripts: ${failed_scripts[*]}"
    fi
    
    # Always return success - this is non-critical
    return 0
}

# Validate that a version/tag/branch exists
validate_version_exists() {
    local target="$1"
    
    # Check if it's a local branch
    if git show-ref --verify --quiet "refs/heads/$target"; then
        log_debug "Found local branch: $target"
        return 0
    fi
    
    # Check if it's a remote branch (requires fetch)
    if git show-ref --verify --quiet "refs/remotes/origin/$target"; then
        log_debug "Found remote tracking branch: $target"
        return 0
    fi
    
    # Check if it's a tag
    if git show-ref --verify --quiet "refs/tags/$target"; then
        log_debug "Found tag: $target"
        return 0
    fi
    
    # Try to resolve as a commit SHA (6+ chars)
    if [[ "$target" =~ ^[a-f0-9]{6,40}$ ]] && git rev-parse --verify --quiet "$target" &>/dev/null; then
        log_debug "Found commit: $target"
        return 0
    fi
    
    # Final check: query remote directly (slower, but definitive)
    # This catches remote branches that haven't been fetched yet
    if git ls-remote --exit-code origin "$target" &>/dev/null; then
        log_debug "Found on remote: $target"
        return 0
    fi
    
    log_debug "Version not found: $target"
    return 1
}

# Switch to a different version/branch/tag
switch_version() {
    local target="$1"
    
    log_header "Switch to Version: $target"
    
    # Validate target exists
    if ! validate_version_exists "$target"; then
        log_error "Version '$target' does not exist or is not reachable"
        log_info "Available options:"
        log_info "  - Run option 2 'List available versions' to see valid versions"
        log_info "  - Use 'Fetch Updates' to download latest releases"
        log_info "  - Check spelling/capitalization"
        return "$E_GENERAL"
    fi
    
    get_current_version
    check_local_changes
    
    # Only skip if we're exactly on the same ref (branch name or tag/commit hash match)
    # Note: CURRENT_VERSION is either a tag name (if at tag) or short SHA, not normalized
    if [[ "$target" == "$CURRENT_BRANCH" ]] || [[ "$target" == "$CURRENT_VERSION" ]]; then
        log_info "Already on version: $target"
        return 0
    fi
    
    # Backup local changes if present
    if [[ "$HAS_LOCAL_CHANGES" == "true" ]]; then
        if ! create_backup_stash; then
            return "$E_GIT_ERROR"
        fi
    fi
    
    log_info "Switching to $target..."
    
    local checkout_output
    local checkout_status=0
    
    # Determine if target is a branch or tag
    if git show-ref --verify --quiet "refs/heads/$target" || git show-ref --verify --quiet "refs/remotes/origin/$target"; then
        # It's a branch - use checkout to track it
        checkout_output=$(git checkout "$target" 2>&1) || checkout_status=$?
    else
        # It's a tag or commit - use checkout with detached HEAD
        checkout_output=$(git checkout "$target" 2>&1) || checkout_status=$?
    fi
    
    if [[ "$checkout_status" -ne 0 ]]; then
        log_error "Failed to switch to $target"
        log_error "Git output: $checkout_output"
        stash_restore_with_retry
        return "$E_GIT_ERROR"
    fi
    
    # Set script permissions (non-critical)
    set_script_permissions
    
    log_success "Successfully switched to $target"
    
    # Restore local changes
    if [[ "$STASH_CREATED" == "true" ]]; then
        stash_restore_with_retry
    fi
    
    # Show new status
    echo
    get_current_version
    if [[ "$IS_DETACHED" == "true" ]]; then
        log_info "You are now viewing version: $CURRENT_VERSION"
        log_info "This is a 'detached HEAD' state - you're viewing a specific release"
        log_info "To switch back to development: use option 9 'Switch to development'"
    else
        log_success "Now on branch: $CURRENT_BRANCH (commit: $CURRENT_VERSION)"
    fi
    
    return 0
}

# Update current version
# Updates the current branch by pulling latest changes from remote
# Only works when on a branch (not in detached HEAD state)
update_current() {
    log_header "Updating Current Version"
    
    get_current_version
    check_local_changes
    
    if [[ "$IS_DETACHED" == "true" ]]; then
        log_error "Cannot update: currently viewing a specific version (detached HEAD state)"
        echo
        log_info "You are viewing a specific release or commit."
        log_info "To get updates, please switch to the development branch first:"
        echo
        echo "  Option 9: Switch to development ($DEFAULT_BRANCH)"
        echo "  Option 3: Switch to different version"
        echo
        return "$E_GENERAL"
    fi
    
    # Strategy: If we have local changes, we'll stash them, pull, then attempt to restore
    # We use manual stash + pull instead of pull --autostash for better error handling
    
    # Backup local changes if present
    if [[ "$HAS_LOCAL_CHANGES" == "true" ]]; then
        if ! create_backup_stash; then
            return "$E_GIT_ERROR"
        fi
    fi
    
    log_info "Updating $CURRENT_BRANCH..."
    
    local pull_output
    local pull_status=0
    
    pull_output=$(git pull origin "$CURRENT_BRANCH" 2>&1) || pull_status=$?
    
    if [[ "$pull_status" -ne 0 ]]; then
        # Check for merge conflicts from the pull itself
        if check_merge_conflicts; then
            log_error "Pull operation failed due to merge conflicts"
            handle_merge_conflicts
            # Don't try to restore stash on top of merge conflicts
            log_info "After resolving merge conflicts, restore your stash manually:"
            log_info "  git stash list              # Find your stash"
            log_info "  git stash apply stash@{N}   # Apply after conflicts are resolved"
            return "$E_MERGE_CONFLICT"
        else
            log_error "Failed to update"
            log_error "Git output: $pull_output"
            stash_restore_with_retry
            return "$E_GIT_ERROR"
        fi
    fi
    
    # Set script permissions (non-critical)
    set_script_permissions
    
    log_success "Successfully updated $CURRENT_BRANCH"
    
    # Restore local changes - this may fail if pulled changes conflict with stashed changes
    if [[ "$STASH_CREATED" == "true" ]]; then
        if ! stash_restore_with_retry; then
            # stash_restore_with_retry already logged detailed information
            # Just add a final summary
            echo
            log_warn "Update completed successfully, but local changes could not be automatically restored"
            log_info "Review the information above to decide how to proceed"
            return 0  # Update succeeded, stash conflict is separate issue
        fi
    fi
    
    return 0
}

# Reset to clean state
# DESTRUCTIVE: Permanently deletes all local changes and untracked files
# Args:
#   $1 - target (commit/tag/branch to reset to)
reset_clean() {
    local target="$1"
    
    log_header "Reset to Clean State"
    
    echo -e "${RED}${BOLD}⚠️  WARNING: DESTRUCTIVE OPERATION  ⚠️${NC}"
    echo
    echo "This will permanently DELETE all local changes!"
    echo
    echo "This operation will:"
    echo "  • Discard ALL uncommitted changes"
    echo "  • Remove ALL untracked files (respecting .gitignore)"
    echo "  • Reset to match: $target"
    echo
    echo -e "${YELLOW}${BOLD}THIS ACTION CANNOT BE UNDONE!${NC}"
    echo
    echo "Type the word 'DELETE' (in capitals) to confirm:"
    read -r confirm
    
    if [[ "$confirm" != "DELETE" ]]; then
        log_info "Operation cancelled (correct confirmation not provided)"
        return "$E_USER_ABORT"
    fi
    
    log_info "Resetting to $target..."
    
    # Reset hard
    local reset_output
    local reset_status=0
    
    reset_output=$(git reset --hard "$target" 2>&1) || reset_status=$?
    
    if [[ "$reset_status" -ne 0 ]]; then
        log_error "Failed to reset repository"
        log_error "Git output: $reset_output"
        return "$E_GIT_ERROR"
    fi
    
    # Clean untracked files
    log_info "Removing untracked files (respecting .gitignore)..."
    local clean_output
    local clean_status=0
    
    clean_output=$(git clean -fd 2>&1) || clean_status=$?
    
    if [[ "$clean_status" -ne 0 ]]; then
        log_warn "Some untracked files could not be removed"
        log_warn "Git output: $clean_output"
    fi
    
    # Set script permissions (non-critical)
    set_script_permissions
    
    log_success "Repository reset to clean state: $target"
    
    # Clear stash flags since we've nuked everything
    STASH_CREATED=false
    CLEANUP_REQUIRED=false
    
    return 0
}

# Show local modifications
show_local_modifications() {
    log_header "Local Modifications"
    
    check_local_changes
    
    if [[ "$HAS_LOCAL_CHANGES" == "false" ]]; then
        log_success "No local modifications detected"
        log_info "Repository is clean and matches the current version"
        return 0
    fi
    
    echo "The following files have local modifications:"
    echo
    
    # Show detailed status
    git status --short 2>/dev/null || log_error "Could not retrieve status"
    
    echo
    echo "Legend:"
    echo "  M  = Modified"
    echo "  A  = Added"
    echo "  D  = Deleted"
    echo "  R  = Renamed"
    echo "  ?? = Untracked"
    echo
    
    # Show diff summary
    echo "Summary of changes:"
    local additions deletions
    additions="$(git diff --numstat 2>/dev/null | awk '{s+=$1} END {print s+0}')"
    deletions="$(git diff --numstat 2>/dev/null | awk '{s+=$2} END {print s+0}')"
    echo "  ${GREEN}+$additions${NC} lines added"
    echo "  ${RED}-$deletions${NC} lines removed"
    echo
    
    log_info "To save these changes:"
    echo "  Option 7: Create backup of changes (stash)"
    echo "  OR: git add <files> && git commit -m 'message'"
    
    return 0
}

# Create manual backup
create_manual_backup() {
    log_header "Create Backup of Changes"
    
    check_local_changes
    
    if [[ "$HAS_LOCAL_CHANGES" == "false" ]]; then
        log_info "No local changes to backup"
        log_info "Repository is clean"
        return 0
    fi
    
    echo "This will save your current changes to a Git stash."
    echo "You can restore it later using 'git stash pop'"
    echo
    
    read -r -p "Continue? [Y/n] " response
    if [[ "$response" =~ ^[Nn]$ ]]; then
        log_info "Operation cancelled"
        return "$E_USER_ABORT"
    fi
    
    local stash_name
    stash_name="manual-backup-$(date +%Y%m%d-%H%M%S)-$$"
    local stash_output
    
    if stash_output=$(git stash push -u -m "$stash_name" 2>&1); then
        log_success "Backup created: $stash_name"
        echo
        echo "To restore this backup later:"
        echo "  git stash list              # Find your backup in the list"
        echo "  git stash apply stash@{N}   # Apply specific backup by number"
        echo "  git stash pop               # Apply and remove most recent backup"
        return 0
    else
        log_error "Failed to create backup"
        log_error "Git output: $stash_output"
        return "$E_GIT_ERROR"
    fi
}

# Switch to latest stable (by date, not version number)
switch_to_latest_stable() {
    log_header "Switch to Latest Stable Release"
    
    local latest_stable
    
    if ! latest_stable=$(get_latest_stable_release); then
        log_error "Could not determine latest stable release"
        log_info "Try running option 2 'List Available Versions' first"
        return "$E_GENERAL"
    fi
    
    log_info "Latest stable release (by date): $latest_stable"
    echo
    switch_version "$latest_stable"
    return $?
}

# Interactive version selection with improved UI
select_version_interactive() {
    log_header "Select Version"
    
    # Fetch latest info
    if ! fetch_updates; then
        log_warn "Could not fetch latest information (continuing with cached data)"
        echo
        read -r -p "Press Enter to continue..."
    fi
    
    # Get available releases sorted by date
    local -a releases
    mapfile -t releases < <(git tag -l 'v*' --sort=-creatordate 2>/dev/null)
    
    echo "Available versions (sorted by release date, newest first):"
    echo
    echo "  ${BOLD}Development:${NC}"
    echo "  0) $DEFAULT_BRANCH - Latest development code (may be unstable)"
    echo
    
    if [[ "${#releases[@]}" -gt 0 ]]; then
        echo "  ${BOLD}Stable Releases:${NC}"
        local index=1
        for release in "${releases[@]}"; do
            local marker=""
            local tag_date
            tag_date="$(git log -1 --format=%ai "$release" 2>/dev/null | cut -d' ' -f1)"
            
            if [[ "$(normalize_version "$CURRENT_VERSION")" == "$(normalize_version "$release")" ]]; then
                marker=" ${GREEN}(current)${NC}"
            fi
            printf "  %2d) %-12s (%s)%s\n" "$index" "$release" "$tag_date" "$marker"
            ((index++))
        done
    else
        log_warn "No release tags available"
    fi
    
    echo
    echo "  q) Cancel"
    echo
    
    local max_choice="${#releases[@]}"
    read -r -p "Select version [0-${max_choice}] or 'q': " choice
    
    if [[ "$choice" == "q" ]] || [[ "$choice" == "Q" ]]; then
        return "$E_USER_ABORT"
    fi
    
    if [[ "$choice" == "0" ]]; then
        switch_version "$DEFAULT_BRANCH"
        return $?
    fi
    
    if [[ "$choice" =~ ^[0-9]+$ ]] && [[ "$choice" -ge 1 ]] && [[ "$choice" -le "${#releases[@]}" ]]; then
        local selected_release="${releases[$((choice-1))]}"
        
        # Verify the tag exists and is reachable
        if ! git rev-parse --verify "refs/tags/$selected_release" &>/dev/null; then
            log_error "Version $selected_release is not available in the repository"
            log_info "Try running 'Fetch Updates' first"
            return "$E_GENERAL"
        fi
        
        switch_version "$selected_release"
        return $?
    fi
    
    log_error "Invalid selection: $choice"
    return "$E_GENERAL"
}

# Show main menu
show_menu() {
    log_header "LyreBirdAudio Version Manager v${VERSION}"
    
    get_current_version
    
    echo -e "Current: ${CYAN}${CURRENT_VERSION}${NC}"
    if [[ "$IS_DETACHED" == "false" ]]; then
        echo -e "Branch:  ${CYAN}${CURRENT_BRANCH}${NC}"
    else
        echo -e "State:   ${YELLOW}Viewing specific version${NC}"
    fi
    echo
    
    echo "Available Actions:"
    echo
    echo "  ${BOLD}Version Management:${NC}"
    echo "    1) Show current status"
    echo "    2) List available versions"
    echo "    3) Switch to different version"
    echo "    4) Update current version (pull latest changes)"
    echo
    echo "  ${BOLD}Maintenance:${NC}"
    echo "    5) Reset to clean state"
    echo "    6) Show local modifications"
    echo "    7) Create backup of changes"
    echo
    echo "  ${BOLD}Quick Actions:${NC}"
    echo "    8) Switch to latest stable release (by date)"
    echo "    9) Switch to development ($DEFAULT_BRANCH)"
    echo
    echo "  ${BOLD}Other:${NC}"
    echo "    h) Show help"
    echo "    q) Quit"
    echo
}

# Show help
show_help() {
    log_header "Help"
    
    cat << 'EOF'
LyreBirdAudio Version Manager

This tool helps you manage different versions of LyreBirdAudio safely.

PREREQUISITES:
  • Git 2.0+ must be installed
  • Bash 4.0+ required
  • Must be run from a git-cloned LyreBirdAudio repository
  • Internet connection required for fetching updates

MENU OPTIONS EXPLAINED:

1. Show current status
   - Displays which version you're currently using
   - Shows if you have any local changes
   - Indicates if updates are available

2. List available versions
   - Shows all released versions sorted by date (newest first)
   - Displays when each version was released
   - Helps you choose which version to use

3. Switch to different version
   - Allows you to select any available version
   - Your local changes will be safely saved (stashed)
   - You can return to development or any other version later

4. Update current version
   - Downloads the latest changes for your current branch
   - Only works when you're on the development branch
   - If you're viewing a specific release, switch to development first

5. Reset to clean state
   - DESTRUCTIVE: Removes all your local changes
   - Returns the repository to an exact version
   - Requires typing 'DELETE' to confirm

6. Show local modifications
   - Lists any files you've changed
   - Shows a summary of additions/deletions
   - Helps decide if you need to backup or commit changes

7. Create backup of changes
   - Saves your current changes without committing them
   - Uses Git stash for safe temporary storage
   - Can be restored later with 'git stash pop'

8. Switch to latest stable release
   - Automatically switches to the newest stable version
   - Uses release date, not version number
   - This ensures you get the most recent release

9. Switch to development
   - Switches to the main development branch
   - Use this to get the bleeding-edge features
   - May contain bugs or incomplete features

UNDERSTANDING GIT TERMS:

Branch:
  A line of development. The 'main' branch is where active development happens.

Tag/Release:
  A specific stable version (like v1.1.0). These are tested and recommended
  for production use.

Detached HEAD:
  When you're viewing a specific version (not following a branch). This is
  normal when viewing a release. To make changes, switch back to a branch.

Stash:
  A temporary storage area for your changes. When you switch versions, your
  changes are "stashed" and can be restored later.

Commit:
  A saved snapshot of your changes. Each commit has a unique ID (hash).

COMMON WORKFLOWS:

To use a stable release:
  1. Run option 8 to switch to latest stable
  OR
  2. Run option 3 and select a specific version

To get the latest development code:
  1. Run option 9 to switch to development branch
  2. Run option 4 to update to latest changes

To test a new release:
  1. Run option 2 to see all versions
  2. Run option 3 to select the new release
  3. Test your configuration
  4. If issues occur, use option 3 to return to a previous version

To backup your changes before experimenting:
  1. Run option 7 to create a backup stash
  2. Make your changes and test
  3. To restore: git stash pop

IMPORTANT NOTES:

- The script ALWAYS saves your changes before switching versions
- To restore saved changes: git stash pop
- All version numbers in releases are tags (v1.0.0, v1.1.0, etc.)
- Latest release BY DATE may not have the highest version number
- This is normal if bug-fix releases are published after newer versions

TROUBLESHOOTING:

"Permission denied" error:
  - Check .git directory permissions: ls -la .git/
  - Fix with: chmod -R u+w .git/
  - Ensure you have write access to the directory

"Not a git repository" error:
  - You must run this script from inside a cloned repository
  - Clone first: git clone https://github.com/tomtom215/LyreBirdAudio.git
  - Then run: cd LyreBirdAudio && ./lyrebird-updater.sh

"Failed to fetch updates" error:
  - Check internet connection
  - Verify GitHub is accessible: git ls-remote origin
  - Try again in a few minutes

"Could not restore local changes" after update:
  - This happens when pulled changes conflict with your local changes
  - Your changes are safely stored in a git stash
  - Options to resolve:
    1. Keep updated versions: git reset --hard HEAD
    2. Manually merge: Edit conflicted files, then git add them
    3. View conflicts: git diff

For more information, visit:
  https://github.com/tomtom215/LyreBirdAudio

EOF
}

# Main menu loop
main_menu() {
    while true; do
        clear
        show_menu
        
        read -r -p "Select option: " choice
        
        case "$choice" in
            1)
                show_status
                read -r -p "Press Enter to continue..."
                ;;
            2)
                list_available_releases
                read -r -p "Press Enter to continue..."
                ;;
            3)
                select_version_interactive
                read -r -p "Press Enter to continue..."
                ;;
            4)
                update_current
                read -r -p "Press Enter to continue..."
                ;;
            5)
                echo
                echo "Reset to which version?"
                echo "  1) Latest commit on current branch"
                echo "  2) origin/$DEFAULT_BRANCH (latest development)"
                echo "  3) Specific version (tag or branch)"
                echo "  4) Cancel"
                echo
                read -r -p "Select [1-4]: " reset_choice
                
                case "$reset_choice" in
                    1)
                        get_current_version
                        if [[ "$IS_DETACHED" == "true" ]]; then
                            log_warn "You are viewing a specific version (detached HEAD)"
                            log_warn "Resetting to HEAD won't change anything"
                            log_info "Recommendation: Use option 2 or 3 instead"
                            read -r -p "Continue anyway? [y/N] " response
                            if [[ ! "$response" =~ ^[Yy]$ ]]; then
                                log_info "Reset cancelled"
                            else
                                reset_clean "HEAD"
                            fi
                        else
                            # Validate remote branch exists before resetting
                            if git show-ref --verify --quiet "refs/remotes/origin/$CURRENT_BRANCH"; then
                                reset_clean "origin/$CURRENT_BRANCH"
                            else
                                log_error "Remote branch origin/$CURRENT_BRANCH does not exist"
                                log_info "Using local HEAD instead"
                                read -r -p "Continue with local HEAD? [y/N] " response
                                if [[ "$response" =~ ^[Yy]$ ]]; then
                                    reset_clean "HEAD"
                                else
                                    log_info "Reset cancelled"
                                fi
                            fi
                        fi
                        ;;
                    2)
                        # Validate default branch exists
                        if git show-ref --verify --quiet "refs/remotes/origin/$DEFAULT_BRANCH"; then
                            reset_clean "origin/$DEFAULT_BRANCH"
                        else
                            log_error "Remote branch origin/$DEFAULT_BRANCH does not exist"
                            log_info "Please fetch updates first or use option 3"
                        fi
                        ;;
                    3)
                        read -r -p "Enter version (e.g., v1.1.0 or $DEFAULT_BRANCH): " version
                        if [[ -z "$version" ]]; then
                            log_error "No version specified"
                        elif ! validate_version_exists "$version"; then
                            log_error "Version '$version' does not exist or is not reachable"
                            log_info "Available options:"
                            log_info "  - Run 'Fetch Updates' first"
                            log_info "  - Use 'List Available Versions' to see valid versions"
                            log_info "  - Check spelling/capitalization"
                        else
                            reset_clean "$version"
                        fi
                        ;;
                    4)
                        log_info "Reset cancelled"
                        ;;
                    *)
                        log_error "Invalid choice"
                        ;;
                esac
                read -r -p "Press Enter to continue..."
                ;;
            6)
                show_local_modifications
                read -r -p "Press Enter to continue..."
                ;;
            7)
                create_manual_backup
                read -r -p "Press Enter to continue..."
                ;;
            8)
                switch_to_latest_stable
                read -r -p "Press Enter to continue..."
                ;;
            9)
                switch_version "$DEFAULT_BRANCH"
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
    fi
    
    # Run interactive menu
    main_menu
    
    exit "$E_SUCCESS"
}

# Run main function
main "$@"
