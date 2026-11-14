# E-CoreBank

A core banking platform written in Elixir and Phoenix, built as a clean rewrite of the
behaviour of Apache Fineract and the Mifos web console. See [docs/00-rewrite-plan.md](docs/00-rewrite-plan.md)
for the plan and the decisions taken so far.

## Layout

An Elixir umbrella. Dependencies point one way: domain apps depend on `ecb_platform`, never the reverse.

| App | Purpose |
|---|---|
| `apps/ecb_platform` | Tenant registry and tenant scoping (one PostgreSQL database per tenant), and later auth, maker-checker, command bus, audit |
| `apps/ecb_web` | Phoenix endpoint, LiveView console and (later) the Fineract-compatible REST API |

More apps (`ecb_money`, `ecb_ledger`, `ecb_org`, `ecb_party`, `ecb_deposits`, `ecb_loans`, ...) are added as their phase starts.

## Tenancy

`ECBPlatform.Repo` is a small **registry** database (`ecb_tenants`) listing tenants and where each tenant's
database lives. Business data goes through `ECBPlatform.TenantRepo`, a dynamic repo:

```elixir
ECBPlatform.Tenancy.with_tenant("default", fn ->
  ECBPlatform.TenantRepo.query!("SELECT 1")
end)
```

The database password is never stored in the registry. A tenant row names an environment variable
(`db_password_env`), or falls back to `ECB_DB_PASSWORD`.

## Requirements

- Elixir 1.18 and Erlang/OTP 27
- PostgreSQL 15 or newer (`docker compose up -d db` starts one)
- Node is **not** required: Phoenix downloads the esbuild and Tailwind binaries

## Getting started

```sh
export ECB_DB_HOST=localhost ECB_DB_USER=postgres ECB_DB_PASSWORD=postgres   # adjust to your server
mix setup                      # deps, registry database, default tenant database, assets
mix phx.server                 # http://localhost:24000
```

Environment variables: `ECB_DB_HOST` (default `localhost`), `ECB_DB_PORT` (`5432`), `ECB_DB_USER` (`postgres`),
`ECB_DB_PASSWORD` (none), `PORT` (`24000` in development).

Useful tasks:

```sh
mix ecb.tenant.migrate           # create and migrate every tenant database
mix ecb.tenant.migrate default   # one tenant
mix test                         # all apps
mix ecb.check                    # the same checks CI runs
```

## Parity with Apache Fineract

E-CoreBank is measured against a pinned Apache Fineract (1.16.1) that runs alongside it. See
[parity/README.md](parity/README.md) for how to download, verify and start it with or without Docker,
and how to run the smoke test:

```sh
parity/scripts/fetch-fineract.sh   # once
parity/scripts/start-oracle.sh
parity/scripts/smoke.sh
```

## Conventions

- Money is `Decimal`, never float.
- Every decision that is hard to reverse gets an ADR in `docs/adr/`.
- No secrets in the repository. Configuration comes from the environment.

Licence: to be decided (see the plan, open items).
