import Foundation

public struct BudgetStatus: Equatable, Sendable {
    public enum Level: String, Sendable { case onTrack, nearingLimit, overBudget }

    public let budget: Budget
    public let period: DateInterval
    /// Limit plus any rollover carried from the previous period.
    public let effectiveLimit: Money
    public let rolloverAmount: Money
    public let spent: Money
    public var remaining: Money { effectiveLimit - spent }
    /// Fraction used (0…∞). nil when the limit is zero.
    public let fractionUsed: Double?
    /// Fraction of the period elapsed (0…1).
    public let fractionElapsed: Double
    /// Linear projection of spend at period end, based on pace so far.
    public let projectedSpend: Money
    public let level: Level
    public let shouldAlert: Bool
}

/// Budget calculations. Spending figures come from `LedgerCalculator`, so transfers, card
/// repayments, top-ups and loan principal never consume budget.
public struct BudgetEngine: Sendable {
    public var calendar: KLCalendar
    public var ledger: LedgerCalculator

    public init(calendar: KLCalendar = .shared, ledger: LedgerCalculator = LedgerCalculator()) {
        self.calendar = calendar
        self.ledger = ledger
    }

    public func period(for budget: Budget, containing date: Date) -> DateInterval {
        budget.period == .monthly ? calendar.monthInterval(containing: date) : calendar.weekInterval(containing: date)
    }

    public func spent(for budget: Budget, in interval: DateInterval, transactions: [TransactionRecord]) -> Money {
        let summary = ledger.summarize(transactions, filter: TransactionFilter(dateInterval: interval))
        if let categoryID = budget.categoryID {
            return summary.spendingByCategory[categoryID] ?? .zero(budget.limit.currency)
        }
        return summary.netSpending
    }

    /// Rollover from previous periods, computed iteratively back to `rolloverHorizon` periods.
    public func rollover(for budget: Budget, before interval: DateInterval, transactions: [TransactionRecord], horizon: Int = 12) -> Money {
        guard budget.rollover != .none else { return .zero(budget.limit.currency) }
        // Find the earliest transaction so we don't roll budget forward from before the user started.
        guard let earliest = transactions.map(\.transactionDate).min() else { return .zero(budget.limit.currency) }

        var periods: [DateInterval] = []
        var cursor = interval
        for _ in 0..<horizon {
            let previous = self.period(for: budget, containing: calendar.addingDays(-1, to: cursor.start))
            guard previous.end > earliest else { break }
            periods.insert(previous, at: 0)
            cursor = previous
        }

        var carry = Money.zero(budget.limit.currency)
        for period in periods {
            let available = budget.limit + carry
            let leftover = available - spent(for: budget, in: period, transactions: transactions)
            switch budget.rollover {
            case .none: carry = .zero(budget.limit.currency)
            case .carryUnused: carry = leftover.isNegative ? .zero(budget.limit.currency) : leftover
            case .carryAll: carry = leftover
            }
        }
        return carry
    }

    public func status(for budget: Budget, on date: Date, transactions: [TransactionRecord]) -> BudgetStatus {
        let interval = period(for: budget, containing: date)
        let carry = rollover(for: budget, before: interval, transactions: transactions)
        let limit = budget.limit + carry
        let spent = spent(for: budget, in: interval, transactions: transactions)

        let total = interval.duration
        let elapsed = min(max(date.timeIntervalSince(interval.start), 0), total)
        let fractionElapsed = total > 0 ? elapsed / total : 1
        // Projection uses whole days elapsed (min 1) to avoid wild early-period numbers.
        let daysElapsed = max(calendar.dayDistance(from: interval.start, to: date) + 1, 1)
        let totalDays = max(calendar.dayDistance(from: interval.start, to: interval.end), 1)
        let projected = spent.isNegative ? spent : spent.multiplied(by: Decimal(totalDays) / Decimal(daysElapsed))

        let fraction = limit.minorUnits > 0 ? Double(spent.minorUnits) / Double(limit.minorUnits) : nil
        let level: BudgetStatus.Level
        if let fraction, fraction > 1 { level = .overBudget }
        else if limit.minorUnits <= 0 && spent.minorUnits > 0 { level = .overBudget }
        else if let fraction, fraction >= budget.alertThreshold { level = .nearingLimit }
        else { level = .onTrack }

        return BudgetStatus(budget: budget, period: interval, effectiveLimit: limit, rolloverAmount: carry, spent: spent,
                            fractionUsed: fraction, fractionElapsed: fractionElapsed, projectedSpend: projected,
                            level: level, shouldAlert: level != .onTrack)
    }

    /// Sum of category allocations, so the editor can show unallocated budget.
    public func allocationSummary(total: Budget?, categoryBudgets: [Budget]) -> (allocated: Money, unallocated: Money?) {
        let allocated = categoryBudgets.filter { $0.isActive && $0.period == .monthly }.map(\.limit).sum()
        guard let total else { return (allocated, nil) }
        return (allocated, total.limit - allocated)
    }
}
