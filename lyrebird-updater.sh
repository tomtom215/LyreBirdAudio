#!/bin/bash
# lyrebird-updater.sh - Interactive LyreBirdAudio Version Manager
# Part of LyreBirdAudio - RTSP Audio Streaming Suite
# https://github.com/tomtom215/LyreBirdAudio
#
# This script provides an interactive interface for managing LyreBirdAudio versions,
# handling git operations, and switching between releases safely.
#
# Version: 1.0.0 - Production Ready Release
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
readonly VERSION="1.0.0"

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
    "stream-manager.sh"
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
    if [[ "${BASH_VERSINFO[0]}" -lt "$MIN_BASH_MAJOR" ]]; then
        log_error "This script requires bash ${MIN_BASH_MAJOR}.0 or higher"
        log_error "Current version: ${BASH_VERSION}"
        ((++errors))
    fi
    
    # Check git installation
    if ! command_exists git; then
        log_error "Git is not installed. Please install git first:"
        echo "  Debian/Ubuntu: sudo apt-get install git"
        echo "  RHEL/CentOS:   sudo yum install git"
        echo "  macOS:         brew install git"
        ((++errors))
        return 1
    fi
    
    # Check git version
    local git_version
    git_version=$(git --version 2>/dev/null | grep -oE '[0-9]+\.[0-9]+' | head -1 || echo "0.0")
    local git_major="${git_version%%.*}"
    
    if [[ "$git_major" -lt "$MIN_GIT_MAJOR" ]]; then
        log_error "This script requires git ${MIN_GIT_MAJOR}.0 or higher"
        log_error "Current version: $(git --version 2>/dev/null || echo 'unknown')"
        ((++errors))
    fi
    
    if [[ "$errors" -gt 0 ]]; then
        return "$E_PREREQUISITES"
    fi
    
    return 0
}

# Check if we're in a git repository
check_git_repository() {
    local git_dir
    
    if ! git_dir=$(git rev-parse --git-dir 2>&1); then
        log_error "Not a git repository"
        log_error "Error details: $git_dir"
        echo
        
        # Offer helpful guidance based on the situation
        if [[ -f "lyrebird-updater.sh" ]] || [[ -f "install_mediamtx.sh" ]] || [[ -f "usb-audio-mapper.sh" ]]; then
            log_warn "It looks like you have LyreBirdAudio scripts here, but no git repository."
            echo
            echo "This version manager requires git to function. You have two options:"
            echo
            echo "Option 1: Clone the repository to a new directory (RECOMMENDED)"
            echo "  This keeps your work-in-progress files separate from the managed version."
            echo
            echo "  Steps:"
            echo "    1. Clone the repo: git clone ${REPO_URL} ~/LyreBirdAudio"
            echo "    2. Run this script from there: cd ~/LyreBirdAudio && ./lyrebird-updater.sh"
            echo "    3. Copy any custom changes you need from this directory"
            echo
            echo "Option 2: Initialize git here and connect to remote (ADVANCED)"
            echo "  Warning: This may conflict with your work-in-progress files."
            echo
            echo "  Steps:"
            echo "    1. Backup this directory: cp -r $(pwd) $(pwd).backup"
            echo "    2. Initialize git: git init"
            echo "    3. Add remote: git remote add origin ${REPO_URL}"
            echo "    4. Fetch: git fetch origin"
            echo "    5. Reset to default branch: git reset --hard origin/main (or origin/master)"
            echo "    6. Then run this script again"
            echo
            read -r -p "Would you like help cloning the repository now? [y/N] " response
            if [[ "$response" =~ ^[Yy]$ ]]; then
                # Capture and return the actual result from offer_clone_assistance
                offer_clone_assistance
                local clone_result=$?
                return $clone_result
            fi
        else
            log_error "Please run this script from within the LyreBirdAudio directory"
            log_error "To clone the repository:"
            echo "  git clone ${REPO_URL}"
        fi
        
        return "$E_NOT_GIT_REPO"
    fi
    
    # Verify this is the LyreBirdAudio repository
    local remote_url
    remote_url="$(git config --get remote.origin.url 2>/dev/null || echo "")"
    
    if [[ -z "$remote_url" ]]; then
        log_warn "No remote 'origin' configured"
        log_warn "This repository may not be properly configured"
        echo
        read -r -p "Continue anyway? [y/N] " response
        if [[ ! "$response" =~ ^[Yy]$ ]]; then
            return "$E_USER_ABORT"
        fi
    elif [[ "$remote_url" != *"$REPO_OWNER/$REPO_NAME"* ]]; then
        log_warn "This doesn't appear to be the $REPO_OWNER/$REPO_NAME repository"
        log_warn "Remote URL: $remote_url"
        log_warn "Expected: ${REPO_OWNER}/${REPO_NAME}"
        echo
        read -r -p "Continue anyway? [y/N] " response
        if [[ ! "$response" =~ ^[Yy]$ ]]; then
            return "$E_USER_ABORT"
        fi
    fi
    
    # Check if repository is corrupted
    if ! git rev-parse HEAD &>/dev/null; then
        log_error "Git repository appears to be corrupted"
        log_error "Try: git fsck --full"
        return "$E_GIT_ERROR"
    fi
    
    return 0
}

# Detect the default branch name (main vs master)
get_default_branch() {
    local default_branch
    
    # Try to get the default branch from remote
    default_branch="$(git symbolic-ref refs/remotes/origin/HEAD 2>/dev/null | sed 's@^refs/remotes/origin/@@')"
    
    # If that fails, try common names
    if [[ -z "$default_branch" ]]; then
        if git show-ref --verify --quiet refs/remotes/origin/main; then
            default_branch="main"
        elif git show-ref --verify --quiet refs/remotes/origin/master; then
            default_branch="master"
        else
            # Fallback to local branch
            default_branch="$(git branch --list 'main' 'master' | head -n1 | tr -d ' *')"
        fi
    fi
    
    echo "${default_branch:-main}"  # Updated fallback to 'main'
}

# Normalize version string for comparison (remove 'v' prefix)
normalize_version() {
    local version="$1"
    echo "${version#v}"
}

# Get current version information
get_current_version() {
    CURRENT_VERSION="$(git describe --tags --always 2>/dev/null || echo "unknown")"
    CURRENT_BRANCH="$(git branch --show-current 2>/dev/null || echo "")"
    
    # Check if we're in detached HEAD state
    if [[ -z "$CURRENT_BRANCH" ]]; then
        IS_DETACHED=true
        local head_ref
        head_ref="$(git describe --tags 2>/dev/null || git rev-parse --short HEAD 2>/dev/null || echo "detached")"
        CURRENT_BRANCH="detached HEAD at $head_ref"
    else
        IS_DETACHED=false
    fi
}

# Check for local modifications
check_local_changes() {
    if git diff-index --quiet HEAD -- 2>/dev/null && \
       [[ -z "$(git ls-files --others --exclude-standard 2>/dev/null)" ]]; then
        HAS_LOCAL_CHANGES=false
    else
        HAS_LOCAL_CHANGES=true
    fi
}

# Create backup stash with unique name
# Saves uncommitted changes and untracked files to a git stash
# Uses timestamp and PID to prevent naming collisions
create_backup_stash() {
    if [[ "$HAS_LOCAL_CHANGES" != "true" ]]; then
        return 0
    fi
    
    # Create unique stash name with timestamp and PID to prevent collisions
    LAST_STASH_NAME="lyrebird-updater-backup-$(date +%Y%m%d-%H%M%S)-$$"
    
    log_info "Creating backup of local changes..."
    
    local stash_output
    if stash_output=$(git stash push -u -m "$LAST_STASH_NAME" 2>&1); then
        STASH_CREATED=true
        CLEANUP_REQUIRED=true
        log_success "Backup created: $LAST_STASH_NAME"
        return 0
    else
        log_error "Failed to create backup stash"
        log_error "Git output: $stash_output"
        return "$E_GIT_ERROR"
    fi
}

# Restore from stash
restore_backup_stash() {
    if [[ "$STASH_CREATED" != "true" ]]; then
        return 0
    fi
    
    log_info "Restoring local changes from backup..."
    
    local pop_output
    if pop_output=$(git stash pop 2>&1); then
        log_success "Local changes restored successfully"
        STASH_CREATED=false
        CLEANUP_REQUIRED=false
        return 0
    else
        log_warn "Could not automatically restore local changes"
        log_warn "Git output: $pop_output"
        log_warn "Your changes are still in the stash: $LAST_STASH_NAME"
        log_info "To restore manually:"
        log_info "  git stash list              # Find your stash"
        log_info "  git stash apply stash@{N}   # Apply specific stash"
        return 1
    fi
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

# Fetch latest repository information
fetch_updates() {
    log_info "Fetching latest repository information..."
    
    # Check network first
    if ! check_network_connectivity; then
        log_error "Cannot fetch updates: No network connectivity"
        return "$E_NETWORK_ERROR"
    fi
    
    local fetch_output
    local fetch_status=0
    
    fetch_output=$(git fetch --tags --prune origin 2>&1) || fetch_status=$?
    
    if [[ "$fetch_status" -ne 0 ]]; then
        log_error "Failed to fetch updates from repository"
        log_error "Git output: $fetch_output"
        return "$E_GIT_ERROR"
    fi
    
    log_success "Repository information updated"
    log_debug "Fetch output: $fetch_output"
    return 0
}

# Get latest stable release (dynamically determined)
get_latest_stable_release() {
    local latest
    
    # Get all version tags, sort by version number, exclude pre-releases (those with -)
    latest="$(git tag -l 'v*.*.*' --sort=-v:refname 2>/dev/null | grep -vE '\-?(alpha|beta|rc|pre|dev)' | head -n1)"
    
    if [[ -z "$latest" ]]; then
        # Fallback: try any v* tag
        latest="$(git tag -l 'v*' --sort=-v:refname 2>/dev/null | head -n1)"
    fi
    
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

# List available releases
list_available_releases() {
    log_header "Available Releases"
    
    local tags
    tags="$(git tag -l 'v*' --sort=-v:refname 2>/dev/null || echo "")"
    
    if [[ -n "$tags" ]]; then
        echo "Stable Releases (recommended for production):"
        echo
        
        local count=0
        while IFS= read -r tag; do
            [[ -z "$tag" ]] && continue
            ((++count))
            
            # Get tag date
            local tag_date
            tag_date="$(git log -1 --format=%ai "$tag" 2>/dev/null | cut -d' ' -f1)"
            
            # Check if this is the current version
            local marker=""
            if [[ "$(normalize_version "$CURRENT_VERSION")" == "$(normalize_version "$tag")" ]]; then
                marker=" ${GREEN}(current)${NC}"
            fi
            
            printf "  ${CYAN}%-12s${NC} - %s%s\n" "$tag" "$tag_date" "$marker"
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
    echo -e "  ${YELLOW}${DEFAULT_BRANCH}${NC}      - Latest development (may have bugs)${branch_marker}"
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
        echo -e "  State:    ${YELLOW}Detached HEAD${NC}"
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
    
    # Check if we're behind remote
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
set_script_permissions() {
    log_debug "Setting script permissions..."
    
    local script
    local errors=0
    
    for script in "${REQUIRED_EXECUTABLE_SCRIPTS[@]}"; do
        if [[ -f "$script" ]]; then
            if ! chmod +x "$script" 2>/dev/null; then
                log_warn "Could not set execute permission on: $script"
                ((++errors))
            else
                log_debug "Set executable: $script"
            fi
        else
            log_debug "Script not found (skipping): $script"
        fi
    done
    
    if [[ "$errors" -gt 0 ]]; then
        log_warn "Failed to set permissions on $errors script(s)"
        return 1
    fi
    
    return 0
}

# Validate that a version/tag/branch exists
validate_version_exists() {
    local target="$1"
    
    # Check if it's a local branch
    if git show-ref --verify --quiet "refs/heads/$target"; then
        return 0
    fi
    
    # Check if it's a remote branch
    if git show-ref --verify --quiet "refs/remotes/origin/$target"; then
        return 0
    fi
    
    # Check if it's a tag
    if git show-ref --verify --quiet "refs/tags/$target"; then
        return 0
    fi
    
    # Try to resolve as a commit hash
    if git rev-parse --verify --quiet "$target^{commit}" >/dev/null 2>&1; then
        return 0
    fi
    
    return 1
}

# Switch to version (tag or branch)
# Workflow:
#   1. Verify target exists (tag or branch)
#   2. Handle local changes (backup or discard with user confirmation)
#   3. Perform git checkout to target version
#   4. If branch: pull latest changes from remote
#   5. Set executable permissions on required scripts
#   6. Offer to restore backed-up changes
# Args:
#   $1 - target_version (tag name or branch name)
switch_version() {
    local target_version="$1"
    local is_branch=false
    
    log_header "Switching to $target_version"
    
    # Verify target exists
    if git show-ref --verify --quiet "refs/heads/$target_version"; then
        is_branch=true
        log_debug "Target is a local branch: $target_version"
    elif git show-ref --verify --quiet "refs/remotes/origin/$target_version"; then
        is_branch=true
        log_debug "Target is a remote branch: $target_version"
    elif git show-ref --verify --quiet "refs/tags/$target_version"; then
        is_branch=false
        log_debug "Target is a tag: $target_version"
    else
        log_error "Unknown or unreachable version: $target_version"
        log_info "Run 'Fetch Updates' first, or check the version name"
        return "$E_GENERAL"
    fi
    
    # Check for local changes
    check_local_changes
    
    if [[ "$HAS_LOCAL_CHANGES" == "true" ]]; then
        log_warn "You have local modifications"
        echo
        git status --short 2>/dev/null || echo "(unable to show status)"
        echo
        echo "Options:"
        echo "  1) Backup and continue (saves changes, switches version)"
        echo "  2) Discard and continue (loses changes, switches version)"
        echo "  3) Cancel"
        echo
        read -r -p "Choose option [1-3]: " choice
        
        case "$choice" in
            1)
                if ! create_backup_stash; then
                    return "$E_GIT_ERROR"
                fi
                ;;
            2)
                log_warn "Discarding local changes..."
                local reset_output
                if ! reset_output=$(git reset --hard HEAD 2>&1); then
                    log_error "Failed to discard changes"
                    log_error "Git output: $reset_output"
                    return "$E_GIT_ERROR"
                fi
                ;;
            3)
                log_info "Operation cancelled"
                return "$E_USER_ABORT"
                ;;
            *)
                log_error "Invalid choice"
                return "$E_GENERAL"
                ;;
        esac
    fi
    
    # Perform the switch
    log_info "Switching to $target_version..."
    
    local checkout_output
    local checkout_status=0
    
    checkout_output=$(git checkout "$target_version" 2>&1) || checkout_status=$?
    
    if [[ "$checkout_status" -ne 0 ]]; then
        log_error "Failed to switch to $target_version"
        log_error "Git output: $checkout_output"
        restore_backup_stash
        return "$E_GIT_ERROR"
    fi
    
    if [[ "$is_branch" == "true" ]]; then
        # Pull latest changes for branch
        log_info "Pulling latest changes..."
        
        local pull_output
        local pull_status=0
        
        pull_output=$(git pull origin "$target_version" 2>&1) || pull_status=$?
        
        if [[ "$pull_status" -ne 0 ]]; then
            # Check for merge conflicts
            if check_merge_conflicts; then
                handle_merge_conflicts
                restore_backup_stash
                return "$E_MERGE_CONFLICT"
            else
                log_warn "Pull operation had issues but no conflicts detected"
                log_warn "Git output: $pull_output"
                log_warn "Continuing with current state..."
            fi
        fi
    fi
    
    # Set script permissions
    set_script_permissions
    
    log_success "Successfully switched to $target_version"
    
    # Optionally restore local changes
    if [[ "$STASH_CREATED" == "true" ]]; then
        echo
        read -r -p "Restore your backed-up changes? [y/N] " response
        if [[ "$response" =~ ^[Yy]$ ]]; then
            restore_backup_stash
        else
            log_info "Your changes remain in stash: $LAST_STASH_NAME"
            log_info "Use 'git stash list' to see them"
            log_info "Use 'git stash pop' to restore them later"
            # User explicitly chose to keep stash - mark as user-managed
            CLEANUP_REQUIRED=false
            STASH_CREATED=false
        fi
    fi
    
    # Show new status
    echo
    get_current_version
    log_success "Now on: $CURRENT_VERSION"
    
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
        log_error "Cannot update: currently in detached HEAD state"
        log_info "A detached HEAD means you're viewing a specific commit or tag"
        log_info "Please switch to a branch first:"
        log_info "  - Use option 3 to switch to '$DEFAULT_BRANCH' or a specific version"
        log_info "  - Or use option 9 for quick switch to development branch"
        return "$E_GENERAL"
    fi
    
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
        # Check for merge conflicts
        if check_merge_conflicts; then
            handle_merge_conflicts
            restore_backup_stash
            return "$E_MERGE_CONFLICT"
        else
            log_error "Failed to update"
            log_error "Git output: $pull_output"
            restore_backup_stash
            return "$E_GIT_ERROR"
        fi
    fi
    
    set_script_permissions
    
    log_success "Successfully updated $CURRENT_BRANCH"
    
    # Restore local changes
    if [[ "$STASH_CREATED" == "true" ]]; then
        restore_backup_stash
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
    
    # Clean untracked files (BUG FIX: Removed -x flag to respect .gitignore)
    log_info "Removing untracked files (respecting .gitignore)..."
    local clean_output
    local clean_status=0
    
    clean_output=$(git clean -fd 2>&1) || clean_status=$?
    
    if [[ "$clean_status" -ne 0 ]]; then
        log_warn "Some untracked files could not be removed"
        log_warn "Git output: $clean_output"
    fi
    
    set_script_permissions
    
    log_success "Repository reset to clean state: $target"
    
    # Clear stash flags since we've nuked everything
    STASH_CREATED=false
    CLEANUP_REQUIRED=false
    
    return 0
}

# Interactive version selection
select_version_interactive() {
    log_header "Select Version"
    
    # Fetch latest info
    if ! fetch_updates; then
        log_warn "Could not fetch latest information (continuing with cached data)"
        echo
        read -r -p "Press Enter to continue..."
    fi
    
    # Get available releases
    local -a releases
    mapfile -t releases < <(git tag -l 'v*' --sort=-v:refname 2>/dev/null)
    
    echo "Available versions:"
    echo
    echo "  0) $DEFAULT_BRANCH (development branch)"
    echo
    
    if [[ "${#releases[@]}" -gt 0 ]]; then
        local index=1
        for release in "${releases[@]}"; do
            local marker=""
            if [[ "$(normalize_version "$CURRENT_VERSION")" == "$(normalize_version "$release")" ]]; then
                marker=" ${GREEN}(current)${NC}"
            fi
            printf "  %d) %s%s\n" "$index" "$release" "$marker"
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
    fi
    echo
    
    echo "Available Actions:"
    echo
    echo "  ${BOLD}Version Management:${NC}"
    echo "    1) Show current status"
    echo "    2) List available versions"
    echo "    3) Switch to different version"
    echo "    4) Update current version"
    echo
    echo "  ${BOLD}Maintenance:${NC}"
    echo "    5) Reset to clean state"
    echo "    6) Show local modifications"
    echo "    7) Create backup of changes"
    echo
    echo "  ${BOLD}Quick Actions:${NC}"
    echo "    8) Switch to latest stable release"
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

TERMINOLOGY:
  • Release/Tag: Stable version (e.g., v1.1.0, v1.0.1)
  • Branch: Development line (e.g., main, master)
  • Local Changes: Modifications you've made to files
  • Stash: Temporary backup of your changes
  • Detached HEAD: Viewing a specific version without being on a branch
  • Merge Conflict: Git cannot automatically merge changes

COMMON WORKFLOWS:

1. Update to latest stable release:
   - Select option 8: "Switch to latest stable release"
   - Or: List versions → Select newest release
   - The script automatically finds the latest version

2. Try development version:
   - Select option 9: "Switch to development branch"
   - Warning: Development branch may contain bugs

3. Go back to stable after testing:
   - Select option 3: "Switch to different version"
   - Choose a release version (e.g., v1.1.0)

4. Update your current version:
   - Select option 4: "Update current version"
   - Only works when on a branch (not detached HEAD)

5. Fix broken installation:
   - Select option 5: "Reset to clean state"
   - Choose which version to reset to
   - Warning: Loses ALL local changes permanently!

6. Save work before switching:
   - Select option 7: "Create backup of changes"
   - Then switch versions safely
   - Your changes are saved in a git stash

SAFETY FEATURES:
  • Automatically backs up local changes when switching versions
  • Warns before destructive operations with explicit confirmations
  • Validates all operations before executing
  • Provides clear status information and error messages
  • Handles merge conflicts with clear resolution instructions
  • Protects against network failures and git errors
  • Graceful signal handling (Ctrl+C safe)
  • Respects .gitignore when cleaning files

COMMAND LINE OPTIONS:
  --version, -v     Show version information
  --status, -s      Show current status (non-interactive)
  --list, -l        List available versions (non-interactive)
  --help, -h        Show this help text

TROUBLESHOOTING:

If you're not in a git repository:
  • The script requires a git-cloned LyreBirdAudio directory
  • If you have scripts locally without git:
    1. Run the script and choose "yes" when offered clone assistance
    2. Or manually clone: git clone https://github.com/tomtom215/LyreBirdAudio
    3. Keep your work-in-progress files separate
  • The script will detect this and offer to help

If you encounter merge conflicts:
  • The script will detect and warn you
  • Follow the on-screen instructions to resolve
  • Common resolution: Use option 5 to reset to clean state

If network operations fail:
  • Check your internet connection
  • Verify GitHub is accessible: ping github.com
  • Try again after network is restored

If the script reports repository corruption:
  • Run: git fsck --full
  • Consider re-cloning if corruption is severe

For more information, visit:
https://github.com/tomtom215/LyreBirdAudio

EOF
}

# Show local modifications
show_local_modifications() {
    log_header "Local Modifications"
    
    check_local_changes
    
    if [[ "$HAS_LOCAL_CHANGES" == "false" ]]; then
        log_success "No local modifications detected"
        return 0
    fi
    
    echo "Modified and untracked files:"
    git status --short 2>/dev/null || echo "(unable to show status)"
    echo
    
    echo "Summary of changes:"
    git diff --stat 2>/dev/null || echo "(unable to show diff summary)"
    echo
    
    read -r -p "Show detailed changes? [y/N] " response
    if [[ "$response" =~ ^[Yy]$ ]]; then
        echo "Viewing detailed changes... (Press 'q' to quit, arrow keys to scroll)"
        git diff 2>/dev/null | less -FRX || echo "(unable to show detailed diff)"
    fi
}

# Create manual backup
create_manual_backup() {
    log_header "Create Backup"
    
    check_local_changes
    
    if [[ "$HAS_LOCAL_CHANGES" == "false" ]]; then
        log_info "No local changes to backup"
        return 0
    fi
    
    echo "This will create a backup of your current changes."
    echo "The backup is stored as a git stash."
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

# Switch to latest stable (dynamic)
switch_to_latest_stable() {
    local latest_stable
    
    if ! latest_stable=$(get_latest_stable_release); then
        log_error "Could not determine latest stable release"
        log_info "Try running 'List Available Versions' first"
        return "$E_GENERAL"
    fi
    
    log_info "Latest stable release: $latest_stable"
    switch_version "$latest_stable"
    return $?
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
                        # BUG FIX: Improved logic for detached HEAD and remote branch validation
                        get_current_version
                        if [[ "$IS_DETACHED" == "true" ]]; then
                            log_warn "You are in detached HEAD state"
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
                        # BUG FIX: Validate version BEFORE asking for DELETE confirmation
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
