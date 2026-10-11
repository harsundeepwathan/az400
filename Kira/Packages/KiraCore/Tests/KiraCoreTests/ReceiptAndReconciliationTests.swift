import XCTest
@testable import KiraCore

final class ReceiptTextExtractorTests: XCTestCase {
    let extractor = ReceiptTextExtractor()

    /// SYNTHETIC: shaped like a typical bank-app DuitNow QR success screen.
    let duitNowReceipt = [
        "Payment Successful", "RM 23.40", "DuitNow QR", "Recipient", "RESTORAN SYNTHETIC", "Reference ID",
        "M1234567890ABC", "Date & Time", "12 Oct 2025, 2:32 PM", "From Savings Account-i", "Synthetic Bank"
    ].map { OCRLine($0, confidence: 0.98) }

    func testExtractsDuitNowReceipt() throws {
        let result = extractor.extract(duitNowReceipt)
        XCTAssertEqual(result.amount, TestData.rm("23.40"))
        XCTAssertEqual(result.status, .successful)
        XCTAssertEqual(result.channel, .duitNowQR)
        XCTAssertEqual(result.counterparty, "RESTORAN SYNTHETIC")
        XCTAssertEqual(result.reference, "M1234567890ABC")
        let date = try XCTUnwrap(result.date)
        XCTAssertEqual(KLCalendar.shared.calendar.component(.hour, from: date), 14)
        XCTAssertGreaterThan(result.confidence, 0.7)
    }

    func testPrefersLabelledAmountOverBalance() {
        let lines = ["Transfer Successful", "Available Balance RM 1,250.00", "Amount", "RM 80.00", "Transfer to: AHMAD BIN ALI", "Ref No: 2025101200123"].map { OCRLine($0) }
        let result = extractor.extract(lines)
        XCTAssertEqual(result.amount, TestData.rm("80.00"))
        XCTAssertEqual(result.counterparty, "AHMAD BIN ALI")
        XCTAssertEqual(result.reference, "2025101200123")
    }

    func testRepairsCommonOCRErrors() {
        let lines = [OCRLine("Payment Successful"), OCRLine("Total Amount"), OCRLine("RM1O.5O", confidence: 0.6)]
        let result = extractor.extract(lines)
        XCTAssertEqual(result.amount, TestData.rm("10.50"))
        XCTAssertLessThanOrEqual(result.amountConfidence, 0.6)
    }

    func testFailedPaymentNotUsable() {
        let lines = ["Transaction Unsuccessful", "RM 15.00", "Merchant: GRAB"].map { OCRLine($0) }
        let result = extractor.extract(lines)
        XCTAssertEqual(result.status, .failed)
        XCTAssertFalse(result.isUsable)
        XCTAssertThrowsError(try ReceiptTransactionFactory.record(from: result, accountID: nil))
    }

    func testNoAmountFound() {
        let result = extractor.extract([OCRLine("Hello"), OCRLine("Thank you for shopping")])
        XCTAssertNil(result.amount)
        XCTAssertThrowsError(try ReceiptTransactionFactory.record(from: result, accountID: nil)) {
            XCTAssertEqual($0 as? ReceiptTransactionFactory.FactoryError, .missingAmount)
        }
    }

    func testReceiptBecomesConfirmedRecord() throws {
        let record = try ReceiptTransactionFactory.record(from: extractor.extract(duitNowReceipt), accountID: nil, now: TestData.date(2025, 10, 12))
        XCTAssertEqual(record.status, .confirmed)
        XCTAssertEqual(record.source, .receiptImage)
        XCTAssertEqual(record.categoryID, BuiltInCategory.restaurants.id)
        XCTAssertEqual(record.externalReference, "M1234567890ABC")
    }
}

final class ReconciliationTests: XCTestCase {
    let engine = ReconciliationEngine()
    let account = UUID()

    func testQRDraftConfirmedByReceiptReference() throws {
        var draft = TestData.tx("23.40", on: TestData.date(2025, 10, 12, 14, 30), merchant: "Restoran Synthetic", status: .draft,
                                account: account, source: .duitNowQR, reference: "M1234567890ABC", flags: [.unconfirmedPayment], channel: .duitNowQR)
        draft.categoryID = BuiltInCategory.restaurants.id
        let receipt = TestData.tx("23.40", on: TestData.date(2025, 10, 12, 14, 32), merchant: "RESTORAN SYNTHETIC", account: account,
                                  source: .receiptImage, reference: "M1234567890ABC")
        let plan = engine.plan(incoming: [receipt], existing: [draft])
        XCTAssertEqual(plan.first?.disposition, .autoMerge(existingID: draft.id))

        let merged = engine.merge(existing: draft, incoming: receipt)
        XCTAssertEqual(merged.id, draft.id)
        XCTAssertEqual(merged.status, .confirmed)
        XCTAssertFalse(merged.flags.contains(.unconfirmedPayment))
        XCTAssertEqual(merged.channel, .duitNowQR)
        XCTAssertEqual(LedgerCalculator().summarize([merged]).netSpending, TestData.rm("23.40"))
    }

    func testShortcutPendingMatchedByStatementIsSuggestedNotAutoMerged() {
        let shortcut = TestData.tx("18.50", on: TestData.date(2025, 10, 15, 9, 0), merchant: "Starbucks", status: .pending,
                                   account: account, source: .appleShortcut, channel: .applePay)
        let statement = TestData.tx("18.50", on: TestData.date(2025, 10, 16), merchant: "STARBUCKS PAVILION KL", account: account, source: .bankStatementCSV)
        let plan = engine.plan(incoming: [statement], existing: [shortcut])
        guard case .likelyMatch(let candidate) = plan[0].disposition else { return XCTFail("\(plan[0].disposition)") }
        XCTAssertEqual(candidate.existingID, shortcut.id)
        XCTAssertTrue(candidate.reasons.contains("Same amount"))

        let merged = engine.merge(existing: shortcut, incoming: statement)
        XCTAssertEqual(merged.status, .reconciled)
        XCTAssertEqual(merged.source, .bankStatementCSV)
        XCTAssertEqual(merged.channel, .applePay, "Apple Pay channel is more specific than card")
        XCTAssertEqual(merged.merchant, "Starbucks", "cleaner name kept")
    }

    func testAmbiguousCandidatesGoToReview() {
        let a = TestData.tx("2.00", on: TestData.date(2025, 10, 9, 9), merchant: "Parking", account: account, source: .appleShortcut)
        let b = TestData.tx("2.00", on: TestData.date(2025, 10, 9, 17), merchant: "Parking", account: account, source: .manual)
        let incoming = TestData.tx("2.00", on: TestData.date(2025, 10, 9), merchant: "PARKING SS2", account: account, source: .bankStatementCSV)
        let plan = engine.plan(incoming: [incoming], existing: [a, b])
        guard case .ambiguous(let candidates) = plan[0].disposition else { return XCTFail("\(plan[0].disposition)") }
        XCTAssertEqual(candidates.count, 2)
    }

    func testDifferentAmountsNeverMatch() {
        let existing = TestData.tx("18.50", merchant: "Starbucks", account: account, source: .appleShortcut)
        let incoming = TestData.tx("18.60", merchant: "Starbucks", account: account, source: .bankStatementCSV)
        XCTAssertEqual(engine.plan(incoming: [incoming], existing: [existing])[0].disposition, .new)
    }

    func testDifferentAccountsNeverMatch() {
        let existing = TestData.tx("50.00", account: UUID(), source: .manual)
        let incoming = TestData.tx("50.00", account: UUID(), source: .bankStatementCSV)
        XCTAssertEqual(engine.plan(incoming: [incoming], existing: [existing])[0].disposition, .new)
    }

    func testOutsideDateWindowNotMatched() {
        let existing = TestData.tx("50.00", on: TestData.date(2025, 10, 1), account: account, source: .manual)
        let incoming = TestData.tx("50.00", on: TestData.date(2025, 10, 10), account: account, source: .bankStatementCSV)
        XCTAssertEqual(engine.plan(incoming: [incoming], existing: [existing])[0].disposition, .new)
    }

    func testSameStatementRowsAreNotDuplicatesOfEachOther() {
        let first = TestData.tx("2.00", merchant: "PARKING", account: account, source: .bankStatementCSV)
        let second = TestData.tx("2.00", merchant: "PARKING", account: account, source: .bankStatementCSV)
        XCTAssertEqual(engine.plan(incoming: [second], existing: [first])[0].disposition, .new)
    }

    func testMergePreservesUserCategoryAndNotes() {
        var manual = TestData.tx("40.00", category: BuiltInCategory.gifts.id, merchant: "Florist friend", account: account, source: .manual)
        manual.categoryIsUserSet = true
        manual.notes = "Birthday flowers"
        let statement = TestData.tx("40.00", category: BuiltInCategory.other.id, merchant: "SQ *BLOOMS", account: account, source: .bankStatementCSV)
        let merged = engine.merge(existing: manual, incoming: statement)
        XCTAssertEqual(merged.categoryID, BuiltInCategory.gifts.id)
        XCTAssertTrue(merged.categoryIsUserSet)
        XCTAssertEqual(merged.notes, "Birthday flowers")
    }

    func testMergeStoredMarksDuplicateSuperseded() {
        let keep = TestData.tx("10.00", account: account, source: .bankStatementCSV)
        let dup = TestData.tx("10.00", status: .pending, account: account, source: .appleShortcut)
        let (kept, superseded) = engine.mergeStored(keep: keep, duplicate: dup)
        XCTAssertEqual(superseded.status, .superseded)
        XCTAssertEqual(superseded.supersededBy, keep.id)
        XCTAssertEqual(LedgerCalculator().summarize([kept, superseded]).netSpending, TestData.rm("10.00"))
    }

    func testUnknownAmountShortcutCanStillBeSuggested() {
        let shortcut = TestData.tx("0.00", on: TestData.date(2025, 10, 15, 9), merchant: "ZUS Coffee", status: .pending,
                                   account: account, source: .appleShortcut, flags: [.amountMissing])
        let statement = TestData.tx("12.90", on: TestData.date(2025, 10, 15), merchant: "ZUS COFFEE SS15", account: account, source: .bankStatementCSV)
        let candidates = engine.candidates(for: statement, in: [shortcut])
        XCTAssertEqual(candidates.count, 1)
        let merged = engine.merge(existing: shortcut, incoming: statement)
        XCTAssertEqual(merged.amount, TestData.rm("12.90"))
        XCTAssertFalse(merged.flags.contains(.amountMissing))
    }
}
