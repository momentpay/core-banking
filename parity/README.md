# parity/: the Apache Fineract oracle and the parity harness

E-CoreBank is measured against a pinned Apache Fineract. This folder runs that Fineract next to
our service so every contract test and differential run can be checked against the real thing.

**Pinned version:** see [VERSION](VERSION) (Apache Fineract 1.16.1). Change it only through an ADR.

## Why not simply `docker pull apache/fineract:1.16.1`?

That image is not published. Docker Hub has `develop`, `latest`, commit-SHA tags and
1.10.1 to 1.12.1 only. We therefore use the **ASF binary release**, verified against the
published SHA-512 (and the PGP signature when `gpg` is installed).

## Option A: without Docker (works today on Windows with Git Bash, and on Linux)

Requirements: bash, curl, tar, python, and PostgreSQL server binaries (`initdb`, `pg_ctl`, `psql`).
**Fineract 1.16.1 needs Java 25.** `fetch-java.sh` downloads a checksum-verified Temurin 25 JRE into
`parity/.cache`, so your installed Java is left alone. About 1.2 GB of free disk space.

```sh
parity/scripts/fetch-java.sh       # once: Temurin 25 JRE (about 60 MB) into parity/.cache
parity/scripts/fetch-fineract.sh   # once: download (about 450 MB), verify, extract into parity/.cache
parity/scripts/start-oracle.sh     # throwaway PostgreSQL on 127.0.0.1:54330 plus Fineract on :8443
parity/scripts/smoke.sh            # health, authentication, GET /offices
parity/scripts/stop-oracle.sh      # add --purge to delete the database cluster
```

The first start applies Fineract's database migrations and takes several minutes. Overrides:
`JAVA_HOME`, `PG_BIN`, `PARITY_PG_PORT` (default 54330), `FINERACT_PORT` (default 8443).

## Option B: Docker

```sh
docker compose -f parity/docker-compose.yml up -d --build
parity/scripts/smoke.sh
```

This path was written but **not yet run** (Docker Desktop could not start on the author's machine
because WSL2 was missing). Treat it as untested until someone has run it.

## Endpoints and credentials (oracle only)

| | |
|---|---|
| Base URL | `https://localhost:8443/fineract-provider` (self-signed certificate: use `curl -k`) |
| Tenant header | `Fineract-Platform-TenantId: default` |
| Login | `mifos` / `password` (Fineract's documented defaults, **for this local oracle only**) |
| Health | `/fineract-provider/actuator/health` |
| Database | PostgreSQL on 127.0.0.1:54330, databases `fineract_tenants` and `fineract_default`, user `postgres`, throwaway password, loopback only |

## Pointing the smoke test at E-CoreBank

```sh
BASE=http://localhost:24000/fineract-provider parity/scripts/smoke.sh
```

It will fail until the compatibility API exists (Phase 1 and 2 in the plan). That is the point: it
is the first contract test.

## The parity measurements

Three layers, cheapest first. All of them compare against the oracle, never against our own idea of
what Fineract does.

### 1. Endpoint inventory: what has to exist

[inventory/SUMMARY.md](inventory/SUMMARY.md) and [inventory/endpoints.csv](inventory/endpoints.csv)
list every operation in Fineract 1.16.1's OpenAPI document (968 operations, 603 paths) with a
functional group and a priority: **must** (bank pilot), **should** (after the pilot core), **defer**
(not built early; returns a documented "not implemented" error), **test-support** (internal endpoints
Fineract's own tests call) or **ignore**. The classification lives in
[inventory/groups.json](inventory/groups.json) and encodes the approved cut list.

```sh
python parity/tools/inventory.py fetch   # snapshot the OpenAPI document from the running oracle
python parity/tools/inventory.py check   # fail if any operation is unclassified
python parity/tools/inventory.py build   # regenerate endpoints.csv and SUMMARY.md
```

When Fineract is upgraded, `check` fails on any new tag until someone classifies it.

### 2. Contract probe: does the target answer like Fineract? (no build, no data)

```sh
python parity/tools/contract_probe.py --target http://localhost:24000/fineract-provider --priority must
```

Calls every read-only operation that needs no path parameters (150 `must` and `should` operations today)
on both the oracle and the target, then compares the HTTP status and the **shape** of the JSON (fields and
types, not values). Operations where the oracle itself answers 5xx are skipped, not counted. Reports go to
`parity/reports/probe-<time>/` (`report.md`, `results.json`). The exit code is 1 below `--fail-under`
(default 100). Use `--no-oracle` to count any 2xx as a pass. Shape comparison is only meaningful when both
servers hold comparable data: fields under an empty array are not compared.

Probing the oracle against itself passes 146 of 146 counted operations (4 skipped, oracle 5xx), which is the
baseline for the tool itself. This layer does not exercise writes, workflows or calculations.

**Current standing of E-CoreBank (14 Nov 2026):** `20 of 146` counted `must` and `should` read operations pass
(offices, currencies, codes, payment types, working days, funds, holidays, staff, account-number formats,
configurations, permissions, roles, users and password preferences); the other 126 answer HTTP 501 "not implemented".
The exact-match layer is wider than the probe: 33 recorded Fineract responses are required byte for byte
(`ECBApiFineract.FixturesTest`). Run it yourself:

```sh
parity/scripts/start-oracle.sh                       # Fineract on :8443
mix ecto.setup && ECB_NO_WATCHERS=1 PHX_SERVER=true mix run --no-halt   # E-CoreBank on :24000
python parity/tools/contract_probe.py --target http://localhost:24000/fineract-provider --priority must,should
BASE=http://localhost:24000/fineract-provider parity/scripts/smoke.sh    # the smoke test, against E-CoreBank
```

### 2b. Recorded responses and write scenarios: exact values and behaviour of what is built

Two kinds of recording, both captured from the oracle with `python parity/tools/capture_fixtures.py` and
replayed against E-CoreBank by the tests of `ecb_api_fineract`:

* **Fixtures** (`capture`, `ECBApiFineract.FixturesTest`): one read request and the exact JSON Fineract answered on
  its seeded data. 33 today.
* **Scenarios** (`scenarios`, `ECBApiFineract.ScenariosTest`): a *sequence* of writes and reads (create an office,
  update it, try every bad request, read it back). The oracle's data is reset first (the resets are in the tool) so ids
  repeat; every step's status and body must match. 10 scenarios today, covering offices, funds, payment types, staff,
  codes, code values, working days and holidays. They are how the validation messages, error codes and the odd corners
  of Fineract (a response that echoes the request, a status code of 600 for "deleted") are found and kept.

Requests whose answer holds text from a Java library (a JSON syntax error, an iCalendar parse error) are left out of the
scenarios and tested for their message *code* instead; the differences are in
[../docs/divergences.md](../docs/divergences.md).

### 3. Fineract's own integration tests: the strict contract

```sh
parity/scripts/fetch-fineract.sh --source    # the source release holds integration-tests/
parity/scripts/fetch-java.sh --jdk           # Gradle needs a JDK, not a JRE
parity/scripts/run-contract-suite.sh --dry-run                            # pre-flight only
parity/scripts/run-contract-suite.sh --tests '*ClientTest'                # one class, against the oracle
parity/scripts/run-contract-suite.sh --target http://localhost:24000/fineract-provider
```

Runs Fineract's unmodified tests (about 390 classes) against the target via the `BACKEND_*` environment
variables and summarises JUnit results per functional group (`tools/junit_report.py`, grouping rules in
`inventory/test-groups.json`). **This builds Fineract's whole project with Gradle** (several GB of
dependencies and output), so the script refuses to start without a JDK 25 and 8 GB of free disk
(`ECB_MIN_FREE_GB` overrides, `GRADLE_USER_HOME` moves the cache to another drive). **Not yet run end to
end:** the pre-flight checks are tested, the Gradle build is not, because the author's machine has about
2.5 GB free.

### Design artifacts: the Fineract data model

[inventory/SCHEMA.md](inventory/SCHEMA.md) groups the 280 tables of the oracle's schema by functional area and
owning E-CoreBank app (rules in `inventory/schema-areas.json`). The raw column and key exports are
`inventory/fineract-schema-<version>-columns.csv` and `-keys.csv`.

```sh
parity/scripts/export-schema.sh              # needs the oracle's PostgreSQL running; read-only
python parity/tools/schema_summary.py check  # fail if a table has no owning area
python parity/tools/schema_summary.py build  # regenerate SCHEMA.md
```

How this feeds the design: [docs/design/00-fineract-design-reference.md](../docs/design/00-fineract-design-reference.md).

### Tenant migrations generated from the oracle

E-CoreBank's tenant tables are Fineract's (ADR-0001). `ddl_export.py` asks the running oracle for a table's
definition with `pg_dump` and writes an Ecto migration into the owning app, so nothing is retyped. A foreign
key to a table that does not exist yet is held back and added automatically by the migration that creates
that table. Seed rows (permissions, configuration, roles) are generated the same way.

```sh
python parity/tools/ddl_export.py schema --app ecb_platform --name create_security_tables --version 20261114100000 --tables m_permission,m_role
python parity/tools/ddl_export.py data   --app ecb_platform --name seed_permissions --version 20261114100100 --tables m_permission
python parity/tools/ddl_export.py status   # what exists and which foreign keys are waiting
```

What has been generated is recorded in `inventory/schema-migrations.json`. The migrations are derived from
Apache Fineract and listed in [NOTICE](../NOTICE).

### Module documents

`docs/modules/` holds one design document per E-CoreBank module. Their facts (API operations, tables, test classes,
Fineract package sizes) are generated from the inventories above; the design text is in `docs/modules/modules.json`.

```sh
python parity/tools/module_docs.py snapshot --src /c/fsrc   # refresh the Fineract package map (needs the source release)
python parity/tools/module_docs.py check                    # every endpoint, table, test class and package owned once; no cycles
python parity/tools/module_docs.py build                    # regenerate docs/modules/*.md
```

### Golden master for ecb_money

`apps/ecb_money` is checked against Fineract's own `Money` class. `gen-money-golden.sh` runs that class
(unpacked from the 1.16.1 binary release) on 130,144 generated cases and writes a compressed fixture to
`apps/ecb_money/test/fixtures/`; the Elixir test replays every case and requires identical text. The fixture
is committed, so the tests need none of this. Run it only to refresh the fixture after changing the pinned version.

```sh
parity/scripts/fetch-fineract.sh && parity/scripts/fetch-java.sh --jdk
PARITY_CLASSPATH_DIR=/c/ecb-parity-classpath parity/scripts/gen-money-golden.sh   # unpacks about 200 MB once
```

### Tests for the tools

```sh
python -m unittest discover -s parity/tools -v     # 38 tests; also run in CI
```

## Layout

```
parity/
  VERSION             pinned release and download locations
  scripts/            fetch-fineract, fetch-java, start/stop-oracle, smoke, run-contract-suite (bash)
  tools/              inventory.py, contract_probe.py, junit_report.py, test_tools.py (Python, stdlib only)
  inventory/          openapi-<version>.json, groups.json, endpoints.csv, SUMMARY.md, test-groups.json
  docker/             Dockerfile, init script and env for Option B
  docker-compose.yml  Option B
  reports/            probe and contract-suite output (git-ignored)
  .cache/             downloads, extracted release, JRE/JDK, database cluster, logs (git-ignored)
```

Still to come: the differential runner (the same generated scenarios replayed against both servers) and
running the Gradle contract suite once there is disk space for it.
