import hashlib
import json
from dataclasses import dataclass
from pathlib import Path

from backend.spans import Span, SpanError, check_spans, resolve_span

DEFAULT_PATH = Path(__file__).with_name("dataset_ja_en.jsonl")


@dataclass(frozen=True)
class Item:
    id: str
    category: str
    text: str
    spans: list[Span]
    reference_en: dict[str, str]
    injection_canary: str | None
    injection_mode: str | None = None  # "span" | "context" (see eval/injection.py)


def load_dataset(path: Path | str = DEFAULT_PATH) -> list[Item]:
    items: list[Item] = []
    seen: set[str] = set()
    with open(path, encoding="utf-8", newline="") as f:
        for lineno, line in enumerate(f, 1):
            if not line.strip():
                continue
            try:
                row = json.loads(line)
                if row["id"] in seen:
                    raise ValueError(f"duplicate item id {row['id']}")
                seen.add(row["id"])
                spans = [resolve_span(row["text"], s["id"], s["source"], s.get("occurrence"))
                         for s in row["spans"]]
                check_spans(row["text"], spans)
                if bool(row.get("injection_canary")) != (row.get("injection_mode") in ("span", "context")):
                    raise ValueError("injection_canary and injection_mode must be set together")
                items.append(Item(row["id"], row["category"], row["text"], spans,
                                  row.get("reference_en", {}), row.get("injection_canary"), row.get("injection_mode")))
            except (KeyError, ValueError, SpanError) as e:
                raise ValueError(f"{path}:{lineno}: {e}") from None
    return items


def dataset_sha256(path: Path | str = DEFAULT_PATH) -> str:
    return hashlib.sha256(Path(path).read_bytes()).hexdigest()
