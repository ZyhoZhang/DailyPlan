#!/bin/bash
# Browser tests use a new, temporary Chrome profile and synthetic app data.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")" && pwd)"
CHROME="${CHROME_BIN:-/Applications/Google Chrome.app/Contents/MacOS/Google Chrome}"
if [ ! -x "$CHROME" ]; then
  echo "Google Chrome was not found. Set CHROME_BIN to its executable." >&2
  exit 1
fi
PROFILE="$(mktemp -d)"
CHROME_PID=""
cleanup() {
  if [ -n "$CHROME_PID" ]; then
    kill "$CHROME_PID" 2>/dev/null || true
    wait "$CHROME_PID" 2>/dev/null || true
  fi
  rm -rf "$PROFILE"
}
trap cleanup EXIT
"$CHROME" --headless=new --no-first-run --no-default-browser-check \
  --disable-background-networking --disable-extensions \
  --remote-debugging-address=127.0.0.1 --remote-debugging-port=0 \
  --remote-allow-origins=http://localhost --user-data-dir="$PROFILE" \
  about:blank >"$PROFILE/chrome.log" 2>&1 &
CHROME_PID=$!
for _ in $(seq 1 100); do
  if [ -s "$PROFILE/DevToolsActivePort" ]; then break; fi
  if ! kill -0 "$CHROME_PID" 2>/dev/null; then
    cat "$PROFILE/chrome.log" >&2
    exit 1
  fi
  sleep 0.1
done
if [ ! -s "$PROFILE/DevToolsActivePort" ]; then
  echo "Chrome did not expose its local testing port." >&2
  exit 1
fi
PORT="$(head -n 1 "$PROFILE/DevToolsActivePort")"
DAILY_PLAN_CDP_URL="http://127.0.0.1:$PORT" PYTHONDONTWRITEBYTECODE=1 \
  python3 "$ROOT/test_ui.py"
