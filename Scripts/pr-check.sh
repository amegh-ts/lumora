#!/usr/bin/env bash
# Fast checks for pull requests (no app or DMG build). Runs the same locally and in CI.
#   1. swift-format lint (strict)
#   2. plist / entitlements validity
#   3. shell and Python script syntax
#   4. release metadata: version bump, build number, release notes, tag not taken
#   5. compile check (debug) against Homebrew libmpv + Sparkle
# Usage: Scripts/pr-check.sh [base-ref]   (default base: origin/main)
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"
BASE="${1:-origin/main}"
FAILED=0

step() { printf '\n==> %s\n' "$1"; }
fail() { printf 'error: %s\n' "$1" >&2; FAILED=1; }

step "Lint (swift-format)"
if ! swift format lint --strict --recursive Sources Package.swift; then
    fail "swift-format found issues — run: swift format format -i -r Sources Package.swift"
fi

step "Property lists"
for plist in Resources/Info.plist Resources/Lumora.entitlements; do
    plutil -lint "$plist" >/dev/null || fail "$plist is not a valid property list"
done

step "Scripts"
for script in Scripts/*.sh; do
    bash -n "$script" || fail "$script has a syntax error"
done
for script in Scripts/*.py Scripts/patches/*.py; do
    python3 -m py_compile "$script" || fail "$script has a syntax error"
done

step "Release metadata"
plist_value() { /usr/libexec/PlistBuddy -c "Print $1" "$2"; }
VERSION="$(plist_value CFBundleShortVersionString Resources/Info.plist)"
BUILD="$(plist_value CFBundleVersion Resources/Info.plist)"
if [[ ! "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    fail "CFBundleShortVersionString '$VERSION' is not x.y.z"
fi
if git rev-parse --verify --quiet "$BASE" >/dev/null; then
    BASE_PLIST="$(mktemp)"
    git show "$BASE:Resources/Info.plist" > "$BASE_PLIST"
    BASE_VERSION="$(plist_value CFBundleShortVersionString "$BASE_PLIST")"
    BASE_BUILD="$(plist_value CFBundleVersion "$BASE_PLIST")"
    rm -f "$BASE_PLIST"
    if [[ "$VERSION" != "$BASE_VERSION" ]]; then
        echo "release $BASE_VERSION → $VERSION (build $BASE_BUILD → $BUILD)"
        (( BUILD > BASE_BUILD )) || fail "CFBundleVersion must increase when the version changes ($BASE_BUILD → $BUILD)"
        [[ -s "release-notes/$VERSION.md" ]] || fail "release-notes/$VERSION.md is missing"
        if git ls-remote --exit-code --tags origin "refs/tags/v$VERSION" >/dev/null 2>&1; then
            fail "tag v$VERSION already exists — bump the version"
        fi
    else
        echo "no version change ($VERSION) — merging will build but not release"
    fi
else
    echo "base $BASE not found; skipping version comparison"
fi

step "Compile"
"$ROOT/Scripts/fetch-sparkle.sh"
if ! swift build 2>&1 | tee .build/pr-check-build.log | grep -E "error:|Compiling|Build complete" | grep -vE "^\[" ; then
    true
fi
grep -q "error:" .build/pr-check-build.log && fail "swift build failed (see .build/pr-check-build.log)"

if (( FAILED )); then
    printf '\nPR check failed.\n' >&2
    exit 1
fi
printf '\nPR check passed.\n'
