import hashlib
import json

import pytest

from eval.judge import cli, prepare
from eval.judge.prepare import JudgeDataError, build_inputs, render_preview, validate_input, write_inputs
from tests.judge_helpers import GEMMA, QWEN, load_judge, make_run

NO_ENV = {}


@pytest.fixture()
def run_dir(tmp_path):
    return make_run(tmp_path / "runs")


def test_inputs_contain_only_allowed_fields_and_no_model_names(run_dir, tmp_path):
    inputs, key, selected = build_inputs(run_dir, 5, NO_ENV)
    assert len(selected) == 5 and len(inputs) == 10 and len(key) == 10
    for rec in inputs:
        assert set(rec) == prepare.INPUT_KEYS
        assert set(rec["candidates"]) == {"first", "second"}
    write_inputs(tmp_path / "judge", inputs, key)
    inputs_blob = (tmp_path / "judge" / "judge_inputs.jsonl").read_text(encoding="utf-8")
    key_blob = (tmp_path / "judge" / "judge_key.json").read_text(encoding="utf-8")
    for needle in ("qwen", "gemma", "translategemma", "ollama", ":9b", ":12b", "digest", str(run_dir)):
        assert needle not in (inputs_blob + key_blob).lower()
    assert '"order"' not in inputs_blob            # the presentation order is never shown to the judge
    assert '"order"' in key_blob                    # it lives only in the separate key file


def test_both_orders_present_with_swapped_candidates(run_dir):
    inputs, key, _ = build_inputs(run_dir, 3, NO_ENV)
    blind = json.loads((run_dir / "blind_key.json").read_text(encoding="utf-8"))
    by_item = {}
    for rec in inputs:
        by_item.setdefault(rec["item_id"], []).append(rec)
    for item, recs in by_item.items():
        r1, r2 = sorted(recs, key=lambda r: key[r["input_id"]]["order"])
        assert key[r1["input_id"]]["first"] == key[r2["input_id"]]["second"] == "A"
        assert r1["candidates"]["first"] == r2["candidates"]["second"]
        assert r1["candidates"]["second"] == r2["candidates"]["first"]
        assert r1["input_id"] != r2["input_id"] and "A" not in r1["input_id"][1:2]
        assert set(blind[item].values()) == {QWEN, GEMMA}


def test_rejected_candidates_expose_status_only(tmp_path):
    run_dir = make_run(tmp_path / "r", gemma_output="[placeholder]")
    inputs, key, _ = build_inputs(run_dir, 2, NO_ENV)
    blind = json.loads((run_dir / "blind_key.json").read_text(encoding="utf-8"))
    for rec in inputs:
        for pos in ("first", "second"):
            model = blind[rec["item_id"]][key[rec["input_id"]][pos]]
            for s in rec["candidates"][pos]["spans"]:
                if model == GEMMA:
                    assert s == {"span_id": s["span_id"], "status": "rejected", "english": None}
            if model == GEMMA:   # the displayed mixed text keeps the Japanese
                assert rec["candidates"][pos]["mixed_text"] == rec["text_ja"]
    assert "[placeholder]" not in json.dumps(inputs, ensure_ascii=False)


def _edit_meta(run_dir, **changes):
    p = run_dir / "run_meta.json"
    m = json.loads(p.read_text(encoding="utf-8"))
    m.update(changes)
    p.write_text(json.dumps(m), encoding="utf-8")


@pytest.mark.parametrize("changes", [{"dataset_sha256": "0" * 64}, {"dataset_sha256": None}, {"status": "interrupted"}])
def test_stops_when_test_data_cannot_be_confirmed(run_dir, changes):
    _edit_meta(run_dir, **changes)
    with pytest.raises(JudgeDataError):
        build_inputs(run_dir, 5, NO_ENV)


def test_stops_when_results_contain_non_dataset_items(run_dir):
    p = run_dir / "results.jsonl"
    rows = [json.loads(l) for l in p.read_text(encoding="utf-8").splitlines()]
    rows[0]["item_id"] = "user-input-001"
    p.write_text("\n".join(json.dumps(r, ensure_ascii=False) for r in rows) + "\n", encoding="utf-8")
    with pytest.raises(JudgeDataError, match="not in the test dataset"):
        build_inputs(run_dir, 5, NO_ENV)


def test_stops_when_spans_or_assembled_text_differ(run_dir):
    p = run_dir / "results.jsonl"
    rows = [json.loads(l) for l in p.read_text(encoding="utf-8").splitlines()]
    rows[0]["spans"][0]["source"] = "別の文章"
    p.write_text("\n".join(json.dumps(r, ensure_ascii=False) for r in rows) + "\n", encoding="utf-8")
    with pytest.raises(JudgeDataError, match="spans differ"):
        build_inputs(run_dir, 5, NO_ENV)


def test_stops_when_stored_assembled_text_is_inconsistent(run_dir):
    p = run_dir / "results.jsonl"
    rows = [json.loads(l) for l in p.read_text(encoding="utf-8").splitlines()]
    rows[0]["assembled_text"] += "余分"
    p.write_text("\n".join(json.dumps(r, ensure_ascii=False) for r in rows) + "\n", encoding="utf-8")
    with pytest.raises(JudgeDataError, match="inconsistent"):
        build_inputs(run_dir, 5, NO_ENV)


def test_stops_without_blind_key_or_with_unreadable_run(run_dir, tmp_path):
    (run_dir / "blind_key.json").unlink()
    with pytest.raises(JudgeDataError):
        build_inputs(run_dir, 5, NO_ENV)
    with pytest.raises(JudgeDataError):
        build_inputs(tmp_path / "nope", 5, NO_ENV)


def _valid_record(run_dir):
    return build_inputs(run_dir, 1, NO_ENV)[0][0]


@pytest.mark.parametrize("mutate", [
    lambda r: r.update(extra="x"),
    lambda r: r.update(model="qwen"),
    lambda r: r.pop("text_ja"),
    lambda r: r["candidates"].update(third={}),
    lambda r: r["candidates"]["first"].update(note="x"),
    lambda r: r["spans"][0].update(path="x"),
    lambda r: r["candidates"]["first"]["spans"][0].update(status="maybe"),
    lambda r: r["candidates"]["first"]["spans"][0].update(status="rejected"),   # english present but rejected
    lambda r: r["candidates"]["first"]["spans"][0].update(english=None),         # accepted without english
    lambda r: r["candidates"]["first"]["spans"].pop(),
])
def test_validate_input_enforces_allow_list(run_dir, mutate):
    rec = _valid_record(run_dir)
    mutate(rec)
    with pytest.raises(JudgeDataError):
        validate_input(rec, ["qwen"], NO_ENV)


@pytest.mark.parametrize("leak", [
    "see /Users/mineno/project/app", "sk-ant-api03-abcdefghijklmnop", "ANTHROPIC_API_KEY=abc", "my api_key is x",
    "-----BEGIN RSA PRIVATE KEY-----", "path .venv/bin/python", "eval_runs/2026", "Qwen said so", "from Ollama",
    "translategemma", "secret-value-123456",
])
def test_leak_scan_stops_on_suspicious_content(run_dir, leak):
    rec = _valid_record(run_dir)
    rec["candidates"]["first"]["spans"][0]["english"] = leak
    env = {"X": "secret-value-123456"}
    with pytest.raises(JudgeDataError):
        validate_input(rec, ["qwen", "translategemma", "ollama"], env)


def test_env_values_are_scanned_but_short_ones_are_ignored(run_dir):
    rec = _valid_record(run_dir)
    rec["candidates"]["first"]["spans"][0]["english"] = "token abcdefghijklmnop here"
    with pytest.raises(JudgeDataError):
        validate_input(rec, [], {"K": "abcdefghijklmnop"})
    validate_input(rec, [], {"K": "short"})


@pytest.mark.parametrize("en,needle", [
    ("/Users/mineno/.ssh", "suspicious"),
    ("sk-ant-api03-abcdefghijklmnopqrstuvwxyz", "suspicious"),
    ("As Qwen wrote", "model name"),                 # the short family name, not only the full tag
    ("a Gemma output", "model name"),
    ("ask translategemma", "model name"),
])
def test_doctored_result_stops_the_whole_build_via_the_real_leak_scan(run_dir, en, needle):
    """Uses build_inputs' own forbidden-term list (not a hand-written one) and keeps assembled_text consistent,
    so the failure can only come from the leak scan."""
    from tests.judge_helpers import rewrite_span
    rewrite_span(run_dir, GEMMA, "keigo-01", "s1", en)
    with pytest.raises(JudgeDataError, match=needle):
        build_inputs(run_dir, 5, NO_ENV)


def test_forbidden_terms_cover_stems_and_families():
    terms = {t.lower() for t in prepare.forbidden_terms([QWEN, GEMMA])}
    assert {"qwen", "gemma", "translategemma", "ollama", QWEN, GEMMA} <= terms


def test_candidate_text_comes_from_what_assemble_adopted(run_dir):
    """A result stored as accepted but rejected by the current validation (or a rewritten result) must stop."""
    p = run_dir / "results.jsonl"
    rows = [json.loads(l) for l in p.read_text(encoding="utf-8").splitlines()]
    for r in rows:
        if r["model"] == QWEN and r["item_id"] == "keigo-01":
            r["spans"][0].update(en="これは日本語です", raw="これは日本語です", accepted=True)     # fails validation
    p.write_text("\n".join(json.dumps(x, ensure_ascii=False) for x in rows) + "\n", encoding="utf-8")
    with pytest.raises(JudgeDataError):
        build_inputs(run_dir, 5, NO_ENV)


def test_translation_invalid_under_current_rules_is_refused(run_dir):
    """An over-long stored translation is no longer adopted by assemble(), so it cannot reach the judge."""
    from tests.judge_helpers import rewrite_span
    rewrite_span(run_dir, QWEN, "keigo-01", "s1", "word " * 150)
    with pytest.raises(JudgeDataError, match="not accepted by the current validation"):
        build_inputs(run_dir, 5, NO_ENV)


def test_candidate_bodies_match_their_labels(run_dir):
    """candidates.first/second must hold the text of the model behind key[...]['first'/'second'] (qwen='english sN',
    gemma='english text' in the fake run)."""
    inputs, key, _ = build_inputs(run_dir, 3, NO_ENV)
    blind = json.loads((run_dir / "blind_key.json").read_text(encoding="utf-8"))
    for rec in inputs:
        for pos in ("first", "second"):
            model = blind[rec["item_id"]][key[rec["input_id"]][pos]]
            for s in rec["candidates"][pos]["spans"]:
                if s["status"] == "accepted":
                    assert s["english"].startswith("english s") == (model == QWEN)
                    assert (s["english"] == "english text") == (model == GEMMA)


def test_input_id_changes_when_the_shown_content_changes(run_dir):
    from tests.judge_helpers import rewrite_span
    before = {r["item_id"] + str(k["order"]): r["input_id"]
              for (r, k) in ((r, build_inputs(run_dir, 2, NO_ENV)[1][r["input_id"]]) for r in build_inputs(run_dir, 2, NO_ENV)[0])}
    rewrite_span(run_dir, GEMMA, "keigo-01", "s1", "A different translation.")
    after = {r["item_id"] + str(k["order"]): r["input_id"]
             for (r, k) in ((r, build_inputs(run_dir, 2, NO_ENV)[1][r["input_id"]]) for r in build_inputs(run_dir, 2, NO_ENV)[0])}
    assert before["keigo-011"] != after["keigo-011"] and before["keigo-012"] != after["keigo-012"]
    assert before["unicode-011"] == after["unicode-011"]                     # unchanged items keep their ids


def test_write_inputs_records_run_binding(run_dir):
    inputs, key, _ = build_inputs(run_dir, 1, NO_ENV)
    write_inputs(run_dir / "judge", inputs, key, run_id=prepare.run_id_of(run_dir))
    meta = json.loads((run_dir / "judge" / "judge_meta.json").read_text(encoding="utf-8"))
    assert meta["run_id"] == prepare.run_id_of(run_dir) and meta["n_inputs"] == 2
    prepare.check_binding(run_dir / "judge", run_dir)


def test_preview_states_scope_and_sends_nothing(run_dir):
    inputs, _, selected = build_inputs(run_dir, 5, NO_ENV)
    text = render_preview(inputs, selected)
    assert "何も送信していません" in text and "テストデータのみ" in text and "モデル名" in text
    assert str(len(inputs)) in text and selected[0] in text
    assert "qwen" not in text.lower() and "gemma" not in text.lower()


def test_existing_comparison_files_are_untouched_and_overwrite_is_refused(run_dir):
    def digests():
        return {p.name: hashlib.sha256(p.read_bytes()).hexdigest() for p in run_dir.iterdir() if p.is_file()}

    before = digests()
    inputs, key, _ = build_inputs(run_dir, 2, NO_ENV)
    jd = run_dir / "judge"
    write_inputs(jd, inputs, key)
    assert digests() == before                                  # human_scores.csv, results, meta unchanged
    with pytest.raises(JudgeDataError, match="already exist"):
        write_inputs(jd, inputs, key)
    write_inputs(jd, inputs, key, force=True)
    assert digests() == before


def test_cli_prepare_ok_and_stops(run_dir, capsys):
    assert cli.main(["prepare", str(run_dir), "--limit", "2"]) == 0
    out = capsys.readouterr().out
    assert "プレビュー" in out and (run_dir / "judge" / "judge_inputs.jsonl").exists()
    _edit_meta(run_dir, dataset_sha256="0" * 64)
    assert cli.main(["prepare", str(run_dir), "--limit", "2", "--force"]) == 2
    assert "停止" in capsys.readouterr().out
    assert cli.main(["prepare", str(run_dir), "--limit", "0"]) == 2
