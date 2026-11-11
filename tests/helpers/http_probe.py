"""Raw HTTP probe for the metrics server tests (tests/test_lyrebird_metrics.bats).

Sends exactly the bytes it is given and reports how the response is framed, so
the tests can check what curl would hide: CRLF line endings, the Content-Length
against the real body length in bytes, Connection: close.

usage: python3 -I http_probe.py PORT REQUEST BODY_FILE [TIMEOUT] [half-close]

REQUEST is sent after decoding the escapes \\r \\n \\t \\\\ and \\xNN; BODY_FILE
receives the response body bytes. Prints key=value lines:

    status=200 | status=none        the status code, or none if nothing came back
    reason=OK
    head_crlf=1                     every line of the head ends in CRLF
    header.<lowercase-name>=value
    body_bytes=N
    content_length_ok=1             Content-Length equals body_bytes
"""

import re
import socket
import sys


SIMPLE_ESCAPES = {b"r": b"\r", b"n": b"\n", b"t": b"\t", b"\\": b"\\"}


def unescape(match):
    code = match.group(1)
    if code in SIMPLE_ESCAPES:
        return SIMPLE_ESCAPES[code]
    return bytes([int(code[1:], 16)])


def main():
    port = int(sys.argv[1])
    request = re.sub(rb"\\(x[0-9a-fA-F]{2}|[rnt\\])", unescape, sys.argv[2].encode("latin-1"))
    body_file = sys.argv[3]
    timeout = float(sys.argv[4]) if len(sys.argv) > 4 else 20.0
    half_close = len(sys.argv) > 5 and sys.argv[5] == "half-close"

    sock = socket.create_connection(("127.0.0.1", port), timeout=timeout)
    sock.sendall(request)
    if half_close:
        sock.shutdown(socket.SHUT_WR)
    data = b""
    try:
        while True:
            chunk = sock.recv(65536)
            if not chunk:
                break
            data += chunk
    except OSError as error:
        print("recv_error=%s" % error)
    sock.close()

    head, separator, body = data.partition(b"\r\n\r\n")
    if not separator or not head.startswith(b"HTTP/1.1 "):
        print("status=none")
        print("bytes=%d" % len(data))
        open(body_file, "wb").close()
        return
    lines = head.split(b"\r\n")
    status = lines[0].split(b" ", 2)
    print("status=%s" % status[1].decode())
    print("reason=%s" % (status[2].decode() if len(status) > 2 else ""))
    print("head_crlf=%d" % (1 if b"\n" not in head.replace(b"\r\n", b"") else 0))
    headers = {}
    for line in lines[1:]:
        name, _, value = line.partition(b":")
        headers[name.strip().lower().decode()] = value.strip().decode()
        print("header.%s=%s" % (name.strip().lower().decode(), value.strip().decode()))
    with open(body_file, "wb") as handle:
        handle.write(body)
    print("body_bytes=%d" % len(body))
    declared = headers.get("content-length", "")
    print("content_length_ok=%d" % (1 if declared == str(len(body)) else 0))


main()
