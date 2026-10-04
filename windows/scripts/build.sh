#!/bin/bash
# Build the Windows installer on macOS (or Linux): a cross-compiled release executable,
# then an NSIS setup around it.
#   needs: rustup target x86_64-pc-windows-gnu, mingw-w64, makensis (brew install mingw-w64 makensis)
#   out:   windows/dist/UsageManager-<version>-windows-x64-setup.exe
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

# The rustup toolchain carries the Windows target; a Homebrew rust on PATH does not.
if command -v rustup >/dev/null; then
  TC="$(dirname "$(rustup which rustc)")"
  export PATH="$TC:$PATH" RUSTC="$TC/rustc"
fi

VERSION="$(sed -n 's/^version = "\(.*\)"/\1/p' Cargo.toml | head -1)"
cargo test --quiet
cargo build --release --target x86_64-pc-windows-gnu

REL="$ROOT/target/x86_64-pc-windows-gnu/release"
# The GNU build loads WebView2 through this DLL, so it ships beside the executable.
[ -f "$REL/WebView2Loader.dll" ] || cp "$(find "$ROOT/target/x86_64-pc-windows-gnu/release/build" -path '*x64/WebView2Loader.dll' | head -1)" "$REL/"

mkdir -p dist
OUT="dist/UsageManager-$VERSION-windows-x64-setup.exe"
# makensis reads the script in the locale’s encoding; under the C locale it rejects UTF-8.
LC_ALL=en_US.UTF-8 makensis -V2 -DVERSION="$VERSION" -DSRC="$REL" -DOUT="$ROOT/$OUT" installer.nsi
shasum -a 256 "$OUT"
echo "Built $OUT"
