#!/usr/bin/env bash
# Starts the Apache Fineract parity oracle without Docker: a dedicated throwaway PostgreSQL
# cluster (loopback only, port 54330) plus the pinned Fineract jar. Idempotent.
#
#   parity/scripts/fetch-fineract.sh    # once
#   parity/scripts/start-oracle.sh
#   parity/scripts/smoke.sh
#   parity/scripts/stop-oracle.sh
set -euo pipefail
# shellcheck source=common.sh
. "$(dirname "${BASH_SOURCE[0]}")/common.sh"

JAVA="$(find_java)"
PGBIN="$(find_pg_bin)"
[ -n "$PGBIN" ] || die "PostgreSQL server binaries not found. Install PostgreSQL or set PG_BIN."
JAR="$(find "$FINERACT_HOME" -name "fineract-provider-${FINERACT_VERSION}.jar" 2>/dev/null | head -n 1 || true)"
[ -n "$JAR" ] || die "Fineract is not downloaded. Run parity/scripts/fetch-fineract.sh first."

pg() { "$PGBIN/$1" "${@:2}"; }

# --- PostgreSQL ---------------------------------------------------------------------------
if [ ! -f "$PG_DATA/PG_VERSION" ]; then
  info "Creating PostgreSQL cluster in $PG_DATA"
  pg initdb -D "$PG_DATA" -U "$PG_USER" -A trust -E UTF8 --locale=C >/dev/null
fi
if ! pg pg_ctl -D "$PG_DATA" status >/dev/null 2>&1; then
  info "Starting PostgreSQL on 127.0.0.1:$PG_PORT"
  pg pg_ctl -D "$PG_DATA" -o "-p $PG_PORT -c listen_addresses=127.0.0.1" -l "$PG_LOG" -w start >/dev/null 2>&1 </dev/null
fi
for db in fineract_tenants fineract_default; do
  exists="$(pg psql -h 127.0.0.1 -p "$PG_PORT" -U "$PG_USER" -d postgres -tAc "SELECT 1 FROM pg_database WHERE datname='$db'")"
  if [ "$exists" != "1" ]; then
    info "Creating database $db"
    pg psql -h 127.0.0.1 -p "$PG_PORT" -U "$PG_USER" -d postgres -qc "CREATE DATABASE $db"
  fi
done

# --- Fineract -----------------------------------------------------------------------------
if fineract_up; then
  info "Fineract is already running at $FINERACT_BASE"
  exit 0
fi

# Same settings as Fineract's own docker env files at this release (see parity/docker/fineract.env).
export FINERACT_HIKARI_DRIVER_SOURCE_CLASS_NAME=org.postgresql.Driver
export FINERACT_HIKARI_JDBC_URL="jdbc:postgresql://localhost:$PG_PORT/fineract_tenants"
export FINERACT_HIKARI_USERNAME="$PG_USER"
export FINERACT_HIKARI_PASSWORD="$PG_PASSWORD"
export FINERACT_DEFAULT_TENANTDB_HOSTNAME=localhost
export FINERACT_DEFAULT_TENANTDB_PORT="$PG_PORT"
export FINERACT_DEFAULT_TENANTDB_UID="$PG_USER"
export FINERACT_DEFAULT_TENANTDB_PWD="$PG_PASSWORD"
export FINERACT_DEFAULT_TENANTDB_NAME=fineract_default
export FINERACT_DEFAULT_TENANTDB_IDENTIFIER=default
export FINERACT_DEFAULT_TENANTDB_DESCRIPTION="Default Demo Tenant"
export FINERACT_DEFAULT_TENANTDB_TIMEZONE=Asia/Kolkata
export FINERACT_DEFAULT_MASTER_PASSWORD=fineract
export FINERACT_NODE_ID=1
export FINERACT_SERVER_PORT="$FINERACT_PORT"
export FINERACT_SERVER_SSL_ENABLED=true
export FINERACT_CONTENT_FILESYSTEM_ROOT_FOLDER="$CACHE_DIR/content"
export FINERACT_MANAGEMENT_ENDPOINT_WEB_EXPOSURE_INCLUDE=health,info,prometheus
export FINERACT_REMOTE_JOB_MESSAGE_HANDLER_SPRING_EVENTS_ENABLED=true
export SPRING_PROFILES_ACTIVE=test,diagnostics
mkdir -p "$FINERACT_CONTENT_FILESYSTEM_ROOT_FOLDER"

JVM_OPTS=(
  -Xmx1G -XX:TieredStopAtLevel=1 -XX:ReservedCodeCacheSize=256m
  --add-exports=java.naming/com.sun.jndi.ldap=ALL-UNNAMED
  --add-opens=java.base/java.lang=ALL-UNNAMED
  --add-opens=java.base/java.lang.invoke=ALL-UNNAMED
  --add-opens=java.base/java.io=ALL-UNNAMED
  --add-opens=java.base/java.security=ALL-UNNAMED
  --add-opens=java.base/java.util=ALL-UNNAMED
  --add-opens=java.management/javax.management=ALL-UNNAMED
  --add-opens=java.naming/javax.naming=ALL-UNNAMED
)

info "Starting Fineract $FINERACT_VERSION (first start applies database migrations and can take several minutes)"
nohup "$JAVA" "${JVM_OPTS[@]}" -jar "$JAR" >"$FINERACT_LOG" 2>&1 </dev/null &
echo $! >"$FINERACT_PID_FILE"

for i in $(seq 1 180); do
  if fineract_up; then
    info "Fineract is up: $FINERACT_BASE (waited about $((i * 5))s)"
    exit 0
  fi
  if ! kill -0 "$(cat "$FINERACT_PID_FILE")" 2>/dev/null; then
    tail -n 40 "$FINERACT_LOG" >&2
    die "Fineract exited during start-up. See $FINERACT_LOG"
  fi
  sleep 5
done
tail -n 40 "$FINERACT_LOG" >&2
die "Fineract did not become healthy within 15 minutes. See $FINERACT_LOG"
