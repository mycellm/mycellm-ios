#!/usr/bin/env bash
# capture-screenshots.sh — App Store marketing capture, maestro-free.
#
# Drives the simulator purely via launch arguments + `simctl io screenshot`.
# No UI tapping (so no flakiness): the app's DEBUG ScreenshotMode seeds mock
# data, and the persisted-tab change lets us select each tab with the
# `-lastSelectedTab N` launch argument. One launch per scene, screenshot,
# terminate.
#
# Pre-reqs (run on the Mac / hokulea):
#   - Mycellm.app built for the iOS Simulator (Debug) — see build step below.
#   - iOS 26.5 simulators present (UDIDs below).
#
# Usage:
#   ./capture-screenshots.sh iphone   /path/to/Mycellm.app
#   ./capture-screenshots.sh ipad13   /path/to/Mycellm.app
#
# Output: screenshots/appstore/<device>/NN-<scene>.png
set -euo pipefail

DEVICE="${1:?usage: capture-screenshots.sh <iphone|ipad13> <app-path>}"
APP_PATH="${2:?path to built Mycellm.app}"
BUNDLE_ID="com.mycellm.app"

case "$DEVICE" in
  iphone)  UDID="D42703DF-BA68-4001-A05E-791F01C5B1FC"; OUT="iphone" ;;   # iPhone 17 Pro Max 26.5 → 1290x2796
  ipad13)  UDID="C062D3ED-20CF-4BBD-B055-6F4FBE8D2FF3"; OUT="ipad" ;;     # iPad Pro 13" (M5) 26.5 → 2064x2752
  *)       echo "unknown device '$DEVICE' (use iphone|ipad13)"; exit 1 ;;
esac

REPO_DIR="$(cd "$(dirname "$0")/.." && pwd)"
OUT_DIR="$REPO_DIR/screenshots/appstore/$OUT"
mkdir -p "$OUT_DIR"

# tab index → scene name (matches MainTabView tags: 0 Dashboard … 4 Settings)
SCENES=( "0:01-dashboard" "1:02-chat" "2:03-models" "3:04-network" "4:05-settings" )

echo "[capture] booting $UDID"
xcrun simctl boot "$UDID" 2>/dev/null || true
xcrun simctl bootstatus "$UDID" -b
xcrun simctl install "$UDID" "$APP_PATH"

for entry in "${SCENES[@]}"; do
  tab="${entry%%:*}"; name="${entry##*:}"
  echo "[capture] $DEVICE :: tab $tab → $name"
  xcrun simctl terminate "$UDID" "$BUNDLE_ID" 2>/dev/null || true
  xcrun simctl launch "$UDID" "$BUNDLE_ID" -screenshotMode YES -lastSelectedTab "$tab" >/dev/null
  # first launch seeds SwiftData + warms fonts; give it room, then settle
  sleep 7
  xcrun simctl io "$UDID" screenshot "$OUT_DIR/$name.png"
done

echo "[capture] done → $OUT_DIR"
ls -1 "$OUT_DIR"
