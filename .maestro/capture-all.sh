#!/usr/bin/env bash
# capture-all.sh — full marketing-screenshot run on both iPad + iPhone sims.
# Runs each flow sequentially on each device, collecting PNGs into
# screenshots/appstore/{ipad,iphone}/.

set -euo pipefail

REPO_DIR="$(cd "$(dirname "$0")/.." && pwd)"

FLOWS=(
  onboarding
  network-chat
  on-device-chat
  settings-tour
  models-tour
  dashboard-tour
)

for device in ipad-a16 iphone-17-pro-max; do
  echo "================================================================"
  echo "  $device"
  echo "================================================================"
  for flow in "${FLOWS[@]}"; do
    echo "[capture-all] $device :: $flow"
    bash "$REPO_DIR/.maestro/capture.sh" "$device" "$flow" || \
      echo "[capture-all] WARN: $flow failed on $device, continuing"
  done
done

echo
echo "Done. PNGs in:"
echo "  $REPO_DIR/screenshots/appstore/ipad/"
echo "  $REPO_DIR/screenshots/appstore/iphone/"
