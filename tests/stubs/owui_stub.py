"""Stub Open WebUI API for the sync test. Records every request in a JSON-lines file.

Usage: owui_stub.py PORT_FILE LOG_FILE. It picks a free port and writes it to PORT_FILE.
"""
import json
import sys
from http.server import BaseHTTPRequestHandler, HTTPServer

port_file, log_file = sys.argv[1:3]
prompts = [{"id": "p1", "command": "review"}]  # an existing prompt, so sync must update it
TASKS = {"ENABLE_TAGS_GENERATION": True, "ENABLE_TITLE_GENERATION": False, "TASK_MODEL_EXTERNAL": ""}
MODELS = {"DEFAULT_MODELS": "", "MODEL_ORDER_LIST": []}


class Handler(BaseHTTPRequestHandler):
    def reply(self, body):
        data = json.dumps(body).encode()
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def record(self):
        length = int(self.headers.get("Content-Length") or 0)
        body = json.loads(self.rfile.read(length) or "null")
        with open(log_file, "a") as f:
            f.write(json.dumps({"method": self.command, "path": self.path, "auth": self.headers.get("Authorization"), "body": body}) + "\n")
        return body

    def do_GET(self):
        self.record()
        self.reply({"/api/v1/prompts/": prompts, "/api/v1/tasks/config": TASKS, "/api/v1/configs/models": MODELS}.get(self.path, {}))

    def do_POST(self):
        body = self.record()
        if self.path == "/api/v1/prompts/create":
            prompts.append({"id": "new-" + body["command"], "command": body["command"]})
        self.reply(True if self.path == "/api/v1/models/import" else body)

    def log_message(self, *args):
        pass


server = HTTPServer(("127.0.0.1", 0), Handler)
open(port_file, "w").write(str(server.server_port))
server.serve_forever()
