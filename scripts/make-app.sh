#!/bin/bash
# Builds a distributable BranchLens.app and zips it into dist/.
# Usage: scripts/make-app.sh [version]
set -euo pipefail
cd "$(dirname "$0")/.."

VERSION="${1:-0.1.1}"
BUILD_STAMP="$(date -u +%Y-%m-%dT%H:%MZ)"
ICON_SRC="Resources/AppIcon-1024.png"

if [ -d "/Applications/Xcode.app" ] && [ "$(xcode-select -p)" = "/Library/Developer/CommandLineTools" ]; then
    export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
fi

if [ ! -f "$ICON_SRC" ]; then
    echo "Missing app icon at $ICON_SRC" >&2
    exit 1
fi

echo "Building release…"
swift build -c release
BIN=.build/release/BranchLens

APP=dist/BranchLens.app
rm -rf dist
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/BranchLens"

echo "Generating icon…"
ICONSET=dist/AppIcon.iconset
mkdir -p "$ICONSET"
for s in 16 32 128 256 512; do
    sips -z "$s" "$s" "$ICON_SRC" --out "${ICONSET}/icon_${s}x${s}.png" > /dev/null
    d=$((s * 2))
    sips -z "$d" "$d" "$ICON_SRC" --out "${ICONSET}/icon_${s}x${s}@2x.png" > /dev/null
done
# 1024 is represented as 512@2x
cp "$ICON_SRC" "${ICONSET}/icon_512x512@2x.png"
iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/AppIcon.icns"
rm -rf "$ICONSET"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key>              <string>BranchLens</string>
    <key>CFBundleDisplayName</key>       <string>BranchLens</string>
    <key>CFBundleIdentifier</key>        <string>app.branchlens.BranchLens</string>
    <key>CFBundleExecutable</key>        <string>BranchLens</string>
    <key>CFBundlePackageType</key>       <string>APPL</string>
    <key>CFBundleShortVersionString</key><string>${VERSION}</string>
    <key>CFBundleVersion</key>           <string>${VERSION}</string>
    <key>BranchLensBuildStamp</key>      <string>${BUILD_STAMP}</string>
    <key>CFBundleIconFile</key>          <string>AppIcon</string>
    <key>CFBundleIconName</key>          <string>AppIcon</string>
    <key>LSMinimumSystemVersion</key>    <string>14.0</string>
    <key>LSApplicationCategoryType</key> <string>public.app-category.developer-tools</string>
    <key>NSHighResolutionCapable</key>   <true/>
    <key>NSPrincipalClass</key>          <string>NSApplication</string>
</dict>
</plist>
PLIST

echo "Ad-hoc signing…"
codesign --force --deep --sign - "$APP"

# Touch Launch Services so Dock/Finder pick up the new icon.
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f "$APP" >/dev/null 2>&1 || true

ZIP="dist/BranchLens-${VERSION}-macos.zip"
ditto -c -k --keepParent "$APP" "$ZIP"
echo "Done: $ZIP"
