#!/usr/bin/env bash
# Downloads an Eclipse Temurin Java runtime of the version Fineract needs into parity/.cache, so
# the oracle does not depend on (or change) the Java installed on the machine. The download is
# verified against the SHA-256 published by Adoptium. Safe to re-run.
#
#   fetch-java.sh          a JRE (about 60 MB) into parity/.cache/java: enough to run the oracle
#   fetch-java.sh --jdk    a full JDK (about 200 MB) into parity/.cache/jdk: needed to build and run
#                          Fineract's integration tests (run-contract-suite.sh)
set -euo pipefail
# shellcheck source=common.sh
. "$(dirname "${BASH_SOURCE[0]}")/common.sh"

if [ "${1:-}" = "--jdk" ]; then image=jdk; dest="$CACHE_DIR/jdk"; else image=jre; dest="$CACHE_DIR/java"; fi

if [ "$image" = jre ] && [ -n "$(local_java || true)" ]; then
  info "Java $FINERACT_JAVA_MIN runtime already present: $(local_java)"
  exit 0
fi
if [ "$image" = jdk ] && [ -n "$(local_jdk || true)" ]; then
  info "Java $FINERACT_JAVA_MIN JDK already present: $(local_jdk)"
  exit 0
fi

PY="$(command -v python3 || command -v python || true)"
[ -n "$PY" ] || die "python3 or python is required to read the Adoptium API response"

case "$(uname -s)" in
  MINGW*|MSYS*|CYGWIN*) os=windows ;;
  Linux*) os=linux ;;
  Darwin*) os=mac ;;
  *) die "unsupported operating system: $(uname -s)" ;;
esac
case "$(uname -m)" in
  x86_64|AMD64|amd64) arch=x64 ;;
  aarch64|arm64) arch=aarch64 ;;
  *) die "unsupported architecture: $(uname -m)" ;;
esac

info "Looking up Temurin $FINERACT_JAVA_MIN ${image^^} for $os/$arch"
meta="$(curl -fsSL "https://api.adoptium.net/v3/assets/latest/${FINERACT_JAVA_MIN}/hotspot?architecture=${arch}&image_type=${image}&os=${os}&vendor=eclipse")"
read -r name sha256 link < <(printf '%s' "$meta" | "$PY" -c "
import json, sys
a = json.load(sys.stdin)[0]['binary']['package']
print(a['name'], a['checksum'], a['link'])
" | tr -d '\r')
[ -n "$name" ] && [ -n "$sha256" ] && [ -n "$link" ] || die "unexpected response from the Adoptium API"

cd "$CACHE_DIR"
info "Downloading $name"
curl -fL --no-progress-meter --retry 5 --retry-delay 5 -C - -o "$name" "$link"

info "Verifying SHA-256"
actual="$(sha256sum "$name" | cut -d' ' -f1)"
[ "$actual" = "$sha256" ] || die "SHA-256 mismatch for $name (expected $sha256, got $actual). Delete it and retry."
echo "    SHA-256 OK"

rm -rf "$dest" "$dest.tmp"
mkdir -p "$dest.tmp"
case "$name" in
  *.zip) "$PY" -c "import sys, zipfile; zipfile.ZipFile(sys.argv[1]).extractall(sys.argv[2])" "$name" "$dest.tmp" ;;
  *.tar.gz) tar -xzf "$name" -C "$dest.tmp" ;;
esac
# The archive holds a single top-level directory (for example jdk-25.0.5+8-jre).
mv "$dest.tmp"/* "$dest"
rmdir "$dest.tmp"
rm -f "$name"
if [ "$image" = jdk ]; then info "Ready: $(local_jdk)"; else info "Ready: $(local_java)"; fi
