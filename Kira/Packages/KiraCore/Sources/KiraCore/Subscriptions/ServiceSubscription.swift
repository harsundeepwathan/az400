import Foundation

/// How often a subscription bills.
public enum BillingCycle: Hashable, Codable, Sendable {
    case weekly
    case monthly
    case quarterly
    case yearly
    /// Every N months (e.g. 6 for half-yearly plans).
    case everyMonths(Int)

    /// Exact number of billing periods in a year.
    public var periodsPerYear: Decimal {
        switch self {
        case .weekly: return 52
        case .monthly: return 12
        case .quarterly: return 4
        case .yearly: return 1
        case .everyMonths(let months): return Decimal(12) / Decimal(max(months, 1))
        }
    }

    /// Months between charges (nil for weekly billing).
    public var months: Int? {
        switch self {
        case .weekly: return nil
        case .monthly: return 1
        case .quarterly: return 3
        case .yearly: return 12
        case .everyMonths(let months): return max(months, 1)
        }
    }

    /// Typical gap between charges in days, for matching statement history.
    public var approximateDays: Int {
        switch self {
        case .weekly: return 7
        default: return (months ?? 1) * 30
        }
    }

    public var displayName: String {
        switch self {
        case .weekly: return "Weekly"
        case .monthly: return "Monthly"
        case .quarterly: return "Every 3 months"
        case .yearly: return "Yearly"
        case .everyMonths(let months): return "Every \(months) months"
        }
    }

    /// Short suffix for prices, e.g. "/mo".
    public var shortSuffix: String {
        switch self {
        case .weekly: return "/wk"
        case .monthly: return "/mo"
        case .quarterly: return "/qtr"
        case .yearly: return "/yr"
        case .everyMonths(let months): return "/\(months) mo"
        }
    }
}

public enum ServiceSubscriptionStatus: String, Codable, CaseIterable, Sendable {
    /// Billing normally.
    case active
    /// Free trial: costs nothing until `trialEndsAt`, then bills at `amount`.
    case trial
    /// Paused by the provider or the user; not billing.
    case paused
    /// Marked as cancelled by the user. Kept for history; never counted.
    case cancelled

    public var displayName: String {
        switch self {
        case .active: return "Active"
        case .trial: return "Free trial"
        case .paused: return "Paused"
        case .cancelled: return "Cancelled"
        }
    }
}

/// A recurring service the user pays for (Netflix, Spotify, iCloud+…).
///
/// Kira never cancels or changes subscriptions with the provider. Status is what the user tells
/// Kira; charges are matched from recorded transactions as evidence, never assumed.
public struct ServiceSubscription: Identifiable, Hashable, Codable, Sendable {
    public var id: UUID
    public var name: String
    /// Catalog entry this subscription belongs to, if any (see `SubscriptionCatalog`).
    public var serviceID: String?
    /// Full price the provider charges per cycle.
    public var amount: Money
    public var cycle: BillingCycle
    /// Next date the provider is expected to charge.
    public var nextRenewal: Date
    public var startDate: Date
    public var status: ServiceSubscriptionStatus
    public var trialEndsAt: Date?
    public var cancelledAt: Date?
    public var accountID: UUID?
    public var categoryID: String
    /// People splitting a family plan, including the user. Your share = amount / shareCount.
    public var shareCount: Int
    /// Days before renewal to send a reminder (nil = no reminder).
    public var reminderDaysBefore: Int?
    /// Billed through Apple (App Store), so it's managed in Apple ID settings.
    public var billedThroughApple: Bool
    /// Extra statement text to match charges with (e.g. "GOOGLE *YOUTUBE").
    public var matchPattern: String?
    public var notes: String?
    public var createdAt: Date
    public var updatedAt: Date

    public init(id: UUID = UUID(), name: String, serviceID: String? = nil, amount: Money, cycle: BillingCycle = .monthly,
                nextRenewal: Date, startDate: Date? = nil, status: ServiceSubscriptionStatus = .active, trialEndsAt: Date? = nil,
                cancelledAt: Date? = nil, accountID: UUID? = nil, categoryID: String = BuiltInCategory.subscriptions.id,
                shareCount: Int = 1, reminderDaysBefore: Int? = 2, billedThroughApple: Bool = false, matchPattern: String? = nil,
                notes: String? = nil, createdAt: Date = Date(), updatedAt: Date = Date()) {
        precondition(!amount.isNegative, "Subscription amount is a magnitude")
        self.id = id
        self.name = name
        self.serviceID = serviceID
        self.amount = amount
        self.cycle = cycle
        self.nextRenewal = nextRenewal
        self.startDate = startDate ?? nextRenewal
        self.status = status
        self.trialEndsAt = trialEndsAt
        self.cancelledAt = cancelledAt
        self.accountID = accountID
        self.categoryID = categoryID
        self.shareCount = max(shareCount, 1)
        self.reminderDaysBefore = reminderDaysBefore
        self.billedThroughApple = billedThroughApple
        self.matchPattern = matchPattern
        self.notes = notes
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    /// Whether this subscription is (or will be) billing.
    public var isLive: Bool { status == .active || status == .trial }
}
