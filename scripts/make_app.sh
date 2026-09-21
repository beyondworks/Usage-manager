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

# Ad-hoc sign so macOS assigns a stable identity (needed for the login-item API).
codesign --force --sign - "$APP" >/dev/null 2>&1 || true

echo "Built $APP"
