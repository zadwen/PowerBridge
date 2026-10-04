#!/usr/bin/env bash
# Build on macOS (locally or GitHub Actions); sign later on the iPhone.
set -euo pipefail
project_root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
cd "$project_root"
command -v xcodebuild >/dev/null || { echo 'This build runs on the GitHub macOS runner, not directly on Linux.'; exit 1; }
mkdir -p build
result_path="$project_root/build/PowerBridge.xcresult"
if [[ -e "$result_path" ]]; then
  result_path="$project_root/build/PowerBridge-$(date +%Y%m%d-%H%M%S)-$$.xcresult"
fi
xcodebuild \
  -project ios/PowerBridge.xcodeproj \
  -scheme PowerBridge \
  -configuration Release \
  -sdk iphoneos \
  -destination 'generic/platform=iOS' \
  -derivedDataPath build/device \
  -resultBundlePath "$result_path" \
  CODE_SIGNING_ALLOWED=NO \
  CODE_SIGNING_REQUIRED=NO \
  CODE_SIGN_IDENTITY='' \
  CODE_SIGN_ENTITLEMENTS='' \
  build
app_path="$project_root/build/device/Build/Products/Release-iphoneos/PowerBridge.app"
[[ -d "$app_path" ]] || { echo 'Device app was not produced.'; exit 1; }
python3 - "$app_path" <<'PY'
import pathlib, plistlib, sys
app = pathlib.Path(sys.argv[1])
info = plistlib.loads((app / 'Info.plist').read_bytes())
assert 'iPhoneOS' in info.get('CFBundleSupportedPlatforms', []), 'Not an iPhone-device build'
assert info.get('CFBundleExecutable') == 'PowerBridge', 'Unexpected executable name'
assert (app / info['CFBundleExecutable']).is_file(), 'Missing executable'
assert not (app / 'embedded.mobileprovision').exists(), 'Unexpected provisioning profile in unsigned build'
print('Verified iPhoneOS application metadata.')
PY
xcrun lipo "$app_path/PowerBridge" -verify_arch arm64
staging_dir=$(mktemp -d "$project_root/build/ipa-stage.XXXXXX")
trap 'rm -rf -- "$staging_dir"' EXIT
mkdir -p "$staging_dir/Payload"
ditto "$app_path" "$staging_dir/Payload/PowerBridge.app"
ipa_path="$project_root/build/PowerBridge-unsigned.ipa"
rm -f -- "$ipa_path"
ditto -c -k --sequesterRsrc --keepParent "$staging_dir/Payload" "$ipa_path"
python3 - "$ipa_path" <<'PY'
import sys, zipfile
with zipfile.ZipFile(sys.argv[1]) as archive:
    assert archive.testzip() is None
    for name in ['Payload/PowerBridge.app/Info.plist', 'Payload/PowerBridge.app/PowerBridge']:
        assert name in archive.namelist(), f'Missing {name}'
print('IPA structure verified. Signing with a matching certificate/profile is still required.')
PY
(cd "$project_root/build" && shasum -a 256 PowerBridge-unsigned.ipa > PowerBridge-unsigned.ipa.sha256)
echo "Created $ipa_path"
