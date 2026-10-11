# Prioritised backlog

## Done in this increment
- KiraCore domain engine + 122 tests (Linux-verified).
- iOS app: navigation, design system, persistence, all MVP screens, App Intent, OCR, QR, StoreKit 2, app lock, export/delete.

## P0 — before TestFlight
| # | Item | Why |
|---|---|---|
| B-1 | Build in Xcode 16, fix any compile issues, run `KiraTests` + `KiraUITests` on simulator | The app target was not compiled in the authoring environment |
| B-2 | Device test the Wallet Transaction automation with Malaysian cards; record findings in FEASIBILITY.md | Core capture promise |
| B-3 | Collect redacted sample statements for all 13 profiles; add fixtures; set `layoutVerified` | Import accuracy |
| B-4 | Device test lock-screen Apple Pay → inbox → drain on unlock | Data-protection interplay |
| B-5 | App icon + launch polish, real-device VoiceOver pass | Store readiness |
| B-6 | Create App Store Connect subscription products; sandbox purchase/restore/expiry tests | Monetisation |

## P1 — fast follows
| # | Item |
|---|---|
| B-7 | Share Extension: "Share receipt to Kira" from bank apps and Photos (currently via in-app picker) |
| B-8 | Transfer-pair suggestions UI (engine `TransferClassifier.pairTransfers` exists and is tested) |
| B-9 | Budget alerts via local notifications at the threshold |
| B-10 | Refund linking UI (pick the original purchase) |
| B-11 | Per-bank PDF layout heuristics (column x-positions via PDFKit selections) |
| B-12 | XLSX import (minimal ZIP + sharedStrings reader) |
| B-13 | Widget: safe-to-spend & month spending (protected data aware) |
| B-14 | Weekly budgets in the editor UI (engine supports them) |

## P2 — later
| # | Item |
|---|---|
| B-15 | Supabase sync with client-side encryption (schema drafted) — Premium |
| B-16 | Household budgeting (shared ledgers) |
| B-17 | Annual plans / trials after pricing validation |
| B-18 | Opt-in AI categorisation fallback with explicit consent, redaction and on-device first |
| B-19 | FinanceKit, if Apple supports Malaysian accounts |
| B-20 | Multi-currency conversion for travel spending |
