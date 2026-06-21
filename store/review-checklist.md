# mycellm iOS — v1.0.0 App Store submission & review checklist

Status legend: ✅ done · ⚠️ action needed · ⬜ to verify on the Mac/App Store Connect

## Build & signing
- ✅ `MARKETING_VERSION` 1.0.0, `CURRENT_PROJECT_VERSION` 1 (project.yml)
- ✅ Bundle ID `com.mycellm.app`, Team `DCMLXQ5H7M`
- ✅ `ITSAppUsesNonExemptEncryption = false` (Info.plist) — no export-compliance docs needed
- ⚠️ **Increased Memory Limit entitlement** (`com.apple.developer.kernel.increased-memory-limit`) is declared. The App ID's provisioning profile MUST include this capability or the App Store build is invalid / >3 GB model loads crash. Verify in Developer Portal → Identifiers → com.mycellm.app → Additional Capabilities, then regenerate the distribution profile.
- ⬜ Archive a **Release** build (`xcodebuild -scheme Mycellm -configuration Release archive`) and validate in Organizer before upload. (Screenshot mode is `#if DEBUG`, absent from Release — correct.)

## Privacy (App Privacy "nutrition label")
- ⚠️ **Privacy Policy URL is required** and must resolve. Code points at `https://mycellm.ai/privacy` and `https://mycellm.ai/terms` (NetworkConfig.swift) — confirm the pages are live and that `mycellm.ai` (not `mycellm.dev`) is canonical, or update NetworkConfig + listing to match.
- ⬜ Nutrition label: recommend **Data Not Collected** — the app has no analytics/crash SDKs and stores identity/keys on-device. BUT in **Network mode** prompts are relayed to peers / the public prime (`api.mycellm.dev`, which you operate). Decide & declare honestly:
  - If the prime does NOT persist prompt content → "Data Not Collected" is defensible; the privacy policy must still describe the P2P data flow.
  - If it logs prompts/metadata → declare under "User Content / Diagnostics" accordingly.
- ✅ `NSLocalNetworkUsageDescription` + `NSBonjourServices` present and accurate.
- ✅ PhotosPicker is used for vision input (system picker → no `NSPhotoLibraryUsageDescription` needed on iOS 17+).

## Common-rejection risk review
- ✅ AI disclaimer shown in chat ("AI responses may be inaccurate…"). Good for 1.2/4.x safety.
- ⚠️ **Guideline 1.2 (UGC) — open chat + uncensored models.** Apps with user-generated/AI content need: a content filter or on-device guard, a way to report/flag, and a EULA. You have Privacy Guard (outbound scanning) but reviewers may ask about objectionable *output*. Mitigations to have ready: note in App Review notes that models are user-selected and run locally; consider a one-line content disclaimer in onboarding. Low-but-real risk.
- ✅ No login wall (Guideline 5.1.1 friendly — no account required).
- ✅ No private APIs; QUIC/Bonjour usage documented in entitlements comments.
- ⬜ Background behavior: app keeps screen awake (`isIdleTimerDisabled`) only while the node runs and user opted in — confirm this is acceptable and documented; no background-execution entitlements requested.

## App Store Connect record
- ⬜ Create the app record (only GentlePrep's App ID is on file today — see credit-system memory). Reserve name "mycellm".
- ⬜ Listing copy → `store/listing-v1.0.0.md` (ready). Load via Storeboard, then push to ASC.
- ⬜ Screenshots: iPhone 6.9" (1290×2796) + iPad 13" (2064×2752), 3–10 each. Capture via `screenshots/capture-screenshots.sh`, frame in Storeboard. (iPad **13"** required — capture on "iPad Pro 13-inch (M5)", not the 11"/A16 sim.)
- ⬜ App preview video: optional for v1.0.0.

## IAP (deferred to v1.0.1 per decision)
- ✅ Tip Jar (StoreKit 2) fully coded but `tipJarSection` hidden (SettingsView.swift:29). No IAP review surface in v1.0.0.
- ⬜ For v1.0.1: sign Paid Apps Agreement, create 5 consumables (`com.mycellm.tip.*`), add a `.storekit` config for sim testing, un-hide the section, submit IAP with the binary.

## Final pre-submit
- ⬜ Run the unit test suite on the Mac (`xcodebuild test -scheme Mycellm`) — ~94 tests.
- ⬜ Smoke-test a Release build on a physical device (model load on 8 GB device exercises the memory entitlement).
- ⬜ App Review notes: explain P2P/on-device architecture, that no account is needed, and that models are user-supplied & run locally. Provide a demo model or note that Network mode works without downloads.
