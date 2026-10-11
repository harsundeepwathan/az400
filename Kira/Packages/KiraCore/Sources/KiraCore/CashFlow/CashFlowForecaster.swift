import Foundation

public enum ForecastConfidence: String, Sendable, Comparable {
    case low, medium, high

    public static func < (lhs: Self, rhs: Self) -> Bool {
        let order: [Self] = [.low, .medium, .high]
        return order.firstIndex(of: lhs)! < order.firstIndex(of: rhs)!
    }
}

/// One projected day. Amounts are kept separate by certainty so the UI can show
/// actual vs scheduled vs estimated rather than a single "balance".
public struct ForecastDay: Equatable, Sendable {
    public let date: Date
    public let openingBalance: Money
    public let scheduledIncome: Money
    public let scheduledOutflow: Money
    public let estimatedDiscretionary: Money
    public var closingBalance: Money { openingBalance + scheduledIncome - scheduledOutflow - estimatedDiscretionary }
    public let events: [String]
}

public struct CashFlowForecast: Equatable, Sendable {
    /// Starting liquid position: user-verified balances adjusted by transactions recorded since.
    public let startingBalance: Money
    /// Oldest verification date among included accounts.
    public let balancesVerifiedAt: Date?
    public let days: [ForecastDay]
    public let endBalance: Money
    public let lowestBalance: Money
    public let lowestBalanceDate: Date?
    public let lowBalancePeriods: [DateInterval]
    /// Amount that can be spent now without the scheduled-only projection dropping below the buffer.
    public let safeToSpend: Money
    public let safeToSpendPerDay: Money
    public let expectedIncome: Money
    public let scheduledCommitments: Money
    public let estimatedDiscretionary: Money
    public let confidence: ForecastConfidence
    /// Human-readable assumptions shown under every forecast.
    public let assumptions: [String]
    /// Accounts included in the forecast that have no balance entered.
    public let accountsMissingBalance: [UUID]
}

public struct CashFlowForecaster: Sendable {
    public struct Settings: Sendable {
        /// Keep at least this much in the bank. Used for low-balance warnings and safe-to-spend.
        public var buffer: Money
        /// Days of history used to estimate everyday discretionary spending.
        public var historyDays: Int
        public init(buffer: Money = Money(minorUnits: 20_000), historyDays: Int = 60) {
            self.buffer = buffer
            self.historyDays = historyDays
        }
    }

    public var settings: Settings
    public var calendar: KLCalendar
    public var ledger: LedgerCalculator

    public init(settings: Settings = Settings(), calendar: KLCalendar = .shared, ledger: LedgerCalculator = LedgerCalculator()) {
        self.settings = settings
        self.calendar = calendar
        self.ledger = ledger
    }

    public func forecast(asOf now: Date, through horizonEnd: Date? = nil, accounts: [Account], transactions: [TransactionRecord],
                         commitments: [Commitment], incomes: [IncomeSource], monthlyBudget: Budget? = nil,
                         categories: [CategoryDefinition] = BuiltInCategory.allDefinitions) -> CashFlowForecast {
        let currency = ledger.policy.baseCurrency
        let zero = Money.zero(currency)
        let liquidAccounts = accounts.filter { !$0.isArchived && $0.includeInForecast && !$0.type.isLiability && $0.currency == currency }
        let liquidIDs = Set(liquidAccounts.map(\.id))
        let today = calendar.startOfDay(now)
        let end = horizonEnd.map { calendar.addingDays(1, to: calendar.startOfDay($0)) } ?? calendar.monthInterval(containing: now).end
        var assumptions: [String] = []
        var confidence = ForecastConfidence.high

        // 1. Starting balance: verified balances + movements recorded after each verification.
        var starting = zero
        var missing: [UUID] = []
        var oldestVerification: Date?
        for account in liquidAccounts {
            guard let balance = account.balance, let verifiedAt = account.balanceVerifiedAt else { missing.append(account.id); continue }
            oldestVerification = min(oldestVerification ?? verifiedAt, verifiedAt)
            let since = transactions.filter {
                $0.accountID == account.id && $0.transactionDate > verifiedAt && $0.transactionDate <= now && ledger.policy.counts($0)
            }
            starting += balance + since.map(\.signedAmount).sum(currency: currency)
        }
        if liquidAccounts.isEmpty {
            assumptions.append("No bank or e-wallet balances are set up, so the forecast starts from RM 0.")
            confidence = .low
        } else if !missing.isEmpty {
            assumptions.append("\(missing.count) account(s) have no balance entered and are treated as RM 0.")
            confidence = .low
        }
        if let verified = oldestVerification {
            let age = calendar.dayDistance(from: verified, to: now)
            if age > 14 {
                confidence = min(confidence, .low)
                assumptions.append("Balances were last confirmed \(age) days ago. Kira can’t see your bank balance, so update it for a reliable forecast.")
            } else if age > 3 {
                confidence = min(confidence, .medium)
                assumptions.append("Balances were last confirmed \(age) days ago and adjusted with transactions recorded since.")
            } else {
                assumptions.append("Starts from balances you confirmed \(age == 0 ? "today" : "\(age) day(s) ago").")
            }
        }

        // 2. Scheduled events from today onward, skipping occurrences that already appear as transactions.
        let window = DateInterval(start: today, end: max(end, today))
        let counted = transactions.filter { ledger.policy.counts($0) }
        var incomeByDay: [Date: (Money, [String])] = [:]
        var outflowByDay: [Date: (Money, [String])] = [:]

        for commitment in commitments where commitment.isActive && commitment.amount.currency == currency {
            if let accountID = commitment.accountID, !liquidIDs.isEmpty, !liquidIDs.contains(accountID) { continue }
            for date in calendar.occurrences(of: commitment.recurrence, startDate: commitment.startDate, endDate: commitment.endDate, in: window) {
                if alreadyRecorded(amount: commitment.amount, direction: .outflow, near: date, now: now, in: counted) { continue }
                let day = calendar.startOfDay(date)
                let current = outflowByDay[day] ?? (zero, [])
                outflowByDay[day] = (current.0 + commitment.amount, current.1 + [commitment.name])
            }
        }
        for income in incomes where income.isActive && income.expectedNet.currency == currency {
            for date in calendar.occurrences(of: income.recurrence, startDate: income.startDate, endDate: income.endDate, in: window) {
                if alreadyRecorded(amount: income.expectedNet, direction: .inflow, near: date, now: now, in: counted) { continue }
                let day = calendar.startOfDay(date)
                let current = incomeByDay[day] ?? (zero, [])
                incomeByDay[day] = (current.0 + income.expectedNet, current.1 + [income.name])
            }
        }
        if !commitments.isEmpty { assumptions.append("Commitments are assumed to be paid on their due dates unless already recorded.") }
        if !incomes.isEmpty { assumptions.append("Expected income is assumed to arrive in full on schedule.") }

        // 3. Everyday discretionary estimate.
        let (dailyEstimate, estimateNote, estimateConfidence) = discretionaryDailyEstimate(now: now, transactions: transactions, monthlyBudget: monthlyBudget, categories: categories)
        assumptions.append(estimateNote)
        confidence = min(confidence, estimateConfidence)

        // 4. Walk the days.
        var days: [ForecastDay] = []
        var balance = starting
        var scheduledOnlyBalance = starting
        var lowestScheduledOnly = starting
        var lowest = starting
        var lowestDate: Date? = nil
        var lowPeriods: [DateInterval] = []
        var currentLowStart: Date?
        var cursor = today
        while cursor < end {
            let income = incomeByDay[cursor] ?? (zero, [])
            let outflow = outflowByDay[cursor] ?? (zero, [])
            // Today's discretionary spending is partly in transactions already; estimate from tomorrow.
            let discretionary = cursor > today ? dailyEstimate : zero
            let day = ForecastDay(date: cursor, openingBalance: balance, scheduledIncome: income.0, scheduledOutflow: outflow.0,
                                  estimatedDiscretionary: discretionary, events: outflow.1 + income.1)
            days.append(day)
            balance = day.closingBalance
            scheduledOnlyBalance = scheduledOnlyBalance + income.0 - outflow.0
            lowestScheduledOnly = min(lowestScheduledOnly, scheduledOnlyBalance)
            if balance < lowest { lowest = balance; lowestDate = cursor }
            if balance < settings.buffer {
                if currentLowStart == nil { currentLowStart = cursor }
            } else if let start = currentLowStart {
                lowPeriods.append(DateInterval(start: start, end: cursor)); currentLowStart = nil
            }
            cursor = calendar.addingDays(1, to: cursor)
        }
        if let start = currentLowStart { lowPeriods.append(DateInterval(start: start, end: end)) }

        let safe = lowestScheduledOnly - settings.buffer
        let safeToSpend = safe.isNegative ? zero : safe
        let remainingDays = max(calendar.dayDistance(from: today, to: end), 1)
        let perDay = Money(minorUnits: safeToSpend.minorUnits / Int64(remainingDays), currency: currency)

        let expectedIncome = incomeByDay.values.map(\.0).sum(currency: currency)
        let scheduled = outflowByDay.values.map(\.0).sum(currency: currency)
        let estimated = days.map(\.estimatedDiscretionary).sum(currency: currency)
        assumptions.append("Keeps a buffer of \(settings.buffer.formatted) in safe-to-spend.")
        if ledger.policy.includePending && transactions.contains(where: { $0.status == .pending }) {
            assumptions.append("Includes pending transactions that are not yet confirmed.")
        }

        return CashFlowForecast(startingBalance: starting, balancesVerifiedAt: oldestVerification, days: days, endBalance: balance,
                                lowestBalance: lowest, lowestBalanceDate: lowestDate, lowBalancePeriods: lowPeriods,
                                safeToSpend: safeToSpend, safeToSpendPerDay: perDay, expectedIncome: expectedIncome,
                                scheduledCommitments: scheduled, estimatedDiscretionary: estimated, confidence: confidence,
                                assumptions: assumptions, accountsMissingBalance: missing)
    }

    func alreadyRecorded(amount: Money, direction: TransactionDirection, near date: Date, now: Date, in transactions: [TransactionRecord]) -> Bool {
        transactions.contains {
            $0.direction == direction && $0.amount == amount && $0.transactionDate <= now &&
                abs(calendar.dayDistance(from: $0.transactionDate, to: date)) <= 3
        }
    }

    /// Average daily discretionary spending over recent complete days; falls back to the budget pace.
    func discretionaryDailyEstimate(now: Date, transactions: [TransactionRecord], monthlyBudget: Budget?, categories: [CategoryDefinition]) -> (Money, String, ForecastConfidence) {
        let currency = ledger.policy.baseCurrency
        let discretionaryIDs = Set(categories.filter(\.isDiscretionary).map(\.id))
        let today = calendar.startOfDay(now)
        let counted = transactions.filter { ledger.policy.counts($0) }
        guard let earliest = counted.map(\.transactionDate).min() else {
            if let budget = monthlyBudget {
                let perDay = Money(minorUnits: budget.limit.minorUnits / Int64(calendar.daysInMonth(containing: now)), currency: currency)
                return (perDay, "Everyday spending is estimated from your monthly budget (\(perDay.formatted)/day) because there is no history yet.", .low)
            }
            return (.zero(currency), "No spending history yet, so everyday spending is not estimated.", .low)
        }
        let historyStart = max(calendar.addingDays(-settings.historyDays, to: today), calendar.startOfDay(earliest))
        let historyDays = calendar.dayDistance(from: historyStart, to: today)
        guard historyDays >= 7 else {
            return (.zero(currency), "Less than a week of history, so everyday spending is not estimated yet.", .low)
        }
        let summary = ledger.summarize(counted, filter: TransactionFilter(dateInterval: DateInterval(start: historyStart, end: today)))
        let discretionary = summary.spendingByCategory.filter { discretionaryIDs.contains($0.key) }.map(\.value).sum(currency: currency)
        let perDay = Money(minorUnits: max(discretionary.minorUnits, 0) / Int64(historyDays), currency: currency)
        let confidence: ForecastConfidence = historyDays >= 30 ? .high : .medium
        return (perDay, "Everyday spending is estimated at \(perDay.formatted)/day from your last \(historyDays) days.", confidence)
    }
}
