#!/usr/bin/env bash
# Stops the parity oracle started by start-oracle.sh: Fineract first, then its PostgreSQL.
# Data is kept in parity/.cache. Pass --purge to delete the database cluster as well.
set -euo pipefail
# shellcheck source=common.sh
. "$(dirname "${BASH_SOURCE[0]}")/common.sh"

if [ -f "$FINERACT_PID_FILE" ]; then
  pid="$(cat "$FINERACT_PID_FILE")"
  if kill -0 "$pid" 2>/dev/null; then
    info "Stopping Fineract (pid $pid)"
    kill "$pid" 2>/dev/null || true
    for _ in $(seq 1 20); do kill -0 "$pid" 2>/dev/null || break; sleep 1; done
    if kill -0 "$pid" 2>/dev/null; then
      # Git Bash: the java process is a Windows process, so fall back to taskkill.
      winpid="$(ps -p "$pid" 2>/dev/null | awk 'NR==2 {print $4}')"
      [ -n "$winpid" ] && taskkill //F //PID "$winpid" >/dev/null 2>&1 || true
    fi
  fi
  rm -f "$FINERACT_PID_FILE"
fi

PGBIN="$(find_pg_bin || true)"
if [ -n "$PGBIN" ] && [ -f "$PG_DATA/PG_VERSION" ]; then
  if "$PGBIN/pg_ctl" -D "$PG_DATA" status >/dev/null 2>&1; then
    info "Stopping PostgreSQL"
    "$PGBIN/pg_ctl" -D "$PG_DATA" -m fast -w stop >/dev/null 2>&1 </dev/null
  fi
fi

if [ "${1:-}" = "--purge" ]; then
  info "Deleting $PG_DATA"
  rm -rf "$PG_DATA"
fi
info "Stopped"
