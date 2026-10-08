"""Generate report.md from a run directory (and optional filled human_scores.csv).

Usage: python -m eval.report eval_runs/<ts> [--scores filled.csv]
"""
import argparse
import csv
import json
import math
import statistics
import sys
from collections import Counter, defaultdict
from pathlib import Path


def percentile_nearest_rank(xs: list[float], p: float) -> float | None:
    if not xs:
        return None
    ordered = sorted(xs)
    return ordered[max(1, math.ceil(p / 100 * len(ordered))) - 1]


def _rate(num: int, den: int) -> float | None:
    return num / den if den else None


def summarize(rows: list[dict]) -> dict:
    by_model: dict[str, list[dict]] = defaultdict(list)
    for r in rows:
        by_model[r["model"]].append(r)
    out = {}
    for model, rs in by_model.items():
        ok = [r for r in rs if not r["error_type"]]
        spans = [s for r in rs for s in r["spans"]]
        accepted = [s for s in spans if s["accepted"]]
        lat = [r["latency_ms"] for r in ok]
        cat: dict[str, list[int]] = defaultdict(lambda: [0, 0])
        for r in rs:
            for s in r["spans"]:
                cat[r["category"]][1] += 1
                cat[r["category"]][0] += bool(s["accepted"])
        inj = {m: {"tested": 0, "followed": 0, "not_testable": 0} for m in ("span", "context")}
        for r in rs:  # rows from older runs have no injection_mode and are not counted
            mode = r.get("injection_mode")
            if mode not in inj:
                continue
            if r.get("injection_testable"):
                inj[mode]["tested"] += 1
                inj[mode]["followed"] += bool(r.get("injection_flag"))
            else:
                inj[mode]["not_testable"] += 1
        out[model] = {
            "items": len(rs),
            "items_ok": len(ok),
            "format_compliant": sum(bool(r["format_compliant"]) for r in ok),
            "format_rate": _rate(sum(bool(r["format_compliant"]) for r in ok), len(ok)),
            "spans": len(spans),
            "spans_accepted": len(accepted),
            "span_rate": _rate(len(accepted), len(spans)),
            "errors": dict(Counter(r["error_type"] for r in rs if r["error_type"])),
            "latency_median_ms": statistics.median(lat) if lat else None,
            "latency_p90_ms": percentile_nearest_rank(lat, 90),
            "reasons": dict(Counter(s["reason"] for s in spans if not s["accepted"] and s["reason"])),
            "categories": {c: {"accepted": a, "spans": n} for c, (a, n) in sorted(cat.items())},
            "injection": inj,
            "preserved_violations": sum(not r["original_preserved"] for r in rs),
        }
    return out


def merge_scores(csv_path: Path | str, blind_key: dict) -> dict:
    """Return {model: {"naturalness": [..], "context_fit": [..]}}. Blank cells are skipped."""
    scores: dict = defaultdict(lambda: {"naturalness": [], "context_fit": []})
    with open(csv_path, encoding="utf-8-sig", newline="") as f:
        for lineno, rec in enumerate(csv.DictReader(f), 2):
            model = blind_key.get(rec.get("item_id"), {}).get(rec.get("label"))
            if model is None:
                raise ValueError(f"{csv_path}:{lineno}: unknown item_id/label ({rec.get('row_id')})")
            for col in ("naturalness", "context_fit"):
                v = (rec.get(col) or "").strip()
                if not v:
                    continue
                if v not in {"1", "2", "3", "4", "5"}:
                    raise ValueError(f"{csv_path}:{lineno}: {col} must be 1-5 (got {v!r})")
                scores[model][col].append(int(v))
    return dict(scores)


def _pct(x):
    return "N/A" if x is None else f"{x * 100:.1f}%"


def _inj(v: dict) -> str:
    if v["tested"]:
        extra = f"（測定不能 {v['not_testable']}件）" if v["not_testable"] else ""
        return f"{v['followed']}/{v['tested']}{extra}"
    return f"測定不能（{v['not_testable']}件）" if v["not_testable"] else "N/A"


def _ms(x):
    return "N/A" if x is None else f"{x:.0f} ms"


def render_markdown(summary: dict, scores: dict | None = None, meta: dict | None = None) -> str:
    lines = ["# mazemaze ローカルLLM比較レポート", ""]
    if meta:
        status = meta.get("status", "complete")
        if status != "complete":
            lines += [f"> **警告**: この run は完了していません（status: {status}、"
                      f"{meta.get('completed_rows')}/{meta.get('planned_rows')} 行）。"
                      "モデル間の比較には使わないでください。", ""]
        digests = ", ".join(f"{m.get('name')}={str(m.get('digest'))[:12]}" for m in meta.get("models", []))
        lines += [f"- run_id: {meta.get('run_id')}", f"- Ollama: {meta.get('ollama_version')}",
                  f"- 項目数上限(limit): {meta.get('limit')} / repeat: {meta.get('repeat')}",
                  f"- データセット sha256: {str(meta.get('dataset_sha256'))[:12]}",
                  f"- モデル digest: {digests}", ""]
    models = list(summary)
    lines += ["## 概要", "",
              "| 指標 | " + " | ".join(models) + " |", "|---|" + "---|" * len(models)]

    def row(label, fn):
        lines.append(f"| {label} | " + " | ".join(fn(summary[m]) for m in models) + " |")

    row("実行数（モデル×項目×repeat）", lambda s: str(s["items"]))
    row("エラーなしの項目数", lambda s: str(s["items_ok"]))
    row("形式遵守率（エラーなし項目あたり）", lambda s: f"{_pct(s['format_rate'])} ({s['format_compliant']}/{s['items_ok']})")
    row("スパン採用率（全スパンあたり）", lambda s: f"{_pct(s['span_rate'])} ({s['spans_accepted']}/{s['spans']})")
    row("応答時間 median（エラー除く）", lambda s: _ms(s["latency_median_ms"]))
    row("応答時間 p90（nearest-rank）", lambda s: _ms(s["latency_p90_ms"]))
    row("エラー", lambda s: ", ".join(f"{k}:{v}" for k, v in sorted(s["errors"].items())) or "なし")
    row("インジェクション: スパン内の指示（全モデルが見る）に従った項目", lambda s: _inj(s["injection"]["span"]))
    row("インジェクション: スパン外の指示（文脈を渡すモデルのみ測定可）に従った項目", lambda s: _inj(s["injection"]["context"]))
    row("原文が保持されなかった項目（0であるべき）", lambda s: str(s["preserved_violations"]))
    lines.append("")
    if any(summary[m]["injection"]["context"]["not_testable"] for m in models):
        lines += ["> **注意（条件差）**: スパン外の指示は、文脈を受け取るモデルでしか測定できません。"
                  "「測定不能」は「従わなかった」ではなく、0/N と同等に扱えません。モデル間で比較しないでください。", ""]
    for m in models:
        if summary[m]["preserved_violations"]:
            lines.append(f"> **警告**: {m} で原文が保持されなかった項目があります。実装のバグです。")
    lines += ["## 不採用の理由（スパン数）", ""]
    for m in models:
        reasons = summary[m]["reasons"]
        lines.append(f"- {m}: " + (", ".join(f"{k}:{v}" for k, v in sorted(reasons.items())) or "なし"))
    lines += ["", "## カテゴリ別スパン採用率", ""]
    cats = sorted({c for m in models for c in summary[m]["categories"]})
    lines += ["| カテゴリ | " + " | ".join(models) + " |", "|---|" + "---|" * len(models)]
    for c in cats:
        cells = []
        for m in models:
            v = summary[m]["categories"].get(c)
            cells.append(f"{_pct(_rate(v['accepted'], v['spans']))} ({v['accepted']}/{v['spans']})" if v else "N/A")
        lines.append(f"| {c} | " + " | ".join(cells) + " |")
    lines += ["", "## 人手スコア（1〜5）", ""]
    if scores:
        lines += ["| モデル | 自然さ 平均(件数) | 文脈の適切さ 平均(件数) |", "|---|---|---|"]
        for m in models:
            sc = scores.get(m, {"naturalness": [], "context_fit": []})
            cells = [f"{statistics.mean(sc[k]):.2f} ({len(sc[k])})" if sc[k] else "N/A"
                     for k in ("naturalness", "context_fit")]
            lines.append(f"| {m} | {cells[0]} | {cells[1]} |")
    else:
        lines.append("未採点です。human_scores.csv に記入して `--scores` で渡すと集計されます。")
    lines += ["", "## 注記", "",
              "- TranslateGemma は公式プロンプトの形式に文脈欄がないため、スパン単独で翻訳しています（Qwen は全文を文脈として渡しています）。",
              "- temperature 0 と seed 固定でも、出力の完全な再現は保証されません。",
              "- 実行件数が少ない場合（スモークテストは各モデル3件、フル実行でも各30件・1回）、統計的な結論は出せません。",
              "- インジェクションの判定は canary 文字列にもとづく目安です。最終判断は出力の目視で行ってください。",
              "- 検証はURL・メール・数値・コードの欠落／混入、日本語の混入、前置き、プレースホルダなど機械的に検出できるものに限られ、"
              "訳が意味的に正しいことや、言い換えによる重複は検出できません。",
              "- 形式遵守率はスキーマ／形式の遵守、スパン採用率は検証を通過した割合で、翻訳品質そのものではありません。", ""]
    return "\n".join(lines)


def main(argv=None) -> int:
    ap = argparse.ArgumentParser(prog="eval.report")
    ap.add_argument("run_dir")
    ap.add_argument("--scores")
    args = ap.parse_args(argv)
    run_dir = Path(args.run_dir)
    try:
        rows = [json.loads(l) for l in (run_dir / "results.jsonl").read_text(encoding="utf-8").splitlines() if l.strip()]
        meta_path = run_dir / "run_meta.json"
        meta = json.loads(meta_path.read_text(encoding="utf-8")) if meta_path.is_file() else None
        scores = None
        if args.scores:
            key = json.loads((run_dir / "blind_key.json").read_text(encoding="utf-8"))
            scores = merge_scores(args.scores, key)
    except (OSError, ValueError) as e:
        print(f"エラー: {e}")
        return 2
    (run_dir / "report.md").write_text(render_markdown(summarize(rows), scores, meta), encoding="utf-8")
    print(f"出力: {run_dir / 'report.md'}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
