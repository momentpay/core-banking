#!/usr/bin/env bash
# Runs Apache Fineract's own integration tests against a server and summarises the results by
# functional group. This is the strict contract: the tests are Fineract's, unmodified.
#
#   run-contract-suite.sh [--target URL] [--tests PATTERN] [--label NAME] [--dry-run]
#
#   --target URL    server under test (default: the Fineract oracle). Must end in /fineract-provider,
#                   because that is the path Fineract's tests use.
#   --tests PATTERN Gradle --tests filter, for example '*ClientTest' or '*LoanProductTest'
#   --label NAME    names the report folder (default: the target's host and port)
#   --dry-run       run every pre-flight check and print the Gradle command, but do not run it
#
# Heavy: this builds Fineract's whole multi-module project from source with Gradle (a few GB of
# dependencies and build output, and a long first build). The script therefore refuses to start
# without a JDK 25 and enough free disk space (default 8 GB; ECB_MIN_FREE_GB overrides it).
#
# Setup, once:  fetch-fineract.sh --source   and   fetch-java.sh --jdk
# NOT YET RUN END TO END: the author's machine has about 2.5 GB free, below the guard.
set -euo pipefail
# shellcheck source=common.sh
. "$(dirname "${BASH_SOURCE[0]}")/common.sh"

TARGET="$FINERACT_BASE"; TESTS=""; LABEL=""; DRY_RUN=0
while [ $# -gt 0 ]; do
  case "$1" in
    --target) TARGET="${2:?--target needs a URL}"; shift 2 ;;
    --tests) TESTS="${2:?--tests needs a pattern}"; shift 2 ;;
    --label) LABEL="${2:?--label needs a name}"; shift 2 ;;
    --dry-run) DRY_RUN=1; shift ;;
    -h|--help) sed -n '2,19p' "$0"; exit 0 ;;
    *) die "unknown argument: $1" ;;
  esac
done

# --- target -------------------------------------------------------------------------------
[[ "$TARGET" =~ ^(https?)://([^/:]+)(:([0-9]+))?(/.*)?$ ]] || die "cannot parse --target: $TARGET"
proto="${BASH_REMATCH[1]}"; host="${BASH_REMATCH[2]}"; port="${BASH_REMATCH[4]}"; path="${BASH_REMATCH[5]:-}"
[ -n "$port" ] || { [ "$proto" = https ] && port=443 || port=80; }
[ "${path%/}" = "/fineract-provider" ] || die "the target path must be /fineract-provider (Fineract's tests hard-code it), got '${path}'"
LABEL="${LABEL:-${host}-${port}}"

# --- pre-flight ---------------------------------------------------------------------------
[ -f "$FINERACT_SRC/gradlew" ] || die "Fineract source not found. Run parity/scripts/fetch-fineract.sh --source"

JDK="${JAVA_HOME:-}"
if ! { [ -n "$JDK" ] && { [ -x "$JDK/bin/javac" ] || [ -x "$JDK/bin/javac.exe" ]; }; }; then JDK=""; fi
if [ -n "$JDK" ]; then
  jmajor="$("$JDK/bin/java" -version 2>&1 | sed -n 's/.*version "\([0-9]*\).*/\1/p' | head -n 1)"
  [ "${jmajor:-0}" -ge "$FINERACT_JAVA_MIN" ] || JDK=""
fi
[ -n "$JDK" ] || JDK="$(local_jdk)"
[ -n "$JDK" ] || die "A JDK $FINERACT_JAVA_MIN (with a compiler) is required to build the tests. Run parity/scripts/fetch-java.sh --jdk"

GRADLE_USER_HOME="${GRADLE_USER_HOME:-$CACHE_DIR/gradle}"; export GRADLE_USER_HOME
mkdir -p "$GRADLE_USER_HOME"
min_gb="${ECB_MIN_FREE_GB:-8}"
free_kb="$(df -Pk "$GRADLE_USER_HOME" | awk 'NR==2 {print $4}')"
free_gb=$(( free_kb / 1024 / 1024 ))
if [ "$free_gb" -lt "$min_gb" ]; then
  die "only ${free_gb} GB free where Gradle would store its cache ($GRADLE_USER_HOME); at least ${min_gb} GB is required. Free some space, set GRADLE_USER_HOME to a drive with more room, or lower ECB_MIN_FREE_GB if you accept the risk."
fi

if ! curl -ksf --max-time 10 "$TARGET/actuator/health" 2>/dev/null | grep -q '"status":"UP"'; then
  die "the target is not answering at $TARGET/actuator/health. Fineract's tests need a running server."
fi

STAMP="$(date +%Y%m%d-%H%M%S)"
OUT="$PARITY_DIR/reports/contract-$LABEL-$STAMP"
CMD=(./gradlew --no-daemon --continue "-Porg.gradle.java.installations.paths=$JDK" :integration-tests:test)
[ -n "$TESTS" ] && CMD+=(--tests "$TESTS")

info "Target: $TARGET   JDK: $JDK   free disk: ${free_gb} GB"
info "Command: (cd $FINERACT_SRC && BACKEND_PROTOCOL=$proto BACKEND_HOST=$host BACKEND_PORT=$port ${CMD[*]})"
if [ "$DRY_RUN" = 1 ]; then info "Dry run: pre-flight passed, nothing executed"; exit 0; fi

# --- run ----------------------------------------------------------------------------------
export JAVA_HOME="$JDK"
export BACKEND_PROTOCOL="$proto" BACKEND_HOST="$host" BACKEND_PORT="$port"
export BACKEND_USERNAME="${BACKEND_USERNAME:-mifos}" BACKEND_PASSWORD="${BACKEND_PASSWORD:-password}" BACKEND_TENANT="${BACKEND_TENANT:-default}"

status=0
( cd "$FINERACT_SRC" && "${CMD[@]}" ) || status=$?

RESULTS="$FINERACT_SRC/integration-tests/build/test-results/test"
if [ -d "$RESULTS" ]; then
  mkdir -p "$OUT/xml"
  cp "$RESULTS"/*.xml "$OUT/xml/"
  PY="$(command -v python3 || command -v python)"
  "$PY" "$PARITY_DIR/tools/junit_report.py" "$OUT/xml" --out "$OUT" || true
else
  echo "no test results were produced (Gradle exit code $status)" >&2
fi
exit "$status"
