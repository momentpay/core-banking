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

# Free space, in MB, on the filesystem holding a path.
free_mb() { df -Pk "$1" | awk 'NR==2 {print int($4 / 1024)}'; }

# Two places grow: Gradle's dependency cache and temp files (GRADLE_USER_HOME), and the build output
# inside the Fineract source tree. They can sit on different drives, so each gets its own threshold.
cache_min_gb="${ECB_MIN_FREE_GB_CACHE:-${ECB_MIN_FREE_GB:-4}}"
build_min_gb="${ECB_MIN_FREE_GB_BUILD:-${ECB_MIN_FREE_GB:-2}}"
cache_free_mb="$(free_mb "$GRADLE_USER_HOME")"
build_free_mb="$(free_mb "$FINERACT_SRC")"
if [ "$cache_free_mb" -lt $(( cache_min_gb * 1024 )) ]; then
  die "only $(( cache_free_mb / 1024 )) GB free where Gradle would keep its cache ($GRADLE_USER_HOME); at least ${cache_min_gb} GB is required. Free space, point GRADLE_USER_HOME at a roomier drive, or lower ECB_MIN_FREE_GB_CACHE if you accept the risk."
fi
if [ "$build_free_mb" -lt $(( build_min_gb * 1024 )) ]; then
  die "only $(( build_free_mb / 1024 )) GB free where the build output goes ($FINERACT_SRC); at least ${build_min_gb} GB is required. Free space or move the source with PARITY_SRC_DIR (use a short path), or lower ECB_MIN_FREE_GB_BUILD if you accept the risk."
fi
# While the build runs, stop it if either drive falls below this many MB. A full system drive is
# worse than a failed build.
abort_free_mb="${ECB_ABORT_FREE_MB:-1024}"

if ! curl -ksf --max-time 10 "$TARGET/actuator/health" 2>/dev/null | grep -q '"status":"UP"'; then
  die "the target is not answering at $TARGET/actuator/health. Fineract's tests need a running server."
fi

STAMP="$(date +%Y%m%d-%H%M%S)"
OUT="$PARITY_DIR/reports/contract-$LABEL-$STAMP"
CMD=(./gradlew --no-daemon --continue "-Porg.gradle.java.installations.paths=$JDK" :integration-tests:test)
[ -n "$TESTS" ] && CMD+=(--tests "$TESTS")

info "Target: $TARGET   JDK: $JDK   free: cache drive $(( cache_free_mb / 1024 )) GB, build drive $(( build_free_mb / 1024 )) GB"
info "Command: (cd $FINERACT_SRC && BACKEND_PROTOCOL=$proto BACKEND_HOST=$host BACKEND_PORT=$port ${CMD[*]})"
if [ "$DRY_RUN" = 1 ]; then info "Dry run: pre-flight passed, nothing executed"; exit 0; fi

# --- run ----------------------------------------------------------------------------------
export JAVA_HOME="$JDK"
export BACKEND_PROTOCOL="$proto" BACKEND_HOST="$host" BACKEND_PORT="$port"
export BACKEND_USERNAME="${BACKEND_USERNAME:-mifos}" BACKEND_PASSWORD="${BACKEND_PASSWORD:-password}" BACKEND_TENANT="${BACKEND_TENANT:-default}"

# Keep temp files next to the Gradle cache rather than on the system drive.
mkdir -p "$GRADLE_USER_HOME/tmp"
export TMPDIR="$GRADLE_USER_HOME/tmp" TMP="$GRADLE_USER_HOME/tmp" TEMP="$GRADLE_USER_HOME/tmp"
export GRADLE_OPTS="${GRADLE_OPTS:-} -Djava.io.tmpdir=$GRADLE_USER_HOME/tmp"

kill_tree() { # kill_tree <pid>: Git Bash starts native Windows processes, so use taskkill when available
  local winpid
  winpid="$(ps -p "$1" 2>/dev/null | awk 'NR==2 {print $4}')"
  if command -v taskkill >/dev/null 2>&1 && [ -n "$winpid" ]; then taskkill //F //T //PID "$winpid" >/dev/null 2>&1 || true
  else kill -TERM "$1" 2>/dev/null || true; fi
}

status=0
( cd "$FINERACT_SRC" && exec "${CMD[@]}" ) &
gradle_pid=$!
aborted=0
while kill -0 "$gradle_pid" 2>/dev/null; do
  sleep 15
  c="$(free_mb "$GRADLE_USER_HOME")"; b="$(free_mb "$FINERACT_SRC")"
  if [ "$c" -lt "$abort_free_mb" ] || [ "$b" -lt "$abort_free_mb" ]; then
    echo "ABORT: free disk fell below ${abort_free_mb} MB (cache drive ${c} MB, build drive ${b} MB). Stopping Gradle." >&2
    kill_tree "$gradle_pid"; aborted=1; break
  fi
done
wait "$gradle_pid" 2>/dev/null || status=$?
[ "$aborted" = 1 ] && { echo "Stopped to protect the disk. Free space, then re-run: Gradle resumes from its cache." >&2; exit 3; }

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
