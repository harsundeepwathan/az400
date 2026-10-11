import XCTest
import SwiftData
import KiraCore
@testable import Kira

/// App-layer integration tests against a real in-memory SwiftData store.
/// Run in Xcode (iOS Simulator): Product › Test.
@MainActor
final class FinanceStoreTests: XCTestCase {
    var store: FinanceStore!
    var inboxDirectory: URL!

    override func setUp() async throws {
        let container = try PersistenceController.makeContainer(inMemory: true)
        inboxDirectory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        store = FinanceStore(repository: SwiftDataFinanceRepository(container: container), inbox: CaptureInbox(directory: inboxDirectory))
        store.now = { KLCalendar.shared.date(2025, 10, 20) }
        store.load()
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: inboxDirectory)
    }

    private func rm(_ s: String) -> Money { Money(major: Decimal(string: s)!)! }

    func testManualTransactionPersistsAndReloads() throws {
        let record = TransactionRecord(amount: rm("12.90"), direction: .outflow, kind: .expense, merchant: "ZUS Coffee",
                                       transactionDescription: "ZUS Coffee", transactionDate: KLCalendar.shared.date(2025, 10, 18))
        store.addManual(record)
        XCTAssertEqual(store.transaction(record.id)?.categoryID, BuiltInCategory.coffee.id)

        let reloaded = try store.repository.loadSnapshot()
        XCTAssertEqual(reloaded.transactions.first?.amount, rm("12.90"))
        XCTAssertEqual(store.summary(for: store.currentMonth).netSpending, rm("12.90"))
    }

    func testCategoryCorrectionLearnsRuleWithoutRewritingHistory() throws {
        let old = TransactionRecord(amount: rm("8.00"), direction: .outflow, kind: .expense, merchant: "Kedai Pak Ali",
                                    transactionDescription: "Kedai Pak Ali", transactionDate: KLCalendar.shared.date(2025, 10, 1),
                                    categoryID: BuiltInCategory.other.id)
        let target = TransactionRecord(amount: rm("9.00"), direction: .outflow, kind: .expense, merchant: "Kedai Pak Ali",
                                       transactionDescription: "Kedai Pak Ali", transactionDate: KLCalendar.shared.date(2025, 10, 2),
                                       categoryID: BuiltInCategory.other.id)
        store.upsert([old, target])
        var edited = target
        edited.categoryID = BuiltInCategory.restaurants.id
        store.update(edited, previous: target)

        XCTAssertEqual(store.transaction(target.id)?.categoryIsUserSet, true)
        XCTAssertEqual(store.transaction(old.id)?.categoryID, BuiltInCategory.other.id, "existing records untouched")
        XCTAssertEqual(store.rules.count, 1)

        let future = TransactionRecord(amount: rm("7.00"), direction: .outflow, kind: .expense, merchant: "KEDAI PAK ALI",
                                       transactionDescription: "KEDAI PAK ALI", transactionDate: KLCalendar.shared.date(2025, 10, 3))
        store.addManual(future)
        XCTAssertEqual(store.transaction(future.id)?.categoryID, BuiltInCategory.restaurants.id)
    }

    func testShortcutCaptureRequiresPlusAndDeduplicates() {
        let input = ShortcutTransactionInput(amountText: "RM18.50", merchant: "Starbucks", cardName: "Visa")
        store.tier = .free
        XCTAssertEqual(store.ingest(input, receivedAt: store.now()), .requiresPlus)
        store.tier = .plus
        XCTAssertEqual(store.ingest(input, receivedAt: store.now()), .saved)
        XCTAssertEqual(store.ingest(input, receivedAt: store.now().addingTimeInterval(30)), .duplicate)
        XCTAssertEqual(store.transactions.filter { $0.source == .appleShortcut }.count, 1)
        XCTAssertEqual(store.transactions.first?.status, .pending)
    }

    func testInboxKeptUntilPlusThenDrained() throws {
        let item = CaptureInboxItem(receivedAt: store.now(), input: ShortcutTransactionInput(amountText: "5.00", merchant: "Tealive"))
        try store.inbox.enqueue(item)
        store.tier = .free
        store.drainInbox()
        XCTAssertEqual(store.inbox.pending().count, 1, "not dropped on the free tier")
        store.tier = .plus
        store.drainInbox()
        XCTAssertEqual(store.inbox.pending().count, 0)
        XCTAssertEqual(store.transactions.count, 1)
    }

    func testImportReviewMergesShortcutWithStatement() {
        store.tier = .plus
        let account = Account(name: "Card", type: .creditCard)
        store.save(account: account)
        let pending = TransactionRecord(accountID: account.id, amount: rm("18.50"), direction: .outflow, kind: .expense, merchant: "Starbucks",
                                        transactionDescription: "Starbucks", transactionDate: KLCalendar.shared.date(2025, 10, 15, 9),
                                        channel: .applePay, status: .pending, source: .appleShortcut)
        store.upsert([pending])
        let statement = TransactionRecord(accountID: account.id, amount: rm("18.50"), direction: .outflow, kind: .expense,
                                          merchant: "STARBUCKS PAVILION KL", transactionDescription: "STARBUCKS PAVILION KL",
                                          transactionDate: KLCalendar.shared.date(2025, 10, 16), channel: .card, source: .bankStatementCSV,
                                          importFingerprint: "fp-1")
        let review = store.prepareReview([statement], source: .bankStatementCSV, profileID: "maybank-card", fileName: "oct.csv")
        XCTAssertEqual(review.mergeCount, 1)
        store.commit(review)

        XCTAssertEqual(store.visibleTransactions.count, 1, "counted once")
        XCTAssertEqual(store.transaction(pending.id)?.status, .reconciled)
        XCTAssertEqual(store.summary(for: store.currentMonth).netSpending, rm("18.50"))
        XCTAssertEqual(store.importsThisMonth(), 1)

        // Re-importing the same file is recognised as a duplicate.
        let again = store.prepareReview([statement], source: .bankStatementCSV, profileID: "maybank-card", fileName: "oct.csv")
        XCTAssertEqual(again.skipCount, 1)
    }

    func testFreeTierImportLimit() throws {
        store.tier = .free
        for _ in 0..<3 {
            try store.repository.recordImport(source: .bankStatementCSV, profileID: nil, fileName: "x.csv", count: 1, at: store.now())
        }
        XCTAssertFalse(store.canImport)
        store.tier = .plus
        XCTAssertTrue(store.canImport)
    }

    func testConfirmRequiresAmount() {
        let draft = TransactionRecord(amount: .zero(), direction: .outflow, kind: .expense, merchant: "Mamak",
                                      transactionDate: store.now(), status: .draft, source: .duitNowQR, flags: [.amountMissing])
        store.upsert([draft])
        store.confirm(draft)
        XCTAssertEqual(store.transaction(draft.id)?.status, .draft)
        XCTAssertNotNil(store.lastErrorMessage)
    }

    func testDeleteAllDataRemovesEverything() throws {
        store.save(account: Account(name: "A", type: .savings))
        store.upsert([TransactionRecord(amount: rm("1.00"), direction: .outflow, kind: .expense, transactionDate: store.now())])
        try store.inbox.enqueue(CaptureInboxItem(input: ShortcutTransactionInput(amountText: "1.00")))
        try store.deleteAllData()
        let snapshot = try store.repository.loadSnapshot()
        XCTAssertTrue(snapshot.transactions.isEmpty)
        XCTAssertTrue(snapshot.accounts.isEmpty)
        XCTAssertTrue(store.inbox.pending().isEmpty)
    }

    func testExportAvailableOnFreeTier() {
        store.tier = .free
        store.upsert([TransactionRecord(amount: rm("3.00"), direction: .outflow, kind: .expense, merchant: "=evil", transactionDate: store.now())])
        let csv = store.exportCSV()
        XCTAssertTrue(csv.contains("'=evil"))
        XCTAssertTrue(store.gate.isAvailable(.exportData))
    }
}
