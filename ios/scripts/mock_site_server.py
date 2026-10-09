#!/usr/bin/env python3
"""Serves ios/WebTests over HTTP on 127.0.0.1 for the simulator self-test.

Aliases: /login and /i/flow/login return the article page (to prove the app refuses them by path).
Usage: python3 mock_site_server.py [port]
"""
import sys
from functools import partial
from http.server import SimpleHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent / "WebTests"
ALIASES = {"/login": "/static.html", "/i/flow/login": "/static.html"}


class Handler(SimpleHTTPRequestHandler):
    def do_GET(self):
        if self.path.split("?", 1)[0] == "/to-safari":      # what x.com does to in-app browsers
            self.send_response(302)
            self.send_header("Location", "x-safari-https://redirect.example.com/page?ct=test")
            self.end_headers()
            return
        super().do_GET()

    def translate_path(self, path):
        path = path.split("?", 1)[0]
        return super().translate_path(ALIASES.get(path, path))

    def log_message(self, *args):
        pass

    def end_headers(self):
        self.send_header("Cache-Control", "no-store")
        super().end_headers()


if __name__ == "__main__":
    port = int(sys.argv[1]) if len(sys.argv) > 1 else 8792
    ThreadingHTTPServer(("127.0.0.1", port), partial(Handler, directory=str(ROOT))).serve_forever()
