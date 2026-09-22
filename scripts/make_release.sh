#!/bin/bash
# Build the release DMGs: one per Mac architecture, from a single universal build.
#
#   scripts/make_release.sh            → dist/UsageManager-<ver>-{apple-silicon,intel}.dmg
#
# macOS only. The app is built on SwiftUI's MenuBarExtra, AppKit, FSEvents and
# ServiceManagement, so there is no Windows or Linux target to package.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
VER="$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' scripts/Info.plist)"
DIST="$ROOT/dist"
rm -rf "$DIST"; mkdir -p "$DIST"

echo "building universal binary (arm64 + x86_64)…"
swift build -c release --arch arm64 --arch x86_64 >/dev/null
FAT="$(find "$ROOT/.build" -path '*Products/Release/UsageManager' -type f -perm +111 | head -1)"
[ -n "$FAT" ] || { echo "release binary not found" >&2; exit 1; }

# App icon, drawn once and reused by both bundles.
ICONSET="$ROOT/build/UsageManager.iconset"
mkdir -p "$ICONSET"
swift "$ROOT/scripts/make_icon.swift" "$ICONSET" >/dev/null
iconutil -c icns "$ICONSET" -o "$ROOT/AppIcon.icns"

package() {  # package <arch> <label>
    local arch="$1" label="$2"
    local app="$DIST/stage-$label/Usage Manager.app"
    rm -rf "$DIST/stage-$label"
    mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
    lipo "$FAT" -extract "$arch" -output "$app/Contents/MacOS/UsageManager"
    cp scripts/Info.plist "$app/Contents/Info.plist"
    cp AppIcon.icns "$app/Contents/Resources/AppIcon.icns"
    printf 'APPL????' > "$app/Contents/PkgInfo"
    # Ad-hoc signature: gives the bundle a stable identity for the login-item API.
    # Release builds stay ad-hoc on purpose. A locally created certificate is trusted
    # only on the Mac that made it, so signing with one would mean nothing to anyone
    # downloading the DMG — and an unknown signer reads worse than no signer at all.
    # (make_app.sh, which builds what gets installed here, can use one: see UM_SIGN_ID.)
    codesign --force --sign - "$app" >/dev/null 2>&1 || true

    local stage="$DIST/dmg-$label"
    rm -rf "$stage"; mkdir -p "$stage"
    cp -R "$app" "$stage/"
    ln -s /Applications "$stage/Applications"
    cp AppIcon.icns "$stage/.VolumeIcon.icns"

    local dmg="$DIST/UsageManager-$VER-$label.dmg"
    local rw; rw="$(mktemp -u).dmg"
    hdiutil create -volname "Usage Manager" -srcfolder "$stage" -ov -format UDRW "$rw" >/dev/null
    local mount; mount="$(hdiutil attach "$rw" -nobrowse -noverify -noautoopen | grep -o '/Volumes/.*' | head -1)"
    [ -n "$mount" ] && { /usr/bin/SetFile -a C "$mount" 2>/dev/null || true; hdiutil detach "$mount" >/dev/null; }
    hdiutil convert "$rw" -format UDZO -o "$dmg" >/dev/null
    rm -f "$rw"
    rm -rf "$stage" "$DIST/stage-$label"
    echo "  $(basename "$dmg")  $(du -h "$dmg" | cut -f1)  [$(lipo -archs "$app/Contents/MacOS/UsageManager" 2>/dev/null || echo "$arch")]"
}

package arm64 apple-silicon
package x86_64 intel
echo "done → $DIST"
