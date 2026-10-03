#!/usr/bin/env bash
# Download checksum-pinned MediaMTX releases for the live tests and print the
# binary paths (space-separated), for LYREBIRD_TEST_MEDIAMTX_BINS.
#
# Usage: tests/fetch_mediamtx.sh [CACHE_DIR] [VERSION...]
#   CACHE_DIR defaults to .cache/mediamtx; VERSION defaults to every pinned one.
# Example:
#   LYREBIRD_TEST_MEDIAMTX_BINS="$(tests/fetch_mediamtx.sh)" bats tests/test_mediamtx_live.bats
#
# Pins are the sha256 values from each release's checksums.sha256 for
# linux_amd64. 1.15.0 is the oldest supported release, 1.18.0 the last one
# without MoQ, 1.19.0 the first with it, 1.21.1 the newest at the time of
# writing (git ls-remote --tags, 2026-10-03).

set -euo pipefail

declare -A SHA256=(
    [v1.15.0]=bf438ba8bf56edf009255bcef4001cea1ad4db861ac02f25173330f303b7331b
    [v1.18.0]=1d7f853340a9fbd73605a4e828f302c63b6696ebb40b9b7a227cdc035473d108
    [v1.19.0]=ee900a73d78919a44f995e04d65588f1cea10ddb43ebf1c740f2c6c4fa0c29b0
    [v1.21.1]=653abc672a3e693f8d3b2717752492fdcfb8072291ec108d03d3dd857411b0ee
)

if [[ "$(uname -s)/$(uname -m)" != Linux/x86_64 ]]; then
    echo "fetch_mediamtx.sh: pins are for linux amd64 only" >&2
    exit 2
fi

cache="${1:-.cache/mediamtx}"
shift || true
if (($#)); then
    versions=("$@")
else
    mapfile -t versions < <(printf '%s\n' "${!SHA256[@]}" | sort -V)
fi

mkdir -p "$cache"
bins=()
for v in "${versions[@]}"; do
    sum="${SHA256[$v]:-}"
    [[ -n "$sum" ]] || {
        echo "fetch_mediamtx.sh: no pin for $v" >&2
        exit 2
    }
    tarball="$cache/mediamtx_${v}_linux_amd64.tar.gz"
    if [[ ! -x "$cache/$v/mediamtx" ]]; then
        curl -sSfL --retry 3 -o "$tarball.part" \
            "https://github.com/bluenviron/mediamtx/releases/download/$v/mediamtx_${v}_linux_amd64.tar.gz"
        if [[ "$(sha256sum "$tarball.part" | cut -d' ' -f1)" != "$sum" ]]; then
            rm -f "$tarball.part"
            echo "fetch_mediamtx.sh: checksum mismatch for $v" >&2
            exit 1
        fi
        mv "$tarball.part" "$tarball"
        mkdir -p "$cache/$v"
        tar -xzf "$tarball" -C "$cache/$v" mediamtx
    fi
    bins+=("$(cd "$cache/$v" && pwd)/mediamtx")
done
printf '%s\n' "${bins[*]}"
