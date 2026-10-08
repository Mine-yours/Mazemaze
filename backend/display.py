"""Display formatting for accepted English spans.

Only the `display` string of English segments is touched, and only its first letter and its final
period. Japanese segments and the validated translation (`text`) are never modified, so
`assemble()` / `validate_translation()` and stored evaluation results stay compatible.
Anything uncertain is left as the model wrote it.
"""
import re
from dataclasses import dataclass
from typing import Literal

from backend.spans import Segment

# Never lowercase these: pronoun "I" and its contractions are always capitalized in English.
# The allow-list below only contains words that cannot be proper nouns or acronyms.
_LOWERABLE_FIRST_WORDS = frozenset({
    "the", "a", "an", "he", "she", "they", "we", "it", "this", "that", "these", "those",
    "there", "here", "my", "your", "his", "her", "our", "their", "its", "and", "but", "so",
    "then", "if", "when", "while", "because", "since", "as", "after", "before", "although",
    "though", "unless", "until", "once", "also", "just", "even", "still", "yet", "now",
    "what", "why", "how", "who", "where", "which", "let", "do", "does", "did", "is", "are",
    "was", "were", "can", "could", "should", "would", "to", "for", "in", "on", "at", "with",
    "from", "by", "of", "about", "without", "into", "over", "under", "every", "each", "all",
    "some", "any", "no", "not", "maybe", "perhaps",
})
_FIRST_WORD = re.compile(r"[A-Za-z]+(?=\s|$|[,;:])")  # whole plain word: not "It's", "A/B", "U.S."
_ABBREVIATIONS = frozenset({
    "mr", "mrs", "ms", "dr", "prof", "sr", "jr", "st", "vs", "etc", "inc", "ltd", "co", "no",
    "approx", "dept", "est", "fig", "vol", "e.g", "i.e", "a.m", "p.m", "u.s", "u.k",
})
# A character that, when it directly precedes the span, means the span starts a new sentence or
# a quotation: keep its capital. Whitespace also counts (the surrounding text is unclear).
_SENTENCE_START_PREV = set("。！？!?｡「『（([“\"‘'〈《【［｛{<\n\r\t 　")


@dataclass(frozen=True)
class DisplaySegment:
    kind: Literal["ja", "en"]
    text: str      # `assemble()` output: validated translation (en) or the original (ja)
    display: str   # what the UI shows and copies; equals `text` unless formatting applied
    source: str    # original Japanese
    start: int
    end: int


def _strip_final_period(en: str, next_char: str | None) -> str:
    """Remove one sentence-final "." only when Japanese text continues right after the span."""
    if next_char is None or next_char.isspace() or not en.endswith("."):
        return en
    if en.endswith(("..", "…")):
        return en
    body = en[:-1]
    if not body or not body[-1].isalpha():  # "3.", "?." and similar stay as they are
        return en
    last_word = re.split(r"[\s(\"'“‘]", body)[-1]
    if "." in last_word:  # U.S., e.g, Ph.D, www.example
        return en
    if len(last_word) == 1 and last_word.isupper():  # initials: "J."
        return en
    if last_word.lower() in _ABBREVIATIONS:
        return en
    return body


def _lower_first_letter(en: str, prev_char: str | None) -> str:
    if prev_char is None or prev_char in _SENTENCE_START_PREV:
        return en
    m = _FIRST_WORD.match(en)
    if not m:
        return en
    rest = en[m.end():].split()
    if rest and rest[0][0].isupper():  # "The Beatles", "A Clockwork Orange": a title or name
        return en
    word = m.group(0)
    if word[0].isupper() and (len(word) == 1 or word[1:].islower()) and word.lower() in _LOWERABLE_FIRST_WORDS:
        return word[0].lower() + en[1:]
    return en


def format_english(en: str, prev_char: str | None, next_char: str | None) -> str:
    """Format one English span given the original characters right before and after it.

    `prev_char` should come from `previous_char()` so that a closing quote after a sentence end
    still counts as a sentence start.
    """
    out = _lower_first_letter(_strip_final_period(en, next_char), prev_char)
    # Safety net: only the first letter's case and one final "." may differ.
    if not out or out.lower() not in (en.lower(), en[:-1].lower()):
        return en
    return out


_CLOSERS = set("」』）)】］｝}〉》”’\"'")


def previous_char(text: str, start: int) -> str | None:
    """The character before `start`; looks through closing quotes/brackets to a sentence end."""
    if start <= 0:
        return None
    i = start - 1
    while i > 0 and text[i] in _CLOSERS:
        i -= 1
    if text[i] in "。！？!?｡":
        return text[i]
    return text[start - 1]


def format_segments(text: str, segments: list[Segment]) -> list[DisplaySegment]:
    """Build display segments for `assemble()` output. Japanese segments are copied verbatim."""
    result: list[DisplaySegment] = []
    for seg in segments:
        if seg.kind == "en":
            prev_char = previous_char(text, seg.start)
            next_char = text[seg.end] if seg.end < len(text) else None
            display = format_english(seg.text, prev_char, next_char)
        else:
            display = seg.text
        result.append(DisplaySegment(seg.kind, seg.text, display, seg.source, seg.start, seg.end))
    return result


def joined(display_segments: list[DisplaySegment]) -> str:
    """The mixed text the UI shows and copies (no characters are inserted between segments)."""
    return "".join(s.display for s in display_segments)


def outside_preserved(text: str, display_segments: list[DisplaySegment]) -> bool:
    """True when every Japanese segment is the exact original slice and coverage is contiguous."""
    pos = 0
    for s in display_segments:
        if s.start != pos or text[s.start:s.end] != s.source:
            return False
        if s.kind == "ja" and not (s.text == s.source == s.display):
            return False
        pos = s.end
    return pos == len(text)
