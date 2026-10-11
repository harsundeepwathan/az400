import Foundation
import XCTest
@testable import KiraCore

/// Builders for synthetic test data. Nothing here represents a real person or account.
enum TestData {
    static let cal = KLCalendar.shared

    static func rm(_ value: String) -> Money {
        Money(major: Decimal(string: value)!, currency: .myr)!
    }

    static func date(_ y: Int, _ m: Int, _ d: Int, _ h: Int = 12, _ min: Int = 0) -> Date {
        cal.date(y, m, d, h, min)
    }

    static func tx(_ amount: String, _ direction: TransactionDirection = .outflow, _ kind: TransactionKind = .expense,
                   on date: Date = TestData.date(2025, 10, 10), category: String? = BuiltInCategory.groceries.id,
                   merchant: String? = "Test Merchant", status: TransactionStatus = .confirmed, account: UUID? = nil,
                   source: ImportSource = .manual, reference: String? = nil, flags: Set<ReviewFlag> = [],
                   linked: UUID? = nil, channel: PaymentChannel = .card) -> TransactionRecord {
        TransactionRecord(accountID: account, amount: rm(amount), direction: direction, kind: kind, merchant: merchant,
                          transactionDescription: merchant ?? "", transactionDate: date, channel: channel, categoryID: category,
                          status: status, source: source, externalReference: reference, flags: flags, linkedTransactionID: linked)
    }

    static func fixture(_ name: String) throws -> String {
        guard let url = Bundle.module.url(forResource: "Fixtures/\(name)", withExtension: nil) else {
            throw XCTSkip("Fixture \(name) missing from bundle")
        }
        return try String(contentsOf: url, encoding: .utf8)
    }
}
