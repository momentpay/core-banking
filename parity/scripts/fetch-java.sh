#!/usr/bin/env bash
# Downloads an Eclipse Temurin JRE of the version Fineract needs into parity/.cache/java, so
# the oracle does not depend on (or change) the Java installed on the machine. The download is
# verified against the SHA-256 published by Adoptium. Safe to re-run.
set -euo pipefail
# shellcheck source=common.sh
. "$(dirname "${BASH_SOURCE[0]}")/common.sh"

if [ -n "$(local_java || true)" ]; then
  info "Java $FINERACT_JAVA_MIN runtime already present: $(local_java)"
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

info "Looking up Temurin $FINERACT_JAVA_MIN JRE for $os/$arch"
meta="$(curl -fsSL "https://api.adoptium.net/v3/assets/latest/${FINERACT_JAVA_MIN}/hotspot?architecture=${arch}&image_type=jre&os=${os}&vendor=eclipse")"
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

rm -rf "$CACHE_DIR/java" "$CACHE_DIR/java.tmp"
mkdir -p "$CACHE_DIR/java.tmp"
case "$name" in
  *.zip) "$PY" -c "import sys, zipfile; zipfile.ZipFile(sys.argv[1]).extractall(sys.argv[2])" "$name" "$CACHE_DIR/java.tmp" ;;
  *.tar.gz) tar -xzf "$name" -C "$CACHE_DIR/java.tmp" ;;
esac
# The archive holds a single top-level directory (for example jdk-25.0.5+8-jre).
mv "$CACHE_DIR/java.tmp"/* "$CACHE_DIR/java"
rmdir "$CACHE_DIR/java.tmp"
rm -f "$name"
info "Ready: $(local_java)"
