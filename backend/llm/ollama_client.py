"""Minimal Ollama HTTP client. Loopback only; cloud models are refused."""
import json
import socket
import time
import urllib.error
import urllib.request
from typing import Callable
from urllib.parse import urlparse

from backend.llm.base import OllamaError

Transport = Callable[[str, str, bytes | None, float], tuple[int, bytes]]

LOOPBACK_HOSTS = {"127.0.0.1", "localhost", "::1"}
DEFAULT_BASE_URL = "http://127.0.0.1:11434"


def assert_local_model(name: str) -> None:
    lowered = name.lower()
    if ":cloud" in lowered or "-cloud" in lowered:
        raise ValueError("cloud models are not allowed (local inference only)")


MIN_LOCAL_MODEL_BYTES = 50 * 1024 * 1024


def _remote_keys(d) -> list[str]:
    return [k for k in d if "remote" in str(k).lower()] if isinstance(d, dict) else []


def assert_local_entry(tag: dict, show: dict) -> None:
    """Fail-closed check that an installed model is a local GGUF, not an alias of a cloud model.

    The name check alone (":cloud" / "-cloud") is bypassable with `ollama cp` or a Modelfile
    alias. Verified against Ollama 0.33.3: local models report details.format == "gguf", a
    multi-GB size and a Modelfile whose FROM lines are local blob paths. What a cloud alias
    looks like is NOT verified, so anything that cannot be positively identified as local is
    rejected. This cannot detect server-side cloud routing (set OLLAMA_NO_CLOUD=1 on the
    server; see eval/README.md).
    """
    if not isinstance(tag, dict) or not isinstance(show, dict):
        raise ValueError("model metadata is unavailable; refusing to use it")
    name = str(tag.get("name") or tag.get("model") or "")
    assert_local_model(name)
    details = tag.get("details") if isinstance(tag.get("details"), dict) else {}
    show_details = show.get("details") if isinstance(show.get("details"), dict) else {}
    if any(_remote_keys(d) for d in (tag, show, details, show_details)):
        raise ValueError(f"{name}: metadata contains remote/cloud fields")
    if details.get("format") != "gguf":
        raise ValueError(f"{name}: not a local GGUF model")
    size = tag.get("size")
    if isinstance(size, bool) or not isinstance(size, int) or size < MIN_LOCAL_MODEL_BYTES:
        raise ValueError(f"{name}: no local model weights (size too small or unknown)")
    modelfile = show.get("modelfile")
    froms = [ln[5:].strip() for ln in modelfile.splitlines() if ln.startswith("FROM ")] \
        if isinstance(modelfile, str) else []
    if not froms or any(not f.startswith("/") for f in froms):
        raise ValueError(f"{name}: Modelfile does not point to local weights")


class _NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, *args, **kwargs):
        return None


def _default_transport(method: str, url: str, body: bytes | None, timeout: float) -> tuple[int, bytes]:
    opener = urllib.request.build_opener(urllib.request.ProxyHandler({}), _NoRedirect())
    req = urllib.request.Request(url, data=body, method=method, headers={"Content-Type": "application/json"})
    try:
        with opener.open(req, timeout=timeout) as resp:
            return resp.status, resp.read()
    except urllib.error.HTTPError as e:
        return e.code, e.read()


def _classify_exception(exc: BaseException) -> OllamaError:
    reason = exc.reason if isinstance(exc, urllib.error.URLError) else exc
    if isinstance(exc, (TimeoutError, socket.timeout)) or isinstance(reason, (TimeoutError, socket.timeout)):
        return OllamaError("timeout", "Ollama request timed out")
    if isinstance(reason, OSError) or isinstance(exc, OSError):
        return OllamaError("ollama_unreachable", "cannot connect to Ollama")
    return OllamaError("http_error", "unexpected transport error")


class OllamaClient:
    def __init__(self, base_url: str = DEFAULT_BASE_URL, timeout: float = 120.0, transport: Transport | None = None):
        parsed = urlparse(base_url)
        if parsed.scheme != "http":
            raise ValueError("base_url must use http")
        if parsed.username is not None or parsed.password is not None:
            raise ValueError("base_url must not contain credentials")
        if parsed.hostname not in LOOPBACK_HOSTS:
            raise ValueError("base_url must be a loopback address")
        self.base_url = base_url.rstrip("/")
        self.timeout = timeout
        self._transport = transport or _default_transport

    def _request(self, method: str, path: str, payload: dict | None = None) -> dict:
        body = json.dumps(payload).encode("utf-8") if payload is not None else None
        try:
            status, data = self._transport(method, self.base_url + path, body, self.timeout)
        except OllamaError:
            raise
        except Exception as exc:  # noqa: BLE001 - classified below
            raise _classify_exception(exc) from None
        parsed = None
        try:
            parsed = json.loads(data)
        except (ValueError, TypeError):
            pass
        if not 200 <= status < 300:
            err = parsed.get("error", "") if isinstance(parsed, dict) else ""
            if status == 404 or (isinstance(err, str) and "not found" in err.lower()):
                raise OllamaError("model_not_found", "model not found")
            raise OllamaError("http_error", f"HTTP {status}")
        if not isinstance(parsed, dict):
            raise OllamaError("invalid_response", "response is not a JSON object")
        return parsed

    def version(self) -> str:
        return str(self._request("GET", "/api/version").get("version", ""))

    def tags(self) -> list[dict]:
        models = self._request("GET", "/api/tags").get("models", [])
        return models if isinstance(models, list) else []

    def show(self, model: str) -> dict:
        assert_local_model(model)
        return self._request("POST", "/api/show", {"model": model})

    def chat(self, payload: dict) -> tuple[dict, float]:
        assert_local_model(str(payload.get("model", "")))
        start = time.perf_counter()
        resp = self._request("POST", "/api/chat", payload)
        return resp, (time.perf_counter() - start) * 1000.0
