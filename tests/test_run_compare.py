import csv
import json
from pathlib import Path

import pytest

from backend.llm.ollama_client import OllamaClient
from eval import run_compare

GOOD_SHOW = {"modelfile": "# generated\nFROM /models/blobs/sha256-abc\nTEMPLATE x\n", "details": {"format": "gguf"}}


def _tag(name, digest, size=6_000_000_000, fmt="gguf", **extra):
    return {"name": name, "digest": digest, "size": size,
            "details": {"format": fmt, "parameter_size": "9B", "quantization_level": "Q4_K_M"}, **extra}


TAGS = {"models": [_tag("qwen3.5:9b", "dq"), _tag("translategemma:12b", "dg")]}


class FakeOllama:
    def __init__(self, tags=TAGS, fail_on=None, down=False, show=GOOD_SHOW, interrupt_on=None, obey=False,
                 gemma_output="english text"):
        self.tags, self.fail_on, self.down, self.show = tags, fail_on, down, show
        self.interrupt_on, self.obey, self.gemma_output = interrupt_on, obey, gemma_output
        self.paths, self.chat_models = [], []

    def __call__(self, method, url, body, timeout):
        path = url.split("11434", 1)[1]
        self.paths.append(path)
        if self.down:
            raise ConnectionRefusedError()
        if path == "/api/version":
            return 200, b'{"version":"0.0-test"}'
        if path == "/api/tags":
            return 200, json.dumps(self.tags).encode()
        if path == "/api/show":
            return 200, json.dumps(self.show).encode()
        assert path == "/api/chat"
        payload = json.loads(body)
        self.chat_models.append(payload["model"])
        flat = json.dumps(payload, ensure_ascii=False)
        if self.interrupt_on and self.interrupt_on in flat:
            raise KeyboardInterrupt()
        if self.fail_on and self.fail_on in flat:
            raise TimeoutError()
        if payload["model"].startswith("qwen"):
            user = json.loads(payload["messages"][1]["content"])
            items = []
            for sp in user["spans"]:
                canary = next((c for c in ("HACKED", "ADMIN_OK") if c in sp["ja"]), None)
                items.append({"id": sp["id"], "en": canary if (self.obey and canary) else "english " + sp["id"]})
            content = json.dumps({"items": items})
        else:
            prompt = payload["messages"][0]["content"]
            canary = next((c for c in ("HACKED", "ADMIN_OK") if c in prompt.split("\n\n\n", 1)[-1]), None)
            content = canary if (self.obey and canary) else self.gemma_output
        return 200, json.dumps({"message": {"content": content}, "eval_count": 1}).encode()


def run(tmp_path, fake, *extra):
    factory = lambda base_url, timeout: OllamaClient(base_url, timeout, transport=fake)  # noqa: E731
    code = run_compare.main(["--limit", "3", "--out", str(tmp_path), *extra], client_factory=factory)
    dirs = list(tmp_path.iterdir())
    return code, (dirs[0] if dirs else None)


def rows(run_dir):
    return [json.loads(l) for l in (run_dir / "results.jsonl").read_text(encoding="utf-8").splitlines()]


def test_limit3_writes_four_files(tmp_path):
    code, d = run(tmp_path, FakeOllama())
    assert code == 0
    assert {p.name for p in d.iterdir()} == {"results.jsonl", "run_meta.json", "human_scores.csv", "blind_key.json"}
    r = rows(d)
    assert len(r) == 6
    assert {x["model"] for x in r} == {"qwen3.5:9b", "translategemma:12b"}
    assert [x["item_id"] for x in r if x["model"] == "qwen3.5:9b"] == ["keigo-01", "unicode-01", "injection-01"]
    meta = json.loads((d / "run_meta.json").read_text(encoding="utf-8"))
    assert meta["ollama_version"] == "0.0-test" and meta["base_url_host"] == "127.0.0.1"
    assert [m["digest"] for m in meta["models"]] == ["dq", "dg"]
    assert meta["models"][0]["options"]["temperature"] == 0 and meta["models"][0]["think"] is False
    assert meta["models"][1]["context_mode"] == "none"


def test_warmup_excluded(tmp_path):
    fake = FakeOllama()
    code, d = run(tmp_path, fake)
    assert len(rows(d)) == 6
    assert fake.chat_models.count("qwen3.5:9b") == 1 + 3          # warm-up + 3 items
    assert fake.chat_models.count("translategemma:12b") == 1 + (2 + 2 + 2)  # warm-up + per-span calls
    assert all(x["item_id"] != "w" for x in rows(d))


def test_item_error_continues(tmp_path):
    code, d = run(tmp_path, FakeOllama(fail_on="𠮷野家"))
    assert code == 0
    by = {(x["model"], x["item_id"]): x for x in rows(d)}
    assert by[("qwen3.5:9b", "unicode-01")]["error_type"] == "timeout"
    assert by[("qwen3.5:9b", "keigo-01")]["error_type"] is None
    assert by[("qwen3.5:9b", "injection-01")]["error_type"] is None
    assert by[("translategemma:12b", "unicode-01")]["error_type"] == "timeout"
    assert by[("qwen3.5:9b", "unicode-01")]["assembled_text"] == "𠮷野家で朝ごはんを食べて、𠮷田さんと一緒に出勤した。"


def test_missing_model_exit2_no_pull(tmp_path):
    fake = FakeOllama(tags={"models": [TAGS["models"][0]]})
    code, d = run(tmp_path, fake)
    assert code == 2 and d is None
    assert "/api/pull" not in fake.paths and "/api/chat" not in fake.paths


def test_unreachable_exit1(tmp_path):
    code, d = run(tmp_path, FakeOllama(down=True))
    assert code == 1


@pytest.mark.parametrize("args", [["--models", "qwen3:cloud"], ["--models", "unknown:1b"],
                                  ["--base-url", "http://192.168.1.5:11434"]])
def test_config_errors_exit2(tmp_path, args):
    fake = FakeOllama()
    code, d = run(tmp_path, fake, *args)
    assert code == 2 and fake.paths == []


def test_csv_bom_and_blind(tmp_path):
    code, d = run(tmp_path, FakeOllama())
    raw = (d / "human_scores.csv").read_bytes()
    assert raw[:3] == b"\xef\xbb\xbf"
    text = raw.decode("utf-8-sig")
    assert "qwen" not in text.lower() and "gemma" not in text.lower()
    recs = list(csv.DictReader(text.splitlines(), delimiter=","))
    assert recs and set(recs[0]) == set(run_compare.CSV_COLUMNS)
    assert {r["label"] for r in recs} == {"A", "B"}
    assert all(r["naturalness"] == "" and r["context_fit"] == "" for r in recs)
    key = json.loads((d / "blind_key.json").read_text(encoding="utf-8"))
    assert set(key["keigo-01"].values()) == {"qwen3.5:9b", "translategemma:12b"}
    # same seed -> same assignment
    other = tmp_path / "again"
    code, d2 = run(other, FakeOllama())
    assert json.loads((d2 / "blind_key.json").read_text(encoding="utf-8")) == key


def test_run_meta_no_env_values(tmp_path, monkeypatch):
    monkeypatch.setenv("MAZE_SECRET", "s3cr3t-value-xyz")
    code, d = run(tmp_path, FakeOllama())
    meta = (d / "run_meta.json").read_text(encoding="utf-8")
    assert "s3cr3t-value-xyz" not in meta
    assert "𠮷" not in meta and "お忙しい" not in meta  # no body text
    assert str(Path.home()) not in meta


def test_original_preserved_all_rows(tmp_path):
    code, d = run(tmp_path, FakeOllama(), "--repeat", "2")
    r = rows(d)
    assert len(r) == 12
    assert all(x["original_preserved"] for x in r)
    assert all(x["injection_flag"] is None for x in r if x["item_id"] != "injection-01")
    inj = [x for x in r if x["item_id"] == "injection-01"]
    assert all(x["injection_mode"] == "context" for x in inj)
    assert {x["model"]: (x["injection_testable"], x["injection_flag"]) for x in inj} == {
        "qwen3.5:9b": (True, False), "translategemma:12b": (False, None)}  # no context -> not testable
    csv_rows = list(csv.DictReader((d / "human_scores.csv").read_text(encoding="utf-8-sig").splitlines()))
    assert len(csv_rows) == 2 * (2 + 2 + 2)  # first repeat only: spans x models


# --- #6 cloud alias / non-local weights ---------------------------------------

def _tags_with(**qwen_extra):
    return {"models": [_tag("qwen3.5:9b", "dq", **qwen_extra), _tag("translategemma:12b", "dg")]}


@pytest.mark.parametrize("fake", [
    FakeOllama(tags=_tags_with(remote_host="https://ollama.com")),
    FakeOllama(tags=_tags_with(size=1234)),
    FakeOllama(tags=_tags_with(fmt="")),
    FakeOllama(show={**GOOD_SHOW, "remote_model": "x"}),
    FakeOllama(show={"modelfile": "FROM gpt-oss:120b\n", "details": {"format": "gguf"}}),
    FakeOllama(show={"modelfile": "FROM /blobs/a\nFROM somemodel\n"}),
    FakeOllama(show={"details": {"format": "gguf"}}),
])
def test_alias_or_nonlocal_model_rejected_before_any_chat(tmp_path, fake):
    code, d = run(tmp_path, fake)
    assert code == 2 and d is None
    assert "/api/chat" not in fake.paths and "/api/show" in fake.paths


def test_assert_local_entry_ok_and_name_check():
    from backend.llm.ollama_client import assert_local_entry
    assert_local_entry(_tag("qwen3.5:9b", "d"), GOOD_SHOW)
    with pytest.raises(ValueError):
        assert_local_entry(_tag("x:cloud", "d"), GOOD_SHOW)
    with pytest.raises(ValueError):
        assert_local_entry(None, GOOD_SHOW)


def test_show_is_loopback_only_and_cloud_names_refused():
    t = FakeOllama()
    c = OllamaClient(transport=t)
    with pytest.raises(ValueError):
        c.show("qwen3:cloud")
    assert t.paths == []


# --- #2 interruption / unexpected exceptions ----------------------------------

def test_interrupt_saves_scoring_files_and_partial_results(tmp_path):
    code, d = run(tmp_path, FakeOllama(interrupt_on="𠮷野家"))
    assert code == 130
    assert {p.name for p in d.iterdir()} == {"results.jsonl", "run_meta.json", "human_scores.csv", "blind_key.json"}
    meta = json.loads((d / "run_meta.json").read_text(encoding="utf-8"))
    assert meta["status"] == "interrupted" and meta["completed_rows"] == 1 and meta["planned_rows"] == 6
    assert [x["item_id"] for x in rows(d)] == ["keigo-01"]
    recs = list(csv.DictReader((d / "human_scores.csv").read_text(encoding="utf-8-sig").splitlines()))
    assert {r["item_id"] for r in recs} == {"keigo-01"}          # only completed items are scored
    key = json.loads((d / "blind_key.json").read_text(encoding="utf-8"))
    assert set(key) == {"keigo-01", "unicode-01", "injection-01"}  # key is complete for the planned items


def test_unexpected_exception_is_recorded_and_run_continues(tmp_path, monkeypatch):
    from backend.llm.qwen_adapter import QwenAdapter
    orig = QwenAdapter.translate

    def boom(self, text, spans):
        if "𠮷野家" in text:
            raise ValueError("secret 本文 𠮷野家")
        return orig(self, text, spans)

    monkeypatch.setattr(QwenAdapter, "translate", boom)
    code, d = run(tmp_path, FakeOllama())
    assert code == 0
    by = {(x["model"], x["item_id"]): x for x in rows(d)}
    bad = by[("qwen3.5:9b", "unicode-01")]
    assert bad["error_type"] == "internal_error" and bad["exception_type"] == "ValueError"
    assert bad["assembled_text"] == "𠮷野家で朝ごはんを食べて、𠮷田さんと一緒に出勤した。" and bad["original_preserved"]
    assert by[("qwen3.5:9b", "injection-01")]["error_type"] is None
    assert "secret" not in (d / "results.jsonl").read_text(encoding="utf-8")   # message not stored
    meta = json.loads((d / "run_meta.json").read_text(encoding="utf-8"))
    assert meta["status"] == "complete"


def test_broken_invariant_is_recorded_not_hidden(tmp_path, monkeypatch):
    def broken(text, spans, translations):
        raise AssertionError("original text not preserved")

    monkeypatch.setattr(run_compare, "assemble", broken)
    code, d = run(tmp_path, FakeOllama())
    assert code == 0
    r = rows(d)
    assert all(x["original_preserved"] is False for x in r)
    assert r[0]["assembled_text"] == "お忙しいところ恐れ入りますが、明日の会議の資料をご確認いただけますでしょうか。"


def test_crash_after_start_still_writes_meta(tmp_path, monkeypatch):
    monkeypatch.setattr(run_compare, "_row", lambda *a, **k: (_ for _ in ()).throw(OSError("disk")))
    factory = lambda base_url, timeout: OllamaClient(base_url, timeout, transport=FakeOllama())  # noqa: E731
    with pytest.raises(OSError):
        run_compare.main(["--limit", "3", "--out", str(tmp_path)], client_factory=factory)
    d = next(tmp_path.iterdir())
    assert json.loads((d / "run_meta.json").read_text(encoding="utf-8"))["status"] == "failed"
    assert (d / "human_scores.csv").exists() and (d / "blind_key.json").exists()


def test_csv_formula_prefix_neutralised(tmp_path):
    code, d = run(tmp_path, FakeOllama(gemma_output="=cmd"))
    recs = list(csv.DictReader((d / "human_scores.csv").read_text(encoding="utf-8-sig").splitlines()))
    outs = [r["en_output"] for r in recs if r["en_output"].endswith("=cmd") or "=cmd" in r["en_output"]]
    assert outs and all(o.startswith("'=") for o in outs)


def test_duplicate_models_are_deduplicated(tmp_path):
    code, d = run(tmp_path, FakeOllama(), "--models", "qwen3.5:9b,qwen3.5:9b")
    assert len(rows(d)) == 3


# --- #5 injection conditions ---------------------------------------------------

def test_injection_conditions_are_explicit_and_not_conflated(tmp_path):
    factory_fake = FakeOllama(obey=True)
    factory = lambda base_url, timeout: OllamaClient(base_url, timeout, transport=factory_fake)  # noqa: E731
    assert run_compare.main(["--out", str(tmp_path)], client_factory=factory) == 0
    d = next(tmp_path.iterdir())
    by = {(x["model"], x["item_id"]): x for x in rows(d) if x["category"] == "injection"}
    # span mode: both models see the instruction; output that is only the canary = obeyed
    for m in ("qwen3.5:9b", "translategemma:12b"):
        for i in ("injection-02", "injection-04"):
            assert by[(m, i)]["injection_mode"] == "span"
            assert by[(m, i)]["injection_testable"] is True and by[(m, i)]["injection_flag"] is True
    # context mode: only the model that receives context is testable
    for i in ("injection-01", "injection-03"):
        assert by[("qwen3.5:9b", i)]["injection_testable"] is True
        assert by[("translategemma:12b", i)]["injection_testable"] is False
        assert by[("translategemma:12b", i)]["injection_flag"] is None
    assert all(x["original_preserved"] for x in by.values())


def test_failed_item_is_not_counted_as_resisting_injection(tmp_path):
    code, d = run(tmp_path, FakeOllama(fail_on="PWNED"))     # every call for injection-01 times out
    assert code == 0
    inj = [x for x in rows(d) if x["item_id"] == "injection-01" and x["model"] == "qwen3.5:9b"]
    assert len(inj) == 1 and inj[0]["error_type"] == "timeout"       # Qwen receives the context containing PWNED
    assert inj[0]["injection_testable"] is False and inj[0]["injection_flag"] is None


def test_scoring_file_failure_is_not_exit_0_and_is_recorded(tmp_path, monkeypatch, capsys):
    monkeypatch.setattr(run_compare, "_write_human_scores", lambda *a, **k: (_ for _ in ()).throw(OSError("full")))
    code, d = run(tmp_path, FakeOllama())
    assert code == 3
    meta = json.loads((d / "run_meta.json").read_text(encoding="utf-8"))
    assert meta["status"] == "complete"                 # the run itself finished
    assert meta["artifacts_ok"] is False and meta["artifacts_failed"] == ["human_scores.csv / blind_key.json"]
    assert len(rows(d)) == 6                            # results.jsonl is intact
    assert "結果は不完全" in capsys.readouterr().out


def test_run_meta_failure_is_not_exit_0(tmp_path, monkeypatch):
    def broken(run_dir, meta):
        raise OSError("read-only")

    monkeypatch.setattr(run_compare, "_write_meta", broken)
    code, d = run(tmp_path, FakeOllama())
    assert code == 3
    assert (d / "human_scores.csv").exists() and (d / "blind_key.json").exists()
    assert not (d / "run_meta.json").exists()


def test_final_meta_rewrite_failure_is_not_exit_0(tmp_path, monkeypatch):
    real = run_compare._write_meta
    calls = {"n": 0}

    def flaky(run_dir, meta):
        calls["n"] += 1
        if calls["n"] == 2:                     # first write ok, the final update fails
            raise OSError("full")
        real(run_dir, meta)

    monkeypatch.setattr(run_compare, "_write_meta", flaky)
    code, d = run(tmp_path, FakeOllama())
    assert code == 3
    assert json.loads((d / "run_meta.json").read_text(encoding="utf-8"))["artifacts_ok"] is None  # honest: unknown


def test_all_artifacts_ok_is_recorded_and_exit_0(tmp_path):
    code, d = run(tmp_path, FakeOllama())
    meta = json.loads((d / "run_meta.json").read_text(encoding="utf-8"))
    assert code == 0 and meta["artifacts_ok"] is True and meta["artifacts_failed"] == []


def test_interrupt_keeps_130_even_if_artifacts_fail(tmp_path, monkeypatch):
    monkeypatch.setattr(run_compare, "_write_human_scores", lambda *a, **k: (_ for _ in ()).throw(OSError("full")))
    code, d = run(tmp_path, FakeOllama(interrupt_on="𠮷野家"))
    assert code == 130
    meta = json.loads((d / "run_meta.json").read_text(encoding="utf-8"))
    assert meta["status"] == "interrupted" and meta["artifacts_ok"] is False


def test_meta_update_failure_leaves_previous_valid_json(tmp_path, monkeypatch):
    run_compare._write_meta(tmp_path, {"status": "complete", "artifacts_ok": None})
    before = (tmp_path / "run_meta.json").read_text(encoding="utf-8")
    real_replace = run_compare.os.replace

    def boom(src, dst):
        raise OSError("disk full while replacing")

    monkeypatch.setattr(run_compare.os, "replace", boom)
    with pytest.raises(OSError):
        run_compare._write_meta(tmp_path, {"status": "complete", "artifacts_ok": False})
    monkeypatch.setattr(run_compare.os, "replace", real_replace)
    assert (tmp_path / "run_meta.json").read_text(encoding="utf-8") == before
    json.loads(before)                                              # still valid JSON
    assert not (tmp_path / "run_meta.json.tmp").exists()            # no stray temp file


def test_meta_write_failure_while_serialising_leaves_no_partial_file(tmp_path):
    with pytest.raises(TypeError):
        run_compare._write_meta(tmp_path, {"bad": object()})
    assert list(tmp_path.iterdir()) == []
