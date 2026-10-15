import Foundation

public struct SubscriptionSummary: Equatable, Sendable {
    /// Your share per month across subscriptions that are billing now (excludes free trials).
    public let monthlyTotal: Money
    public let yearlyTotal: Money
    /// Monthly total once current free trials convert to paid plans.
    public let monthlyAfterTrials: Money
    public let activeCount: Int
    public let trialCount: Int
    /// Subscriptions billed in another currency — listed, but not added to RM totals.
    public let foreignCurrencyCount: Int
    public let upcoming: [UpcomingRenewal]
}

public struct UpcomingRenewal: Equatable, Sendable, Identifiable {
    public var id: String { "\(subscriptionID)-\(date.timeIntervalSince1970)" }
    public let subscriptionID: UUID
    public let date: Date
    /// What the provider will charge (full price; trials show their first paid charge).
    public let amount: Money
    public let isTrialConversion: Bool
}

public struct SubscriptionAlert: Equatable, Sendable, Identifiable {
    public enum Kind: Equatable, Sendable {
        case renewsSoon(Date)
        case trialEnding(Date)
        /// Latest matched charge differs from the tracked price.
        case priceChanged(from: Money, to: Money)
        /// Statements show no charge when one was expected — it may have been cancelled.
        case noRecentCharge(expected: Date)
        /// Two live subscriptions to the same service.
        case duplicate(otherID: UUID)
    }

    public var id: String { "\(subscriptionID)-\(kindKey)" }
    public let subscriptionID: UUID
    public let kind: Kind

    var kindKey: String {
        switch kind {
        case .renewsSoon: return "renews"
        case .trialEnding: return "trial"
        case .priceChanged: return "price"
        case .noRecentCharge: return "missing"
        case .duplicate(let other): return "dup-\(other)"
        }
    }
}

public struct SpendTotal: Equatable, Sendable {
    public let amount: Money
    public let since: Date
    public let chargeCount: Int
    /// True when computed from the schedule because no charges were recorded.
    public let isEstimate: Bool
}

public struct MonthlyAmount: Equatable, Sendable, Identifiable {
    public var id: Date { monthStart }
    public let monthStart: Date
    public let amount: Money
}

public struct RenewalCalendarMonth: Equatable, Sendable {
    public let month: DateInterval
    /// Keyed by start of day (Malaysia time).
    public let renewalsByDay: [Date: [UpcomingRenewal]]
    /// Full prices due this month in RM (other currencies excluded).
    public let total: Money
}

/// A recurring charge found in transactions that isn't tracked yet.
public struct SubscriptionSuggestion: Equatable, Sendable, Identifiable {
    public var id: String { merchantKey }
    public let merchantKey: String
    public let name: String
    public let service: SubscriptionService?
    public let amount: Money
    public let cycle: BillingCycle
    public let lastCharge: Date
    public let nextExpected: Date
    public let occurrences: Int
}

/// Subscription maths and matching. Pure functions over value types; every money figure is
/// exact integer sen.
public struct SubscriptionEngine: Sendable {
    public var calendar: KLCalendar
    public var ledger: LedgerCalculator
    /// Days ahead considered "upcoming".
    public var upcomingWindowDays: Int

    public init(calendar: KLCalendar = .shared, ledger: LedgerCalculator = LedgerCalculator(), upcomingWindowDays: Int = 30) {
        self.calendar = calendar
        self.ledger = ledger
        self.upcomingWindowDays = upcomingWindowDays
    }

    // MARK: Cost

    /// The user's share of one charge (family plans split evenly; remainder sen rounds half-up).
    public func yourShare(_ subscription: ServiceSubscription) -> Money {
        guard subscription.shareCount > 1 else { return subscription.amount }
        return Money.rounded(major: subscription.amount.decimalValue / Decimal(subscription.shareCount), currency: subscription.amount.currency)
    }

    /// Your share normalised to one month (yearly ÷ 12, weekly × 52 ÷ 12).
    public func monthlyCost(_ subscription: ServiceSubscription) -> Money {
        Money.rounded(major: yourShare(subscription).decimalValue * subscription.cycle.periodsPerYear / 12, currency: subscription.amount.currency)
    }

    public func yearlyCost(_ subscription: ServiceSubscription) -> Money {
        Money.rounded(major: yourShare(subscription).decimalValue * subscription.cycle.periodsPerYear, currency: subscription.amount.currency)
    }

    /// Whether the subscription costs money at `date` (a trial only bills after it ends).
    public func isBilling(_ subscription: ServiceSubscription, on date: Date) -> Bool {
        switch subscription.status {
        case .active: return true
        case .trial: return (subscription.trialEndsAt ?? subscription.nextRenewal) <= date
        case .paused, .cancelled: return false
        }
    }

    // MARK: Dates

    /// For a free trial, billing starts on the trial's end date, so renewals are anchored there.
    public func billingSchedule(_ subscription: ServiceSubscription) -> ServiceSubscription {
        guard subscription.status == .trial, let trialEnd = subscription.trialEndsAt else { return subscription }
        var anchored = subscription
        anchored.nextRenewal = trialEnd
        return anchored
    }

    /// The renewal after `date`, stepping by the billing cycle (month-end days clamp: 31 Jan → 28/29 Feb).
    public func renewal(after date: Date, for subscription: ServiceSubscription) -> Date {
        step(date, by: subscription.cycle, anchorDay: calendar.calendar.component(.day, from: subscription.nextRenewal), forward: true)
    }

    /// Rolls a stale `nextRenewal` forward so it is today or later.
    public func rolledForward(_ subscription: ServiceSubscription, now: Date) -> ServiceSubscription {
        var updated = subscription
        let today = calendar.startOfDay(now)
        let anchorDay = calendar.calendar.component(.day, from: subscription.nextRenewal)
        var guardCount = 0
        while calendar.startOfDay(updated.nextRenewal) < today && guardCount < 600 {
            updated.nextRenewal = step(updated.nextRenewal, by: subscription.cycle, anchorDay: anchorDay, forward: true)
            guardCount += 1
        }
        return updated
    }

    /// Renewal dates inside `interval`.
    public func renewals(of subscription: ServiceSubscription, in interval: DateInterval) -> [Date] {
        guard subscription.isLive else { return [] }
        let anchorDay = calendar.calendar.component(.day, from: subscription.nextRenewal)
        var dates: [Date] = []
        var cursor = rolledForward(subscription, now: interval.start).nextRenewal
        var guardCount = 0
        while cursor < interval.end && guardCount < 600 {
            if cursor >= interval.start { dates.append(cursor) }
            cursor = step(cursor, by: subscription.cycle, anchorDay: anchorDay, forward: true)
            guardCount += 1
        }
        return dates
    }

    func step(_ date: Date, by cycle: BillingCycle, anchorDay: Int, forward: Bool) -> Date {
        let sign = forward ? 1 : -1
        guard let months = cycle.months else { return calendar.addingDays(7 * sign, to: date) }
        let moved = calendar.addingMonths(months * sign, to: date)
        // Restore the original day where the month allows (Jan 31 → Feb 28 → Mar 31).
        let monthStart = calendar.monthInterval(containing: moved).start
        let day = min(anchorDay, calendar.daysInMonth(containing: moved))
        let target = calendar.calendar.date(byAdding: .day, value: day - 1, to: monthStart)!
        let components = calendar.calendar.dateComponents([.hour, .minute], from: date)
        return calendar.calendar.date(bySettingHour: components.hour ?? 12, minute: components.minute ?? 0, second: 0, of: target)!
    }

    // MARK: Summary

    public func summary(_ subscriptions: [ServiceSubscription], now: Date) -> SubscriptionSummary {
        let base = ledger.policy.baseCurrency
        var monthly = Money.zero(base), yearly = Money.zero(base), afterTrials = Money.zero(base)
        var active = 0, trials = 0, foreign = 0
        let window = DateInterval(start: calendar.startOfDay(now), end: calendar.addingDays(upcomingWindowDays + 1, to: calendar.startOfDay(now)))
        var upcoming: [UpcomingRenewal] = []

        for subscription in subscriptions where subscription.isLive {
            if subscription.status == .trial { trials += 1 } else { active += 1 }
            guard subscription.amount.currency == base else { foreign += 1; continue }
            afterTrials += monthlyCost(subscription)
            if subscription.status == .active {
                monthly += monthlyCost(subscription)
                yearly += yearlyCost(subscription)
            }
            let schedule = billingSchedule(subscription)
            for date in renewals(of: schedule, in: window) {
                let isConversion = subscription.status == .trial && calendar.dayDistance(from: schedule.nextRenewal, to: date) == 0
                upcoming.append(UpcomingRenewal(subscriptionID: subscription.id, date: date, amount: subscription.amount, isTrialConversion: isConversion))
            }
        }
        upcoming.sort { $0.date < $1.date }
        return SubscriptionSummary(monthlyTotal: monthly, yearlyTotal: yearly, monthlyAfterTrials: afterTrials, activeCount: active, trialCount: trials,
                                   foreignCurrencyCount: foreign, upcoming: upcoming)
    }

    // MARK: Matching charges

    /// Recorded charges that belong to this subscription, newest first. Matching needs the
    /// merchant to match the service (name, catalog aliases or the user's pattern) and the
    /// amount to be within 30% of the tracked price (prices change; FX moves).
    public func matchedCharges(for subscription: ServiceSubscription, in transactions: [TransactionRecord]) -> [TransactionRecord] {
        let service = SubscriptionCatalog.service(id: subscription.serviceID)
        let patterns = ([subscription.name, subscription.matchPattern].compactMap { $0 } + (service?.aliases ?? []))
            .map { MerchantNormalizer.key($0) }.filter { $0.count >= 3 }
        return transactions.filter { record in
            guard ledger.policy.counts(record), record.direction == .outflow, record.kind == .expense,
                  record.amount.currency == subscription.amount.currency else { return false }
            if let accountID = subscription.accountID, let recordAccount = record.accountID, accountID != recordAccount { return false }
            let text = " " + SubscriptionCatalog.fullKey((record.merchant ?? "") + " " + record.transactionDescription) + " "
            guard patterns.contains(where: { text.contains(" \($0) ") || (record.merchant.map { TextSimilarity.merchant($0, subscription.name) >= 0.85 } ?? false) }) else { return false }
            let tracked = Double(subscription.amount.minorUnits), charged = Double(record.amount.minorUnits)
            return tracked == 0 || abs(charged - tracked) <= tracked * 0.3
        }
        .sorted { $0.transactionDate > $1.transactionDate }
    }

    // MARK: Alerts

    public func alerts(_ subscriptions: [ServiceSubscription], transactions: [TransactionRecord], now: Date) -> [SubscriptionAlert] {
        var alerts: [SubscriptionAlert] = []
        let today = calendar.startOfDay(now)
        let live = subscriptions.filter(\.isLive)
        // Evidence window: Kira only knows about charges the user has imported or logged.
        let statementDates = transactions.filter { $0.source.isStatement }.map(\.transactionDate)

        for subscription in live {
            let current = rolledForward(subscription, now: now)

            if subscription.status == .trial, let trialEnd = subscription.trialEndsAt {
                let days = calendar.dayDistance(from: today, to: trialEnd)
                if (0...3).contains(days) { alerts.append(SubscriptionAlert(subscriptionID: subscription.id, kind: .trialEnding(trialEnd))) }
            } else if subscription.status == .active, let lead = subscription.reminderDaysBefore {
                let days = calendar.dayDistance(from: today, to: current.nextRenewal)
                if (0...max(lead, 0)).contains(days) { alerts.append(SubscriptionAlert(subscriptionID: subscription.id, kind: .renewsSoon(current.nextRenewal))) }
            }

            let charges = matchedCharges(for: subscription, in: transactions)
            if let latest = charges.first, latest.amount != subscription.amount, latest.transactionDate > subscription.updatedAt {
                alerts.append(SubscriptionAlert(subscriptionID: subscription.id, kind: .priceChanged(from: subscription.amount, to: latest.amount)))
            }

            // "No recent charge" only when statements cover the period after the expected charge,
            // so users who don't import statements are never nagged.
            if subscription.status == .active {
                let expected = step(current.nextRenewal, by: subscription.cycle, anchorDay: calendar.calendar.component(.day, from: subscription.nextRenewal), forward: false)
                let graceEnd = calendar.addingDays(5, to: expected)
                let covered = statementDates.contains { $0 > graceEnd }
                let charged = charges.contains { abs(calendar.dayDistance(from: $0.transactionDate, to: expected)) <= 5 }
                if expected > subscription.startDate && expected < today && covered && !charged {
                    alerts.append(SubscriptionAlert(subscriptionID: subscription.id, kind: .noRecentCharge(expected: expected)))
                }
            }
        }

        let grouped = Dictionary(grouping: live.filter { $0.serviceID != nil }, by: { $0.serviceID! })
        for group in grouped.values where group.count > 1 {
            let sorted = group.sorted { $0.createdAt < $1.createdAt }
            for later in sorted.dropFirst() {
                alerts.append(SubscriptionAlert(subscriptionID: later.id, kind: .duplicate(otherID: sorted[0].id)))
            }
        }
        return alerts
    }

    // MARK: Suggestions

    /// Recurring charges in the transaction history that look like subscriptions and aren't
    /// tracked. Known services need 2 charges; anything else needs 3 at a steady cadence.
    public func suggestions(transactions: [TransactionRecord], existing: [ServiceSubscription]) -> [SubscriptionSuggestion] {
        let analytics = AnalyticsEngine(ledger: ledger, calendar: calendar)
        let tracked = existing.filter { $0.status != .cancelled }
        let trackedServices = Set(tracked.compactMap(\.serviceID))
        let trackedKeys = Set(tracked.map { MerchantNormalizer.key($0.name) })
        let alreadyMatched = Set(tracked.flatMap { matchedCharges(for: $0, in: transactions).map(\.id) })

        var results: [SubscriptionSuggestion] = []
        for charge in analytics.recurringCharges(transactions, minimumOccurrences: 2) where charge.cadenceDays >= 28 {
            let service = SubscriptionCatalog.match(charge.displayName) ?? SubscriptionCatalog.match(charge.merchantKey)
            if service == nil && charge.occurrences < 3 { continue }
            if let service, trackedServices.contains(service.id) { continue }
            if trackedKeys.contains(charge.merchantKey) { continue }
            let merchantCharges = transactions.filter { MerchantNormalizer.key($0.merchant ?? $0.transactionDescription) == charge.merchantKey }
            if merchantCharges.contains(where: { alreadyMatched.contains($0.id) }) { continue }
            // Only things that behave like subscriptions: catalog services or the Subscriptions category.
            let looksLikeSubscription = service != nil || transactions.contains {
                MerchantNormalizer.key($0.merchant ?? $0.transactionDescription) == charge.merchantKey && $0.categoryID == BuiltInCategory.subscriptions.id
            }
            guard looksLikeSubscription else { continue }
            let cycle: BillingCycle
            switch charge.cadenceDays {
            case 91: cycle = .quarterly
            case 365: cycle = .yearly
            default: cycle = .monthly
            }
            results.append(SubscriptionSuggestion(merchantKey: charge.merchantKey, name: service?.name ?? charge.displayName, service: service,
                                                  amount: charge.typicalAmount, cycle: cycle, lastCharge: charge.lastDate,
                                                  nextExpected: charge.nextExpectedDate, occurrences: charge.occurrences))
        }
        return results.sorted { $0.amount.minorUnits > $1.amount.minorUnits }
    }

    /// Turns a suggestion into a subscription the user can confirm.
    public func subscription(from suggestion: SubscriptionSuggestion, now: Date) -> ServiceSubscription {
        let draft = ServiceSubscription(name: suggestion.name, serviceID: suggestion.service?.id, amount: suggestion.amount, cycle: suggestion.cycle,
                                        nextRenewal: suggestion.nextExpected, startDate: suggestion.lastCharge,
                                        categoryID: suggestion.service?.categoryID ?? BuiltInCategory.subscriptions.id,
                                        billedThroughApple: suggestion.service?.billedThroughAppleByDefault ?? false,
                                        createdAt: now, updatedAt: now)
        return rolledForward(draft, now: now)
    }

    // MARK: History

    /// Spending to date. `recorded` is the sum of matched charges Kira has seen; when there are
    /// none, `estimated` counts renewals since the start date at the current price instead.
    public func totalSpent(for subscription: ServiceSubscription, transactions: [TransactionRecord], now: Date) -> SpendTotal {
        let charges = matchedCharges(for: subscription, in: transactions)
        if !charges.isEmpty {
            let first = charges.map(\.transactionDate).min() ?? subscription.startDate
            return SpendTotal(amount: charges.map(\.amount).sum(currency: subscription.amount.currency), since: first,
                              chargeCount: charges.count, isEstimate: false)
        }
        guard subscription.status != .trial else {
            return SpendTotal(amount: .zero(subscription.amount.currency), since: subscription.startDate, chargeCount: 0, isEstimate: true)
        }
        let end = subscription.status == .cancelled ? (subscription.cancelledAt ?? now) : now
        let past = pastRenewals(of: subscription, from: subscription.startDate, through: end)
        return SpendTotal(amount: subscription.amount.multiplied(by: Decimal(past.count)), since: subscription.startDate,
                          chargeCount: past.count, isEstimate: true)
    }

    /// Most recent charge: a matched transaction if there is one, else the last expected renewal.
    public func lastBilled(_ subscription: ServiceSubscription, transactions: [TransactionRecord], now: Date) -> (date: Date, isEstimate: Bool)? {
        if let charge = matchedCharges(for: subscription, in: transactions).first { return (charge.transactionDate, false) }
        guard subscription.status != .trial else { return nil }
        let end = subscription.status == .cancelled ? min(subscription.cancelledAt ?? now, now) : now
        return pastRenewals(of: subscription, from: subscription.startDate, through: end).last.map { ($0, true) }
    }

    /// Expected renewal dates in `[from, through]`, walking back from the next renewal.
    func pastRenewals(of subscription: ServiceSubscription, from start: Date, through end: Date) -> [Date] {
        let anchorDay = calendar.calendar.component(.day, from: subscription.nextRenewal)
        var cursor = rolledForward(subscription, now: end).nextRenewal
        var dates: [Date] = []
        var guardCount = 0
        while guardCount < 600 {
            cursor = step(cursor, by: subscription.cycle, anchorDay: anchorDay, forward: false)
            guard calendar.startOfDay(cursor) >= calendar.startOfDay(start) else { break }
            if cursor <= end { dates.append(cursor) }
            guardCount += 1
        }
        return dates.reversed()
    }

    /// Recorded subscription spending per calendar month (matched charges only — no estimates),
    /// oldest first, for the trend chart.
    public func monthlySpend(_ subscriptions: [ServiceSubscription], transactions: [TransactionRecord], endingAt date: Date, months: Int) -> [MonthlyAmount] {
        let base = ledger.policy.baseCurrency
        let charges = Dictionary(subscriptions.flatMap { matchedCharges(for: $0, in: transactions) }.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
            .values.filter { $0.amount.currency == base }
        var points: [MonthlyAmount] = []
        var interval = calendar.monthInterval(containing: date)
        for _ in 0..<max(months, 1) {
            let total = charges.filter { interval.contains($0.transactionDate) && $0.transactionDate < interval.end }.map(\.amount).sum(currency: base)
            points.insert(MonthlyAmount(monthStart: interval.start, amount: total), at: 0)
            interval = calendar.previousMonthInterval(before: interval.start)
        }
        return points
    }

    // MARK: Calendar

    /// Renewals in the calendar month containing `date`, grouped by day, with the month's total.
    public func calendarMonth(_ subscriptions: [ServiceSubscription], containing date: Date) -> RenewalCalendarMonth {
        let base = ledger.policy.baseCurrency
        let month = calendar.monthInterval(containing: date)
        var byDay: [Date: [UpcomingRenewal]] = [:]
        var total = Money.zero(base)
        for subscription in subscriptions where subscription.isLive {
            let schedule = billingSchedule(subscription)
            for renewal in renewals(of: schedule, in: month) {
                let day = calendar.startOfDay(renewal)
                let isConversion = subscription.status == .trial && calendar.dayDistance(from: schedule.nextRenewal, to: renewal) == 0
                byDay[day, default: []].append(UpcomingRenewal(subscriptionID: subscription.id, date: renewal, amount: subscription.amount, isTrialConversion: isConversion))
                if subscription.amount.currency == base { total += subscription.amount }
            }
        }
        return RenewalCalendarMonth(month: month, renewalsByDay: byDay, total: total)
    }

    // MARK: Forecasting

    /// Represents a live subscription as a commitment so cash-flow forecasts include it.
    /// Trials start at their first paid charge; foreign-currency plans are skipped.
    public func commitment(for subscription: ServiceSubscription) -> Commitment? {
        guard subscription.isLive, subscription.amount.currency == ledger.policy.baseCurrency else { return nil }
        let subscription = billingSchedule(subscription)
        let day = calendar.calendar.component(.day, from: subscription.nextRenewal)
        let recurrence: Recurrence
        switch subscription.cycle {
        case .weekly: recurrence = .weekly(weekday: calendar.calendar.component(.weekday, from: subscription.nextRenewal))
        case .monthly: recurrence = .monthly(day: day)
        case .yearly: recurrence = .yearly(month: calendar.calendar.component(.month, from: subscription.nextRenewal), day: day)
        case .quarterly: recurrence = .everyMonths(3, day: day)
        case .everyMonths(let months): recurrence = .everyMonths(months, day: day)
        }
        let start = subscription.nextRenewal
        return Commitment(id: subscription.id, name: subscription.name, type: .subscription, amount: subscription.amount,
                          recurrence: recurrence, startDate: calendar.startOfDay(start), accountID: subscription.accountID,
                          categoryID: subscription.categoryID)
    }
}
