#!/bin/bash
# Builds "build/Media Helper.app" (universal, macOS 14+, ad-hoc signed).
#
#   ./build.sh                 Release build
#   ./build.sh debug           Debug build
set -euo pipefail
cd "$(dirname "$0")"
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode-beta.app/Contents/Developer}"
CONFIG=Release; [[ "${1:-}" == "debug" ]] && CONFIG=Debug

XCODEGEN="$(command -v xcodegen || echo /opt/homebrew/bin/xcodegen)"
"$XCODEGEN" generate >/dev/null

DERIVED=build/DerivedData
rm -rf "$DERIVED"
xcodebuild -project MediaHelper.xcodeproj -scheme MediaHelper -configuration "$CONFIG" \
  -derivedDataPath "$DERIVED" ARCHS="arm64 x86_64" ONLY_ACTIVE_ARCH=NO build 2>&1 \
  | grep -E "error:|warning: unre|BUILD (SUCCEEDED|FAILED)" || true

SRC="$DERIVED/Build/Products/$CONFIG/Media Helper.app"
[[ -d "$SRC" ]] || { echo "Build failed."; exit 1; }
rm -rf "build/Media Helper.app"
cp -R "$SRC" "build/Media Helper.app"
codesign --force --deep --sign - "build/Media Helper.app"

BIN="build/Media Helper.app/Contents/MacOS/Media Helper"
echo "Built: build/Media Helper.app"
lipo -archs "$BIN" | sed 's/^/Architectures: /'
vtool -show-build "$BIN" | grep -E "minos" | sort -u | sed 's/^ */Deployment target: /'
