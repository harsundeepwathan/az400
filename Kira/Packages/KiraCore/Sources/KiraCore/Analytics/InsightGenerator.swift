import Foundation

public struct Insight: Equatable, Sendable, Identifiable {
    public enum Kind: String, Sendable { case categoryChange, upcomingCommitments, merchantSpend, discretionaryRemaining, budgetPace, recurringFound }
    public enum Tone: String, Sendable { case neutral, positive, caution }

    public let id: String
    public let kind: Kind
    public let tone: Tone
    public let title: String
    public let detail: String
    /// Optional category for iconography / deep link.
    public let categoryID: String?
}

/// Generates insights only when the underlying data is sufficient. Each rule states its
/// minimum-data threshold; with too little data it returns nothing rather than a weak claim.
public struct InsightGenerator: Sendable {
    public var analytics: AnalyticsEngine
    public var calendar: KLCalendar
    public var categories: [String: CategoryDefinition]

    /// A month comparison needs at least this many counted transactions in *each* month.
    public var minimumTransactionsPerMonth = 10
    /// …and at least this much spent in the category in the previous month.
    public var minimumCategoryBase = Money(minorUnits: 10_000)
    public var minimumChange = 0.15

    public init(analytics: AnalyticsEngine = AnalyticsEngine(), calendar: KLCalendar = .shared,
                categories: [CategoryDefinition] = BuiltInCategory.allDefinitions) {
        self.analytics = analytics
        self.calendar = calendar
        self.categories = Dictionary(categories.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
    }

    public func insights(now: Date, transactions: [TransactionRecord], commitments: [Commitment], monthlyBudget: Budget?) -> [Insight] {
        var results: [Insight] = []
        let ledger = analytics.ledger
        let thisMonth = calendar.monthInterval(containing: now)
        let lastMonth = calendar.previousMonthInterval(before: now)
        // Compare like-for-like: the same number of elapsed days in the previous month.
        let elapsedDays = calendar.dayDistance(from: thisMonth.start, to: now) + 1
        let lastMonthComparable = DateInterval(start: lastMonth.start, end: min(calendar.addingDays(elapsedDays, to: lastMonth.start), lastMonth.end))
        let current = ledger.summarize(transactions, filter: TransactionFilter(dateInterval: DateInterval(start: thisMonth.start, end: max(now, thisMonth.start))))
        let previous = ledger.summarize(transactions, filter: TransactionFilter(dateInterval: lastMonthComparable))

        // 1. Category change vs last month (same point in month).
        if current.countedTransactions >= minimumTransactionsPerMonth && previous.countedTransactions >= minimumTransactionsPerMonth {
            let changes = current.spendingByCategory.compactMap { (categoryID, amount) -> (String, Double, Money)? in
                guard categoryID != BuiltInCategory.transfers.id, let before = previous.spendingByCategory[categoryID], before >= minimumCategoryBase,
                      let ratio = amount.ratio(to: before) else { return nil }
                let change = ratio - 1
                return abs(change) >= minimumChange ? (categoryID, change, amount - before) : nil
            }.sorted { abs($0.2.minorUnits) > abs($1.2.minorUnits) }
            if let (categoryID, change, _) = changes.first {
                let name = categories[categoryID]?.name ?? "Other"
                let direction = change > 0 ? "increased" : "decreased"
                results.append(Insight(id: "category-change-\(categoryID)", kind: .categoryChange, tone: change > 0 ? .caution : .positive,
                                       title: "\(name) \(direction) \(PercentFormatter.string(abs(change)))",
                                       detail: "Your \(name.lowercased()) spending \(direction) \(PercentFormatter.string(abs(change))) compared with the same point last month.",
                                       categoryID: categoryID))
            }
        }

        // 2. Upcoming commitments for the rest of the month.
        let rest = DateInterval(start: calendar.addingDays(1, to: calendar.startOfDay(now)), end: thisMonth.end)
        if rest.duration > 0 {
            let upcoming = commitments.filter(\.isActive).flatMap { commitment in
                calendar.occurrences(of: commitment.recurrence, startDate: commitment.startDate, endDate: commitment.endDate, in: rest).map { _ in commitment.amount }
            }
            if !upcoming.isEmpty {
                let total = upcoming.sum()
                results.append(Insight(id: "upcoming-commitments", kind: .upcomingCommitments, tone: .neutral,
                                       title: "\(total.formatted) in upcoming commitments",
                                       detail: "\(upcoming.count) scheduled payment\(upcoming.count == 1 ? "" : "s") before the end of \(calendar.monthName(now)).",
                                       categoryID: nil))
            }
        }

        // 3. Merchant concentration: only with ≥3 transactions at that merchant this month.
        let monthFilter = TransactionFilter(dateInterval: thisMonth)
        if let top = analytics.topMerchants(transactions, filter: monthFilter, limit: 1).first, top.count >= 3, top.amount.minorUnits >= 5_000 {
            results.append(Insight(id: "merchant-\(top.merchantKey)", kind: .merchantSpend, tone: .neutral,
                                   title: "\(top.amount.formatted) at \(top.displayName)",
                                   detail: "You spent \(top.amount.formatted) at \(top.displayName) across \(top.count) payments this month.",
                                   categoryID: nil))
        }

        // 4. Discretionary budget remaining (requires a monthly budget).
        if let budget = monthlyBudget, budget.isActive {
            let committedRest = commitments.filter(\.isActive).flatMap { commitment in
                calendar.occurrences(of: commitment.recurrence, startDate: commitment.startDate, endDate: commitment.endDate, in: rest)
                    .map { _ in commitment.type.isDebt ? Money.zero() : commitment.amount }
            }.sum()
            let remaining = budget.limit - current.netSpending - committedRest
            let tone: Insight.Tone = remaining.isNegative ? .caution : .positive
            results.append(Insight(id: "discretionary-remaining", kind: .discretionaryRemaining, tone: tone,
                                   title: remaining.isNegative ? "Over budget by \(remaining.magnitude.formatted)" : "\(remaining.formatted) left to spend",
                                   detail: "Your remaining discretionary budget after upcoming non-loan commitments.",
                                   categoryID: nil))
        }

        // 5. Recurring charges not yet tracked as commitments.
        let known = Set(commitments.map { MerchantNormalizer.key($0.name) })
        if let recurring = analytics.recurringCharges(transactions).first(where: { !known.contains($0.merchantKey) }) {
            results.append(Insight(id: "recurring-\(recurring.merchantKey)", kind: .recurringFound, tone: .neutral,
                                   title: "\(recurring.displayName) looks recurring",
                                   detail: "\(recurring.occurrences) payments of about \(recurring.typicalAmount.formatted). Add it as a commitment to include it in forecasts.",
                                   categoryID: nil))
        }
        return results
    }
}
