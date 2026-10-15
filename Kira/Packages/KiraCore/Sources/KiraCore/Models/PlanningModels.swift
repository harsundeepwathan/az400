import Foundation

/// Recurrence for commitments and expected income.
public enum Recurrence: Hashable, Codable, Sendable {
    /// Every month on `day` (clamped to the month's last day, e.g. 31 → 30 Apr, 28/29 Feb).
    case monthly(day: Int)
    case weekly(weekday: Int) // 1 = Sunday … 7 = Saturday (Gregorian)
    case yearly(month: Int, day: Int)
    /// Every `months` months on `day`, counted from the start date's month (quarterly = 3).
    case everyMonths(Int, day: Int)
    case once(Date)
}

public enum CommitmentType: String, Codable, CaseIterable, Sendable {
    case mortgage, rent, carFinancing, personalLoan, creditCard, insurance, utilities, subscription, ptptn, bnpl, other

    public var displayName: String {
        switch self {
        case .mortgage: return "Mortgage"
        case .rent: return "Rent"
        case .carFinancing: return "Car financing"
        case .personalLoan: return "Personal loan"
        case .creditCard: return "Credit card"
        case .insurance: return "Insurance"
        case .utilities: return "Utilities"
        case .subscription: return "Subscription"
        case .ptptn: return "PTPTN"
        case .bnpl: return "Buy Now Pay Later"
        case .other: return "Other"
        }
    }

    /// Debt commitments pay down principal; their cash outflow is reported separately from consumption.
    public var isDebt: Bool {
        switch self {
        case .mortgage, .carFinancing, .personalLoan, .creditCard, .ptptn, .bnpl: return true
        default: return false
        }
    }
}

public enum InterestMethod: String, Codable, CaseIterable, Sendable {
    /// Reducing balance (annuity) — mortgages, most personal loans, PTPTN (ujrah approximated).
    case reducingBalance
    /// Flat rate — Malaysian hire purchase (car financing) under the Hire-Purchase Act.
    case flatRate
}

public struct DebtTerms: Hashable, Codable, Sendable {
    public var principal: Money
    /// Annual interest / profit rate as a decimal fraction (0.035 = 3.5% p.a.).
    public var annualRate: Decimal
    public var tenureMonths: Int
    public var method: InterestMethod
    public var startDate: Date
    /// Outstanding balance as last stated by the lender, if the user entered it.
    public var statedOutstanding: Money?

    public init(principal: Money, annualRate: Decimal, tenureMonths: Int, method: InterestMethod, startDate: Date, statedOutstanding: Money? = nil) {
        self.principal = principal
        self.annualRate = annualRate
        self.tenureMonths = tenureMonths
        self.method = method
        self.startDate = startDate
        self.statedOutstanding = statedOutstanding
    }
}

/// A recurring obligation (rent, loan instalment, subscription…).
public struct Commitment: Identifiable, Hashable, Codable, Sendable {
    public var id: UUID
    public var name: String
    public var type: CommitmentType
    public var amount: Money
    public var recurrence: Recurrence
    public var startDate: Date
    public var endDate: Date?
    public var accountID: UUID?
    public var categoryID: String?
    public var debtTerms: DebtTerms?
    public var isActive: Bool

    public init(id: UUID = UUID(), name: String, type: CommitmentType, amount: Money, recurrence: Recurrence,
                startDate: Date, endDate: Date? = nil, accountID: UUID? = nil, categoryID: String? = nil,
                debtTerms: DebtTerms? = nil, isActive: Bool = true) {
        self.id = id
        self.name = name
        self.type = type
        self.amount = amount
        self.recurrence = recurrence
        self.startDate = startDate
        self.endDate = endDate
        self.accountID = accountID
        self.categoryID = categoryID
        self.debtTerms = debtTerms
        self.isActive = isActive
    }
}

public enum IncomeType: String, Codable, CaseIterable, Sendable {
    case basicSalary, additionalSalary, freelance, bonus, rental, other

    public var displayName: String {
        switch self {
        case .basicSalary: return "Basic salary"
        case .additionalSalary: return "Additional salary"
        case .freelance: return "Freelance"
        case .bonus: return "Bonus"
        case .rental: return "Rental income"
        case .other: return "Other income"
        }
    }
}

/// Expected income. `expectedNet` is what lands in the account; payroll estimates are advisory.
public struct IncomeSource: Identifiable, Hashable, Codable, Sendable {
    public var id: UUID
    public var name: String
    public var type: IncomeType
    public var expectedNet: Money
    public var gross: Money?
    public var recurrence: Recurrence
    public var startDate: Date
    public var endDate: Date?
    public var accountID: UUID?
    public var isActive: Bool

    public init(id: UUID = UUID(), name: String, type: IncomeType, expectedNet: Money, gross: Money? = nil,
                recurrence: Recurrence, startDate: Date, endDate: Date? = nil, accountID: UUID? = nil, isActive: Bool = true) {
        self.id = id
        self.name = name
        self.type = type
        self.expectedNet = expectedNet
        self.gross = gross
        self.recurrence = recurrence
        self.startDate = startDate
        self.endDate = endDate
        self.accountID = accountID
        self.isActive = isActive
    }
}

public enum BudgetPeriodKind: String, Codable, CaseIterable, Sendable {
    case monthly, weekly
}

public enum RolloverPolicy: String, Codable, CaseIterable, Sendable {
    /// Each period starts fresh.
    case none
    /// Unused budget carries forward; overspending does not.
    case carryUnused
    /// Both unused budget and overspending carry forward.
    case carryAll

    public var displayName: String {
        switch self {
        case .none: return "Start fresh each period"
        case .carryUnused: return "Carry unused amount forward"
        case .carryAll: return "Carry surplus and overspend"
        }
    }
}

/// A budget for all spending (`categoryID == nil`) or one category.
public struct Budget: Identifiable, Hashable, Codable, Sendable {
    public var id: UUID
    public var categoryID: String?
    public var limit: Money
    public var period: BudgetPeriodKind
    public var rollover: RolloverPolicy
    /// Alert when this fraction of the budget is used (e.g. 0.8).
    public var alertThreshold: Double
    public var isActive: Bool

    public init(id: UUID = UUID(), categoryID: String? = nil, limit: Money, period: BudgetPeriodKind = .monthly,
                rollover: RolloverPolicy = .none, alertThreshold: Double = 0.8, isActive: Bool = true) {
        self.id = id
        self.categoryID = categoryID
        self.limit = limit
        self.period = period
        self.rollover = rollover
        self.alertThreshold = alertThreshold
        self.isActive = isActive
    }
}

/// User-created categorisation rule — layer 1 of the category engine.
public struct MerchantRule: Identifiable, Hashable, Codable, Sendable {
    public enum MatchType: String, Codable, CaseIterable, Sendable { case exact, contains, prefix }

    public var id: UUID
    public var pattern: String
    public var matchType: MatchType
    public var categoryID: String
    /// Optional kind override (e.g. mark "MAYBANK CC PAYMENT" as creditCardRepayment).
    public var kind: TransactionKind?
    /// Created automatically from a user's correction (vs. created in the rules editor).
    public var learnedFromCorrection: Bool
    public var createdAt: Date

    public init(id: UUID = UUID(), pattern: String, matchType: MatchType = .contains, categoryID: String,
                kind: TransactionKind? = nil, learnedFromCorrection: Bool = false, createdAt: Date = Date()) {
        self.id = id
        self.pattern = pattern
        self.matchType = matchType
        self.categoryID = categoryID
        self.kind = kind
        self.learnedFromCorrection = learnedFromCorrection
        self.createdAt = createdAt
    }
}
