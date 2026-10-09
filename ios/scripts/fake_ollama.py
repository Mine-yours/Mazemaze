#!/usr/bin/env python3
"""A tiny deterministic stand-in for Ollama (test tool; the real model is not involved).

Serves just enough of /api/version, /api/tags, /api/show and /api/chat for the Mazemaze FastAPI
server to start and translate: every requested span becomes "English <n>".
Usage: python3 fake_ollama.py [port]   (binds 127.0.0.1 only)
"""
import json
import sys
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

MODELS = ["qwen3.5:9b", "translategemma:12b"]


class Handler(BaseHTTPRequestHandler):
    def log_message(self, *args):  # never log request bodies
        pass

    def _json(self, obj, status=200):
        data = json.dumps(obj).encode()
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def do_GET(self):
        if self.path == "/api/version":
            self._json({"version": "0.0-fake"})
        elif self.path == "/api/tags":
            self._json({"models": [{"name": m, "model": m, "digest": "fake-" + m, "size": 6_000_000_000,
                                    "details": {"format": "gguf"}} for m in MODELS]})
        else:
            self._json({}, 404)

    def do_POST(self):
        length = int(self.headers.get("Content-Length") or 0)
        body = json.loads(self.rfile.read(length) or b"{}")
        if self.path == "/api/show":
            self._json({"modelfile": "FROM /fake/blobs/sha256-0\n", "details": {"format": "gguf"}})
        elif self.path == "/api/chat":
            time.sleep(0.4)   # slow enough that the self-test can snapshot the page before the first translation lands
            content = body["messages"][-1]["content"]
            try:
                user = json.loads(content)
                if isinstance(user, dict) and "source_ja" in user:       # /api/define: a word or phrase card (two steps)
                    props = (body.get("format") or {}).get("properties", {})
                    if "senses" in props:
                        card = {"matchInSource": "持っています", "lemma": user["word"].lower(), "pos": "動詞", "contextIndex": 0,
                                "senses": [{"gloss": "持つ・所有する"}, {"gloss": "食べる・飲む"}, {"gloss": "経験する"}]}
                    elif "phrases" in props:
                        card = {"example": {"en": "I have a pen.", "ja": "私はペンを持っています。"}, "phrases": ["have to", "have been"], "note": "have to は「〜しなければならない」"}
                    elif "points" in props:
                        card = {"points": [{"expr": "have", "note": "所有を表す"}], "synonyms": ["I've got a pen"], "example": {"en": "I have a red pen.", "ja": "赤いペンを持っています。"}}
                    else:
                        card = {"meaning": "私はペンを持っています", "nuance": "ごく基本的な言い方"}
                    self._json({"message": {"content": json.dumps(card, ensure_ascii=False)}})
                    return
            except (ValueError, TypeError):
                pass
            try:
                spans = json.loads(content)["spans"]          # Qwen adapter (JSON request)
                items = [{"id": s["id"], "en": f"English {i}"} for i, s in enumerate(spans, 1)]
                self._json({"message": {"content": json.dumps({"items": items})}})
            except (ValueError, KeyError, TypeError):          # TranslateGemma adapter (plain text)
                self._json({"message": {"content": "English text"}})
        else:
            self._json({}, 404)


if __name__ == "__main__":
    port = int(sys.argv[1]) if len(sys.argv) > 1 else 11435
    ThreadingHTTPServer(("127.0.0.1", port), Handler).serve_forever()
