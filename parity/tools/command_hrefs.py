#!/usr/bin/env python3
"""Extract the `href` Fineract records for every command, from CommandWrapperBuilder.java.

Fineract stores, with each command, the URL a client can use to look at what the command made
(`m_portfolio_command_source.api_get_url`): `/funds/template` for a new fund, `/funds/7` for a change to
fund 7. The audit and maker-checker lists show it. This tool reads the builder's source and writes
`apps/ecb_platform/priv/command_hrefs.json`: for each `ENTITY|ACTION` a template in which `{entityId}` and
`{subentityId}` stand for the ids of the command and `{?}` for any other value (not resolved here).

  command_hrefs.py build [--source DIR]   regenerate the JSON from a Fineract source tree
  command_hrefs.py check                   fail if the JSON is missing or has no entries

Standard library only. The source tree defaults to PARITY_SRC_DIR (see parity/scripts/common.sh).
"""
from __future__ import annotations

import argparse
import json
import os
import re
import sys
from pathlib import Path

PARITY_DIR = Path(__file__).resolve().parent.parent
OUT = PARITY_DIR.parent / "apps" / "ecb_platform" / "priv" / "command_hrefs.json"


def find_builder(source: Path) -> Path:
    hits = list(source.rglob("CommandWrapperBuilder.java"))
    hits = [h for h in hits if "build" not in h.parts]
    if not hits:
        sys.exit(f"error: CommandWrapperBuilder.java not found under {source}")
    return hits[0]


def parse(text: str) -> dict[str, str]:
    consts = dict(re.findall(r'(?:ACTION|ENTITY)_(\w+)\s*=\s*"([^"]*)"', text))
    actions = {m[0]: m[1] for m in re.findall(r'ACTION_(\w+)\s*=\s*"([^"]*)"', text)}
    entities = {m[0]: m[1] for m in re.findall(r'ENTITY_(\w+)\s*=\s*"([^"]*)"', text)}
    del consts
    result: dict[str, str] = {}
    for m in re.finditer(r"public CommandWrapperBuilder (\w+)\(([^)]*)\)\s*\{(.*?)\n    \}", text, re.S):
        body = m.group(3)
        action = re.search(r"this\.actionName\s*=\s*ACTION_(\w+)", body)
        entity = re.search(r"this\.entityName\s*=\s*ENTITY_(\w+)", body)
        href = re.search(r"this\.href\s*=\s*(.*?);", body, re.S)
        if not (action and entity and href):
            continue
        entity_var = re.search(r"this\.entityId\s*=\s*(\w+)\s*;", body)
        sub_var = re.search(r"this\.subentityId\s*=\s*(\w+)\s*;", body)
        pieces = []
        for part in re.split(r"\s*\+\s*", href.group(1).strip()):
            part = part.strip()
            if part.startswith('"') and part.endswith('"'):
                pieces.append(part[1:-1])
            elif entity_var and part == entity_var.group(1):
                pieces.append("{entityId}")
            elif sub_var and part == sub_var.group(1):
                pieces.append("{subentityId}")
            else:
                pieces.append("{?}")
        key = f"{entities.get(entity.group(1), entity.group(1))}|{actions.get(action.group(1), action.group(1))}"
        result.setdefault(key, "".join(pieces))
    return dict(sorted(result.items()))


def cmd_build(args) -> int:
    source = Path(args.source or os.environ.get("PARITY_SRC_DIR", r"C:\fsrc") )
    candidates = [source] + list(source.glob("apache-fineract-src-*"))
    builder = None
    for c in candidates:
        try:
            builder = find_builder(c)
            break
        except SystemExit:
            continue
    if builder is None:
        sys.exit(f"error: no Fineract source tree at {source}")
    table = parse(builder.read_text(encoding="utf-8"))
    OUT.write_text(json.dumps(table, indent=1, sort_keys=True) + "\n", encoding="utf-8", newline="\n")
    print(f"Wrote {len(table)} command hrefs to {OUT}")
    return 0


def cmd_check(_args) -> int:
    if not OUT.exists() or len(json.loads(OUT.read_text(encoding="utf-8"))) < 100:
        sys.exit("error: apps/ecb_platform/priv/command_hrefs.json is missing or incomplete; run command_hrefs.py build")
    print("OK")
    return 0


def main(argv=None) -> int:
    p = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = p.add_subparsers(dest="command", required=True)
    b = sub.add_parser("build")
    b.add_argument("--source")
    b.set_defaults(func=cmd_build)
    sub.add_parser("check").set_defaults(func=cmd_check)
    args = p.parse_args(argv)
    return args.func(args)


if __name__ == "__main__":
    sys.exit(main())
