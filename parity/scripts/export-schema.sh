#!/usr/bin/env bash
# Exports the database schema of the running Fineract oracle (the default tenant database) as two CSV
# files in parity/inventory/: every column, and every primary key, foreign key and unique constraint.
# This is the proven data model that E-CoreBank's schema follows (see docs/design/).
#
# Needs the oracle's PostgreSQL running (parity/scripts/start-oracle.sh). Read-only.
set -euo pipefail
# shellcheck source=common.sh
. "$(dirname "${BASH_SOURCE[0]}")/common.sh"

PGBIN="$(find_pg_bin)"
[ -n "$PGBIN" ] || die "PostgreSQL client binaries not found. Install PostgreSQL or set PG_BIN."
OUT="$PARITY_DIR/inventory"
psqlq() { "$PGBIN/psql" -h 127.0.0.1 -p "$PG_PORT" -U "$PG_USER" -d fineract_default -v ON_ERROR_STOP=1 -q -c "$1"; }

info "Exporting columns"
psqlq "COPY (
  SELECT c.table_name, c.ordinal_position AS position, c.column_name, c.data_type,
         c.character_maximum_length AS max_length, c.numeric_precision AS precision, c.numeric_scale AS scale,
         c.is_nullable AS nullable, (c.column_default IS NOT NULL) AS has_default
  FROM information_schema.columns c
  JOIN information_schema.tables t ON t.table_schema = c.table_schema AND t.table_name = c.table_name
  WHERE c.table_schema = 'public' AND t.table_type = 'BASE TABLE'
  ORDER BY c.table_name, c.ordinal_position
) TO STDOUT WITH CSV HEADER" | tr -d '\r' >"$OUT/fineract-schema-$FINERACT_VERSION-columns.csv"

info "Exporting keys and constraints"
psqlq "COPY (
  SELECT cl.relname AS table_name, con.conname AS constraint_name,
         CASE con.contype WHEN 'p' THEN 'PRIMARY KEY' WHEN 'f' THEN 'FOREIGN KEY' WHEN 'u' THEN 'UNIQUE' END AS type,
         (SELECT string_agg(a.attname, ';' ORDER BY k.ord) FROM unnest(con.conkey) WITH ORDINALITY k(attnum, ord)
            JOIN pg_attribute a ON a.attrelid = con.conrelid AND a.attnum = k.attnum) AS columns,
         refcl.relname AS ref_table,
         (SELECT string_agg(a.attname, ';' ORDER BY k.ord) FROM unnest(con.confkey) WITH ORDINALITY k(attnum, ord)
            JOIN pg_attribute a ON a.attrelid = con.confrelid AND a.attnum = k.attnum) AS ref_columns
  FROM pg_constraint con
  JOIN pg_class cl ON cl.oid = con.conrelid
  JOIN pg_namespace ns ON ns.oid = cl.relnamespace AND ns.nspname = 'public'
  LEFT JOIN pg_class refcl ON refcl.oid = con.confrelid
  WHERE con.contype IN ('p', 'f', 'u')
  ORDER BY cl.relname, con.contype, con.conname
) TO STDOUT WITH CSV HEADER" | tr -d '\r' >"$OUT/fineract-schema-$FINERACT_VERSION-keys.csv"

info "Wrote $(wc -l <"$OUT/fineract-schema-$FINERACT_VERSION-columns.csv") column rows and $(wc -l <"$OUT/fineract-schema-$FINERACT_VERSION-keys.csv") constraint rows to $OUT"
