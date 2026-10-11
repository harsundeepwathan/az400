import Foundation

/// Rules for which records count toward totals.
public struct LedgerPolicy: Hashable, Sendable {
    /// Pending records (e.g. Wallet tap events) are real evidence of payment but not yet confirmed.
    /// Included by default so the dashboard is not misleadingly low; the UI labels them.
    public var includePending: Bool
    public var baseCurrency: CurrencyCode

    public init(includePending: Bool = true, baseCurrency: CurrencyCode = .myr) {
        self.includePending = includePending
        self.baseCurrency = baseCurrency
    }

    public static let `default` = LedgerPolicy()

    /// Whether a record contributes to any total.
    public func counts(_ record: TransactionRecord) -> Bool {
        guard record.amount.currency == baseCurrency else { return false }
        guard !record.flags.contains(.amountMissing) else { return false }
        switch record.status {
        case .confirmed, .reconciled: return true
        case .pending: return includePending
        case .draft, .superseded: return false
        }
    }
}

/// Filters shared by Activity, Insights and exports.
public struct TransactionFilter: Hashable, Sendable {
    public var dateInterval: DateInterval?
    public var accountIDs: Set<UUID>?
    public var categoryIDs: Set<String>?
    public var merchantQuery: String?
    public var channels: Set<PaymentChannel>?
    public var statuses: Set<TransactionStatus>?
    public var sources: Set<ImportSource>?
    public var kinds: Set<TransactionKind>?

    public init(dateInterval: DateInterval? = nil, accountIDs: Set<UUID>? = nil, categoryIDs: Set<String>? = nil,
                merchantQuery: String? = nil, channels: Set<PaymentChannel>? = nil, statuses: Set<TransactionStatus>? = nil,
                sources: Set<ImportSource>? = nil, kinds: Set<TransactionKind>? = nil) {
        self.dateInterval = dateInterval
        self.accountIDs = accountIDs
        self.categoryIDs = categoryIDs
        self.merchantQuery = merchantQuery
        self.channels = channels
        self.statuses = statuses
        self.sources = sources
        self.kinds = kinds
    }

    public func matches(_ record: TransactionRecord) -> Bool {
        if let dateInterval, !(record.transactionDate >= dateInterval.start && record.transactionDate < dateInterval.end) { return false }
        if let accountIDs, !(record.accountID.map(accountIDs.contains) ?? false) { return false }
        if let categoryIDs, !categoryIDs.contains(LedgerCalculator.effectiveCategory(of: record)) { return false }
        if let channels, !channels.contains(record.channel) { return false }
        if let statuses, !statuses.contains(record.status) { return false }
        if let sources, !sources.contains(record.source) { return false }
        if let kinds, !kinds.contains(record.kind) { return false }
        if let query = merchantQuery?.trimmingCharacters(in: .whitespaces), !query.isEmpty {
            let haystack = (record.merchant ?? "") + " " + record.transactionDescription
            if haystack.range(of: query, options: [.caseInsensitive, .diacriticInsensitive]) == nil { return false }
        }
        return true
    }
}

/// Totals for a set of transactions. All dashboard, budget and analytics figures derive from this.
public struct LedgerSummary: Hashable, Sendable {
    /// Expenses + fees (before refunds).
    public var grossSpending: Money
    /// Refunds + reversals.
    public var refunds: Money
    /// grossSpending − refunds. The "spending" figure shown to users.
    public var netSpending: Money { grossSpending - refunds }
    public var income: Money
    /// Internal movements — shown separately, never as spending or income.
    public var transfersOut: Money
    public var transfersIn: Money
    public var creditCardRepayments: Money
    public var walletTopUps: Money
    /// Principal instalments — debt cash outflow, separate from consumption.
    public var debtRepayments: Money
    public var fees: Money
    /// Net spending per effective category ID.
    public var spendingByCategory: [String: Money]
    public var countedTransactions: Int
    /// Records skipped: drafts, merged duplicates, unknown amounts, foreign currency.
    public var excludedTransactions: Int
    public var pendingIncluded: Int

    /// All money that left the user's accounts for outside parties (spending + debt), net of refunds.
    public var externalCashOutflow: Money { netSpending + debtRepayments }

    public static func empty(_ currency: CurrencyCode = .myr) -> LedgerSummary {
        let zero = Money.zero(currency)
        return LedgerSummary(grossSpending: zero, refunds: zero, income: zero, transfersOut: zero, transfersIn: zero,
                             creditCardRepayments: zero, walletTopUps: zero, debtRepayments: zero, fees: zero,
                             spendingByCategory: [:], countedTransactions: 0, excludedTransactions: 0, pendingIncluded: 0)
    }
}

/// The single, audited calculation engine. Views never sum transactions themselves.
public struct LedgerCalculator: Sendable {
    public var policy: LedgerPolicy

    public init(policy: LedgerPolicy = .default) {
        self.policy = policy
    }

    /// Category used for aggregation when the record has none assigned.
    public static func effectiveCategory(of record: TransactionRecord) -> String {
        if let categoryID = record.categoryID { return categoryID }
        switch record.kind {
        case .fee: return BuiltInCategory.debtInterestFees.id
        case .transfer, .creditCardRepayment, .walletTopUp: return BuiltInCategory.transfers.id
        default: return BuiltInCategory.other.id
        }
    }

    public func summarize(_ records: [TransactionRecord], filter: TransactionFilter = TransactionFilter()) -> LedgerSummary {
        var summary = LedgerSummary.empty(policy.baseCurrency)
        let byID = Dictionary(records.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })

        for record in records where filter.matches(record) {
            guard policy.counts(record) else {
                summary.excludedTransactions += 1
                continue
            }
            summary.countedTransactions += 1
            if record.status == .pending { summary.pendingIncluded += 1 }

            switch record.kind {
            case .expense, .fee:
                // An inflow labelled expense is treated as a refund to stay conservative.
                if record.direction == .outflow {
                    summary.grossSpending += record.amount
                    if record.kind == .fee { summary.fees += record.amount }
                    summary.spendingByCategory[Self.effectiveCategory(of: record), default: .zero(policy.baseCurrency)] += record.amount
                } else {
                    applyRefund(record, original: nil, to: &summary)
                }
            case .refund, .reversal:
                applyRefund(record, original: record.linkedTransactionID.flatMap { byID[$0] }, to: &summary)
            case .income:
                if record.direction == .inflow { summary.income += record.amount } else { summary.income -= record.amount }
            case .transfer:
                if record.direction == .outflow { summary.transfersOut += record.amount } else { summary.transfersIn += record.amount }
            case .creditCardRepayment:
                // Count once: the paying side's outflow. The card-side inflow is the same money.
                if record.direction == .outflow { summary.creditCardRepayments += record.amount }
            case .walletTopUp:
                if record.direction == .outflow { summary.walletTopUps += record.amount }
            case .debtRepayment:
                if record.direction == .outflow { summary.debtRepayments += record.amount } else { summary.debtRepayments -= record.amount }
            }
        }
        return summary
    }

    private func applyRefund(_ record: TransactionRecord, original: TransactionRecord?, to summary: inout LedgerSummary) {
        // A refund recorded as an outflow (e.g. merchant clawback) is spending again.
        let amount = record.direction == .inflow ? record.amount : record.amount.negated
        summary.refunds += amount
        let category = record.categoryID ?? original?.categoryID ?? Self.effectiveCategory(of: record)
        summary.spendingByCategory[category, default: .zero(policy.baseCurrency)] -= amount
    }
}
