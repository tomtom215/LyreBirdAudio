"""A MediaMTX API that answers /v3/info and hangs on every other request.

Listens on an ephemeral loopback port and prints it on the first line of stdout.
GET /v3/info is answered at once with a valid instance document; for any other
path the connection is accepted, the request is read, and no byte is ever sent
back, which is how a MediaMTX that is stuck half-way through a scrape looks to
curl. With "all" as the first argument it hangs on /v3/info as well.

usage: python3 -I slow_api.py [all]
"""

import socket
import sys
import threading
import time

HANG_ALL = len(sys.argv) > 1 and sys.argv[1] == "all"
INFO = b'{"version":"1.19.2","upTime":100000000000}'


def serve(conn):
    try:
        data = b""
        while b"\r\n\r\n" not in data:
            chunk = conn.recv(4096)
            if not chunk:
                return
            data += chunk
        path = data.split(b" ", 2)[1]
        if path == b"/v3/info" and not HANG_ALL:
            head = b"HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: %d\r\nConnection: close\r\n\r\n" % len(INFO)
            conn.sendall(head + INFO)
            conn.close()
            return
        while True:
            time.sleep(1)
    except OSError:
        pass


srv = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
srv.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
srv.bind(("127.0.0.1", 0))
srv.listen(16)
print(srv.getsockname()[1], flush=True)
while True:
    conn, _ = srv.accept()
    threading.Thread(target=serve, args=(conn,), daemon=True).start()
