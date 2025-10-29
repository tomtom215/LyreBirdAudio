#!/bin/bash
# apply_orchestrator_fix.sh - Fix the active streams detection bug
# Run as: sudo bash apply_orchestrator_fix.sh /path/to/LyreBirdAudio

set -euo pipefail

if [[ $EUID -ne 0 ]]; then
    echo "ERROR: This script must be run as root"
    exit 1
fi

LYREBIRD_DIR="${1:-.}"
ORCHESTRATOR="${LYREBIRD_DIR}/lyrebird-orchestrator.sh"

if [[ ! -f "$ORCHESTRATOR" ]]; then
    echo "ERROR: Cannot find lyrebird-orchestrator.sh at: $ORCHESTRATOR"
    echo "Usage: sudo bash apply_orchestrator_fix.sh /path/to/LyreBirdAudio"
    exit 1
fi

echo "Found orchestrator at: $ORCHESTRATOR"
echo "Creating backup..."

# Create backup
BACKUP="${ORCHESTRATOR}.backup.$(date +%Y%m%d_%H%M%S)"
cp "$ORCHESTRATOR" "$BACKUP"
echo "Backup created: $BACKUP"

# Apply fix
echo "Applying fix..."

# Use sed to find and replace the detect_active_streams function
# This is the safe version that handles newlines properly
sed -i.tmp '/^detect_active_streams() {/,/^}/ {
    # Start of function - keep it
    /^detect_active_streams() {/ b
    # End of function - keep it  
    /^}/ b
    # Delete everything between
    d
}' "$ORCHESTRATOR"

# Now insert the fixed function after the function declaration
sed -i.tmp '/^detect_active_streams() {/a\
    ACTIVE_STREAMS=0\
    \
    # Count FFmpeg processes streaming to MediaMTX\
    if command_exists pgrep; then\
        local count\
        count=$(pgrep -fc "ffmpeg.*rtsp://.*:8554" 2>/dev/null || echo "0")\
        # Remove any whitespace/newlines and ensure it'"'"'s a valid number\
        count=$(echo "$count" | tr -d '"'"'\\n\\r\\t '"'"' | xargs)\
        # Validate it'"'"'s a number before assignment\
        if [[ "$count" =~ ^[0-9]+$ ]]; then\
            ACTIVE_STREAMS=$count\
        else\
            ACTIVE_STREAMS=0\
        fi\
    fi\
    \
    log DEBUG "Active streams=$ACTIVE_STREAMS"' "$ORCHESTRATOR"

# Clean up temp file
rm -f "${ORCHESTRATOR}.tmp"

# Verify the fix was applied
if grep -q 'Validate it.*s a number before assignment' "$ORCHESTRATOR"; then
    echo "✓ Fix applied successfully!"
    echo
    echo "The detect_active_streams() function has been updated to:"
    echo "  1. Use a local variable to avoid contamination"
    echo "  2. Remove all whitespace characters (newlines, tabs, spaces)"
    echo "  3. Validate the result is a number before assignment"
    echo
    echo "You can now run the orchestrator without the syntax error."
    echo
    echo "If you need to revert, use the backup:"
    echo "  sudo cp $BACKUP $ORCHESTRATOR"
else
    echo "✗ Fix may not have been applied correctly"
    echo "Restoring backup..."
    cp "$BACKUP" "$ORCHESTRATOR"
    echo "Please apply the fix manually by editing: $ORCHESTRATOR"
    echo
    echo "Find the detect_active_streams() function and replace it with:"
    echo '─────────────────────────────────────────────────────────'
    cat << 'EOF'
detect_active_streams() {
    ACTIVE_STREAMS=0
    
    # Count FFmpeg processes streaming to MediaMTX
    if command_exists pgrep; then
        local count
        count=$(pgrep -fc "ffmpeg.*rtsp://.*:8554" 2>/dev/null || echo "0")
        # Remove any whitespace/newlines and ensure it's a valid number
        count=$(echo "$count" | tr -d '\n\r\t ' | xargs)
        # Validate it's a number before assignment
        if [[ "$count" =~ ^[0-9]+$ ]]; then
            ACTIVE_STREAMS=$count
        else
            ACTIVE_STREAMS=0
        fi
    fi
    
    log DEBUG "Active streams=$ACTIVE_STREAMS"
}
EOF
    echo '─────────────────────────────────────────────────────────'
    exit 1
fi
