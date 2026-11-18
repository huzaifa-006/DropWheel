#!/bin/bash
# Builds DropWheel.app, a zip and a DMG into ./dist
# Usage: scripts/build-app.sh [version]   (set UNIVERSAL=1 to build arm64 + x86_64)
set -euo pipefail
cd "$(dirname "$0")/.."
VERSION="${1:-1.0.0}"
APP="dist/DropWheel.app"
rm -rf dist && mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

if [[ "${UNIVERSAL:-0}" == "1" ]]; then
  swift build -c release --product DropWheel --arch arm64 --arch x86_64
  BIN=".build/apple/Products/Release/DropWheel"
else
  swift build -c release --product DropWheel
  BIN=".build/release/DropWheel"
fi
cp "$BIN" "$APP/Contents/MacOS/DropWheel"

# Icon
ICONSET="$(mktemp -d)/DropWheel.iconset"; mkdir -p "$ICONSET"
swift scripts/make-icon.swift "$ICONSET/icon_512x512@2x.png"
for s in 16 32 128 256 512; do
  sips -z $s $s "$ICONSET/icon_512x512@2x.png" --out "$ICONSET/icon_${s}x${s}.png" >/dev/null
  d=$((s * 2)); sips -z $d $d "$ICONSET/icon_512x512@2x.png" --out "$ICONSET/icon_${s}x${s}@2x.png" >/dev/null
done
iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/AppIcon.icns"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleName</key><string>DropWheel</string>
  <key>CFBundleDisplayName</key><string>DropWheel</string>
  <key>CFBundleIdentifier</key><string>app.dropwheel.DropWheel</string>
  <key>CFBundleExecutable</key><string>DropWheel</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>${VERSION}</string>
  <key>CFBundleVersion</key><string>${VERSION}</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>LSUIElement</key><true/>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSHumanReadableCopyright</key><string>DropWheel</string>
  <key>NSDesktopFolderUsageDescription</key><string>DropWheel saves converted files next to the originals.</string>
  <key>NSDocumentsFolderUsageDescription</key><string>DropWheel saves converted files next to the originals.</string>
  <key>NSDownloadsFolderUsageDescription</key><string>DropWheel saves converted files next to the originals.</string>
</dict></plist>
PLIST

# Ad-hoc signature (free). For no Gatekeeper warning you need an Apple Developer ID.
codesign --force --deep --sign - "$APP"

(cd dist && ditto -c -k --keepParent DropWheel.app "DropWheel-${VERSION}.zip")
STAGE="$(mktemp -d)"; cp -R "$APP" "$STAGE/"; ln -s /Applications "$STAGE/Applications"
hdiutil create -volname DropWheel -srcfolder "$STAGE" -ov -format UDZO "dist/DropWheel-${VERSION}.dmg" >/dev/null
cp "dist/DropWheel-${VERSION}.dmg" dist/DropWheel.dmg
cp "dist/DropWheel-${VERSION}.zip" dist/DropWheel.zip
echo "Built: $(ls dist)"
