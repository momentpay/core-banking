# Design reference: what E-CoreBank takes from Apache Fineract

Status: draft (14 Nov 2026). Decision record: [ADR-0001](../adr/0001-follow-fineract-design.md).
Written for the engineers building E-CoreBank. Facts below were read from the Fineract 1.16.1 source
release and from the running oracle, not recalled from memory. Paths are inside the source release
(`parity/scripts/fetch-fineract.sh --source`; set `PARITY_SRC_DIR` to a short path on Windows).

## 1. The rule

**Where Fineract has a design for something, we follow it.** It has run in production for over ten years.
A departure needs an ADR and an entry in `docs/divergences.md`, so it is a decision rather than an accident.
Fineract is Apache-2.0: we may read, follow and port its design and algorithms. Anything copied
verbatim (SQL, schema text, a distinctive algorithm) keeps the Apache licence header and is listed in
`NOTICE`. The names "Apache Fineract" and "Mifos" stay out of the product (see the plan, section 2).

## 2. Where the design lives

| What you need | Where to look |
|---|---|
| Why it is built this way | `fineract-doc/src/docs/en/chapters/architecture/` (`principles`, `design`, `system`, `persistence`, `idempotency`, `business-date`, `loan-locking`, `batch-jobs`, `reliable-event-framework`, `validation`, `api-backward-compatibility`) and `chapters/command/` |
| Where Fineract itself says the design is weak | `architecture/cross-feature-boundary-violations.adoc` (a 70 KB list of cross-feature entanglement), and the note at the top of `architecture/design.adoc` that command processing is "a little bit convoluted" |
| The data model | [parity/inventory/SCHEMA.md](../../parity/inventory/SCHEMA.md): 280 tables, 2,970 columns, 568 foreign keys, each table assigned to an area and an E-CoreBank app. Raw files: `fineract-schema-1.16.1-columns.csv` and `-keys.csv`. Regenerate with `parity/scripts/export-schema.sh` |
| The migration history | `fineract-provider/src/main/resources/db/changelog/` (471 Liquibase files: `tenant-store` and `tenant`) |
| The API contract | [parity/inventory/endpoints.csv](../../parity/inventory/endpoints.csv) and `openapi-1.16.1.json` |
| Behaviour you cannot read from code | Run the same call against the oracle (`https://localhost:8443/fineract-provider`) |
| The tests that define correct | `integration-tests/` (about 390 classes), run with `parity/scripts/run-contract-suite.sh` |

## 3. What we adopt

| Fineract design | What it is | E-CoreBank equivalent |
|---|---|---|
| **Headless, API-only core** | Every capability is reachable only through the REST API. No private back door for a bundled UI. "The core stays core": origination workflow, scoring and channel logic live in surrounding systems | The compatible API and later the native API are the only entrances. Our LiveView console is an API client in spirit: it goes through the same command and query layers |
| **Command/query separation** | Writes are commands, reads are plain SQL queries (`ReadPlatformService`). Every state-changing command is persisted, which gives an audit trail and powers maker-checker | `ecb_platform` command bus: validate, authorise, execute in one `Ecto.Multi`, persist the command. Reads are separate query modules, not changesets |
| **Command persisted before it is trusted** | `PortfolioCommandSourceWritePlatformService` records each command in `m_portfolio_command_source` with a status. Updates store only the changed fields. 1.16 adds a newer typed command framework (`fineract-command*`: dispatcher, handlers, before/after/error hooks, store, audit, idempotency) and an `m_command` table | Follow the newer dispatcher/handler/hook shape. Keep the `m_portfolio_command_source` data model for parity |
| **Maker-checker by running, then rolling back** | If maker-checker applies and the caller is not a checker, the command runs fully inside a transaction so domain validation is real, is rolled back at the end, and a `Pending` entry is logged. Approval re-runs it | Same behaviour, same statuses. Configurable per command, with fine-grained permissions per API |
| **Idempotency** | A command is identified by idempotency key plus action name plus entity name. Same request again: return the stored result with `x-served-from-cache: true`. Still running: HTTP 409. Batch items carry their own key. Header name is `Idempotency-Key` (the docs spell it wrongly in places; the config default is correct) | Same contract, same header. Unique constraint on (key, action, entity) |
| **Vertical-slice packaging** | Per feature: `api`, `handler`, `service` (read and write), `domain`, `data`, `serialization` | One Elixir context per feature inside its app. The same six roles, as modules: controller, command handler, read module, write module, Ecto schema, serializer |
| **Database per tenant** | A tenant-store database lists tenants and their connection details. Each tenant has its own database. Tenant database password is stored encrypted with a master password | Implemented: `ecb_tenants` registry plus dynamic repo per tenant. **Divergence:** we store an environment-variable name, never a password (ADR-0001) |
| **Liquibase, per tenant** | Tenant schema and tenant-store schema migrate separately, with database-specific changesets selected by context | Ecto migrations: `priv/repo/migrations` (registry) and `priv/tenant_repo/migrations` (tenants). PostgreSQL only |
| **Write, read and batch instance types** | The same binary runs as write, read (replica) and batch instances, switched by `fineract.mode.*` flags | Same release, node roles chosen by configuration. Needed before COB at scale |
| **Business date** | A logical business day separate from the calendar, plus a COB date. Managed by API or job. Used wherever a date is not supplied. Makes back-dated tests, missed-day catch-up and COB-while-open possible | `Clock` behaviour with the same date types and the same business-date API. Phase 1 |
| **Close of business as configurable business steps** | COB is a partitioned job made of ordered business steps stored in configuration, with manager and worker nodes | Oban partitioned queues, steps in configuration. Phase 5 |
| **Loan locking** | `m_loan_account_locks`: soft lock (COB queued: run an inline COB for the request) and hard lock (a worker has the loan: reject with 409), `bypass_enabled` for repairs, orphaned-lock clean-up step | Same table and semantics. Phase 4 |
| **Reliable event framework** | Business events written to an outbox table in the same transaction, then published in order, at least once, as Avro | Transactional outbox. Follow Fineract's event types and Avro schemas (`fineract-avro-schemas`) |
| **Data tables** | Tenants extend core tables with their own tables through an API | `ecb_platform` data-table engine. Phase 1 |
| **API backward compatibility checked automatically** | An OpenAPI descriptor is the contract, and changes are checked mechanically | Our CI diffs against the pinned descriptor (`parity/inventory`) |
| **Data model and names** | `m_*` tables for portfolio features, `acc_*` for accounting, `c_*` for configuration | **Follow it: same table and column names, types and constraints for the in-scope tables.** Elixir field names may differ through `source:` mappings. Reasons: SQL reports and data tables reference these names, migration is a plain data copy, and parity checks can compare rows |

## 4. Where we deliberately differ

These follow from the platform, not from disagreement with the design.

| Fineract | E-CoreBank | Why |
|---|---|---|
| JPA with EclipseLink, partly eager fetching (Fineract's own docs call this a known flaw) | Ecto with explicit preloads | No hidden fetching |
| Spring Batch, Spring events | Oban, Broadway, `Phoenix.PubSub` | The BEAM's native tools |
| Jersey resources and handler lookup by reflection | Phoenix controllers and an explicit handler registry | Compile-time visible |
| Cross-feature entanglement (compile-time, database, infrastructure, transactional) documented in `cross-feature-boundary-violations.adoc` | Umbrella apps with one-way dependencies, checked by the compiler and `mix xref` | We copy the capability, not the entanglement |
| MySQL and MariaDB paths kept alongside PostgreSQL | PostgreSQL only | Fineract is deprecating the others |
| Tenant password stored in a table | Environment variable reference | No secret at rest in the registry |
| Angular UI | LiveView | One language and runtime |

## 5. How to take a feature from Fineract

For each feature (for example "savings accounts"):

1. **Scope.** Filter `endpoints.csv` by group and priority. Only `must` and `should` are built.
2. **Read the design.** The relevant adoc chapter, then the vertical slice in `fineract-provider/.../portfolio/<feature>` (and the matching module such as `fineract-savings`).
3. **Take the data model.** The area's tables in `SCHEMA.md`, then the keys and columns CSVs. Write the Ecto migration to match.
4. **Pin behaviour with the oracle.** Call the endpoints on Fineract and keep the requests and responses as fixtures.
5. **Write the pure core first** for calculations (schedules, interest), as plain functions on `Decimal`, with the same rounding rules.
6. **Implement the handlers and queries**, then run the contract probe and the matching integration-test classes.
7. **Record departures** in `docs/divergences.md`.

## 6. Open points

- Table and column names are adopted as-is (section 3). Say if you would rather use Elixir-style names with a mapping layer; the cost is that Fineract SQL reports and data tables would need rewriting.
- Which of the 1.16 newer-framework features (async dispatcher, LMAX Disruptor, Chronicle Queue) matter. Our default is the synchronous dispatcher and Oban for asynchrony.
- Avro on the wire for events, or JSON with the same field names. Avro keeps consumers compatible; JSON is easier to debug.
