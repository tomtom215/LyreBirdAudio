"""Listen on ADDR:PORT like an ordinary service would (no SO_REUSEPORT), for SECONDS.

usage: python3 -I port_holder.py PORT SECONDS [ADDR]     (ADDR defaults to 127.0.0.1)

Used by the metrics server tests to occupy a port: a second listener on it must
be refused, unlike a second netcat, which sets SO_REUSEPORT and would bind next
to it.
"""

import socket
import sys
import time

sock = socket.socket()
sock.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
sock.bind((sys.argv[3] if len(sys.argv) > 3 else "127.0.0.1", int(sys.argv[1])))
sock.listen(5)
time.sleep(float(sys.argv[2]))
