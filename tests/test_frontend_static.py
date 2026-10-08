"""Static checks on the frontend (no browser available): safe DOM use, no external resources."""
import re
from html.parser import HTMLParser
from pathlib import Path

FRONT = Path(__file__).resolve().parent.parent / "frontend"
HTML = (FRONT / "index.html").read_text(encoding="utf-8")
JS = (FRONT / "app.js").read_text(encoding="utf-8")
CSS = (FRONT / "style.css").read_text(encoding="utf-8")


class Collector(HTMLParser):
    def __init__(self):
        super().__init__()
        self.tags = []

    def handle_starttag(self, tag, attrs):
        self.tags.append((tag, dict(attrs)))


def parsed():
    c = Collector()
    c.feed(HTML)
    return c.tags


def test_no_unsafe_dom_apis():
    for bad in ("innerHTML", "outerHTML", "insertAdjacentHTML", "document.write", "eval(", "new Function"):
        assert bad not in JS


def test_no_external_resources_or_inline_handlers():
    for tag, attrs in parsed():
        for k, v in attrs.items():
            assert not k.startswith("on"), (tag, k)
            if k in ("src", "href") and v:
                assert v.startswith("/static/") or v.startswith("#"), v
    assert not re.search(r"https?://", HTML + JS + CSS)
    assert "@import" not in CSS


def test_basics_for_mobile_and_accessibility():
    tags = parsed()
    html_attrs = next(a for t, a in tags if t == "html")
    assert html_attrs.get("lang") == "ja"
    assert any(t == "meta" and a.get("name") == "viewport" and "width=device-width" in a.get("content", "")
               for t, a in tags)
    ids = {a["id"] for _, a in tags if "id" in a}
    assert any(t == "label" and a.get("for") == "input" for t, a in tags)
    ta = next(a for t, a in tags if t == "textarea")
    assert ta["maxlength"] == "1000"
    rng = next(a for t, a in tags if t == "input" and a.get("id") == "ratio")
    assert (rng["min"], rng["max"], rng["value"]) == ("10", "70", "30")
    assert re.search(r'role="status" id="progress-msg"', HTML)
    assert re.search(r'id="error"[^>]*role="alert"', HTML)
    assert 'aria-live="polite"' in HTML
    for used in re.findall(r'\$\("([\w-]+)"\)', JS):
        assert used in ids, used
    assert "overflow-wrap" in CSS and "text-decoration: underline" in CSS
    assert re.search(r"min-height:\s*44px", CSS)


def test_js_uses_api_contract_without_offsets():
    for field in ("segments", "display", "source", "original", "warnings", "stats", "actual_ratio"):
        assert field in JS
    assert ".start" not in JS and ".end" not in JS  # offsets are code points; never slice by them
    assert "ratio: Number(ratio.value) / 100" in JS  # slider is %, API is a 0.1-0.7 ratio


def test_english_spans_are_keyboard_operable_inline_elements():
    assert 'document.createElement("span")' in JS and 'setAttribute("role", "button")' in JS
    assert "el.tabIndex = 0" in JS and '"Enter"' in JS and '" "' in JS
    assert "aria-expanded" in JS
    assert "button.en" not in CSS and ".en {" in CSS
    assert "scroll-padding-bottom" in CSS  # sticky detail panel must not hide focused text
    assert re.search(r'id="error"[^>]*tabindex="-1"', HTML)
