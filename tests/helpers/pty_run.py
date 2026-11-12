"""Run a command on a pseudo-terminal and answer its prompts (orchestrator tests).

The orchestrator hands every delegated script `</dev/tty` and reads its menus
from the terminal, so its menus and delegations cannot run without a controlling
terminal (a CI runner has none). This runs COMMAND with one, waits for each
prompt before sending the answer (no sleeps: an answer sent early would be
thrown away by the orchestrator's own stdin flush), and prints everything the
command wrote.

usage: python3 -I pty_run.py [--timeout SECONDS] [--step REGEX TEXT]... -- COMMAND [ARGS...]

  --step REGEX TEXT   once REGEX matches the output the command has written since
                      the previous step, send TEXT (the escapes \\n and \\t are
                      decoded). Steps are consumed in order.
  --timeout SECONDS   kill the command after this long (default 60), exit 124.

Output (stdout): the command's output with ANSI colour sequences and carriage
returns removed. Exit status: the command's own (128+N when a signal ended it);
124 on timeout; 125 when a step never matched (it is named on stderr), because
a prompt that never appeared must fail the test, not pass it.
"""

import os
import pty
import re
import select
import signal
import sys
import time

ANSI = re.compile(r"\x1b\[[0-9;?]*[A-Za-z]")


def clean(text):
    return ANSI.sub("", text).replace("\r", "")


def decode(text):
    return text.replace("\\n", "\n").replace("\\t", "\t")


def parse(argv):
    timeout = 60.0
    steps = []
    i = 0
    while i < len(argv):
        arg = argv[i]
        if arg == "--":
            return timeout, steps, argv[i + 1 :]
        if arg == "--timeout":
            timeout = float(argv[i + 1])
            i += 2
        elif arg == "--step":
            steps.append((re.compile(argv[i + 1]), decode(argv[i + 2])))
            i += 3
        else:
            sys.exit("pty_run: unknown option %r" % arg)
    sys.exit("pty_run: missing -- COMMAND")


def main():
    timeout, steps, command = parse(sys.argv[1:])
    if not command:
        sys.exit("pty_run: missing COMMAND")

    pid, fd = pty.fork()
    if pid == 0:
        try:
            os.execvp(command[0], command)
        except OSError as error:
            sys.stderr.write("pty_run: cannot run %s: %s\n" % (command[0], error))
            os._exit(127)

    deadline = time.monotonic() + timeout
    raw = b""
    since_step = ""
    step = 0
    timed_out = False
    while True:
        if time.monotonic() > deadline:
            timed_out = True
            break
        ready, _, _ = select.select([fd], [], [], 0.1)
        if not ready:
            continue
        try:
            chunk = os.read(fd, 65536)
        except OSError:
            break
        if not chunk:
            break
        raw += chunk
        since_step += clean(chunk.decode("utf-8", "replace"))
        while step < len(steps) and steps[step][0].search(since_step):
            os.write(fd, steps[step][1].encode())
            step += 1
            since_step = ""

    if timed_out:
        try:
            os.killpg(pid, signal.SIGKILL)
        except OSError:
            pass
    _, status = os.waitpid(pid, 0)
    sys.stdout.write(clean(raw.decode("utf-8", "replace")))
    sys.stdout.flush()
    if timed_out:
        sys.stderr.write("pty_run: timed out after %ss\n" % timeout)
        return 124
    if step < len(steps):
        sys.stderr.write(
            "pty_run: step %d never matched: %s\n" % (step + 1, steps[step][0].pattern)
        )
        return 125
    return os.waitstatus_to_exitcode(status)


if __name__ == "__main__":
    sys.exit(main())
