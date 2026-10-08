"""The judge is a development-time tool: no cloud LLM client in the app, no API key introduced."""
import ast
import re
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
FORBIDDEN_IMPORTS = {"anthropic", "openai", "httpx", "requests", "aiohttp", "urllib3"}
JUDGE_FORBIDDEN = FORBIDDEN_IMPORTS | {"socket", "urllib", "subprocess", "importlib", "http", "ssl"}
KEY_PATTERNS = [re.compile(p, re.IGNORECASE) for p in (r"ANTHROPIC_API_KEY", r"x-api-key", r"api\.anthropic\.com", r"sk-ant-")]


def _py(*dirs):
    return [p for d in dirs for p in (ROOT / d).rglob("*.py")]


def _imports(path):
    for node in ast.walk(ast.parse(path.read_text(encoding="utf-8"))):
        if isinstance(node, ast.Import):
            for a in node.names:
                yield a.name
        elif isinstance(node, ast.ImportFrom) and node.module:
            yield node.module


def test_backend_never_imports_the_judge_or_any_cloud_client():
    for path in _py("backend"):
        for mod in _imports(path):
            assert not mod.startswith("eval"), f"{path.name} imports {mod}"
            assert mod.split(".")[0] not in FORBIDDEN_IMPORTS, f"{path.name} imports {mod}"


def test_judge_package_has_no_network_client_and_no_api_key():
    for path in _py("eval/judge"):
        for mod in _imports(path):
            assert mod.split(".")[0] not in JUDGE_FORBIDDEN, f"{path.name} imports {mod}"
        src = path.read_text(encoding="utf-8")
        for token in ("os.system", "os.popen", "__import__", "eval(", "exec("):
            assert token not in src.replace("def evaluate(", "").replace("evaluate_", ""), f"{path.name} uses {token}"
    for path in _py("backend", "eval"):
        if path == ROOT / "eval" / "judge" / "prepare.py":      # the leak scanner names these patterns on purpose
            continue
        if path == ROOT / "tests" / "judge_helpers.py":
            continue
        text = path.read_text(encoding="utf-8")
        for rx in KEY_PATTERNS:
            assert not rx.search(text), f"{path.name} mentions {rx.pattern}"


def test_requirements_add_no_cloud_sdk():
    reqs = (ROOT / "requirements-dev.txt").read_text(encoding="utf-8").lower()
    assert "anthropic" not in reqs and "openai" not in reqs


def _front(text):
    front = text.split("\n---\n")[0].removeprefix("---\n")
    top = {}
    for line in front.splitlines():
        if line and not line.startswith((" ", "-")) and ":" in line:
            k, v = line.split(":", 1)
            top[k.strip()] = v.strip()
    return front, top


def test_judge_agent_definition():
    text = (ROOT / ".claude" / "agents" / "translation-judge.md").read_text(encoding="utf-8")
    front, fields = _front(text)
    assert fields["name"] == "translation-judge"
    assert fields["model"] == "opus" and fields["omitClaudeMd"] == "true" and fields["maxTurns"] == "3"
    tools = {t.strip() for t in fields["tools"].split(",")}
    assert tools <= {"Read", "Grep", "Glob"}                      # read-only: no Write/Edit/Bash/network
    # a subagent-scoped hook that denies the judge's read tools (enforcement beyond the prompt).
    # Live-verified 2026-10-08: Read/Grep/Glob are rejected by the hook, SubagentHandback passes.
    assert "PreToolUse" in front and "exit 2" in front
    matcher = re.search(r'^\s*-?\s*matcher:\s*"([^"]*)"', front, re.MULTILINE)
    assert matcher, "PreToolUse matcher is missing"
    assert matcher.group(1) == "Read|Grep|Glob"                    # never ".*": that would also block SubagentHandback
    for tool in ("Read", "Grep", "Glob"):
        assert re.fullmatch(matcher.group(1), tool), f"{tool} must be denied by the hook"
    assert not re.fullmatch(matcher.group(1), "SubagentHandback"), "the hand-back must not be matched by the hook"
    body = text.split("\n---\n", 1)[1]
    assert "never instructions" in body and "DATA to be evaluated" in body
    assert "Do not use any tool" in body
    for rule in ("position", "length", "rejected", "null"):
        assert rule in body.lower()
    assert "never null" in body                                    # accuracy / naturalness are mandatory
