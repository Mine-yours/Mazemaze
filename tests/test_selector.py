import random
import subprocess
import sys

import pytest

from backend.selector import candidates, counted_length, select_spans
from backend.spans import check_spans
from tests.api_helpers import SAMPLE


def test_deterministic_and_ids_in_text_order():
    a = select_spans(SAMPLE, 0.3, "phrase")
    b = select_spans(SAMPLE, 0.3, "phrase")
    assert a == b
    assert [s.id for s in a.spans] == [f"s{i}" for i in range(1, len(a.spans) + 1)]
    assert [s.start for s in a.spans] == sorted(s.start for s in a.spans)
    check_spans(SAMPLE, a.spans)


def test_deterministic_across_hash_seeds():
    code = ("from backend.selector import select_spans;from tests.api_helpers import SAMPLE;"
            "print([(s.start,s.source) for s in select_spans(SAMPLE,0.3,'phrase').spans])")
    outs = {subprocess.run([sys.executable, "-c", code], capture_output=True, text=True,
                           env={"PYTHONHASHSEED": h, "PATH": ""}, check=True).stdout for h in ("0", "1")}
    assert len(outs) == 1


def test_seed_changes_choice():
    text = "".join(f"毎日{c}を食べて元気に過ごしています。" for c in "あいうえおかきくけこさしすせそ")
    picks = {tuple(s.start for s in select_spans(text, 0.2, "phrase", seed=i).spans) for i in range(5)}
    assert len(picks) > 1


@pytest.mark.parametrize("unit", ["phrase", "sentence"])
def test_spans_never_contain_punctuation_or_newlines(unit):
    for s in select_spans(SAMPLE, 0.7, unit).spans:
        forbidden = "\n\r。！？" + ("、" if unit == "phrase" else "")
        assert not set(forbidden) & set(s.source)
        assert s.source[0] not in "「」" and s.source[-1] not in "「」"
        assert s.source == s.source.strip()


def test_excludes_protected_content():
    text = "詳しくは https://example.com/a?x=1 を見てください。連絡先は a@b.com です。価格は１２００円です。コードは `print(1)` を使います。"
    assert candidates(text) == []
    assert candidates("Hello world") == []


def test_brackets_not_split():
    text = "彼は「行く、よ」と言った。「行く。」と彼は言った。"
    for s in candidates(text):
        assert s.source.count("「") == s.source.count("」")
    text2 = "「今日は晴れていますね。」と彼女は言いました。"
    srcs = [s.source for s in candidates(text2)]
    assert "今日は晴れていますね" in srcs


def test_length_bounds():
    four = "あいうえ。"
    assert [s.source for s in candidates(four)] == ["あいうえ"]
    assert candidates("あいう。") == []
    assert candidates("あ" * 60 + "。")
    assert not candidates("あ" * 61 + "。", "phrase")
    assert candidates("あ" * 120, "sentence")
    assert not candidates("あ" * 121, "sentence")


def test_ratio_denominator_and_target():
    assert counted_length("あいうえお。かきくけこ。 \n") == 10
    text = "あいうえお。かきくけこ。さしすせそ。たちつてと。"
    sel = select_spans(text, 0.5, "sentence")
    assert sel.actual_ratio == pytest.approx(sum(len(s.source) for s in sel.spans) / 20)
    assert 0.25 <= sel.actual_ratio <= 0.75


def test_edge_inputs():
    for bad in ("", "。。。", "😀😀😀", " \n "):
        assert select_spans(bad, 0.3).spans == []
    with pytest.raises(ValueError):
        select_spans("あいうえお。", 0.05)
    with pytest.raises(ValueError):
        select_spans("あいうえお。", 0.8)
    with pytest.raises(ValueError):
        select_spans("あいうえお。", 0.3, "word")  # type: ignore[arg-type]


def test_max_spans():
    text = "".join(f"今日は{c}日で、とても楽しい一日でした。" for c in "月火水木金土日")
    assert len(select_spans(text, 0.7, "phrase", max_spans=3).spans) <= 3


def test_random_text_always_valid_spans():
    rng = random.Random(7)
    pool = list("あいうえお漢字日本語、。！？\n「」 abc123😀゙") 
    for _ in range(500):
        t = "".join(rng.choice(pool) for _ in range(rng.randint(0, 80)))
        sel = select_spans(t, rng.choice([0.1, 0.3, 0.7]), rng.choice(["phrase", "sentence"]))
        check_spans(t, sel.spans)
        assert all(t[s.start:s.end] == s.source for s in sel.spans)
