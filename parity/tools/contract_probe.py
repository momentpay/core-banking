#!/usr/bin/env python3
"""OpenAPI-driven contract probe: compares a target server with the Apache Fineract oracle.

For every read-only operation in parity/inventory/endpoints.csv that needs no path parameters
(list and template endpoints), the probe calls the oracle and the target with the same
credentials and tenant, then compares:

  * the HTTP status code, and
  * the *shape* of the JSON response: which fields exist and their types. Values are ignored.

It needs no build and no test data, so it is the cheapest parity measurement. It is a first
layer: it does not exercise writes, workflows or calculations. Those are covered by Fineract's own
integration tests (scripts/run-contract-suite.sh) and, later, the differential runner.

Shape comparison only means something when both servers hold comparable data. Where either side
returns an empty array, the fields under that array are not compared.

Standard library only. Python 3.9 or newer.
"""
from __future__ import annotations

import argparse
import base64
import csv
import json
import ssl
import sys
import time
import urllib.error
import urllib.request
from collections import Counter, defaultdict
from concurrent.futures import ThreadPoolExecutor
from datetime import datetime, timezone
from pathlib import Path

PARITY_DIR = Path(__file__).resolve().parent.parent
ENDPOINTS_CSV = PARITY_DIR / "inventory" / "endpoints.csv"
DEFAULT_ORACLE = "https://localhost:8443/fineract-provider"

# --- shapes -------------------------------------------------------------------------------


def _type_name(value) -> str:
    if value is None:
        return "null"
    if isinstance(value, bool):
        return "bool"
    if isinstance(value, (int, float)):
        return "number"
    if isinstance(value, str):
        return "string"
    if isinstance(value, list):
        return "array"
    return "object"


def shape(value, prefix: str = "$", paths: dict | None = None, empty: set | None = None, depth: int = 0):
    """Return (paths, empty_arrays). paths maps a JSON path to the set of types seen there."""
    paths = {} if paths is None else paths
    empty = set() if empty is None else empty
    paths.setdefault(prefix, set()).add(_type_name(value))
    if depth > 12:  # guard against pathological nesting
        return paths, empty
    if isinstance(value, dict):
        for key, child in value.items():
            shape(child, f"{prefix}.{key}", paths, empty, depth + 1)
    elif isinstance(value, list):
        if not value:
            empty.add(prefix)
        for child in value[:25]:  # a sample is enough to learn an element's shape
            shape(child, f"{prefix}[]", paths, empty, depth + 1)
    return paths, empty


def _under(path: str, prefixes: set[str]) -> bool:
    return any(path.startswith(p + "[]") or path == p + "[]" for p in prefixes)


def compare_shapes(oracle_body, target_body) -> dict:
    """Compare two parsed JSON bodies. Returns counts and a few examples per category."""
    o_paths, o_empty = shape(oracle_body)
    t_paths, t_empty = shape(target_body)
    skip = o_empty | t_empty
    o = {p: t for p, t in o_paths.items() if not _under(p, skip)}
    t = {p: ty for p, ty in t_paths.items() if not _under(p, skip)}
    missing = sorted(set(o) - set(t))
    extra = sorted(set(t) - set(o))
    mismatched = sorted(
        p for p in set(o) & set(t) if (o[p] - {"null"}) and (t[p] - {"null"}) and not ((o[p] - {"null"}) & (t[p] - {"null"}))
    )
    return {
        "missing": missing,
        "extra": extra,
        "type_mismatch": [f"{p} (oracle {sorted(o[p])}, target {sorted(t[p])})" for p in mismatched],
        "equal": not (missing or extra or mismatched),
    }


# --- http ---------------------------------------------------------------------------------

_CTX = ssl.create_default_context()
_CTX.check_hostname = False  # local servers use self-signed certificates
_CTX.verify_mode = ssl.CERT_NONE


def call(base: str, api_path: str, headers: dict, timeout: float) -> dict:
    """GET base + api_path. Returns {status, content_type, body (parsed or None), error, ms}."""
    url = base.rstrip("/") + api_path
    req = urllib.request.Request(url, headers=headers, method="GET")
    started = time.monotonic()
    try:
        with urllib.request.urlopen(req, context=_CTX, timeout=timeout) as resp:  # noqa: S310
            status, ctype, raw = resp.status, resp.headers.get("Content-Type", ""), resp.read()
    except urllib.error.HTTPError as err:
        status, ctype, raw = err.code, err.headers.get("Content-Type", "") if err.headers else "", err.read()
    except Exception as err:  # connection refused, timeout, TLS failure, ...
        return {"status": None, "content_type": "", "body": None, "error": f"{type(err).__name__}: {err}", "ms": 0}
    body = None
    if "json" in ctype.lower() and raw:
        try:
            body = json.loads(raw.decode("utf-8"))
        except ValueError:
            body = None
    return {"status": status, "content_type": ctype, "body": body, "error": None, "ms": int((time.monotonic() - started) * 1000)}


def auth_headers(user: str, password: str, tenant: str) -> dict:
    token = base64.b64encode(f"{user}:{password}".encode()).decode()
    return {"Authorization": f"Basic {token}", "Fineract-Platform-TenantId": tenant, "Accept": "application/json"}


# --- probing ------------------------------------------------------------------------------


def load_operations(priorities: set[str], only_group: str | None = None) -> list[dict]:
    if not ENDPOINTS_CSV.exists():
        sys.exit(f"error: {ENDPOINTS_CSV} not found. Run: python parity/tools/inventory.py build")
    with ENDPOINTS_CSV.open(encoding="utf-8", newline="") as f:
        rows = [r for r in csv.DictReader(f) if r["probe_safe"] == "yes" and r["priority"] in priorities]
    if only_group:
        rows = [r for r in rows if r["group"] == only_group]
    return rows


def judge(op_row: dict, oracle: dict | None, target: dict) -> dict:
    """Decide the outcome for one operation.

    Outcomes: PASS, STATUS_DIFF, SHAPE_DIFF, TARGET_ERROR, and SKIPPED when the oracle itself answers
    with a 5xx (a Fineract server error is not a contract to copy). SKIPPED is left out of pass rates.
    """
    result = {
        "method": op_row["method"], "path": op_row["path"], "group": op_row["group"], "priority": op_row["priority"],
        "oracle_status": oracle["status"] if oracle else None, "target_status": target["status"], "detail": {},
    }
    if oracle is not None and oracle["status"] is not None and oracle["status"] >= 500:
        result["outcome"], result["detail"] = "SKIPPED", {"note": f"oracle answered {oracle['status']}"}
        return result
    if target["error"]:
        result["outcome"], result["detail"] = "TARGET_ERROR", {"error": target["error"]}
        return result
    if oracle is None:  # no oracle: a 2xx is the best available signal
        result["outcome"] = "PASS" if 200 <= target["status"] < 300 else "STATUS_DIFF"
        return result
    if oracle["status"] != target["status"]:
        result["outcome"] = "STATUS_DIFF"
        return result
    if oracle["body"] is not None and target["body"] is not None:
        diff = compare_shapes(oracle["body"], target["body"])
        if not diff["equal"]:
            result["outcome"] = "SHAPE_DIFF"
            result["detail"] = {k: v[:10] for k, v in diff.items() if k != "equal" and v}
            result["detail"]["counts"] = {k: len(v) for k, v in diff.items() if k != "equal"}
            return result
    elif (oracle["body"] is None) != (target["body"] is None):
        result["outcome"], result["detail"] = "SHAPE_DIFF", {"note": "one side is JSON and the other is not"}
        return result
    result["outcome"] = "PASS"
    return result


def summarize(results: list[dict]) -> dict:
    total = Counter(r["outcome"] for r in results)
    by_group: dict[str, Counter] = defaultdict(Counter)
    for r in results:
        by_group[r["group"]][r["outcome"]] += 1
    return {"total": len(results), "outcomes": dict(total), "by_group": {g: dict(c) for g, c in by_group.items()}}


def pass_rate(results: list[dict]) -> tuple[int, int]:
    """(passed, counted). SKIPPED operations are not counted."""
    counted = [r for r in results if r["outcome"] != "SKIPPED"]
    return sum(1 for r in counted if r["outcome"] == "PASS"), len(counted)


def render_report(results: list[dict], summary: dict, meta: dict) -> str:
    passed, n = pass_rate(results)
    n = n or 1
    skipped = summary["outcomes"].get("SKIPPED", 0)
    lines = [
        "# Contract probe report", "",
        f"- Target: `{meta['target']}`",
        f"- Oracle: `{meta['oracle'] or 'none (2xx counts as a pass)'}`",
        f"- Run at: {meta['when']}",
        f"- Priorities probed: {', '.join(sorted(meta['priorities']))}", "",
        f"**{passed} of {n} counted operations pass ({100 * passed / n:.1f}%).**"
        + (f" {skipped} skipped because the oracle itself returned a 5xx." if skipped else ""), "",
        "| Outcome | Count |", "|---|---:|",
    ]
    for outcome in ("PASS", "SHAPE_DIFF", "STATUS_DIFF", "TARGET_ERROR", "SKIPPED"):
        if summary["outcomes"].get(outcome):
            lines.append(f"| {outcome} | {summary['outcomes'][outcome]} |")
    lines += ["", "## By group", "", "| Group | Pass | Total | % |", "|---|---:|---:|---:|"]
    for group in sorted(summary["by_group"]):
        c = summary["by_group"][group]
        tot = sum(v for k, v in c.items() if k != "SKIPPED")
        pct = f"{100 * c.get('PASS', 0) / tot:.0f}%" if tot else "n/a"
        lines.append(f"| {group} | {c.get('PASS', 0)} | {tot} | {pct} |")
    failing = [r for r in results if r["outcome"] not in ("PASS", "SKIPPED")]
    if failing:
        lines += ["", f"## Failures (first {min(len(failing), 40)} of {len(failing)})", ""]
        for r in failing[:40]:
            extra = ""
            if r["outcome"] == "STATUS_DIFF":
                extra = f"oracle {r['oracle_status']}, target {r['target_status']}"
            elif r["outcome"] == "TARGET_ERROR":
                extra = r["detail"].get("error", "")
            elif r["detail"].get("counts"):
                extra = ", ".join(f"{k}: {v}" for k, v in r["detail"]["counts"].items() if v)
            lines.append(f"- `{r['outcome']}` {r['method']} {r['path']} ({r['group']}) {extra}")
    lines.append("")
    return "\n".join(lines)


def run(args) -> int:
    priorities = set(args.priority.split(","))
    ops = load_operations(priorities, args.group)
    if not ops:
        print("No operations selected.", file=sys.stderr)
        return 2
    headers = auth_headers(args.user, args.password, args.tenant)

    oracle_base = None if args.no_oracle else args.oracle
    if oracle_base:  # fail fast if the oracle itself is down: every comparison would be meaningless
        health = call(oracle_base, "/actuator/health", headers, 10)
        if health["status"] != 200:
            print(f"error: oracle not reachable at {oracle_base} ({health['error'] or health['status']}). "
                  "Start it with parity/scripts/start-oracle.sh, or use --no-oracle.", file=sys.stderr)
            return 2

    def probe(row: dict) -> dict:
        path = row["api_path"]
        # api_path is the full path (/fineract-provider/api/v1/...). The base URL already carries
        # /fineract-provider, so strip that prefix.
        rel = path[len("/fineract-provider"):] if path.startswith("/fineract-provider") else path
        oracle = call(oracle_base, rel, headers, args.timeout) if oracle_base else None
        target = call(args.target, rel, headers, args.timeout)
        return judge(row, oracle, target)

    print(f"Probing {len(ops)} operations: target {args.target}, oracle {oracle_base or 'none'}")
    with ThreadPoolExecutor(max_workers=args.workers) as pool:
        results = list(pool.map(probe, ops))

    summary = summarize(results)
    meta = {
        "target": args.target, "oracle": oracle_base, "priorities": sorted(priorities),
        "when": datetime.now(timezone.utc).strftime("%Y-%m-%d %H:%M:%S UTC"),
    }
    out_dir = Path(args.out) if args.out else PARITY_DIR / "reports" / ("probe-" + datetime.now().strftime("%Y%m%d-%H%M%S"))
    out_dir.mkdir(parents=True, exist_ok=True)
    (out_dir / "results.json").write_text(json.dumps({"meta": meta, "summary": summary, "results": results}, indent=1), encoding="utf-8")
    report = render_report(results, summary, meta)
    (out_dir / "report.md").write_text(report, encoding="utf-8", newline="\n")

    passed, counted = pass_rate(results)
    pct = 100 * passed / counted if counted else 0.0
    skipped = summary["outcomes"].get("SKIPPED", 0)
    print(f"{passed}/{counted} pass ({pct:.1f}%), {skipped} skipped (oracle 5xx). Report: {out_dir / 'report.md'}")
    return 0 if pct >= args.fail_under else 1


def main(argv=None) -> int:
    p = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    p.add_argument("--target", required=True, help="base URL of the server under test, for example http://localhost:24000/fineract-provider")
    p.add_argument("--oracle", default=DEFAULT_ORACLE, help=f"base URL of the Fineract oracle (default {DEFAULT_ORACLE})")
    p.add_argument("--no-oracle", action="store_true", help="do not compare with the oracle; a 2xx response counts as a pass")
    p.add_argument("--tenant", default="default")
    p.add_argument("--user", default="mifos")
    p.add_argument("--password", default="password")
    p.add_argument("--priority", default="must", help="comma-separated priorities to probe (default: must)")
    p.add_argument("--group", help="only probe one group, for example loans")
    p.add_argument("--workers", type=int, default=8)
    p.add_argument("--timeout", type=float, default=30.0)
    p.add_argument("--out", help="output directory (default parity/reports/probe-<timestamp>)")
    p.add_argument("--fail-under", type=float, default=100.0, help="exit 1 if the pass rate is below this percentage (default 100)")
    return run(p.parse_args(argv))


if __name__ == "__main__":
    sys.exit(main())
