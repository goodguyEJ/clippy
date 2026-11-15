#!/bin/zsh
# Builds ClipStack.app (universal: Apple Silicon + Intel) next to this script.
#   ./build.sh            build/ClipStack.app
#   ./build.sh --release  also build/ClipStack-<version>.zip and its .sha256
# Set CLIPSTACK_SIGN_IDENTITY to a code-signing certificate's name (see scripts/make-signing-cert.sh)
# so every build has the same signature and macOS keeps ClipStack's Accessibility permission across updates.
set -euo pipefail
cd "$(dirname "$0")"

NAME="ClipStack"
BUNDLE_ID="io.github.goodguyej.clipstack"
VERSION="$(tr -d '[:space:]' < VERSION)"
# The commit count gives every release a higher build number, which ClipStack uses to re-explain
# Accessibility after an update. Shallow clones and source zips fall back to 1.
BUILD_NUMBER="$(git rev-list --count HEAD 2>/dev/null || echo 1)"
APP="build/$NAME.app"

rm -rf "$APP" build/obj
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

for arch in arm64 x86_64; do
  mkdir -p "build/obj/$arch"
  swiftc -O -swift-version 5 -target "$arch-apple-macos14.0" \
    -framework AppKit -framework SwiftUI -framework Carbon -framework ServiceManagement \
    Sources/*.swift -o "build/obj/$arch/$NAME"
done
lipo -create build/obj/arm64/$NAME build/obj/x86_64/$NAME -output "$APP/Contents/MacOS/$NAME"

ICON_KEY=""
if [ -f Resources/AppIcon.icns ]; then
  cp Resources/AppIcon.icns "$APP/Contents/Resources/"
  ICON_KEY="<key>CFBundleIconFile</key><string>AppIcon</string>"
fi

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>$NAME</string>
  <key>CFBundleDisplayName</key><string>$NAME</string>
  <key>CFBundleIdentifier</key><string>$BUNDLE_ID</string>
  <key>CFBundleExecutable</key><string>$NAME</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>$VERSION</string>
  <key>CFBundleVersion</key><string>$BUILD_NUMBER</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>LSApplicationCategoryType</key><string>public.app-category.utilities</string>
  <key>LSUIElement</key><true/>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSHumanReadableCopyright</key><string>© 2026 EJ Bringuela. MIT License.</string>
  $ICON_KEY
  <key>CFBundleURLTypes</key>
  <array>
    <dict>
      <key>CFBundleURLName</key><string>$BUNDLE_ID</string>
      <key>CFBundleURLSchemes</key><array><string>clipstack</string></array>
    </dict>
  </array>
</dict>
</plist>
PLIST

# Hardened runtime blocks injecting code (DYLD_INSERT_LIBRARIES) into an app that holds Accessibility
# permission. ClipStack needs no entitlements, and no Apple timestamp server applies to these identities.
# A named certificate that codesign can't use (missing, untrusted, locked) falls back to ad-hoc
# rather than failing the build.
signed=""
if [ -n "${CLIPSTACK_SIGN_IDENTITY:-}" ]; then
  if codesign --force --options runtime --timestamp=none --sign "$CLIPSTACK_SIGN_IDENTITY" "$APP"; then
    signed="yes"
    echo "Signed with \"$CLIPSTACK_SIGN_IDENTITY\""
  else
    echo "Couldn't sign with \"$CLIPSTACK_SIGN_IDENTITY\" (run scripts/make-signing-cert.sh to create or re-trust it)."
  fi
fi
if [ -z "$signed" ]; then
  echo "Signing ad-hoc (set CLIPSTACK_SIGN_IDENTITY to keep permissions across updates)"
  codesign --force --options runtime --timestamp=none --sign - "$APP"
fi
echo "Built $PWD/$APP ($VERSION, build $BUILD_NUMBER)"

if [ "${1:-}" = "--release" ]; then
  ZIP="$NAME-$VERSION.zip"
  (cd build && rm -f "$ZIP" "$ZIP.sha256" && ditto -c -k --keepParent "$NAME.app" "$ZIP" && shasum -a 256 "$ZIP" > "$ZIP.sha256")
  echo "Release: build/$ZIP"
  cat "build/$ZIP.sha256"
fi
