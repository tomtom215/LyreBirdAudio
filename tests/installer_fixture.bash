# shellcheck shell=bash
# A local stand-in for GitHub's release downloads, so that tests can run the
# real install_mediamtx.sh download, checksum, extract and install code without a
# network. The installer's own download_file (curl, retries) is the only function
# replaced; get_release_info, download_mediamtx, verify_checksum, the extraction
# and the atomic replacement are the real ones.
#
# Usage (in a test):
#   installer_release_fixture "$FIXTURE_DIR" v1.21.1 /path/to/a/mediamtx/binary
#   export FIXTURE_DIR
#   ... bash -c 'source install_mediamtx.sh; eval "$PREAMBLE"; install_mediamtx'
# with PREAMBLE="$(installer_fixture_preamble)".

# Lay out the files a release has, for the linux/amd64 asset:
#   DIR/release.json                       {"tag_name": "VERSION"}
#   DIR/mediamtx_VERSION_linux_amd64.tar.gz   BINARY, named mediamtx
#   DIR/checksums.sha256                   sha256 of the tarball, in the format
#                                          the release publishes
# With the fourth argument "bad-checksum" the published checksum is wrong (a
# valid hash of something else); with "no-checksum" there is no checksum file.
#   installer_release_fixture DIR VERSION BINARY [bad-checksum|no-checksum]
installer_release_fixture() {
    local dir="$1" version="$2" binary="$3" mode="${4:-}" tarball hash
    mkdir -p "$dir/stage"
    ln -sf "$binary" "$dir/stage/mediamtx"
    tarball="$dir/mediamtx_${version}_linux_amd64.tar.gz"
    tar -czhf "$tarball" -C "$dir/stage" mediamtx
    printf '{"tag_name": "%s"}\n' "$version" >"$dir/release.json"
    rm -f "$dir/checksums.sha256"
    case "$mode" in
        no-checksum) ;;
        bad-checksum)
            printf '%s  %s\n' "$(printf '%064d' 0)" "$(basename "$tarball")" >"$dir/checksums.sha256"
            ;;
        *)
            hash="$(sha256sum "$tarball" | awk '{print $1}')"
            printf '%s  %s\n' "$hash" "$(basename "$tarball")" >"$dir/checksums.sha256"
            ;;
    esac
}

# Shell code for the installer's process (evaluated after sourcing it): the
# download function reads from $FIXTURE_DIR instead of the network, the platform
# is linux/amd64 whatever this machine is, and the temporary directory exists.
installer_fixture_preamble() {
    cat <<'EOF'
download_file() {
    local url="$1" out="$2" f
    case "$url" in
        */releases/latest | */releases/tags/*) f="$FIXTURE_DIR/release.json" ;;
        *) f="$FIXTURE_DIR/${url##*/}" ;;
    esac
    if [[ ! -f "$f" ]]; then
        echo "fixture: nothing to download for $url" >&2
        return 1
    fi
    cp "$f" "$out"
}
PLATFORM_OS=linux
PLATFORM_ARCH=amd64
create_temp_dir
EOF
}
