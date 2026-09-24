"""Controlled stand-in for monolith-backend / user-service / sales-service.

Integration tests of the gateway need to know EXACTLY what reached the
backend (which one, which method/path, which X-Request-ID / traceparent /
Host), which real services do not reveal. Every response echoes that as
JSON; like the real backends it also echoes X-Request-ID. /health is 200.
Standard library only.
"""

from __future__ import annotations

import json
import os
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

NAME = os.environ["STUB_NAME"]
ECHO_HEADERS = ("x-request-id", "traceparent", "tracestate", "host", "x-forwarded-for", "x-real-ip", "origin")


class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def _handle(self) -> None:
        length = int(self.headers.get("Content-Length") or 0)
        if length:
            self.rfile.read(length)
        if self.path == "/health":
            body = {"status": "ok", "service": NAME}
        else:
            body = {
                "service": NAME,
                "method": self.command,
                "path": self.path,
                "headers": {h: self.headers.get(h) for h in ECHO_HEADERS if self.headers.get(h)},
            }
        raw = json.dumps(body).encode()
        status = 201 if self.command == "POST" and self.path != "/health" else 200
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(raw)))
        self.send_header("Server", f"stub/{NAME}")
        # Mimic the monolith's CORS middleware leaking credentials=true: the
        # gateway must strip it (its own CORS policy is the only one).
        self.send_header("Access-Control-Allow-Credentials", "true")
        rid = self.headers.get("X-Request-ID")
        if rid:
            self.send_header("X-Request-ID", rid)
        self.end_headers()
        self.wfile.write(raw)

    do_GET = do_POST = do_PUT = do_PATCH = do_DELETE = do_HEAD = _handle

    def log_message(self, format: str, *args: object) -> None:  # noqa: A002
        return


if __name__ == "__main__":
    ThreadingHTTPServer(("0.0.0.0", 8000), Handler).serve_forever()  # noqa: S104
