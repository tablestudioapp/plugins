"""A stand-in for TableStudio's MCP server, for tests/run.sh.

Answers MCP JSON-RPC like the real server (initialize, tools/list, tools/call; 202 for
notifications), requires the bearer token, and records every request's headers and body, one
JSON object per line, so the tests can check what the bridge and the hooks sent.

    python3 tests/fake_mcp_server.py <port> <log file> <token>
"""

import json
import sys
from http.server import BaseHTTPRequestHandler, HTTPServer

PORT, LOG, TOKEN = int(sys.argv[1]), sys.argv[2], sys.argv[3]


class Handler(BaseHTTPRequestHandler):
    def log_message(self, *args):
        pass

    def reply(self, status, body=b"", content_type="application/json"):
        self.send_response(status)
        self.send_header("Content-Type", content_type)
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def do_POST(self):
        body = self.rfile.read(int(self.headers.get("Content-Length") or 0)).decode()
        with open(LOG, "a") as log:
            log.write(json.dumps({"path": self.path, "headers": dict(self.headers), "body": body}) + "\n")
        if self.headers.get("Authorization") != f"Bearer {TOKEN}":
            return self.reply(401, b'{"error":"Unauthorized"}')
        if self.path == "/agent/events":
            return self.reply(204)
        message = json.loads(body)
        if "id" not in message:
            return self.reply(202)
        method = message.get("method")
        if method == "initialize":
            result = {"protocolVersion": "2025-06-18", "capabilities": {"tools": {}},
                      "serverInfo": {"name": "TableStudio", "version": "test"}}
        elif method == "tools/list":
            result = {"tools": [{"name": "list_connections", "inputSchema": {"type": "object"}}]}
        elif method == "tools/call":
            # A pretty-printed body, like a server that formats its JSON, to check the bridge sends
            # each response back as one line.
            text = json.dumps({"connections": []})
            out = json.dumps({"jsonrpc": "2.0", "id": message["id"],
                              "result": {"content": [{"type": "text", "text": text}]}}, indent=2)
            return self.reply(200, out.encode())
        else:
            result = {}
        self.reply(200, json.dumps({"jsonrpc": "2.0", "id": message["id"], "result": result}).encode())


HTTPServer(("127.0.0.1", PORT), Handler).serve_forever()
