#!/usr/bin/env python3
"""Tiny stand-in app: serves APP_VERSION and persists a marker on EFS."""
import os
import time
from http.server import BaseHTTPRequestHandler, HTTPServer

VERSION = os.environ.get("APP_VERSION", "unknown")
DATA_DIR = os.environ.get("DATA_DIR", "/data")
MARKER = os.path.join(DATA_DIR, "marker.txt")


def ensure_marker():
    os.makedirs(DATA_DIR, exist_ok=True)
    if not os.path.exists(MARKER):
        with open(MARKER, "w", encoding="utf-8") as f:
            f.write(f"written_by={VERSION}\nts={time.strftime('%Y-%m-%dT%H:%M:%SZ', time.gmtime())}\n")
        print(f"WROTE_MARKER version={VERSION} path={MARKER}", flush=True)
    else:
        with open(MARKER, encoding="utf-8") as f:
            existing = f.read().strip()
        print(f"FOUND_MARKER version={VERSION} content={existing!r}", flush=True)


class Handler(BaseHTTPRequestHandler):
    def do_GET(self):
        marker = "MISSING"
        if os.path.exists(MARKER):
            with open(MARKER, encoding="utf-8") as f:
                marker = f.read()
        body = f"APP_VERSION={VERSION}\nEFS_MARKER=\n{marker}\n".encode()
        self.send_response(200)
        self.send_header("Content-Type", "text/plain")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, fmt, *args):
        print(f"HTTP {args[0]}", flush=True)


if __name__ == "__main__":
    ensure_marker()
    port = int(os.environ.get("PORT", "8080"))
    print(f"Listening on :{port} APP_VERSION={VERSION}", flush=True)
    HTTPServer(("", port), Handler).serve_forever()
