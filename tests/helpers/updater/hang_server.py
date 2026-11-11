"""Accept TCP connections on an ephemeral loopback port and never answer.

Prints the port on the first line of stdout, then holds every connection open
until it is killed. To git this is a black-holed network path: the connection
is made, no byte ever comes back.
"""
import socket
import time

srv = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
srv.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
srv.bind(("127.0.0.1", 0))
srv.listen(16)
print(srv.getsockname()[1], flush=True)
held = []
while True:
    conn, _ = srv.accept()
    held.append(conn)
    time.sleep(0.01)
