#!/bin/sh
# Creates the two databases Fineract expects: the tenant store and the default tenant.
# Runs once, when the PostgreSQL data volume is first initialised.
set -eu

psql -v ON_ERROR_STOP=1 --username "$POSTGRES_USER" --dbname postgres <<'SQL'
CREATE DATABASE fineract_tenants;
CREATE DATABASE fineract_default;
SQL
