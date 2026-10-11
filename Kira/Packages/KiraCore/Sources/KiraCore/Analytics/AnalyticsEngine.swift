import Foundation

public struct CategoryShare: Equatable, Sendable, Identifiable {
    public var id: String { categoryID }
    public let categoryID: String
    public let amount: Money
    public let share: Double
}

public struct MerchantTotal: Equatable, Sendable, Identifiable {
    public var id: String { merchantKey }
    public let merchantKey: String
    public let displayName: String
    public let amount: Money
    public let count: Int
}

public struct MonthlyPoint: Equatable, Sendable, Identifiable {
    public var id: Date { monthStart }
    public let monthStart: Date
    public let spending: Money
    public let income: Money
    public let debtRepayments: Money
}

public struct RecurringCharge: Equatable, Sendable, Identifiable {
    public var id: String { merchantKey }
    public let merchantKey: String
    public let displayName: String
    public let typicalAmount: Money
    public let cadenceDays: Int
    public let occurrences: Int
    public let lastDate: Date
    public let nextExpectedDate: Date
}

/// Read-only analytics. Every figure is computed through `LedgerCalculator` so the Insights tab,
/// Home dashboard and budgets can never disagree.
public struct AnalyticsEngine: Sendable {
    public var ledger: LedgerCalculator
    public var calendar: KLCalendar

    public init(ledger: LedgerCalculator = LedgerCalculator(), calendar: KLCalendar = .shared) {
        self.ledger = ledger
        self.calendar = calendar
    }

    public func categoryBreakdown(_ records: [TransactionRecord], filter: TransactionFilter) -> [CategoryShare] {
        let summary = ledger.summarize(records, filter: filter)
        let positive = summary.spendingByCategory.filter { $0.value.minorUnits > 0 }
        let total = positive.values.map(\.minorUnits).reduce(0, +)
        guard total > 0 else { return [] }
        return positive.map { CategoryShare(categoryID: $0.key, amount: $0.value, share: Double($0.value.minorUnits) / Double(total)) }
            .sorted { $0.amount.minorUnits == $1.amount.minorUnits ? $0.categoryID < $1.categoryID : $0.amount.minorUnits > $1.amount.minorUnits }
    }

    public func topMerchants(_ records: [TransactionRecord], filter: TransactionFilter, limit: Int = 10) -> [MerchantTotal] {
        var totals: [String: (name: String, amount: Int64, count: Int)] = [:]
        for record in spendingRecords(records, filter: filter) {
            let key = MerchantNormalizer.key(record.merchant ?? record.transactionDescription)
            guard !key.isEmpty else { continue }
            let signed = record.kind == .refund || record.kind == .reversal ? -record.amount.minorUnits : record.amount.minorUnits
            let entry = totals[key] ?? (record.merchant ?? MerchantNormalizer.displayName(record.transactionDescription), 0, 0)
            totals[key] = (entry.name, entry.amount + signed, entry.count + (signed > 0 ? 1 : 0))
        }
        let currency = ledger.policy.baseCurrency
        var merchants: [MerchantTotal] = []
        for (key, value) in totals where value.amount > 0 {
            merchants.append(MerchantTotal(merchantKey: key, displayName: value.name, amount: Money(minorUnits: value.amount, currency: currency), count: value.count))
        }
        merchants.sort { lhs, rhs in
            lhs.amount.minorUnits == rhs.amount.minorUnits ? lhs.merchantKey < rhs.merchantKey : lhs.amount.minorUnits > rhs.amount.minorUnits
        }
        return Array(merchants.prefix(limit))
    }

    public func monthlyTrend(_ records: [TransactionRecord], endingAt date: Date, months: Int, filter: TransactionFilter = TransactionFilter()) -> [MonthlyPoint] {
        var points: [MonthlyPoint] = []
        var interval = calendar.monthInterval(containing: date)
        for _ in 0..<months {
            var monthFilter = filter
            monthFilter.dateInterval = interval
            let summary = ledger.summarize(records, filter: monthFilter)
            points.insert(MonthlyPoint(monthStart: interval.start, spending: summary.netSpending, income: summary.income, debtRepayments: summary.debtRepayments), at: 0)
            interval = calendar.previousMonthInterval(before: interval.start)
        }
        return points
    }

    /// Spending split by weekday vs weekend, plus average per day of each type in the range.
    public func weekdayWeekend(_ records: [TransactionRecord], filter: TransactionFilter) -> (weekday: Money, weekend: Money, weekdayAverage: Money, weekendAverage: Money) {
        var weekday = Money.zero(ledger.policy.baseCurrency), weekend = Money.zero(ledger.policy.baseCurrency)
        for record in spendingRecords(records, filter: filter) {
            let signed = record.kind == .refund || record.kind == .reversal ? record.amount.negated : record.amount
            if calendar.isWeekend(record.transactionDate) { weekend += signed } else { weekday += signed }
        }
        var weekdayDays = 0, weekendDays = 0
        if let interval = filter.dateInterval {
            var cursor = calendar.startOfDay(interval.start)
            while cursor < interval.end {
                if calendar.isWeekend(cursor) { weekendDays += 1 } else { weekdayDays += 1 }
                cursor = calendar.addingDays(1, to: cursor)
            }
        }
        let currency = ledger.policy.baseCurrency
        return (weekday, weekend,
                Money(minorUnits: weekdayDays > 0 ? weekday.minorUnits / Int64(weekdayDays) : 0, currency: currency),
                Money(minorUnits: weekendDays > 0 ? weekend.minorUnits / Int64(weekendDays) : 0, currency: currency))
    }

    public func byPaymentChannel(_ records: [TransactionRecord], filter: TransactionFilter) -> [(PaymentChannel, Money)] {
        var totals: [PaymentChannel: Money] = [:]
        for record in spendingRecords(records, filter: filter) where record.kind == .expense || record.kind == .fee {
            totals[record.channel, default: .zero(ledger.policy.baseCurrency)] += record.amount
        }
        return totals.sorted { $0.value.minorUnits > $1.value.minorUnits }
    }

    /// (income − net spending − debt repayments) / income. nil without income.
    public func savingsRate(_ records: [TransactionRecord], filter: TransactionFilter) -> Double? {
        let summary = ledger.summarize(records, filter: filter)
        guard summary.income.minorUnits > 0 else { return nil }
        let saved = summary.income - summary.netSpending - summary.debtRepayments
        return Double(saved.minorUnits) / Double(summary.income.minorUnits)
    }

    /// Detects charges repeating at a regular cadence with stable amounts (subscriptions, bills).
    public func recurringCharges(_ records: [TransactionRecord], minimumOccurrences: Int = 3) -> [RecurringCharge] {
        let groups = Dictionary(grouping: records.filter { ledger.policy.counts($0) && $0.direction == .outflow && ($0.kind == .expense || $0.kind == .debtRepayment) }) {
            MerchantNormalizer.key($0.merchant ?? $0.transactionDescription)
        }
        var results: [RecurringCharge] = []
        for (key, group) in groups where !key.isEmpty && group.count >= minimumOccurrences {
            let sorted = group.sorted { $0.transactionDate < $1.transactionDate }
            let gaps = zip(sorted, sorted.dropFirst()).map { calendar.dayDistance(from: $0.transactionDate, to: $1.transactionDate) }
            guard let medianGap = gaps.sorted()[safe: gaps.count / 2] else { continue }
            let cadence: Int
            switch medianGap {
            case 6...8: cadence = 7
            case 26...35: cadence = 30
            case 85...95: cadence = 91
            case 355...375: cadence = 365
            default: continue
            }
            // Require most gaps to be close to the cadence and amounts within 15% of the median.
            let tolerance = max(cadence / 6, 2)
            let regularGaps = gaps.filter { abs($0 - medianGap) <= tolerance }.count
            guard Double(regularGaps) >= Double(gaps.count) * 0.75 else { continue }
            let amounts = sorted.map(\.amount.minorUnits).sorted()
            let median = amounts[amounts.count / 2]
            guard median > 0, amounts.allSatisfy({ abs($0 - median) * 100 <= median * 15 }) else { continue }
            let last = sorted.last!
            let next = cadence == 30 ? calendar.addingMonths(1, to: last.transactionDate) : calendar.addingDays(cadence, to: last.transactionDate)
            results.append(RecurringCharge(merchantKey: key, displayName: last.merchant ?? MerchantNormalizer.displayName(last.transactionDescription),
                                           typicalAmount: Money(minorUnits: median, currency: last.amount.currency), cadenceDays: cadence,
                                           occurrences: sorted.count, lastDate: last.transactionDate, nextExpectedDate: next))
        }
        return results.sorted { $0.typicalAmount.minorUnits > $1.typicalAmount.minorUnits }
    }

    func spendingRecords(_ records: [TransactionRecord], filter: TransactionFilter) -> [TransactionRecord] {
        records.filter { filter.matches($0) && ledger.policy.counts($0) && [.expense, .fee, .refund, .reversal].contains($0.kind) }
    }
}

extension Array {
    subscript(safe index: Int) -> Element? { indices.contains(index) ? self[index] : nil }
}
