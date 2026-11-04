#!/usr/bin/env bash
# Builds Mac2Hog in release mode and wraps it into a double-clickable Mac2Hog.app bundle.
set -euo pipefail
cd "$(dirname "$0")/.."

CONFIG=${CONFIG:-release}
swift build -c "$CONFIG" --product Mac2Hog
BIN="$(swift build -c "$CONFIG" --show-bin-path)/Mac2Hog"

APP=build/Mac2Hog.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/Mac2Hog"
cp Resources/Info.plist "$APP/Contents/Info.plist"

# Ad-hoc sign so macOS allows local network access prompts and launches without "damaged app" errors.
codesign --force --deep --sign - "$APP" >/dev/null 2>&1 || echo "warning: codesign failed (app will still run locally)"

(cd build && rm -f Mac2Hog.zip && ditto -c -k --keepParent Mac2Hog.app Mac2Hog.zip)
echo "Built $APP"
