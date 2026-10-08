"""Build the judge inputs from an existing run, with an allow-list, test-data verification and a preview.

Nothing here talks to any model. The inputs contain only: item id, the Japanese sentence and target
spans, the two anonymous candidates (accepted English text / rejected status and the displayed mixed
text). Model names stay in the run's blind_key.json and are never written to the judge directory.
"""
import hashlib
import json
import os
import re
from pathlib import Path

from backend.spans import assemble, is_preserved
from eval.dataset import DEFAULT_PATH, dataset_sha256, load_dataset

INPUT_KEYS = {"input_id", "item_id", "text_ja", "spans", "candidates"}
SPAN_KEYS = {"span_id", "source_ja"}
CANDIDATE_KEYS = {"mixed_text", "spans"}
CANDIDATE_SPAN_KEYS = {"span_id", "status", "english"}
STATUSES = ("accepted", "rejected")
MIN_ENV_VALUE_LEN = 12
MAX_ENGLISH_LEN = 600
KNOWN_FAMILIES = ("qwen", "gemma", "llama", "mistral", "ollama")
_LEAK_PATTERNS = [re.compile(p, re.IGNORECASE) for p in (
    r"sk-ant-", r"sk-[A-Za-z0-9]{20,}", r"/Users/", r"/home/", r"\.venv", r"eval_runs", r"\.claude",
    r"ANTHROPIC", r"api[_-]?key", r"BEGIN [A-Z ]*PRIVATE KEY", r"id_ed25519", r"OLLAMA_",
    r"\btoken=",
)]


class JudgeDataError(ValueError):
    """The data cannot be confirmed to be test data / is not safe to send. Processing must stop."""


def forbidden_terms(models: list[str]) -> list[str]:
    """Full names, every alphabetic stem of them (qwen, translategemma, ...) and well-known families."""
    terms = set(KNOWN_FAMILIES)
    for m in models:
        terms.add(m)
        terms.update(t for t in re.findall(r"[A-Za-z]{3,}", m))
    return sorted(terms)


def input_id(run_id: str, item_id: str, order: int, content: str = "") -> str:
    """Opaque id bound to the run, item, order AND the exact content shown to the judge."""
    return "j" + hashlib.sha256(f"{run_id}|{item_id}|{order}|{content}".encode("utf-8")).hexdigest()[:12]


def _strings(obj):
    if isinstance(obj, str):
        yield obj
    elif isinstance(obj, dict):
        for k, v in obj.items():
            yield from _strings(k)
            yield from _strings(v)
    elif isinstance(obj, list):
        for v in obj:
            yield from _strings(v)


def scan_for_leaks(rec: dict, forbidden_terms: list[str], environ=None) -> None:
    env_values = [v for v in (os.environ if environ is None else environ).values() if len(v) >= MIN_ENV_VALUE_LEN]
    for s in _strings(rec):
        for rx in _LEAK_PATTERNS:
            if rx.search(s):
                raise JudgeDataError(f"{rec.get('item_id')}: suspicious content matching {rx.pattern!r}")
        low = s.lower()
        for term in forbidden_terms:
            if term and term.lower() in low:
                raise JudgeDataError(f"{rec.get('item_id')}: model name appears in the data")
        for v in env_values:
            if v in s:
                raise JudgeDataError(f"{rec.get('item_id')}: an environment variable value appears in the data")


def validate_input(rec: dict, forbidden_terms: list[str], environ=None) -> None:
    """Strict allow-list: exactly the permitted keys and types, then a leak scan."""
    def need(cond, msg):
        if not cond:
            raise JudgeDataError(f"invalid judge input ({rec.get('item_id') if isinstance(rec, dict) else '?'}): {msg}")

    need(isinstance(rec, dict) and set(rec) == INPUT_KEYS, "unexpected or missing top-level keys")
    need(all(isinstance(rec[k], str) for k in ("input_id", "item_id", "text_ja")), "id/text must be strings")
    spans = rec["spans"]
    need(isinstance(spans, list) and spans, "spans must be a non-empty list")
    for s in spans:
        need(isinstance(s, dict) and set(s) == SPAN_KEYS and all(isinstance(v, str) for v in s.values()), "bad span")
    ids = [s["span_id"] for s in spans]
    need(len(set(ids)) == len(ids), "duplicate span ids")
    cands = rec["candidates"]
    need(isinstance(cands, dict) and set(cands) == {"first", "second"}, "candidates must be first/second")
    for c in cands.values():
        need(isinstance(c, dict) and set(c) == CANDIDATE_KEYS and isinstance(c["mixed_text"], str), "bad candidate")
        need(isinstance(c["spans"], list) and [x.get("span_id") for x in c["spans"]] == ids, "candidate spans differ")
        for x in c["spans"]:
            need(set(x) == CANDIDATE_SPAN_KEYS and x["status"] in STATUSES, "bad candidate span")
            need((x["status"] == "accepted") == isinstance(x["english"], str), "english must exist iff accepted")
    scan_for_leaks(rec, forbidden_terms, environ)


def _load_run(run_dir: Path):
    try:
        meta = json.loads((run_dir / "run_meta.json").read_text(encoding="utf-8"))
        rows = [json.loads(l) for l in (run_dir / "results.jsonl").read_text(encoding="utf-8").splitlines() if l.strip()]
        key = json.loads((run_dir / "blind_key.json").read_text(encoding="utf-8"))
    except (OSError, ValueError) as e:
        raise JudgeDataError(f"cannot read the run files ({type(e).__name__})") from None
    return meta, rows, key


def verify_test_data(meta: dict, rows: list[dict], items: dict) -> None:
    """Stop unless the run demonstrably evaluated the repository's own test dataset."""
    if meta.get("dataset_sha256") != dataset_sha256(DEFAULT_PATH):
        raise JudgeDataError("run_meta dataset_sha256 does not match eval/dataset_ja_en.jsonl: "
                             "cannot confirm that this is the test data")
    if meta.get("status") != "complete":
        raise JudgeDataError(f"the run is not complete (status={meta.get('status')!r})")
    for r in rows:
        item = items.get(r.get("item_id"))
        if item is None or r.get("category") != item.category:
            raise JudgeDataError(f"results contain an item that is not in the test dataset: {r.get('item_id')!r}")
        by_id = {s.get("id"): s for s in r.get("spans", [])}
        if [s.id for s in item.spans] != list(by_id) or any(by_id[s.id].get("source") != s.source for s in item.spans):
            raise JudgeDataError(f"{item.id}: spans differ from the test dataset")


def build_inputs(run_dir: Path, limit: int | None = None, environ=None):
    """Return (inputs, judge_key, selected_item_ids). Raises JudgeDataError on any doubt."""
    run_dir = Path(run_dir)
    meta, rows, blind_key = _load_run(run_dir)
    items = {i.id: i for i in load_dataset()}
    verify_test_data(meta, rows, items)
    run_id = str(meta.get("run_id") or run_dir.name)
    first_rows = {}
    for r in rows:
        if r.get("repeat") == 1:
            first_rows[(r["model"], r["item_id"])] = r
    models = sorted({m for m, _ in first_rows})
    selected = [i for i in items if all((m, i) in first_rows for m in models)]
    if len(models) != 2:
        raise JudgeDataError(f"exactly two models are required (found {len(models)})")
    if limit is not None:
        selected = selected[:limit]
    if not selected:
        raise JudgeDataError("no items to evaluate")
    forbidden = forbidden_terms(models)

    inputs, key = [], {}
    for item_id in selected:
        item = items[item_id]
        labels = blind_key.get(item_id)
        if not isinstance(labels, dict) or sorted(labels.values()) != models:
            raise JudgeDataError(f"{item_id}: blind_key does not map the two models")
        cand_by_label = {}
        for label, model in labels.items():
            row = first_rows[(model, item_id)]
            by_id = {s["id"]: s for s in row["spans"]}
            translations = {sid: s["en"] for sid, s in by_id.items() if s["accepted"]}
            segs = assemble(item.text, item.spans, translations)
            mixed = "".join(s.text for s in segs)
            if mixed != row.get("assembled_text") or not is_preserved(item.text, segs):
                raise JudgeDataError(f"{item_id}: assembled text is inconsistent with the stored result")
            en_by_start = {sg.start: sg for sg in segs if sg.kind == "en"}
            cand_spans = []
            for sp in item.spans:
                stored_ok = bool(by_id[sp.id]["accepted"])
                seg = en_by_start.get(sp.start)
                # What the judge sees must be what assemble() actually adopted, not just what was stored.
                if stored_ok and (seg is None or seg.source != sp.source):
                    raise JudgeDataError(f"{item_id}/{sp.id}: stored as accepted but not accepted by the current validation")
                if seg is not None and not stored_ok:
                    raise JudgeDataError(f"{item_id}/{sp.id}: adopted although stored as rejected")
                if seg is not None and (len(seg.text) > MAX_ENGLISH_LEN or "\n" in seg.text):
                    raise JudgeDataError(f"{item_id}/{sp.id}: translation is too long or multi-line")
                cand_spans.append({"span_id": sp.id, "status": "accepted" if seg is not None else "rejected",
                                   "english": seg.text if seg is not None else None})
            cand_by_label[label] = {"mixed_text": mixed, "spans": cand_spans}
        for order, (first, second) in ((1, ("A", "B")), (2, ("B", "A"))):
            body = {"item_id": item_id, "text_ja": item.text,
                    "spans": [{"span_id": s.id, "source_ja": s.source} for s in item.spans],
                    "candidates": {"first": cand_by_label[first], "second": cand_by_label[second]}}
            iid = input_id(run_id, item_id, order, json.dumps(body, ensure_ascii=False, sort_keys=True))
            rec = {"input_id": iid, **body}
            validate_input(rec, forbidden, environ)
            inputs.append(rec)
            key[iid] = {"item_id": item_id, "order": order, "first": first, "second": second}
    return inputs, key, selected


def render_preview(inputs: list[dict], selected: list[str]) -> str:
    n_chars = sum(len(json.dumps(r, ensure_ascii=False)) for r in inputs)
    n_cand = sum(len(c["spans"]) for r in inputs for c in r["candidates"].values())
    lines = [
        "== judge 送信プレビュー（送信前の確認用。ここでは何も送信していません） ==",
        f"対象: eval/dataset_ja_en.jsonl のテストデータのみ（{len(selected)}件: {', '.join(selected)}）",
        f"入力数: {len(inputs)}（各項目を A→B / B→A の2順序）／候補スパン数: {n_cand}／合計 {n_chars} 文字",
        f"含まれる項目（許可リスト）: {', '.join(sorted(INPUT_KEYS))}",
        "含まれないもの: モデル名と対応表、ソースコード、Git情報、環境変数、APIキー、ログ、パス",
        "検証: データセット SHA 一致／結果の件名・スパンがデータセットと一致／許可リスト／漏えいパターン走査 すべて合格",
        "", "--- 先頭の入力（全文） ---", json.dumps(inputs[0], ensure_ascii=False, indent=2),
    ]
    return "\n".join(lines)


def run_id_of(run_dir: Path) -> str:
    try:
        meta = json.loads((Path(run_dir) / "run_meta.json").read_text(encoding="utf-8"))
    except (OSError, ValueError):
        raise JudgeDataError("cannot read run_meta.json") from None
    return str(meta.get("run_id") or Path(run_dir).name)


def write_inputs(out_dir: Path, inputs: list[dict], key: dict, force: bool = False, run_id: str = "") -> None:
    out_dir = Path(out_dir)
    out_dir.mkdir(parents=True, exist_ok=True)
    targets = [out_dir / "judge_inputs.jsonl", out_dir / "judge_key.json", out_dir / "judge_meta.json"]
    if not force and any(t.exists() for t in targets):
        raise JudgeDataError("judge inputs already exist (use --force to regenerate)")
    text = "".join(json.dumps(r, ensure_ascii=False) + "\n" for r in inputs)
    targets[0].write_text(text, encoding="utf-8")
    targets[1].write_text(json.dumps(key, ensure_ascii=False, indent=2), encoding="utf-8")
    targets[2].write_text(json.dumps({"run_id": run_id, "inputs_sha256": hashlib.sha256(text.encode("utf-8")).hexdigest(),
                                      "n_inputs": len(inputs)}, indent=2), encoding="utf-8")


def check_binding(judge_dir: Path, run_dir: Path) -> None:
    """The judge directory must belong to this run and to exactly these inputs."""
    judge_dir = Path(judge_dir)
    try:
        meta = json.loads((judge_dir / "judge_meta.json").read_text(encoding="utf-8"))
        text = (judge_dir / "judge_inputs.jsonl").read_text(encoding="utf-8")
    except (OSError, ValueError):
        raise JudgeDataError("judge_meta.json / judge_inputs.jsonl are missing or unreadable") from None
    if meta.get("run_id") != run_id_of(run_dir):
        raise JudgeDataError("this judge directory belongs to a different run")
    if meta.get("inputs_sha256") != hashlib.sha256(text.encode("utf-8")).hexdigest():
        raise JudgeDataError("judge_inputs.jsonl was changed after prepare")
