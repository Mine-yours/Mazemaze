"""TranslateGemma adapter: official translation prompt, one plain-text call per span."""
import hashlib

from backend.llm.base import ItemResult, OllamaError, SpanResult, add_stats
from backend.spans import (Span, check_spans, looks_like_preamble, normalize_translation,
                           outside_text, validate_translation)

MODEL = "translategemma:12b"

PROMPT_TEMPLATE = (
    "You are a professional Japanese (ja) to English (en) translator. "
    "Your goal is to accurately convey the meaning and nuances of the original Japanese text "
    "while adhering to English grammar, vocabulary, and cultural sensitivities. "
    "Produce only the English translation, without any additional explanations or commentary. "
    "Please translate the following Japanese text into English:\n\n\n{TEXT}"
)

OPTIONS = {"temperature": 0, "seed": 42, "num_ctx": 2048, "num_predict": 256}

def build_prompt(source: str) -> str:
    return PROMPT_TEMPLATE.replace("{TEXT}", source)


def _format_violation(raw: str) -> bool:
    s = normalize_translation(raw)
    return not s or "\n" in s or "\r" in s or looks_like_preamble(s)


class TranslateGemmaAdapter:
    context_mode = "none"
    prompt_sha256 = hashlib.sha256(PROMPT_TEMPLATE.encode("utf-8")).hexdigest()

    def __init__(self, client, model: str = MODEL):
        self.client = client
        self.name = model

    def options(self) -> dict:
        return dict(OPTIONS)

    def build_payload(self, source: str) -> dict:
        return {
            "model": self.name,
            "stream": False,
            "keep_alive": "5m",
            "options": dict(OPTIONS),
            "messages": [{"role": "user", "content": build_prompt(source)}],
        }

    def translate(self, text: str, spans: list[Span]) -> ItemResult:
        check_spans(text, spans)
        results: list[SpanResult] = []
        raws: list[str] = []
        stats: dict = {}
        latency = 0.0
        error_type = None
        compliant = True
        for s in spans:
            try:
                resp, ms = self.client.chat(self.build_payload(s.source))
            except OllamaError as e:
                error_type = error_type or e.error_type
                compliant = False
                results.append(SpanResult(s.id, s.source, None, None, False, "call_failed"))
                continue
            latency += ms
            add_stats(stats, resp)
            message = resp.get("message") if isinstance(resp.get("message"), dict) else {}
            raw = message.get("content")
            raw = raw if isinstance(raw, str) else ""
            raws.append(raw)
            if _format_violation(raw):
                compliant = False
                results.append(SpanResult(s.id, s.source, raw, None, False, "format_violation"))
                continue
            en = normalize_translation(raw)
            reason = validate_translation(s.source, en, outside=outside_text(text, s))
            results.append(SpanResult(s.id, s.source, raw, None if reason else en, reason is None, reason))
        return ItemResult(model=self.name, spans=results, format_compliant=compliant,
                          error_type=error_type, latency_ms=latency, ollama_stats=stats,
                          raw_responses=raws, thinking_present=False)
