#!/bin/zsh
# Builds Deepslate.app and an unsigned (ad-hoc signed) DMG into ./dist.
# Usage: ./build.sh [version]   e.g. ./build.sh 1.0.0
set -euo pipefail
cd "${0:a:h}"
VERSION="${1:-0.1.0}"
ICON_SRC="${ICON_SRC:-$HOME/Downloads/deepslate1}"   # TODO before public release: replace with an original icon
APP=dist/Deepslate.app

swift build -c release
rm -rf dist && mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp .build/release/Deepslate "$APP/Contents/MacOS/Deepslate"

if [[ -f "$ICON_SRC" ]]; then
  SET=$(mktemp -d)/AppIcon.iconset && mkdir -p "$SET"
  for s in 16 32 128 256 512; do
    sips -s format png -z $s $s "$ICON_SRC" --out "$SET/icon_${s}x${s}.png" >/dev/null
    sips -s format png -z $((s*2)) $((s*2)) "$ICON_SRC" --out "$SET/icon_${s}x${s}@2x.png" >/dev/null
  done
  iconutil -c icns "$SET" -o "$APP/Contents/Resources/AppIcon.icns"
fi

cat > "$APP/Contents/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleName</key><string>Deepslate</string>
  <key>CFBundleDisplayName</key><string>Deepslate</string>
  <key>CFBundleIdentifier</key><string>com.riyaansheth.deepslate</string>
  <key>CFBundleExecutable</key><string>Deepslate</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>$VERSION</string>
  <key>CFBundleVersion</key><string>$VERSION</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>LSApplicationCategoryType</key><string>public.app-category.developer-tools</string>
  <key>NSHighResolutionCapable</key><true/>
</dict></plist>
EOF

codesign --force --deep --sign - "$APP"

STAGE=$(mktemp -d) && cp -R "$APP" "$STAGE/" && ln -s /Applications "$STAGE/Applications"
hdiutil create -volname Deepslate -srcfolder "$STAGE" -ov -format UDZO "dist/Deepslate-$VERSION.dmg" >/dev/null
echo "Built $APP and dist/Deepslate-$VERSION.dmg"
# Release: gh release create v$VERSION dist/Deepslate-$VERSION.dmg --repo riyaansheth/deepslate-ide
