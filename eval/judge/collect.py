"""Parse and validate raw judge outputs into ai_scores.jsonl.

Judge output is untrusted data: anything malformed is recorded as an explicit failure
("invalid_output" / "missing_output"), never silently scored and never turned into a 0.
"""
import json
import re
from pathlib import Path

from eval.judge.prepare import check_binding

from eval.judge.rubric import AXES, CRITICAL_TYPES, PREFERENCES, REQUIRED_AXES, valid_score, weighted_score

_FENCE = re.compile(r"\A```(?:json)?\s*\n(.*)\n```\s*\Z", re.DOTALL)
NOTE_MAX = 300


class JudgeOutputError(ValueError):
    def __init__(self, reason: str):
        super().__init__(reason)
        self.reason = reason


def parse_judge_text(text: str) -> dict:
    """Accept a bare JSON object or one JSON object in a single fenced block; nothing else."""
    if not isinstance(text, str) or not text.strip("\ufeff \t\r\n"):
        raise JudgeOutputError("empty_output")
    body = text.strip("\ufeff \t\r\n")
    m = _FENCE.match(body)
    if m:
        body = m.group(1).strip()
    try:
        obj = json.loads(body)
    except (ValueError, RecursionError):
        raise JudgeOutputError("json_parse_error") from None
    if not isinstance(obj, dict):
        raise JudgeOutputError("not_an_object")
    return obj


def _clip(v) -> str:
    return v[:NOTE_MAX] if isinstance(v, str) else ""


def _candidate(raw, status: str, label: str) -> tuple[dict, list[str]]:
    """Validate one candidate's evaluation. Returns (record, warnings)."""
    rec = {"label": label, "status": status, "valid": False, "reason": None, "scores": None,
           "weighted": None, "critical_errors": [], "note": ""}
    warnings: list[str] = []
    if status == "rejected":
        rec["reason"] = "rejected_by_validator"          # not a quality judgement: tallied separately
        if raw is not None:
            warnings.append("judge_scored_rejected")      # ignored: rejected candidates are never scored
        return rec, warnings
    if not isinstance(raw, dict):
        rec["reason"] = "missing_scores"
        return rec, warnings
    errors = raw.get("critical_errors", [])
    clean = []
    errors_ok = isinstance(errors, list)
    for e in errors if errors_ok else []:
        if isinstance(e, dict) and e.get("type") in CRITICAL_TYPES:
            clean.append({"type": e["type"], "note": _clip(e.get("note"))})
        else:
            errors_ok = False
    # A reported critical error is kept even if the rest of the evaluation is unusable.
    rec["critical_errors"] = clean if errors_ok else []
    if not errors_ok:
        rec["reason"] = "bad_critical_errors"
        return rec, warnings
    scores = {}
    for axis in AXES:
        if axis not in raw:
            rec["reason"] = f"missing_axis:{axis}"
            return rec, warnings
        v = raw[axis]
        if v is None and axis in REQUIRED_AXES:
            rec["reason"] = f"null_not_allowed:{axis}"       # accuracy / naturalness always apply
            return rec, warnings
        if v is not None and not valid_score(v):
            rec["reason"] = f"bad_score:{axis}"
            return rec, warnings
        scores[axis] = v
    weighted = weighted_score(scores)
    if weighted is None:
        rec["reason"] = "no_applicable_axis"
        return rec, warnings
    if clean and scores["accuracy"] > 2:
        warnings.append("accuracy_not_capped")
    rec.update(valid=True, scores=scores, weighted=weighted, critical_errors=clean, note=_clip(raw.get("note")))
    return rec, warnings


def _span_record(inp: dict, key: dict, span_id: str, out_span: dict | None, judge_model: str,
                 input_status: str, input_reason: str | None) -> dict:
    status = {pos: next(s["status"] for s in inp["candidates"][pos]["spans"] if s["span_id"] == span_id)
              for pos in ("first", "second")}
    warnings: list[str] = []
    cands = {}
    for pos in ("first", "second"):
        if out_span is None:
            rec = {"label": key[pos], "status": status[pos], "valid": False,
                   "reason": "rejected_by_validator" if status[pos] == "rejected" else input_reason,
                   "scores": None, "weighted": None, "critical_errors": [], "note": ""}
            w: list[str] = []
        else:
            rec, w = _candidate(out_span.get(pos), status[pos], key[pos])
            rec["label"] = key[pos]
        cands[pos] = rec
        warnings += w
    both_accepted = status["first"] == status["second"] == "accepted"
    pref, pref_valid = "unrated", False
    if both_accepted and out_span is not None:
        raw_pref = out_span.get("preference")
        if raw_pref in PREFERENCES and raw_pref != "unrated" and cands["first"]["valid"] and cands["second"]["valid"]:
            pref, pref_valid = raw_pref, True
    label = {"first": key["first"], "second": key["second"]}.get(pref, pref)
    return {"input_id": inp["input_id"], "item_id": inp["item_id"], "order": key["order"], "span_id": span_id,
            "comparison": "comparable" if both_accepted else "not_comparable_rejected",
            "input_status": input_status, "first": cands["first"], "second": cands["second"],
            "preference_position": pref, "preference_label": label, "preference_valid": pref_valid,
            "comment": _clip(out_span.get("comment")) if isinstance(out_span, dict) else "",
            "warnings": sorted(set(warnings)), "judge_model": judge_model}


def evaluate_output(inp: dict, key: dict, text: str | None) -> list[dict]:
    """Return one ai_scores record per span of this input (never raises)."""
    span_ids = [s["span_id"] for s in inp["spans"]]
    if text is None:
        return [_span_record(inp, key, sid, None, "unknown", "missing_output", "missing_output") for sid in span_ids]
    try:
        obj = parse_judge_text(text)
        if obj.get("input_id") != inp["input_id"]:
            raise JudgeOutputError("input_id_mismatch")
        spans = obj.get("spans")
        if not isinstance(spans, list) or [s.get("span_id") if isinstance(s, dict) else None for s in spans] != span_ids:
            raise JudgeOutputError("span_mismatch")
    except JudgeOutputError as e:
        return [_span_record(inp, key, sid, None, "unknown", "invalid_output", e.reason) for sid in span_ids]
    model = obj.get("judge_model")
    model = model if isinstance(model, str) and model else "unknown"
    return [_span_record(inp, key, s["span_id"], s, model, "ok", None) for s in spans]


def collect(judge_dir: Path, run_dir: Path | None = None) -> dict:
    """Read judge_inputs.jsonl, judge_key.json and raw/<input_id>.txt; write ai_scores.jsonl."""
    judge_dir = Path(judge_dir)
    if run_dir is not None:
        check_binding(judge_dir, run_dir)
    inputs = [json.loads(l) for l in (judge_dir / "judge_inputs.jsonl").read_text(encoding="utf-8").splitlines() if l.strip()]
    keys = json.loads((judge_dir / "judge_key.json").read_text(encoding="utf-8"))
    records, counts = [], {"ok": 0, "invalid_output": 0, "missing_output": 0}
    for inp in inputs:
        raw_path = judge_dir / "raw" / f"{inp['input_id']}.txt"
        text = raw_path.read_text(encoding="utf-8", errors="replace") if raw_path.is_file() else None
        recs = evaluate_output(inp, keys[inp["input_id"]], text)
        counts[recs[0]["input_status"]] += 1
        records += recs
    (judge_dir / "ai_scores.jsonl").write_text("".join(json.dumps(r, ensure_ascii=False) + "\n" for r in records),
                                               encoding="utf-8")
    known = {i["input_id"] for i in inputs}
    raw_dir = judge_dir / "raw"
    stale = sorted(p.stem for p in raw_dir.glob("*.txt") if p.stem not in known) if raw_dir.is_dir() else []
    return {"inputs": len(inputs), **counts, "records": len(records), "stale_raw_ignored": len(stale)}
