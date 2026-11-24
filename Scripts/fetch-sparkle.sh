#!/usr/bin/env bash
# Downloads (checksum-verified) and unpacks Sparkle into .build/deps/sparkle.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DEPS="$ROOT/.build/deps"
SRC="$DEPS/src"

SPARKLE_VERSION="2.10.1"
SPARKLE_URL="https://github.com/sparkle-project/Sparkle/releases/download/${SPARKLE_VERSION}/Sparkle-${SPARKLE_VERSION}.tar.xz"
SPARKLE_SHA256="1a856d2a9edb8e628de88121d7be04cf0e2167f8641650b78fca00b14244cf27"
FILE="$SRC/Sparkle-$SPARKLE_VERSION.tar.xz"

if [[ -f "$DEPS/sparkle/.version-$SPARKLE_VERSION" ]]; then
    exit 0
fi
mkdir -p "$SRC"
if [[ ! -f "$FILE" ]]; then
    curl -fL --retry 3 -o "$FILE.part" "$SPARKLE_URL"
    mv "$FILE.part" "$FILE"
fi
echo "$SPARKLE_SHA256  $FILE" | shasum -a 256 -c - >/dev/null || { echo "error: checksum mismatch for Sparkle" >&2; exit 1; }
rm -rf "$DEPS/sparkle"
mkdir -p "$DEPS/sparkle"
tar -xJf "$FILE" -C "$DEPS/sparkle"
touch "$DEPS/sparkle/.version-$SPARKLE_VERSION"
echo "==> Sparkle $SPARKLE_VERSION ready"
