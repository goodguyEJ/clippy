#!/bin/zsh
# Builds Clippy.app next to this script.
set -euo pipefail
cd "$(dirname "$0")"

APP="build/Clippy.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

swiftc -O -swift-version 5 \
  -target "$(uname -m)-apple-macos14.0" \
  -framework AppKit -framework SwiftUI -framework Carbon -framework ServiceManagement \
  Sources/*.swift -o "$APP/Contents/MacOS/Clippy"

cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>Clippy</string>
  <key>CFBundleDisplayName</key><string>Clippy</string>
  <key>CFBundleIdentifier</key><string>local.personal.clippy</string>
  <key>CFBundleExecutable</key><string>Clippy</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>2.0</string>
  <key>CFBundleVersion</key><string>2</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>LSUIElement</key><true/>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSHumanReadableCopyright</key><string>Personal use</string>
  <key>CFBundleURLTypes</key>
  <array>
    <dict>
      <key>CFBundleURLName</key><string>local.personal.clippy</string>
      <key>CFBundleURLSchemes</key><array><string>clippy</string></array>
    </dict>
  </array>
</dict>
</plist>
PLIST

# Ad-hoc sign with the hardened runtime, which blocks injecting code (DYLD_INSERT_LIBRARIES)
# into an app that holds Accessibility permission. Clippy needs no entitlements.
codesign --force --options runtime --sign - "$APP"
echo "Built $PWD/$APP"
