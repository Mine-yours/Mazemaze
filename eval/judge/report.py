"""Aggregate ai_scores.jsonl into judge_report.md and review_queue.csv.

Models appear only here (resolved through the run's blind_key.json), never in the judge inputs.
A span that could not be scored is counted as such; it never contributes a 0 to any mean.
"""
import csv
import json
import statistics
from collections import Counter, defaultdict
from pathlib import Path

from eval.judge.prepare import check_binding
from eval.judge.rubric import AXES

_FORMULA_PREFIXES = ("=", "+", "-", "@", "\t", "\r")
MISMATCH_DIFF = 0.5


def _csv_safe(v: str) -> str:
    return "'" + v if isinstance(v, str) and v.startswith(_FORMULA_PREFIXES) else v


def _md(v) -> str:
    """Judge-written text goes into Markdown: flatten it so it cannot break the table or add headings."""
    t = " ".join(str(v).split()).replace("|", "/").replace("`", "'")
    return t.lstrip("#>-* ")


def _load_jsonl(path: Path) -> list[dict]:
    return [json.loads(l) for l in path.read_text(encoding="utf-8").splitlines() if l.strip()]


def analyze(judge_dir: Path, run_dir: Path) -> dict:
    judge_dir, run_dir = Path(judge_dir), Path(run_dir)
    check_binding(judge_dir, run_dir)          # refuse a judge directory from another run / edited inputs
    inputs = {r["input_id"]: r for r in _load_jsonl(judge_dir / "judge_inputs.jsonl")}
    keys = json.loads((judge_dir / "judge_key.json").read_text(encoding="utf-8"))
    scores = _load_jsonl(judge_dir / "ai_scores.jsonl")
    blind = json.loads((run_dir / "blind_key.json").read_text(encoding="utf-8"))
    models = sorted({m for item in blind.values() for m in item.values()})

    english = {}  # (item, label, span) -> english or None
    ja_source = {}
    for iid, inp in inputs.items():
        k = keys[iid]
        for pos in ("first", "second"):
            for s in inp["candidates"][pos]["spans"]:
                english[(inp["item_id"], k[pos], s["span_id"])] = s["english"]
        for s in inp["spans"]:
            ja_source[(inp["item_id"], s["span_id"])] = s["source_ja"]

    by_span: dict = defaultdict(dict)
    input_status, judge_models = {}, {}
    for r in scores:
        by_span[(r["item_id"], r["span_id"])][r["order"]] = r
        input_status[r["input_id"]] = r["input_status"]
        judge_models[r["input_id"]] = r["judge_model"]

    st = {m: {"spans": 0, "rejected": 0, "scored": 0, "unscorable": 0, "weighted": [], "stability": [],
              "axes": defaultdict(list), "critical": Counter(), "critical_spans": 0, "critical_both_orders": 0,
              "wins": 0} for m in models}
    pair = Counter()
    unrated_reasons = Counter()
    length = Counter()
    queue = defaultdict(list)  # (item, span) -> [reasons]
    notes = defaultdict(list)
    decided = []

    for (item, span), orders in sorted(by_span.items()):
        model_of = blind[item]
        for label, model in model_of.items():
            recs = []
            for o in (1, 2):
                r = orders.get(o)
                if r is None:
                    continue
                pos = "first" if r["first"]["label"] == label else "second"
                recs.append((o, r[pos]))
            if not recs:
                continue
            s = st[model]
            s["spans"] += 1
            if recs[0][1]["status"] == "rejected":
                s["rejected"] += 1
                continue
            valid = [(o, c) for o, c in recs if c["valid"]]
            for _, c in recs:
                if not c["valid"] and c["critical_errors"]:
                    queue[(item, span)].append(f"invalid_but_critical_error[{label}]")
                    notes[(item, span)] += [f"{label}: {e['note']}" for e in c["critical_errors"] if e["note"]]
            if not valid:
                s["unscorable"] += 1
                reasons = sorted({c["reason"] or "unknown" for _, c in recs})
                queue[(item, span)].append(f"unscorable[{label}]:{'/'.join(reasons)}")
                continue
            s["scored"] += 1
            s["weighted"].append(statistics.mean(c["weighted"] for _, c in valid))
            if len(valid) == 2:
                s["stability"].append(abs(valid[0][1]["weighted"] - valid[1][1]["weighted"]))
            for axis in AXES:
                vals = [c["scores"][axis] for _, c in valid if c["scores"][axis] is not None]
                if vals:
                    s["axes"][axis].append(statistics.mean(vals))
            types = {t: [e["note"] for _, c in valid for e in c["critical_errors"] if e["type"] == t]
                     for t in ("mistranslation", "addition", "omission", "proper_noun")}
            found = {t for t, v in types.items() if v}
            for t in found:
                s["critical"][t] += 1
            if found:
                s["critical_spans"] += 1
                if len(valid) == 2 and all(c["critical_errors"] for _, c in valid):
                    s["critical_both_orders"] += 1
                queue[(item, span)].append(f"critical_error[{label}]:{','.join(sorted(found))}")
                notes[(item, span)] += [f"{label}: {n}" for v in types.values() for n in v if n]
        # pairwise (only when both candidates were accepted and judged in both orders)
        recs = [orders.get(1), orders.get(2)]
        for r in recs:
            if r is None:
                continue
            for w in r["warnings"]:
                queue[(item, span)].append(f"{w}")
            if r["comparison"] == "comparable" and r["first"]["valid"] and r["second"]["valid"] and r["preference_valid"]:
                d = r["first"]["weighted"] - r["second"]["weighted"]
                p = r["preference_position"]
                if (p == "first" and d <= -MISMATCH_DIFF) or (p == "second" and d >= MISMATCH_DIFF) or \
                        (p == "tie" and abs(d) >= 2 * MISMATCH_DIFF):
                    queue[(item, span)].append(f"preference_score_mismatch(order{r['order']})")
        if all(r is not None and r["comparison"] == "comparable" for r in recs):
            verdicts = []
            for r in recs:
                if not r["preference_valid"]:
                    verdicts.append(None)
                elif r["preference_label"] == "tie":
                    verdicts.append("tie")
                else:
                    verdicts.append(model_of[r["preference_label"]])
            if None in verdicts:
                why = "invalid_or_missing_judgement"
                pair["unrated"] += 1
                unrated_reasons[why] += 1
                queue[(item, span)].append("unrated")
            elif verdicts[0] != verdicts[1]:
                pair["inconsistent"] += 1
                queue[(item, span)].append("order_inconsistent")
            elif verdicts[0] == "tie":
                pair["tie"] += 1
            else:
                pair["win"] += 1
                st[verdicts[0]]["wins"] += 1
                win_label = next(l for l, m in model_of.items() if m == verdicts[0])
                lose_label = next(l for l in model_of if l != win_label)
                w_en, l_en = english[(item, win_label, span)], english[(item, lose_label, span)]
                decided.append((w_en, l_en))
                length["longer"] += len(w_en) > len(l_en)
                length["shorter"] += len(w_en) < len(l_en)
                length["equal"] += len(w_en) == len(l_en)
        elif any(r is not None and r["comparison"] != "comparable" for r in recs):
            pair["not_comparable_rejected"] += 1
    ok = [i for i, s in input_status.items() if s == "ok"]
    opus = [i for i in ok if "opus" in judge_models[i].lower()]
    for i, s in input_status.items():
        if s != "ok":
            for sid in [x["span_id"] for x in inputs[i]["spans"]]:
                queue[(inputs[i]["item_id"], sid)].append(s)
        elif judge_models[i] != "unknown" and "opus" not in judge_models[i].lower():
            for sid in [x["span_id"] for x in inputs[i]["spans"]]:
                queue[(inputs[i]["item_id"], sid)].append("judge_model_not_opus")
    unknown = sum(1 for i in ok if judge_models[i] == "unknown")
    return {"unknown_model": unknown, "models": models, "stats": st, "pair": pair, "unrated_reasons": unrated_reasons, "length": length,
            "decided": len(decided), "input_status": Counter(input_status.values()), "judge_models": Counter(judge_models.values()),
            "ok": len(ok), "opus": len(opus), "queue": queue, "notes": notes, "english": english,
            "ja_source": ja_source, "blind": blind}


def _f(x, nd=2):
    return "N/A" if x is None else f"{x:.{nd}f}"


def _mean(xs):
    return statistics.mean(xs) if xs else None


def render_markdown(a: dict, run_id: str = "") -> str:
    models, st, pair = a["models"], a["stats"], a["pair"]
    L = ["# mazemaze 翻訳品質 LLM-as-a-Judge レポート", ""]
    L += [f"- 対象 run: {run_id}（既存の比較結果・`human_scores.csv` は変更していない）",
          f"- Judge 入力: {sum(a['input_status'].values())}件（正常 {a['input_status'].get('ok', 0)} / 出力不正 "
          f"{a['input_status'].get('invalid_output', 0)} / 出力なし {a['input_status'].get('missing_output', 0)}）",
          f"- Judge の自己申告モデル: " + (", ".join(f"{m} ×{n}" for m, n in sorted(a["judge_models"].items())) or "なし"),
          f"- 「opus」と自己申告した正常出力: {a['opus']}/{a['ok']}（自己申告は証明ではない。README の確認方法を参照）", ""]
    if a["ok"] and a["opus"] != a["ok"]:
        L += [f"> **警告**: Opus と自己申告していない出力があります（自己申告なし {a['unknown_model']}件を含む）。"
              "Opus 以外を自己申告した出力のスパンは review_queue.csv に入れました。モデルを別途確認してください。", ""]
    L += ["## モデル別（Judge 採点）", "",
          "| 指標 | " + " | ".join(models) + " |", "|---|" + "---|" * len(models)]

    def row(label, fn):
        L.append(f"| {label} | " + " | ".join(fn(st[m]) for m in models) + " |")

    row("評価したスパン数（候補）", lambda s: str(s["spans"]))
    row("採点できたスパン数", lambda s: str(s["scored"]))
    row("不採用（機械検証で不採用。品質は採点せず別集計）", lambda s: str(s["rejected"]))
    row("評価不能（採用だが有効な採点なし。0点にはしない）", lambda s: str(s["unscorable"]))
    row("加重平均点（1〜5。該当しない軸は除外して重みを再計算）", lambda s: _f(_mean(s["weighted"])))
    for axis, name in zip(AXES, ("意味の正確性", "英語の自然さ", "文脈との整合性", "固有名詞・数値")):
        row(f"　{name}（平均）", lambda s, axis=axis: f"{_f(_mean(s['axes'][axis]))}（{len(s['axes'][axis])}件）")
    row("重大な誤訳等があったスパン数", lambda s: str(s["critical_spans"]))
    row("　内訳（誤訳/追加/欠落/固有名詞）", lambda s: "/".join(str(s["critical"][t]) for t in
                                                         ("mistranslation", "addition", "omission", "proper_noun")))
    row("　うち両順序で指摘されたスパン数", lambda s: str(s["critical_both_orders"]))
    row("順序入れ替え時の点差（平均の絶対差）", lambda s: _f(_mean(s["stability"])))
    L += ["", "## A/B 比較（両候補が採用されたスパン。2順序の判定が一致した場合のみ優劣を採用）", ""]
    decided_total = pair["win"] + pair["tie"] + pair["inconsistent"]
    L += ["| 区分 | 件数 |", "|---|---|"]
    for m in models:
        L.append(f"| {m} の勝ち（両順序で一致） | {st[m]['wins']} |")
    L += [f"| 引き分け（両順序で tie） | {pair['tie']} |",
          f"| 不一致（順序で判定が変わった。優劣は採用しない） | {pair['inconsistent']} |",
          f"| 評価不能（無効・欠落した判定を含む） | {pair['unrated']} |",
          f"| 比較対象外（片方または両方が不採用） | {pair['not_comparable_rejected']} |", "",
          f"- 順序入れ替え時の一致率: {_f(None if not decided_total else (pair['win'] + pair['tie']) / decided_total * 100, 1)}%"
          f"（一致 {pair['win'] + pair['tie']} / 判定できた {decided_total}。評価不能 {pair['unrated']}件は分母から除外）",
          f"- 長さの偏りの確認（一致した勝ちのうち、勝者の方が長かった数）: {a['length']['longer']}/{a['decided']}"
          "（偏りの目安。長い方が勝つ傾向があれば要注意）", "",
          "## 重大な誤訳・情報の追加・欠落・固有名詞の誤訳（個別記録）", ""]
    any_crit = False
    for (item, span), reasons in sorted(a["queue"].items()):
        crit = [r for r in reasons if r.startswith("critical_error")]
        if crit:
            any_crit = True
            L.append(f"- {item}/{span}: {'; '.join(sorted(set(crit)))} — " + " / ".join(_md(n) for n in a["notes"][(item, span)][:4]))
    if not any_crit:
        L.append("- なし")
    L += ["", "## 注意・限界", "",
          "- 自動評価は人手採点の代わりではなく、レビューの優先順位付けに使う。`review_queue.csv` の項目は人が確認する。",
          "- Judge の採点は LLM の判断であり、正解ではない。評価対象は既存のテストデータ（30件のうち実行した分）だけで、少数では統計的な結論は出せない。",
          "- A/B の割り当てと順序は Judge に渡していない。モデル名の対応は run の `blind_key.json`（ローカル）のみ。",
          "- 検証で不採用のスパンは品質を採点していない。不採用が多いモデルの平均点は、採用されたスパンだけの平均である。", ""]
    return "\n".join(L)


def write_review_queue(a: dict, path: Path) -> int:
    rows = []
    labels = sorted({l for item in a["blind"].values() for l in item})
    for (item, span), reasons in sorted(a["queue"].items()):
        en = {l: a["english"].get((item, l, span)) for l in labels}
        rows.append({"item_id": item, "span_id": span, "ja_source": a["ja_source"].get((item, span), ""),
                     **{f"english_{l}": _csv_safe(en[l]) if en[l] is not None else "（不採用）" for l in labels},
                     "reasons": " | ".join(sorted(set(reasons))), "judge_notes": _csv_safe(" / ".join(_md(n) for n in a["notes"][(item, span)][:4])),
                     "human_decision": "", "human_note": ""})
    cols = ["item_id", "span_id", "ja_source", *[f"english_{l}" for l in labels], "reasons", "judge_notes",
            "human_decision", "human_note"]
    with open(path, "w", encoding="utf-8-sig", errors="backslashreplace", newline="") as f:
        w = csv.DictWriter(f, fieldnames=cols)
        w.writeheader()
        w.writerows(rows)
    return len(rows)


def build(judge_dir: Path, run_dir: Path) -> dict:
    a = analyze(judge_dir, run_dir)
    run_id = Path(run_dir).name
    Path(judge_dir, "judge_report.md").write_text(render_markdown(a, run_id), encoding="utf-8")
    n = write_review_queue(a, Path(judge_dir, "review_queue.csv"))
    return {"review_rows": n, "stats": a["stats"], "pair": a["pair"]}
