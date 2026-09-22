#!/bin/bash
# Build a release .app bundle for the menu-bar app.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

swift build -c release --product UsageManager

# App icon (.icns), drawn parametrically by make_icon.swift
ICONSET="$ROOT/build/UsageManager.iconset"
mkdir -p "$ICONSET"
swift "$ROOT/scripts/make_icon.swift" "$ICONSET" >/dev/null
iconutil -c icns "$ICONSET" -o "$ROOT/AppIcon.icns"

APP="$ROOT/Usage Manager.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$ROOT/.build/release/UsageManager" "$APP/Contents/MacOS/UsageManager"
cp "$ROOT/scripts/Info.plist" "$APP/Contents/Info.plist"
cp "$ROOT/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"
printf 'APPL????' > "$APP/Contents/PkgInfo"

# Sign so macOS assigns an identity (the login-item API needs one).
#
# An ad-hoc signature's designated requirement is the code hash itself, so every build
# is a different app as far as the keychain is concerned — and the "always allow" the
# user granted for reading Claude's credentials is forgotten each time. Signing with a
# named certificate instead ties the requirement to the identifier and that certificate,
# so the grant survives a rebuild.
#
# Set UM_SIGN_ID to the certificate's common name to use it. A self-signed certificate
# in the login keychain is enough; it is trusted only on this Mac, which is why release
# builds stay ad-hoc (see make_release.sh) — elsewhere it would mean nothing.
if [ -n "${UM_SIGN_ID:-}" ] && codesign --force --sign "$UM_SIGN_ID" "$APP" 2>/dev/null; then
    echo "signed with $UM_SIGN_ID"
else
    [ -n "${UM_SIGN_ID:-}" ] && echo "note: '$UM_SIGN_ID' unavailable; falling back to ad-hoc" >&2
    codesign --force --sign - "$APP" >/dev/null 2>&1 || true
fi

echo "Built $APP"
