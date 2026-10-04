#!/bin/bash
# Builds a distributable Voilà DMG: universal, Developer ID-signed app + "drag to Applications" layout.
# Notarization (optional; staples both the app and the DMG):
#   NOTARY_PROFILE=<name>                       local: profile from `xcrun notarytool store-credentials`
#   NOTARY_KEY_PATH, NOTARY_KEY_ID, NOTARY_ISSUER_ID   CI: App Store Connect API key (.p8)
set -euo pipefail
cd "$(dirname "$0")/.."

VERSION=$(/usr/libexec/PlistBuddy -c "Print CFBundleShortVersionString" Resources/Info.plist)
BUILD=$(/usr/libexec/PlistBuddy -c "Print CFBundleVersion" Resources/Info.plist)
DMG="dist/Voila-$VERSION.dmg"
STAGE="build/dmg"

./scripts/build.sh --release

NOTARY_AUTH=()
if [ -n "${NOTARY_PROFILE:-}" ]; then
  NOTARY_AUTH=(--keychain-profile "$NOTARY_PROFILE")
elif [ -n "${NOTARY_KEY_PATH:-}" ] && [ -n "${NOTARY_KEY_ID:-}" ] && [ -n "${NOTARY_ISSUER_ID:-}" ]; then
  NOTARY_AUTH=(--key "$NOTARY_KEY_PATH" --key-id "$NOTARY_KEY_ID" --issuer "$NOTARY_ISSUER_ID")
fi

notarize() {   # notarize <file>: submit to Apple and wait; fails the script if Apple rejects it
  echo "▸ Notarizing $(basename "$1") (usually 1–5 minutes)…"
  xcrun notarytool submit "$1" "${NOTARY_AUTH[@]}" --wait --timeout 30m | tee build/notary.log
  if ! grep -q "status: Accepted" build/notary.log; then
    id=$(awk '/^  id:/ {print $2; exit}' build/notary.log)
    [ -n "$id" ] && xcrun notarytool log "$id" "${NOTARY_AUTH[@]}" || true
    echo "✗ Notarization failed" >&2
    exit 1
  fi
}

if [ ${#NOTARY_AUTH[@]} -gt 0 ]; then
  # Staple the app itself so it opens without a network check even after leaving the DMG.
  ditto -c -k --keepParent "build/Voilà.app" build/Voila-notarize.zip
  notarize build/Voila-notarize.zip
  xcrun stapler staple "build/Voilà.app"
  rm -f build/Voila-notarize.zip
fi

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

if [ ${#NOTARY_AUTH[@]} -gt 0 ]; then
  notarize "$DMG"
  xcrun stapler staple "$DMG"
  spctl --assess --type open --context context:primary-signature -v "$DMG"
fi

rm -rf "$STAGE"
echo "✓ $DMG (version $VERSION, build $BUILD)"
