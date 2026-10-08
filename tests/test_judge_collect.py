import json

import pytest

from eval.judge import collect
from eval.judge.collect import JudgeOutputError, evaluate_output, parse_judge_text
from eval.judge.prepare import build_inputs, run_id_of, write_inputs
from eval.judge.rubric import weighted_score
from tests.judge_helpers import GEMMA, GOOD, QWEN, judge_output, load_judge, make_run


@pytest.fixture()
def setup(tmp_path):
    run_dir = make_run(tmp_path / "runs", limit=2)
    inputs, key, _ = build_inputs(run_dir, 2, {})
    write_inputs(run_dir / "judge", inputs, key, run_id=run_id_of(run_dir))
    blind = json.loads((run_dir / "blind_key.json").read_text(encoding="utf-8"))
    inp = inputs[0]
    return run_dir, inp, key[inp["input_id"]], blind


def good(setup, **kw):
    _, inp, key, blind = setup
    return judge_output(inp, key, blind, prefer=QWEN, **kw)


# ---- parsing --------------------------------------------------------------------------------

def test_parse_accepts_bare_json_and_one_fenced_block():
    assert parse_judge_text('{"a": 1}') == {"a": 1}
    assert parse_judge_text('```json\n{"a": 1}\n```') == {"a": 1}
    assert parse_judge_text('\n  {"a": 1}  \n') == {"a": 1}


@pytest.mark.parametrize("text,reason", [
    ("", "empty_output"), ("   \n", "empty_output"), (None, "empty_output"),
    ("Here is my evaluation: {\"a\": 1}", "json_parse_error"),          # prose around JSON is not accepted
    ('{"a": 1} thanks', "json_parse_error"),
    ('{"a": 1', "json_parse_error"), ("{'a': 1}", "json_parse_error"), ("not json", "json_parse_error"),
    ("[1, 2]", "not_an_object"), ('"x"', "not_an_object"), ("null", "not_an_object"),
    ("[" * 200000, "json_parse_error"),                                   # RecursionError is contained
    ('```json\n{"a": 1}\n```\n```json\n{"b": 2}\n```', "json_parse_error"),
])
def test_parse_rejects_malformed(text, reason):
    with pytest.raises(JudgeOutputError) as e:
        parse_judge_text(text)
    assert e.value.reason == reason


# ---- whole-output failures: recorded explicitly, never scored ------------------------------------

@pytest.mark.parametrize("make,reason", [
    (lambda s: "not json at all", "json_parse_error"),
    (lambda s: "", "empty_output"),
    (lambda s: "[]", "not_an_object"),
    (lambda s: json.dumps({"input_id": "someone-else", "spans": []}), "input_id_mismatch"),
    (lambda s: json.dumps({**json.loads(good(s)), "spans": []}), "span_mismatch"),
    (lambda s: json.dumps({**json.loads(good(s)), "spans": "oops"}), "span_mismatch"),
    (lambda s: json.dumps({**json.loads(good(s)), "spans": [{"span_id": "zz", "preference": "tie"}]}), "span_mismatch"),
])
def test_invalid_output_marks_every_span_unrated_never_scored(setup, make, reason):
    _, inp, key, _ = setup
    recs = evaluate_output(inp, key, make(setup))
    assert len(recs) == len(inp["spans"])
    for r in recs:
        assert r["input_status"] == "invalid_output"
        assert r["preference_valid"] is False and r["preference_position"] == "unrated"
        for pos in ("first", "second"):
            assert r[pos]["weighted"] is None and r[pos]["scores"] is None       # never a 0
            assert r[pos]["valid"] is False
            if r[pos]["status"] == "accepted":
                assert r[pos]["reason"] == reason


def test_missing_output_is_distinct_from_invalid(setup):
    _, inp, key, _ = setup
    recs = evaluate_output(inp, key, None)
    assert {r["input_status"] for r in recs} == {"missing_output"}
    assert all(r[p]["weighted"] is None for r in recs for p in ("first", "second"))


# ---- per-candidate validation ----------------------------------------------------------------------

def tweak(setup, mutate):
    _, inp, key, blind = setup
    obj = json.loads(good(setup))
    mutate(obj["spans"][0])
    return evaluate_output(inp, key, json.dumps(obj))[0], obj


@pytest.mark.parametrize("bad", [0, 6, -1, 4.5, "4", True, [4], {"v": 4}])
def test_out_of_range_or_wrong_type_scores_are_invalid_not_clamped(setup, bad):
    rec, _ = tweak(setup, lambda sp: sp["first"].update(accuracy=bad))
    assert rec["first"]["valid"] is False and rec["first"]["reason"] == "bad_score:accuracy"
    assert rec["first"]["weighted"] is None and rec["preference_valid"] is False
    assert rec["second"]["valid"] is True                      # the other candidate is unaffected


def test_missing_axis_or_scores_are_invalid(setup):
    rec, _ = tweak(setup, lambda sp: sp["first"].pop("naturalness"))
    assert rec["first"]["reason"] == "missing_axis:naturalness"
    rec, _ = tweak(setup, lambda sp: sp.update(first=None))
    assert rec["first"]["reason"] == "missing_scores" and rec["first"]["weighted"] is None
    rec, _ = tweak(setup, lambda sp: sp.update(first="great"))
    assert rec["first"]["reason"] == "missing_scores"


@pytest.mark.parametrize("errors", ["oops", [{"type": "typo", "note": "x"}], ["str"], [{"note": "x"}]])
def test_bad_critical_errors_invalidate_the_candidate(setup, errors):
    rec, _ = tweak(setup, lambda sp: sp["first"].update(critical_errors=errors))
    assert rec["first"]["valid"] is False


def test_all_axes_null_is_unscorable_not_zero(setup):
    rec, _ = tweak(setup, lambda sp: sp["first"].update(accuracy=None, naturalness=None, context=None, proper_nouns=None))
    assert rec["first"]["valid"] is False and rec["first"]["weighted"] is None
    assert rec["first"]["reason"] == "null_not_allowed:accuracy"


@pytest.mark.parametrize("axis", ["accuracy", "naturalness"])
def test_accuracy_and_naturalness_may_not_be_null(setup, axis):
    """A null accuracy must not silently raise a bad translation's average via renormalisation."""
    rec, _ = tweak(setup, lambda sp: sp["first"].update({axis: None}))
    assert rec["first"]["valid"] is False and rec["first"]["reason"] == f"null_not_allowed:{axis}"
    assert rec["first"]["weighted"] is None and rec["preference_valid"] is False


@pytest.mark.parametrize("axis", ["context", "proper_nouns"])
def test_context_and_proper_nouns_may_be_null_and_are_renormalised(setup, axis):
    rec, _ = tweak(setup, lambda sp: sp["first"].update({axis: None}))
    assert rec["first"]["valid"] is True and rec["first"]["scores"][axis] is None
    assert 1 <= rec["first"]["weighted"] <= 5


def test_critical_errors_survive_an_otherwise_invalid_candidate(setup):
    errs = [{"type": "mistranslation", "note": "meaning reversed"}]
    rec, _ = tweak(setup, lambda sp: sp["first"].update(accuracy=9, critical_errors=errs))
    assert rec["first"]["valid"] is False and rec["first"]["weighted"] is None
    assert rec["first"]["critical_errors"] == errs                      # the finding is not lost


def test_stale_and_foreign_raw_outputs_are_not_used(setup):
    """input_id embeds a hash of the exact content shown to the judge."""
    run_dir, _, _, blind = setup
    jd = run_dir / "judge"
    inputs, keys = load_judge(jd)
    from tests.judge_helpers import write_raw
    write_raw(jd, "jdeadbeef0000", judge_output(inputs[0], keys[inputs[0]["input_id"]], blind, prefer=QWEN))
    write_raw(jd, inputs[1]["input_id"] + "x", "{}")
    summary = collect.collect(jd, run_dir)
    assert summary["ok"] == 0 and summary["missing_output"] == len(inputs) and summary["stale_raw_ignored"] == 2


def test_collect_survives_non_utf8_and_bom_outputs(setup):
    run_dir, _, _, blind = setup
    jd = run_dir / "judge"
    inputs, keys = load_judge(jd)
    (jd / "raw").mkdir()
    (jd / "raw" / f"{inputs[0]['input_id']}.txt").write_bytes(b"\xff\xfe\x00 not utf8 {")
    good = judge_output(inputs[1], keys[inputs[1]["input_id"]], blind, prefer=QWEN)
    (jd / "raw" / f"{inputs[1]['input_id']}.txt").write_bytes(b"\xef\xbb\xbf" + good.encode("utf-8"))
    summary = collect.collect(jd, run_dir)
    assert summary["invalid_output"] == 1 and summary["ok"] == 1          # one bad file does not stop the rest


def test_collect_refuses_a_directory_from_another_run_or_edited_inputs(setup):
    from eval.judge.prepare import JudgeDataError
    run_dir, _, _, _ = setup
    jd = run_dir / "judge"
    meta = json.loads((jd / "judge_meta.json").read_text(encoding="utf-8"))
    (jd / "judge_meta.json").write_text(json.dumps({**meta, "run_id": "other-run"}), encoding="utf-8")
    with pytest.raises(JudgeDataError, match="different run"):
        collect.collect(jd, run_dir)
    (jd / "judge_meta.json").write_text(json.dumps(meta), encoding="utf-8")
    with open(jd / "judge_inputs.jsonl", "a", encoding="utf-8") as f:
        f.write("\n")
    with pytest.raises(JudgeDataError, match="changed after prepare"):
        collect.collect(jd, run_dir)


@pytest.mark.parametrize("pref", ["both", "", None, 1, "FIRST", ["first"]])
def test_invalid_preference_is_unrated(setup, pref):
    rec, _ = tweak(setup, lambda sp: sp.update(preference=pref))
    assert rec["preference_valid"] is False and rec["preference_position"] == "unrated"
    assert rec["first"]["valid"] and rec["second"]["valid"]    # scores are still usable


def test_critical_error_with_high_accuracy_is_flagged(setup):
    rec, _ = tweak(setup, lambda sp: sp["first"].update(critical_errors=[{"type": "proper_noun", "note": "x"}], accuracy=4))
    assert "accuracy_not_capped" in rec["warnings"]
    assert rec["first"]["critical_errors"] == [{"type": "proper_noun", "note": "x"}]


def test_long_notes_are_clipped(setup):
    rec, _ = tweak(setup, lambda sp: sp["first"].update(note="x" * 5000, critical_errors=[{"type": "omission", "note": "y" * 5000}]))
    assert len(rec["first"]["note"]) == 300 and len(rec["first"]["critical_errors"][0]["note"]) == 300


def test_scores_for_a_rejected_candidate_are_ignored(tmp_path):
    run_dir = make_run(tmp_path / "r", limit=1, gemma_output="[x]")       # every Gemma span is rejected
    inputs, key, _ = build_inputs(run_dir, 1, {})
    blind = json.loads((run_dir / "blind_key.json").read_text(encoding="utf-8"))
    inp = inputs[0]
    k = key[inp["input_id"]]
    obj = json.loads(judge_output(inp, k, blind, prefer=QWEN))
    for sp in obj["spans"]:                                                # a misbehaving judge scores it anyway
        pos = "first" if blind[inp["item_id"]][k["first"]] == GEMMA else "second"
        sp[pos] = {**GOOD, "critical_errors": [], "note": "scored anyway"}
        sp["preference"] = "first"
    recs = evaluate_output(inp, k, json.dumps(obj))
    for r in recs:
        assert r["comparison"] == "not_comparable_rejected" and r["preference_valid"] is False
        gem = r["first"] if blind[inp["item_id"]][k["first"]] == GEMMA else r["second"]
        assert gem["status"] == "rejected" and gem["weighted"] is None and gem["scores"] is None
        assert "judge_scored_rejected" in r["warnings"]


# ---- weights ------------------------------------------------------------------------------------------

def test_weights_and_renormalisation():
    assert weighted_score({"accuracy": 5, "naturalness": 5, "context": 5, "proper_nouns": 5}) == pytest.approx(5)
    full = {"accuracy": 4, "naturalness": 3, "context": 2, "proper_nouns": 1}
    assert weighted_score(full) == pytest.approx(0.4 * 4 + 0.25 * 3 + 0.25 * 2 + 0.1 * 1)
    no_pn = {**full, "proper_nouns": None}                          # weights renormalised over 0.9
    assert weighted_score(no_pn) == pytest.approx((0.4 * 4 + 0.25 * 3 + 0.25 * 2) / 0.9)
    only_two = {"accuracy": 5, "naturalness": None, "context": 3, "proper_nouns": None}
    assert weighted_score(only_two) == pytest.approx((0.4 * 5 + 0.25 * 3) / 0.65)
    assert weighted_score({a: None for a in ("accuracy", "naturalness", "context", "proper_nouns")}) is None
    assert weighted_score({}) is None


# ---- collect() end to end ------------------------------------------------------------------------------

def test_collect_writes_ai_scores_and_counts_statuses(setup):
    run_dir, _, _, blind = setup
    jd = run_dir / "judge"
    inputs, keys = load_judge(jd)
    from tests.judge_helpers import write_raw
    write_raw(jd, inputs[0]["input_id"], judge_output(inputs[0], keys[inputs[0]["input_id"]], blind, prefer=QWEN))
    write_raw(jd, inputs[1]["input_id"], "I cannot comply")
    summary = collect.collect(jd)
    assert summary["inputs"] == len(inputs) and summary["ok"] == 1 and summary["invalid_output"] == 1
    assert summary["missing_output"] == len(inputs) - 2
    lines = [json.loads(l) for l in (jd / "ai_scores.jsonl").read_text(encoding="utf-8").splitlines()]
    assert len(lines) == summary["records"]
    assert not any("qwen" in json.dumps(l).lower() or "gemma" in json.dumps(l).lower() for l in lines)  # labels only
