"""FastAPI app: local translation API plus the static frontend (same origin)."""
import hmac
import ipaddress
import logging
from contextlib import asynccontextmanager
from pathlib import Path
from typing import Literal

from fastapi import FastAPI, Request
from fastapi.exceptions import RequestValidationError
from fastapi.responses import FileResponse, JSONResponse
from fastapi.staticfiles import StaticFiles
from pydantic import BaseModel, Field, field_validator

from backend.config import MAX_INPUT_CHARS, Settings
from backend.selector import DEFAULT_RATIO, MAX_RATIO, MIN_RATIO
from backend.service import ServiceError, TranslationService

log = logging.getLogger("mazemaze")
FRONTEND_DIR = Path(__file__).resolve().parent.parent / "frontend"
LOOPBACK_NAMES = {"localhost", "127.0.0.1", "::1"}
TOKEN_HEADER = "x-mazemaze-token"


class TranslateRequest(BaseModel):
    text: str = Field(max_length=MAX_INPUT_CHARS)
    ratio: float = Field(default=DEFAULT_RATIO, ge=MIN_RATIO, le=MAX_RATIO)
    unit: Literal["phrase", "sentence"] = "phrase"

    @field_validator("text")
    @classmethod
    def _not_blank(cls, v: str) -> str:
        if not v.strip():
            raise ValueError("blank")
        if "\x00" in v:
            raise ValueError("nul")
        try:
            v.encode("utf-8")
        except UnicodeEncodeError:
            raise ValueError("surrogate") from None
        return v


def _error(status: int, code: str, message: str) -> JSONResponse:
    return JSONResponse({"error": {"code": code, "message": message}}, status_code=status,
                        headers={"Cache-Control": "no-store"})


def _host_name(host_header: str) -> str:
    host = host_header.strip().lower()
    if host.startswith("["):
        return host[1:host.find("]")] if "]" in host else host
    return host.rsplit(":", 1)[0] if host.count(":") == 1 else host


def _is_private_ip(value: str, *, loopback_only: bool) -> bool:
    try:
        ip = ipaddress.ip_address(value)
    except ValueError:
        return False
    if isinstance(ip, ipaddress.IPv6Address) and ip.ipv4_mapped:
        ip = ip.ipv4_mapped  # judge by the embedded IPv4 address, independent of the Python version
    if ip.is_loopback:
        return True
    return not loopback_only and (ip.is_private or ip.is_link_local) and not ip.is_unspecified


def create_app(settings: Settings | None = None, service: TranslationService | None = None) -> FastAPI:
    settings = settings or Settings.from_env()
    service = service or TranslationService(settings)

    @asynccontextmanager
    async def lifespan(app: FastAPI):
        # Fail fast on a model whose metadata is not a local GGUF; stay up if Ollama is just off.
        try:
            service.check_model()
        except ServiceError as exc:
            if exc.code == "model_rejected":
                raise RuntimeError("configured model is not a verified local model") from None
            log.warning("startup model check: %s (will retry on each request)", exc.code)
        yield

    app = FastAPI(title="mazemaze", lifespan=lifespan, docs_url=None, redoc_url=None, openapi_url=None)
    app.state.service = service
    app.state.settings = settings

    def host_allowed(host_header: str) -> bool:
        name = _host_name(host_header)
        if name in LOOPBACK_NAMES or name in settings.extra_hosts:
            return True
        if not settings.allow_lan:
            return False
        return name.endswith(".local") or _is_private_ip(name, loopback_only=False)

    def check_request(request: Request) -> JSONResponse | None:
        client_ip = request.client.host if request.client else ""
        if not _is_private_ip(client_ip, loopback_only=not settings.allow_lan):
            return _error(403, "forbidden", "このネットワークからは利用できません。")
        if not host_allowed(request.headers.get("host", "")):
            return _error(400, "bad_host", "このホスト名では利用できません。表示された URL で開き直してください。")
        if request.method == "POST":
            length = request.headers.get("content-length")
            if length is None:
                return _error(411, "length_required", "送信内容の長さが必要です。")
            try:
                too_big = int(length) > 20000
            except ValueError:
                too_big = True
            if too_big:
                return _error(413, "too_large", "送信内容が大きすぎます。")
            origin = request.headers.get("origin")
            if origin is not None and origin.split("://", 1)[-1].lower() != request.headers.get("host", "").lower():
                return _error(403, "bad_origin", "別のサイトからの要求は受け付けません。")
            if not request.headers.get("content-type", "").lower().startswith("application/json"):
                return _error(415, "bad_content_type", "JSON 形式で送信してください。")
        if settings.token and request.url.path.startswith("/api/"):
            supplied = request.headers.get(TOKEN_HEADER, "")
            if not hmac.compare_digest(supplied.encode(), settings.token.encode()):
                return _error(401, "token_required",
                              "アクセストークンが必要です。Mac のターミナルに表示された URL（末尾が #t=… のもの）を、このブラウザで開き直してください。")
        return None

    @app.middleware("http")
    async def guard(request: Request, call_next):
        response = check_request(request) or await call_next(request)
        response.headers.setdefault("X-Content-Type-Options", "nosniff")
        response.headers.setdefault("Referrer-Policy", "no-referrer")
        response.headers.setdefault(
            "Content-Security-Policy",
            "default-src 'self'; style-src 'self'; script-src 'self'; frame-ancestors 'none'")
        if request.url.path.startswith("/api/"):
            response.headers["Cache-Control"] = "no-store"
        return response

    @app.exception_handler(RequestValidationError)
    async def _invalid(request: Request, exc: RequestValidationError):
        # Default handler echoes the submitted body; never do that with the user's text.
        fields = sorted({str(e["loc"][-1]) for e in exc.errors() if e.get("loc")})
        if "text" in fields:
            message = f"文章は空でなく、{MAX_INPUT_CHARS} 文字以内で入力してください。"
        else:
            message = "入力値が正しくありません（英語化率は 10〜70%）。"
        return _error(422, "invalid_request", message)

    # Plain `def` endpoints run in a worker thread: the Ollama client is blocking.
    @app.post("/api/translate")
    def translate(req: TranslateRequest):
        if not service.try_acquire():
            resp = _error(429, "busy", ServiceError("busy").message)
            resp.headers["Retry-After"] = "2"
            return resp
        try:
            return JSONResponse(service.translate(req.text, req.ratio, req.unit))
        except ServiceError as exc:
            return _error(exc.status, exc.code, exc.message)
        except Exception as exc:  # noqa: BLE001
            log.error("unexpected error: %s", type(exc).__name__)
            return _error(500, "internal_error", ServiceError("internal_error").message)
        finally:
            service.release()

    @app.post("/api/warmup")
    def warmup():
        """Load the model before the first real request (a cold start takes 5-20 s). Carries no user text."""
        if not service.try_acquire():
            return JSONResponse({"ok": True, "skipped": "busy"})   # someone is translating: the model is loaded
        try:
            return JSONResponse(service.warmup())
        except ServiceError as exc:
            return _error(exc.status, exc.code, exc.message)
        except Exception as exc:  # noqa: BLE001
            log.error("unexpected warmup error: %s", type(exc).__name__)
            return _error(500, "internal_error", ServiceError("internal_error").message)
        finally:
            service.release()

    @app.get("/api/status")
    def status():
        return service.status()

    @app.get("/")
    def index():
        return FileResponse(FRONTEND_DIR / "index.html", headers={"Cache-Control": "no-cache"})

    if FRONTEND_DIR.is_dir():
        app.mount("/static", StaticFiles(directory=FRONTEND_DIR), name="static")
    return app


def app_factory() -> FastAPI:
    """Entry point for `uvicorn backend.app:app_factory --factory`."""
    return create_app()
