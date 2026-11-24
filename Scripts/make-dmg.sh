#!/usr/bin/env bash
# Builds dist/Lumora.app and dist/Lumora-<version>.dmg.
#
# Environment:
#   SIGN_IDENTITY   codesign identity, e.g. "Developer ID Application: Name (TEAMID)". Default "-" (ad-hoc).
#   NOTARY_PROFILE  notarytool keychain profile (xcrun notarytool store-credentials). Notarizes when set.
#   ALLOW_HOMEBREW_MPV=1  allow bundling Homebrew's GPL libmpv (local testing only).
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

APP="$ROOT/dist/Lumora.app"
VERSION="$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' "$ROOT/Resources/Info.plist")"
DMG="$ROOT/dist/Lumora-$VERSION.dmg"
SPARKLE="$ROOT/.build/deps/sparkle/Sparkle.framework"
SIGN_IDENTITY="${SIGN_IDENTITY:--}"
ENTITLEMENTS="$ROOT/Resources/Lumora.entitlements"

step() { printf '==> %s\n' "$1"; }

if [[ ! -f "$ROOT/.build/deps/prefix/lib/libmpv.dylib" ]]; then
    if [[ "${ALLOW_HOMEBREW_MPV:-}" != "1" ]]; then
        echo "error: LGPL libmpv not built. Run Scripts/build-deps.sh (or set ALLOW_HOMEBREW_MPV=1 for a local-only test build)." >&2
        exit 1
    fi
    echo "warning: bundling Homebrew's GPL libmpv — do not distribute this build" >&2
fi
[[ -d "$SPARKLE" ]] || { echo "error: Sparkle missing. Run Scripts/build-deps.sh" >&2; exit 1; }

step "Building app"
"$ROOT/Scripts/build-app.sh" > "$ROOT/.build/build-app.log" 2>&1 || { tail -30 "$ROOT/.build/build-app.log"; exit 1; }

step "Bundling libraries"
mkdir -p "$APP/Contents/Frameworks"
ditto "$SPARKLE" "$APP/Contents/Frameworks/Sparkle.framework"
python3 "$ROOT/Scripts/bundle-dylibs.py" "$APP"
cp "$ROOT/THIRD_PARTY_NOTICES.md" "$APP/Contents/Resources/"

BINARY="$APP/Contents/MacOS/Lumora"
while read -r rpath; do
    case "$rpath" in
        @executable_path/../Frameworks) ;;
        *) install_name_tool -delete_rpath "$rpath" "$BINARY" ;;
    esac
done < <(otool -l "$BINARY" | awk '/cmd LC_RPATH/{getline; getline; print $2}')

if otool -L "$BINARY" "$APP"/Contents/Frameworks/*.dylib | grep -E '^\s+/(opt/homebrew|usr/local|Users)/'; then
    echo "error: bundle still references absolute non-system paths" >&2
    exit 1
fi

step "Signing ($([[ "$SIGN_IDENTITY" == "-" ]] && echo ad-hoc || echo "$SIGN_IDENTITY"))"
SIGN_FLAGS=(--force --sign "$SIGN_IDENTITY")
if [[ "$SIGN_IDENTITY" != "-" ]]; then
    SIGN_FLAGS+=(--options runtime --timestamp)
else
    SIGN_FLAGS+=(--timestamp=none)
fi
for lib in "$APP"/Contents/Frameworks/*.dylib; do
    codesign "${SIGN_FLAGS[@]}" "$lib" 2>/dev/null
done
SPARKLE_IN_APP="$APP/Contents/Frameworks/Sparkle.framework"
for nested in \
    "$SPARKLE_IN_APP/Versions/B/XPCServices/Installer.xpc" \
    "$SPARKLE_IN_APP/Versions/B/XPCServices/Downloader.xpc" \
    "$SPARKLE_IN_APP/Versions/B/Autoupdate" \
    "$SPARKLE_IN_APP/Versions/B/Updater.app"; do
    [[ -e "$nested" ]] && codesign "${SIGN_FLAGS[@]}" "$nested" 2>/dev/null
done
codesign "${SIGN_FLAGS[@]}" "$SPARKLE_IN_APP" 2>/dev/null
if [[ "$SIGN_IDENTITY" != "-" ]]; then
    codesign "${SIGN_FLAGS[@]}" --entitlements "$ENTITLEMENTS" "$APP" 2>/dev/null
else
    codesign "${SIGN_FLAGS[@]}" "$APP" 2>/dev/null
fi
codesign --verify --deep --strict "$APP"

step "Creating DMG"
DMGBUILD="$ROOT/.build/dmgtools/bin/dmgbuild"
if [[ ! -x "$DMGBUILD" ]]; then
    python3 -m venv "$ROOT/.build/dmgtools"
    "$ROOT/.build/dmgtools/bin/pip" install -q dmgbuild==1.6.5
fi
ART="$ROOT/.build/dmg-art"
rm -rf "$ART" "$DMG"
swift "$ROOT/Scripts/make-dmg-background.swift" "$ART"
tiffutil -cathidpicheck "$ART/background.png" "$ART/background@2x.png" -out "$ART/background.tiff" >/dev/null 2>&1
"$DMGBUILD" -s "$ROOT/Scripts/dmg-settings.py" \
    -D app="$APP" -D background="$ART/background.tiff" \
    "Lumora" "$DMG" >/dev/null
if [[ "$SIGN_IDENTITY" != "-" ]]; then
    codesign --force --sign "$SIGN_IDENTITY" --timestamp "$DMG"
fi

if [[ -n "${NOTARY_PROFILE:-}" ]]; then
    [[ "$SIGN_IDENTITY" != "-" ]] || { echo "error: notarization needs a Developer ID SIGN_IDENTITY" >&2; exit 1; }
    step "Notarizing"
    xcrun notarytool submit "$DMG" --keychain-profile "$NOTARY_PROFILE" --wait
    xcrun stapler staple "$DMG"
fi

printf 'App: %s (%s)\n' "$APP" "$(du -sh "$APP" | cut -f1)"
printf 'DMG: %s (%s)\n' "$DMG" "$(du -sh "$DMG" | cut -f1)"
