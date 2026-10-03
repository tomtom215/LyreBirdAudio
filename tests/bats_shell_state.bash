# Sourcing a LyreBirdAudio script into a bats test shell replaces bats' own
# EXIT/ERR/DEBUG traps (the scripts install cleanup traps) and shell options
# (they enable `set -euo pipefail`). With bats' traps gone no test in the file
# can fail. Call bats_save_shell_state before `source` and
# bats_restore_shell_state right after it.
#
# Options are read from $SHELLOPTS directly: inside $(...) bash turns errexit
# off, so `$(set +o)` would record errexit as off and "restore" it to off.
# `$(trap -p)` is special-cased by bash and does report the caller's traps.
bats_save_shell_state() {
    _BATS_SAVED_TRAPS=$(trap -p EXIT ERR DEBUG INT TERM HUP QUIT)
    _BATS_SAVED_SHELLOPTS=$SHELLOPTS
}

bats_restore_shell_state() {
    local opt
    trap - EXIT ERR DEBUG INT TERM HUP QUIT
    eval "$_BATS_SAVED_TRAPS"
    for opt in errexit nounset pipefail errtrace functrace; do
        if [[ ":$_BATS_SAVED_SHELLOPTS:" == *":$opt:"* ]]; then
            set -o "$opt"
        else
            set +o "$opt"
        fi
    done
}
