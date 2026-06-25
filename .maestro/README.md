# mycellm — Maestro flows

iOS UI automation for App Store screenshot capture + smoke testing the chat
flows. Mirrors the WunderGuide `.maestro/` pattern adapted for a native
Swift app (no Metro / React Native involvement).

> **For App Store marketing capture, prefer the maestro-free path:**
> `screenshots/capture-screenshots.sh`. It drives the simulator purely via
> launch arguments (`-screenshotMode YES -lastSelectedTab N`) + `simctl io
> screenshot` — no Maestro install, no UI-tap flakiness. The app's DEBUG
> `ScreenshotMode` seeds mock data so every scene looks alive. The Maestro
> flows below remain for smoke-testing real interaction flows.

## Files

- `flows/onboarding.yaml` — first-launch: dismiss LAN permission prompt + AI disclaimer
- `flows/network-chat.yaml` — Network mode chat with the public bootstrap
- `flows/on-device-chat.yaml` — On-Device chat (model must be loaded first)
- `flows/settings-tour.yaml` — Settings → Chat (reasoning toggle) → Privacy Guard → Tip Jar
- `flows/models-tour.yaml` — Models tab + suggested-models picker
- `flows/dashboard-tour.yaml` — Dashboard with network + node stats
- `flows/appstore-screenshots.yaml` — orchestrates all of the above, takes screenshots at each scene
- `capture.sh` — single-device capture run
- `capture-all.sh` — iPad + iPhone consecutive runs

## Pre-reqs

- Maestro 0.15.4+ installed on the Mac driving the simulator
- iPad (A16) iOS 26.5 simulator (UDID `D5D37793-2BA1-4CE0-B808-CDA399D20C21`)
- iPhone 17 Pro Max iOS 26.5 simulator (UDID `D42703DF-BA68-4001-A05E-791F01C5B1FC`)
- Mycellm.app installed on the target simulator (build via Xcode or `xcodebuild`)
- Bundle ID: `com.mycellm.app`

## How it works

Maestro drives the UI by tapping visible text labels — no testIDs needed
because the SwiftUI UI's accessibility labels are stable. Screenshots are
written via Maestro's `takeScreenshot` command into the local PNG paths
listed at the top of each flow.

## Adding a new flow

1. Drop a `flows/foo.yaml` (see existing for the `appId: com.mycellm.app`
   prelude pattern + `takeScreenshot` usage).
2. Add to `capture-all.sh` if you want it included in the marketing run.
3. Run locally: `maestro test .maestro/flows/foo.yaml`.

## Marketing screenshots end up in

- `screenshots/appstore/ipad/` — iPad A16 PNGs
- `screenshots/appstore/iphone/` — iPhone 17 Pro Max PNGs

These are the files you upload to App Store Connect after a capture run.
