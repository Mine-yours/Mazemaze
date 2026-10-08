#!/usr/bin/env python3
"""Run explicit project quality checks by level. Standard library only.

Exit codes: 0 automated checks passed; 1 test failed; 2 config/unverified.
A passing exit code is NOT a claim that pending manual acceptance is complete.
"""
import argparse
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys

ROOT = Path(__file__).resolve().parent.parent
LEVELS = {"quick": 0, "standard": 1, "rigorous": 2}


def load_checks():
    path = ROOT / ".harness/checks.json"
    if not path.is_file():
        raise ValueError(".harness/checks.json not found")
    obj = json.loads(path.read_text(encoding="utf-8"))
    if not isinstance(obj, dict) or not isinstance(obj.get("checks"), list):
        raise ValueError("Expected an object containing checks array")
    manual = obj.get("manual_checks", [])
    if not isinstance(manual, list) or any(not isinstance(x, str) or not x.strip() for x in manual):
        raise ValueError("manual_checks must be a list of nonempty strings")
    seen = set()
    for check in obj["checks"]:
        if not isinstance(check, dict):
            raise ValueError("each check must be an object")
        name, cmd, level = check.get("name"), check.get("cmd"), check.get("level")
        if not isinstance(name, str) or not name.strip() or name in seen:
            raise ValueError("check names must be unique nonempty strings")
        seen.add(name)
        if not isinstance(cmd, list) or not cmd or any(not isinstance(x, str) or not x for x in cmd):
            raise ValueError("cmd must be a nonempty array of nonempty strings")
        if level not in LEVELS:
            raise ValueError("level must be quick, standard or rigorous")
        subdir = check.get("cwd", ".")
        if not isinstance(subdir, str) or not subdir.strip():
            raise ValueError("cwd must be a project-relative directory")
        wd = (ROOT / subdir).resolve()
        if not wd.is_relative_to(ROOT.resolve()) or not wd.is_dir():
            # is_relative_to was added in Python 3.9.
            raise ValueError("cwd must be an existing directory inside the project")
        timeout = check.get("timeout_seconds", 240)
        if type(timeout) is not int or not (1 <= timeout <= 3600):
            raise ValueError("timeout_seconds must be integer 1..3600")
    return obj["checks"], manual


def run(level):
    try:
        checks, manual = load_checks()
    except (ValueError, OSError, json.JSONDecodeError) as exc:
        print("CONFIG ERROR:", exc, flush=True)
        return 2
    selected = [c for c in checks if LEVELS[c["level"]] <= LEVELS[level]]
    if not selected:
        print("NOT VERIFIED: no automated checks configured for this level.")
        print("Edit .harness/checks.json with real executable project commands.")
        return 2
    print("QUALITY GATE:", level, "checks:", len(selected), flush=True)
    env = os.environ.copy()
    env["CI"] = "1"
    for check in selected:
        wd = ROOT / check.get("cwd", ".")
        print("RUN:", check["name"], "cmd=", json.dumps(check["cmd"]), "cwd=", str(wd), flush=True)
        try:
            proc = subprocess.run(check["cmd"], cwd=wd, env=env,
                                  timeout=check.get("timeout_seconds", 240), check=False)
        except (OSError, subprocess.TimeoutExpired) as exc:
            print("FAIL:", check["name"], str(exc))
            return 1
        if proc.returncode:
            print("FAIL:", check["name"], "exit:", proc.returncode)
            return 1
        print("PASS:", check["name"], flush=True)
    if shutil.which("git"):
        for cmd in (["git", "diff", "--check"], ["git", "diff", "--cached", "--check"]):
            res = subprocess.run(cmd, cwd=ROOT, capture_output=True, text=True, check=False)
            if res.returncode == 0:
                print("PASS:", " ".join(cmd))
            elif "not a git repository" in res.stderr.lower():
                print("NOT RUN: git diff check (not a git repository)")
                break
            else:
                print("FAIL:", " ".join(cmd), res.stderr)
                return 1
    else:
        print("NOT RUN: Git unavailable")
    print("AUTOMATED PASS:", len(selected), "check(s) passed.")
    for item in manual:
        print("MANUAL PENDING:", item)
    if manual:
        print("OVERALL: automated checks passed; acceptance is incomplete until manual checks are evidenced.")
    else:
        print("OVERALL: automated checks passed; independently assess acceptance criteria and UI flows.")
    return 0


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--level", choices=list(LEVELS), default="standard")
    args = parser.parse_args()
    return run(args.level)


if __name__ == "__main__":
    sys.exit(main())
