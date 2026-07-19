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

@test "generate_udev_rules emits an active (non-comment) udev rule [C1 regression]" {
    # Exercises the REAL function, not a local mock. The historical bug stored a
    # literal "\n" in a double-quoted string and printed it with printf '%s', so
    # the comment and the rule collapsed onto one '#'-prefixed line and udev
    # ignored the entire rule -- USB persistent naming silently never worked.
    run env PROJECT_ROOT="$PROJECT_ROOT" bash -c '
        set +euo pipefail
        source "$PROJECT_ROOT/usb-audio-mapper.sh" >/dev/null 2>&1
        generate_udev_rules "0d8c" "0014" "test-mic" "Blue Yeti" "1-1.4" ""
    '
    [ "$status" -eq 0 ]
    # At least one ACTIVE (non-#) line must exist; the bug produced zero.
    [ "$(printf '%s\n' "$output" | grep -vc '^[[:space:]]*#')" -ge 1 ]
    # It is a real udev rule that applies the persistent id.
    printf '%s\n' "$output" | grep -qE '^SUBSYSTEM=="sound".*ATTR\{id\}="test-mic"'
    # No stray literal backslash-n survived into the output.
    [[ "$output" != *'\n'* ]]
}

@test "generate_udev_rules strips injection from the card name [H7 regression]" {
    # A card name carrying a newline + RUN+= must not yield an active udev
    # directive other than the intended SUBSYSTEM rule. The old tr set
    # '[:alnum:] \t-_.' was read as the range 0x09-0x5F and let newlines through.
    run env PROJECT_ROOT="$PROJECT_ROOT" bash -c '
        set +euo pipefail
        source "$PROJECT_ROOT/usb-audio-mapper.sh" >/dev/null 2>&1
        evil=$(printf "pwned\nRUN+=\"/bin/sh -c evilcmd\"")
        generate_udev_rules "0d8c" "0014" "good-mic" "$evil" "1-1.4" ""
    '
    [ "$status" -eq 0 ]
    # No RUN/PROGRAM/IMPORT directive anywhere in the output.
    ! printf '%s\n' "$output" | grep -qE "RUN[+]=|PROGRAM==|IMPORT[{]"
    # Exactly one active (non-comment) line: the intended rule.
    [ "$(printf '%s\n' "$output" | grep -vc '^[[:space:]]*#')" -eq 1 ]
}

@test "is_valid_usb_path accepts real ports, rejects injection/synthetic/junk [USB-1/USB-2 regression]" {
    run env PROJECT_ROOT="$PROJECT_ROOT" bash -c '
        set +euo pipefail
        source "$PROJECT_ROOT/usb-audio-mapper.sh" >/dev/null 2>&1
        for good in "1-2" "1-2.3" "usb-1-2.3.4" "3-1.4.2"; do
            is_valid_usb_path "$good" || { echo "REJECTED-GOOD:$good"; exit 1; }
        done
        evil=$(printf "1-2\" GOTO=\"end\nACTION==\"add\", RUN+=\"/bin/rm -rf /\"\nLABEL=\"end")
        for bad in "$evil" "bus3-dev5" "a-b" "1-2;rm" "../etc" "1_2" ""; do
            if is_valid_usb_path "$bad"; then echo "ACCEPTED-BAD:[$bad]"; exit 1; fi
        done
        echo ALLGOOD
    '
    [ "$status" -eq 0 ]
    [[ "$output" == *ALLGOOD* ]]
}

@test "generate_udev_rules rejects an injection-laden port (no KERNELS/RUN) [USB-1 regression]" {
    # An operator-supplied -u value with an embedded newline + RUN+= must not be
    # spliced into a KERNELS== match; the rule falls back to VID:PID only.
    run env PROJECT_ROOT="$PROJECT_ROOT" bash -c '
        set +euo pipefail
        source "$PROJECT_ROOT/usb-audio-mapper.sh" >/dev/null 2>&1
        evilport=$(printf "1-2\" GOTO=\"end\nACTION==\"add\", RUN+=\"/bin/sh -c evil\"\nLABEL=\"end")
        generate_udev_rules "0d8c" "0014" "mic" "Card" "$evilport" "" 2>/dev/null
    '
    [ "$status" -eq 0 ]
    ! printf '%s\n' "$output" | grep -qE "RUN[+]=|PROGRAM==|IMPORT[{]|GOTO"
    ! printf '%s\n' "$output" | grep -q "KERNELS"
    # Exactly one active line: the VID:PID-only fallback rule.
    [ "$(printf '%s\n' "$output" | grep -vc '^[[:space:]]*#')" -eq 1 ]
}

@test "generate_udev_rules omits a dead KERNELS for the synthetic bus-dev fallback [USB-2 regression]" {
    run env PROJECT_ROOT="$PROJECT_ROOT" bash -c '
        set +euo pipefail
        source "$PROJECT_ROOT/usb-audio-mapper.sh" >/dev/null 2>&1
        generate_udev_rules "0d8c" "0014" "mic" "Card" "bus3-dev5" "" 2>/dev/null
    '
    [ "$status" -eq 0 ]
    # A KERNELS=="bus3-dev5" rule would never match any real device.
    ! printf '%s\n' "$output" | grep -q 'KERNELS'
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
