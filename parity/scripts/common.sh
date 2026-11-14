#!/usr/bin/env bash
# Shared settings for the parity scripts. Source this file; do not run it.
# Works in Git Bash on Windows and on Linux. Requires: bash, curl, tar, sha512sum, python,
# Java 25 (run fetch-java.sh to get one), and PostgreSQL server binaries (initdb, pg_ctl, psql).

PARITY_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CACHE_DIR="$PARITY_DIR/.cache"
# shellcheck source=../VERSION
. "$PARITY_DIR/VERSION"

ARCHIVE="apache-fineract-bin-${FINERACT_VERSION}.tar.gz"
FINERACT_HOME="$CACHE_DIR/fineract-${FINERACT_VERSION}"
# Where the Fineract source release is extracted and built. Override PARITY_SRC_DIR with a SHORT path
# (for example /d/fsrc): Fineract builds deeply nested paths, and Windows stops at 260 characters
# unless long paths are enabled, which fails the build in confusing ways.
FINERACT_SRC="${PARITY_SRC_DIR:-$CACHE_DIR/src}/apache-fineract-src-${FINERACT_VERSION}"
FINERACT_PID_FILE="$CACHE_DIR/fineract.pid"
FINERACT_LOG="$CACHE_DIR/fineract.log"
FINERACT_PORT="${FINERACT_PORT:-8443}"
FINERACT_BASE="https://localhost:${FINERACT_PORT}/fineract-provider"

# A throwaway PostgreSQL cluster dedicated to the oracle. It listens on loopback only and is
# separate from any other PostgreSQL on the machine.
PG_DATA="$CACHE_DIR/pgdata"
PG_LOG="$CACHE_DIR/postgres.log"
PG_PORT="${PARITY_PG_PORT:-54330}"
PG_USER=postgres
PG_PASSWORD="fineract-local-only"

mkdir -p "$CACHE_DIR"

die() { echo "error: $*" >&2; exit 1; }
info() { echo "==> $*"; }

# Locate a PostgreSQL bin directory (override with PG_BIN).
find_pg_bin() {
  if [ -n "${PG_BIN:-}" ] && [ -x "$PG_BIN/pg_ctl" -o -x "$PG_BIN/pg_ctl.exe" ]; then echo "$PG_BIN"; return; fi
  if command -v pg_ctl >/dev/null 2>&1; then dirname "$(command -v pg_ctl)"; return; fi
  local d
  for d in /usr/lib/postgresql/*/bin "/d/Program Files/PostgreSQL"/*/bin "/c/Program Files/PostgreSQL"/*/bin; do
    if [ -x "$d/pg_ctl" ] || [ -x "$d/pg_ctl.exe" ]; then echo "$d"; fi
  done | sort -V | tail -n 1
}

# The Java runtime downloaded by fetch-java.sh, if present.
local_java() {
  local j
  for j in "$CACHE_DIR/java/bin/java" "$CACHE_DIR/java/bin/java.exe"; do
    if [ -x "$j" ]; then echo "$j"; return; fi
  done
  return 0
}

# The JDK (with a compiler) downloaded by `fetch-java.sh --jdk`, if present. Prints its home directory.
local_jdk() {
  local d="$CACHE_DIR/jdk"
  if [ -x "$d/bin/javac" ] || [ -x "$d/bin/javac.exe" ]; then echo "$d"; fi
  return 0
}

# Locate a Java runtime new enough for Fineract (see FINERACT_JAVA_MIN in VERSION).
# Order: JAVA_HOME, the runtime downloaded by fetch-java.sh, then java on the PATH.
find_java() {
  # Each candidate is tried in turn and the first one that is new enough wins, so an older
  # JAVA_HOME does not hide the downloaded runtime.
  local j major tried=""
  for j in "${JAVA_HOME:+$JAVA_HOME/bin/java}" "$(local_java)" "$(command -v java 2>/dev/null || true)"; do
    [ -n "$j" ] && [ -x "$j" ] || continue
    major="$("$j" -version 2>&1 | sed -n 's/.*version "\([0-9]*\).*/\1/p' | head -n 1)"
    if [ "${major:-0}" -ge "$FINERACT_JAVA_MIN" ]; then echo "$j"; return; fi
    tried="$tried java ${major:-?} at $j;"
  done
  die "Java $FINERACT_JAVA_MIN or newer is required (found:${tried:- none}). Run parity/scripts/fetch-java.sh."
}

# Quick check that the oracle answers on its health endpoint.
fineract_up() {
  curl -ksf --max-time 5 "$FINERACT_BASE/actuator/health" 2>/dev/null | grep -q '"status":"UP"'
}
