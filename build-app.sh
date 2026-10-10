#!/bin/bash
# Builds Time.app into build/ and copies it to /Applications.  ./build-app.sh [--no-install]
set -euo pipefail

REPO="$(cd "$(dirname "$0")" && pwd)"
OUT="$REPO/build/Time.app"
VERSION="$(node -p "require('$REPO/package.json').version")"

[ -d "$REPO/node_modules/tlock-js" ] || (cd "$REPO" && npm install --omit=dev)

rm -rf "$OUT"
mkdir -p "$OUT/Contents/MacOS" "$OUT/Contents/Resources/payload"

echo "==> Compiling"
swiftc -O -swift-version 5 -target "$(uname -m)-apple-macos13.0" \
  -framework AppKit -framework WebKit \
  -o "$OUT/Contents/MacOS/Time" "$REPO/app/main.swift"

echo "==> Icon"
ICONSET="$REPO/build/AppIcon.iconset"
rm -rf "$ICONSET" && mkdir -p "$ICONSET"
swift "$REPO/app/icon.swift" "$REPO/build/icon-1024.png"
for s in 16 32 128 256 512; do
  sips -z $s $s "$REPO/build/icon-1024.png" --out "$ICONSET/icon_${s}x${s}.png" >/dev/null
  sips -z $((s * 2)) $((s * 2)) "$REPO/build/icon-1024.png" --out "$ICONSET/icon_${s}x${s}@2x.png" >/dev/null
done
iconutil -c icns "$ICONSET" -o "$OUT/Contents/Resources/AppIcon.icns"

echo "==> Bundling the service"
cp "$REPO/app/setup.html" "$OUT/Contents/Resources/"
cp -R "$REPO/src" "$REPO/ui" "$REPO/node_modules" "$REPO/package.json" "$REPO/install.sh" "$REPO/uninstall.sh" \
  "$OUT/Contents/Resources/payload/"

cat > "$OUT/Contents/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>Time</string>
  <key>CFBundleDisplayName</key><string>Time</string>
  <key>CFBundleIdentifier</key><string>com.rubenhayrapetyan.time</string>
  <key>CFBundleExecutable</key><string>Time</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>$VERSION</string>
  <key>CFBundleVersion</key><string>$VERSION</string>
  <key>LSMinimumSystemVersion</key><string>13.0</string>
  <key>LSApplicationCategoryType</key><string>public.app-category.productivity</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSPrincipalClass</key><string>NSApplication</string>
  <key>NSAppTransportSecurity</key><dict><key>NSAllowsLocalNetworking</key><true/></dict>
  <key>NSAppleEventsUsageDescription</key><string>Time uses this to read and change your Screen Time settings.</string>
  <key>NSHumanReadableCopyright</key><string>Personal build</string>
</dict>
</plist>
EOF

echo "==> Signing (ad hoc)"
codesign --force --deep --sign - "$OUT" >/dev/null 2>&1
codesign --verify --deep "$OUT"

if [ "${1:-}" != "--no-install" ]; then
  echo "==> Copying to /Applications"
  pkill -x Time 2>/dev/null || true
  rm -rf /Applications/Time.app
  cp -R "$OUT" /Applications/Time.app
  echo "Built /Applications/Time.app"
else
  echo "Built $OUT"
fi
