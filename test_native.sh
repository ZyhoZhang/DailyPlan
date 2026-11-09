#!/bin/bash
# Build and run the Swift compatibility/logic tests.
#
#   ./test_native.sh
#
# Uses a throwaway directory, so it never touches real data.

set -euo pipefail
ROOT="$(cd "$(dirname "$0")" && pwd)"
TEST_DIR="$(mktemp -d)"
trap 'rm -rf "$TEST_DIR"' EXIT
BIN="$TEST_DIR/compat"

swiftc \
  -sdk "$(xcrun --show-sdk-path)" \
  -target "$(uname -m)-apple-macos14.0" \
  -framework SwiftUI -framework AppKit -framework UserNotifications \
  -framework ServiceManagement \
  -parse-as-library \
  -o "$BIN" \
  "$ROOT/native/DailyPlan/Model.swift" \
  "$ROOT/native/DailyPlan/Store.swift" \
  "$ROOT/native/DailyPlan/Countdown.swift" \
  "$ROOT/native/DailyPlan/NoteFormat.swift" \
  "$ROOT/native/DailyPlan/NoteEditor.swift" \
  "$ROOT/native/test_compat.swift"

"$BIN" "$ROOT"
