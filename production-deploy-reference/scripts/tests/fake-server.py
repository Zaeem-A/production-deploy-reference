"""HTTPS stand-in for Nginx and the API, used by test-deploy-flow.sh.

GET anything answers {"service":"notes-api","version":"<contents of the state file>","env":"production"},
which is what scripts/_common.sh wait_for_version looks for.

Usage: fake-server.py PORT CERT KEY STATE_FILE
"""

import http.server
import json
import ssl
import sys

port, cert, key, state = int(sys.argv[1]), sys.argv[2], sys.argv[3], sys.argv[4]


class Handler(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        try:
            with open(state, encoding="utf-8") as fh:
                version = fh.read().strip()
        except FileNotFoundError:
            version = "none"
        body = json.dumps(
            {"service": "notes-api", "version": version, "env": "production"},
            separators=(",", ":"),
        ).encode()
        self.send_response(200)
        self.send_header("content-type", "application/json")
        self.send_header("content-length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, *args):
        pass


server = http.server.ThreadingHTTPServer(("127.0.0.1", port), Handler)
context = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
context.load_cert_chain(cert, key)
server.socket = context.wrap_socket(server.socket, server_side=True)
server.serve_forever()
