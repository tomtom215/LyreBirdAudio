#!/usr/bin/env bats
# Mechanical checks that documentation claims match behaviour verified against
# the real software (see docs/REMEDIATION-2026-11.md). Each test names the
# claim it pins so a future edit cannot silently reintroduce a verified-wrong
# example.

setup() {
    ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
    GUIDE="$ROOT/docs/SECURITY-GUIDE.md"
}

@test "SECURITY-GUIDE never uses shell-style interpolation in a MediaMTX pass line" {
    # MediaMTX does not expand ${VAR} in its YAML; the literal text becomes the password.
    run grep -nE '^[[:space:]]*pass:[[:space:]]*["'\'']?\$\{' "$GUIDE"
    [ "$status" -eq 1 ] || { echo "$output"; return 1; }
}

@test "SECURITY-GUIDE regular-expression paths carry MediaMTX's ~ prefix" {
    # Without '~' the value is a literal path name, so a '^…$' pattern matches nothing.
    run grep -nE '^[[:space:]]*path:[[:space:]]*["'\'']\^' "$GUIDE"
    [ "$status" -eq 1 ] || { echo "$output"; return 1; }
    grep -qE "path:[[:space:]]*'~\^" "$GUIDE"
}

@test "SECURITY-GUIDE authentication example keeps a loopback-only password-less local user" {
    # The suite's own publishers and health checks connect to localhost without
    # credentials; an authInternalUsers list without this user breaks them.
    grep -qF "ips: ['127.0.0.1', '::1']" "$GUIDE"
    grep -qE '^[[:space:]]*-[[:space:]]*user:[[:space:]]*any$' "$GUIDE"
}

@test "SECURITY-GUIDE documents the MTX_ environment override instead of YAML interpolation" {
    grep -qF 'MTX_AUTHINTERNALUSERS_1_PASS' "$GUIDE"
}

@test "SECURITY-GUIDE does not call WebRTC open by default or the API localhost-only by bind scope" {
    run grep -nE '^\|[[:space:]]*WebRTC[[:space:]]*\|' "$GUIDE"
    [ "$status" -eq 1 ] || { echo "$output"; return 1; }
    run grep -nE '^\|[[:space:]]*RTSP API[[:space:]]*\|.*Localhost only' "$GUIDE"
    [ "$status" -eq 1 ] || { echo "$output"; return 1; }
}
