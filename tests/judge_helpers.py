"""Helpers for the judge tests: a fake comparison run (no Ollama) and mock judge outputs."""
import json
from pathlib import Path

from backend.llm.ollama_client import OllamaClient
from backend.spans import assemble
from eval import run_compare
from eval.dataset import load_dataset
from tests.test_run_compare import FakeOllama

QWEN, GEMMA = "qwen3.5:9b", "translategemma:12b"
GOOD = {"accuracy": 5, "naturalness": 4, "context": 4, "proper_nouns": None}
BAD = {"accuracy": 2, "naturalness": 3, "context": 3, "proper_nouns": None}


def make_run(tmp_path: Path, limit: int = 5, **fake_kwargs) -> Path:
    fake = FakeOllama(**fake_kwargs)
    factory = lambda base_url, timeout: OllamaClient(base_url, timeout, transport=fake)  # noqa: E731
    assert run_compare.main(["--limit", str(limit), "--out", str(tmp_path)], client_factory=factory) == 0
    return next(tmp_path.iterdir())


def rewrite_span(run_dir: Path, model: str, item_id: str, span_id: str, en: str) -> None:
    """Replace one accepted translation in results.jsonl (keeping assembled_text consistent)."""
    items = {i.id: i for i in load_dataset()}
    path = run_dir / "results.jsonl"
    out = []
    for line in path.read_text(encoding="utf-8").splitlines():
        r = json.loads(line)
        if r["model"] == model and r["item_id"] == item_id:
            for s in r["spans"]:
                if s["id"] == span_id:
                    s.update(raw=en, en=en, accepted=True, reason=None)
            it = items[item_id]
            segs = assemble(it.text, it.spans, {s["id"]: s["en"] for s in r["spans"] if s["accepted"]})
            r["assembled_text"] = "".join(s.text for s in segs)
        out.append(json.dumps(r, ensure_ascii=False))
    path.write_text("\n".join(out) + "\n", encoding="utf-8")


def load_judge(judge_dir: Path):
    inputs = [json.loads(l) for l in (judge_dir / "judge_inputs.jsonl").read_text(encoding="utf-8").splitlines()]
    keys = json.loads((judge_dir / "judge_key.json").read_text(encoding="utf-8"))
    return inputs, keys


def judge_output(inp, key, blind, *, scores=None, prefer=None, critical=None, model="claude-opus-5-5", position_bias=None):
    """Build a mock judge reply. `scores`: {model: axis dict}; `prefer`: model name | 'tie' | 'unrated';
    `critical`: {model: [critical error dicts]}; `position_bias`: 'first'/'second' to always pick a position."""
    scores = scores or {QWEN: GOOD, GEMMA: GOOD}
    critical = critical or {}
    model_at = {pos: blind[inp["item_id"]][key[pos]] for pos in ("first", "second")}
    spans = []
    for sp in inp["spans"]:
        entry = {"span_id": sp["span_id"], "comment": "mock"}
        accepted = {}
        for pos in ("first", "second"):
            cs = next(s for s in inp["candidates"][pos]["spans"] if s["span_id"] == sp["span_id"])
            accepted[pos] = cs["status"] == "accepted"
            entry[pos] = ({**scores[model_at[pos]], "critical_errors": critical.get(model_at[pos], []), "note": "mock"}
                          if accepted[pos] else None)
        if not all(accepted.values()):
            entry["preference"] = "unrated"
        elif position_bias:
            entry["preference"] = position_bias
        elif prefer in ("tie", "unrated"):
            entry["preference"] = prefer
        else:
            entry["preference"] = "first" if model_at["first"] == prefer else "second"
        spans.append(entry)
    return json.dumps({"input_id": inp["input_id"], "judge_model": model, "spans": spans}, ensure_ascii=False)


def write_raw(judge_dir: Path, input_id: str, text: str) -> None:
    raw = judge_dir / "raw"
    raw.mkdir(exist_ok=True)
    (raw / f"{input_id}.txt").write_text(text, encoding="utf-8")
