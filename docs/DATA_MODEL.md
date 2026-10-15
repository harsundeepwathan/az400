# Persistent data model

All records are KiraCore `Codable` structs, persisted by SwiftData (`Kira/Core/Persistence/Entities.swift`) as a JSON payload plus query columns.

## TransactionRecord (normalised transaction)

| Field | Type | Notes |
|---|---|---|
| `id` | UUID | Stable identity; kept when records are merged |
| `accountID` | UUID? | Owning account, if known |
| `amount` | `Money` (Int64 sen + currency) | **Magnitude, never negative** |
| `direction` | outflow / inflow | Sign relative to the account |
| `kind` | expense, income, transfer, creditCardRepayment, walletTopUp, refund, reversal, fee, debtRepayment | Decides what counts as spending |
| `merchant` | String? | Cleaned display name |
| `transactionDescription` | String | Raw statement/receipt text (sanitised) |
| `transactionDate` | Date | When it happened (MYT) |
| `postingDate` | Date? | When the bank posted it |
| `channel` | Apple Pay, card, DuitNow QR, DuitNow transfer, FPX, JomPAY, e-wallet, bank transfer, cash, direct debit, ATM, other | Payment channel |
| `categoryID` | String? | Built-in ID or custom UUID |
| `categoryIsUserSet` | Bool | When true, automation never changes the category |
| `status` | draft, pending, confirmed, reconciled, superseded | Lifecycle |
| `source` | manual, appleShortcut, duitNowQR, receiptImage, receiptDocument, eWalletStatement, bankStatementCSV, bankStatementPDF, financeKit | Import source; ordered by evidential authority |
| `externalReference` | String? | Bank/wallet reference, QR bill/reference number |
| `confidence` | Double 0–1 | Extraction + categorisation confidence |
| `flags` | Set<ReviewFlag> | amountMissing, merchantMissing, lowConfidenceCategory, possibleDuplicate, unconfirmedPayment, directionUncertain, foreignCurrency |
| `notes` | String? | User notes (≤ 500 chars) |
| `merchantCategoryCode` | String? | ISO 18245 MCC (from QR) |
| `linkedTransactionID` | UUID? | Refund → original, transfer leg → counterpart |
| `supersededBy` | UUID? | Set when merged into another record |
| `importFingerprint` | String? | FNV-1a of account/day/direction/amount/description/reference/occurrence — re-import detection |
| `createdAt` / `updatedAt` | Date | Timestamps |

### What counts where (LedgerCalculator)

| Kind | Spending | Income | Shown separately as |
|---|---|---|---|
| expense, fee | ✅ (+) | | |
| refund, reversal | ✅ (−) in the original category | | |
| income | | ✅ | |
| transfer | | | Transfers in/out |
| creditCardRepayment | | | Card repayments (outflow leg only) |
| walletTopUp | | | E-wallet top-ups |
| debtRepayment | | | Debt cash outflow |

Counted statuses: confirmed, reconciled, pending (by default; labelled). Drafts, superseded records, `amountMissing` and non-MYR records are excluded and reported as `excludedTransactions`.

## Other entities

| Entity | Key fields |
|---|---|
| `Account` | name, type (savings/current/creditCard/eWallet/cash/loan), institution, lastFour, walletCardNames, balance + balanceVerifiedAt (user-entered), includeInForecast, isArchived |
| `CategoryDefinition` | id, name, SF Symbol, tint token, isBuiltIn, isDiscretionary, isArchived |
| `Budget` | categoryID? (nil = total), limit, period (monthly/weekly), rollover (none/carryUnused/carryAll), alertThreshold |
| `Commitment` | name, type (mortgage, rent, car financing, personal loan, credit card, insurance, utilities, subscription, PTPTN, BNPL), amount, recurrence, start/end, accountID, `DebtTerms?` |
| `DebtTerms` | principal, annualRate (Decimal), tenureMonths, method (reducing balance / flat rate), startDate, statedOutstanding? |
| `ServiceSubscription` | name, serviceID (catalog), amount (full price), cycle (weekly/monthly/quarterly/yearly/every N months), nextRenewal, status (active/trial/paused/cancelled), trialEndsAt, cancelledAt, accountID, categoryID, shareCount, reminderDaysBefore, billedThroughApple, matchPattern, notes |
| `IncomeSource` | name, type (basic/additional salary, freelance, bonus, rental), expectedNet, gross?, recurrence |
| `MerchantRule` | pattern, matchType (exact/contains/prefix), categoryID, kind?, learnedFromCorrection |
| `StatutoryRuleSet` | versioned EPF/SOCSO/EIS rates, ceilings, effectiveFrom, source, userVerified |
| `ImportBatchEntity` | importedAt, source, profileID, fileName, count (free-tier limit, history) |
| `AuditEventEntity` | occurredAt, action, detail (digits redacted) — exports, lock changes |
| `CaptureInboxItem` (file) | id, receivedAt, ShortcutTransactionInput |
