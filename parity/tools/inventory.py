#!/usr/bin/env python3
"""Endpoint inventory for the Apache Fineract parity programme.

Reads Fineract's OpenAPI document and parity/inventory/groups.json (the classification of every
API tag as must / should / defer / test-support) and produces:

  parity/inventory/endpoints.csv   one row per API operation, with group and priority
  parity/inventory/SUMMARY.md      counts by priority and by group

Commands:
  fetch   download the OpenAPI document from the running oracle and snapshot it
  build   regenerate endpoints.csv and SUMMARY.md
  check   fail if any operation is unclassified or groups.json is inconsistent with the spec

Standard library only. Python 3.9 or newer.
"""
from __future__ import annotations

import argparse
import csv
import json
import ssl
import sys
import urllib.request
from collections import Counter, defaultdict
from pathlib import Path

HTTP_METHODS = ("get", "post", "put", "delete", "patch")
PRIORITIES = ("must", "should", "defer", "test-support", "ignore")
PARITY_DIR = Path(__file__).resolve().parent.parent
INVENTORY_DIR = PARITY_DIR / "inventory"
GROUPS_FILE = INVENTORY_DIR / "groups.json"


# --- loading ------------------------------------------------------------------------------

def load_groups(path: Path = GROUPS_FILE) -> dict:
    return json.loads(path.read_text(encoding="utf-8"))


def load_spec(groups: dict) -> dict:
    spec_path = INVENTORY_DIR / groups["spec"]
    if not spec_path.exists():
        sys.exit(f"error: {spec_path} not found. Run: python parity/tools/inventory.py fetch")
    return json.loads(spec_path.read_text(encoding="utf-8"))


def tag_index(groups: dict) -> tuple[dict, list[str]]:
    """Map tag -> (group, priority). Also returns a list of problems (duplicates, bad priorities)."""
    index: dict[str, tuple[str, str]] = {}
    problems: list[str] = []
    for group, body in groups["groups"].items():
        for priority, tags in body.get("tags", {}).items():
            if priority not in PRIORITIES:
                problems.append(f"group {group!r}: unknown priority {priority!r}")
                continue
            for tag in tags:
                if tag in index:
                    problems.append(f"tag {tag!r} is classified twice ({index[tag][0]} and {group})")
                index[tag] = (group, priority)
    return index, problems


# --- classification -----------------------------------------------------------------------

def operations(spec: dict):
    """Yield (method, path, operation) for every API operation, sorted for stable output."""
    for path in sorted(spec["paths"]):
        item = spec["paths"][path]
        for method in HTTP_METHODS:
            if method in item:
                yield method.upper(), path, item[method]


def classify(path: str, op: dict, index: dict, overrides: list[dict]) -> tuple[str, str, str, str]:
    """Return (tag, group, priority, note). Unclassified -> ('', '', '', '').

    A tag decides first. Path overrides cover operations the spec left untagged, unless a rule sets
    "applies_to_tagged": true, in which case it also beats the tag.
    """
    tags = op.get("tags") or []
    tag = tags[0] if tags else ""
    if tag in index:
        group, priority = index[tag]
        for rule in overrides:
            if rule.get("applies_to_tagged") and path.startswith(rule["prefix"]):
                return tag, rule["group"], rule["priority"], rule.get("note", "")
        return tag, group, priority, ""
    for rule in overrides:
        if path.startswith(rule["prefix"]):
            return tag, rule["group"], rule["priority"], rule.get("note", "")
    return tag, "", "", ""


def path_params(op: dict, item: dict) -> list[str]:
    params = list(item.get("parameters", [])) + list(op.get("parameters", []))
    return sorted({p["name"] for p in params if p.get("in") == "path"})


def build_rows(spec: dict, groups: dict) -> list[dict]:
    index, _ = tag_index(groups)
    overrides = groups.get("path_overrides", [])
    base = (spec.get("servers") or [{"url": ""}])[0]["url"]
    rows = []
    for method, path, op in operations(spec):
        tag, group, priority, note = classify(path, op, index, overrides)
        params = path_params(op, spec["paths"][path])
        rows.append(
            {
                "method": method,
                "path": path,
                "api_path": base.rstrip("/") + path,
                "operation_id": op.get("operationId", ""),
                "tag": tag,
                "group": group,
                "priority": priority,
                "note": note,
                "path_params": ";".join(params),
                "has_body": "yes" if "requestBody" in op else "no",
                # A read-only call with nothing to fill in: safe for the contract probe.
                "probe_safe": "yes" if method == "GET" and not params else "no",
                "summary": (op.get("summary") or "").replace("\n", " ").strip(),
            }
        )
    return rows


# --- commands -----------------------------------------------------------------------------

def cmd_fetch(args) -> int:
    ctx = ssl.create_default_context()
    ctx.check_hostname = False  # the oracle uses a self-signed certificate (local only)
    ctx.verify_mode = ssl.CERT_NONE
    url = args.base.rstrip("/") + "/fineract.json"
    print(f"Fetching {url}")
    with urllib.request.urlopen(url, context=ctx, timeout=60) as resp:  # noqa: S310 (local oracle)
        spec = json.loads(resp.read().decode("utf-8"))
    version = spec["info"]["version"]
    out = INVENTORY_DIR / f"openapi-{version}.json"
    INVENTORY_DIR.mkdir(parents=True, exist_ok=True)
    out.write_text(json.dumps(spec, separators=(",", ":"), sort_keys=True), encoding="utf-8", newline="\n")
    print(f"Wrote {out} ({out.stat().st_size // 1024} KiB, Fineract {version})")
    return 0


def problems_for(spec: dict, groups: dict) -> list[str]:
    index, problems = tag_index(groups)
    overrides = groups.get("path_overrides", [])
    spec_tags = {t for _, _, op in operations(spec) for t in (op.get("tags") or [])}
    for tag in sorted(set(index) - spec_tags):
        problems.append(f"groups.json lists tag {tag!r}, which is not in the spec")
    for method, path, op in operations(spec):
        _, group, priority, _ = classify(path, op, index, overrides)
        if not priority:
            problems.append(f"unclassified: {method} {path} (tag {(op.get('tags') or ['<none>'])[0]!r})")
    return problems


def cmd_check(_args) -> int:
    groups = load_groups()
    spec = load_spec(groups)
    problems = problems_for(spec, groups)
    version = spec["info"]["version"]
    if problems:
        print(f"{len(problems)} problem(s) classifying Fineract {version}:")
        for p in problems:
            print(f"  - {p}")
        return 1
    print(f"OK: every operation in Fineract {version} is classified")
    return 0


CSV_FIELDS = [
    "method", "path", "api_path", "operation_id", "tag", "group", "priority",
    "note", "path_params", "has_body", "probe_safe", "summary",
]


def write_csv(rows: list[dict], path: Path) -> None:
    with path.open("w", encoding="utf-8", newline="") as f:
        w = csv.DictWriter(f, fieldnames=CSV_FIELDS, lineterminator="\n")
        w.writeheader()
        w.writerows(rows)


def summary_markdown(rows: list[dict], spec: dict) -> str:
    version = spec["info"]["version"]
    by_priority = Counter(r["priority"] or "unclassified" for r in rows)
    per_group: dict[str, Counter] = defaultdict(Counter)
    for r in rows:
        per_group[r["group"] or "unclassified"][r["priority"] or "unclassified"] += 1
    probe_safe = sum(1 for r in rows if r["probe_safe"] == "yes" and r["priority"] in ("must", "should"))

    lines = [
        f"# Endpoint inventory: Apache Fineract {version}",
        "",
        "Generated by `python parity/tools/inventory.py build`. Do not edit by hand: change",
        "`groups.json` and regenerate. The full list is in [endpoints.csv](endpoints.csv).",
        "",
        f"**{len(rows)} operations** across {len({r['path'] for r in rows})} paths.",
        "",
        "## By priority",
        "",
        "| Priority | Operations | Meaning |",
        "|---|---:|---|",
    ]
    meaning = {
        "must": "Needed for the bank pilot",
        "should": "After the pilot core",
        "defer": "Not built early; returns a documented 'not implemented' error",
        "test-support": "Internal endpoints that Fineract's own integration tests call",
        "ignore": "Not part of the API contract",
        "unclassified": "NEEDS A DECISION",
    }
    for p in (*PRIORITIES, "unclassified"):
        if by_priority.get(p):
            lines.append(f"| {p} | {by_priority[p]} | {meaning[p]} |")

    lines += ["", "## By group", "", "| Group | must | should | defer | test-support | ignore | Total |", "|---|---:|---:|---:|---:|---:|---:|"]
    for group in sorted(per_group):
        c = per_group[group]
        cells = [str(c.get(p, 0) or "") for p in PRIORITIES]
        lines.append(f"| {group} | " + " | ".join(cells) + f" | {sum(c.values())} |")

    lines += [
        "",
        "## Contract probe coverage",
        "",
        f"{probe_safe} `must` and `should` operations are read-only calls with no path parameters, so",
        "`parity/tools/contract_probe.py` can call them against any server without setting up data.",
        "",
    ]
    return "\n".join(lines)


def cmd_build(_args) -> int:
    groups = load_groups()
    spec = load_spec(groups)
    problems = problems_for(spec, groups)
    if problems:
        print("Cannot build: fix groups.json first (run `check` for details).", file=sys.stderr)
        for p in problems[:10]:
            print(f"  - {p}", file=sys.stderr)
        return 1
    rows = build_rows(spec, groups)
    write_csv(rows, INVENTORY_DIR / "endpoints.csv")
    (INVENTORY_DIR / "SUMMARY.md").write_text(summary_markdown(rows, spec), encoding="utf-8", newline="\n")
    print(f"Wrote {len(rows)} rows to {INVENTORY_DIR / 'endpoints.csv'} and SUMMARY.md")
    return 0


def main(argv=None) -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = parser.add_subparsers(dest="command", required=True)
    f = sub.add_parser("fetch", help="download the OpenAPI document from the running oracle")
    f.add_argument("--base", default="https://localhost:8443/fineract-provider")
    f.set_defaults(func=cmd_fetch)
    sub.add_parser("build", help="regenerate endpoints.csv and SUMMARY.md").set_defaults(func=cmd_build)
    sub.add_parser("check", help="verify the classification is complete").set_defaults(func=cmd_check)
    args = parser.parse_args(argv)
    return args.func(args)


if __name__ == "__main__":
    sys.exit(main())
