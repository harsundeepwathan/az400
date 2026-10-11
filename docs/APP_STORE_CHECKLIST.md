# App Store submission checklist

## Build & quality
- [ ] `xcodegen generate` → open `Kira.xcodeproj` → build for device with no warnings-as-errors failures
- [ ] `KiraCore` tests (`swift test`), `KiraTests` and `KiraUITests` green on the iOS 18 simulator
- [ ] Device tests: QR scan, receipt OCR, PDF import, Wallet automation, app lock, lock-screen capture → unlock drain
- [ ] VoiceOver walkthrough of every tab; Dynamic Type at AccessibilityXXXL; light/dark; Reduce Motion
- [ ] Offline: airplane mode, all features work (StoreKit purchases excepted)
- [ ] App icon (1024), launch screen

## App Store Connect
- [ ] Bundle ID `my.kira.app`; capabilities: Data Protection (Complete), In-App Purchase
- [ ] Subscription group "Kira" with `my.kira.plus.monthly` (RM 6.90) and `my.kira.premium.monthly` (RM 12.90); localised names/descriptions; review screenshot of the paywall
- [ ] Paywall shows price, period, auto-renew terms, Restore, Terms (EULA) and Privacy Policy links (Guideline 3.1.2)
- [ ] Privacy Policy URL (from `PRIVACY_POLICY_DRAFT.md` after legal review)
- [ ] **App Privacy "nutrition label": Data Not Collected** — valid only while sync is off. Revisit if sync ships
- [ ] `PrivacyInfo.xcprivacy` included (UserDefaults CA92.1, file timestamp C617.1). No tracking
- [ ] Export compliance: `ITSAppUsesNonExemptEncryption = NO` (only OS-provided encryption)
- [ ] Age rating; category: Finance
- [ ] Review notes: explain that Kira does **not** connect to banks, the Shortcuts automation setup, and how to test with sample statements (provide synthetic files)

## Guideline risk review
- [ ] 2.3 / 5.1.1 — no claims of bank connectivity, "bank-grade" security or automatic Apple Pay import. Marketing copy says "log taps with Shortcuts"
- [ ] 3.1.1 — all unlocks via IAP; no external purchase links
- [ ] 3.1.2 — subscriptions provide ongoing value; data export/deletion never paywalled
- [ ] 5.1.1(v) — account deletion: N/A (no accounts). In-app "Delete all data" provided
- [ ] 5.1.2 — no data sharing; on-device OCR only
- [ ] Financial apps (5.1.1(ix)): the app doesn't provide lending/banking services; seller is a registered company if required

## Malaysia specifics
- [ ] Storefront pricing tiers resolve to RM 6.90 / RM 12.90 (SST as applicable via Apple)
- [ ] Malay localisation (backlog), Malay month names already parsed in imports
- [ ] PDPA review complete (see FEASIBILITY.md › Unresolved dependencies)
