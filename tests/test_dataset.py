import json
import unicodedata
from collections import Counter

import pytest

from backend.spans import SpanError, check_spans
from eval.dataset import DEFAULT_PATH, load_dataset

EXPECTED = {"keigo": 4, "colloquial": 4, "idiom": 4, "complex": 4,
            "proper_noun": 3, "url_email_number": 3, "unicode": 4, "injection": 4}


@pytest.fixture(scope="module")
def items():
    return load_dataset()


def test_dataset_integrity(items):
    assert len(items) == 30
    assert len({i.id for i in items}) == 30
    assert Counter(i.category for i in items) == EXPECTED
    for i in items:
        assert 1 <= len(i.spans) <= 3
        assert "\n" not in i.text and "\r" not in i.text
        check_spans(i.text, i.spans)
        assert set(i.reference_en) == {s.id for s in i.spans}
        assert i.text == unicodedata.normalize("NFC", i.text) or i.category == "unicode"


def test_dataset_unicode_raw(items):
    text = "".join(i.text for i in items if i.category == "unicode")
    assert "𠮷" in text                      # surrogate pair
    assert "゙" in text or "́" in text  # not folded by NFC
    assert "‍" in text                  # ZWJ emoji
    assert "Ａ" in text and "１" in text    # fullwidth


def test_smoke_order(items):
    assert [i.category for i in items[:3]] == ["keigo", "unicode", "injection"]
    assert "𠮷" in items[1].text


def test_injection_modes_and_canary_placement(items):
    inj = [i for i in items if i.category == "injection"]
    assert {i.injection_mode for i in inj} == {"span", "context"}
    assert sum(i.injection_mode == "span" for i in inj) == 2 and sum(i.injection_mode == "context" for i in inj) == 2
    for i in items:
        if i.category != "injection":
            assert i.injection_canary is None and i.injection_mode is None
    for i in inj:
        assert i.injection_canary in i.text
        in_span = any(i.injection_canary in s.source for s in i.spans)
        # span mode: every model sees the instruction; context mode: only outside the spans
        assert in_span == (i.injection_mode == "span")


def test_canary_and_mode_must_be_set_together(tmp_path):
    p = tmp_path / "d.jsonl"
    row = {"id": "a", "category": "x", "text": "猫と犬", "spans": [{"id": "s1", "source": "猫"}],
           "injection_canary": "PWNED"}
    p.write_text(json.dumps(row, ensure_ascii=False) + "\n", encoding="utf-8")
    with pytest.raises(ValueError, match="together"):
        load_dataset(p)


def test_bad_span_reports_line_number(tmp_path):
    p = tmp_path / "d.jsonl"
    good = {"id": "a", "category": "x", "text": "猫と犬", "spans": [{"id": "s1", "source": "猫"}]}
    bad = {"id": "b", "category": "x", "text": "猫と犬", "spans": [{"id": "s1", "source": "鳥"}]}
    p.write_text(json.dumps(good, ensure_ascii=False) + "\n" + json.dumps(bad, ensure_ascii=False) + "\n",
                 encoding="utf-8")
    with pytest.raises(ValueError, match=r":2:"):
        load_dataset(p)


def test_default_path_exists():
    assert DEFAULT_PATH.is_file()
