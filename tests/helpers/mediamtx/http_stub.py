"""Stand-in for the MediaMTX control API, for the probe tests.

usage: python3 -I http_stub.py PORT PLAN_FILE LOG_FILE READY_FILE

Listens on 127.0.0.1:PORT. PLAN_FILE is JSON that is re-read for every request,
so a test can change the answer while the server runs:

    {"routes": {"/v3/paths/list": REPLY}, "default": REPLY}

REPLY is {"status": 200, "body": "text", "delay": 0.0, "drop": false,
"truncate": false, "headers": {"Name": "value"}}. A reply with "drop" closes the
connection without answering; one with "truncate" announces 50 bytes more than
it sends and closes. A request for a path with no route gets "default"
(404, "404 page not found" if the plan has none). Every request is appended to
LOG_FILE as "METHOD PATH". READY_FILE is created once the port is bound.
"""

import http.server
import json
import socketserver
import sys
import time

PORT = int(sys.argv[1])
PLAN = sys.argv[2]
LOG = sys.argv[3]
READY = sys.argv[4]

NOT_FOUND = {"status": 404, "body": "404 page not found"}


class Handler(http.server.BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def _reply(self):
        with open(LOG, "a") as log:
            log.write("%s %s\n" % (self.command, self.path))
        try:
            with open(PLAN) as plan_file:
                plan = json.load(plan_file)
        except (OSError, ValueError):
            plan = {}
        route = self.path.split("?", 1)[0]
        reply = plan.get("routes", {}).get(route, plan.get("default", NOT_FOUND))
        time.sleep(float(reply.get("delay", 0)))
        if reply.get("drop"):
            self.close_connection = True
            return
        body = reply.get("body", "").encode("latin-1")
        self.send_response(int(reply.get("status", 200)))
        for name, value in reply.get("headers", {}).items():
            self.send_header(name, value)
        # "truncate": announce more than is sent, then close (a cut-off answer)
        self.send_header("Content-Length", str(len(body) + (50 if reply.get("truncate") else 0)))
        self.end_headers()
        self.wfile.write(body)
        if reply.get("truncate"):
            self.wfile.flush()
            self.close_connection = True

    do_GET = _reply
    do_POST = _reply

    def log_message(self, *args):
        pass


class Server(socketserver.ThreadingMixIn, http.server.HTTPServer):
    allow_reuse_address = True
    daemon_threads = True


with Server(("127.0.0.1", PORT), Handler) as server:
    open(READY, "w").close()
    server.serve_forever()
