#!/usr/bin/env python3
"""Record Apache Fineract's responses as fixtures for E-CoreBank's API tests.

  capture_fixtures.py capture [--only NAME ...]   fetch each manifest entry from the running oracle
  capture_fixtures.py status                      show what is captured, built and pending

The manifest (apps/ecb_api_fineract/test/fixtures/fineract/manifest.json) lists the requests. Each
entry has a `name`, a `path` (under /fineract-provider/api) and a `status` to expect, and may set
`pending: true` until E-CoreBank implements it, and `today_keys`, the JSON keys whose value is today's
date (stored as "__TODAY__" so the fixture does not go stale).

The fixture holds the response of the oracle on its seeded data, which E-CoreBank starts with too, so
`ECBApiFineract.FixturesTest` can require the same JSON from E-CoreBank. That checks exact values, not just
shape: the contract probe checks shape across the whole API, fixtures check the details of what is built.

Standard library only. Python 3.9 or newer.
"""
from __future__ import annotations

import argparse
import base64
import json
import ssl
import sys
import urllib.error
import urllib.request
from datetime import date
from pathlib import Path

PARITY_DIR = Path(__file__).resolve().parent.parent
FIXTURES = PARITY_DIR.parent / "apps" / "ecb_api_fineract" / "test" / "fixtures" / "fineract"
MANIFEST = FIXTURES / "manifest.json"
ORACLE = "https://localhost:8443/fineract-provider/api"
CTX = ssl.create_default_context()
CTX.check_hostname = False  # the oracle's self-signed certificate (local only)
CTX.verify_mode = ssl.CERT_NONE


def load_manifest() -> dict:
    return json.loads(MANIFEST.read_text(encoding="utf-8"))


def fetch(path: str) -> tuple[int, object]:
    req = urllib.request.Request(
        ORACLE + path,
        headers={
            "Authorization": "Basic " + base64.b64encode(b"mifos:password").decode(),
            "Fineract-Platform-TenantId": "default",
            "Accept": "application/json",
        },
    )
    try:
        with urllib.request.urlopen(req, context=CTX, timeout=60) as resp:  # noqa: S310 (local oracle)
            return resp.status, json.loads(resp.read().decode("utf-8"))
    except urllib.error.HTTPError as err:
        return err.code, json.loads(err.read().decode("utf-8") or "null")


def mark_today(value, keys: list[str]):
    """Replace today's date, where it appears under one of `keys`, with a marker."""
    today = date.today()
    marker = [today.year, today.month, today.day]
    if isinstance(value, dict):
        return {k: ("__TODAY__" if k in keys and v == marker else mark_today(v, keys)) for k, v in value.items()}
    if isinstance(value, list):
        return [mark_today(v, keys) for v in value]
    return value


def fixture_path(entry: dict) -> Path:
    return FIXTURES / f"{entry['name']}.json"


def cmd_capture(args) -> int:
    manifest = load_manifest()
    count = 0
    for entry in manifest["entries"]:
        if args.only and entry["name"] not in args.only:
            continue
        status, body = fetch(entry["path"])
        if status != entry.get("status", 200):
            print(f"warning: {entry['name']}: expected HTTP {entry.get('status', 200)}, oracle answered {status}", file=sys.stderr)
        body = mark_today(body, entry.get("today_keys", []))
        fixture_path(entry).write_text(
            json.dumps({"path": entry["path"], "status": status, "body": body}, indent=1, ensure_ascii=False) + "\n",
            encoding="utf-8", newline="\n")
        count += 1
    print(f"Captured {count} fixture(s) into {FIXTURES}")
    return 0


def cmd_status(_args) -> int:
    manifest = load_manifest()
    entries = manifest["entries"]
    built = [e for e in entries if not e.get("pending")]
    print(f"{len(entries)} fixtures in the manifest: {len(built)} built, {len(entries) - len(built)} pending")
    for e in entries:
        mark = "pending" if e.get("pending") else "built  "
        have = "captured" if fixture_path(e).exists() else "NOT CAPTURED"
        print(f"  {mark}  {have:<12} {e['path']}")
    return 0


def main(argv=None) -> int:
    p = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = p.add_subparsers(dest="command", required=True)
    c = sub.add_parser("capture")
    c.add_argument("--only", nargs="*")
    c.set_defaults(func=cmd_capture)
    sub.add_parser("status").set_defaults(func=cmd_status)
    args = p.parse_args(argv)
    return args.func(args)


if __name__ == "__main__":
    sys.exit(main())
