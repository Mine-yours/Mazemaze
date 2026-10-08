from dataclasses import dataclass, field
from typing import Literal, Protocol

from backend.spans import Span

ErrorType = Literal[
    "ollama_unreachable", "model_not_found", "timeout", "http_error", "invalid_response",
    "internal_error",  # unexpected exception inside an adapter (recorded by run_compare)
]


class OllamaError(Exception):
    """Message must never contain request/response bodies."""

    def __init__(self, error_type: ErrorType, message: str = ""):
        super().__init__(message or error_type)
        self.error_type = error_type


@dataclass
class SpanResult:
    id: str
    source: str
    raw: str | None
    en: str | None
    accepted: bool
    reason: str | None


@dataclass
class ItemResult:
    model: str
    spans: list[SpanResult]
    format_compliant: bool
    error_type: ErrorType | None
    latency_ms: float  # sum of successful calls only
    ollama_stats: dict = field(default_factory=dict)  # ns sums
    raw_responses: list[str] = field(default_factory=list)
    thinking_present: bool = False


_STAT_KEYS = ("total_duration", "load_duration", "eval_count", "eval_duration")


def add_stats(stats: dict, resp: dict) -> None:
    for k in _STAT_KEYS:
        v = resp.get(k)
        if isinstance(v, int) and not isinstance(v, bool):
            stats[k] = stats.get(k, 0) + v


class Adapter(Protocol):
    name: str
    context_mode: str  # "full_text" | "none"
    prompt_sha256: str

    def options(self) -> dict: ...

    def translate(self, text: str, spans: list[Span]) -> ItemResult: ...
