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
# Any named certificate will do — what matters is that the requirement stops being the
# code hash. UM_SIGN_ID names one explicitly; otherwise an Apple Development
# certificate on this Mac is used, which keeps anyone's certificate name out of the
# repository. Release builds stay ad-hoc (see make_release.sh): a certificate that only
# this Mac trusts would mean nothing to anyone downloading the DMG.
if [ -z "${UM_SIGN_ID:-}" ]; then
    UM_SIGN_ID="$(security find-identity -v -p codesigning 2>/dev/null \
        | sed -n 's/.*"\(Apple Development: [^"]*\)".*/\1/p' | head -1)"
fi
if [ -n "${UM_SIGN_ID:-}" ] && codesign --force --sign "$UM_SIGN_ID" "$APP" 2>/dev/null; then
    echo "signed with $UM_SIGN_ID"
else
    [ -n "${UM_SIGN_ID:-}" ] && echo "note: '$UM_SIGN_ID' unavailable; falling back to ad-hoc" >&2
    codesign --force --sign - "$APP" >/dev/null 2>&1 || true
fi

echo "Built $APP"
