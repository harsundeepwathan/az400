# Integration feasibility & feature availability

_Last reviewed: 11 Oct 2026. Re-verify every row before launch: Apple and Malaysian payment providers change fast._

Legend: ✅ confirmed & implemented · 🧪 implemented, **needs real-device validation** · 🤝 needs provider partnership / Apple entitlement · ⛔ not supported / not possible

## Environment

| Item | Finding |
|---|---|
| Build host for this work | Linux container (Ubuntu 24.04). **No Xcode / iOS SDK available.** |
| Swift | Swift 6.0.3 toolchain installed. `KiraCore` (all financial logic) builds and its **122 tests pass** here. |
| iOS app target | Written for Xcode 16+ / iOS 18 SDK. **Not compiled in this environment.** It must be built and tested in Xcode (see `Kira/README.md`). |

## Matrix

| Capability | Status | Evidence / notes | Implementation |
|---|---|---|---|
| Manual entry, budgets, categories, analytics | ✅ | Pure local logic; fully unit-tested in KiraCore | `KiraCore/*`, app Features |
| Money arithmetic in integer sen | ✅ | `Money` (Int64 minor units); tests cover 0.1+0.2, allocation, rounding | `Money.swift` |
| DuitNow QR parsing (static, dynamic, P2P, no-amount) | ✅ | Field map follows PayNet's public DuitNow QR "QR Data Object" spec. CRC-16/CCITT-FALSE **matches both PayNet published example payloads (343F, 3A23)** | `DuitNowQRParser.swift`, `DuitNowQRTests` |
| DuitNow QR → payment confirmation | ⛔ by design | Scanning proves nothing about payment. Kira stores a **draft**; it's confirmed by a receipt, a statement match or the user | `DuitNowDraftFactory` |
| DuitNow payment initiation from Kira | ⛔ | Needs PayNet participation / acquirer partnership. Not implemented | — |
| Camera QR scanning (AVFoundation) | 🧪 | Standard `AVCaptureMetadataOutput`; needs device testing on real merchant QR codes (lighting, printed stickers) | `QRScannerView.swift` |
| QR from screenshot (Vision barcodes) | 🧪 | `VNDetectBarcodesRequest` | `ReceiptOCR.detectQRCodes` |
| Apple Pay → Shortcuts "Transaction" automation | 🧪 | iOS 17+ Wallet **Transaction** trigger passes Card or Pass, Merchant and Amount to a shortcut ([community docs](https://matthewcassinelli.com/shortcuts-automations-ios-ipados-transaction-display-stage-manager/)). Developers report **blank merchant / 0.0 amount** at times ([Apple Developer Forums](https://developer.apple.com/forums/thread/797233)). Not documented to fire for online / in-app Apple Pay. **Unverified with Malaysian-issued cards** — must test with Maybank, CIMB, Public Bank etc. Apple Pay cards | `LogPaymentIntent`, `ShortcutCaptureProcessor`, `CaptureInbox` |
| Capture while device is locked | 🧪 | Intent writes to an inbox file with `completeUnlessOpen` protection; drained on unlock. Needs device test with Lock-Screen Apple Pay | `CaptureInbox.swift` |
| FinanceKit (Apple Wallet transaction API) | 🤝 / ⛔ for MY | Needs Apple's managed FinanceKit entitlement. Launched for US Apple Card/Cash/Savings. No evidence that Malaysian cards are supported. **Off behind `FeatureFlags.financeKit`; no code linked** | `FeatureFlags.swift` |
| Malaysian bank transaction APIs (Maybank, CIMB, …) | 🤝 | No public personal-account transaction API is available to third-party apps. Malaysia has no live open-banking mandate comparable to the UK's. Would need bilateral bank partnerships. **Kira never asks for banking credentials or scrapes bank apps** | — |
| E-wallet APIs (TNG, GrabPay, Boost, ShopeePay) | 🤝 | No public consumer transaction-history API. Import exported history instead | — |
| CSV statement import | ✅ logic / 🧪 layouts | Header-synonym detection handles re-ordered columns, debit/credit or signed amounts, DR/CR markers, Malay headings, BOM/UTF-16/Windows-1252, failed-status rows, balance/summary lines. **Profiles are not yet verified against real exports from each bank** (`layoutVerified = false`; the UI warns the user to check the preview) | `CSVStatementImporter`, `ImportProfiles` |
| Text-based PDF statements | ✅ logic / 🧪 layouts | PDFKit text → line parser: date-led rows, continuation lines, trailing `-`/`+`/DR/CR markers, running-balance direction inference. Needs validation per bank PDF layout | `StatementTextParser`, `PDFTextExtractor` |
| Scanned PDF statements | 🧪 | Falls back to on-device OCR per page (lower accuracy; user is warned) | `PDFTextExtractor` |
| Password-protected PDFs | 🧪 | User enters the password; PDFKit unlocks in memory only | `StatementImportView` |
| XLSX import | ⛔ (MVP) | Not implemented. The user is told to export CSV/PDF. Backlog item B-12 | `ImportFileValidator` |
| Receipt screenshots / photos (Vision OCR) | ✅ extraction logic / 🧪 OCR quality | Labelled-field extraction (amount, recipient, reference, date, status, channel) with OCR repairs (O→0, I/l→1). Vision runs on-device; Malay is requested only if the device's Vision revision supports it | `ReceiptTextExtractor`, `ReceiptOCR` |
| AI categorisation fallback | ⛔ (by default) | Protocol only (`CategorySuggestionProvider`). No implementation ships. Any future one needs explicit opt-in consent | `CategoryEngine.swift` |
| Reconciliation & duplicate detection | ✅ | Auto-merges only on identical reference numbers or re-imported rows. Similar-looking payments go to review | `ReconciliationEngine` |
| Biometric app lock | 🧪 | LocalAuthentication `.deviceOwnerAuthentication` (passcode fallback) | `AppLock.swift` |
| Encrypted local storage | 🧪 | iOS Data Protection `NSFileProtectionComplete` (entitlement + per-file attributes). No extra SQLCipher layer | `PersistenceController` |
| StoreKit 2 subscriptions | 🧪 | Verified-transaction entitlements, restore, `Transaction.updates`. Local `.storekit` config for testing. Products must be created in App Store Connect | `SubscriptionManager` |
| Supabase sync | ⛔ (not implemented) | RLS schema drafted. Client **not** implemented; flag off | `supabase/migrations`, `SyncService.swift` |
| EPF / SOCSO / EIS | ✅ as estimate | Versioned `StatutoryRuleSet` with sources. Percentage approximations of banded tables, labelled "estimate". Payslip values override | `PayrollEstimator` |
| PCB / MTD | ⛔ by design | Not calculated (depends on reliefs and LHDN schedules). User enters it from the payslip | — |

## Unresolved integration dependencies

1. **Real-device validation of the Wallet Transaction automation** with Malaysian-issued Visa/Mastercard/AMEX Apple Pay cards: which fields arrive, whether online payments trigger it, and how often values are blank.
2. **Sample exports** (redacted) from each listed bank and e-wallet, in CSV and PDF, to verify and harden `ImportProfile`s. Then set `layoutVerified = true` per profile.
3. **PayNet DuitNow QR**: the public developer docs were used. Confirm against the licensed spec version, especially templates 27–51 and tag 82 (data-integrity hash).
4. **Apple FinanceKit**: monitor regional availability; apply for the entitlement only when Malaysian accounts are supported.
5. **App Store Connect**: create the `my.kira.plus.monthly` and `my.kira.premium.monthly` products (proposed RM 6.90 / RM 12.90), the subscription group and the review screenshots.
6. **Legal review**: PDPA (incl. the 2024 amendments, e.g. mandatory breach notification and the data-portability right), the final privacy policy, and confirmation that receipt/statement processing needs no BNM licensing (Kira initiates no payments and holds no funds).
