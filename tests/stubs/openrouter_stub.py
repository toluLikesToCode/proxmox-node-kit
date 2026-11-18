"""Stub OpenRouter for the integration test. Lists one model and answers chat requests.

Usage: openrouter_stub.py PORT MODEL_ID. GET /_log returns every chat request it received as
JSON lines, so the test can see exactly what Open WebUI sent upstream.
"""
import json
import sys
from http.server import BaseHTTPRequestHandler, HTTPServer

port, model = int(sys.argv[1]), sys.argv[2]
received = []


class Handler(BaseHTTPRequestHandler):
    def reply(self, body, kind="application/json"):
        data = body if isinstance(body, bytes) else json.dumps(body).encode()
        self.send_response(200)
        self.send_header("Content-Type", kind)
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def do_GET(self):
        if self.path == "/_log":
            self.reply("".join(json.dumps(r) + "\n" for r in received).encode(), "text/plain")
        else:
            self.reply({"object": "list", "data": [{"id": model, "object": "model", "name": model}]})

    def do_POST(self):
        body = json.loads(self.rfile.read(int(self.headers.get("Content-Length") or 0)) or "null")
        received.append({"path": self.path, "body": body})
        self.reply({"id": "x", "object": "chat.completion", "created": 0, "model": model,
                    "choices": [{"index": 0, "finish_reason": "stop", "message": {"role": "assistant", "content": "ok"}}]})


HTTPServer(("0.0.0.0", port), Handler).serve_forever()
