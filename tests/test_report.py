import csv
import json

import pytest

from eval import report


def mk(model, item, cat, spans, error=None, compliant=True, lat=100.0, flag=None, preserved=True,
       mode=None, testable=False):
    return {"model": model, "item_id": item, "category": cat, "error_type": error,
            "latency_ms": lat, "format_compliant": compliant, "injection_flag": flag,
            "original_preserved": preserved, "injection_mode": mode, "injection_testable": testable,
            "spans": [{"id": f"s{i}", "accepted": ok, "reason": None if ok else why}
                      for i, (ok, why) in enumerate(spans)]}


ROWS = [
    mk("A", "i1", "keigo", [(True, None), (False, "empty")], lat=100),
    mk("A", "i2", "idiom", [(True, None)], lat=300),
    mk("A", "i3", "injection", [(False, None)], error="timeout", lat=0, compliant=False, flag=None,
       mode="context", testable=False),
    mk("B", "i1", "keigo", [(True, None), (True, None)], compliant=False, lat=50, flag=None),
    mk("B", "i4", "injection", [(True, None)], lat=70, flag=True, preserved=True, mode="span", testable=True),
]


@pytest.mark.parametrize("xs,med,p90", [(list(range(1, 11)), 5.5, 9), ([5], 5, 5), ([], None, None)])
def test_percentiles(xs, med, p90):
    assert report.percentile_nearest_rank(xs, 90) == p90
    s = report.summarize([mk("M", f"i{i}", "c", [(True, None)], lat=x) for i, x in enumerate(xs)])
    assert s.get("M", {}).get("latency_median_ms") == med


def test_rates_denominators():
    s = report.summarize(ROWS)
    a, b = s["A"], s["B"]
    assert a["items"] == 3 and a["items_ok"] == 2          # error item excluded from compliance
    assert a["format_rate"] == 1.0
    assert a["spans"] == 4 and a["spans_accepted"] == 2 and a["span_rate"] == 0.5
    assert a["errors"] == {"timeout": 1}
    assert a["latency_median_ms"] == 200 and a["latency_p90_ms"] == 300  # error item excluded
    assert a["reasons"] == {"empty": 1}
    assert b["format_rate"] == 0.5 and b["span_rate"] == 1.0
    assert b["injection"]["span"] == {"tested": 1, "followed": 1, "not_testable": 0}
    assert a["injection"]["context"] == {"tested": 0, "followed": 0, "not_testable": 1}  # not "0 followed"
    assert a["categories"]["keigo"] == {"accepted": 1, "spans": 2}


def test_preserved_violation_warning():
    rows = ROWS + [mk("A", "i9", "keigo", [(True, None)], preserved=False)]
    md = report.render_markdown(report.summarize(rows))
    assert "警告" in md


def test_render_has_na_and_models():
    md = report.render_markdown(report.summarize([mk("A", "i1", "c", [(True, None)], error="timeout", lat=0)]))
    assert "N/A" in md and "未採点" in md


def write_csv(path, recs):
    with open(path, "w", encoding="utf-8-sig", newline="") as f:
        w = csv.DictWriter(f, fieldnames=["row_id", "item_id", "label", "naturalness", "context_fit"])
        w.writeheader()
        w.writerows(recs)


KEY = {"i1": {"A": "m1", "B": "m2"}}


def test_merge_human_scores(tmp_path):
    p = tmp_path / "s.csv"
    write_csv(p, [
        {"row_id": "r1", "item_id": "i1", "label": "A", "naturalness": "4", "context_fit": "5"},
        {"row_id": "r2", "item_id": "i1", "label": "B", "naturalness": "2", "context_fit": ""},
        {"row_id": "r3", "item_id": "i1", "label": "B", "naturalness": "", "context_fit": ""},
    ])
    s = report.merge_scores(p, KEY)
    assert s["m1"] == {"naturalness": [4], "context_fit": [5]}
    assert s["m2"] == {"naturalness": [2], "context_fit": []}
    md = report.render_markdown(report.summarize([mk("m1", "i1", "c", [(True, None)])]), s)
    assert "4.00 (1)" in md


@pytest.mark.parametrize("bad", ["0", "6", "abc", "3.5"])
def test_merge_rejects_out_of_range(tmp_path, bad):
    p = tmp_path / "s.csv"
    write_csv(p, [{"row_id": "r1", "item_id": "i1", "label": "A", "naturalness": bad, "context_fit": ""}])
    with pytest.raises(ValueError, match=r":2:"):
        report.merge_scores(p, KEY)


def test_merge_rejects_unknown_row(tmp_path):
    p = tmp_path / "s.csv"
    write_csv(p, [{"row_id": "r1", "item_id": "zzz", "label": "A", "naturalness": "3", "context_fit": ""}])
    with pytest.raises(ValueError, match=r":2:"):
        report.merge_scores(p, KEY)


def test_injection_conditions_not_conflated_in_markdown():
    md = report.render_markdown(report.summarize(ROWS))
    assert "測定不能（1件）" in md          # model A: could not be tested, not "0/1"
    assert "1/1" in md                      # model B: span-mode instruction followed
    assert "条件差" in md and "同等に扱えません" in md
    only_testable = [r for r in ROWS if r["model"] == "B"]
    assert "条件差" not in report.render_markdown(report.summarize(only_testable))


def test_old_rows_without_injection_fields_do_not_crash():
    old = {k: v for k, v in ROWS[0].items() if not k.startswith("injection")}
    s = report.summarize([old])["A"]
    assert s["injection"]["span"]["tested"] == 0 and "N/A" in report.render_markdown({"A": s})


def test_cli_writes_report(tmp_path):
    (tmp_path / "results.jsonl").write_text("\n".join(json.dumps(r, ensure_ascii=False) for r in ROWS), encoding="utf-8")
    assert report.main([str(tmp_path)]) == 0
    assert (tmp_path / "report.md").read_text(encoding="utf-8").startswith("# mazemaze")
    assert report.main([str(tmp_path / "missing")]) == 2


def test_incomplete_run_is_flagged_in_report():
    meta = {"run_id": "r", "status": "interrupted", "completed_rows": 40, "planned_rows": 60,
            "dataset_sha256": "a" * 64, "models": [{"name": "A", "digest": "d" * 64}]}
    md = report.render_markdown(report.summarize(ROWS), None, meta)
    assert "この run は完了していません" in md and "40/60" in md and "比較には使わないで" in md
    assert "aaaaaaaaaaaa" in md and "A=dddddddddddd" in md
    ok = report.render_markdown(report.summarize(ROWS), None, {**meta, "status": "complete"})
    assert "完了していません" not in ok
