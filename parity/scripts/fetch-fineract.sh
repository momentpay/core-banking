#!/usr/bin/env bash
# Downloads the pinned Apache Fineract release into parity/.cache, verifies it, and extracts it.
#
#   fetch-fineract.sh            the binary release (about 450 MB): what the oracle runs
#   fetch-fineract.sh --source   the source release (about 17 MB): holds Fineract's integration tests
#
# Verification is not optional: the script stops if the SHA-512 does not match, and verifies the
# PGP signature when gpg is available.
set -euo pipefail
# shellcheck source=common.sh
. "$(dirname "${BASH_SOURCE[0]}")/common.sh"

kind=bin
[ "${1:-}" = "--source" ] && kind=src

ARCHIVE="apache-fineract-${kind}-${FINERACT_VERSION}.tar.gz"
cd "$CACHE_DIR"

# Already downloaded, verified and extracted: nothing to do. (The archive is not kept, to save disk.)
if [ "$kind" = bin ] && [ -n "$(find "$FINERACT_HOME" -name "fineract-provider-${FINERACT_VERSION}.jar" 2>/dev/null | head -n 1)" ]; then
  info "Fineract $FINERACT_VERSION binary release already present in $FINERACT_HOME"; exit 0
fi
if [ "$kind" = src ] && [ -f "$FINERACT_SRC/gradlew" ]; then
  info "Fineract $FINERACT_VERSION source release already present in $FINERACT_SRC"; exit 0
fi

download() { # download <file>
  local f="$1"
  curl -fL --no-progress-meter --retry 5 --retry-delay 5 -C - -o "$f" "$FINERACT_DIST_URL/$f" 2>/dev/null \
    || curl -fL --no-progress-meter --retry 5 --retry-delay 5 -C - -o "$f" "$FINERACT_ARCHIVE_URL/$f"
}

info "Fetching Apache Fineract $FINERACT_VERSION ($kind release)"
download "$ARCHIVE.sha512"
download "$ARCHIVE.asc"
download "$ARCHIVE"

info "Verifying SHA-512"
expected="$(sed 's/^[^:]*://' "$ARCHIVE.sha512" | tr -d ' \r\n' | tr 'A-F' 'a-f')"
actual="$(sha512sum "$ARCHIVE" | cut -d' ' -f1)"
[ "$expected" = "$actual" ] || die "SHA-512 mismatch for $ARCHIVE (expected $expected, got $actual). Delete it and retry."
echo "    SHA-512 OK"

if command -v gpg >/dev/null 2>&1; then
  info "Verifying PGP signature"
  GNUPGHOME="$CACHE_DIR/gnupg"; export GNUPGHOME
  mkdir -p "$GNUPGHOME"; chmod 700 "$GNUPGHOME" 2>/dev/null || true
  curl -fsSL -o "$CACHE_DIR/KEYS" "$FINERACT_KEYS_URL"
  gpg --batch --quiet --import "$CACHE_DIR/KEYS" 2>/dev/null || true
  if gpg --batch --verify "$ARCHIVE.asc" "$ARCHIVE" 2>"$CACHE_DIR/gpg-verify.txt"; then
    echo "    signature OK"
  else
    cat "$CACHE_DIR/gpg-verify.txt" >&2
    die "PGP signature verification failed"
  fi
else
  echo "    gpg not found: signature NOT verified (SHA-512 only)" >&2
fi

if [ "$kind" = bin ]; then
  target="$FINERACT_HOME"
  if [ ! -d "$target" ]; then
    info "Extracting to $target"
    mkdir -p "$target.tmp"
    tar -xzf "$ARCHIVE" -C "$target.tmp"
    mv "$target.tmp" "$target"
  fi
  jar="$(find "$target" -name "fineract-provider-${FINERACT_VERSION}.jar" | head -n 1)"
  [ -n "$jar" ] || die "no fineract-provider jar found under $target"
  info "Ready: $jar"
else
  if [ ! -d "$FINERACT_SRC" ]; then
    info "Extracting to $FINERACT_SRC"
    mkdir -p "$CACHE_DIR/src"
    tar -xzf "$ARCHIVE" -C "$CACHE_DIR/src"
  fi
  [ -f "$FINERACT_SRC/gradlew" ] || die "unexpected source layout under $FINERACT_SRC"
  info "Ready: $FINERACT_SRC (integration tests in integration-tests/)"
fi

# The verified archive has served its purpose; delete it to save disk (the checksum was checked above).
rm -f "$ARCHIVE"
