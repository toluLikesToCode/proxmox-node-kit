"""Stub ntfy publish endpoint for the telemetry tests. Records every request as a JSON line.

Usage: ntfy_stub.py PORT_FILE LOG_FILE ATTACH_DIR. An attachment body (a request with a Filename
header) is saved to ATTACH_DIR under that name. STUB_FAIL=1 answers every request with 500.
"""
import json
import os
import sys
from http.server import BaseHTTPRequestHandler, HTTPServer

port_file, log_file, attach_dir = sys.argv[1:4]


class Handler(BaseHTTPRequestHandler):
    def handle_publish(self):
        raw = self.rfile.read(int(self.headers.get("Content-Length") or 0))
        filename = self.headers.get("Filename")
        entry = {"method": self.command, "topic": self.path.strip("/"), "auth": self.headers.get("Authorization"),
                 "title": self.headers.get("Title"), "tags": self.headers.get("Tags"),
                 "priority": self.headers.get("Priority"), "message": self.headers.get("Message"),
                 "filename": filename, "bytes": len(raw)}
        if filename:
            with open(os.path.join(attach_dir, filename), "wb") as f:
                f.write(raw)
        else:
            entry["body"] = raw.decode()
        with open(log_file, "a") as f:
            f.write(json.dumps(entry) + "\n")
        code = 500 if os.environ.get("STUB_FAIL") == "1" else 200
        data = b'{"id":"x"}'
        self.send_response(code)
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    do_POST = do_PUT = handle_publish

    def log_message(self, *args):
        pass


server = HTTPServer(("127.0.0.1", 0), Handler)
open(port_file, "w").write(str(server.server_port))
server.serve_forever()
