#!/bin/bash
# Build a drag-to-install DMG containing Usage Manager.app.
#
# NOTE: the app is ad-hoc signed, not notarized. On the machine that built it
# there is no warning. On another Mac, the first launch shows a Gatekeeper
# prompt — right-click the app → Open (once), or run:
#   xattr -dr com.apple.quarantine /Applications/Usage Manager.app
# A fully warning-free install requires an Apple Developer ID + notarization.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

# 1) Fresh release .app
"$ROOT/scripts/make_app.sh"

APP="$ROOT/Usage Manager.app"
DMG="$ROOT/UsageManager.dmg"
VOL="Usage Manager"

# 2) Stage app + /Applications symlink + volume icon for drag-install
STAGING="$(mktemp -d)"
trap 'rm -rf "$STAGING"' EXIT
cp -R "$APP" "$STAGING/"
ln -s /Applications "$STAGING/Applications"
cp "$ROOT/AppIcon.icns" "$STAGING/.VolumeIcon.icns"   # bars icon as the mounted-volume icon

# 3) Build a read-write image, flag the volume as having a custom icon, then
#    convert to a compressed read-only DMG (the flag carries through the convert).
rm -f "$DMG"
hdiutil detach "/Volumes/$VOL" >/dev/null 2>&1 || true   # clear a stale mount, if any
RWDMG="$(mktemp -u).dmg"
hdiutil create -volname "$VOL" -srcfolder "$STAGING" -ov -format UDRW "$RWDMG" >/dev/null
MOUNT="$(hdiutil attach "$RWDMG" -nobrowse -noverify -noautoopen | grep -o '/Volumes/.*' | head -1)"
if [ -n "$MOUNT" ]; then
    /usr/bin/SetFile -a C "$MOUNT" 2>/dev/null \
        || echo "  (SetFile unavailable — volume icon flag not set; DMG still builds)" >&2
    hdiutil detach "$MOUNT" >/dev/null
fi
hdiutil convert "$RWDMG" -format UDZO -o "$DMG" >/dev/null
rm -f "$RWDMG"

echo "Built $DMG"
