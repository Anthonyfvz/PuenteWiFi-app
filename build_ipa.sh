#!/bin/bash
# Builds a signed PuenteWiFi.ipa. Requires Xcode signed in to your Apple ID.
# Usage: ./build_ipa.sh TEAM_ID [BUNDLE_ID]
set -euo pipefail

team="${1:-}"
bundle_id="${2:-com.puentewifi.app}"
if [ -z "$team" ]; then
  echo "Uso: ./build_ipa.sh TEAM_ID [BUNDLE_ID]" >&2
  echo "El Team ID está en Xcode > Settings > Accounts, o en developer.apple.com/account." >&2
  exit 1
fi

root="$(cd "$(dirname "$0")" && pwd)"
build="$root/build"
rm -rf "$build"
mkdir -p "$build"

cat > "$build/ExportOptions.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>method</key><string>debugging</string>
  <key>signingStyle</key><string>automatic</string>
  <key>teamID</key><string>$team</string>
</dict>
</plist>
EOF

xcodebuild archive \
  -project "$root/PuenteWiFi.xcodeproj" \
  -scheme PuenteWiFi \
  -configuration Release \
  -destination 'generic/platform=iOS' \
  -archivePath "$build/PuenteWiFi.xcarchive" \
  -allowProvisioningUpdates \
  DEVELOPMENT_TEAM="$team" \
  PRODUCT_BUNDLE_IDENTIFIER="$bundle_id"

xcodebuild -exportArchive \
  -archivePath "$build/PuenteWiFi.xcarchive" \
  -exportPath "$build/ipa" \
  -exportOptionsPlist "$build/ExportOptions.plist" \
  -allowProvisioningUpdates

echo "IPA lista: $build/ipa/PuenteWiFi.ipa"
