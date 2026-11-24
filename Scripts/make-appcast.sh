#!/usr/bin/env bash
# Signs dist/Lumora-<version>.dmg with the Sparkle key in the login Keychain (account "lumora")
# and writes dist/appcast.xml pointing at the GitHub release for that version.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
VERSION="$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' "$ROOT/Resources/Info.plist")"
DMG="$ROOT/dist/Lumora-$VERSION.dmg"
TOOLS="$ROOT/.build/deps/sparkle/bin"
REPO_URL="https://github.com/amegh-ts/lumora"
WORK="$ROOT/.build/appcast"

[[ -f "$DMG" ]] || { echo "error: $DMG missing — run Scripts/make-dmg.sh first" >&2; exit 1; }

rm -rf "$WORK"
mkdir -p "$WORK"
cp "$DMG" "$WORK/"
# CI passes the private key through SPARKLE_KEY_FILE; locally the login Keychain is used.
KEY_ARGS=(--account lumora)
if [[ -n "${SPARKLE_KEY_FILE:-}" ]]; then
    KEY_ARGS=(--ed-key-file "$SPARKLE_KEY_FILE")
fi
"$TOOLS/generate_appcast" \
    "${KEY_ARGS[@]}" \
    --download-url-prefix "$REPO_URL/releases/download/v$VERSION/" \
    --full-release-notes-url "$REPO_URL/releases/tag/v$VERSION" \
    --link "$REPO_URL" \
    -o "$WORK/appcast.xml" \
    "$WORK"
cp "$WORK/appcast.xml" "$ROOT/dist/appcast.xml"
echo "Appcast: $ROOT/dist/appcast.xml"
