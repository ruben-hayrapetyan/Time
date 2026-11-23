#!/bin/bash
# Archives the iPhone app and uploads it to App Store Connect (it appears in TestFlight first).
# Needs Xcode signed in to the developer account, and Apple's approval of the Family Controls
# distribution entitlement for the app and both extensions.   ./release.sh [--archive-only]
set -euo pipefail
cd "$(dirname "$0")"
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"

command -v xcodegen >/dev/null || { echo "Error: brew install xcodegen" >&2; exit 1; }
xcodegen --quiet

ARCHIVE=build/Time.xcarchive
rm -rf "$ARCHIVE" build/export
echo "==> Archiving"
xcodebuild -project TimePhone.xcodeproj -scheme Time -configuration Release \
  -destination 'generic/platform=iOS' -archivePath "$ARCHIVE" -allowProvisioningUpdates -quiet archive

[ "${1:-}" = "--archive-only" ] && { echo "Archived to ios/$ARCHIVE"; exit 0; }

echo "==> Uploading to App Store Connect"
# Xcode bumps the build number past whatever was uploaded last.
xcodebuild -exportArchive -archivePath "$ARCHIVE" -exportOptionsPlist ExportOptions.plist \
  -exportPath build/export -allowProvisioningUpdates -quiet
echo "Uploaded. It shows up in App Store Connect → TestFlight after Apple processes it (usually 10–30 minutes)."
