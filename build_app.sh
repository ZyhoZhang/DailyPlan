#!/bin/bash
# Build DailyPlan.app (and optionally a .dmg) from the sources in this folder.
#
#   ./build_app.sh              -> creates dist/DailyPlan.app
#   ./build_app.sh --dmg        -> also creates dist/DailyPlan.dmg
#
# The .app is a thin launcher: it starts app.py with the system Python and
# opens the browser. All real code stays in this folder, so editing app.py or
# static/index.html takes effect the next time you launch the app.

set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
DIST="$ROOT/dist"
APP="$DIST/DailyPlan.app"
MACOS="$APP/Contents/MacOS"
RES="$APP/Contents/Resources"

rm -rf "$APP"
mkdir -p "$MACOS" "$RES"

# --- payload: a self-contained copy of the app, so the bundle is transferable
cp "$ROOT/app.py" "$RES/app.py"
cp -R "$ROOT/static" "$RES/static"

# --- Info.plist
cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN"
  "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key>              <string>DailyPlan</string>
  <key>CFBundleDisplayName</key>       <string>Daily Plan</string>
  <key>CFBundleIdentifier</key>        <string>local.dailyplan.app</string>
  <key>CFBundleVersion</key>           <string>1.0</string>
  <key>CFBundleShortVersionString</key><string>1.0</string>
  <key>CFBundlePackageType</key>       <string>APPL</string>
  <key>CFBundleExecutable</key>        <string>DailyPlan</string>
  <key>CFBundleIconFile</key>          <string>AppIcon</string>
  <key>LSMinimumSystemVersion</key>    <string>11.0</string>
  <key>LSUIElement</key>               <true/>
  <key>NSHighResolutionCapable</key>   <true/>
</dict>
</plist>
PLIST

# --- launcher
cat > "$MACOS/DailyPlan" <<'LAUNCH'
#!/bin/bash
# Start the Daily Plan server (if it isn't already up) and open the browser.
set -uo pipefail

RES="$(cd "$(dirname "$0")/../Resources" && pwd)"
PORT="${DAILY_PLAN_PORT:-8777}"
URL="http://127.0.0.1:${PORT}"

# Data lives outside the bundle so upgrading / reinstalling never loses history.
DATA_HOME="${DAILY_PLAN_HOME:-$HOME/Documents/daily_plan}"
mkdir -p "$DATA_HOME"
export DAILY_PLAN_HOME="$DATA_HOME"

PY="$(command -v python3 || true)"
if [ -z "$PY" ]; then
  osascript -e 'display alert "Daily Plan" message "python3 was not found. Install the Xcode command line tools with:\n\n    xcode-select --install" as critical'
  exit 1
fi

# Already running? Just focus the tab.
if curl -fsS --max-time 2 "$URL/api/state" >/dev/null 2>&1; then
  open "$URL"
  exit 0
fi

LOG="$DATA_HOME/server.log"
nohup "$PY" "$RES/app.py" --port "$PORT" --no-browser >>"$LOG" 2>&1 &

# Wait for the port to answer before opening the browser.
for _ in $(seq 1 50); do
  if curl -fsS --max-time 1 "$URL/api/state" >/dev/null 2>&1; then
    open "$URL"
    exit 0
  fi
  sleep 0.2
done

osascript -e "display alert \"Daily Plan\" message \"The server did not start. See $LOG for details.\" as critical"
exit 1
LAUNCH
chmod +x "$MACOS/DailyPlan"

# --- icon (generated so the bundle needs no binary assets checked in)
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
  BASE="$(mktemp -d)/icon.png"
  qlmanage -t -s 1024 -o "$(dirname "$BASE")" "$SVG" >/dev/null 2>&1 || true
  GENERATED="$(dirname "$BASE")/$(basename "$SVG").png"
  if [ -f "$GENERATED" ]; then
    for size in 16 32 64 128 256 512 1024; do
      sips -z $size $size "$GENERATED" --out "$ICONSET/icon_${size}x${size}.png" >/dev/null 2>&1 || true
    done
    # Retina variants iconutil expects.
    cp "$ICONSET/icon_32x32.png"     "$ICONSET/icon_16x16@2x.png"   2>/dev/null || true
    cp "$ICONSET/icon_64x64.png"     "$ICONSET/icon_32x32@2x.png"   2>/dev/null || true
    cp "$ICONSET/icon_256x256.png"   "$ICONSET/icon_128x128@2x.png" 2>/dev/null || true
    cp "$ICONSET/icon_512x512.png"   "$ICONSET/icon_256x256@2x.png" 2>/dev/null || true
    cp "$ICONSET/icon_1024x1024.png" "$ICONSET/icon_512x512@2x.png" 2>/dev/null || true
    rm -f "$ICONSET/icon_64x64.png" "$ICONSET/icon_1024x1024.png"
    iconutil -c icns "$ICONSET" -o "$RES/AppIcon.icns" >/dev/null 2>&1 || \
      echo "note: icon generation skipped (iconutil failed)"
  fi
fi

# Ad-hoc sign so macOS treats it as a stable, consistent bundle.
codesign --force --deep --sign - "$APP" >/dev/null 2>&1 || \
  echo "note: ad-hoc codesign skipped"

echo "Built $APP"

# --- optional dmg
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
