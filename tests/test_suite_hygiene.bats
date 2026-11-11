#!/usr/bin/env bats
# Static guards for how the suite itself is written, so a class of host-state
# leak cannot come back unnoticed.

setup() {
    ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
}

@test "no test redirects the stream manager's log through MEDIAMTX_LOG_FILE alone" {
    # MEDIAMTX_LOG_FILE is MediaMTX's output file. The manager's own log has its
    # own variable (X-15); a test that sets only the former lets the manager
    # write the real /var/log/lyrebird-stream-manager.log of the machine it runs on.
    local f bad=0
    for f in "$ROOT"/tests/*.bats "$ROOT"/tests/*.bash; do
        [[ "$f" == "$ROOT/tests/test_stream_log_variables.bats" ]] && continue
        [[ "$f" == "$BATS_TEST_FILENAME" ]] && continue
        if grep -qE 'MEDIAMTX_LOG_FILE=' "$f" && ! grep -qF 'STREAM_MANAGER_LOG_FILE' "$f"; then
            echo "sets MEDIAMTX_LOG_FILE but never STREAM_MANAGER_LOG_FILE: ${f#"$ROOT"/}"
            bad=1
        fi
    done
    [ "$bad" -eq 0 ]
}
