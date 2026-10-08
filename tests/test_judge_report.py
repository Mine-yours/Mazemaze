import csv
import hashlib
import json
import shutil

import pytest

from eval.judge import cli, collect, report
from eval.judge.prepare import build_inputs, run_id_of, write_inputs
from tests.judge_helpers import BAD, GEMMA, GOOD, QWEN, judge_output, load_judge, make_run, rewrite_span, write_raw


def pipeline(run_dir, outputs):
    """prepare -> mock judge replies -> collect. `outputs(inp, key, blind)` returns raw text or None."""
    inputs, key, _ = build_inputs(run_dir, 5, {})
    jd = run_dir / "judge"
    shutil.rmtree(jd, ignore_errors=True)          # a fresh judge directory for every mock evaluation
    write_inputs(jd, inputs, key, run_id=run_id_of(run_dir))
    blind = json.loads((run_dir / "blind_key.json").read_text(encoding="utf-8"))
    for inp in inputs:
        text = outputs(inp, key[inp["input_id"]], blind)
        if text is not None:
            write_raw(jd, inp["input_id"], text)
    collect.collect(jd)
    return jd, report.analyze(jd, run_dir), blind


@pytest.fixture()
def run_dir(tmp_path):
    return make_run(tmp_path / "runs")


def sp_count(a, model):
    return a["stats"][model]["scored"]


def test_consistent_preference_is_adopted_and_aggregated(run_dir):
    jd, a, _ = pipeline(run_dir, lambda i, k, b: judge_output(
        i, k, b, scores={QWEN: GOOD, GEMMA: BAD}, prefer=QWEN))
    n = a["stats"][QWEN]["scored"]
    assert n == a["stats"][GEMMA]["scored"] > 0
    assert a["pair"]["win"] == n and a["pair"]["inconsistent"] == 0 and a["stats"][QWEN]["wins"] == n
    assert a["stats"][GEMMA]["wins"] == 0
    assert report.statistics.mean(a["stats"][QWEN]["weighted"]) > report.statistics.mean(a["stats"][GEMMA]["weighted"])
    md = report.render_markdown(a, run_dir.name)
    for needle in ("加重平均点", "評価不能", "重大な誤訳", "A/B 比較", "順序入れ替え時の一致率: 100.0%"):
        assert needle in md


def test_position_biased_judge_yields_inconsistent_not_a_winner(run_dir):
    for bias in ("first", "second"):
        _, a, _ = pipeline(run_dir, lambda i, k, b, bias=bias: judge_output(i, k, b, position_bias=bias))
        assert a["pair"]["win"] == 0 and a["pair"]["tie"] == 0 and a["pair"]["inconsistent"] > 0
        assert a["stats"][QWEN]["wins"] == a["stats"][GEMMA]["wins"] == 0
        assert "順序入れ替え時の一致率: 0.0%" in report.render_markdown(a)


def test_tie_inconsistency_and_unrated_are_distinct(run_dir):
    # tie in both orders
    _, a, _ = pipeline(run_dir, lambda i, k, b: judge_output(i, k, b, prefer="tie"))
    assert a["pair"]["tie"] > 0 and a["pair"]["win"] == 0 and a["pair"]["inconsistent"] == 0

    # order 1 says tie, order 2 prefers a model -> inconsistent (not tie, not win)
    def mixed(i, k, b):
        return judge_output(i, k, b, prefer="tie" if k["order"] == 1 else QWEN)

    _, a, _ = pipeline(run_dir, mixed)
    assert a["pair"]["inconsistent"] > 0 and a["pair"]["tie"] == 0 and a["pair"]["win"] == 0

    # order 2 missing / invalid -> unrated (evaluation impossible), not inconsistent
    def half(i, k, b):
        return judge_output(i, k, b, prefer=QWEN) if k["order"] == 1 else ("{broken" if i["item_id"] == "keigo-01" else None)

    _, a, _ = pipeline(run_dir, half)
    assert a["pair"]["unrated"] > 0 and a["pair"]["win"] == 0 and a["pair"]["inconsistent"] == 0


def test_rejected_candidates_are_not_scored_and_counted_separately(tmp_path):
    run_dir = make_run(tmp_path / "r", gemma_output="[x]")            # every Gemma translation is rejected
    _, a, _ = pipeline(run_dir, lambda i, k, b: judge_output(i, k, b, prefer=QWEN))
    g, q = a["stats"][GEMMA], a["stats"][QWEN]
    assert g["scored"] == 0 and g["weighted"] == [] and g["rejected"] > 0 and g["unscorable"] == 0
    assert q["scored"] > 0 and q["rejected"] == 0
    assert a["pair"]["not_comparable_rejected"] > 0 and a["pair"]["win"] == 0
    md = report.render_markdown(a)
    row = next(l for l in md.splitlines() if l.startswith("| 加重平均点"))
    assert "N/A" in row and "0.00" not in row                           # never averaged in as a zero
    assert not any("critical" in r for rs in a["queue"].values() for r in rs)


def test_unscorable_accepted_spans_are_excluded_not_zeroed(run_dir):
    def broken(i, k, b):
        obj = json.loads(judge_output(i, k, b, prefer=QWEN))
        for sp in obj["spans"]:
            sp["first"] = None if i["item_id"] == "keigo-01" else sp["first"]
            sp["second"] = None if i["item_id"] == "keigo-01" else sp["second"]
        return json.dumps(obj)

    _, a, _ = pipeline(run_dir, broken)
    assert a["stats"][QWEN]["unscorable"] == 2 and a["stats"][GEMMA]["unscorable"] == 2
    assert all(w >= 1 for w in a["stats"][QWEN]["weighted"])            # no 0 entries
    assert any(r.startswith("unscorable") for r in a["queue"][("keigo-01", "s1")])


def test_known_mistranslation_is_detected_and_queued(tmp_path):
    """The 𠮷野家 -> 'Sano house' mistranslation observed in the real run: a judge that flags it must
    surface as a critical error for that candidate, in the report and in the human review queue."""
    run_dir = make_run(tmp_path / "r")
    rewrite_span(run_dir, QWEN, "unicode-01", "s1", "ate breakfast at the Sano house,")

    def judge(i, k, b):
        crit = {}
        if i["item_id"] == "unicode-01":
            crit = {QWEN: [{"type": "proper_noun", "note": "𠮷野家 (Yoshinoya) mistranslated as 'Sano house'"}]}
        scores = {QWEN: GOOD, GEMMA: GOOD}
        if i["item_id"] == "unicode-01":
            scores = {QWEN: {**BAD, "accuracy": 1}, GEMMA: GOOD}
        obj = json.loads(judge_output(i, k, b, scores=scores, critical=crit,
                                      prefer=GEMMA if i["item_id"] == "unicode-01" else "tie"))
        for sp in obj["spans"]:                      # only s1 contains 𠮷野家; s2 (𠮷田) is not flagged
            if sp["span_id"] != "s1":
                for pos in ("first", "second"):
                    sp[pos]["critical_errors"] = []
        return json.dumps(obj, ensure_ascii=False)

    jd, a, blind = pipeline(run_dir, judge)
    assert a["stats"][QWEN]["critical"]["proper_noun"] == 1 and a["stats"][QWEN]["critical_spans"] == 1
    assert a["stats"][QWEN]["critical_both_orders"] == 1
    assert a["stats"][GEMMA]["critical_spans"] == 0
    assert a["stats"][GEMMA]["wins"] >= 1
    report.build(jd, run_dir)
    md = (jd / "judge_report.md").read_text(encoding="utf-8")
    assert "unicode-01/s1" in md and "Sano house" in md
    rows = list(csv.DictReader((jd / "review_queue.csv").read_text(encoding="utf-8-sig").splitlines()))
    hit = next(r for r in rows if r["item_id"] == "unicode-01" and r["span_id"] == "s1")
    qlabel = next(l for l, m in blind["unicode-01"].items() if m == QWEN)
    assert f"critical_error[{qlabel}]:proper_noun" in hit["reasons"]
    assert "Sano house" in hit[f"english_{qlabel}"] and "Sano house" in hit["judge_notes"]
    assert hit["human_decision"] == ""                                 # left for a human


def test_review_queue_is_blind_and_safe_and_lists_problem_spans(run_dir):
    def judge(i, k, b):
        return judge_output(i, k, b, prefer=QWEN, model="claude-sonnet-5-5" if i["item_id"] == "keigo-02" else "claude-opus-5-5",
                            critical={GEMMA: [{"type": "omission", "note": "=cmd|' /C calc'!A0"}]} if i["item_id"] == "keigo-01" else None)

    jd, a, _ = pipeline(run_dir, judge)
    report.build(jd, run_dir)
    raw = (jd / "review_queue.csv").read_bytes()
    assert raw[:3] == b"\xef\xbb\xbf"
    text = raw.decode("utf-8-sig")
    assert "qwen" not in text.lower() and "gemma" not in text.lower()
    rows = list(csv.DictReader(text.splitlines()))
    reasons = {(r["item_id"], r["span_id"]): r["reasons"] for r in rows}
    assert "judge_model_not_opus" in reasons[("keigo-02", "s1")]
    assert any("critical_error" in v for (item, _), v in reasons.items() if item == "keigo-01")
    assert "警告" in report.render_markdown(a)


def test_judge_model_self_report_is_counted(run_dir):
    _, a, _ = pipeline(run_dir, lambda i, k, b: judge_output(i, k, b, prefer="tie"))
    assert a["ok"] == a["opus"] == 10
    _, a2, _ = pipeline(run_dir, lambda i, k, b: judge_output(i, k, b, prefer="tie", model="unknown"))
    assert a2["opus"] == 0 and "unknown" in report.render_markdown(a2)


def test_preference_contradicting_scores_is_queued(run_dir):
    _, a, _ = pipeline(run_dir, lambda i, k, b: judge_output(i, k, b, scores={QWEN: GOOD, GEMMA: BAD}, prefer=GEMMA))
    assert any("preference_score_mismatch" in r for rs in a["queue"].values() for r in rs)


def test_report_does_not_modify_existing_run_files(run_dir):
    def digests():
        return {p.name: hashlib.sha256(p.read_bytes()).hexdigest() for p in run_dir.iterdir() if p.is_file()}

    before = digests()
    jd, _, _ = pipeline(run_dir, lambda i, k, b: judge_output(i, k, b, prefer=QWEN))
    report.build(jd, run_dir)
    assert digests() == before
    assert {p.name for p in jd.iterdir() if p.is_file()} >= {"judge_inputs.jsonl", "judge_key.json", "ai_scores.jsonl",
                                                             "judge_report.md", "review_queue.csv"}


def test_cli_collect_and_report(run_dir, capsys):
    assert cli.main(["prepare", str(run_dir), "--limit", "2"]) == 0
    jd = run_dir / "judge"
    inputs, keys = load_judge(jd)
    blind = json.loads((run_dir / "blind_key.json").read_text(encoding="utf-8"))
    for inp in inputs:
        write_raw(jd, inp["input_id"], judge_output(inp, keys[inp["input_id"]], blind, prefer=QWEN))
    assert cli.main(["collect", str(run_dir)]) == 0
    assert cli.main(["report", str(run_dir)]) == 0
    assert (jd / "judge_report.md").exists() and (jd / "review_queue.csv").exists()
    assert cli.main(["report", str(run_dir / "missing")]) == 2


def test_spreadsheet_formulas_are_neutralised_in_every_text_column(run_dir):
    rewrite_span(run_dir, QWEN, "keigo-01", "s1", "=HYPERLINK(1)")
    crit = {QWEN: [{"type": "omission", "note": "=cmd|' /C calc'!A0"}]}
    jd, a, blind = pipeline(run_dir, lambda i, k, b: judge_output(i, k, b, prefer="tie", critical=crit))
    report.build(jd, run_dir)
    rows = list(csv.DictReader((jd / "review_queue.csv").read_text(encoding="utf-8-sig").splitlines()))
    cells = [c for r in rows for c in r.values()]
    assert all(not c.startswith(("=", "+", "-", "@")) for c in cells)
    qlabel = next(l for l, m in blind["keigo-01"].items() if m == QWEN)
    hit = next(r for r in rows if r["item_id"] == "keigo-01" and r["span_id"] == "s1")
    assert hit[f"english_{qlabel}"] == "'=HYPERLINK(1)"                    # the English column is covered too
    assert report._csv_safe("=1+1") == "'=1+1" and report._csv_safe("ok") == "ok"


def test_judge_text_cannot_break_the_markdown_report(run_dir):
    nasty = "line1\n# Heading\n| a | b |\n`code`"
    crit = {QWEN: [{"type": "mistranslation", "note": nasty}]}
    jd, a, _ = pipeline(run_dir, lambda i, k, b: judge_output(i, k, b, prefer="tie", critical=crit))
    md = report.render_markdown(a)
    assert "\n# Heading" not in md and "| a | b |" not in md and "`code`" not in md
    assert report._md(nasty) == "line1 # Heading / a / b / 'code'"


def test_unknown_self_report_warns_once_without_flooding_the_queue(run_dir):
    jd, a, _ = pipeline(run_dir, lambda i, k, b: judge_output(i, k, b, prefer="tie", model="unknown"))
    assert a["unknown_model"] == a["ok"] == 10 and a["opus"] == 0
    assert not any("judge_model_not_opus" in r for rs in a["queue"].values() for r in rs)
    md = report.render_markdown(a)
    assert "自己申告なし 10件" in md and "警告" in md


def test_other_model_self_report_is_queued_per_span(run_dir):
    jd, a, _ = pipeline(run_dir, lambda i, k, b: judge_output(i, k, b, prefer="tie", model="claude-sonnet-5-5"))
    assert sum("judge_model_not_opus" in r for rs in a["queue"].values() for r in rs) > 0


def test_report_refuses_a_judge_directory_from_another_run(tmp_path, run_dir):
    from eval.judge.prepare import JudgeDataError
    jd, _, _ = pipeline(run_dir, lambda i, k, b: judge_output(i, k, b, prefer=QWEN))
    other = make_run(tmp_path / "other")
    meta_path = other / "run_meta.json"
    meta_path.write_text(json.dumps({**json.loads(meta_path.read_text(encoding="utf-8")), "run_id": "another-run"}),
                         encoding="utf-8")                      # (two fake runs created in one second share a timestamp id)
    with pytest.raises(JudgeDataError, match="different run"):
        report.analyze(jd, other)


def test_invalid_candidate_with_a_critical_error_is_queued_not_lost(run_dir):
    def judge(i, k, b):
        obj = json.loads(judge_output(i, k, b, prefer=QWEN))
        for sp in obj["spans"]:
            if i["item_id"] == "unicode-01":
                for pos in ("first", "second"):
                    sp[pos]["accuracy"] = None              # invalid: accuracy may not be null
                    sp[pos]["critical_errors"] = [{"type": "proper_noun", "note": "misread name"}]
        return json.dumps(obj)

    _, a, _ = pipeline(run_dir, judge)
    assert any(r.startswith("invalid_but_critical_error") for r in a["queue"][("unicode-01", "s1")])
    assert a["stats"][QWEN]["critical_spans"] == 0           # not counted as a verified finding, but surfaced for review


def test_agreement_line_states_how_many_unrated_are_excluded(run_dir):
    _, a, _ = pipeline(run_dir, lambda i, k, b: judge_output(i, k, b, prefer=QWEN) if k["order"] == 1 else None)
    md = report.render_markdown(a)
    assert "評価不能" in md and "分母から除外" in md
