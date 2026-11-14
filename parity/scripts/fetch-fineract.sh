#!/usr/bin/env bash
# Downloads the pinned Apache Fineract binary release into parity/.cache, verifies it, and
# extracts it. Verification is not optional: the script stops if the SHA-512 does not match,
# and verifies the PGP signature when gpg is available.
set -euo pipefail
# shellcheck source=common.sh
. "$(dirname "${BASH_SOURCE[0]}")/common.sh"

cd "$CACHE_DIR"

download() { # download <file>
  local f="$1"
  curl -fL --no-progress-meter --retry 5 --retry-delay 5 -C - -o "$f" "$FINERACT_DIST_URL/$f" 2>/dev/null \
    || curl -fL --no-progress-meter --retry 5 --retry-delay 5 -C - -o "$f" "$FINERACT_ARCHIVE_URL/$f"
}

info "Fetching Apache Fineract $FINERACT_VERSION (binary release)"
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

if [ ! -d "$FINERACT_HOME" ]; then
  info "Extracting to $FINERACT_HOME"
  mkdir -p "$FINERACT_HOME.tmp"
  tar -xzf "$ARCHIVE" -C "$FINERACT_HOME.tmp"
  mv "$FINERACT_HOME.tmp" "$FINERACT_HOME"
fi

jar="$(find "$FINERACT_HOME" -name "fineract-provider-${FINERACT_VERSION}.jar" | head -n 1)"
[ -n "$jar" ] || die "no fineract-provider jar found under $FINERACT_HOME"
info "Ready: $jar"
