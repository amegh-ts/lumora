#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

CONFIGURATION="${CONFIGURATION:-release}"
ARCH="${ARCH:-arm64}"
APP="$ROOT/dist/Lumora.app"
ICONSET="$ROOT/.build/Lumora.iconset"

BIN_DIR="$(swift build -c "$CONFIGURATION" --arch "$ARCH" --show-bin-path)"
swift build -c "$CONFIGURATION" --arch "$ARCH"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

cp "$BIN_DIR/Lumora" "$APP/Contents/MacOS/Lumora"
cp "$ROOT/Resources/Info.plist" "$APP/Contents/Info.plist"
strip -x "$APP/Contents/MacOS/Lumora"
chmod +x "$APP/Contents/MacOS/Lumora"
plutil -lint "$APP/Contents/Info.plist"

if command -v iconutil >/dev/null 2>&1; then
    rm -rf "$ICONSET"
    swift "$ROOT/Scripts/make-icon.swift" "$ICONSET"
    iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/AppIcon.icns"
fi

# strip invalidates the linker's ad-hoc signature; re-sign so the bundle launches.
# make-dmg.sh signs again after bundling libraries.
codesign --force --sign - "$APP" 2>/dev/null

printf 'Built %s\n' "$APP"
du -sh "$APP"
