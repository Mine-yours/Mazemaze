"""Fake Ollama transport and app factory for API tests. No network is ever used."""
import json
import threading

from fastapi.testclient import TestClient

from backend.app import create_app
from backend.config import Settings
from backend.llm.ollama_client import OllamaClient
from backend.service import TranslationService

GOOD_TAG = {"name": "qwen3.5:9b", "model": "qwen3.5:9b", "digest": "abc",
            "size": 6_000_000_000, "details": {"format": "gguf"}}
GOOD_SHOW = {"modelfile": "FROM /Users/x/.ollama/models/blobs/sha256-abc\n", "details": {"format": "gguf"}}


def default_chat(payload: dict) -> dict:
    """Translate every requested span to 'English <n>'."""
    user = json.loads(payload["messages"][-1]["content"])
    items = [{"id": s["id"], "en": f"English {i}"} for i, s in enumerate(user["spans"], 1)]
    return {"message": {"content": json.dumps({"items": items})}}


class FakeOllama:
    def __init__(self, chat=default_chat, tags=None, show=None, reachable=True):
        self.chat_handler = chat
        self.tags = [GOOD_TAG] if tags is None else tags
        self.show = GOOD_SHOW if show is None else show
        self.reachable = reachable
        self.calls: list[str] = []
        self.chat_payloads: list[dict] = []
        self._lock = threading.Lock()

    def __call__(self, method, url, body, timeout):
        path = "/" + url.split("/", 3)[3]
        with self._lock:
            self.calls.append(path)
        if not self.reachable:
            raise ConnectionRefusedError("refused")
        if path == "/api/tags":
            return 200, json.dumps({"models": self.tags}).encode()
        if path == "/api/show":
            return 200, json.dumps(self.show).encode()
        if path == "/api/chat":
            payload = json.loads(body)
            with self._lock:
                self.chat_payloads.append(payload)
            result = self.chat_handler(payload)
            if isinstance(result, tuple):
                return result
            return 200, json.dumps(result).encode()
        return 404, b"{}"


def make_service(fake: FakeOllama, clock=None, **settings_kw) -> TranslationService:
    settings = Settings(**settings_kw)
    kwargs = {"clock": clock} if clock else {}
    return TranslationService(
        settings, lambda timeout: OllamaClient(settings.ollama_url, timeout=timeout, transport=fake), **kwargs)


def make_client(fake: FakeOllama | None = None, *, client_ip="127.0.0.1", clock=None,
                base_url="http://localhost",
                raise_server_exceptions=True, **settings_kw):
    fake = fake or FakeOllama()
    settings = Settings(**settings_kw)
    app = create_app(settings, make_service(fake, clock=clock, **settings_kw))
    return TestClient(app, base_url=base_url, client=(client_ip, 50000),
                      raise_server_exceptions=raise_server_exceptions), fake


SAMPLE = "今日は天気がとても良かったので、友達と一緒に公園へ散歩に行きました。\n帰り道に新しいカフェを見つけて、コーヒーを飲みながら本を読みました。"
