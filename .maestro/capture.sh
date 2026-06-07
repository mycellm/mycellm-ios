#!/usr/bin/env bash
# capture.sh — single-device Maestro capture run.
#
# Args:
#   $1 — sim UDID (or "ipad-a16" / "iphone-17-pro-max" shortcut)
#   $2 — optional flow name (default: appstore-screenshots, runs all flows)
#
# Output: PNGs land in ~/.maestro/tests/<runid>/screenshots/ on the sim
# host, then this script rsyncs them to screenshots/appstore/<device>/.

set -euo pipefail

SIM_INPUT="${1:-}"
FLOW="${2:-appstore-screenshots}"

case "$SIM_INPUT" in
  ipad-a16)         SIM_UDID="D5D37793-2BA1-4CE0-B808-CDA399D20C21"; DEVICE_DIR="ipad" ;;
  iphone-17-pro-max) SIM_UDID="D42703DF-BA68-4001-A05E-791F01C5B1FC"; DEVICE_DIR="iphone" ;;
  *)                SIM_UDID="$SIM_INPUT"; DEVICE_DIR="custom" ;;
esac

if [ -z "$SIM_UDID" ]; then
  echo "Usage: capture.sh <ipad-a16|iphone-17-pro-max|UDID> [flow-name]" >&2
  exit 1
fi

REPO_DIR="$(cd "$(dirname "$0")/.." && pwd)"
FLOW_PATH="$REPO_DIR/.maestro/flows/$FLOW.yaml"
OUT_DIR="$REPO_DIR/screenshots/appstore/$DEVICE_DIR"
mkdir -p "$OUT_DIR"

# Maestro takeScreenshot writes to ./out/*.png by default (relative to cwd).
# We cd into a temp dir so we can collect everything afterwards.
RUN_DIR="$(mktemp -d -t mycellm-maestro-XXXX)"
cd "$RUN_DIR"

echo "[capture] Running $FLOW on $SIM_UDID → $OUT_DIR"
xcrun simctl boot "$SIM_UDID" 2>/dev/null || true
maestro --device "$SIM_UDID" test "$FLOW_PATH"

# Move PNGs into screenshots/appstore/<device>/
if [ -d "$RUN_DIR/out" ]; then
  cp -av "$RUN_DIR/out/"*.png "$OUT_DIR/" 2>/dev/null || true
  echo "[capture] $(ls "$OUT_DIR" | wc -l | tr -d ' ') screenshots in $OUT_DIR"
fi
