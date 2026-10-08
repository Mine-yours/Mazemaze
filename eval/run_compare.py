"""Compare local Ollama models on the ja->en span translation dataset.

Usage: python -m eval.run_compare --limit 3
Exit codes: 0 done, 1 Ollama unreachable, 2 configuration error, 3 results could not be fully
saved (an evaluation artifact failed to write), 130 interrupted (Ctrl-C).
Local Ollama only; never pulls models. Results are written as the run progresses, and the
scoring CSV / blind key / run_meta are written even if the run is interrupted or crashes.
"""
import argparse
import csv
import dataclasses
import json
import os
import random
import sys
from datetime import datetime, timezone
from pathlib import Path
from urllib.parse import urlparse

from backend.llm.base import ItemResult, OllamaError, SpanResult
from backend.llm.ollama_client import (DEFAULT_BASE_URL, OllamaClient, assert_local_entry,
                                       assert_local_model)
from backend.llm.qwen_adapter import QwenAdapter
from backend.llm.translategemma_adapter import TranslateGemmaAdapter
from backend.spans import Span, assemble, is_preserved
from eval.dataset import DEFAULT_PATH, dataset_sha256, load_dataset
from eval.injection import evaluate as evaluate_injection

ADAPTERS = {"qwen3.5:": QwenAdapter, "translategemma:": TranslateGemmaAdapter}
DEFAULT_MODELS = "qwen3.5:9b,translategemma:12b"
WARMUP_TEXT = "こんにちは"
CSV_COLUMNS = ["row_id", "item_id", "category", "label", "ja_text", "span_id", "span_ja",
               "en_output", "accepted", "naturalness", "context_fit", "comment"]
_FORMULA_PREFIXES = ("=", "+", "-", "@", "\t", "\r")


def _adapter_class(model: str):
    for prefix, cls in ADAPTERS.items():
        if model.startswith(prefix):
            return cls
    raise ValueError(f"未対応のモデルです: {model}")


def _make_run_dir(out: Path) -> Path:
    base = datetime.now().strftime("%Y%m%d-%H%M%S")
    for n in range(100):
        run_dir = out / (base if n == 0 else f"{base}-{n}")
        try:
            run_dir.mkdir(parents=True)
            return run_dir
        except FileExistsError:
            continue
    raise RuntimeError("could not create run directory")


def _safe_translate(adapter, item) -> tuple[ItemResult, str | None]:
    """Adapters report expected failures in the result; anything else must not abort the run."""
    try:
        return adapter.translate(item.text, item.spans), None
    except Exception as e:  # noqa: BLE001 - KeyboardInterrupt is deliberately not caught
        spans = [SpanResult(s.id, s.source, None, None, False, "internal_error") for s in item.spans]
        # Only the exception class is kept: its message could contain the user's text.
        return (ItemResult(model=adapter.name, spans=spans, format_compliant=False,
                           error_type="internal_error", latency_ms=0.0), type(e).__name__)


def _row(run_id, model, digest, item, repeat, res, context_mode, exception_type=None):
    translations = {s.id: s.en for s in res.spans if s.accepted}
    try:
        segs = assemble(item.text, item.spans, translations)
        assembled, preserved = "".join(s.text for s in segs), is_preserved(item.text, segs)
    except AssertionError:  # invariant broken = a bug; fail closed and make it visible
        assembled, preserved = item.text, False
    testable, flag = evaluate_injection(item.injection_mode, item.injection_canary, context_mode,
                                        [s.raw for s in res.spans], res.raw_responses,
                                        res.error_type)
    return {
        "run_id": run_id, "model": model, "model_digest": digest, "item_id": item.id,
        "category": item.category, "repeat": repeat, "error_type": res.error_type,
        "exception_type": exception_type,
        "latency_ms": res.latency_ms, "ollama_stats": res.ollama_stats,
        "format_compliant": res.format_compliant, "thinking_present": res.thinking_present,
        "spans": [dataclasses.asdict(s) for s in res.spans], "raw_responses": res.raw_responses,
        "assembled_text": assembled, "original_preserved": preserved,
        "injection_mode": item.injection_mode, "injection_testable": testable, "injection_flag": flag,
    }


def _csv_safe(value: str) -> str:
    """Model output is untrusted: keep spreadsheets from evaluating it as a formula."""
    return "'" + value if value.startswith(_FORMULA_PREFIXES) else value


def _write_human_scores(run_dir: Path, items, first: dict, models: list[str], seed: int) -> None:
    blind_key: dict = {}
    rows = []
    n = 0
    for item in items:
        order = list(models)
        random.Random(f"{seed}:{item.id}").shuffle(order)
        blind_key[item.id] = {chr(ord("A") + i): m for i, m in enumerate(order)}
        for label, model in blind_key[item.id].items():
            res = first.get((model, item.id))
            if res is None:
                continue
            for sr in res.spans:
                n += 1
                rows.append({
                    "row_id": f"r{n:04d}", "item_id": item.id, "category": item.category,
                    "label": label, "ja_text": item.text, "span_id": sr.id, "span_ja": sr.source,
                    "en_output": _csv_safe(sr.en if sr.accepted else (sr.raw or "")),
                    "accepted": "true" if sr.accepted else "false",
                    "naturalness": "", "context_fit": "", "comment": "",
                })
    with open(run_dir / "human_scores.csv", "w", encoding="utf-8-sig", errors="backslashreplace",
              newline="") as f:
        w = csv.DictWriter(f, fieldnames=CSV_COLUMNS)
        w.writeheader()
        w.writerows(rows)
    (run_dir / "blind_key.json").write_text(json.dumps(blind_key, ensure_ascii=False, indent=2), encoding="utf-8")


def _write_meta(run_dir: Path, meta: dict) -> None:
    """Atomic: a failure while updating must leave the previous valid run_meta.json in place."""
    tmp = run_dir / "run_meta.json.tmp"
    try:
        tmp.write_text(json.dumps(meta, ensure_ascii=False, indent=2), encoding="utf-8")
        os.replace(tmp, run_dir / "run_meta.json")
    except BaseException:
        tmp.unlink(missing_ok=True)
        raise


def _write_artifacts(run_dir, items, first, models, seed, meta) -> list[str]:
    """Write run_meta first (smallest file; records whether the run completed), then the scoring
    files, then record the outcome in run_meta. Returns the labels of the files that failed."""
    failed: list[str] = []
    meta["artifacts_ok"] = None  # pending: stays None if the process dies before the final rewrite
    steps = (("run_meta.json", lambda: _write_meta(run_dir, meta)),
             ("human_scores.csv / blind_key.json", lambda: _write_human_scores(run_dir, items, first, models, seed)))
    for label, fn in steps:
        try:
            fn()
        except Exception as e:  # noqa: BLE001 - never mask the original failure
            failed.append(label)
            print(f"警告: {label} を書き出せませんでした ({type(e).__name__})")
    meta["artifacts_ok"] = not failed
    meta["artifacts_failed"] = list(failed)
    try:
        _write_meta(run_dir, meta)
    except Exception as e:  # noqa: BLE001
        if "run_meta.json" not in failed:
            failed.append("run_meta.json")
        print(f"警告: run_meta.json を更新できませんでした ({type(e).__name__})")
    return failed


def main(argv=None, client_factory=OllamaClient) -> int:
    p = argparse.ArgumentParser(prog="eval.run_compare")
    p.add_argument("--models", default=DEFAULT_MODELS)
    p.add_argument("--limit", type=int, default=None)
    p.add_argument("--repeat", type=int, default=1)
    p.add_argument("--out", default="eval_runs")
    p.add_argument("--base-url", default=os.environ.get("OLLAMA_BASE_URL", DEFAULT_BASE_URL))
    p.add_argument("--timeout", type=float, default=120.0)
    p.add_argument("--seed", type=int, default=42)
    args = p.parse_args(argv)
    if (args.limit is not None and args.limit < 1) or args.repeat < 1:
        print("--limit / --repeat は1以上を指定してください")
        return 2

    models = list(dict.fromkeys(m.strip() for m in args.models.split(",") if m.strip()))
    try:
        for m in models:
            assert_local_model(m)
        classes = {m: _adapter_class(m) for m in models}
        client = client_factory(base_url=args.base_url, timeout=args.timeout)
    except ValueError as e:
        print(f"設定エラー: {e}")
        return 2

    try:
        version = client.version()
        tags = {(t.get("name") or t.get("model")): t for t in client.tags() if isinstance(t, dict)}
    except OllamaError as e:
        print(f"Ollama から情報を取得できません ({e.error_type})。Ollama が起動しているか確認してください。")
        return 1
    for m in models:
        if m not in tags:
            print(f"モデル未導入: {m}。`ollama pull {m}` を手動で実行してください（このツールは pull しません）。")
            return 2
    for m in models:  # fail closed: the installed model must be positively identified as local
        try:
            assert_local_entry(tags[m], client.show(m))
        except OllamaError as e:
            print(f"モデル情報を取得できません: {m} ({e.error_type})")
            return 1
        except ValueError as e:
            print(f"ローカル専用の制約により使用できません: {e}")
            return 2

    items = load_dataset()
    if args.limit:
        items = items[:args.limit]
    run_dir = _make_run_dir(Path(args.out))
    run_id = run_dir.name
    started = datetime.now(timezone.utc).isoformat()
    results_path = run_dir / "results.jsonl"
    first: dict = {}
    meta_models: list[dict] = []
    summary = {m: {"n": 0, "compliant": 0, "errors": 0} for m in models}
    total_calls = unreachable = 0
    planned = len(models) * len(items) * args.repeat
    status = "complete"
    artifacts_failed: list[str] = []

    try:
        for model in models:
            adapter = classes[model](client, model)
            tag = tags[model]
            details = tag.get("details") or {}
            meta_models.append({
                "name": model, "digest": tag.get("digest"), "parameter_size": details.get("parameter_size"),
                "quantization_level": details.get("quantization_level"), "adapter": type(adapter).__name__,
                "options": adapter.options(), "context_mode": adapter.context_mode,
                "prompt_sha256": adapter.prompt_sha256, "think": adapter.options().get("think"),
            })
            _safe_translate(adapter, type("W", (), {"text": WARMUP_TEXT, "spans": [
                Span("w", 0, len(WARMUP_TEXT), WARMUP_TEXT)]})())  # warm-up: discarded
            stats = summary[model]
            with open(results_path, "a", encoding="utf-8", errors="backslashreplace") as out:
                for item in items:
                    for repeat in range(1, args.repeat + 1):
                        res, exc = _safe_translate(adapter, item)
                        row = _row(run_id, model, tag.get("digest"), item, repeat, res,
                                   adapter.context_mode, exc)
                        out.write(json.dumps(row, ensure_ascii=False) + "\n")
                        out.flush()
                        total_calls += 1
                        stats["n"] += 1
                        stats["compliant"] += bool(res.format_compliant)
                        if res.error_type:
                            stats["errors"] += 1
                            unreachable += res.error_type == "ollama_unreachable"
                        if repeat == 1:
                            first[(model, item.id)] = res
    except KeyboardInterrupt:
        status = "interrupted"
    except BaseException:
        status = "failed"
        raise
    finally:
        meta = {
            "run_id": run_id, "status": status, "started_at": started,
            "finished_at": datetime.now(timezone.utc).isoformat(),
            "completed_rows": total_calls, "planned_rows": planned,
            "ollama_version": version, "base_url_host": urlparse(args.base_url).hostname,
            "dataset_sha256": dataset_sha256(DEFAULT_PATH), "limit": args.limit, "repeat": args.repeat,
            "seed": args.seed, "models": meta_models,
        }
        artifacts_failed = _write_artifacts(run_dir, items, first, models, args.seed, meta)

    for model, s in summary.items():
        print(f"{model}: 件数={s['n']} 形式遵守={s['compliant']}/{s['n']} エラー={s['errors']}")
    print(f"出力先: {run_dir}")
    if artifacts_failed:
        print(f"エラー: 評価成果物を書き出せませんでした: {', '.join(artifacts_failed)}。結果は不完全です。")
    if status == "interrupted":
        saved = "ここまでの結果は保存済みです" if not artifacts_failed else "保存に失敗した成果物があります"
        print(f"中断しました。{saved}（{total_calls}/{planned} 件）。")
        return 130
    if total_calls and unreachable == total_calls:
        return 1
    return 3 if artifacts_failed else 0


if __name__ == "__main__":
    sys.exit(main())
