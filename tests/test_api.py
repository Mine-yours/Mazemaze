import json
import logging
import threading

import pytest

from backend.config import ConfigError, Settings
from backend.service import batch_spans
from backend.spans import Span
from tests.api_helpers import (GOOD_SHOW, GOOD_TAG, SAMPLE, FakeOllama, default_chat, make_client,
                               make_service)

SENTINEL = "秘密の合言葉ZZZ"


def post(client, **body):
    body.setdefault("text", SAMPLE)
    return client.post("/api/translate", json=body)


def assert_preserved(data):
    assert "".join(s["source"] for s in data["segments"]) == data["original"]
    pos = 0
    for s in data["segments"]:
        assert s["start"] == pos and data["original"][s["start"]:s["end"]] == s["source"]
        if s["kind"] == "ja":
            assert s["display"] == s["source"] and s["translation"] is None
        pos = s["end"]
    assert pos == len(data["original"])


# ---- success paths -------------------------------------------------------------------------
def test_success_mixes_languages_and_preserves_original():
    client, fake = make_client()
    r = post(client)
    assert r.status_code == 200
    data = r.json()
    assert_preserved(data)
    assert data["model"] == "qwen3.5:9b"
    en = [s for s in data["segments"] if s["kind"] == "en"]
    assert en and data["stats"]["accepted_spans"] == len(en)
    assert data["mixed_text"] == "".join(s["display"] for s in data["segments"])
    assert all(p["model"] == "qwen3.5:9b" for p in fake.chat_payloads)
    ctx = json.loads(fake.chat_payloads[0]["messages"][-1]["content"])["context"]
    assert ctx == SAMPLE  # full text is sent as context, unchanged
    assert r.headers["cache-control"] == "no-store"


def test_same_input_selects_same_spans():
    client, _ = make_client()
    a = post(client).json()
    b = post(client).json()
    assert [s["source"] for s in a["segments"]] == [s["source"] for s in b["segments"]]


def test_partial_failure_keeps_japanese():
    calls = {"n": 0}

    def chat(payload):
        calls["n"] += 1
        if calls["n"] == 1:
            user = json.loads(payload["messages"][-1]["content"])
            # first span missing, second ok
            return {"message": {"content": json.dumps({"items": [{"id": user["spans"][-1]["id"], "en": "Fine"}]})}}
        return default_chat(payload)

    client, _ = make_client(FakeOllama(chat=chat))
    data = post(client, ratio=0.7).json()
    assert_preserved(data)
    assert data["stats"]["accepted_spans"] < data["stats"]["requested_spans"]
    assert any("日本語のまま" in w for w in data["warnings"])


def test_garbage_llm_output_returns_original():
    client, _ = make_client(FakeOllama(chat=lambda p: {"message": {"content": "not json"}}))
    r = post(client)
    assert r.status_code == 200
    data = r.json()
    assert_preserved(data)
    assert data["mixed_text"] == SAMPLE and data["stats"]["accepted_spans"] == 0


def test_fullwidth_punctuation_in_translation_is_rejected():
    def chat(payload):
        user = json.loads(payload["messages"][-1]["content"])
        return {"message": {"content": json.dumps(
            {"items": [{"id": s["id"], "en": "Hello。"} for s in user["spans"]]})}}

    client, _ = make_client(FakeOllama(chat=chat))
    data = post(client).json()
    assert data["mixed_text"] == SAMPLE


def test_no_candidates_never_calls_the_model():
    client, fake = make_client()
    data = post(client, text="123 abc").json()
    assert data["mixed_text"] == "123 abc" and fake.chat_payloads == []
    assert data["warnings"]


def test_crlf_and_leading_whitespace_preserved():
    text = "  今日は天気がとても良かったです。\r\n明日も天気が良いといいですね。\r\n"
    client, _ = make_client()
    assert_preserved(post(client, text=text, ratio=0.7).json())


def test_assemble_assertion_falls_back_to_original(monkeypatch):
    import backend.service as svc

    def boom(*a, **k):
        raise AssertionError("x")

    real = svc.assemble
    calls = {"n": 0}

    def flaky(text, spans, tr):
        calls["n"] += 1
        return boom() if calls["n"] == 1 else real(text, spans, tr)

    monkeypatch.setattr(svc, "assemble", flaky)
    client, _ = make_client()
    data = post(client).json()
    assert data["mixed_text"] == SAMPLE and data["warnings"]


# ---- batching ------------------------------------------------------------------------------
def test_batching_limits():
    spans = [Span(f"s{i}", i * 100, i * 100 + 10, "あ" * 10) for i in range(24)]
    batches = batch_spans(spans)
    assert [len(b) for b in batches] == [6, 6, 6, 6]
    long_spans = [Span(f"s{i}", i * 200, i * 200 + 100, "あ" * 100) for i in range(3)]
    assert [len(b) for b in batch_spans(long_spans)] == [1, 1, 1]
    assert batch_spans([]) == []


def test_many_spans_use_multiple_calls():
    text = "".join(f"今日は{c}曜日で、とても楽しい一日でした。" for c in "月火水木金土日")
    client, fake = make_client()
    data = post(client, text=text, ratio=0.7).json()
    assert_preserved(data)
    assert len(fake.chat_payloads) >= 2
    for p in fake.chat_payloads:
        spans = json.loads(p["messages"][-1]["content"])["spans"]
        assert len(spans) <= 6 and sum(len(s["ja"]) for s in spans) <= 150 or len(spans) == 1


# ---- Ollama / model failures ---------------------------------------------------------------
@pytest.mark.parametrize("fake,status", [
    (FakeOllama(reachable=False), 503),
    (FakeOllama(tags=[]), 503),
    (FakeOllama(tags=[dict(GOOD_TAG, name="other:1b", model="other:1b")]), 503),
])
def test_ollama_down_or_missing_model(fake, status):
    client, f = make_client(fake)
    r = post(client)
    assert r.status_code == status
    assert SAMPLE[:6] not in r.text and r.json()["error"]["message"]
    assert f.chat_payloads == []


def test_timeout_total_failure_is_504():
    def chat(payload):
        raise TimeoutError()

    client, _ = make_client(FakeOllama(chat=chat))
    r = post(client)
    assert r.status_code == 504 and "時間" in r.json()["error"]["message"]


def test_http_error_is_502():
    client, _ = make_client(FakeOllama(chat=lambda p: (500, b"{}")))
    assert post(client).status_code == 502


def test_partial_timeout_returns_partial_result():
    text = "".join(f"今日は{c}曜日で、とても楽しい一日でした。" for c in "月火水木金土日")
    calls = {"n": 0}

    def chat(payload):
        calls["n"] += 1
        if calls["n"] == 2:
            raise TimeoutError()
        return default_chat(payload)

    client, _ = make_client(FakeOllama(chat=chat))
    r = post(client, text=text, ratio=0.7)
    assert r.status_code == 200
    data = r.json()
    assert_preserved(data)
    assert data["stats"]["accepted_spans"] >= 1 and data["warnings"]


def test_deadline_stops_remaining_batches():
    text = "".join(f"今日は{c}曜日で、とても楽しい一日でした。" for c in "月火水木金土日")
    now = {"t": 0.0}

    def chat(payload):
        now["t"] += 100.0  # each call "takes" 100 s
        return default_chat(payload)

    fake = FakeOllama(chat=chat)
    client, _ = make_client(fake, clock=lambda: now["t"], deadline=90.0)
    r = post(client, text=text, ratio=0.7)
    assert r.status_code == 200
    assert len(fake.chat_payloads) == 1  # later batches skipped
    assert any("時間切れ" in w for w in r.json()["warnings"])
    assert_preserved(r.json())


# ---- model allow-list / local verification --------------------------------------------------
@pytest.mark.parametrize("name", ["qwen3.5:cloud", "gpt-oss:20b", "qwen3.5:9b-cloud", "", " qwen3.5:9b", "QWEN3.5:9B"])
def test_settings_reject_disallowed_models(name):
    with pytest.raises(ConfigError):
        Settings(model=name).validate()


def test_translategemma_is_allowed():
    Settings(model="translategemma:12b").validate()


def test_settings_reject_non_loopback_ollama():
    with pytest.raises(ConfigError):
        Settings(ollama_url="http://192.168.0.5:11434").validate()


def test_env_model_is_validated(monkeypatch):
    monkeypatch.setenv("MAZEMAZE_MODEL", "qwen3.5:cloud")
    with pytest.raises(ConfigError):
        Settings.from_env()
    monkeypatch.setenv("MAZEMAZE_MODEL", "translategemma:12b")
    assert Settings.from_env().model == "translategemma:12b"


@pytest.mark.parametrize("tag,show", [
    (dict(GOOD_TAG, remote_host="https://x"), GOOD_SHOW),
    (dict(GOOD_TAG, size=10), GOOD_SHOW),
    (dict(GOOD_TAG, details={"format": "other"}), GOOD_SHOW),
    (GOOD_TAG, {"modelfile": "FROM qwen3.5:cloud\n"}),
])
def test_cloud_alias_metadata_is_rejected_and_chat_never_called(tag, show):
    client, fake = make_client(FakeOllama(tags=[tag], show=show))
    r = post(client)
    assert r.status_code == 503
    assert fake.chat_payloads == []


def test_startup_fails_closed_on_rejected_model():
    from fastapi.testclient import TestClient
    from backend.app import create_app
    fake = FakeOllama(tags=[dict(GOOD_TAG, size=10)])
    app = create_app(Settings(), make_service(fake))
    with pytest.raises(RuntimeError):
        with TestClient(app, base_url="http://localhost", client=("127.0.0.1", 1)):
            pass


def test_startup_survives_ollama_down_and_status_reports_it():
    from fastapi.testclient import TestClient
    from backend.app import create_app
    app = create_app(Settings(), make_service(FakeOllama(reachable=False)))
    with TestClient(app, base_url="http://localhost", client=("127.0.0.1", 1)) as c:
        st = c.get("/api/status").json()
    assert st["ollama_reachable"] is False and st["model"] == "qwen3.5:9b"


def test_status_contains_no_secrets():
    client, _ = make_client(token="s3cr3t-token")
    r = client.get("/api/status", headers={"x-mazemaze-token": "s3cr3t-token"})
    body = r.text
    assert r.status_code == 200
    assert "s3cr3t" not in body and "11434" not in body and "abc" not in body


def test_model_check_runs_on_every_request():
    client, fake = make_client()
    post(client)
    post(client)
    assert fake.calls.count("/api/tags") == 2 and fake.calls.count("/api/show") == 2


# ---- input validation ----------------------------------------------------------------------
@pytest.mark.parametrize("body", [
    {"text": ""}, {"text": "  \n "}, {"text": "あ" * 1001}, {"text": SENTINEL, "ratio": 0.05},
    {"text": SENTINEL, "ratio": 0.71}, {"text": SENTINEL, "ratio": "a"}, {"text": SENTINEL, "ratio": None},
    {"text": SENTINEL, "unit": "word"}, {"text": 5}, {}, {"text": "あ\x00い" + SENTINEL},
])
def test_invalid_input_is_422_and_never_echoed(body, caplog):
    caplog.set_level(logging.DEBUG)
    client, fake = make_client()
    r = client.post("/api/translate", json=body)
    assert r.status_code == 422
    assert SENTINEL not in r.text and SENTINEL not in caplog.text
    assert r.json()["error"]["code"] == "invalid_request"
    assert fake.calls == []


def test_non_json_body_is_rejected_without_echo():
    client, _ = make_client()
    r = client.post("/api/translate", content=SENTINEL, headers={"content-type": "application/json"})
    assert r.status_code == 422 and SENTINEL not in r.text
    r = client.post("/api/translate", content=json.dumps({"text": SAMPLE}), headers={"content-type": "text/plain"})
    assert r.status_code == 415
    r = client.post("/api/translate", content="x" * 30000, headers={"content-type": "application/json"})
    assert r.status_code == 413


def test_unhandled_error_is_generic_and_does_not_log_text(monkeypatch, caplog):
    import backend.service as svc

    def boom(*a, **k):
        raise RuntimeError(SENTINEL)

    monkeypatch.setattr(svc, "select_spans", boom)
    caplog.set_level(logging.DEBUG)
    client, _ = make_client()
    r = post(client, text=SAMPLE)
    assert r.status_code == 500 and SENTINEL not in r.text and SENTINEL not in caplog.text
    # the lock must have been released
    monkeypatch.undo()
    assert post(client).status_code == 200


def test_logs_do_not_contain_text(caplog):
    caplog.set_level(logging.DEBUG)
    client, _ = make_client(FakeOllama(chat=lambda p: {"message": {"content": SENTINEL}}))
    post(client, text="今日は天気がとても良かったです。" + SENTINEL)
    assert SENTINEL not in caplog.text


# ---- concurrency ---------------------------------------------------------------------------
def test_concurrent_request_gets_429_and_status_stays_responsive():
    started, release = threading.Event(), threading.Event()

    def chat(payload):
        started.set()
        release.wait(5)
        return default_chat(payload)

    client, _ = make_client(FakeOllama(chat=chat))
    first: dict = {}
    t = threading.Thread(target=lambda: first.update(r=post(client)))
    t.start()
    assert started.wait(5)
    r2 = post(client)
    assert r2.status_code == 429 and r2.headers["retry-after"] and SAMPLE[:6] not in r2.text
    st = client.get("/api/status")
    assert st.status_code == 200 and st.json()["busy"] is True
    release.set()
    t.join(5)
    assert first["r"].status_code == 200
    assert post(client).status_code == 200


def test_lock_released_after_total_failure():
    fake = FakeOllama(chat=lambda p: (_ for _ in ()).throw(TimeoutError()))
    client, _ = make_client(fake)
    assert post(client).status_code == 504
    fake.chat_handler = default_chat
    assert post(client).status_code == 200


# ---- TranslateGemma through the service (one call per span) ----------------------------------
def gemma_chat(payload):
    assert payload["model"] == "translategemma:12b"
    return {"message": {"content": "Translated sample"}}


def gemma_client(chat=gemma_chat, **kw):
    tag = dict(GOOD_TAG, name="translategemma:12b", model="translategemma:12b")
    return make_client(FakeOllama(chat=chat, tags=[tag]), model="translategemma:12b", **kw)


def test_gemma_success_and_preserves_original():
    client, fake = gemma_client()
    data = post(client).json()
    assert data["model"] == "translategemma:12b"
    assert_preserved(data)
    assert data["stats"]["accepted_spans"] == data["stats"]["requested_spans"] > 0
    assert len(fake.chat_payloads) == data["stats"]["requested_spans"]


def test_gemma_partial_failure_keeps_successful_spans():
    calls = {"n": 0}

    def chat(payload):
        calls["n"] += 1
        if calls["n"] == 1:
            raise TimeoutError()
        return gemma_chat(payload)

    client, _ = gemma_client(chat)
    r = post(client, ratio=0.7)
    assert r.status_code == 200
    data = r.json()
    assert_preserved(data)
    assert 1 <= data["stats"]["accepted_spans"] < data["stats"]["requested_spans"]
    assert data["warnings"]


def test_gemma_calls_respect_the_request_deadline():
    now = {"t": 0.0}

    def chat(payload):
        now["t"] += 60.0
        return gemma_chat(payload)

    client, fake = gemma_client(chat, clock=lambda: now["t"], deadline=100.0)
    r = post(client, ratio=0.7)
    assert r.status_code == 200
    assert len(fake.chat_payloads) == 2  # the third per-span call is refused by the deadline
    assert_preserved(r.json())


def test_surrogate_input_is_422_without_calling_the_model():
    client, fake = make_client()
    r = client.post("/api/translate", content='{"text": "\\ud800今日はとても良い天気でした"}',
                    headers={"content-type": "application/json"})
    assert r.status_code == 422 and fake.calls == []


def test_status_reports_deadline():
    client, _ = make_client(deadline=90.0)
    assert client.get("/api/status").json()["deadline_seconds"] == 90.0


def test_gemma_deadline_mid_batch_reports_time_not_network_error():
    now = {"t": 0.0}

    def chat(payload):
        now["t"] += 60.0
        return gemma_chat(payload)

    client, _ = gemma_client(chat, clock=lambda: now["t"], deadline=100.0)
    warnings = post(client, ratio=0.7).json()["warnings"]
    assert any("時間切れ" in w for w in warnings)
    assert not any("通信エラー" in w for w in warnings)


def test_gemma_mixed_timeout_and_rejections_is_not_a_total_failure():
    calls = {"n": 0}

    def chat(payload):
        calls["n"] += 1
        if calls["n"] == 1:
            raise TimeoutError()
        return {"message": {"content": "Sure, here is the translation: x"}}  # format violation

    client, _ = gemma_client(chat)
    r = post(client, ratio=0.7)
    assert r.status_code == 200
    data = r.json()
    assert data["mixed_text"] == SAMPLE and data["warnings"]


# ---- warm-up ---------------------------------------------------------------------------------
def test_warmup_loads_the_model_with_a_fixed_request_and_no_user_text():
    client, fake = make_client()
    r = client.post("/api/warmup", json={})
    assert r.status_code == 200 and r.json()["ok"] is True and "elapsed_ms" in r.json()
    assert len(fake.chat_payloads) == 1 and fake.chat_payloads[0]["keep_alive"] == "30m"
    assert fake.chat_payloads[0]["model"] == "qwen3.5:9b"


def test_warmup_requires_the_token_and_the_same_guards():
    client, fake = make_client(token="warm-token")
    assert client.post("/api/warmup", json={}).status_code == 401
    assert fake.calls == []
    assert client.post("/api/warmup", json={}, headers={"x-mazemaze-token": "warm-token"}).status_code == 200
    bad, _ = make_client(base_url="http://evil.com")
    assert bad.post("/api/warmup", json={}).status_code == 400


def test_warmup_skips_when_busy_and_reports_ollama_problems():
    started, release = threading.Event(), threading.Event()

    def chat(payload):
        started.set()
        release.wait(5)
        return default_chat(payload)

    client, _ = make_client(FakeOllama(chat=chat))
    t = threading.Thread(target=lambda: post(client))
    t.start()
    assert started.wait(5)
    r = client.post("/api/warmup", json={})
    assert r.status_code == 200 and r.json() == {"ok": True, "skipped": "busy"}
    release.set(); t.join(5)
    down, _ = make_client(FakeOllama(reachable=False))
    assert down.post("/api/warmup", json={}).status_code == 503


def test_busy_reply_tells_clients_to_retry_soon():
    started, release = threading.Event(), threading.Event()

    def chat(payload):
        started.set(); release.wait(5)
        return default_chat(payload)

    client, _ = make_client(FakeOllama(chat=chat))
    t = threading.Thread(target=lambda: post(client)); t.start()
    assert started.wait(5)
    assert post(client).headers["retry-after"] == "2"
    release.set(); t.join(5)
