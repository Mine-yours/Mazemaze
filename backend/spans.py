"""Span resolution, translation validation and assembly.

Offsets are Python code points. Text is never normalized. Anything that fails
validation stays Japanese, so the original text is always reconstructible.
"""
import re
import unicodedata
from dataclasses import dataclass
from typing import Literal


class SpanError(ValueError):
    pass


@dataclass(frozen=True)
class Span:
    id: str
    start: int
    end: int
    source: str  # text[start:end] == source


@dataclass(frozen=True)
class Segment:
    kind: Literal["ja", "en"]
    text: str
    source: str
    start: int
    end: int


def resolve_span(text: str, id: str, source: str, occurrence: int | None = None) -> Span:
    if not source:
        raise SpanError(f"{id}: empty source")
    positions = []
    pos = text.find(source)
    while pos != -1:
        positions.append(pos)
        pos = text.find(source, pos + len(source))
    if not positions:
        raise SpanError(f"{id}: source not found in text")
    if occurrence is None:
        if len(positions) > 1:
            raise SpanError(f"{id}: source appears {len(positions)} times; specify occurrence")
        start = positions[0]
    else:
        if not 0 <= occurrence < len(positions):
            raise SpanError(f"{id}: occurrence {occurrence} out of range")
        start = positions[occurrence]
    return Span(id=id, start=start, end=start + len(source), source=source)


def check_spans(text: str, spans: list[Span]) -> None:
    seen: set[str] = set()
    for s in spans:
        if s.id in seen:
            raise SpanError(f"{s.id}: duplicate id")
        seen.add(s.id)
        if s.start >= s.end:
            raise SpanError(f"{s.id}: empty span")
        if text[s.start:s.end] != s.source:
            raise SpanError(f"{s.id}: source does not match text[start:end]")
        if "\r" in s.source or "\n" in s.source:
            raise SpanError(f"{s.id}: span contains a newline")
        if unicodedata.combining(text[s.start]):
            raise SpanError(f"{s.id}: span starts with a combining character")
        if s.end < len(text) and unicodedata.combining(text[s.end]):
            raise SpanError(f"{s.id}: span splits a combining sequence")
    ordered = sorted(spans, key=lambda s: s.start)
    for a, b in zip(ordered, ordered[1:]):
        if b.start < a.end:
            raise SpanError(f"{a.id}/{b.id}: overlapping spans")


# ASCII-only on purpose: Python's \w and negated classes also match Japanese,
# which made adjacent text (e.g. "...com" + "まで") part of the protected token.
_URL = re.compile(r"https?://[A-Za-z0-9._~:/?#\[\]@!$&'()*+,;=%-]+")
_EMAIL = re.compile(r"[A-Za-z0-9._%+-]+@[A-Za-z0-9-]+(?:\.[A-Za-z0-9-]+)+")
_NUMBER = re.compile(r"[0-9][0-9,.]*")
_CODE = re.compile(r"`([^`\n]{3,})`")
_NUMERIC_TOKEN = re.compile(r"[0-9][0-9,.]*")
_JA_RANGES = (
    (0x3040, 0x309F),
    (0x30A0, 0x30FF),
    (0xFF66, 0xFF9F),
    (0x3400, 0x4DBF),
    (0x4E00, 0x9FFF),
    (0x20000, 0x3134F),
)
_BIDI = set(range(0x202A, 0x202F)) | set(range(0x2066, 0x206A))
_PREAMBLE = re.compile(
    r"^(?:here(?:'s|\s+is|\s+are)\s+(?:the|my|your|an?)?\s*(?:english\s+)?translations?\b"
    r"|(?:sure|certainly|of\s+course)[,!:]\s*(?:here|this\s+is|the\s+translation|translation)\b"
    r"|(?:english\s+)?translation\s*:"
    r"|english\s*:)",
    re.IGNORECASE,
)
_PLACEHOLDERS = (
    ("[", re.compile(r"\[[^\[\]]{1,60}\]")),
    ("{", re.compile(r"\{[^{}]{0,60}\}")),
    ("<", re.compile(r"<[^<>]{1,60}>")),
)
_BLANK_RUN = re.compile(r"_{3,}")


def normalize_translation(en: str) -> str:
    """Shared by every adapter and by assemble: only surrounding whitespace is removed."""
    return en.strip()


def looks_like_preamble(en: str) -> bool:
    """Chatty lead-in ("Here is the translation:", "Sure, ...") or a code fence.

    Deliberately narrow: replies that merely start with "Sure," / "Of course," are legitimate
    translations of Japanese dialogue. Only "Sure, here ..." style lead-ins are rejected.
    """
    s = normalize_translation(en)
    return "```" in s or bool(_PREAMBLE.match(s))


def _trim(token: str) -> str:
    return token.rstrip(".,;:!?)]'\"")


def _protected_tokens(source: str) -> list[str]:
    tokens = []
    for rx in (_URL, _EMAIL, _NUMBER):
        tokens += [t for t in (_trim(m) for m in rx.findall(source)) if t]
    return tokens


def _contains_token(en: str, token: str) -> bool:
    if _NUMERIC_TOKEN.fullmatch(token):
        # Whole number only: "15" is not inside "2015" or "15.5", but may touch letters
        # ("3D", "1990s", "page2" are fine).
        return re.search(rf"(?<![0-9])(?<![0-9][.,]){re.escape(token)}(?![0-9])(?![.,][0-9])", en) is not None
    return token in en


def outside_text(text: str, span: Span) -> str:
    """Everything except the span, used to detect content copied in from the context."""
    return text[:span.start] + "\n" + text[span.end:]


def _context_tokens(outside: str, source: str) -> list[str]:
    tokens = _protected_tokens(outside) + [m.strip() for m in _CODE.findall(outside)]
    return [t for t in tokens if t and t not in source]


def _has_placeholder(source: str, en: str) -> bool:
    if not any(ch.isalnum() for ch in en) or _BLANK_RUN.search(en):
        return True
    return any(opener not in source and rx.search(en) for opener, rx in _PLACEHOLDERS)


def validate_translation(source: str, en: str, *, outside: str) -> str | None:
    """Return None if acceptable, otherwise a reason code.

    `outside` (keyword-only, required) is the text around the span (see `outside_text`). It has no
    default on purpose: a forgotten argument must fail loudly (TypeError) instead of silently
    disabling the context-leak check. Pass `outside=""` only when there is genuinely no
    surrounding text. Limits: this only catches mechanical problems
    (format, language, copied-in URLs/emails/numbers/code, bracket placeholders). It cannot
    tell whether the English is semantically correct, nor detect paraphrased duplication.
    """
    if not isinstance(en, str):
        return "empty"
    en = normalize_translation(en)
    if not en:
        return "empty"
    if "\n" in en or "\r" in en:
        return "newline"
    for ch in en:
        cat = unicodedata.category(ch)
        if (cat in ("Cc", "Cs", "Zl", "Zp") or (cat == "Cf" and ch != "‍")
                or ord(ch) in _BIDI):
            return "control_char"
    for ch in en:
        cp = ord(ch)
        if any(lo <= cp <= hi for lo, hi in _JA_RANGES):
            return "japanese_chars"
    if len(en) > max(8 * len(source), 100):
        return "too_long"
    if looks_like_preamble(en):
        return "preamble"
    if _has_placeholder(source, en):
        return "placeholder"
    for token in _protected_tokens(source):
        if not _contains_token(en, token):
            return "protected_token_missing"
    if any(_contains_token(en, t) for t in _context_tokens(outside, source)):
        return "context_leak"
    return None


def assemble(text: str, spans: list[Span], translations: dict[str, str | None]) -> list[Segment]:
    check_spans(text, spans)
    segments: list[Segment] = []
    pos = 0

    def add_ja(start: int, end: int) -> None:
        if end > start:
            chunk = text[start:end]
            segments.append(Segment("ja", chunk, chunk, start, end))

    for s in sorted(spans, key=lambda s: s.start):
        add_ja(pos, s.start)
        en = translations.get(s.id)
        if isinstance(en, str):
            en = normalize_translation(en)
        if en is not None and validate_translation(s.source, en, outside=outside_text(text, s)) is None:
            segments.append(Segment("en", en, s.source, s.start, s.end))
        else:
            add_ja(s.start, s.end)
        pos = s.end
    add_ja(pos, len(text))
    if not is_preserved(text, segments):
        raise AssertionError("original text not preserved")
    return segments


def is_preserved(text: str, segments: list[Segment]) -> bool:
    if "".join(s.source for s in segments) != text:
        return False
    pos = 0
    for s in segments:
        if s.start != pos or text[s.start:s.end] != s.source:
            return False
        if s.kind == "ja" and s.text != s.source:
            return False
        pos = s.end
    return pos == len(text)
