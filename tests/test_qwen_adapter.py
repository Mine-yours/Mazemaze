import hashlib
import json

import pytest

from backend.llm import qwen_adapter
from backend.llm.base import OllamaError
from backend.llm.ollama_client import OllamaClient
from backend.llm.qwen_adapter import QwenAdapter
from backend.spans import assemble, is_preserved, resolve_span

TEXT = "今日は天気がいいので、公園へ行きます。https://example.com も見てね。"
SPANS = [
    resolve_span(TEXT, "s1", "天気がいい"),
    resolve_span(TEXT, "s2", "公園へ行きます"),
    resolve_span(TEXT, "s3", "見てね"),
]


class FakeClient:
    def __init__(self, content=None, resp=None, exc=None):
        self.payloads = []
        self.content, self.resp, self.exc = content, resp, exc

    def chat(self, payload):
        self.payloads.append(payload)
        if self.exc:
            raise self.exc
        resp = self.resp or {"message": {"content": self.content}, "total_duration": 5, "eval_count": 2}
        return resp, 12.5


def items(*pairs):
    return json.dumps({"items": [{"id": i, "en": e} for i, e in pairs]})


GOOD = items(("s1", "nice weather"), ("s2", "go to the park"), ("s3", "take a look"))


def run(content=None, **kw):
    client = FakeClient(content=content, **kw)
    return QwenAdapter(client).translate(TEXT, SPANS), client


def test_request_payload():
    res, client = run(GOOD)
    assert len(client.payloads) == 1
    p = client.payloads[0]
    assert p["model"] == "qwen3.5:9b" and p["stream"] is False and p["think"] is False
    assert p["format"] == qwen_adapter.SCHEMA
    assert p["options"]["temperature"] == 0 and p["options"]["seed"] == 42
    user = json.loads(p["messages"][1]["content"])
    assert user["context"] == TEXT
    assert user["spans"][0] == {"id": "s1", "ja": "天気がいい"}
    assert res.format_compliant and res.error_type is None
    assert all(s.accepted for s in res.spans)
    assert res.latency_ms == 12.5 and res.ollama_stats["total_duration"] == 5


BAD = {
    "missing": items(("s1", "a"), ("s2", "b")),
    "extra": items(("s1", "a"), ("s2", "b"), ("s3", "c"), ("s9", "d")),
    "duplicate": items(("s1", "a"), ("s1", "z"), ("s2", "b"), ("s3", "c")),
    "empty_en": items(("s1", ""), ("s2", "b"), ("s3", "c")),
    "int_id": json.dumps({"items": [{"id": 1, "en": "a"}, {"id": "s2", "en": "b"}, {"id": "s3", "en": "c"}]}),
    "num_en": json.dumps({"items": [{"id": "s1", "en": 5}, {"id": "s2", "en": "b"}, {"id": "s3", "en": "c"}]}),
    "not_json": "Sure! Here you go",
    "think_prefix": "<think>hmm</think>" + GOOD,
    "no_items": json.dumps({"result": []}),
    "list_top": "[1,2]",
    "japanese_out": items(("s1", "天気"), ("s2", "b"), ("s3", "c")),
}


@pytest.mark.parametrize("name", list(BAD))
def test_id_mismatch_cases(name):
    res, _ = run(BAD[name])
    if name != "japanese_out":
        assert res.format_compliant is False
    translations = {s.id: s.en for s in res.spans}
    segs = assemble(TEXT, SPANS, translations)
    assert is_preserved(TEXT, segs)


def test_partial_accept_valid_ids():
    res, _ = run(BAD["missing"])
    by = {s.id: s for s in res.spans}
    assert by["s1"].accepted and by["s2"].accepted
    assert not by["s3"].accepted and by["s3"].reason == "missing_id"
    assert res.format_compliant is False


def test_duplicate_id_rejects_both():
    res, _ = run(BAD["duplicate"])
    by = {s.id: s for s in res.spans}
    assert by["s1"].accepted is False and by["s1"].reason == "duplicate_id"
    assert by["s2"].accepted and by["s3"].accepted


def test_unparseable_marks_all_failed():
    res, _ = run(BAD["think_prefix"])
    assert all(s.reason == "unparseable" and not s.accepted for s in res.spans)


def test_any_output_preserves_original():
    for content in list(BAD.values()) + [GOOD, "", "{}"]:
        res, _ = run(content)
        segs = assemble(TEXT, SPANS, {s.id: s.en for s in res.spans})
        assert is_preserved(TEXT, segs)


def test_transport_error_maps_to_error_type():
    for exc, expected in [
        (ConnectionRefusedError(), "ollama_unreachable"),
        (TimeoutError(), "timeout"),
    ]:
        def transport(*a, _e=exc, **k):
            raise _e

        res = QwenAdapter(OllamaClient(transport=transport)).translate(TEXT, SPANS)
        assert res.error_type == expected
        assert all(s.reason == "call_failed" and not s.accepted for s in res.spans)
    res = QwenAdapter(FakeClient(exc=OllamaError("model_not_found"))).translate(TEXT, SPANS)
    assert res.error_type == "model_not_found"


def test_thinking_field_flagged_not_used():
    resp = {"message": {"content": GOOD, "thinking": "reasoning..."}}
    res, _ = run(resp=resp)
    assert res.thinking_present is True
    assert res.format_compliant


def test_prompt_hash():
    assert QwenAdapter.prompt_sha256 == hashlib.sha256(qwen_adapter.SYSTEM_PROMPT.encode()).hexdigest()
    assert QwenAdapter.context_mode == "full_text"


def test_outer_whitespace_normalized_like_gemma():
    content = items(("s1", " nice weather\n"), ("s2", "\tgo to the park "), ("s3", "take a look"))
    res, _ = run(content)
    assert [s.en for s in res.spans] == ["nice weather", "go to the park", "take a look"]
    assert res.format_compliant
    segs = assemble(TEXT, SPANS, {s.id: s.en for s in res.spans})
    assert [s.text for s in segs if s.kind == "en"] == ["nice weather", "go to the park", "take a look"]


def test_whitespace_only_en_is_malformed():
    res, _ = run(items(("s1", "   "), ("s2", "b"), ("s3", "c")))
    assert res.format_compliant is False
    assert res.spans[0].reason == "missing_id"


def test_same_output_same_verdict_in_both_adapters():
    from backend.llm.translategemma_adapter import TranslateGemmaAdapter
    from tests.test_translategemma_adapter import FakeClient as GemmaClient
    for out in ["nice weather", " nice weather\n", "Sure, here is nice weather", "Of course, I'll go.", "[x]", "天気", "x" * 101]:
        q, _ = run(items(("s1", out), ("s2", "b"), ("s3", "c")))
        g = TranslateGemmaAdapter(GemmaClient([out, "b", "c"])).translate(TEXT, SPANS)
        assert q.spans[0].accepted == g.spans[0].accepted, out


def test_context_leak_and_placeholder_stay_japanese():
    text = "質問があれば support@example.com まで連絡してください。最新は `git clone https://example.org/r.git` で。"
    spans = [resolve_span(text, "s1", "連絡してください"), resolve_span(text, "s2", "最新は")]
    res = QwenAdapter(FakeClient(content=items(
        ("s1", "please contact us at support@example.com"), ("s2", "The latest is [source]")))).translate(text, spans)
    assert [s.reason for s in res.spans] == ["context_leak", "placeholder"]
    assert res.format_compliant  # schema-valid; rejection is a validation outcome, not a format failure
    segs = assemble(text, spans, {s.id: s.en for s in res.spans})
    assert "".join(s.text for s in segs) == text
