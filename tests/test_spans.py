import pytest

from backend.spans import (
    Span,
    SpanError,
    assemble,
    check_spans,
    is_preserved,
    resolve_span,
    validate_translation,
)

def validate(source, en, outside=""):
    """Test helper: `outside` is required by the real API, so every test states it (here: default none)."""
    return validate_translation(source, en, outside=outside)


TEXT = "今日は天気がいいので、公園へ行きます。"


def _spans():
    return [resolve_span(TEXT, "s1", "天気がいい"), resolve_span(TEXT, "s2", "公園へ行きます")]


def test_assemble_preserves_source_for_any_output():
    spans = _spans()
    bad_outputs = [None, "", "  ", "てんき", "天気", "x" * 500, "line\nbreak", "ok\x00", "fine weather"]
    for a in bad_outputs:
        for b in bad_outputs:
            segs = assemble(TEXT, spans, {"s1": a, "s2": b})
            assert is_preserved(TEXT, segs)
            assert "".join(s.source for s in segs) == TEXT
            for s in segs:
                if s.kind == "ja":
                    assert s.text == s.source


def test_failed_span_falls_back_to_ja():
    segs = assemble(TEXT, _spans(), {"s1": "good weather", "s2": None})
    kinds = [(s.kind, s.text) for s in segs]
    assert ("en", "good weather") in kinds
    assert ("ja", "公園へ行きます") in kinds


def test_assemble_unknown_id_ignored():
    segs = assemble(TEXT, _spans(), {"zzz": "hello"})
    assert [s.kind for s in segs] == ["ja"] * len(segs)
    assert "".join(s.text for s in segs) == TEXT


def test_offsets_surrogate_pair():
    text = "𠮷野家で食べた"
    sp = resolve_span(text, "s1", "𠮷野家")
    assert (sp.start, sp.end) == (0, 3)
    assert text[sp.start:sp.end] == "𠮷野家"
    segs = assemble(text, [sp], {"s1": "Yoshinoya"})
    assert is_preserved(text, segs)


def test_offsets_combining_chars():
    text = "がんたん"  # か + 結合濁点
    with pytest.raises(SpanError):
        check_spans(text, [Span("s1", 0, 1, "か")])  # 結合文字を切断
    with pytest.raises(SpanError):
        check_spans(text, [Span("s1", 1, 3, "゙ん")])  # 結合文字で開始
    check_spans(text, [Span("s1", 0, 2, "が")])


def test_crlf_preserved():
    text = "一行目です。\r\n二行目です。"
    sp = resolve_span(text, "s1", "二行目です")
    segs = assemble(text, [sp], {"s1": "Second line"})
    assert "".join(s.source for s in segs) == text
    assert any("\r\n" in s.text for s in segs)
    with pytest.raises(SpanError):
        check_spans(text, [Span("s1", 0, 9, text[0:9])])


def test_resolve_occurrence_index():
    text = "猫と猫と猫"
    assert resolve_span(text, "a", "猫", 0).start == 0
    assert resolve_span(text, "a", "猫", 1).start == 2
    assert resolve_span(text, "a", "猫", 2).start == 4
    with pytest.raises(SpanError):
        resolve_span(text, "a", "猫", 3)


def test_resolve_ambiguous_without_occurrence():
    with pytest.raises(SpanError):
        resolve_span("猫と猫", "a", "猫")
    with pytest.raises(SpanError):
        resolve_span("猫", "a", "犬")


def test_overlap_rejected():
    text = "abcdefgh"
    with pytest.raises(SpanError):
        check_spans(text, [Span("a", 0, 4, "abcd"), Span("b", 3, 6, "def")])
    with pytest.raises(SpanError):
        check_spans(text, [Span("a", 0, 6, "abcdef"), Span("b", 2, 4, "cd")])
    with pytest.raises(SpanError):
        check_spans(text, [Span("a", 0, 2, "ab"), Span("a", 4, 6, "ef")])  # duplicate id
    check_spans(text, [Span("a", 0, 4, "abcd"), Span("b", 4, 6, "ef")])  # adjacent ok


@pytest.mark.parametrize(
    "en,reason",
    [
        ("", "empty"),
        ("   ", "empty"),
        ("a\nb", "newline"),
        ("a\tb", "control_char"),
        ("a‮b", "control_char"),
        ("ひらがな", "japanese_chars"),
        ("カタカナ", "japanese_chars"),
        ("ｶﾀｶﾅ", "japanese_chars"),
        ("ー", "japanese_chars"),
        ("天気", "japanese_chars"),
        ("𠮷", "japanese_chars"),
        ("x" * 101, "too_long"),
    ],
)
def test_validate_reasons(en, reason):
    assert validate("天気", en) == reason


def test_validate_length_boundary():
    assert validate("天気", "x" * 100) is None
    assert validate("天気", "x" * 101) == "too_long"
    src = "あ" * 20  # 8x = 160 > 100
    assert validate(src, "x" * 160) is None
    assert validate(src, "x" * 161) == "too_long"
    src = "あ" * 12  # 8x = 96 < 100: floor of 100 applies
    assert validate(src, "x" * 100) is None
    assert validate(src, "x" * 101) == "too_long"


def test_validate_accepts_previously_rejected_smoke_outputs():
    # Regression: smoke-test outputs that the old 4x limit wrongly rejected.
    assert validate(
        "お忙しいところ恐れ入りますが",
        "I apologize for the inconvenience, but given your busy schedule,") is None
    assert validate("𠮷野家で朝ごはんを食べて",
                                "I had breakfast at a traditional Japanese farmhouse.") is None


def test_validate_protected_tokens():
    src = "詳細は https://example.com/a?b=1 と info@example.com と 1,200 を見て"
    ok = "See https://example.com/a?b=1 and info@example.com and 1,200"
    assert validate(src, ok) is None
    assert validate(src, "See the site") == "protected_token_missing"
    assert validate("3個です", "three") == "protected_token_missing"
    assert validate("3個です", "3 items") is None


# --- #3 shared whitespace rule ------------------------------------------------

def test_normalize_translation_strips_only_outer_whitespace():
    from backend.spans import normalize_translation
    assert normalize_translation("  a b \n") == "a b"
    assert normalize_translation("　a ") == "a"


def test_validate_ignores_outer_whitespace_and_assemble_stores_stripped():
    assert validate("天気", "  nice weather \n") is None
    segs = assemble(TEXT, _spans(), {"s1": "  nice weather\n", "s2": None})
    assert [s.text for s in segs if s.kind == "en"] == ["nice weather"]
    assert validate("天気", "a\nb") == "newline"  # inner newline still rejected


# --- #4 protected tokens must not swallow adjacent Japanese -------------------

def test_protected_tokens_stop_at_japanese():
    from backend.spans import _protected_tokens
    assert "https://example.com/guide" in _protected_tokens("https://example.com/guideを見て")
    assert _protected_tokens("連絡はtaro@example.comまで") == ["taro@example.com"]
    assert _protected_tokens("価格は3.5ドルです。2026.") == ["3.5", "2026"]
    assert _protected_tokens("詳細はhttps://example.com/a.") == ["https://example.com/a"]


def test_url_and_email_adjacent_to_japanese_are_acceptable_when_kept():
    src = "連絡はtaro@example.comまで。詳細はhttps://example.com/guideを見て"
    assert validate(src, "Contact taro@example.com; see https://example.com/guide") is None
    assert validate(src, "Contact us; see the guide") == "protected_token_missing"


# --- #7 content copied in from outside the span / placeholders ----------------

OUT = "質問があれば support@example.com まで。最新は `git clone https://example.org/repo.git` で。"


@pytest.mark.parametrize("en", [
    "please contact us at support@example.com",       # email from the context
    "git clone https://example.org/repo.git",          # code from the context
    "see https://example.org/repo.git",                # URL from the context
])
def test_context_leak_rejected(en):
    assert validate("連絡してください", en, OUT) == "context_leak"
    assert validate("連絡してください", en) is None  # no context given: not checkable


def test_context_leak_not_triggered_by_source_tokens_or_unrelated_numbers():
    out = "3月15日の予約。\n1,200円です。"
    assert validate("お待ちしています", "We look forward to seeing you", out) is None
    assert validate("1,200円です", "It is 1,200 yen", out) is None   # token is in the source
    assert validate("お待ちしています", "Reserved for 15 guests", out) == "context_leak"
    assert validate("お待ちしています", "In 2015 we waited", out) is None  # 15 is not a whole number there


def test_assemble_rejects_leaked_context_and_keeps_japanese():
    text = "質問があれば support@example.com まで連絡してください。"
    spans = [resolve_span(text, "s1", "連絡してください")]
    segs = assemble(text, spans, {"s1": "please contact us at support@example.com"})
    assert all(s.kind == "ja" for s in segs)
    assert "".join(s.text for s in segs) == text
    assert is_preserved(text, segs)


@pytest.mark.parametrize("en", ["It can be obtained from [source/location].", "Hello {name}", "Dear <name>,",
                                "____", "...", "???", "-"])
def test_placeholder_rejected(en):
    assert validate("取得できます", en) == "placeholder"


def test_brackets_allowed_when_source_has_them():
    assert validate("「猫」[注]", "the cat [note]") is None


# --- shared preamble rule (previously Gemma-only) -----------------------------

@pytest.mark.parametrize("en", ["Here is the translation: nice", "Here's the English translation: nice",
                                "Sure, here is the translation: nice weather", "Certainly! Here you go: nice weather", "Translation: nice",
                                "English: nice", "```nice```"])
def test_preamble_rejected(en):
    assert validate("天気", en) == "preamble"


@pytest.mark.parametrize("en", ["Sure.", "Sure!", "Surely not", "Here is the place.", "Of course", "Of course, I'll go.",
                                "Certainly, that works for me.", "Sure, nice weather", "Sure, I can."])
def test_plain_translations_not_flagged_as_preamble(en):
    assert validate("はい", en) is None


@pytest.mark.parametrize("ch", ["\ud800", " ", " ", "​", "﻿", "­"])
def test_invisible_and_surrogate_chars_rejected(ch):
    assert validate("天気", f"nice{ch}weather") == "control_char"


def test_zwj_allowed():
    assert validate("家族", "family \U0001F468‍\U0001F469") is None


# --- review fixes: number boundaries ------------------------------------------

@pytest.mark.parametrize("src,en", [
    ("詳細は https://example.com/page2 を見て", "See https://example.com/page2"),
    ("連絡は taro2@example.com まで", "Contact taro2@example.com"),
    ("3Dプリンターです", "It is a 3D printer"),
    ("1990年代の話", "a story from the 1990s"),
    ("3位でした", "It was 3rd"),
    ("iPhone15を買った", "I bought an iPhone15"),
])
def test_numbers_touching_letters_are_kept(src, en):
    assert validate(src, en) is None


def test_changed_numbers_are_still_rejected():
    assert validate("3位でした", "It was third") == "protected_token_missing"
    assert validate("1990年代", "the 2000s") == "protected_token_missing"
    assert validate("1990年代", "the 19905") == "protected_token_missing"


def test_context_leak_number_boundaries():
    out = "3月のこと。\n"
    assert validate("お待ちしています", "It costs 3,000 yen", out) is None       # not the bare 3
    assert validate("お待ちしています", "Version 3.5 is out", out) is None
    assert validate("お待ちしています", "Back in March 3", out) == "context_leak"
    assert validate("お待ちしています", "See you on the 3rd", out) == "context_leak"


# --- `outside` must be explicit: forgetting it must fail, not silently skip the leak check ----

def test_outside_is_required_and_keyword_only():
    with pytest.raises(TypeError):
        validate_translation("連絡してください", "please contact support@example.com")
    with pytest.raises(TypeError):
        validate_translation("連絡してください", "x", "support@example.com")   # positional is refused too
    assert validate_translation("連絡してください", "please contact support@example.com", outside="") is None
    assert validate_translation("連絡してください", "please contact support@example.com",
                                outside="support@example.com") == "context_leak"


def test_adapters_and_assemble_always_pass_the_surrounding_text(monkeypatch):
    """If any production caller dropped `outside`, a context leak would be accepted again."""
    import backend.spans as spans_mod
    from backend.llm.qwen_adapter import QwenAdapter
    from backend.llm.translategemma_adapter import TranslateGemmaAdapter

    text = "質問があれば support@example.com まで連絡してください。"
    sp = [resolve_span(text, "s1", "連絡してください")]
    leak = "please contact us at support@example.com"

    class Q:
        def chat(self, payload):
            import json
            return {"message": {"content": json.dumps({"items": [{"id": "s1", "en": leak}]})}}, 1.0

    class G:
        def chat(self, payload):
            return {"message": {"content": leak}}, 1.0

    assert QwenAdapter(Q()).translate(text, sp).spans[0].reason == "context_leak"
    assert TranslateGemmaAdapter(G()).translate(text, sp).spans[0].reason == "context_leak"
    assert all(s.kind == "ja" for s in assemble(text, sp, {"s1": leak}))
