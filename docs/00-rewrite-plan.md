# E-CoreBank: clean Elixir/Phoenix rewrite of Apache Fineract and Mifos

Status: plan draft v3 (14 Nov 2026). Supersedes `Core-Banking/04-fineract-mifos-elixir-parity-plan.md`, which assumed Koṣa as the base. v3 records the answers given on 14 Nov. Each row in section 1 becomes an ADR in `docs/adr/` before it is treated as final.

## 1. Decisions taken

| Topic | Decision | Consequence |
|---|---|---|
| Product name | **E-CoreBank**. OTP apps `ecb_*`, module namespaces `ECB<App>` (for example `ECBPlatform`, `ECBWeb`, `ECBLoans`). | "Fineract" and "Mifos" appear only in docs and in "compatible with" statements, never in the product UI or branding (check trademark rules before any marketing use). |
| Repository | `github.com/momentpay/core-banking` (exists, empty). No path dependencies on any sibling repo. | |
| Approach | **Clean rewrite** of Fineract and Mifos. Koṣa is *not* the base. | |
| Design source | **Fineract's own design is followed** (command/query separation, maker-checker, idempotency, business date, COB steps, loan locking, event outbox, accounting) **including its data model** (same table and column names). Direction given 14 Nov 2026. | Replaces "own domain model and schema". Details and planned departures: [design/00-fineract-design-reference.md](design/00-fineract-design-reference.md), [ADR-0001](adr/0001-follow-fineract-design.md). The data-model part is my reading of "design" and is open to correction. |
| Base app | The Phoenix 1.7 app in `core-banking-product\core-banking` (MySQL, single app). | Convert to **PostgreSQL** and an **umbrella** (section 4.4). |
| Parity | API, features and UIs. | |
| Structure | **Umbrella**. | |
| Tenancy | **Aligned with Fineract: one database per tenant** plus a tenant-registry database. | Replaces my earlier row-level-security recommendation. See 4.2. |
| Database | PostgreSQL (Fineract's own recommended database). | MySQL/MariaDB are deprecated in Fineract too. |
| Versions | **Latest stable.** Oracle: Apache Fineract **1.16.1** (ASF release catalog, 29 Oct 2026). UI baseline: the latest Mifos web-app release (targets Fineract **1.14**). | The UI and the API are two releases apart. See 5, item 1. |
| Accounting | **Follow Fineract's accounting** (GL accounts, accounting rules, journal entries, closures, cash/accrual modes). Finacle integration or migration later, through an adapter. | Replaces my earlier "sub-ledger only" idea. Journal and GL endpoints become strict parity, not "adapted". |
| Native API | **Yes**: our own API next to the Fineract-compatible one. | Fineract runs alongside for verification (section 5). |
| Cut list | Defaults proposed in section 9. Awaiting confirmation. | |
| Timeline | Flexible, sequenced by risk and dependency. | |

## 2. What "clean rewrite" means here

- **Rewrite in Elixir, following Fineract's design.** Fineract is the specification, the design reference and the test oracle. We do not machine-translate Java: each feature is re-implemented in Elixir idioms from Fineract's documented design, its source, its API and observed results. Where Fineract documents a weakness (eager fetching, cross-feature entanglement, a convoluted legacy command path) we copy the capability, not the weakness.
- **Wire-compatible API.** The Fineract REST surface (`/fineract-provider/api/v1/...`, `?command=` actions, templates, pagination, error format, tenant header) is reproduced so existing clients keep working. This is a compatibility layer on top of our own domain model, not our internal model.
- **Fineract's data model.** The in-scope tables keep Fineract's names, columns, types and constraints (`parity/inventory/SCHEMA.md`: 280 tables, 2,970 columns). Migration from a Fineract database is therefore a data copy, and Fineract's SQL reports and data tables keep working. Departures need an ADR.
- **Koṣa as reference only.** Its ADRs and patterns (tenant isolation, posting rules as data, parameter cascade, maker-checker, HSM-backed keys) are free design input because it is the same organisation's work. Anything reused is copied deliberately into this repo and owned here. Koṣa and this product later integrate by API only (for example, debit cards funded from deposit accounts).
- **Licences.** Fineract is Apache-2.0. Reimplementing behaviour is fine. If any code or test is copied, keep the licence and NOTICE. Check each Mifos repository's licence before copying anything (some are MPL-2.0, which is file-level copyleft). The product is called E-CoreBank. Do not use the Mifos or Apache Fineract names or logos in product branding. "Compatible with" statements need a trademark check before external use.

## 3. Principles

1. **Parity is measured, not claimed.** Fineract's integration tests run against our service in CI from week one. Pass rate is the progress metric.
2. **Pure core, thin shell.** Loan schedules, interest calculation, charge and allocation logic are pure functions with no database or clock. They are the part where Elixir is strongest and where Fineract bugs have lived. Easy to property-test and diff.
3. **Accounting follows Fineract.** When a product's accounting rule is cash or accrual, the balanced journal is posted in the same database transaction as the business change. When it is "none", nothing is posted, as in Fineract. No module writes another module's balances directly.
4. **Money is `Decimal` plus an explicit currency and rounding policy.** No floats, anywhere. Rounding mode and precision are explicit inputs.
5. **Time is an input.** A `Clock` behaviour supplies the business date, so back-dated, end-of-day and time-travel scenarios are testable. Fineract's own tests depend on business-date control.
6. **Boundaries enforced by the compiler.** Dependencies point one way. A new module cannot reach into another context's tables.
7. **Security by construction.** One database per tenant, a cross-tenant isolation test in CI, maker-checker on mutating commands, immutable audit log, no PII in logs, no secrets in committed config.
8. **ADR before irreversible choices.** Every decision in section 9 becomes an ADR.

## 4. Target architecture

### 4.1 Shape: Elixir umbrella, one release, strict dependency direction

```
core-banking/
  apps/
    ecb_platform      tenant registry and per-tenant repos, auth, RBAC, maker-checker, command bus, audit,
                     idempotency, outbox, config, business-date Clock, datatables engine
    ecb_money         Money and currency, rounding, interest-rate and day-count math (pure)
    ecb_ledger        Fineract-style accounting: GL accounts, accounting rules, journal entries, closures,
                     cash and accrual modes; export port for a later Finacle integration
    ecb_org           offices, staff, codes, currencies, holidays, working days, payment types
    ecb_branch        tellers, cashiers, branch cash (split from ecb_org: it posts journals, so it sits above ecb_ledger)
    ecb_party         clients, groups, identifiers, addresses, family, KYC hooks, documents, notes
    ecb_catalog       charges, tax groups, rates, interest-rate charts, product building blocks
    ecb_deposits      savings, current, fixed and recurring deposits, holds, dormancy, transfers
    ecb_loans         products, schedule engine (pure), disbursement, repayment, accruals, restructure
    ecb_collateral    collateral, guarantors, limits and exposure (later)
    ecb_shares        shares (optional, later)
    ecb_batch         close of business, business date roll, jobs and scheduler on Oban
    ecb_reports       report engine, SQL reports, exports
    ecb_events        business events, hooks and webhooks, Kafka or AMQP adapters (optional)
    ecb_api_fineract  wire-compatible REST layer: routing, serializers, templates, error format
    ecb_api_native    our own E-CoreBank API (/api/ecb/v1), added after the compatible API is stable
    ecb_web           LiveView console (the Mifos rewrite) and its design system
    ecb_migrate       Fineract-to-new data migration tool
  parity/            docker compose for pinned Fineract, harness, differential runner, corpora
  docs/              adr/, plans, runbooks
  config/, rel/, .github/
```

Dependency rule: `ecb_money` ← `ecb_platform` ← `ecb_ledger` ← domain apps ← `ecb_api_fineract` and `ecb_web`. Domain apps talk to each other only through public context modules and events. Enforce with `mix xref` checks in CI (or the `boundary` library).

### 4.2 Core technical choices (to confirm by ADR)

| Concern | Recommendation | Why |
|---|---|---|
| Runtime | Elixir 1.18, OTP 27, Phoenix, Ecto, PostgreSQL | Matches the installed toolchain and your existing skills. |
| Tenancy | **Database per tenant**, as in Fineract. A small `ecb_tenants` registry database holds tenants and their connection details. A tenant is resolved per request (`Fineract-Platform-TenantId` header, and our own header on the native API) or per job, then a dynamic Ecto repo is used for that tenant. | Aligns with Fineract and gives strong isolation. Costs: a pool per tenant, per-tenant migrations, and a registry. Design these in Phase 1. |
| Commands | Command bus: validate, authorize, maker-checker, execute in one `Ecto.Multi`, write audit and outbox rows | Mirrors Fineract's command pipeline and its `?command=` model. |
| Events | Transactional outbox, published by Oban or Broadway | No dual-write bugs. |
| Jobs and COB | Oban with partitioned queues | Replaces Spring Batch. |
| Concurrency on accounts | Start with DB-level optimistic or row locking. Add per-account processes only if load tests demand it. | Simplest correct option first. |
| Event sourcing | **No.** Journals and transaction rows are the history. | Avoid cost with no requirement. |
| API definition | OpenAPI checked against Fineract's published spec in CI | Detects wire drift. |
| UI | Phoenix LiveView plus a component library | One language, no separate Angular build. |
| Quality gates | `mix format`, Credo strict, Dialyzer, Sobelow, `mix_audit`, coverage floor, cross-tenant isolation test | Bank-grade hygiene from day one. |

### 4.3 Accounting and Finacle
- **Decision (14 Nov): follow Fineract's accounting.** `ecb_ledger` reproduces Fineract's model: GL accounts and hierarchy, product accounting rules (none, cash, accrual periodic, accrual upfront), financial-activity mappings, payment-type to account mappings, journal entries with reversal, accruals, closures, provisioning entries, and the `/glaccounts`, `/journalentries`, `/accountingrules`, `/glclosures` endpoints. These are **strict parity** and are tested against Fineract.
- Double entry is enforced by a deferred database constraint.
- Finacle integration or migration comes later. Keep a `GlExport` behaviour in `ecb_ledger` with extraction state per journal and destination, so a Finacle adapter (file, API or other) can be added without touching the product apps. Until then there is no Finacle code.
- When the Finacle step is scoped, still open: how Finacle accepts postings, its chart-of-accounts shape and cut-off rules, and who at the bank or Infosys owns that interface.

### 4.4 Converting the base app (`core-banking-product\core-banking`)

What is there today (read on 14 Nov 2026): a stock Phoenix 1.7 / LiveView 1.0 app, `da_product_app`, about 30 source files, no domain code. It uses MyXQL (MySQL) and a dev database called `walletapp`. The dev config holds a committed database password and endpoint secret. The folder is not under git yet.

Conversion steps:
1. **PostgreSQL.** Replace `myxql` with `postgrex`, switch the Ecto adapter, rewrite the config (dev, test, runtime), and read all credentials from environment variables. Remove the committed password from `config/dev.exs`.
2. **Umbrella.** Root `mix.exs` with `apps_path`. Move code into apps: `ecb_platform` (Repo, application, mailer), `ecb_web` (endpoint, router, components, assets). Add the other apps from 4.1 as empty skeletons only when their phase starts, to avoid dead code.
3. **Rename** `DaProductApp` and `DaProductAppWeb` to `ECBPlatform` and `ECBWeb`.
4. **Raise the Elixir floor** from `~> 1.14` to `~> 1.18`. Dependencies stay on the current Phoenix 1.7 and LiveView 1.0 lines for now; moving to Phoenix 1.8 is a separate decision (ADR).
5. **Tenancy skeleton.** Registry repo plus a dynamic-repo helper, with one tenant (`default`) so Fineract's default tenant name works in the harness.
6. **Tooling.** Add Credo, Dialyzer, Sobelow, `mix_audit`, a formatter config, GitHub Actions, and `docker compose` for PostgreSQL.
7. **Git.** Initialise the repository, set the remote to `momentpay/core-banking`, and push only when you say so.

**Status (14 Nov 2026): steps 1 to 6 are done and verified; step 7 is waiting for your go-ahead.** The repository root is `core-banking-product\core-banking`.
- Two apps: `ecb_platform` (registry `Repo`, dynamic `TenantRepo`, `Tenancy`, `Tenancy.Pools`, `mix ecb.tenant.migrate`) and `ecb_web`.
- `mix ecto.setup` creates the registry database `ecb_tenants` and the `default` tenant database `ecb_default`. Re-running it is safe.
- 13 tests pass (8 platform, 5 web) on PostgreSQL 18, and `mix compile --warnings-as-errors`, `mix format --check-formatted`, `mix credo --strict` and `mix deps.audit` are clean.
- Sobelow could not be verified on this Windows machine (the tool crashes on Windows paths). It is wired into CI, which runs on Linux.
- Not yet done: a second tenant in the isolation test (needs a second database), the Fineract oracle and parity harness (`parity/`, Phase 0), and removal of leftover assets (see below).

Leftovers from the original base app that need a decision:
- `apps/ecb_web/assets/vendor` contains **AG Grid Enterprise** and **AG Charts Enterprise** (commercial). **Decision (14 Nov 2026): keep them.** The licence is held for production use. Record the licence owner and seat or deployment terms in `docs/adr/` so it survives staff changes. Terminal, analytics and map hooks from another product are also still in `assets/js/hooks` and can be removed when convenient.
- The original 272-line MomentPay marketing home page was replaced by a minimal E-CoreBank page.
- The dev endpoint secret in `config/dev.exs` and `config/test.exs` is the one from the base app. It is dev-only, but generate fresh values if the repository will be public.


## 5. The parity machinery (built first)

`parity/` is the first thing that exists, before domain code:

1. **Pinned oracle, running alongside.** Docker compose runs Apache Fineract **1.16.1** (latest in the ASF release catalog on 14 Nov 2026) plus PostgreSQL, next to E-CoreBank, permanently. Every contract test and differential run can be checked against the real thing. **There is no published `apache/fineract:1.16.1` Docker image** (Docker Hub has `develop`, `latest`, commit-SHA tags and 1.10.1 to 1.12.1 only), so the oracle runs from the ASF binary release, verified by SHA-512 and PGP signature. `parity/` supports both a native run (Java 25 plus a dedicated PostgreSQL) and a Docker build of the same release. **Status (14 Nov 2026): the native oracle runs Apache Fineract 1.16.1 and passes the smoke test (health, authentication, `GET /offices`). Fineract 1.16.1 needs Java 25. The Docker variant is written but untested, because Docker Desktop could not start (WSL2 missing).** The ASF catalog page says its data is not yet reviewed by the Fineract project, so re-confirm 1.16.1 as the latest stable release when Phase 0 closes. **Version gap:** the latest Mifos web-app release targets Fineract 1.14. Track A must show which 1.15 and 1.16 API changes break it. If breakage is large, fall back to Fineract 1.14.0 as the oracle for the UI bridge only, and keep 1.16.1 for API and feature parity.
2. **Contract suite.** Fineract's `integration-tests` and e2e modules run against our base URL. A pass-rate dashboard shows green, red, skipped (with reason) per endpoint group. The harness's assumptions (default admin user, tenant id, business date set-up) must be verified in Phase 0.
3. **Endpoint inventory.** Every operation from the OpenAPI spec is classified **must / should / cut** by bank usage. This is the scope contract.
4. **Differential runner.** Generates scenarios (loan lifecycles, savings interest, charges, reversals, back-dated transactions) with StreamData, replays each against both systems, and diffs responses, schedule lines, transactions and balances. Corpora are stored and versioned.
5. **Divergence log.** Intentional differences are explicit, reviewed and linked to an ADR.
6. **UI parity checks.** Screen-by-screen checklist from the Mifos web app, plus recorded Playwright flows (see section 7).

## 6. Phased plan

Exit gate for every phase: contract-suite pass rate for the phase's endpoints, zero unexplained diffs in differential runs, cross-tenant isolation test green, maker-checker and audit on every mutating command, ADRs and runbook updated.

### Phase 0: Foundations and contract (6–8 weeks)
- Repo bootstrap: convert the base app to a PostgreSQL umbrella (4.4), CI, quality gates, docker compose, ADR template, contribution rules.
- `parity/` harness running the pinned Fineract and the baseline suite.
- First module built. **`ecb_money` (14 Nov 2026):** currency, `Money`, rounding modes, math context, day-count types and null-safe decimal helpers, with 138 tests including a golden master of 130,144 cases produced by running Fineract's own `Money` class. The comparison found and fixed two real defects in the first port (negative zero, and a rounding difference at 19-digit precision). See [docs/modules/ecb_money.md](modules/ecb_money.md) and [docs/divergences.md](divergences.md).
- Platform, part 1. **`ecb_platform` command pipeline (14 Nov 2026):** persisted commands, permission checks, maker-checker (run, roll back, park, approve, reject), idempotency with the 409 and replay rules, hooks, users and roles, all on Fineract's own tables. The tenant tables and their seed data (984 permissions, 79 configuration rows) are generated from the oracle's schema by `parity/tools/ddl_export.py`, so they match Fineract exactly. 58 tests run against a real tenant database, including eight concurrent identical requests of which exactly one runs. See [docs/modules/ecb_platform.md](modules/ecb_platform.md) and [docs/divergences.md](divergences.md).
- First API slice. **`ecb_org` offices and `ecb_api_fineract` (14 Nov 2026):** tenant resolution, basic authentication, `POST /authentication`, `GET /offices`, `/offices/{id}` and `/offices/template`, with Fineract's own error shapes captured from the oracle, and the head office and default users seeded from Fineract's data. The real server answers the same head office as Fineract and passes the smoke test; the contract probe started at **2 of 146** counted read operations, the baseline to improve from. 238 tests across the umbrella pass.
- Reference data and administration reads. **Done (14 Nov 2026):** the read endpoints of currencies, codes, payment types, working days, funds, holidays, staff, account-number formats, configurations, permissions, roles, users and password preferences, on migrations generated from Fineract's schema and seed data. Each is checked against a response recorded from Fineract on the same data (33 fixtures, exact match). The contract probe is now **20 of 146** (13.7%). Next: the write side of these resources through the command pipeline, then clients and the catalog.
- Module documents. **Done (14 Nov 2026):** [docs/modules/](modules/README.md) holds one design document per module (18 including the deferred features), each aligned with the Fineract source: scope, API operations, tables, tests, design rules taken from Fineract, build order and acceptance criteria. The generated parts are checked in CI, and the check fails on a dependency cycle or on any endpoint, table, test class or Fineract package that no module owns.
- Design reference. **Done:** [design/00-fineract-design-reference.md](design/00-fineract-design-reference.md) maps each Fineract design element to its E-CoreBank equivalent, and `parity/inventory/SCHEMA.md` assigns all 280 tables of the oracle's schema to an area and an owning app.
- Endpoint inventory and must/should/cut list. **Done (14 Nov 2026):** `parity/inventory/` classifies all 968 operations of Fineract 1.16.1 (535 must, 255 should, 158 defer, 18 test-support, 2 ignore) from the approved cut list. `inventory.py check` fails when a Fineract upgrade adds an unclassified tag.
- Contract measurements. **Done:** the OpenAPI-driven contract probe (`parity/tools/contract_probe.py`) compares status and JSON shape for the 150 read-only `must` and `should` operations that need no setup, and passes 146 of 146 counted operations when the oracle is probed against itself. **Written, not yet run end to end:** the runner for Fineract's own integration tests (`parity/scripts/run-contract-suite.sh`). It needs a JDK 25 and about 8 GB of free disk for the Gradle build, and the development machine has about 2.5 GB free. Its pre-flight checks are tested.
- ADRs: umbrella and boundaries, database-per-tenant, money and rounding, command bus, schema strategy, Fineract-style accounting with a later Finacle adapter, UI approach, versions pinned, native API, naming.
- Confirm the Fineract and Docker image versions and the Mifos web-app tag.

### Phase 1: Platform (8–12 weeks)
- `ecb_platform`, `ecb_money`, `ecb_ledger` skeleton: tenant registry, dynamic repos, per-tenant migrations and the isolation test, auth (local users, OAuth2/OIDC, 2FA), RBAC, maker-checker, audit, idempotency, outbox, Clock, command bus, error and pagination format.
- Datatables engine (custom fields on entities). Cross-cutting and easy to underestimate.
- Gate: a demo "client" endpoint passes its slice of the suite end to end through the tenant registry, with maker-checker and audit.

### Phase 2: Organisation, parties, catalog (8–10 weeks)
- `ecb_org`, `ecb_party`, `ecb_catalog`: offices, staff, codes, currencies, holidays, working days, payment types, clients, groups (if kept), identifiers, addresses, notes, documents, charges, tax groups, rates.
- Gate: contract suite green for these groups. Stock Mifos web app logs in and browses (Track A, section 7).

### Phase 3: Ledger and deposits (4–5 months)
- Full `ecb_ledger` on Fineract's accounting model (4.3): GL accounts, accounting rules, journals, closures, accrual modes, and the `GlExport` port (no Finacle adapter yet).
- `ecb_deposits`: savings and current accounts, interest (all calculation types and posting periods), charges, holds, dormancy, FD and RD, transfers, standing instructions.
- Gate: golden-master diffs of interest and balances against Fineract on generated scenarios.

### Phase 4: Loans (6–9 months, the critical path)
- Pure schedule engine first (flat, declining balance, amortization options, interest-calculation periods, grace, rounding), then repayment strategies and allocation, then transaction processing, reversals, back-dating, then restructure, reschedule, write-off, charge-off, then progressive loans, then working-capital and origination.
- Collateral, guarantors, delinquency and provisioning rules.
- Gate: zero diffs across the generated corpus, including rounding and reversals.

### Phase 5: Close of business and reporting (3–4 months, overlaps 3–4)
- `ecb_batch`: business date, partitioned COB, retry and resume, monitoring.
- `ecb_reports`: report engine and SQL reports, exports, statutory report framework for the pilot country.

### Phase 6: Integration (ongoing from Phase 3)
- `ecb_events`: hooks, webhooks, Kafka or AMQP adapters, notifications (SMS, email).
- Payment-rail adapters as needed (the Mifos Payment Hub equivalent). Integration with Koṣa and card programmes by API.

### Phase 7: Migration, hardening, release (4–6 months)
- `ecb_migrate` from Fineract databases with reconciliation reports, performance and soak tests (COB at scale), security review and penetration test, DR and backup drills, upgrade and rollback runbooks.
- Upstream sync process: each new Fineract release is reviewed, re-run through the suite, and divergences are logged. Budget ~10% of capacity.

## 7. UI plan (Mifos parity)

- **Track A (early, throw-away):** run the stock Mifos web app against `ecb_api_fineract` from Phase 2. It validates wire compatibility with a real client and gives pilots something usable. Use the latest Mifos web-app release (it targets Fineract 1.14), and record what breaks against our 1.16.1-level API.
- **Track B (the rewrite):** LiveView console in `ecb_web`, built module by module after the matching API is green. Start from a screen inventory of the Mifos web app, ranked by daily use by operations staff. Build a small design system first (tables, forms, wizards, maker-checker inbox, search, detail tabs).
- **Retire Track A** per module once the LiveView screens reach parity and Playwright flows pass.
- **Mobile apps** (Kotlin Multiplatform client apps) and **self-service**: they are API clients. Keep them as-is against the compatibility layer. Rewriting them is out of scope unless you decide otherwise.
- **Payment Hub (Java)** is an integration product, not core. Treat as Phase 6.

## 8. Estimates and team

Assumption: 8–12 engineers (platform 3, ledger and deposits 2–3, loans 3, UI 2–3, QA and parity 1–2). These are my rough numbers. Firm them up after Phase 0.

| Milestone | Estimate |
|---|---|
| Phase 0–2 complete: platform, clients, reference data, Mifos Track A browsing | ~6–8 months |
| Bank pilot: CASA, FD/RD, basic loans, COB, Fineract-style accounting | ~12–16 months |
| Broad parity on the "must" list, LiveView UI | ~24–36 months |

Without Koṣa to reuse, the platform phase is longer than in plan 04. The parity harness and the pure loan engine are where the schedule is won or lost.

## 9. Decisions needed (each becomes an ADR)

Resolved on 14 Nov (see section 1): umbrella, database per tenant, latest stable versions, Fineract-style accounting with Finacle later, native API plus Fineract alongside, the name E-CoreBank.

Still open:

1. **Cut list** (explained below). Defaults proposed, please confirm or change.
2. Pilot bank and country (rails, regulatory returns, tax, language and currency handling).
3. Hosting and database operations (cloud, on-prem at the bank, Kubernetes or VMs).
4. Licence for the E-CoreBank repository (proprietary or open), and the handling of any copied test code.
5. Native API timing: the plan puts it after the compatible API is stable. Confirm.

### Cut list: what it means and the proposed defaults

Fineract was built for microfinance as well as banks, so it includes features a retail bank rarely uses. "Cut" does not mean deleted forever. It means **not built in the first releases**. Each deferred endpoint returns a clear "not implemented" error, and the contract suite marks it skipped with a reason, so the pass rate stays honest.

| Feature | What it is | Proposed default for a bank |
|---|---|---|
| Clients (individual and entity), identifiers, addresses, documents, notes | Customer master | **Must** |
| Savings and current accounts, charges, holds, transfers, standing instructions | Core deposit products | **Must** |
| Fixed and recurring deposits, interest-rate charts | Term deposits | **Must** |
| Individual loans (products, schedules, charges, collateral, guarantors, multi-disbursement, restructure, write-off) | Core lending | **Must** |
| Accounting (GL, rules, journals, closures, accruals, provisioning) | Books | **Must** |
| Maker-checker, roles, offices, staff, holidays, business date, close of business, reports | Operations | **Must** |
| Tellers and cashiers | Branch cash handling | **Must** if the pilot bank has branches |
| Hooks and webhooks, notifications | Integration | **Should** (after the pilot core) |
| Progressive and working-capital loans, loan origination module | Newer Fineract lending features | **Should** (progressive first) |
| Floating rates | Variable-rate loans | **Should** |
| Shares accounts | Cooperative member shares | **Defer** unless the bank asks |
| Groups and centers, group loans, joint liability group (JLG) loans, collection sheets, meetings and calendars | Group-based microfinance | **Defer** |
| Investor module | Selling loan portions to external investors | **Defer** |
| SMS campaigns | Bulk marketing | **Defer** |
| Self-service API | Customer-facing endpoints (also removed from the Mifos web-app 1.0.0) | **Defer**. Revisit when a customer channel is planned. |
| XBRL and MIX reporting | Microfinance reporting formats | **Defer** |

Please tell me which rows to change, or say "approve defaults".

## 10. Risks

| Risk | Mitigation |
|---|---|
| Loan rounding and schedule drift | Pure engine, property tests, differential corpus, any diff blocks the phase. |
| Scope creep ("Fineract + Mifos + other modules") | must/should/cut list frozen per release. |
| Mifos UI size | Screen inventory, usage ranking, Track A bridges the gap while Track B is built. |
| Parity chasing a moving target | Pin versions, scheduled upstream sync, divergence log. |
| Underestimated cross-cutting work (datatables, maker-checker, reporting) | Build them in Phase 1, with a vertical-slice gate. |
| Tenant data leak or wrong-tenant write | Database per tenant, tenant resolved once at the edge and carried in a scope, isolation test in CI. Watch for pool exhaustion with many tenants. |
| Money bugs | `Decimal` only, balanced-journal constraint, reconciliation jobs, golden masters. |
| Key-person and hiring risk (Elixir banking engineers) | ADRs, runbooks, pairing, written conventions from day one. |
| Rewrite fatigue | Ship the pilot milestone early, run Fineract in parallel for pilots if needed. |

## 11. First 30 days

1. Decide the repository root (the `core-banking` folder or its parent), initialise git there and set the remote to `momentpay/core-banking`. Add LICENSE and NOTICE decisions, README, `docs/adr/`.
2. Convert the base app to a PostgreSQL umbrella (4.4): `ecb_platform` and `ecb_web` first, then `ecb_money`, `ecb_ledger`, `ecb_api_fineract`. Add CI with the quality gates.
3. Stand up `parity/` with Fineract 1.16.1 and PostgreSQL in docker compose, and run its integration suite to get a baseline pass rate (against Fineract itself, then against an empty E-CoreBank stub).
4. Produce the endpoint inventory from the OpenAPI spec, and apply the confirmed cut list.
5. Draft ADRs for the section 1 decisions, plus money and rounding.
6. Run the stock Mifos web-app against Fineract 1.16.1 to learn what the 1.14 to 1.16 gap breaks.
