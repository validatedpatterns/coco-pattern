#!/usr/bin/env python3
"""Smart HTTP git server — fallback for when Apache dumb HTTP
doesn't work with go-git (patterns-operator / ArgoCD).

Uses git-http-backend CGI behind a threaded Python HTTP server.
No root required — runs on any port > 1024.

Usage:
    python3 git-http-server.py [PORT] [GIT_PROJECT_ROOT]

    PORT              — default 8080
    GIT_PROJECT_ROOT  — default ~/public_html/git

Systemd user service (persistent):
    systemctl --user enable --now git-http.service
"""
import os
import subprocess
import sys
import socketserver
from http.server import HTTPServer, BaseHTTPRequestHandler
from urllib.parse import urlparse

GIT_PROJECT_ROOT = os.path.expanduser(
    sys.argv[2] if len(sys.argv) > 2 else "~/public_html/git"
)
GIT_HTTP_BACKEND = "/usr/libexec/git-core/git-http-backend"


class GitHTTPHandler(BaseHTTPRequestHandler):
    def do_GET(self):
        self._handle()

    def do_POST(self):
        self._handle()

    def _handle(self):
        parsed = urlparse(self.path)
        env = dict(os.environ)
        env.update(
            {
                "GIT_PROJECT_ROOT": GIT_PROJECT_ROOT,
                "GIT_HTTP_EXPORT_ALL": "1",
                "PATH_INFO": parsed.path,
                "QUERY_STRING": parsed.query or "",
                "REQUEST_METHOD": self.command,
                "CONTENT_TYPE": self.headers.get("Content-Type", ""),
                "SERVER_PROTOCOL": "HTTP/1.1",
                "HTTP_CONTENT_ENCODING": self.headers.get("Content-Encoding", ""),
            }
        )
        cl = self.headers.get("Content-Length", "")
        if cl:
            env["CONTENT_LENGTH"] = cl

        proc = subprocess.Popen(
            [GIT_HTTP_BACKEND],
            stdin=subprocess.PIPE,
            stdout=subprocess.PIPE,
            env=env,
        )

        if cl:
            body = self.rfile.read(int(cl))
            proc.stdin.write(body)
        proc.stdin.close()

        status = 200
        hdrs = []
        while True:
            line = proc.stdout.readline()
            if not line or line.strip() == b"":
                break
            line = line.decode("utf-8", errors="replace").strip()
            if line.lower().startswith("status:"):
                status = int(line.split(":")[1].strip().split()[0])
            elif ":" in line:
                k, v = line.split(":", 1)
                hdrs.append((k.strip(), v.strip()))

        self.send_response(status)
        for k, v in hdrs:
            self.send_header(k, v)
        self.end_headers()

        while True:
            chunk = proc.stdout.read(65536)
            if not chunk:
                break
            self.wfile.write(chunk)
        proc.wait()

    def log_message(self, fmt, *args):
        pass


class ThreadedHTTPServer(socketserver.ThreadingMixIn, HTTPServer):
    daemon_threads = True


if __name__ == "__main__":
    port = int(sys.argv[1]) if len(sys.argv) > 1 else 8080
    srv = ThreadedHTTPServer(("0.0.0.0", port), GitHTTPHandler)
    print(f"Git HTTP server on port {port}, root={GIT_PROJECT_ROOT}", flush=True)
    srv.serve_forever()
