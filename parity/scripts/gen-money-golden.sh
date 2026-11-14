#!/usr/bin/env bash
# Regenerates the golden-master fixtures for apps/ecb_money by running Apache Fineract's own `Money`
# class (from the pinned binary release) on generated cases.
#
#   parity/scripts/gen-money-golden.sh [SEED] [CASES_PER_COMBINATION]
#
# Needs: the Fineract binary release (fetch-fineract.sh) and a JDK 25 (fetch-java.sh --jdk). The
# fixture is committed, so the Elixir tests do not need any of this; run it only to refresh the
# fixture, for example after moving to a new Fineract version.
set -euo pipefail
# shellcheck source=common.sh
. "$(dirname "${BASH_SOURCE[0]}")/common.sh"

SEED="${1:-20261114}"
PER_COMBO="${2:-120}"
OUT_JSON="$CACHE_DIR/fineract_money_golden.json"
OUT="$PARITY_DIR/../apps/ecb_money/test/fixtures/fineract_money_golden.json.gz"

JDK="$(local_jdk)"
[ -n "$JDK" ] || die "A JDK $FINERACT_JAVA_MIN is required. Run parity/scripts/fetch-java.sh --jdk"
JAR="$(find "$FINERACT_HOME" -name "fineract-provider-${FINERACT_VERSION}.jar" 2>/dev/null | head -n 1)"
[ -n "$JAR" ] || die "Fineract is not downloaded. Run parity/scripts/fetch-fineract.sh"

# The provider jar is a Spring Boot fat jar. Fineract's own classes and every dependency are in
# BOOT-INF/lib, so unpack that once into a class path directory.
CP_DIR="${PARITY_CLASSPATH_DIR:-$CACHE_DIR/classpath}"
if [ ! -d "$CP_DIR/lib" ]; then
  info "Unpacking dependency jars to $CP_DIR (once, about 200 MB)"
  PY="$(command -v python3 || command -v python)"
  "$PY" - "$JAR" "$CP_DIR" <<'PYEOF'
import sys, zipfile, pathlib
jar, dest = sys.argv[1], pathlib.Path(sys.argv[2])
(dest / "lib").mkdir(parents=True, exist_ok=True)
with zipfile.ZipFile(jar) as z:
    for name in z.namelist():
        if name.startswith("BOOT-INF/lib/") and name.endswith(".jar"):
            (dest / "lib" / pathlib.Path(name).name).write_bytes(z.read(name))
PYEOF
fi

mkdir -p "$(dirname "$OUT")"
info "Running Fineract's Money on generated cases (seed $SEED)"
# On Windows (Git Bash) the Java launcher needs a native path for the wildcard class path.
if command -v cygpath >/dev/null 2>&1; then CP_ARG="$(cygpath -m "$CP_DIR/lib")/*"; else CP_ARG="$CP_DIR/lib/*"; fi
"$JDK/bin/java" -cp "$CP_ARG" "$PARITY_DIR/tools/golden/MoneyGolden.java" "$OUT_JSON" "$SEED" "$PER_COMBO" 2>&1 | grep -v " INFO "
# Compressed, so the committed fixture stays small (about 20 MB of JSON becomes well under 2 MB).
gzip -9 -n -c "$OUT_JSON" > "$OUT"
rm -f "$OUT_JSON"
info "Wrote $OUT ($(wc -c < "$OUT") bytes)"
