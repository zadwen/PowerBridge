#!/usr/bin/env bash
set -euo pipefail
cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../ios"
command -v xcodebuild >/dev/null || { echo 'Run this script on macOS with Xcode installed and selected.'; exit 1; }
# The ready-made project is included. project.yml is provided for XcodeGen users.
if [[ ${1:-} == '--simulator' ]]; then
    xcodebuild -project PowerBridge.xcodeproj -scheme PowerBridge -sdk iphonesimulator -configuration Debug CODE_SIGNING_ALLOWED=NO build
else
    : "${TEAM_ID:?Set TEAM_ID to your Apple development team ID}"
    xcodebuild -project PowerBridge.xcodeproj -scheme PowerBridge -destination 'generic/platform=iOS' -configuration Release DEVELOPMENT_TEAM="$TEAM_ID" -allowProvisioningUpdates -archivePath ../build/PowerBridge.xcarchive archive
    echo 'Archive created. Open build/PowerBridge.xcarchive in Xcode and choose Distribute App to export a signed IPA for your registered iPhone.'
fi
