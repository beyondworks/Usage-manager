#!/bin/bash
# The session list stops growing after five rows but still shows part of the sixth.
# Rendering the popover is the only place that geometry is real, so the check renders
# it rather than reading the constants back.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

BIN=".build/debug/UsageManager"
[ -x "$BIN" ] || swift build >/dev/null

OUT="$(mktemp -d)"
trap 'rm -rf "$OUT"' EXIT

height() {
    USAGE_MANAGER_DEMO=1 USAGE_MANAGER_DEMO_ROWS="$1" "$BIN" --snap "$OUT/$1.png" >/dev/null
    sips -g pixelHeight "$OUT/$1.png" | awk '/pixelHeight/ {print $2}'
}

h4=$(height 4); h5=$(height 5); h6=$(height 6); h8=$(height 8)
echo "heights: 4=$h4 5=$h5 6=$h6 8=$h8"

row=$((h5 - h4))
peek=$((h6 - h5))
fail=0
[ "$row" -gt 0 ]      || { echo "FAIL  a fifth row adds no height"; fail=1; }
[ "$peek" -gt 0 ]     || { echo "FAIL  the sixth row does not show at all"; fail=1; }
[ "$peek" -lt "$row" ] || { echo "FAIL  the sixth row shows in full, so the list still grows"; fail=1; }
[ "$h8" -eq "$h6" ]   || { echo "FAIL  height keeps growing past six rows"; fail=1; }

# The README screenshot has to be a render of this same layout, not an older one.
shot=$(sips -g pixelHeight docs/screenshot.png | awk '/pixelHeight/ {print $2}')
[ "$shot" -eq "$h6" ] || { echo "FAIL  docs/screenshot.png is $shot tall, this layout renders $h6"; fail=1; }

# Documentation drift, the two claims this layout change made. A grep only proves the
# sentence is there; the behaviour behind it is what check_rows and check_hooks measure.
if ! grep -q "다섯 개를 넘으면" README.md; then
    echo "FAIL  README does not describe the sixth row"; fail=1
fi
if grep -q "Codex 세션은 목록에도 그대로 나오고" README.md; then
    echo "FAIL  README still says Codex threads are listed"; fail=1
fi

[ "$fail" -eq 0 ] && echo "OK rows" || exit 1
