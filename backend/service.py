"""Translation service: select spans, call the local model in batches, validate, assemble, format.

The original text is only ever re-assembled from slices of itself. Any failure leaves the affected
spans Japanese. Nothing here logs or returns request text except in the successful response.
"""
import logging
import re
import threading
import time
from typing import Callable

from backend.config import (ADAPTERS, BATCH_MAX_CHARS, BATCH_MAX_SPANS, MAX_SPANS, Settings,
                            validate_model)
from backend.display import format_segments, joined, outside_preserved
from backend.llm.base import OllamaError
from backend.llm.ollama_client import OllamaClient, assert_local_entry
from backend.selector import counted_length, select_spans
from backend.spans import Segment, Span, assemble

log = logging.getLogger("mazemaze")
# validate_translation does not treat CJK punctuation / full-width forms as Japanese; reject here.
_FULLWIDTH = re.compile("[\u3000-\u303f\uff00-\uffef]")

ClientFactory = Callable[[float], OllamaClient]

_ERROR_STATUS = {
    "ollama_unreachable": (503, "Ollama に接続できません。Mac で Ollama アプリを起動してから、もう一度お試しください。"),
    "model_not_found": (503, "モデルが見つかりません。Mac のターミナルで ollama list を実行し、導入済みか確認してください。"),
    "timeout": (504, "ローカルモデルの応答が時間内に終わりませんでした。短い文章で再試行してください。"),
    "http_error": (502, "Ollama がエラーを返しました。Ollama を再起動してから再試行してください。"),
    "invalid_response": (502, "Ollama の応答を読み取れませんでした。再試行してください。"),
    "internal_error": (500, "内部エラーが発生しました。再試行してください。"),
    "model_rejected": (503, "このモデルはローカルモデルとして確認できないため、使用できません。"),
    "busy": (429, "別の変換を処理中です。完了してからもう一度お試しください。"),
}


MIN_CALL_WINDOW = 5.0  # seconds


class _DeadlineClient:
    """Wraps a client so that every single call (TranslateGemma makes one per span) respects both
    the per-call timeout and the request deadline."""

    def __init__(self, inner: OllamaClient, call_timeout: float, deadline_at: float,
                 clock: Callable[[], float]):
        self._inner = inner
        self._call_timeout = call_timeout
        self._deadline_at = deadline_at
        self._clock = clock
        self.hit_deadline = False

    def chat(self, payload: dict):
        remaining = self._deadline_at - self._clock()
        if remaining < MIN_CALL_WINDOW:  # too little time for a model call to finish
            self.hit_deadline = True
            raise OllamaError("timeout", "request deadline reached")
        self._inner.timeout = min(self._call_timeout, remaining)
        return self._inner.chat(payload)


class ServiceError(Exception):
    def __init__(self, code: str):
        status, message = _ERROR_STATUS.get(code, _ERROR_STATUS["internal_error"])
        super().__init__(code)
        self.code = code
        self.status = status
        self.message = message


def batch_spans(spans: list[Span]) -> list[list[Span]]:
    """Group spans so each LLM call stays within BATCH_MAX_SPANS spans / BATCH_MAX_CHARS chars."""
    batches: list[list[Span]] = []
    current: list[Span] = []
    chars = 0
    for s in spans:
        n = len(s.source)
        if current and (len(current) >= BATCH_MAX_SPANS or chars + n > BATCH_MAX_CHARS):
            batches.append(current)
            current, chars = [], 0
        current.append(s)
        chars += n
    if current:
        batches.append(current)
    return batches


class TranslationService:
    def __init__(self, settings: Settings, client_factory: ClientFactory | None = None,
                 clock: Callable[[], float] = time.monotonic):
        settings.validate()
        self.settings = settings
        self._clock = clock
        self._client_factory = client_factory or (
            lambda timeout: OllamaClient(settings.ollama_url, timeout=timeout))
        self._lock = threading.Lock()

    # -- model verification ------------------------------------------------------------------
    def check_model(self) -> str:
        """Verify the configured model is allow-listed and a local GGUF. Returns the digest.

        Runs for every request (a few ms) so that a model replaced after startup is caught.
        Raises ServiceError. This cannot detect server-side cloud routing (set OLLAMA_NO_CLOUD=1).
        """
        model = validate_model(self.settings.model)
        client = self._client_factory(5.0)
        try:
            tags = client.tags()
            tag = next((t for t in tags if isinstance(t, dict)
                        and model in (t.get("name"), t.get("model"))), None)
            if tag is None:
                raise ServiceError("model_not_found")
            show = client.show(model)
        except OllamaError as exc:
            raise ServiceError(exc.error_type) from None
        try:
            assert_local_entry(tag, show)
        except ValueError:
            raise ServiceError("model_rejected") from None
        digest = tag.get("digest")
        return digest if isinstance(digest, str) else ""

    def status(self) -> dict:
        info = {"model": self.settings.model, "deadline_seconds": self.settings.deadline, "allowed_models": sorted(ADAPTERS),
                "ollama_reachable": False, "model_installed": False, "model_metadata_ok": False,
                "busy": self._lock.locked()}
        try:
            self.check_model()
            info.update(ollama_reachable=True, model_installed=True, model_metadata_ok=True)
        except ServiceError as exc:
            if exc.code == "model_not_found":
                info.update(ollama_reachable=True)
            elif exc.code == "model_rejected":
                info.update(ollama_reachable=True, model_installed=True)
        return info

    # -- translation --------------------------------------------------------------------------
    def try_acquire(self) -> bool:
        return self._lock.acquire(blocking=False)

    def release(self) -> None:
        self._lock.release()

    def translate(self, text: str, ratio: float, unit: str) -> dict:
        """Caller must hold the lock (try_acquire). Raises ServiceError on total failure."""
        started = self._clock()
        self.check_model()
        selection = select_spans(text, ratio, unit, max_spans=MAX_SPANS)  # type: ignore[arg-type]
        spans = selection.spans
        warnings: list[str] = []
        translations: dict[str, str | None] = {}
        error_types: list[str] = []
        batches = batch_spans(spans)
        skipped = 0
        unusable = 0
        ran_results = 0
        call_failed = 0
        deadline_hit = False

        for i, batch in enumerate(batches):
            remaining = self.settings.deadline - (self._clock() - started)
            if remaining < MIN_CALL_WINDOW:
                skipped = len(batches) - i
                break
            client = _DeadlineClient(self._client_factory(self.settings.call_timeout),
                                     self.settings.call_timeout, started + self.settings.deadline,
                                     self._clock)
            adapter = ADAPTERS[self.settings.model](client, self.settings.model)
            try:
                item = adapter.translate(text, batch)
                deadline_hit = deadline_hit or client.hit_deadline
            except Exception as exc:  # noqa: BLE001 - never leak text via the exception message
                log.warning("adapter failure: %s", type(exc).__name__)
                error_types.append("internal_error")
                continue
            if item.error_type:  # per-span adapters may still have partial successes
                error_types.append(item.error_type)
            for r in item.spans:
                ran_results += 1
                call_failed += r.reason == "call_failed"
                if r.accepted and r.en and not _FULLWIDTH.search(r.en):
                    translations[r.id] = r.en
                elif r.reason != "call_failed":
                    unusable += 1

        if spans and error_types and not translations and ran_results and call_failed == ran_results:
            # Every call failed for infrastructure reasons: report it instead of a silent no-op.
            raise ServiceError(error_types[0])
        if error_types and not deadline_hit:
            warnings.append("一部の箇所は変換できませんでした（通信エラーなど）。その部分は日本語のままです。")
        if skipped or deadline_hit:
            warnings.append("時間切れのため、一部の箇所を変換せず日本語のまま残しました。")
        if unusable:
            warnings.append(f"{unusable} 箇所は自然で安全な英語にできなかったため、日本語のままです。")
        if not spans:
            warnings.append("英語に置き換えられる箇所が見つかりませんでした（短すぎる、数字や英字を含む等）。")
        elif selection.actual_ratio < selection.target_ratio * 0.5 and translations:
            warnings.append("候補が少ないため、英語化率は目標を下回っています（目標は目安です）。")

        segments: list[Segment]
        try:
            segments = assemble(text, spans, translations)
        except AssertionError:
            log.error("original text was not preserved; returning the original unchanged")
            segments = assemble(text, [], {})
            translations = {}
            warnings.append("内部検証に失敗したため、原文をそのまま表示しています。")
        display = format_segments(text, segments)
        if not outside_preserved(text, display):
            display = format_segments(text, assemble(text, [], {}))
            warnings.append("内部検証に失敗したため、原文をそのまま表示しています。")

        accepted_chars = sum(counted_length(s.source) for s in display if s.kind == "en")
        total_chars = counted_length(text)
        return {
            "original": text,
            "model": self.settings.model,
            "segments": [{"kind": s.kind, "source": s.source,
                          "translation": s.text if s.kind == "en" else None,
                          "display": s.display, "start": s.start, "end": s.end} for s in display],
            "mixed_text": joined(display),
            "stats": {
                "requested_spans": len(spans),
                "accepted_spans": sum(1 for s in display if s.kind == "en"),
                "target_ratio": selection.target_ratio,
                "selected_ratio": round(selection.actual_ratio, 4),
                "actual_ratio": round(accepted_chars / total_chars, 4) if total_chars else 0.0,
                "elapsed_ms": int((self._clock() - started) * 1000),
            },
            "warnings": warnings,
        }
