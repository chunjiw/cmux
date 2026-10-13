#!/usr/bin/env bash
# Builds and signs the two App Attest probe bundles (cx-ds09i slice 0). Not a
# product and not a release channel: the output is a CI artifact only.
#
#   build.sh <out-dir> <signing-identity> <profile-path>
#
# variant-a/attestprobe.app  Developer ID + embedded profile + application-identifier
# variant-b/attestprobe.app  Developer ID only: no profile, no restricted entitlements
#                            (how cmux NEXT is signed today)
set -euo pipefail

out="$1"
identity="$2"
profile="$3"
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
team=7WLXT3NR37
bundle_id=com.cmuxterm.attestprobe

rm -rf "$out"
mkdir -p "$out/bin"
swiftc -O -swift-version 5 -target arm64-apple-macos14.0 -o "$out/bin/attestprobe" "$here/main.swift"

make_bundle() {
  local app="$1"
  mkdir -p "$app/Contents/MacOS"
  cp "$out/bin/attestprobe" "$app/Contents/MacOS/attestprobe"
  cat >"$app/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleIdentifier</key><string>$bundle_id</string>
  <key>CFBundleName</key><string>attestprobe</string>
  <key>CFBundleExecutable</key><string>attestprobe</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>1.0</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>LSUIElement</key><true/>
</dict>
</plist>
PLIST
}

a="$out/variant-a/attestprobe.app"
make_bundle "$a"
cp "$profile" "$a/Contents/embedded.provisionprofile"
cat >"$out/variant-a.entitlements" <<ENT
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>com.apple.application-identifier</key><string>$team.$bundle_id</string>
  <key>com.apple.developer.team-identifier</key><string>$team</string>
</dict>
</plist>
ENT
codesign --force --options runtime --timestamp --sign "$identity" --entitlements "$out/variant-a.entitlements" "$a"

b="$out/variant-b/attestprobe.app"
make_bundle "$b"
codesign --force --options runtime --timestamp --sign "$identity" "$b"

for app in "$a" "$b"; do
  codesign --verify --strict --verbose=2 "$app"
  codesign -d --entitlements - "$app" 2>/dev/null || true
done
rm -rf "$out/bin"
