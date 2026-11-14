#!/usr/bin/env python3
"""Record Apache Fineract's responses as fixtures for E-CoreBank's API tests.

  capture_fixtures.py capture [--only NAME ...]   fetch each manifest entry from the running oracle
  capture_fixtures.py status                      show what is captured, built and pending
  capture_fixtures.py scenarios [--only NAME ...] replay write scenarios on the oracle and record every response

The manifest (apps/ecb_api_fineract/test/fixtures/fineract/manifest.json) lists the requests. Each
entry has a `name`, a `path` (under /fineract-provider/api) and a `status` to expect, and may set
`pending: true` until E-CoreBank implements it, and `today_keys`, the JSON keys whose value is today's
date (stored as "__TODAY__" so the fixture does not go stale).

The fixture holds the response of the oracle on its seeded data, which E-CoreBank starts with too, so
`ECBApiFineract.FixturesTest` can require the same JSON from E-CoreBank. That checks exact values, not just
shape: the contract probe checks shape across the whole API, fixtures check the details of what is built.

Write scenarios (`scenarios.json`) are sequences of requests that change data (create an office, then
update it, then try a bad update). Each names the `reset` of the oracle's data that makes ids repeatable
(offices are removed and their id sequence restarted), and the capture records the status and body of every
step into `scenarios/<name>.json`. `ECBApiFineract.ScenariosTest` replays them on E-CoreBank. The oracle's
own database is reached with `psql` (set ORACLE_PSQL, ORACLE_PG_PORT to override the defaults).

Standard library only. Python 3.9 or newer.
"""
from __future__ import annotations

import argparse
import base64
import json
import os
import ssl
import subprocess
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


def fetch(path: str, method: str = "GET", body: str | None = None, auth: tuple[str, str] = ("mifos", "password")) -> tuple[int, object]:
    headers = {
        "Authorization": "Basic " + base64.b64encode(f"{auth[0]}:{auth[1]}".encode()).decode(),
        "Fineract-Platform-TenantId": "default",
        "Accept": "application/json",
    }
    data = None
    if body is not None:
        data = body.encode("utf-8")
        headers["Content-Type"] = "application/json"
    req = urllib.request.Request(ORACLE + path, data=data, method=method, headers=headers)
    try:
        with urllib.request.urlopen(req, context=CTX, timeout=60) as resp:  # noqa: S310 (local oracle)
            return resp.status, json.loads(resp.read().decode("utf-8") or "null")
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


# --- write scenarios --------------------------------------------------------------------------

SCENARIOS = FIXTURES / "scenarios.json"
SCENARIO_DIR = FIXTURES / "scenarios"

# SQL that returns a part of the oracle's data to its seeded state, so ids repeat from run to run.
RESETS = {
    "offices": [
        "DELETE FROM m_office WHERE id > 1",
        "SELECT setval(pg_get_serial_sequence('m_office', 'id'), 1)",
    ],
    "funds": [
        "DELETE FROM m_fund",
        "SELECT setval(pg_get_serial_sequence('m_fund', 'id'), 1, false)",
    ],
    "paymenttypes": [
        "DELETE FROM m_payment_type WHERE id > 3",
        "SELECT setval(pg_get_serial_sequence('m_payment_type', 'id'), 3)",
    ],
    "codes": [
        "DELETE FROM m_code_value WHERE id > 22",
        "DELETE FROM m_code WHERE is_system_defined = false",
        "UPDATE m_code_value SET code_value = 'Passport', code_description = NULL, order_position = 1, is_active = true WHERE id = 1",
        "SELECT setval(pg_get_serial_sequence('m_code', 'id'), 49)",
        "SELECT setval(pg_get_serial_sequence('m_code_value', 'id'), 22)",
    ],
    "workingdays": [
        "UPDATE m_working_days SET recurrence = 'FREQ=WEEKLY;INTERVAL=1;BYDAY=MO,TU,WE,TH,FR,SA,SU', repayment_rescheduling_enum = 2, extend_term_daily_repayments = false, extend_term_holiday_repayment = false",
    ],
    "holidays": [
        "DELETE FROM m_holiday_office",
        "DELETE FROM m_holiday",
        "SELECT setval(pg_get_serial_sequence('m_holiday', 'id'), 1, false)",
    ],
    "roles": [
        "DELETE FROM m_appuser_previous_password",
        "DELETE FROM m_appuser_role WHERE appuser_id IN (SELECT id FROM m_appuser WHERE id > 3)",
        "DELETE FROM m_appuser WHERE id > 3",
        "UPDATE m_appuser SET username = 'system' WHERE id = 2",
        "DELETE FROM m_role_permission WHERE role_id > 2",
        "DELETE FROM m_role WHERE id > 2",
        "SELECT setval(pg_get_serial_sequence('m_role', 'id'), 2)",
        "SELECT setval(pg_get_serial_sequence('m_appuser', 'id'), 3)",
    ],
    "configuration": [
        "UPDATE c_configuration SET enabled = false, value = NULL, string_value = NULL, date_value = NULL WHERE id = 1",
        "UPDATE c_configuration SET enabled = true, value = 2 WHERE id = 10",
        "UPDATE c_configuration SET enabled = false, value = 0 WHERE id = 11",
        "UPDATE c_configuration SET enabled = true, value = 6 WHERE id = 23",
        "UPDATE c_configuration SET enabled = true, string_value = 'Asset' WHERE id = 35",
        "UPDATE c_configuration SET enabled = false, value = 3 WHERE id = 62",
        "UPDATE c_configuration SET enabled = false WHERE id = 44",
        "UPDATE c_configuration SET enabled = true WHERE id = 45",
        "DELETE FROM m_business_date",
        "UPDATE m_password_validation_policy SET active = (id = 3)",
        "UPDATE m_permission SET can_maker_checker = false WHERE code IN ('CREATE_OFFICE', 'UPDATE_OFFICE', 'CREATE_CLIENT', 'DELETE_FUND', 'CREATE_FUND')",
    ],
    "commands": [
        "DELETE FROM m_portfolio_command_source",
        "SELECT setval(pg_get_serial_sequence('m_portfolio_command_source', 'id'), 1, false)",
    ],
    "staff": [
        "DELETE FROM m_staff",
        "SELECT setval(pg_get_serial_sequence('m_staff', 'id'), 1, false)",
    ],
}


def oracle_sql(statements: list[str]) -> None:
    psql = os.environ.get("ORACLE_PSQL", r"D:\Program Files\PostgreSQL\18\bin\psql.exe")
    port = os.environ.get("ORACLE_PG_PORT", "54330")
    for sql in statements:
        subprocess.run(
            [psql, "-h", "127.0.0.1", "-p", port, "-U", "postgres", "-d", "fineract_default", "-v", "ON_ERROR_STOP=1", "-qtAc", sql],
            check=True, capture_output=True, text=True)


def step_body(step: dict) -> str | None:
    """A step's body as text: `raw` is sent as is (for malformed JSON), `body` is encoded."""
    if "raw" in step:
        return step["raw"]
    if "body" in step:
        return json.dumps(step["body"])
    return None


def cmd_scenarios(args) -> int:
    definitions = json.loads(SCENARIOS.read_text(encoding="utf-8"))["scenarios"]
    SCENARIO_DIR.mkdir(exist_ok=True)
    count = 0
    for scenario in definitions:
        if args.only and scenario["name"] not in args.only:
            continue
        for reset in scenario.get("reset", []):
            oracle_sql(RESETS[reset])
        steps = []
        for step in scenario["steps"]:
            status, body = fetch(step["path"], step.get("method", "GET"), step_body(step), tuple(step.get("auth", ("mifos", "password"))))
            recorded = {k: v for k, v in step.items() if k in ("method", "path", "body", "raw", "auth", "ignore")}
            recorded.update({"status": status, "response": body})
            steps.append(recorded)
        (SCENARIO_DIR / f"{scenario['name']}.json").write_text(
            json.dumps({"name": scenario["name"], "reset": scenario.get("reset", []), "steps": steps}, indent=1, ensure_ascii=False) + "\n",
            encoding="utf-8", newline="\n")
        for reset in scenario.get("reset", []):
            oracle_sql(RESETS[reset])  # leave the oracle as it was seeded
        count += 1
    print(f"Captured {count} scenario(s) into {SCENARIO_DIR}")
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
    sc = sub.add_parser("scenarios")
    sc.add_argument("--only", nargs="*")
    sc.set_defaults(func=cmd_scenarios)
    sub.add_parser("status").set_defaults(func=cmd_status)
    args = p.parse_args(argv)
    return args.func(args)


if __name__ == "__main__":
    sys.exit(main())
