#!/bin/bash
# Builds Voilà.app into ./build.
#   --install  copy it to ~/Applications and launch it
#   --release  universal binary (Apple Silicon + Intel) signed with a secure timestamp (for distribution)
set -euo pipefail
cd "$(dirname "$0")/.."

INSTALL=0; RELEASE=0
for arg in "$@"; do
  case "$arg" in
    --install) INSTALL=1 ;;
    --release) RELEASE=1 ;;
    *) echo "Unknown option: $arg" >&2; exit 1 ;;
  esac
done

if [ $RELEASE = 1 ]; then ARCHS=(--arch arm64 --arch x86_64); else ARCHS=(--arch arm64); fi

APP="build/Voilà.app"
echo "▸ Compiling (release, ${ARCHS[*]})…"
swift build -c release "${ARCHS[@]}"

echo "▸ Assembling $APP"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
BIN="$(swift build -c release "${ARCHS[@]}" --show-bin-path)"
cp "$BIN/Voila" "$APP/Contents/MacOS/Voila"
# Sparkle (auto-updates) is loaded from Contents/Frameworks (rpath @executable_path/../Frameworks).
mkdir -p "$APP/Contents/Frameworks"
ditto "$BIN/Sparkle.framework" "$APP/Contents/Frameworks/Sparkle.framework"
cp Resources/Info.plist "$APP/Contents/Info.plist"

if [ ! -f build/AppIcon.icns ] && [ -f assets/logo/Voila.icns ]; then
  mkdir -p build && cp assets/logo/Voila.icns build/AppIcon.icns
fi
if [ ! -f build/AppIcon.icns ]; then
  echo "▸ Rendering icon"
  ICONSET=build/AppIcon.iconset
  mkdir -p "$ICONSET"
  swift scripts/make_icon.swift build/icon_1024.png
  for s in 16 32 128 256 512; do
    sips -z $s $s build/icon_1024.png --out "$ICONSET/icon_${s}x${s}.png" >/dev/null
    sips -z $((s*2)) $((s*2)) build/icon_1024.png --out "$ICONSET/icon_${s}x${s}@2x.png" >/dev/null
  done
  iconutil -c icns "$ICONSET" -o build/AppIcon.icns
fi
cp build/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"

# Embed the Google OAuth client so users only click "Connect". The JSON stays out of git.
OAUTH_JSON="${GOOGLE_OAUTH_JSON:-GoogleOAuthClient.json}"
if [ -f "$OAUTH_JSON" ]; then
  python3 - "$OAUTH_JSON" <<'PY'
import json, sys
d = json.load(open(sys.argv[1]))
c = d.get("installed", d)
assert c.get("client_id") and c.get("client_secret"), "client_id/client_secret missing"
assert "web" not in d, "This is a Web client; create a 'Desktop app' OAuth client instead"
PY
  cp "$OAUTH_JSON" "$APP/Contents/Resources/GoogleOAuthClient.json"
  echo "▸ Embedded Google OAuth client from $OAUTH_JSON"
else
  echo "▸ No $OAUTH_JSON found. Users will be asked for a Client ID and secret"
fi

# Prefer a real signing identity (keeps Keychain access stable across rebuilds); fall back to ad-hoc.
IDENTITY="${SIGN_IDENTITY:-$(security find-identity -v -p codesigning | awk -F'"' '/Developer ID Application|Apple Development/ {print $2; exit}')}"
echo "▸ Signing with: ${IDENTITY:-ad-hoc}"
if [ $RELEASE = 1 ]; then
  [[ "$IDENTITY" == Developer\ ID\ Application* ]] || { echo "A Developer ID Application identity is required for --release" >&2; exit 1; }
  TIMESTAMP=(--timestamp)          # secure timestamp: required for notarization
else
  TIMESTAMP=(--timestamp=none)     # fast local builds
fi
# Sign inside-out: Sparkle's helpers, the framework, then the app.
SIGN=(codesign --force --options runtime "${TIMESTAMP[@]}" --sign "${IDENTITY:--}")
FW="$APP/Contents/Frameworks/Sparkle.framework"
"${SIGN[@]}" "$FW/Versions/B/XPCServices/Installer.xpc"
"${SIGN[@]}" --preserve-metadata=entitlements "$FW/Versions/B/XPCServices/Downloader.xpc"
"${SIGN[@]}" "$FW/Versions/B/Autoupdate"
"${SIGN[@]}" "$FW/Versions/B/Updater.app"
"${SIGN[@]}" "$FW"
"${SIGN[@]}" "$APP"

if [ $INSTALL = 1 ]; then
  mkdir -p ~/Applications
  pkill -x Voila 2>/dev/null || true
  rm -rf ~/Applications/Voila.app ~/Applications/Voilà.app
  cp -R "$APP" ~/Applications/
  echo "▸ Installed to ~/Applications/Voilà.app"
  open ~/Applications/Voilà.app
fi
echo "✓ Done"
