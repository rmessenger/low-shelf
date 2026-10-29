#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
swift build -c release --product FineTune -Xswiftc -warnings-as-errors
BIN_DIR="$(swift build -c release --show-bin-path)"
APP="${1:-$PWD/dist/FineTune.app}"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
swift scripts/make-icon.swift "$PWD/dist/AppIcon.iconset"
iconutil -c icns "$PWD/dist/AppIcon.iconset" -o "$APP/Contents/Resources/AppIcon.icns"
cp "$BIN_DIR/FineTune" "$APP/Contents/MacOS/FineTune.new"
mv -f "$APP/Contents/MacOS/FineTune.new" "$APP/Contents/MacOS/FineTune"
cp Resources/Info.plist "$APP/Contents/Info.plist"
codesign --force --sign "${CODESIGN_IDENTITY:--}" --identifier app.lowshelf.LowShelf "$APP"
codesign --verify --strict "$APP"
printf '\nBuilt %s\n' "$APP"
