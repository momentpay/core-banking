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

## Layout

```
parity/
  VERSION             pinned release and download locations
  scripts/            fetch, start, stop, smoke (bash)
  docker/             Dockerfile, init script and env for Option B
  docker-compose.yml  Option B
  .cache/             downloads, extracted release, database cluster, logs (git-ignored)
```

Coming next in Phase 0: the contract-suite runner (Fineract's integration tests against our base
URL), the endpoint inventory from the OpenAPI spec, and the differential runner.
