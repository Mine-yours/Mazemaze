import json
import urllib.error
import urllib.request

import pytest

from backend.llm.base import OllamaError
from backend.llm import ollama_client
from backend.llm.ollama_client import OllamaClient, assert_local_model


class Recorder:
    def __init__(self, result=None, exc=None):
        self.calls = []
        self.result = result
        self.exc = exc

    def __call__(self, method, url, body, timeout):
        self.calls.append((method, url, body, timeout))
        if self.exc:
            raise self.exc
        return self.result


@pytest.mark.parametrize(
    "url",
    [
        "http://192.168.1.2:11434",
        "http://0.0.0.0:11434",
        "http://127.0.0.2:11434",
        "http://127.0.0.1.evil.com:11434",
        "http://localhost@evil.com:11434",
        "https://127.0.0.1:11434",
        "http://user:pw@127.0.0.1:11434",
    ],
)
def test_non_loopback_rejected_before_transport(url):
    t = Recorder(result=(200, b"{}"))
    with pytest.raises(ValueError):
        OllamaClient(url, transport=t)
    assert t.calls == []


@pytest.mark.parametrize("url", ["http://127.0.0.1:11434", "http://localhost:11434", "http://[::1]:11434"])
def test_loopback_accepted(url):
    OllamaClient(url, transport=Recorder(result=(200, b"{}")))


@pytest.mark.parametrize("model", ["qwen3:cloud", "gpt-oss:120b-cloud", "X:CLOUD", "m-Cloud"])
def test_cloud_model_rejected(model):
    t = Recorder(result=(200, b"{}"))
    c = OllamaClient(transport=t)
    with pytest.raises(ValueError):
        c.chat({"model": model})
    with pytest.raises(ValueError):
        assert_local_model(model)
    assert t.calls == []


def test_cloudy_name_allowed():
    assert_local_model("cloudy:7b")


@pytest.mark.parametrize(
    "transport,expected",
    [
        (Recorder(exc=ConnectionRefusedError()), "ollama_unreachable"),
        (Recorder(exc=urllib.error.URLError(ConnectionRefusedError())), "ollama_unreachable"),
        (Recorder(exc=TimeoutError()), "timeout"),
        (Recorder(exc=urllib.error.URLError(TimeoutError())), "timeout"),
        (Recorder(result=(404, b'{"error":"model \'x\' not found"}')), "model_not_found"),
        (Recorder(result=(500, b'{"error":"boom"}')), "http_error"),
        (Recorder(result=(500, b"not json")), "http_error"),
        (Recorder(result=(200, b"not json")), "invalid_response"),
        (Recorder(result=(200, b"[1,2]")), "invalid_response"),
    ],
)
def test_error_classification(transport, expected):
    c = OllamaClient(transport=transport)
    with pytest.raises(OllamaError) as ei:
        c.chat({"model": "qwen3.5:9b"})
    assert ei.value.error_type == expected


def test_error_message_no_body_leak():
    secret = "機密本文SECRET"
    c = OllamaClient(transport=Recorder(result=(500, json.dumps({"error": secret}).encode())))
    with pytest.raises(OllamaError) as ei:
        c.chat({"model": "qwen3.5:9b", "messages": [{"content": secret}]})
    assert secret not in str(ei.value)


def test_chat_returns_json_and_latency():
    c = OllamaClient(transport=Recorder(result=(200, b'{"message":{"content":"x"}}')))
    resp, ms = c.chat({"model": "qwen3.5:9b"})
    assert resp["message"]["content"] == "x"
    assert ms >= 0


def test_version_and_tags():
    t = Recorder(result=(200, b'{"version":"0.33.3","models":[{"name":"a"}]}'))
    c = OllamaClient(transport=t)
    assert c.version() == "0.33.3"
    assert c.tags() == [{"name": "a"}]
    assert t.calls[0][1].endswith("/api/version")


def test_default_opener_no_proxy_no_redirect(monkeypatch):
    monkeypatch.setenv("HTTP_PROXY", "http://proxy.invalid:8080")
    monkeypatch.setenv("http_proxy", "http://proxy.invalid:8080")
    captured = {}
    real_build = urllib.request.build_opener

    def spy(*handlers):
        captured["handlers"] = handlers
        return real_build(*handlers)

    monkeypatch.setattr(urllib.request, "build_opener", spy)
    with pytest.raises(RuntimeError):  # network is blocked by conftest guard
        ollama_client._default_transport("GET", "http://127.0.0.1:11434/api/version", None, 1)
    proxies = [h for h in captured["handlers"] if isinstance(h, urllib.request.ProxyHandler)]
    assert proxies and proxies[0].proxies == {}
    redirect = [h for h in captured["handlers"] if isinstance(h, ollama_client._NoRedirect)]
    assert redirect and redirect[0].redirect_request(None, None, 302, "", {}, "http://x") is None
