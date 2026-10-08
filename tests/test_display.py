import random

import pytest

from backend.display import (format_english, format_segments, joined, outside_preserved,
                             previous_char)
from backend.spans import Span, assemble


@pytest.mark.parametrize("en,prev,nxt,expected", [
    ("go to the park.", "は", "。", "go to the park"),
    ("go to the park.", "は", "と", "go to the park"),
    ("go to the park.", "は", None, "go to the park."),
    ("go to the park.", "は", "\n", "go to the park."),
    ("go to the park.", "は", " ", "go to the park."),
    ("See Mr.", "は", "。", "See Mr."),
    ("etc.", "は", "。", "etc."),
    ("e.g.", "は", "。", "e.g."),
    ("vs.", "は", "。", "vs."),
    ("in the U.S.", "は", "。", "in the U.S."),
    ("at 5 p.m.", "は", "。", "at 5 p.m."),
    ("Ph.D.", "は", "。", "Ph.D."),
    ("by J.", "は", "。", "by J."),
    ("version 3.", "は", "。", "version 3."),
    ("wait...", "は", "。", "wait..."),
    ("wait…", "は", "。", "wait…"),
    ("what?", "は", "。", "what?"),
    ("go!", "は", "。", "go!"),
    ("a..", "は", "。", "a.."),
    ('said "go."', "は", "。", 'said "go."'),
    ("(see below.)", "は", "。", "(see below.)"),
    ("The park", "は", "で", "the park"),
    ("The park", None, "で", "The park"),
    ("The park", "\n", "で", "The park"),
    ("The park", "。", "で", "The park"),
    ("The park", "「", "で", "The park"),
    ("The park", " ", "で", "The park"),
    ("The park", "　", "で", "The park"),
    ("A walk", "は", "で", "a walk"),
    ("The Beatles", "は", "で", "The Beatles"),
    ("A Clockwork Orange", "は", "で", "A Clockwork Orange"),
    ("I", "は", "で", "I"),
    ("I'm tired", "は", "で", "I'm tired"),
    ("It's fine", "は", "で", "It's fine"),
    ("Tokyo", "は", "で", "Tokyo"),
    ("Monday", "は", "で", "Monday"),
    ("IT", "は", "で", "IT"),
    ("A/B test", "は", "で", "A/B test"),
    ("😀 The park", "は", "で", "😀 The park"),
    ("café.", "は", "。", "café"),
    ("", "は", "。", ""),
    (".", "は", "。", "."),
])
def test_format_english(en, prev, nxt, expected):
    assert format_english(en, prev, nxt) == expected


def test_previous_char_looks_through_closing_quote():
    text = "「行く。」The park"
    assert previous_char(text, text.index("The")) == "。"
    assert format_english("The park", previous_char(text, text.index("The")), None) == "The park"
    assert previous_char("abc", 0) is None
    assert previous_char("あいう", 2) == "い"


def test_japanese_segments_and_text_are_untouched():
    text = "彼は公園へ行きました。帰りました。"
    spans = [Span("s1", 2, 7, text[2:7])]
    segs = assemble(text, spans, {"s1": "The park."})
    disp = format_segments(text, segs)
    assert outside_preserved(text, disp)
    assert [d.display for d in disp if d.kind == "ja"] == [s.text for s in segs if s.kind == "ja"]
    en = [d for d in disp if d.kind == "en"][0]
    assert en.text == "The park." and en.display == "the park"
    assert joined(disp) == "彼は" + "the park" + text[7:]


def test_random_inputs_only_allowed_changes():
    rng = random.Random(1234)
    alphabet = list("abcAB .,!?…'\"()-3é😀‍") + ["The ", "A ", "I ", "Mr. ", "e.g."]
    for _ in range(3000):
        en = "".join(rng.choice(alphabet) for _ in range(rng.randint(0, 12)))
        prev = rng.choice([None, "は", "。", "\n", "「", " ", "、"])
        nxt = rng.choice([None, "。", "、", "と", "\n", " "])
        out = format_english(en, prev, nxt)
        allowed = {en, en[:-1], (en[:1].lower() + en[1:]), (en[:-1][:1].lower() + en[:-1][1:])}
        assert out in allowed
        if en.endswith(".."):
            assert out == en or out != en[:-1]


def test_format_failure_never_touches_assembled_text():
    text = "あいうえお"
    segs = assemble(text, [Span("s1", 0, 5, text)], {"s1": "Hello world."})
    disp = format_segments(text, segs)
    assert disp[0].text == "Hello world."  # validated translation is kept as-is
    assert disp[0].display == "Hello world."  # end of text: period stays
