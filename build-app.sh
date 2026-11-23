#!/bin/bash
# Builds Time.app into build/ and copies it to /Applications.  ./build-app.sh [--no-install] [--release]
# --release builds for both Apple silicon and Intel and zips the app for a GitHub release, without installing.
set -euo pipefail

INSTALL=1
RELEASE=0
for arg in "$@"; do
  case "$arg" in
    --no-install) INSTALL=0 ;;
    --release) RELEASE=1; INSTALL=0 ;;
    *) echo "Error: unknown option $arg" >&2; exit 1 ;;
  esac
done

REPO="$(cd "$(dirname "$0")" && pwd)"
OUT="$REPO/build/Time.app"
VERSION="$(node -p "require('$REPO/package.json').version")"
# Unique per build, so the app can tell when the installed service is older than itself.
BUILD="$(date +%Y%m%d%H%M%S)"

[ -d "$REPO/node_modules/tlock-js" ] || (cd "$REPO" && npm install --omit=dev)

rm -rf "$OUT"
mkdir -p "$OUT/Contents/MacOS" "$OUT/Contents/Resources/payload"

ARCHS="$(uname -m)"
[ "$RELEASE" = 1 ] && ARCHS="arm64 x86_64"

echo "==> Compiling ($ARCHS)"
for arch in $ARCHS; do
  swiftc -O -swift-version 5 -target "$arch-apple-macos13.0" \
    -framework AppKit -framework WebKit \
    -o "$REPO/build/Time-$arch" "$REPO/app/main.swift"
done
lipo -create $(for arch in $ARCHS; do echo "$REPO/build/Time-$arch"; done) -output "$OUT/Contents/MacOS/Time"

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

node -e '
  const f = process.argv[1], p = require(f);
  p.build = process.argv[2];
  require("fs").writeFileSync(f, JSON.stringify(p, null, 2) + "\n");
' "$OUT/Contents/Resources/payload/package.json" "$BUILD"

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
  <key>TimeBuild</key><string>$BUILD</string>
  <key>LSMinimumSystemVersion</key><string>13.0</string>
  <key>LSApplicationCategoryType</key><string>public.app-category.productivity</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSPrincipalClass</key><string>NSApplication</string>
  <key>NSAppTransportSecurity</key><dict><key>NSAllowsLocalNetworking</key><true/></dict>
  <key>NSHumanReadableCopyright</key><string>Personal build</string>
</dict>
</plist>
EOF

# Signed with the "Time Local Signing" certificate if there is one, ad hoc otherwise.
IDENTITY="Time Local Signing"
security find-identity -p codesigning | grep -q "\"$IDENTITY\"" || IDENTITY="-"
echo "==> Signing ($IDENTITY)"
codesign --force --deep --sign "$IDENTITY" "$OUT" >/dev/null 2>&1
codesign --verify --deep "$OUT"

if [ "$RELEASE" = 1 ]; then
  ZIP="$REPO/build/Time-$VERSION.zip"
  rm -f "$ZIP"
  # ditto keeps the signature and permissions intact, which a plain zip can break.
  ditto -c -k --keepParent "$OUT" "$ZIP"
  echo "Built $ZIP"
elif [ "$INSTALL" = 1 ]; then
  echo "==> Copying to /Applications"
  pkill -x Time 2>/dev/null || true
  rm -rf /Applications/Time.app
  cp -R "$OUT" /Applications/Time.app
  echo "Built /Applications/Time.app"
else
  echo "Built $OUT"
fi
