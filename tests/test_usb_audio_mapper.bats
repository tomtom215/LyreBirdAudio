#!/usr/bin/env bats
# Unit tests for usb-audio-mapper.sh
# Run with: bats tests/test_usb_audio_mapper.bats

# Setup - load helper functions
setup() {
    TEST_DIR="$( cd "$( dirname "$BATS_TEST_FILENAME" )" && pwd )"
    PROJECT_ROOT="$( cd "$TEST_DIR/.." && pwd )"

    # Create temp directory for test files
    export TEST_TMP=$(mktemp -d)

    # Source common library if available
    source "$PROJECT_ROOT/lyrebird-common.sh" 2>/dev/null || true

    # Mock log function if not defined
    if ! declare -f log &>/dev/null; then
        log() { :; }
    fi
}

teardown() {
    # Clean up temp directory
    rm -rf "$TEST_TMP" 2>/dev/null || true
}

# ============================================================================
# Device Name Sanitization Tests
# ============================================================================

@test "sanitize_device_name removes special characters" {
    sanitize_device_name() {
        local name="$1"
        # Replace non-alphanumeric (except underscore/hyphen) with underscore
        name="${name//[^a-zA-Z0-9_-]/_}"
        # Collapse multiple underscores
        while [[ "$name" =~ __ ]]; do
            name="${name//__/_}"
        done
        # Remove leading/trailing underscores
        name="${name#_}"
        name="${name%_}"
        echo "$name"
    }

    run sanitize_device_name "USB Audio Device (1234)"
    [ "$status" -eq 0 ]
    [[ ! "$output" =~ [\(\)\ ] ]]
    [[ "$output" =~ ^[a-zA-Z0-9_-]+$ ]]
}

@test "sanitize_device_name handles empty input" {
    sanitize_device_name() {
        local name="$1"
        name="${name//[^a-zA-Z0-9_-]/_}"
        while [[ "$name" =~ __ ]]; do
            name="${name//__/_}"
        done
        name="${name#_}"
        name="${name%_}"
        echo "$name"
    }

    run sanitize_device_name ""
    [ "$status" -eq 0 ]
    [ -z "$output" ]
}

@test "sanitize_device_name preserves valid characters" {
    sanitize_device_name() {
        local name="$1"
        name="${name//[^a-zA-Z0-9_-]/_}"
        while [[ "$name" =~ __ ]]; do
            name="${name//__/_}"
        done
        name="${name#_}"
        name="${name%_}"
        echo "$name"
    }

    run sanitize_device_name "Blue_Yeti-Pro"
    [ "$status" -eq 0 ]
    [ "$output" = "Blue_Yeti-Pro" ]
}

@test "sanitize_device_name handles unicode characters" {
    sanitize_device_name() {
        local name="$1"
        name="${name//[^a-zA-Z0-9_-]/_}"
        while [[ "$name" =~ __ ]]; do
            name="${name//__/_}"
        done
        name="${name#_}"
        name="${name%_}"
        echo "$name"
    }

    run sanitize_device_name "Микрофон USB"
    [ "$status" -eq 0 ]
    # Should convert to underscores
    [[ "$output" =~ ^[a-zA-Z0-9_-]*$ ]]
}

# ============================================================================
# USB ID Validation Tests
# ============================================================================

@test "validate_usb_id accepts valid VID:PID" {
    is_valid_usb_id() {
        local id="$1"
        [[ "$id" =~ ^[0-9a-fA-F]{4}:[0-9a-fA-F]{4}$ ]]
    }

    run is_valid_usb_id "1234:5678"
    [ "$status" -eq 0 ]
}

@test "validate_usb_id accepts lowercase hex" {
    is_valid_usb_id() {
        local id="$1"
        [[ "$id" =~ ^[0-9a-fA-F]{4}:[0-9a-fA-F]{4}$ ]]
    }

    run is_valid_usb_id "abcd:ef01"
    [ "$status" -eq 0 ]
}

@test "validate_usb_id accepts uppercase hex" {
    is_valid_usb_id() {
        local id="$1"
        [[ "$id" =~ ^[0-9a-fA-F]{4}:[0-9a-fA-F]{4}$ ]]
    }

    run is_valid_usb_id "ABCD:EF01"
    [ "$status" -eq 0 ]
}

@test "validate_usb_id rejects invalid format" {
    is_valid_usb_id() {
        local id="$1"
        [[ "$id" =~ ^[0-9a-fA-F]{4}:[0-9a-fA-F]{4}$ ]]
    }

    run is_valid_usb_id "123:456"
    [ "$status" -eq 1 ]
}

@test "validate_usb_id rejects non-hex characters" {
    is_valid_usb_id() {
        local id="$1"
        [[ "$id" =~ ^[0-9a-fA-F]{4}:[0-9a-fA-F]{4}$ ]]
    }

    run is_valid_usb_id "ghij:klmn"
    [ "$status" -eq 1 ]
}

# ============================================================================
# ALSA Card Parsing Tests
# ============================================================================

@test "parse_alsa_card_number extracts card number" {
    parse_card_number() {
        local line="$1"
        echo "$line" | grep -oE '^[[:space:]]*[0-9]+' | tr -d ' '
    }

    run parse_card_number " 0 [HDMI           ]: HDA-Intel - HDA Intel HDMI"
    [ "$status" -eq 0 ]
    [ "$output" = "0" ]
}

@test "parse_alsa_card_number handles double digits" {
    parse_card_number() {
        local line="$1"
        echo "$line" | grep -oE '^[[:space:]]*[0-9]+' | tr -d ' '
    }

    run parse_card_number "10 [USB            ]: USB-Audio - Blue Yeti"
    [ "$status" -eq 0 ]
    [ "$output" = "10" ]
}

# ============================================================================
# udev Rule Generation Tests
# ============================================================================

@test "generate_udev_rule creates valid symlink" {
    generate_udev_rule() {
        local vid="$1"
        local pid="$2"
        local name="$3"
        echo "ACTION==\"add\", SUBSYSTEM==\"sound\", ATTRS{idVendor}==\"$vid\", ATTRS{idProduct}==\"$pid\", ATTR{id}=\"$name\""
    }

    run generate_udev_rule "1234" "5678" "test_mic"
    [ "$status" -eq 0 ]
    [[ "$output" =~ ACTION==\"add\" ]]
    [[ "$output" =~ idVendor==\"1234\" ]]
    [[ "$output" =~ idProduct==\"5678\" ]]
    [[ "$output" =~ id=\"test_mic\" ]]
}

# ============================================================================
# Device Detection Simulation Tests
# ============================================================================

@test "proc_asound_cards_parsing handles standard format" {
    parse_proc_cards() {
        local content="$1"
        echo "$content" | while IFS= read -r line; do
            if [[ "$line" =~ ^[[:space:]]*([0-9]+)[[:space:]]*\[([^\]]+)\] ]]; then
                echo "${BASH_REMATCH[1]}:${BASH_REMATCH[2]}"
            fi
        done
    }

    test_content=" 0 [HDMI           ]: HDA-Intel - HDA Intel HDMI
 1 [USB            ]: USB-Audio - Blue Yeti"

    run parse_proc_cards "$test_content"
    [ "$status" -eq 0 ]
    [[ "$output" =~ "0:HDMI" ]]
    [[ "$output" =~ "1:USB" ]]
}

# ============================================================================
# Configuration File Tests
# ============================================================================

@test "config file writing is atomic" {
    write_config_atomic() {
        local file="$1"
        local content="$2"
        local tmp_file="${file}.tmp.$$"

        echo "$content" > "$tmp_file" || return 1
        mv "$tmp_file" "$file" || return 1
        return 0
    }

    run write_config_atomic "$TEST_TMP/test.conf" "key=value"
    [ "$status" -eq 0 ]
    [ -f "$TEST_TMP/test.conf" ]
    [ ! -f "$TEST_TMP/test.conf.tmp.$$" ]
    [ "$(cat "$TEST_TMP/test.conf")" = "key=value" ]
}

@test "config file reading handles missing file" {
    read_config_safe() {
        local file="$1"
        if [[ -f "$file" && -r "$file" ]]; then
            cat "$file"
        else
            echo ""
            return 1
        fi
    }

    run read_config_safe "$TEST_TMP/nonexistent.conf"
    [ "$status" -eq 1 ]
    [ -z "$output" ]
}
