import Foundation

/// User data export (PDPA access/portability). Always available regardless of subscription.
public enum DataExporter {
    public static let csvHeader = ["id", "date", "posting_date", "account", "merchant", "description", "direction", "amount", "currency",
                                   "kind", "category", "channel", "status", "source", "reference", "notes"]

    public static func csv(transactions: [TransactionRecord], accounts: [Account], categories: [CategoryDefinition]) -> String {
        let accountNames = Dictionary(accounts.map { ($0.id, $0.name) }, uniquingKeysWith: { first, _ in first })
        let categoryNames = Dictionary(categories.map { ($0.id, $0.name) }, uniquingKeysWith: { first, _ in first })
        let iso = ISO8601DateFormatter()
        iso.timeZone = KLCalendar.shared.calendar.timeZone
        iso.formatOptions = [.withInternetDateTime]

        var lines = [csvHeader.joined(separator: ",")]
        for record in transactions.sorted(by: { $0.transactionDate < $1.transactionDate }) {
            let amount = MoneyFormatter(signStyle: .never, spaceAfterSymbol: false).string(from: record.amount)
                .replacingOccurrences(of: MoneyFormatter.standard.symbol(for: record.amount.currency), with: "")
                .replacingOccurrences(of: ",", with: "")
            let fields: [String] = [
                record.id.uuidString,
                iso.string(from: record.transactionDate),
                record.postingDate.map(iso.string(from:)) ?? "",
                record.accountID.flatMap { accountNames[$0] } ?? "",
                record.merchant ?? "",
                record.transactionDescription,
                record.direction.rawValue,
                amount,
                record.amount.currency.rawValue,
                record.kind.rawValue,
                record.categoryID.flatMap { categoryNames[$0] } ?? "",
                record.channel.rawValue,
                record.status.rawValue,
                record.source.rawValue,
                record.externalReference ?? "",
                record.notes ?? ""
            ]
            lines.append(fields.map(InputSanitizer.csvSafeCell).joined(separator: ","))
        }
        return lines.joined(separator: "\r\n") + "\r\n"
    }

    public struct Snapshot: Codable, Sendable {
        public var exportedAt: Date
        public var formatVersion: Int
        public var accounts: [Account]
        public var transactions: [TransactionRecord]
        public var budgets: [Budget]
        public var commitments: [Commitment]
        public var incomes: [IncomeSource]
        public var rules: [MerchantRule]
        public var customCategories: [CategoryDefinition]
        /// Added in format 1.1; optional so older exports still decode.
        public var subscriptions: [ServiceSubscription]?

        public init(exportedAt: Date, accounts: [Account], transactions: [TransactionRecord], budgets: [Budget], commitments: [Commitment],
                    incomes: [IncomeSource], rules: [MerchantRule], customCategories: [CategoryDefinition], subscriptions: [ServiceSubscription] = []) {
            self.exportedAt = exportedAt
            self.formatVersion = 1
            self.accounts = accounts
            self.transactions = transactions
            self.budgets = budgets
            self.commitments = commitments
            self.incomes = incomes
            self.rules = rules
            self.customCategories = customCategories
            self.subscriptions = subscriptions
        }
    }

    public static func json(_ snapshot: Snapshot) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return try encoder.encode(snapshot)
    }
}
