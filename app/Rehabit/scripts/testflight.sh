#!/bin/bash
# Archive Rehabit and upload the build to TestFlight.
#
# Needs, once: Xcode signed in to the developer account (Settings > Accounts),
# an app record in App Store Connect for the bundle identifier, and
# app/Rehabit/Config/Local.xcconfig with DEVELOPMENT_TEAM and
# PRODUCT_BUNDLE_IDENTIFIER. Pass --archive-only to stop before the upload.
set -euo pipefail
cd "$(dirname "$0")/.."

export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
if [ ! -f Config/Local.xcconfig ]; then
  echo "Config/Local.xcconfig is missing. Copy Config/Local.example.xcconfig and fill it in." >&2
  exit 1
fi

# Every upload needs a build number higher than the last; the time gives one.
BUILD="$(date -u +%Y%m%d%H%M)"
OUT="build/testflight-$BUILD"
mkdir -p "$OUT"

xcodegen
xcodebuild -project Rehabit.xcodeproj -scheme Rehabit -configuration Release \
  -destination 'generic/platform=iOS' -archivePath "$OUT/Rehabit.xcarchive" \
  -allowProvisioningUpdates CURRENT_PROJECT_VERSION="$BUILD" archive

if [ "${1:-}" = "--archive-only" ]; then
  echo "Archived to $OUT/Rehabit.xcarchive (not uploaded)."
  exit 0
fi

cat > "$OUT/ExportOptions.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>method</key><string>app-store-connect</string>
  <key>destination</key><string>upload</string>
  <key>signingStyle</key><string>automatic</string>
</dict></plist>
PLIST

xcodebuild -exportArchive -archivePath "$OUT/Rehabit.xcarchive" -exportPath "$OUT/export" \
  -exportOptionsPlist "$OUT/ExportOptions.plist" -allowProvisioningUpdates
echo "Uploaded build $BUILD. It appears in TestFlight after Apple finishes processing, usually within 15 minutes."
