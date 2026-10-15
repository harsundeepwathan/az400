# Kira — Product Requirements (MVP)

**Promise:** Track where your money goes across Malaysian banks, Apple Pay, DuitNow, cards and e-wallets with the least possible manual input — privately, on your iPhone.

_Name: "Kira" is Malay for "count / calculate"._

## Users & problems

| Persona | Problem today | What Kira does |
|---|---|---|
| Salaried professional in KL with 2–3 bank apps, a credit card and TNG eWallet | Spending is spread across apps. Top-ups and card repayments make totals look doubled | One ledger that classifies transfers, top-ups and card repayments as non-spending |
| DuitNow QR-heavy spender (mamak, kopitiam, pasar malam) | QR payments are frequent and small, so receipts pile up | Scan the QR first (draft), pay, share the receipt. The draft is confirmed automatically by reference match |
| Apple Pay user | iOS doesn't share Wallet history with third-party apps | A Shortcuts automation logs taps as *pending*. Statements reconcile them later |
| Household budgeter with loans (car HP, PTPTN, mortgage) | Loan instalments distort "spending". Hard to know what's safe to spend | Debt cash outflow kept separate. Commitments feed a forecast that states its confidence |

## Principles

1. **Honest data.** Unconfirmed payments are labelled (Draft / Pending). Forecasts are labelled as estimates with a confidence level. Kira never claims access it doesn't have.
2. **One calculation engine.** Every figure (Home, Insights, Budgets, Forecast, Export) comes from `KiraCore.LedgerCalculator`.
3. **Local-first & private.** No account needed, no analytics SDKs, no banking credentials, on-device OCR.
4. **Least input.** Auto-categorisation (Malaysian merchant dictionary + rules learned from corrections), duplicate detection, one-tap confirmations.

## MVP scope (this build)

| Area | Included | Plan |
|---|---|---|
| Manual transactions (CRUD, edit, delete, notes) | ✅ | Free |
| Accounts (bank, card, e-wallet, cash, loan) with user-entered, timestamped balances | ✅ | Free |
| 24 Malaysian default categories + custom categories | ✅ | Free |
| Category learning from corrections (future transactions only) | ✅ | Free |
| Custom merchant rules | ✅ | Plus |
| Monthly + category budgets, rollover, alerts | ✅ | Free |
| Home dashboard: month spending, budget remaining, % used, vs last month, income, commitments, projected month-end, card balances, insights, latest activity | ✅ | Free |
| DuitNow QR scan → draft → confirm / receipt match | ✅ | Free |
| Receipt import (Vision OCR) | ✅ | Free (counts toward the import limit) |
| Statement import CSV / text-PDF / scanned PDF (OCR) | ✅ | Free: 3/month. Plus: unlimited |
| Reconciliation review screen | ✅ | Free (basic) |
| Apple Pay Shortcuts capture | ✅ | Plus |
| Analytics: trend, categories, merchants, weekday/weekend, payment method, savings rate, recurring detection | ✅ | Free (basic) |
| Cash-flow forecast with confidence, safe-to-spend, low-balance periods | ✅ | Premium |
| Commitments & income; loan schedules (reducing / flat-rate HP) | ✅ commitments / Premium loan analytics | Mixed |
| Payslip estimator (EPF/SOCSO/EIS, versioned rules; PCB user-entered) | ✅ | Free |
| Subscription tracker: services catalog, monthly/yearly totals, family-plan share, trials, renewal reminders (local notifications, no amounts), charge matching, price-change and "still subscribed?" alerts, suggestions from transactions, included in forecasts, per-month and due-in-30-days tiles, spending trend (3M/6M/1Y, recorded charges only), renewal calendar with month total, last billed and total spent (recorded or labelled estimate) | ✅ | Free |
| Face ID / passcode lock, app-switcher privacy, Data Protection | ✅ | Free |
| CSV + JSON export, delete all data | ✅ | **Always free** |
| StoreKit 2 subscriptions | ✅ | — |
| Supabase sync, household budgeting, FinanceKit, XLSX | ❌ deferred | See BACKLOG |

## Success metrics (post-launch)

- ≥ 60% of week-1 users capture ≥ 10 transactions.
- Median manual fields typed per transaction ≤ 1.5 (merchant/amount prefilled by QR, receipt or Shortcut).
- < 1% of reconciled imports later corrected as wrong merges.
- Day-30 retention ≥ 35%. Plus conversion ≥ 4% of monthly actives.

## Non-goals

Payment initiation, credit scoring, investment tracking, bank-credential aggregation, and anything requiring a BNM licence.
