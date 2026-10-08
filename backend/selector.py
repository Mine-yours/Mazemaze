"""App-side span selection. The LLM never decides what to replace (CLAUDE.md §5).

Candidates are whole clauses or sentences cut at Japanese punctuation, so particles and
conjugations stay intact and punctuation always stays Japanese. Selection is deterministic for
the same text and settings.
"""
import hashlib
import re
import unicodedata
from dataclasses import dataclass
from typing import Literal

from backend.spans import Span, check_spans

Unit = Literal["phrase", "sentence"]

MIN_RATIO, MAX_RATIO, DEFAULT_RATIO = 0.10, 0.70, 0.30
MIN_CANDIDATE_CHARS = 4
MAX_CANDIDATE_CHARS = {"phrase": 60, "sentence": 120}

_SENTENCE_END = "。！？!?｡"
_CLAUSE_END = "、，,"
_CLOSERS = "」』）)】］｝}〉》”’\"'"
_OPENERS = "「『（(【［｛{〈《“‘"
# ASCII-only on purpose (see backend/spans.py): Japanese text next to a URL is not part of it.
_PROTECTED = re.compile(
    r"https?://|[A-Za-z0-9._%+-]+@[A-Za-z0-9-]+\.|[0-9０-９]|`|www\.|[A-Za-zＡ-Ｚａ-ｚ]", re.IGNORECASE)
_IGNORED_FOR_RATIO = re.compile(
    r"[\s　。、，．,.！!？?：:；;「」『』（）()【】［］｛｝{}〈〉《》“”‘’\"'…・―ー〜~\-—/]")


@dataclass(frozen=True)
class Selection:
    spans: list[Span]
    candidates: int
    target_ratio: float
    actual_ratio: float


def counted_length(s: str) -> int:
    """Characters that count toward the ratio: everything except whitespace and punctuation."""
    return len(_IGNORED_FOR_RATIO.sub("", s))


def _trim(text: str, start: int, end: int) -> tuple[int, int]:
    """Trim whitespace, openers, closers and trailing punctuation off a chunk."""
    junk = _SENTENCE_END + _CLAUSE_END + _CLOSERS + _OPENERS + " \t　"
    while start < end and text[start] in junk:
        start += 1
    while end > start and text[end - 1] in junk:
        end -= 1
    return start, end


def _chunks(text: str, unit: Unit) -> list[tuple[int, int]]:
    """Raw (start, end) pieces: sentences, further split at clause marks for `phrase`."""
    enders = _SENTENCE_END + ("" if unit == "sentence" else _CLAUSE_END)
    chunks: list[tuple[int, int]] = []
    start = 0
    n = len(text)
    i = 0
    while i < n:
        ch = text[i]
        if ch in "\r\n\x0b\x0c\x85\u2028\u2029":
            chunks.append((start, i))
            start = i + 1
        elif ch in enders:
            end = i + 1
            while end < n and text[end] in _CLOSERS:
                end += 1
            chunks.append((start, end))
            start = i = end
            continue
        i += 1
    chunks.append((start, n))
    return chunks


def _joins_neighbour(ch: str) -> bool:
    return unicodedata.category(ch).startswith("M") or ch in "\u200d\ufe0e\ufe0f"


def candidates(text: str, unit: Unit = "phrase") -> list[Span]:
    out: list[Span] = []
    limit = MAX_CANDIDATE_CHARS[unit]
    for raw_start, raw_end in _chunks(text, unit):
        start, end = _trim(text, raw_start, raw_end)
        if end <= start:
            continue
        if _joins_neighbour(text[start]) or (end < len(text) and _joins_neighbour(text[end])):
            continue  # would split a combining sequence
        piece = text[start:end]
        if len(piece) > limit or counted_length(piece) < MIN_CANDIDATE_CHARS:
            continue
        if _PROTECTED.search(piece):
            continue
        # Unbalanced brackets would cut a quotation in half.
        if (sum(piece.count(c) for c in _OPENERS) != sum(piece.count(c) for c in _CLOSERS)
                and any(c in piece for c in _OPENERS + _CLOSERS)):
            continue
        out.append(Span(id=f"s{len(out) + 1}", start=start, end=end, source=piece))
    return out


def _rank(seed: int, span: Span) -> str:
    return hashlib.sha256(f"{seed}|{span.start}|{span.source}".encode("utf-8")).hexdigest()


def select_spans(text: str, ratio: float = DEFAULT_RATIO, unit: Unit = "phrase",
                 seed: int = 0, max_spans: int | None = None) -> Selection:
    """Pick non-overlapping spans until their length reaches `ratio` of the text (a target, not
    a guarantee). Ids are renumbered in text order after selection."""
    if unit not in MAX_CANDIDATE_CHARS:
        raise ValueError("unknown unit")
    if not MIN_RATIO <= ratio <= MAX_RATIO:
        raise ValueError("ratio out of range")
    total = counted_length(text)
    cands = candidates(text, unit)
    if total == 0 or not cands:
        return Selection([], len(cands), ratio, 0.0)

    target = ratio * total
    chosen: list[Span] = []
    got = 0
    for span in sorted(cands, key=lambda s: _rank(seed, s)):
        if got >= target or (max_spans is not None and len(chosen) >= max_spans):
            break
        length = counted_length(span.source)
        # Stop short of overshooting by more than half a candidate (keeps results near the target).
        if got > 0 and got + length - target > length / 2:
            continue
        chosen.append(span)
        got += length

    ordered = sorted(chosen, key=lambda s: s.start)
    spans = [Span(id=f"s{i}", start=s.start, end=s.end, source=s.source)
             for i, s in enumerate(ordered, 1)]
    check_spans(text, spans)
    return Selection(spans, len(cands), ratio, got / total)
