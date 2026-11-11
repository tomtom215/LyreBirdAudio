#!/usr/bin/env bash
# Download checksum-verified MediaMTX releases for the live tests and print the
# binary paths (space-separated), for LYREBIRD_TEST_MEDIAMTX_BINS.
#
# Usage: tests/fetch_mediamtx.sh [CACHE_DIR] [VERSION...]
#   CACHE_DIR defaults to .cache/mediamtx; VERSION defaults to every pinned one.
#   VERSION may be "latest": the newest stable upstream release, resolved at
#   run time and verified against the checksums.sha256 asset of that same
#   release (see below). It is never part of the default set.
# Example:
#   LYREBIRD_TEST_MEDIAMTX_BINS="$(tests/fetch_mediamtx.sh)" bats tests/test_mediamtx_live.bats
#
# Pins are the sha256 values from each release's checksums.sha256 for
# linux_amd64, each confirmed by hashing the downloaded tarball. 1.15.0 is the
# oldest supported release, 1.18.0 the last one without MoQ, 1.19.0 the first
# with it, 1.21.3 the newest at the time of writing (git ls-remote --tags,
# 2026-11-11).
#
# "latest" is for the advisory canary job only. The release's own checksum file
# proves the tarball was not corrupted or swapped in transit; it cannot prove
# the release itself is trustworthy, which is why the blocking matrix uses the
# reviewed pins above. If "latest" resolves to a pinned version, the pin wins
# and the checksum file must agree with it.
#
# The newest release is the highest vX.Y.Z tag (pre-release tags are ignored),
# found with git ls-remote: no API token or rate limit is involved.
#
# Environment (used by tests/test_ci_config.bats to run against a local tree):
#   LYREBIRD_MEDIAMTX_RELEASES_URL  default https://github.com/bluenviron/mediamtx/releases
#   LYREBIRD_MEDIAMTX_GIT_URL       default https://github.com/bluenviron/mediamtx.git

set -euo pipefail

declare -A SHA256=(
    ["v1.15.0"]=bf438ba8bf56edf009255bcef4001cea1ad4db861ac02f25173330f303b7331b
    ["v1.18.0"]=1d7f853340a9fbd73605a4e828f302c63b6696ebb40b9b7a227cdc035473d108
    ["v1.19.0"]=ee900a73d78919a44f995e04d65588f1cea10ddb43ebf1c740f2c6c4fa0c29b0
    ["v1.21.1"]=653abc672a3e693f8d3b2717752492fdcfb8072291ec108d03d3dd857411b0ee
    ["v1.21.2"]=121be6e00397e473a95d83c75f4fcd3819a6af3b0e1a50889cba43ab4fab6a27
    ["v1.21.3"]=0a2ea7eba96023631efa1bea7804823a9145b043b6646a8a05798d4ac24ed635
)

releases_url="${LYREBIRD_MEDIAMTX_RELEASES_URL:-https://github.com/bluenviron/mediamtx/releases}"
git_url="${LYREBIRD_MEDIAMTX_GIT_URL:-https://github.com/bluenviron/mediamtx.git}"

die() {
    echo "fetch_mediamtx.sh: $*" >&2
    exit "${2:-1}"
}

if [[ "$(uname -s)/$(uname -m)" != Linux/x86_64 ]]; then
    die "pins are for linux amd64 only" 2
fi

# Print the newest stable vX.Y.Z tag of the upstream repository.
latest_tag() {
    local refs tag
    refs="$(git ls-remote --tags --refs "$git_url" 'v*')" || return 1
    tag="$(sed -n 's#^[0-9a-f]*[[:space:]]*refs/tags/\(v[0-9][0-9]*\.[0-9][0-9]*\.[0-9][0-9]*\)$#\1#p' <<<"$refs" | sort -V | tail -n 1)"
    [[ -n "$tag" ]] || return 1
    printf '%s\n' "$tag"
}

# Print the sha256 that release $1's checksums.sha256 lists for its linux
# amd64 tarball. Fails unless exactly one well-formed line names it.
release_checksum() {
    local tag="$1" file sums
    local -a found
    file="mediamtx_${tag}_linux_amd64.tar.gz"
    sums="$(curl -sSfL --retry 3 "$releases_url/download/$tag/checksums.sha256")" || return 1
    # Lines look like "<64 hex> *<file>" (binary-mode marker) or "<64 hex>  <file>".
    mapfile -t found < <(awk -v f="$file" '$2 == f || $2 == "*" f { print $1 }' <<<"$sums")
    [[ ${#found[@]} -eq 1 && "${found[0]}" =~ ^[0-9a-f]{64}$ ]] || return 1
    printf '%s\n' "${found[0]}"
}

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
    if [[ "$v" == latest ]]; then
        v="$(latest_tag)" || die "cannot determine the latest upstream release from $git_url"
        echo "fetch_mediamtx.sh: latest upstream release is $v" >&2
        sum="$(release_checksum "$v")" || die "no usable linux amd64 entry in the checksums.sha256 of $v"
        if [[ -n "${SHA256[$v]:-}" && "${SHA256[$v]}" != "$sum" ]]; then
            die "the checksums.sha256 of $v disagrees with the pinned value: refusing it"
        fi
    else
        sum="${SHA256[$v]:-}"
        [[ -n "$sum" ]] || die "no pin for $v" 2
    fi
    tarball="$cache/mediamtx_${v}_linux_amd64.tar.gz"
    if [[ ! -x "$cache/$v/mediamtx" ]]; then
        curl -sSfL --retry 3 -o "$tarball.part" \
            "$releases_url/download/$v/mediamtx_${v}_linux_amd64.tar.gz"
        if [[ "$(sha256sum "$tarball.part" | cut -d' ' -f1)" != "$sum" ]]; then
            rm -f "$tarball.part"
            die "checksum mismatch for $v"
        fi
        mv "$tarball.part" "$tarball"
        mkdir -p "$cache/$v"
        tar -xzf "$tarball" -C "$cache/$v" mediamtx
    fi
    bins+=("$(cd "$cache/$v" && pwd)/mediamtx")
done
printf '%s\n' "${bins[*]}"
