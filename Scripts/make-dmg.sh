#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

APP="$ROOT/dist/Lumora.app"
VERSION="$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' "$ROOT/Resources/Info.plist")"
DMG="$ROOT/dist/Lumora-$VERSION.dmg"
STAGING="$ROOT/.build/dmg-staging"
SIGN_IDENTITY="${SIGN_IDENTITY:--}"

"$ROOT/Scripts/build-app.sh"
python3 "$ROOT/Scripts/bundle-dylibs.py" "$APP"

BINARY="$APP/Contents/MacOS/Lumora"
while read -r rpath; do
    case "$rpath" in
        /opt/homebrew*|/usr/local*) install_name_tool -delete_rpath "$rpath" "$BINARY" ;;
    esac
done < <(otool -l "$BINARY" | awk '/cmd LC_RPATH/{getline; getline; print $2}')

if otool -L "$BINARY" "$APP"/Contents/Frameworks/*.dylib | grep -E '^\s+/(opt/homebrew|usr/local)/'; then
    echo "error: bundle still references Homebrew paths" >&2
    exit 1
fi

for lib in "$APP"/Contents/Frameworks/*.dylib; do
    codesign --force --sign "$SIGN_IDENTITY" --timestamp=none "$lib"
done
codesign --force --sign "$SIGN_IDENTITY" --timestamp=none "$APP"
codesign --verify --deep --strict "$APP"

rm -rf "$STAGING" "$DMG"
mkdir -p "$STAGING"
cp -R "$APP" "$STAGING/"
ln -s /Applications "$STAGING/Applications"
hdiutil create -volname "Lumora" -srcfolder "$STAGING" -ov -format UDZO "$DMG" >/dev/null
rm -rf "$STAGING"

printf 'App: %s (%s)\n' "$APP" "$(du -sh "$APP" | cut -f1)"
printf 'DMG: %s (%s)\n' "$DMG" "$(du -sh "$DMG" | cut -f1)"
