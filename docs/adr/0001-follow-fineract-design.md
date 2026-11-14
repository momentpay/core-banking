# ADR-0001: Follow Apache Fineract's design

- Status: accepted (direction given by the product owner on 14 Nov 2026: "design related information can be taken from Fineract design, which is proven"). Details below are my reading of that and are open to correction.
- Supersedes: the plan's earlier statement that E-CoreBank would have "its own domain model and schema".

## Context

E-CoreBank is a rewrite of Apache Fineract and the Mifos console in Elixir. Fineract's architecture, data model and
algorithms have been used in production for over ten years and are documented in its own source release. Inventing a
new design would add risk without adding value, and would make parity with Fineract harder to prove.

## Decision

1. **Follow Fineract's design wherever it has one:** command/query separation with persisted commands, maker-checker by
   run-then-roll-back, idempotency, vertical-slice features, database per tenant, business date, COB as business steps,
   loan locking, the reliable event framework with an outbox, data tables, and the accounting model.
2. **Follow its data model**: the same table names, column names, types and constraints for in-scope tables
   (`parity/inventory/SCHEMA.md`). Elixir field names may differ through Ecto `source:` mappings.
3. **Departures are explicit.** Each needs an ADR and a line in `docs/divergences.md`. The planned ones are in
   [docs/design/00-fineract-design-reference.md](../design/00-fineract-design-reference.md), section 4.
4. **Licence hygiene.** Fineract is Apache-2.0. Verbatim material (SQL, schema text, distinctive algorithms) keeps its
   licence header and is listed in `NOTICE`. The names "Apache Fineract" and "Mifos" are not used in the product.

## Consequences

- Migration from an existing Fineract database is a data copy rather than a transformation.
- Fineract SQL reports and data tables that reference `m_*` tables keep working.
- Parity can be checked at three levels: API (probe), behaviour (Fineract's integration tests) and data (row comparison).
- We inherit Fineract's naming conventions, including awkward ones. Accepted.
- We deliberately do not inherit its documented weaknesses: eager fetching, cross-feature entanglement, a convoluted
  legacy command path, and the tenant database password stored in a table.
- Upgrades follow Fineract's own changelog: each release is diffed (OpenAPI, schema export, changelogs) before we move the pin.

## Open

- Confirm the data-model decision (2). The alternative is idiomatic Elixir names with a mapping layer, at the cost of
  rewriting Fineract's SQL reports and data tables.
- Avro or JSON for outbox events.
