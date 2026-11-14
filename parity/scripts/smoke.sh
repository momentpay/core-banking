#!/usr/bin/env bash
# Smoke test for a Fineract-compatible server. Defaults to the Fineract oracle. Point it at
# E-CoreBank to check wire compatibility:
#
#   BASE=http://localhost:24000/fineract-provider parity/scripts/smoke.sh
#
# Checks: health, authentication (what the Mifos web app does at login), and a read call.
set -euo pipefail
# shellcheck source=common.sh
. "$(dirname "${BASH_SOURCE[0]}")/common.sh"

BASE="${BASE:-$FINERACT_BASE}"
TENANT="${TENANT:-default}"
USER_NAME="${FINERACT_USER:-mifos}"
USER_PASS="${FINERACT_PASSWORD:-password}"
fail=0
check() { # check <name> <ok|fail> [detail]
  if [ "$2" = ok ]; then echo "PASS  $1"; else echo "FAIL  $1 ${3:-}"; fail=1; fi
}

echo "Target: $BASE (tenant $TENANT)"

health="$(curl -ksf --max-time 10 "$BASE/actuator/health" || true)"
case "$health" in *'"status":"UP"'*) check "health endpoint reports UP" ok ;; *) check "health endpoint reports UP" fail "($health)" ;; esac

auth="$(curl -ks --max-time 20 -X POST "$BASE/api/v1/authentication" \
  -H "Fineract-Platform-TenantId: $TENANT" -H "Content-Type: application/json" \
  -d "{\"username\":\"$USER_NAME\",\"password\":\"$USER_PASS\"}" || true)"
case "$auth" in *base64EncodedAuthenticationKey*) check "authentication returns an auth key" ok ;; *) check "authentication returns an auth key" fail "($(echo "$auth" | head -c 200))" ;; esac

code="$(curl -ks --max-time 20 -o /tmp/ecb-smoke-offices.json -w '%{http_code}' -u "$USER_NAME:$USER_PASS" \
  -H "Fineract-Platform-TenantId: $TENANT" "$BASE/api/v1/offices" || echo 000)"
if [ "$code" = 200 ] && grep -q '"name"' /tmp/ecb-smoke-offices.json 2>/dev/null; then
  check "GET /offices returns the office list" ok
else
  check "GET /offices returns the office list" fail "(HTTP $code)"
fi
rm -f /tmp/ecb-smoke-offices.json

[ "$fail" = 0 ] && echo "All smoke checks passed" || { echo "Some smoke checks failed"; exit 1; }
