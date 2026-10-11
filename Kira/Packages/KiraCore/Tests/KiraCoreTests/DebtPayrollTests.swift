import XCTest
@testable import KiraCore

final class LoanCalculatorTests: XCTestCase {
    func testReducingBalanceInstalment() {
        let terms = DebtTerms(principal: TestData.rm("100000.00"), annualRate: Decimal(string: "0.04")!, tenureMonths: 360,
                              method: .reducingBalance, startDate: TestData.date(2025, 1, 1))
        XCTAssertEqual(LoanCalculator.monthlyInstalment(terms), TestData.rm("477.42"))
        let schedule = LoanCalculator.schedule(terms)
        XCTAssertEqual(schedule.count, 360)
        XCTAssertEqual(schedule.last?.balance, .zero())
        XCTAssertEqual(schedule.map(\.principal).sum(), TestData.rm("100000.00"))
        XCTAssertEqual(schedule.first?.interest, TestData.rm("333.33"))
    }

    func testFlatRateHirePurchase() {
        let terms = DebtTerms(principal: TestData.rm("50000.00"), annualRate: Decimal(string: "0.03")!, tenureMonths: 108,
                              method: .flatRate, startDate: TestData.date(2025, 1, 1))
        XCTAssertEqual(LoanCalculator.monthlyInstalment(terms), TestData.rm("587.96"))
        let schedule = LoanCalculator.schedule(terms)
        XCTAssertEqual(schedule.last?.balance, .zero())
        XCTAssertEqual(schedule.map(\.principal).sum(), TestData.rm("50000.00"))
        // Rule of 78 front-loads interest.
        XCTAssertGreaterThan(schedule[0].interest, schedule[107].interest)
        XCTAssertEqual(LoanCalculator.totalInterest(terms), schedule.map(\.interest).sum())
    }

    func testZeroRateAndOutstanding() {
        let terms = DebtTerms(principal: TestData.rm("1200.00"), annualRate: 0, tenureMonths: 12, method: .reducingBalance, startDate: TestData.date(2025, 1, 15))
        XCTAssertEqual(LoanCalculator.monthlyInstalment(terms), TestData.rm("100.00"))
        XCTAssertEqual(LoanCalculator.outstanding(terms, asOf: TestData.date(2025, 3, 20)), TestData.rm("900.00"))
        XCTAssertEqual(LoanCalculator.remainingMonths(terms, asOf: TestData.date(2025, 3, 20)), 9)
        var stated = terms
        stated.statedOutstanding = TestData.rm("950.00")
        XCTAssertEqual(LoanCalculator.outstanding(stated, asOf: TestData.date(2025, 3, 20)), TestData.rm("950.00"))
    }
}

final class PayrollEstimatorTests: XCTestCase {
    let rules = StatutoryRuleSet.malaysiaReference2024

    func testEstimateUnderCeiling() {
        let slip = PayrollEstimator.estimate(basic: TestData.rm("5000.00"), rules: rules)
        XCTAssertEqual(slip.epf, TestData.rm("550.00"))
        XCTAssertEqual(slip.socso, TestData.rm("25.00"))
        XCTAssertEqual(slip.eis, TestData.rm("10.00"))
        XCTAssertEqual(slip.pcb, .zero())
        XCTAssertEqual(slip.net, TestData.rm("4415.00"))
        XCTAssertTrue(slip.isEstimate, "reference rules are never presented as exact")
    }

    func testCeilingAndRounding() {
        let high = PayrollEstimator.estimate(basic: TestData.rm("7000.00"), rules: rules)
        XCTAssertEqual(high.socso, TestData.rm("30.00"))
        XCTAssertEqual(high.eis, TestData.rm("12.00"))
        XCTAssertEqual(PayrollEstimator.estimate(basic: TestData.rm("3333.33"), rules: rules).epf, TestData.rm("367.00"))
    }

    func testPayslipOverridesWin() {
        var verified = rules
        verified.userVerified = true
        let slip = PayrollEstimator.estimate(basic: TestData.rm("5000.00"), rules: verified,
                                             overrides: PayslipOverrides(epf: TestData.rm("550.00"), socso: TestData.rm("24.75"), eis: TestData.rm("9.90"), pcb: TestData.rm("120.50")))
        XCTAssertEqual(slip.socso, TestData.rm("24.75"))
        XCTAssertEqual(slip.net, TestData.rm("4294.85"))
        XCTAssertFalse(slip.isEstimate)
    }

    func testRuleSetVersionSelection() {
        var older = rules
        older.id = "old"
        older.effectiveFrom = TestData.date(2023, 1, 1)
        older.socsoWageCeiling = TestData.rm("5000.00")
        XCTAssertEqual(StatutoryRuleSet.applicable([older, rules], on: TestData.date(2024, 6, 1))?.id, "old")
        XCTAssertEqual(StatutoryRuleSet.applicable([older, rules], on: TestData.date(2025, 6, 1))?.id, rules.id)
        XCTAssertNil(StatutoryRuleSet.applicable([rules], on: TestData.date(2020, 1, 1)))
    }
}

final class ShortcutCaptureTests: XCTestCase {
    let processor = ShortcutCaptureProcessor()
    let card = Account(name: "Maybank Visa", type: .creditCard, institution: .maybank, lastFour: "4321", walletCardNames: ["Maybank Visa Signature"])
    let received = TestData.date(2025, 10, 15, 9, 0)

    func testCompleteInputCreatesPendingApplePayRecord() throws {
        let input = ShortcutTransactionInput(amountText: "RM18.50", merchant: "Starbucks", cardName: "Maybank Visa Signature", date: received)
        guard case .created(let record) = processor.process(input, receivedAt: received, accounts: [card], existing: []) else { return XCTFail() }
        XCTAssertEqual(record.status, .pending)
        XCTAssertEqual(record.channel, .applePay)
        XCTAssertEqual(record.source, .appleShortcut)
        XCTAssertEqual(record.amount, TestData.rm("18.50"))
        XCTAssertEqual(record.accountID, card.id)
        XCTAssertEqual(record.categoryID, BuiltInCategory.coffee.id)
        XCTAssertTrue(record.flags.contains(.unconfirmedPayment), "a tap is not a settled payment")
    }

    func testIncompleteInputIsKeptButExcludedFromTotals() throws {
        // Wallet automations sometimes deliver a blank merchant and 0.0 amount.
        let input = ShortcutTransactionInput(amountText: "0.0", merchant: "", cardName: "Card ending 4321")
        guard case .created(let record) = processor.process(input, receivedAt: received, accounts: [card], existing: []) else { return XCTFail() }
        XCTAssertTrue(record.flags.contains(.amountMissing))
        XCTAssertTrue(record.flags.contains(.merchantMissing))
        XCTAssertEqual(record.accountID, card.id, "matched by last four digits")
        XCTAssertEqual(LedgerCalculator().summarize([record]).netSpending, .zero())

        guard case .created(let empty) = processor.process(ShortcutTransactionInput(), receivedAt: received, accounts: [], existing: []) else { return XCTFail() }
        XCTAssertTrue(empty.flags.contains(.amountMissing))
        XCTAssertEqual(empty.transactionDate, received)
    }

    func testRepeatedAutomationEventIsDeduplicated() {
        let input = ShortcutTransactionInput(amountText: "12.90", merchant: "ZUS Coffee", cardName: "Maybank Visa Signature")
        guard case .created(let first) = processor.process(input, receivedAt: received, accounts: [card], existing: []) else { return XCTFail() }
        let again = processor.process(input, receivedAt: received.addingTimeInterval(20), accounts: [card], existing: [first])
        XCTAssertEqual(again, .duplicate(existingID: first.id))
        // A genuine second purchase later is not a duplicate.
        let later = processor.process(input, receivedAt: received.addingTimeInterval(3600), accounts: [card], existing: [first])
        guard case .created = later else { return XCTFail("\(later)") }
    }

    func testAmountFormatsAndForeignCurrency() {
        func amount(_ text: String) -> Money? {
            if case .created(let r) = processor.process(ShortcutTransactionInput(amountText: text, merchant: "X"), receivedAt: received, accounts: [], existing: []) { return r.amount }
            return nil
        }
        XCTAssertEqual(amount("12,50"), TestData.rm("12.50"))
        XCTAssertEqual(amount("MYR 1,234.50"), TestData.rm("1234.50"))
        XCTAssertEqual(amount("S$10.00")?.currency, .sgd)
        if case .created(let r) = processor.process(ShortcutTransactionInput(amountText: "S$10.00", merchant: "X"), receivedAt: received, accounts: [], existing: []) {
            XCTAssertTrue(r.flags.contains(.foreignCurrency))
        }
        XCTAssertEqual(processor.process(ShortcutTransactionInput(amountText: "abc"), receivedAt: received, accounts: [], existing: []), .rejected("Amount “abc” could not be read"))
    }

    func testImplausibleDatesReplaced() {
        let future = ShortcutTransactionInput(amountText: "1.00", date: received.addingTimeInterval(86_400 * 30))
        if case .created(let r) = processor.process(future, receivedAt: received, accounts: [], existing: []) {
            XCTAssertEqual(r.transactionDate, received)
        } else { XCTFail() }
    }

    func testInputSanitised() {
        let input = ShortcutTransactionInput(amountText: "5.00", merchant: "Shop\u{202E}\u{0000}Name\n\n", notes: String(repeating: "x", count: 2000))
        if case .created(let r) = processor.process(input, receivedAt: received, accounts: [], existing: []) {
            XCTAssertFalse(r.merchant!.unicodeScalars.contains { $0.properties.generalCategory == .format || $0.value < 32 })
            XCTAssertEqual(r.notes?.count, 500)
        } else { XCTFail() }
    }

    func testInboxItemRoundTrips() throws {
        let item = CaptureInboxItem(receivedAt: received, input: ShortcutTransactionInput(amountText: "9.90", merchant: "Tealive"))
        let data = try JSONEncoder().encode(item)
        XCTAssertEqual(try JSONDecoder().decode(CaptureInboxItem.self, from: data), item)
    }
}

final class SecurityTests: XCTestCase {
    func testCSVInjectionNeutralised() {
        XCTAssertEqual(InputSanitizer.csvSafeCell("=HYPERLINK(\"http://evil\")"), "\"'=HYPERLINK(\"\"http://evil\"\")\"")
        XCTAssertEqual(InputSanitizer.csvSafeCell("+cmd"), "'+cmd")
        XCTAssertEqual(InputSanitizer.csvSafeCell("@SUM(A1)"), "'@SUM(A1)")
        XCTAssertEqual(InputSanitizer.csvSafeCell("-12.50"), "-12.50")
        XCTAssertEqual(InputSanitizer.csvSafeCell("a,b"), "\"a,b\"")
    }

    func testExportIsInjectionSafe() {
        var record = TestData.tx("10.00", merchant: "=cmd|' /C calc'!A0")
        record.notes = "@evil"
        let csv = DataExporter.csv(transactions: [record], accounts: [], categories: BuiltInCategory.allDefinitions)
        XCTAssertFalse(csv.contains(",=cmd"))
        XCTAssertTrue(csv.contains("'=cmd"))
        XCTAssertTrue(csv.contains("'@evil"))
        XCTAssertTrue(csv.hasPrefix(DataExporter.csvHeader.joined(separator: ",")))
    }

    func testRedactionAndMasking() {
        XCTAssertEqual(InputSanitizer.maskAccountNumber("1234 5678 9012"), "•••• 9012")
        XCTAssertEqual(InputSanitizer.redactForLogging("IBG to 162012345678 ref 99"), "IBG to ############ ref 99")
    }

    func testFileValidator() throws {
        let validator = ImportFileValidator(maximumBytes: 1024)
        XCTAssertEqual(try validator.validate(data: Data("Date,Amount\n".utf8), fileExtension: "csv"), .csv)
        XCTAssertEqual(try validator.validate(data: Data("%PDF-1.7\n".utf8), fileExtension: "pdf"), .pdf)
        XCTAssertEqual(try validator.validate(data: Data([0xFF, 0xD8, 0xFF, 0xE0]), fileExtension: "jpg"), .image)
        XCTAssertThrowsError(try validator.validate(data: Data(), fileExtension: "csv")) { XCTAssertEqual($0 as? ImportFileValidator.ValidationError, .empty) }
        XCTAssertThrowsError(try validator.validate(data: Data(count: 2048), fileExtension: "csv")) { XCTAssertEqual($0 as? ImportFileValidator.ValidationError, .tooLarge(limitBytes: 1024)) }
        XCTAssertThrowsError(try validator.validate(data: Data("not a pdf".utf8), fileExtension: "pdf")) { XCTAssertEqual($0 as? ImportFileValidator.ValidationError, .contentMismatch(expected: .pdf)) }
        XCTAssertThrowsError(try validator.validate(data: Data([0x50, 0x4B, 0x03, 0x04, 0, 0]), fileExtension: "csv"))
        XCTAssertThrowsError(try validator.validate(data: Data("x".utf8), fileExtension: "exe"))
        XCTAssertThrowsError(try validator.validate(data: Data("x".utf8), fileExtension: "xlsx")) { error in
            guard case ImportFileValidator.ValidationError.unsupportedType = error else { return XCTFail() }
        }
    }

    func testTextDecoding() {
        let validator = ImportFileValidator()
        XCTAssertEqual(validator.decodeText(Data([0xEF, 0xBB, 0xBF] + Array("abc".utf8))), "abc")
        XCTAssertEqual(validator.decodeText(Data([0x63, 0x61, 0x66, 0xE9])), "café") // Windows-1252
        XCTAssertNil(validator.decodeText(Data([0x61, 0x00, 0x62])))
    }

    func testDataAccessNeverGated() {
        let expired = FeatureGate(tier: .free)
        for feature in [Feature.exportData, .deleteData, .viewHistory, .editTransactions, .manualTracking] {
            XCTAssertTrue(expired.isAvailable(feature), "\(feature) must stay free")
        }
        XCTAssertFalse(expired.isAvailable(.cashFlowForecast))
        XCTAssertTrue(expired.canImport(importsThisMonth: 2))
        XCTAssertFalse(expired.canImport(importsThisMonth: 3))
        XCTAssertTrue(FeatureGate(tier: .plus).canImport(importsThisMonth: 100))
        XCTAssertTrue(FeatureGate(tier: .premium).isAvailable(.shortcutsCapture))
    }

    func testSnapshotExportRoundTrip() throws {
        let snapshot = DataExporter.Snapshot(exportedAt: TestData.date(2025, 10, 1), accounts: [Account(name: "A", type: .savings)],
                                             transactions: [TestData.tx("1.00")], budgets: [], commitments: [], incomes: [], rules: [], customCategories: [])
        let data = try DataExporter.json(snapshot)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let decoded = try decoder.decode(DataExporter.Snapshot.self, from: data)
        XCTAssertEqual(decoded.transactions.first?.amount, TestData.rm("1.00"))
    }
}
