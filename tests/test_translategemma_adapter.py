import pytest

from backend.llm.base import OllamaError
from backend.llm.translategemma_adapter import TranslateGemmaAdapter, build_prompt
from backend.spans import assemble, is_preserved, resolve_span

TEXT = "今日は天気がいいので、公園へ行きます。見てね。"
SPANS = [
    resolve_span(TEXT, "s1", "天気がいい"),
    resolve_span(TEXT, "s2", "公園へ行きます"),
    resolve_span(TEXT, "s3", "見てね"),
]

OFFICIAL = (
    "You are a professional Japanese (ja) to English (en) translator. Your goal is to accurately "
    "convey the meaning and nuances of the original Japanese text while adhering to English grammar, "
    "vocabulary, and cultural sensitivities. Produce only the English translation, without any "
    "additional explanations or commentary. Please translate the following Japanese text into English:"
    "\n\n\n天気がいい"
)


class FakeClient:
    def __init__(self, outputs):
        self.outputs = list(outputs)  # str | Exception
        self.payloads = []

    def chat(self, payload):
        self.payloads.append(payload)
        out = self.outputs.pop(0)
        if isinstance(out, Exception):
            raise out
        return {"message": {"content": out}, "eval_count": 3}, 10.0


def run(outputs):
    client = FakeClient(outputs)
    return TranslateGemmaAdapter(client).translate(TEXT, SPANS), client


def test_prompt_exact():
    assert build_prompt("天気がいい") == OFFICIAL
    res, client = run(["nice weather", "go to the park", "take a look"])
    assert client.payloads[0]["messages"] == [{"role": "user", "content": OFFICIAL}]
    assert "format" not in client.payloads[0]


def test_one_call_per_span():
    res, client = run(["a", "b", "c"])
    assert len(client.payloads) == 3
    assert res.format_compliant and all(s.accepted for s in res.spans)
    assert res.latency_ms == 30.0 and res.ollama_stats["eval_count"] == 9


@pytest.mark.parametrize(
    "raw",
    ["Here is the translation: nice", "Here's the translation: one", "Sure, here is the translation: nice", "Translation: nice",
     "English: nice", "```nice```", "line1\nline2", "", "   "],
)
def test_preamble_detected(raw):
    res, _ = run([raw, "b", "c"])
    first = res.spans[0]
    assert first.reason == "format_violation" and not first.accepted
    assert res.format_compliant is False
    assert res.spans[1].accepted


def test_outer_whitespace_ok():
    res, _ = run(["nice weather\n", "b", "c"])
    assert res.format_compliant
    assert res.spans[0].en == "nice weather"


def test_one_span_error_others_continue():
    res, client = run([OllamaError("timeout"), "b", "c"])
    assert res.error_type == "timeout" and res.format_compliant is False
    assert res.spans[0].reason == "call_failed"
    assert res.spans[1].accepted and res.spans[2].accepted
    assert len(client.payloads) == 3
    assert res.latency_ms == 20.0


def test_invalid_translation_stays_japanese():
    res, _ = run(["天気", "b", "c"])
    assert res.spans[0].reason == "japanese_chars"
    segs = assemble(TEXT, SPANS, {s.id: s.en for s in res.spans})
    assert is_preserved(TEXT, segs)
    assert any(s.kind == "ja" and s.text == "天気がいい" for s in segs)


def test_context_leak_and_placeholder_stay_japanese():
    text = "最新のコードは `git clone https://example.org/repo.git` で取得できます。ご不明点は山本まで。"
    spans = [resolve_span(text, "s1", "で取得できます"), resolve_span(text, "s2", "ご不明点は山本まで")]
    client = FakeClient(["git clone https://example.org/repo.git", "Ask Yamamoto at [contact]."])
    res = TranslateGemmaAdapter(client).translate(text, spans)
    assert [s.reason for s in res.spans] == ["context_leak", "placeholder"]
    assert not any(s.accepted for s in res.spans)
    segs = assemble(text, spans, {s.id: s.en for s in res.spans})
    assert "".join(s.text for s in segs) == text
