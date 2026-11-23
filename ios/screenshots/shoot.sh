#!/bin/bash
# Renders mock.html into 1320x2868 PNGs (App Store 6.9" iPhone size) with headless Chrome.
set -euo pipefail
cd "$(dirname "$0")"
CHROME="/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"
n=1
for s in locked idle shield emergency onboarding; do
  "$CHROME" --headless=new --disable-gpu --hide-scrollbars --allow-file-access-from-files \
    --force-device-scale-factor=3 --window-size=440,956 --virtual-time-budget=1500 \
    --screenshot="$PWD/$n-$s.png" "file://$PWD/mock.html#$s" 2>/dev/null
  n=$((n + 1))
done
sips -g pixelWidth -g pixelHeight ./*.png | grep -v "^$"
