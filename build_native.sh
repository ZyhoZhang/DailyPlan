#!/bin/bash
# Build the native SwiftUI DailyPlan.app (and optionally a .dmg).
#
#   ./build_native.sh           -> dist-native/DailyPlan.app
#   ./build_native.sh --dmg     -> also dist-native/DailyPlan.dmg
#
# Compiles straight with swiftc — no .xcodeproj, so the sources stay as easy
# to edit as any other text file in this folder.

set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
SRC="$ROOT/native/DailyPlan"
DIST="$ROOT/dist-native"
APP="$DIST/DailyPlan.app"
MACOS="$APP/Contents/MacOS"
RES="$APP/Contents/Resources"

rm -rf "$APP"
mkdir -p "$MACOS" "$RES"

# --- Info.plist -------------------------------------------------------------
cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN"
  "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key>              <string>DailyPlan</string>
  <key>CFBundleDisplayName</key>       <string>Daily Plan</string>
  <key>CFBundleIdentifier</key>        <string>local.dailyplan.native</string>
  <key>CFBundleVersion</key>           <string>2.0</string>
  <key>CFBundleShortVersionString</key><string>2.0</string>
  <key>CFBundlePackageType</key>       <string>APPL</string>
  <key>CFBundleExecutable</key>        <string>DailyPlan</string>
  <key>CFBundleIconFile</key>          <string>AppIcon</string>
  <key>LSMinimumSystemVersion</key>    <string>14.0</string>
  <key>NSHighResolutionCapable</key>   <true/>
  <key>NSSupportsAutomaticTermination</key> <false/>
  <key>NSSupportsSuddenTermination</key>    <false/>
</dict>
</plist>
PLIST

# --- compile ----------------------------------------------------------------
echo "Compiling…"
SDK="$(xcrun --show-sdk-path)"
swiftc \
  -O \
  -sdk "$SDK" \
  -target arm64-apple-macos14.0 \
  -framework SwiftUI -framework AppKit -framework UserNotifications \
  -framework ServiceManagement \
  -parse-as-library \
  -o "$MACOS/DailyPlan" \
  "$SRC"/*.swift

# --- icon -------------------------------------------------------------------
ICONSET="$(mktemp -d)/AppIcon.iconset"
mkdir -p "$ICONSET"
SVG="$(mktemp).svg"
cat > "$SVG" <<'SVGEOF'
<svg xmlns="http://www.w3.org/2000/svg" width="1024" height="1024">
  <defs>
    <linearGradient id="g" x1="0" y1="0" x2="1" y2="1">
      <stop offset="0%" stop-color="#1f3a93"/>
      <stop offset="55%" stop-color="#2d55c9"/>
      <stop offset="100%" stop-color="#4570e0"/>
    </linearGradient>
  </defs>
  <rect width="1024" height="1024" rx="225" fill="url(#g)"/>
  <path d="M300 530 L455 685 L735 350" stroke="#ffffff" stroke-width="88"
        fill="none" stroke-linecap="round" stroke-linejoin="round"/>
</svg>
SVGEOF

if command -v qlmanage >/dev/null 2>&1 && command -v sips >/dev/null 2>&1; then
  TMPDIR_ICON="$(mktemp -d)"
  qlmanage -t -s 1024 -o "$TMPDIR_ICON" "$SVG" >/dev/null 2>&1 || true
  GENERATED="$TMPDIR_ICON/$(basename "$SVG").png"
  if [ -f "$GENERATED" ]; then
    for size in 16 32 128 256 512; do
      sips -z $size $size "$GENERATED" --out "$ICONSET/icon_${size}x${size}.png" >/dev/null 2>&1 || true
      double=$((size * 2))
      sips -z $double $double "$GENERATED" --out "$ICONSET/icon_${size}x${size}@2x.png" >/dev/null 2>&1 || true
    done
    iconutil -c icns "$ICONSET" -o "$RES/AppIcon.icns" >/dev/null 2>&1 || \
      echo "note: icon generation skipped"
  fi
fi

# --- sign -------------------------------------------------------------------
# Notifications and SMAppService both want a stable signed identity.
codesign --force --deep --sign - \
  --entitlements <(cat <<'ENT'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN"
  "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>com.apple.security.app-sandbox</key> <false/>
</dict>
</plist>
ENT
) "$APP" >/dev/null 2>&1 || codesign --force --deep --sign - "$APP" >/dev/null 2>&1 || \
  echo "note: codesign skipped"

echo "Built $APP"

# --- optional dmg -----------------------------------------------------------
if [ "${1:-}" = "--dmg" ]; then
  STAGE="$(mktemp -d)/DailyPlan"
  mkdir -p "$STAGE"
  cp -R "$APP" "$STAGE/"
  ln -s /Applications "$STAGE/Applications"
  rm -f "$DIST/DailyPlan.dmg"
  hdiutil create -volname "Daily Plan" -srcfolder "$STAGE" -ov -quiet \
    -format UDZO "$DIST/DailyPlan.dmg"
  echo "Built $DIST/DailyPlan.dmg"
fi
