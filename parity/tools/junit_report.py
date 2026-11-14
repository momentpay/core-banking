#!/usr/bin/env python3
"""Summarise Fineract integration-test results (JUnit XML) into pass rates per functional group.

  junit_report.py RESULTS_DIR [--out DIR] [--fail-under PCT]

RESULTS_DIR holds the *.xml files Gradle writes under integration-tests/build/test-results/test.
Each test class is assigned to a functional group (loans, deposits, clients, ...) by matching its
class name against the rules in parity/inventory/test-groups.json. The mapping is a heuristic: it
exists so progress can be read by area, not to replace the per-test results, which are kept in
results.json.

Standard library only. Python 3.9 or newer.
"""
from __future__ import annotations

import argparse
import json
import re
import sys
import xml.etree.ElementTree as ET
from collections import Counter, defaultdict
from pathlib import Path

PARITY_DIR = Path(__file__).resolve().parent.parent
RULES_FILE = PARITY_DIR / "inventory" / "test-groups.json"


def load_rules(path: Path = RULES_FILE) -> list[tuple[re.Pattern, str]]:
    data = json.loads(path.read_text(encoding="utf-8"))
    return [(re.compile(r["match"], re.IGNORECASE), r["group"]) for r in data["rules"]]


def group_for(class_name: str, rules: list[tuple[re.Pattern, str]]) -> str:
    simple = class_name.rsplit(".", 1)[-1]
    for pattern, group in rules:
        if pattern.search(simple):
            return group
    return "other"


def parse_results(results_dir: Path) -> list[dict]:
    """One dict per test case: class, name, outcome (passed / failed / error / skipped), message."""
    cases = []
    for xml_file in sorted(results_dir.glob("*.xml")):
        root = ET.parse(xml_file).getroot()
        suites = [root] if root.tag == "testsuite" else root.findall("testsuite")
        for suite in suites:
            for tc in suite.findall("testcase"):
                outcome, message = "passed", ""
                for tag, label in (("failure", "failed"), ("error", "error"), ("skipped", "skipped")):
                    node = tc.find(tag)
                    if node is not None:
                        outcome, message = label, (node.get("message") or "")[:300]
                        break
                cases.append({"class": tc.get("classname", ""), "name": tc.get("name", ""), "outcome": outcome, "message": message})
    return cases


def summarize(cases: list[dict], rules) -> dict:
    by_group: dict[str, Counter] = defaultdict(Counter)
    for c in cases:
        c["group"] = group_for(c["class"], rules)
        by_group[c["group"]][c["outcome"]] += 1
    total = Counter(c["outcome"] for c in cases)
    return {"total": dict(total), "by_group": {g: dict(v) for g, v in by_group.items()}}


def pass_rate(counter: dict) -> tuple[int, int]:
    """(passed, counted). Skipped tests are not counted."""
    counted = sum(v for k, v in counter.items() if k != "skipped")
    return counter.get("passed", 0), counted


def render(summary: dict, cases: list[dict], source: str) -> str:
    passed, counted = pass_rate(summary["total"])
    pct = 100 * passed / counted if counted else 0.0
    lines = [
        "# Fineract integration-test report", "",
        f"- Results read from: `{source}`", "",
        f"**{passed} of {counted} tests pass ({pct:.1f}%).** Skipped: {summary['total'].get('skipped', 0)}.", "",
        "| Group | Passed | Counted | % |", "|---|---:|---:|---:|",
    ]
    for group in sorted(summary["by_group"]):
        p, n = pass_rate(summary["by_group"][group])
        lines.append(f"| {group} | {p} | {n} | {100 * p / n:.0f}% |" if n else f"| {group} | 0 | 0 | n/a |")
    failing = [c for c in cases if c["outcome"] in ("failed", "error")]
    if failing:
        lines += ["", f"## Failing tests (first {min(len(failing), 40)} of {len(failing)})", ""]
        for c in failing[:40]:
            lines.append(f"- `{c['class'].rsplit('.', 1)[-1]}.{c['name']}` ({c['group']}): {c['message']}")
    lines.append("")
    return "\n".join(lines)


def main(argv=None) -> int:
    p = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    p.add_argument("results_dir", type=Path)
    p.add_argument("--out", type=Path, help="output directory (default: RESULTS_DIR/../summary)")
    p.add_argument("--fail-under", type=float, default=0.0, help="exit 1 if the pass rate is below this percentage")
    args = p.parse_args(argv)

    if not args.results_dir.is_dir():
        sys.exit(f"error: {args.results_dir} is not a directory")
    cases = parse_results(args.results_dir)
    if not cases:
        sys.exit(f"error: no JUnit XML test cases found in {args.results_dir}")
    summary = summarize(cases, load_rules())
    out = args.out or args.results_dir.parent / "summary"
    out.mkdir(parents=True, exist_ok=True)
    (out / "results.json").write_text(json.dumps({"summary": summary, "cases": cases}, indent=1), encoding="utf-8")
    report = render(summary, cases, str(args.results_dir))
    (out / "report.md").write_text(report, encoding="utf-8", newline="\n")
    passed, counted = pass_rate(summary["total"])
    pct = 100 * passed / counted if counted else 0.0
    print(f"{passed}/{counted} pass ({pct:.1f}%). Report: {out / 'report.md'}")
    return 0 if pct >= args.fail_under else 1


if __name__ == "__main__":
    sys.exit(main())
