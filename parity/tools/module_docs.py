#!/usr/bin/env python3
"""Generate one design document per E-CoreBank module, aligned with Apache Fineract.

  module_docs.py snapshot [--src DIR]   read the Fineract source tree and save a package map and the
                                        integration-test class list into parity/inventory/
  module_docs.py check                  verify the module spec covers every endpoint tag, schema table
                                        and test group exactly once
  module_docs.py build                  write docs/modules/<app>.md and docs/modules/README.md

Inputs: docs/modules/modules.json (hand-written: purpose, design notes, acceptance criteria) plus the
generated inventories (endpoints.csv, SCHEMA data, source map, test classes). The hand-written parts are
the design; the generated parts are facts and are regenerated, never edited. Standard library only.
"""
from __future__ import annotations

import argparse
import csv
import json
import os
import sys
from collections import Counter, defaultdict
from pathlib import Path

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))
import junit_report as jr  # noqa: E402
import schema_summary as ss  # noqa: E402

PARITY_DIR = HERE.parent
REPO = PARITY_DIR.parent
INVENTORY = PARITY_DIR / "inventory"
SPEC_FILE = REPO / "docs" / "modules" / "modules.json"
OUT_DIR = REPO / "docs" / "modules"
FINERACT_PKG = "org/apache/fineract/"


def version() -> str:
    return ss.version()


# --- snapshot of the Fineract source tree ----------------------------------------------------


def find_source(arg: str | None) -> Path:
    ver = version()
    candidates = [arg] if arg else [os.environ.get("PARITY_SRC_DIR"), str(PARITY_DIR / ".cache" / "src")]
    for base in candidates:
        if base:
            p = Path(base) / f"apache-fineract-src-{ver}"
            if p.is_dir():
                return p
            if (Path(base) / "settings.gradle").exists():
                return Path(base)
    sys.exit("error: Fineract source not found. Run parity/scripts/fetch-fineract.sh --source, then pass --src or set PARITY_SRC_DIR")


def cmd_snapshot(args) -> int:
    src = find_source(args.src)
    prefixes: dict[str, Counter] = defaultdict(Counter)
    totals: Counter = Counter()
    for module_dir in sorted(p for p in src.iterdir() if (p / "src" / "main" / "java").is_dir()):
        root = module_dir / "src" / "main" / "java"
        for java in root.rglob("*.java"):
            rel = java.relative_to(root).as_posix()
            if not rel.startswith(FINERACT_PKG):
                continue
            parts = rel[len(FINERACT_PKG):].split("/")[:-1]
            totals[module_dir.name] += 1
            for depth in range(1, min(len(parts), 3) + 1):
                prefixes[".".join(parts[:depth])][module_dir.name] += 1
    snap = {
        "version": version(),
        "gradle_modules": dict(sorted(totals.items())),
        "prefixes": {k: dict(sorted(v.items())) for k, v in sorted(prefixes.items())},
    }
    (INVENTORY / f"fineract-source-map-{version()}.json").write_text(
        json.dumps(snap, indent=1, sort_keys=True), encoding="utf-8", newline="\n")
    classes = sorted({p.stem for p in (src / "integration-tests" / "src" / "test" / "java").rglob("*Test.java")})
    (INVENTORY / f"fineract-it-classes-{version()}.txt").write_text("\n".join(classes) + "\n", encoding="utf-8", newline="\n")
    print(f"Source map: {sum(totals.values())} Java files in {len(totals)} Gradle modules, {len(prefixes)} package prefixes; {len(classes)} integration-test classes")
    return 0


# --- loading ----------------------------------------------------------------------------------


class Model:
    """Everything the documents are built from."""

    def __init__(self):
        ver = version()
        self.version = ver
        self.spec = json.loads(SPEC_FILE.read_text(encoding="utf-8"))
        self.modules = {m["app"]: m for m in self.spec["modules"]}
        self.snap = json.loads((INVENTORY / f"fineract-source-map-{ver}.json").read_text(encoding="utf-8"))
        self.it_classes = (INVENTORY / f"fineract-it-classes-{ver}.txt").read_text(encoding="utf-8").split()
        with (INVENTORY / "endpoints.csv").open(encoding="utf-8", newline="") as f:
            self.ops = list(csv.DictReader(f))
        columns, constraints = ss.load(ver)
        self.tables = ss.analyse(columns, constraints, ss.load_rules())
        self.test_rules = jr.load_rules()
        self.problems: list[str] = []
        self._assign()

    # who owns what
    def op_owner(self, op: dict) -> str | None:
        if op["priority"] == "ignore":
            return None
        if not op["tag"]:  # untagged operations are placed by path prefix first
            for rule in self.spec.get("path_owner", []):
                if op["path"].startswith(rule["prefix"]):
                    return rule["owner"]
        return self.spec["tag_owner"].get(op["tag"]) or self.spec["group_owner"].get(op["group"])

    def table_owner(self, table: dict) -> str:
        app = table["app"]
        if app == "(framework)":
            return "ecb_platform"
        return "deferred" if app == "(deferred)" else app

    def test_owner(self, test_group: str) -> str | None:
        return self.spec["test_group_owner"].get(test_group)

    def _assign(self):
        self.ops_by_module: dict[str, list[dict]] = defaultdict(list)
        for op in self.ops:
            if op["priority"] == "ignore":
                continue
            owner = self.op_owner(op)
            if owner is None:
                self.problems.append(f"no module owns {op['method']} {op['path']} (tag {op['tag']!r}, group {op['group']!r})")
            elif owner not in self.modules:
                self.problems.append(f"{op['path']}: owner {owner!r} is not a module in modules.json")
            else:
                self.ops_by_module[owner].append(op)
        self.tables_by_module: dict[str, list[tuple[str, dict]]] = defaultdict(list)
        for name, t in sorted(self.tables.items()):
            owner = self.table_owner(t)
            if owner not in self.modules:
                self.problems.append(f"table {name}: owner {owner!r} is not a module in modules.json")
            else:
                self.tables_by_module[owner].append((name, t))
        self.tests_by_module: dict[str, list[tuple[str, str]]] = defaultdict(list)
        for cls in self.it_classes:
            group = jr.group_for(cls, self.test_rules)
            owner = self.test_owner(group)
            if owner is None or owner not in self.modules:
                self.problems.append(f"test class {cls}: group {group!r} has no owning module in test_group_owner")
            else:
                self.tests_by_module[owner].append((cls, group))
        for app, m in self.modules.items():
            for pkg in m.get("packages", []):
                if pkg not in self.snap["prefixes"]:
                    self.problems.append(f"{app}: package prefix {pkg!r} not found in the Fineract source map")
            for dep in m.get("depends_on", []):
                if dep not in self.modules:
                    self.problems.append(f"{app}: depends_on unknown module {dep!r}")
        self._find_cycles()
        claimed: Counter = Counter()
        for m in self.modules.values():
            for pkg in m.get("packages", []):
                claimed[pkg] += 1
        for pkg, n in claimed.items():
            if n > 1:
                self.problems.append(f"package prefix {pkg!r} is claimed by {n} modules")


def coverage(model: Model):
    """Return (claimed, excluded, total, unclaimed) counts of Fineract Java files.

    A file belongs to the most specific package prefix in the source map (depth up to 3). A prefix is
    covered when a module claims it or one of its ancestors, or it is listed under excluded_packages.
    """
    px = model.snap["prefixes"]
    claimed_roots = [p for m in model.modules.values() for p in m.get("packages", [])]
    excluded_roots = list(model.spec.get("excluded_packages", {}))
    # Files that sit directly in a package (shared enums, error handlers) can be claimed without
    # claiming every sub-package below it.
    direct = model.spec.get("direct_package_owner", {})

    def covered(prefix: str, roots) -> bool:
        return any(prefix == r or prefix.startswith(r + ".") for r in roots)

    claimed = excluded = total = 0
    unclaimed: list[tuple[str, int]] = []
    for prefix, counts in px.items():
        children = sum(sum(c.values()) for k, c in px.items() if k.startswith(prefix + ".") and k.count(".") == prefix.count(".") + 1)
        own = sum(counts.values()) - children
        if own <= 0:
            continue
        total += own
        if covered(prefix, claimed_roots) or prefix in direct:
            claimed += own
        elif covered(prefix, excluded_roots):
            excluded += own
        else:
            unclaimed.append((prefix, own))
    return claimed, excluded, total, sorted(unclaimed, key=lambda kv: -kv[1])


def _find_cycles(self):
    """Report every dependency cycle among modules (a cycle would make the umbrella impossible to compile)."""
    state: dict[str, int] = {}
    stack: list[str] = []

    def visit(app: str):
        state[app] = 1
        stack.append(app)
        for dep in self.modules[app].get("depends_on", []):
            if dep not in self.modules:
                continue
            if state.get(dep) == 1:
                cycle = stack[stack.index(dep):] + [dep]
                self.problems.append("dependency cycle: " + " -> ".join(cycle))
            elif dep not in state:
                visit(dep)
        stack.pop()
        state[app] = 2

    for app in self.modules:
        if app not in state:
            visit(app)


Model._find_cycles = _find_cycles


def cmd_check(_a) -> int:
    model = Model()
    _c, _e, _t, unclaimed = coverage(model)
    for prefix, n in unclaimed:
        model.problems.append(f"Fineract package {prefix!r} ({n} files) is claimed by no module and is not excluded")
    if model.problems:
        print(f"{len(model.problems)} problem(s) in the module spec:")
        for p in model.problems[:60]:
            print(f"  - {p}")
        return 1
    claimed, excluded, total, _u = coverage(model)
    print(f"OK: {len(model.modules)} modules cover all {sum(len(v) for v in model.ops_by_module.values())} operations, "
          f"{len(model.tables)} tables and {len(model.it_classes)} integration-test classes exactly once; "
          f"{claimed} of {total} Fineract Java files are claimed ({excluded} excluded as SDK or tooling)")
    return 0


# --- rendering --------------------------------------------------------------------------------


def esc(text: str, limit: int = 110) -> str:
    text = (text or "").replace("|", "\\|").replace("\n", " ").strip()
    return text if len(text) <= limit else text[: limit - 1] + "…"


def bullets(items) -> list[str]:
    return [f"- {i}" for i in items] if items else ["- (none yet)"]


def render_module(model: Model, m: dict) -> str:
    app = m["app"]
    ops = model.ops_by_module.get(app, [])
    tables = model.tables_by_module.get(app, [])
    tests = model.tests_by_module.get(app, [])
    by_prio = Counter(o["priority"] for o in ops)
    L: list[str] = []
    L += [f"# {app}: {m['title']}", ""]
    deps = ", ".join(f"`{d}`" for d in m.get("depends_on", [])) or "none (a leaf of the dependency graph)"
    L += [f"> **Phase** {m['phase']}  |  **Status** {m['status']}  |  **Depends on** {deps}", "",
          "Generated parts of this document (the Fineract reference, API scope, data model and tests) come from",
          "`parity/` inventories and are regenerated by `python parity/tools/module_docs.py build`. The rest is the",
          "design and lives in `docs/modules/modules.json`. Overall approach: [design reference](../design/00-fineract-design-reference.md), [ADR-0001](../adr/0001-follow-fineract-design.md).", ""]
    L += ["## 1. Purpose", "", m["summary"], ""]
    L += ["## 2. Responsibilities", ""] + bullets(m.get("responsibilities")) + [""]
    L += ["## 3. Out of scope", ""] + bullets(m.get("out_of_scope")) + [""]

    # Fineract reference
    L += ["## 4. Fineract reference", ""]
    gm = m.get("gradle_modules", [])
    if gm:
        L += ["Gradle modules in the 1.16.1 source release:", "", "| Module | Main Java files |", "|---|---:|"]
        for g in gm:
            L.append(f"| `{g}` | {model.snap['gradle_modules'].get(g, 0)} |")
        L.append("")
    pk = m.get("packages", [])
    if pk:
        L += ["Packages under `org.apache.fineract` (Fineract splits a package across Gradle modules, so counts are summed):", "",
              "| Package | Java files | Found in |", "|---|---:|---|"]
        total = 0
        for p in pk:
            c = model.snap["prefixes"].get(p, {})
            total += sum(c.values())
            L.append(f"| `{p}` | {sum(c.values())} | {', '.join(f'{k} ({v})' for k, v in c.items())} |")
        L += ["", f"About **{total} Java files** of Fineract implement this module's area. That is a measure of scope, not a line count to match.", ""]
    docs = m.get("design_docs", [])
    L += ["Design documents to read first (`fineract-doc/src/docs/en/chapters/`):", ""] + bullets([f"`{d}`" for d in docs]) + [""]

    # API
    L += ["## 5. API scope", ""]
    if m.get("api_overview"):
        L += [m.get("api_note", ""), "", "| Owning module | must | should | defer | test-support | Total |", "|---|---:|---:|---:|---:|---:|"]
        for other, other_ops in model.ops_by_module.items():
            c = Counter(o["priority"] for o in other_ops)
            L.append(f"| [{other}]({other}.md) | {c['must']} | {c['should']} | {c['defer']} | {c['test-support']} | {len(other_ops)} |")
        total = sum(len(v) for v in model.ops_by_module.values())
        L += [f"| **All** |  |  |  |  | **{total}** |", ""]
    elif ops:
        L += [f"**{len(ops)} operations**: " + ", ".join(f"{by_prio[p]} {p}" for p in ("must", "should", "defer", "test-support") if by_prio.get(p)) + ".",
              "Source: [parity/inventory/endpoints.csv](../../parity/inventory/endpoints.csv). Paths are under `/fineract-provider/api`.", "",
              "| Tag | Operations | Priority |", "|---|---:|---|"]
        tag_rows: dict[str, list[dict]] = defaultdict(list)
        for o in ops:
            tag_rows[o["tag"] or "(untagged)"].append(o)
        for tag in sorted(tag_rows):
            rows = tag_rows[tag]
            L.append(f"| {esc(tag, 60)} | {len(rows)} | {', '.join(sorted({r['priority'] for r in rows}))} |")
        L += ["", "<details><summary>All operations</summary>", "", "| Method | Path | Priority | Summary |", "|---|---|---|---|"]
        for o in sorted(ops, key=lambda r: (r["path"], r["method"])):
            L.append(f"| {o['method']} | `{o['path']}` | {o['priority']} | {esc(o['summary'])} |")
        L += ["", "</details>", ""]
    else:
        L += [m.get("api_note", "This module exposes no operations of its own."), ""]

    # data model
    L += ["## 6. Data model", ""]
    if tables:
        cols = sum(t["columns"] for _, t in tables)
        L += [f"**{len(tables)} tables, {cols} columns.** Names, columns, types and constraints follow Fineract "
              "([SCHEMA.md](../../parity/inventory/SCHEMA.md); raw data in `parity/inventory/fineract-schema-*-columns.csv` and `-keys.csv`).", "",
              "| Table | Columns | Foreign keys | Area |", "|---|---:|---:|---|"]
        for name, t in tables:
            L.append(f"| `{name}` | {t['columns']} | {t['fks']} | {t['area']} |")
        L.append("")
    else:
        L += [m.get("data_note", "This module owns no tables."), ""]

    L += ["## 7. Design to follow", ""] + bullets(m.get("design")) + [""]
    L += ["## 8. Build order", ""] + [f"{i}. {s}" for i, s in enumerate(m.get("build_order", []), 1)] + [""]

    L += ["## 9. Contract tests", ""]
    if tests:
        by_group: dict[str, list[str]] = defaultdict(list)
        for cls, g in tests:
            by_group[g].append(cls)
        L += [f"**{len(tests)} of Fineract's integration-test classes** exercise this module "
              "(run with `parity/scripts/run-contract-suite.sh --tests '<pattern>'`; class-to-area mapping is a heuristic in "
              "`parity/inventory/test-groups.json`).", ""]
        for g in sorted(by_group):
            L.append(f"- **{g}** ({len(by_group[g])}): " + ", ".join(f"`{c}`" for c in sorted(by_group[g])))
        L.append("")
    else:
        L += [m.get("tests_note", "No Fineract integration-test class maps to this module."), ""]

    L += ["## 10. Acceptance criteria", "", "Module-specific:", ""] + bullets(m.get("acceptance")) + [
        "", "Common to every module:", "",
        "- Contract probe: every `must` read operation of this module passes against the oracle (status and response shape).",
        "- Fineract's integration-test classes listed above pass, or each failure is recorded as a divergence with an ADR.",
        "- Every state-changing operation goes through the command bus: validated, authorised, audited, idempotent, maker-checker aware.",
        "- Every table has an Ecto migration in the tenant repo that matches the Fineract schema, and the cross-tenant isolation test covers the module.",
        "- Money uses `Decimal` with an explicit currency and rounding rule; no floats.",
        "- Dependencies point only at the modules in the header. `mix xref` finds no cycle or reverse dependency.",
        "- `mix format`, Credo strict, Dialyzer and the module's tests pass; the module README and this document are updated.", ""]
    L += ["## 11. Open questions", ""] + bullets(m.get("open_questions")) + [""]
    return "\n".join(L)


def render_index(model: Model) -> str:
    L = [
        "# E-CoreBank module documents", "",
        f"One design document per module, aligned with Apache Fineract {model.version}. Generated by `python parity/tools/module_docs.py build` from",
        "`modules.json` (design, hand-written) and the `parity/` inventories (facts). See the [design reference](../design/00-fineract-design-reference.md).", "",
        "| Module | Title | Phase | Depends on | Operations (must / should / defer) | Tables | Fineract Java files | Test classes |",
        "|---|---|---:|---|---|---:|---:|---:|",
    ]
    for app, m in model.modules.items():
        ops = model.ops_by_module.get(app, [])
        c = Counter(o["priority"] for o in ops)
        files = sum(sum(model.snap["prefixes"].get(p, {}).values()) for p in m.get("packages", []))
        deps = ", ".join(m.get("depends_on", [])) or "none"
        L.append(f"| [{app}]({app}.md) | {m['title']} | {m['phase']} | {deps} | {c['must']} / {c['should']} / {c['defer']} | "
                 f"{len(model.tables_by_module.get(app, []))} | {files} | {len(model.tests_by_module.get(app, []))} |")
    L += ["", "## Dependency graph", "", "```mermaid", "graph TD"]
    for app, m in model.modules.items():
        for d in m.get("depends_on", []):
            L.append(f"  {app} --> {d}")
    L += ["```", "", "Arrows point at what a module depends on. The graph must stay acyclic and is enforced with `mix xref`.", "",
          "## Implementation order", ""] + [f"{i}. {s}" for i, s in enumerate(model.spec["implementation_order"], 1)] + [""]
    claimed, excluded, total, _u = coverage(model)
    L += ["## Coverage of Fineract's source", "",
          f"Every Java package of the Fineract {model.version} server source is claimed by exactly one module or deliberately excluded: "
          f"**{claimed} of {total} files claimed**, {excluded} excluded.", ""]
    for pkg, why in model.spec.get("excluded_packages", {}).items():
        L.append(f"- Excluded `{pkg}`: {why}")
    L += ["", "`python parity/tools/module_docs.py check` fails when a Fineract upgrade adds a package that no module claims.", ""]
    L += ["## How the pieces fit", "", model.spec["overview"], ""]
    return "\n".join(L)


def cmd_build(_a) -> int:
    model = Model()
    if model.problems:
        print("Cannot build: the module spec has problems (run `check`).", file=sys.stderr)
        for p in model.problems[:10]:
            print(f"  - {p}", file=sys.stderr)
        return 1
    OUT_DIR.mkdir(parents=True, exist_ok=True)
    for app, m in model.modules.items():
        (OUT_DIR / f"{app}.md").write_text(render_module(model, m), encoding="utf-8", newline="\n")
    (OUT_DIR / "README.md").write_text(render_index(model), encoding="utf-8", newline="\n")
    print(f"Wrote {len(model.modules)} module documents and README.md to {OUT_DIR}")
    return 0


def main(argv=None) -> int:
    p = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = p.add_subparsers(dest="command", required=True)
    s = sub.add_parser("snapshot")
    s.add_argument("--src")
    s.set_defaults(func=cmd_snapshot)
    sub.add_parser("check").set_defaults(func=cmd_check)
    sub.add_parser("build").set_defaults(func=cmd_build)
    args = p.parse_args(argv)
    return args.func(args)


if __name__ == "__main__":
    sys.exit(main())
