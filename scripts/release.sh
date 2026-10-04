#!/bin/bash
# Builds a distributable Voilà DMG: universal, Developer ID-signed app + "drag to Applications" layout.
#   NOTARY_PROFILE=<name>  also notarize and staple (profile created with `xcrun notarytool store-credentials`)
set -euo pipefail
cd "$(dirname "$0")/.."

VERSION=$(/usr/libexec/PlistBuddy -c "Print CFBundleShortVersionString" Resources/Info.plist)
BUILD=$(/usr/libexec/PlistBuddy -c "Print CFBundleVersion" Resources/Info.plist)
DMG="dist/Voila-$VERSION.dmg"
STAGE="build/dmg"

./scripts/build.sh --release

echo "▸ Staging DMG contents"
rm -rf "$STAGE" "$DMG"
mkdir -p "$STAGE" dist
cp -R "build/Voilà.app" "$STAGE/"
ln -s /Applications "$STAGE/Applications"
cp build/AppIcon.icns "$STAGE/.VolumeIcon.icns"
SetFile -a C "$STAGE" 2>/dev/null || true      # use the custom volume icon

echo "▸ Creating $DMG"
hdiutil create -quiet -volname "Voilà $VERSION" -srcfolder "$STAGE" -fs HFS+ -format UDZO -ov "$DMG"

IDENTITY="${SIGN_IDENTITY:-$(security find-identity -v -p codesigning | awk -F'"' '/Developer ID Application/ {print $2; exit}')}"
codesign --force --timestamp --sign "$IDENTITY" "$DMG"

if [ -n "${NOTARY_PROFILE:-}" ]; then
  echo "▸ Notarizing (this can take a few minutes)…"
  xcrun notarytool submit "$DMG" --keychain-profile "$NOTARY_PROFILE" --wait
  xcrun stapler staple "$DMG"
fi

rm -rf "$STAGE"
echo "✓ $DMG (version $VERSION, build $BUILD)"
