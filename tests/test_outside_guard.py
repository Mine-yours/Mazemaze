"""Static guard: every production call of validate_translation passes the surrounding text."""
import ast
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent


def _calls():
    for path in [*(ROOT / "backend").rglob("*.py"), *(ROOT / "eval").rglob("*.py")]:
        for node in ast.walk(ast.parse(path.read_text(encoding="utf-8"))):
            if isinstance(node, ast.Call) and getattr(node.func, "id", getattr(node.func, "attr", None)) == "validate_translation":
                yield path.name, node


def test_every_production_call_passes_outside_text():
    calls = list(_calls())
    assert {name for name, _ in calls} == {"spans.py", "qwen_adapter.py", "translategemma_adapter.py"}
    for name, node in calls:
        kw = {k.arg: k.value for k in node.keywords}
        assert "outside" in kw, f"{name}:{node.lineno} omits outside="
        value = kw["outside"]
        assert isinstance(value, ast.Call) and getattr(value.func, "id", None) == "outside_text", \
            f"{name}:{node.lineno} must pass outside=outside_text(text, span), not a literal/default"
