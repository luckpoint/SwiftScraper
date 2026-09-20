#!/usr/bin/env python3
"""Regex eval harness for the swiftscraper skill.

Each case runs in a clean temporary workspace. With --mode both, the same cases
run with and without the skill installed so the skill lift is measurable.
"""
import argparse
import json
import os
import re
import shlex
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path

EVALS_DIR = Path(__file__).resolve().parent
SKILL_DIR = EVALS_DIR.parent
DEFAULT_AGENT = "claude -p --output-format text"


def install_skill(workspace):
    destination = Path(workspace) / ".claude" / "skills" / SKILL_DIR.name
    destination.parent.mkdir(parents=True, exist_ok=True)
    shutil.copytree(SKILL_DIR, destination, ignore=shutil.ignore_patterns("evals"))


def run_agent(prompt, workspace, timeout):
    agent = os.environ.get("SWIFTSCRAPER_EVAL_AGENT", DEFAULT_AGENT)
    result = subprocess.run(
        shlex.split(agent) + [prompt],
        cwd=workspace, capture_output=True, text=True, timeout=timeout,
    )
    return result.stdout


def grade(output, case):
    failures = [f"missing /{p}/" for p in case.get("expect", []) if not re.search(p, output)]
    failures += [f"forbidden /{p}/" for p in case.get("reject", []) if re.search(p, output)]
    return failures


def run_case(case, with_skill, trials, timeout):
    passed, first_failure = 0, None
    for _ in range(trials):
        with tempfile.TemporaryDirectory() as workspace:
            if with_skill:
                install_skill(workspace)
            try:
                output = run_agent(case["prompt"], workspace, timeout)
            except subprocess.TimeoutExpired:
                first_failure = first_failure or ["timeout"]
                continue
        failures = grade(output, case)
        if failures:
            first_failure = first_failure or failures
        else:
            passed += 1
    return passed, first_failure


def run_mode(cases, with_skill, trials, timeout):
    label = "with skill" if with_skill else "no skill"
    print(f"\n=== {label} ({trials} trials/case) ===")
    total = 0
    for case in cases:
        passed, failures = run_case(case, with_skill, trials, timeout)
        total += passed
        mark = "PASS" if passed == trials else ("FLAKY" if passed else "FAIL")
        gap = "  [known gap]" if case.get("known_gap") else ""
        print(f"  {mark:5} {passed}/{trials}  {case['id']}{gap}")
        if failures and passed < trials:
            print(f"         {failures[0]}")
    rate = total / (len(cases) * trials)
    print(f"  ---- {label}: {rate:.1%}")
    return rate


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--mode", choices=["with-skill", "no-skill", "both"], default="with-skill")
    parser.add_argument("--trials", type=int, default=3, help="runs per case (3-5 recommended)")
    parser.add_argument("--timeout", type=int, default=180, help="seconds per agent run")
    parser.add_argument("--group", choices=["happy", "negative", "trace"], help="run one group only")
    parser.add_argument("--case", help="run one case id only")
    args = parser.parse_args()

    cases = json.loads((EVALS_DIR / "cases.json").read_text())["cases"]
    if args.group:
        cases = [c for c in cases if c.get("group") == args.group]
    if args.case:
        cases = [c for c in cases if c["id"] == args.case]
    if not cases:
        sys.exit("no matching cases")

    if args.mode == "both":
        with_rate = run_mode(cases, True, args.trials, args.timeout)
        without_rate = run_mode(cases, False, args.trials, args.timeout)
        print(f"\nskill lift: {with_rate - without_rate:+.1%}")
        print("Lift near zero means the model absorbed the skill; consider retiring it.")
    else:
        run_mode(cases, args.mode == "with-skill", args.trials, args.timeout)


if __name__ == "__main__":
    main()
