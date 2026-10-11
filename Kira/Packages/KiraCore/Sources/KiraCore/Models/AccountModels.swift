import Foundation

public enum AccountType: String, Codable, CaseIterable, Sendable {
    case savings
    case current
    case creditCard
    case eWallet
    case cash
    case loan

    public var displayName: String {
        switch self {
        case .savings: return "Savings"
        case .current: return "Current"
        case .creditCard: return "Credit card"
        case .eWallet: return "E-wallet"
        case .cash: return "Cash"
        case .loan: return "Loan"
        }
    }

    /// Liability accounts: a positive balance means money owed.
    public var isLiability: Bool { self == .creditCard || self == .loan }
}

/// Malaysian institutions Kira has import profiles for. `other` covers anything else.
public enum Institution: String, Codable, CaseIterable, Sendable {
    case maybank, cimb, publicBank, rhb, hongLeong, ambank, bankIslam, bankMuamalat, allianceBank
    case touchNGo, grabPay, boost, shopeePay
    case other

    public var displayName: String {
        switch self {
        case .maybank: return "Maybank / MAE"
        case .cimb: return "CIMB"
        case .publicBank: return "Public Bank"
        case .rhb: return "RHB"
        case .hongLeong: return "Hong Leong Bank"
        case .ambank: return "AmBank"
        case .bankIslam: return "Bank Islam"
        case .bankMuamalat: return "Bank Muamalat"
        case .allianceBank: return "Alliance Bank"
        case .touchNGo: return "Touch ’n Go eWallet"
        case .grabPay: return "GrabPay"
        case .boost: return "Boost"
        case .shopeePay: return "ShopeePay"
        case .other: return "Other"
        }
    }

    public var isEWallet: Bool {
        switch self {
        case .touchNGo, .grabPay, .boost, .shopeePay: return true
        default: return false
        }
    }
}

/// A user-declared account. Kira never connects to the bank: balances are user-entered
/// and stamped with when they were last verified.
public struct Account: Identifiable, Hashable, Codable, Sendable {
    public var id: UUID
    public var name: String
    public var type: AccountType
    public var institution: Institution
    public var currency: CurrencyCode
    /// Last four digits or wallet nickname, used to match Shortcut "card or pass" names.
    public var lastFour: String?
    /// Names Wallet may report for this card in Shortcuts (e.g. "Maybank Visa").
    public var walletCardNames: [String]
    /// User-entered balance. For liabilities, the amount owed (positive).
    public var balance: Money?
    public var balanceVerifiedAt: Date?
    public var includeInForecast: Bool
    public var isArchived: Bool

    public init(
        id: UUID = UUID(), name: String, type: AccountType, institution: Institution = .other,
        currency: CurrencyCode = .myr, lastFour: String? = nil, walletCardNames: [String] = [],
        balance: Money? = nil, balanceVerifiedAt: Date? = nil, includeInForecast: Bool = true, isArchived: Bool = false
    ) {
        self.id = id
        self.name = name
        self.type = type
        self.institution = institution
        self.currency = currency
        self.lastFour = lastFour
        self.walletCardNames = walletCardNames
        self.balance = balance
        self.balanceVerifiedAt = balanceVerifiedAt
        self.includeInForecast = includeInForecast
        self.isArchived = isArchived
    }
}

/// Category definition. Built-ins have stable string IDs; custom categories use UUID strings.
public struct CategoryDefinition: Identifiable, Hashable, Codable, Sendable {
    public var id: String
    public var name: String
    /// SF Symbol name.
    public var symbol: String
    /// Design-system tint token name.
    public var tint: String
    public var isBuiltIn: Bool
    /// Discretionary categories feed safe-to-spend estimates; essentials do not shrink.
    public var isDiscretionary: Bool
    public var isArchived: Bool

    public init(id: String, name: String, symbol: String, tint: String, isBuiltIn: Bool, isDiscretionary: Bool, isArchived: Bool = false) {
        self.id = id
        self.name = name
        self.symbol = symbol
        self.tint = tint
        self.isBuiltIn = isBuiltIn
        self.isDiscretionary = isDiscretionary
        self.isArchived = isArchived
    }
}

public enum BuiltInCategory: String, CaseIterable, Sendable {
    case groceries, restaurants, coffee, foodDelivery, petrol, tolls, parking, publicTransport, rideHailing
    case shopping, utilities, mobileInternet, subscriptions, housing, insurance, healthcare, fitness
    case entertainment, travel, education, personalCare, gifts, debtInterestFees, transfers, other

    public var id: String { rawValue }

    public var definition: CategoryDefinition {
        let (name, symbol, tint, discretionary): (String, String, String, Bool) = {
            switch self {
            case .groceries: return ("Groceries", "cart", "green", false)
            case .restaurants: return ("Restaurants & Mamak", "fork.knife", "amber", true)
            case .coffee: return ("Coffee & Cafes", "cup.and.saucer", "amber", true)
            case .foodDelivery: return ("Food Delivery", "takeoutbag.and.cup.and.straw", "amber", true)
            case .petrol: return ("Petrol", "fuelpump", "blue", false)
            case .tolls: return ("Tolls", "road.lanes", "blue", false)
            case .parking: return ("Parking", "parkingsign", "blue", false)
            case .publicTransport: return ("Public Transport", "tram", "blue", false)
            case .rideHailing: return ("Ride Hailing", "car", "blue", true)
            case .shopping: return ("Shopping", "bag", "rose", true)
            case .utilities: return ("Utilities", "bolt", "slate", false)
            case .mobileInternet: return ("Mobile & Internet", "wifi", "slate", false)
            case .subscriptions: return ("Subscriptions", "repeat", "violet", true)
            case .housing: return ("Housing", "house", "slate", false)
            case .insurance: return ("Insurance", "shield", "slate", false)
            case .healthcare: return ("Healthcare", "cross.case", "red", false)
            case .fitness: return ("Fitness", "figure.run", "green", true)
            case .entertainment: return ("Entertainment", "ticket", "violet", true)
            case .travel: return ("Travel", "airplane", "blue", true)
            case .education: return ("Education", "book", "slate", false)
            case .personalCare: return ("Personal Care", "sparkles", "rose", true)
            case .gifts: return ("Gifts", "gift", "rose", true)
            case .debtInterestFees: return ("Debt Interest & Fees", "percent", "red", false)
            case .transfers: return ("Transfers", "arrow.left.arrow.right", "slate", false)
            case .other: return ("Other", "ellipsis.circle", "slate", true)
            }
        }()
        return CategoryDefinition(id: rawValue, name: name, symbol: symbol, tint: tint, isBuiltIn: true, isDiscretionary: discretionary)
    }

    public static var allDefinitions: [CategoryDefinition] { allCases.map(\.definition) }
}
