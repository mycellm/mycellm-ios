# In-App Purchase Setup — Tip Jar

## App Store Connect

- [ ] Sign **Paid Apps Agreement** in App Store Connect > Business (requires bank + tax)
- [ ] Register app in App Store Connect (Bundle ID `com.mycellm.app`)
- [ ] Create 5 **Consumable** In-App Purchases under Monetization > In-App Purchases:

| Reference Name | Product ID | Price |
|---|---|---|
| Tip - Coffee | `com.mycellm.tip.small` | $0.99 |
| Tip - Matcha | `com.mycellm.tip.medium` | $2.99 |
| Tip - Pizza | `com.mycellm.tip.large` | $4.99 |
| Tip - Bento | `com.mycellm.tip.generous` | $9.99 |
| Tip - Party | `com.mycellm.tip.huge` | $24.99 |

- [ ] Add localized display name + description for each IAP
- [ ] Add a review screenshot for each IAP (screenshot of tip jar section)
- [ ] Submit IAPs with an app binary for review

## Xcode — Local Testing

- [ ] Create StoreKit Configuration File: File > New > StoreKit Configuration File (`Mycellm.storekit`)
- [ ] Add all 5 products with matching product IDs and prices
- [ ] Set scheme to use config: Edit Scheme > Run > Options > StoreKit Configuration > `Mycellm.storekit`
- [ ] Test purchases in Simulator or on device (no App Store Connect needed for local testing)

## Code (Already Done)

- `Mycellm/Core/TipJarManager.swift` — StoreKit 2 product loading, purchase, verification
- `Mycellm/Views/Settings/SettingsView.swift` — Tip jar UI section with 5 tiers
- Product IDs defined in `TipJarManager.productIds`

## Secrets

**None.** StoreKit 2 is zero-secret — all verification is on-device via App Store signed receipts. Product IDs are public identifiers. The entire codebase is safe for a public repo.

If server-side receipt validation is ever needed (subscriptions, entitlements):
- App Store Server API key (`.p8`) would be a secret — store as env var on server
- `.p8` files are covered by `*.key` in `.gitignore`
- Not needed for consumable tips
