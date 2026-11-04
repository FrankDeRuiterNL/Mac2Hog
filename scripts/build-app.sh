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

# Version (Semantic Versioning) from the VERSION file; build number = number of commits.
VERSION=$(tr -d '[:space:]' < VERSION)
BUILD=$(git rev-list --count HEAD 2>/dev/null || echo 1)
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $VERSION" "$APP/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $BUILD" "$APP/Contents/Info.plist"

# App icon: the classic .icns (CFBundleIconFile) plus, when Xcode's actool is available,
# the compiled asset catalog (Assets.car, CFBundleIconName = AppIcon).
cp Resources/AppIcon/Mac2Hog.icns "$APP/Contents/Resources/Mac2Hog.icns"
if xcrun --find actool >/dev/null 2>&1; then
  xcrun actool Resources/AppIcon/Assets.xcassets \
    --compile "$APP/Contents/Resources" \
    --platform macosx --minimum-deployment-target 13.0 \
    --app-icon AppIcon \
    --output-partial-info-plist "$(mktemp -t mac2hog-icon).plist" >/dev/null \
    || echo "warning: actool failed; using Mac2Hog.icns only"
fi

# Ad-hoc sign so macOS allows local network access prompts and launches without "damaged app" errors.
codesign --force --deep --sign - "$APP" >/dev/null 2>&1 || echo "warning: codesign failed (app will still run locally)"

(cd build && rm -f Mac2Hog.zip && ditto -c -k --keepParent Mac2Hog.app Mac2Hog.zip)
echo "Built $APP (v$VERSION, build $BUILD)"
