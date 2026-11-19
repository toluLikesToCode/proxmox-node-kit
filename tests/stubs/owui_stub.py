"""Stub Open WebUI API for the sync tests. Records every request in a JSON-lines file.

Usage: owui_stub.py PORT_FILE LOG_FILE. It picks a free port and writes it to PORT_FILE.
Knowledge bases and files are kept in memory, like the real API, with a page size of 2 so that
paging is exercised. Fault injection through the environment:
  STUB_UPLOAD_FAILS=<filename>:<n>   the first n uploads of that file answer 500 (n=99: always)
  STUB_PROCESS_STATUS=failed         processing of every upload ends in "failed"
  STUB_CHATS=<file> / STUB_FEEDBACK=<file>   JSON served by the chat and feedback exports
"""
import hashlib
import json
import os
import sys
import uuid
from http.server import BaseHTTPRequestHandler, HTTPServer
from urllib.parse import parse_qs, urlparse

port_file, log_file = sys.argv[1:3]
PAGE = 2
prompts = [{"id": "p1", "command": "review"}]  # an existing prompt, so sync must update it
TASKS = {"ENABLE_TAGS_GENERATION": True, "ENABLE_TITLE_GENERATION": False, "TASK_MODEL_EXTERNAL": ""}
MODELS = {"DEFAULT_MODELS": "", "MODEL_ORDER_LIST": []}
model = {"id": "homelab-advisor", "meta": {"knowledge": [{"type": "collection", "id": "kb-other", "name": "Someone's own base"}]}}
kbs = {}      # id -> {"id", "name", "files": [file id]}
files = {}    # id -> {"id", "filename", "hash"}
upload_fails = {}
if os.environ.get("STUB_UPLOAD_FAILS"):
    name, _, n = os.environ["STUB_UPLOAD_FAILS"].rpartition(":")
    upload_fails[name] = int(n)


def parse_multipart(content_type, raw):
    boundary = content_type.split("boundary=")[1].encode()
    for part in raw.split(b"--" + boundary):
        head, sep, body = part.partition(b"\r\n\r\n")
        if sep and b"filename=" in head:
            filename = head.split(b'filename="')[1].split(b'"')[0].decode()
            return filename, body[:-2] if body.endswith(b"\r\n") else body
    raise ValueError("no file part")


class Handler(BaseHTTPRequestHandler):
    def reply(self, body, code=200):
        data = json.dumps(body).encode()
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def record(self, upload=None):
        length = int(self.headers.get("Content-Length") or 0)
        raw = self.rfile.read(length)
        body = upload or json.loads(raw or "null")
        with open(log_file, "a") as f:
            f.write(json.dumps({"method": self.command, "path": self.path, "auth": self.headers.get("Authorization"), "body": body}) + "\n")
        return raw, body

    def do_GET(self):
        self.record()
        u = urlparse(self.path)
        q = parse_qs(u.query)
        parts = u.path.strip("/").split("/")
        if u.path == "/api/v1/knowledge/":
            return self.reply({"items": [{"id": k["id"], "name": k["name"]} for k in kbs.values()], "total": len(kbs)})
        if parts[:3] == ["api", "v1", "knowledge"] and parts[-1] == "files":
            members = [files[i] for i in kbs[parts[3]]["files"]]
            page = int(q.get("page", ["1"])[0])
            return self.reply({"items": members[(page - 1) * PAGE: page * PAGE], "total": len(members)})
        if parts[:3] == ["api", "v1", "files"] and parts[-1] == "status":
            return self.reply({"status": os.environ.get("STUB_PROCESS_STATUS", "completed")})
        if u.path == "/api/v1/models/model":
            return self.reply(model)
        exports = {"/api/v1/chats/all/db": "STUB_CHATS", "/api/v1/evaluations/feedbacks/all/export": "STUB_FEEDBACK"}
        if u.path in exports:
            src = os.environ.get(exports[u.path])
            return self.reply(json.load(open(src)) if src else [])
        self.reply({"/api/v1/prompts/": prompts, "/api/v1/tasks/config": TASKS, "/api/v1/configs/models": MODELS}.get(u.path, {}))

    def do_DELETE(self):
        self.record()
        files.pop(urlparse(self.path).path.rsplit("/", 1)[1], None)
        self.reply(True)

    def do_POST(self):
        u = urlparse(self.path)
        if u.path == "/api/v1/files/":
            filename, content = parse_multipart(self.headers["Content-Type"], self.rfile.read(int(self.headers["Content-Length"])))
            digest = hashlib.sha256(content).hexdigest()
            with open(log_file, "a") as f:
                f.write(json.dumps({"method": "POST", "path": u.path, "auth": self.headers.get("Authorization"), "body": {"filename": filename, "sha256": digest}}) + "\n")
            if upload_fails.get(filename, 0) > 0:
                upload_fails[filename] -= 1
                return self.reply({"detail": "boom"}, 500)
            fid = str(uuid.uuid4())
            files[fid] = {"id": fid, "filename": filename, "hash": digest}
            return self.reply({"id": fid, "filename": filename})
        _, body = self.record()
        parts = u.path.strip("/").split("/")
        if u.path == "/api/v1/prompts/create":
            prompts.append({"id": "new-" + body["command"], "command": body["command"]})
        elif u.path == "/api/v1/knowledge/create":
            kid = "kb-" + str(len(kbs) + 1)
            kbs[kid] = {"id": kid, "name": body["name"], "files": []}
            return self.reply({"id": kid, "name": body["name"]})
        elif parts[:3] == ["api", "v1", "knowledge"] and parts[-2:] == ["file", "add"]:
            kbs[parts[3]]["files"].append(body["file_id"])
        elif parts[:3] == ["api", "v1", "knowledge"] and parts[-2:] == ["file", "remove"]:
            kbs[parts[3]]["files"].remove(body["file_id"])
            if "delete_file=true" in u.query:
                files.pop(body["file_id"], None)
        elif u.path == "/api/v1/models/model/update":
            model.update(body)
            return self.reply(model)
        self.reply(True if u.path == "/api/v1/models/import" else body)

    def log_message(self, *args):
        pass


server = HTTPServer(("127.0.0.1", 0), Handler)
open(port_file, "w").write(str(server.server_port))
server.serve_forever()
