import XCTest
@testable import KiraCore

final class DateParserTests: XCTestCase {
    let parser = MalaysianDateParser()
    let cal = KLCalendar.shared.calendar

    func ymd(_ date: Date?) -> [Int]? {
        guard let date else { return nil }
        let c = cal.dateComponents([.year, .month, .day], from: date)
        return [c.year!, c.month!, c.day!]
    }

    func testDayFirstFormats() {
        XCTAssertEqual(ymd(parser.parse("03/04/2025")), [2025, 4, 3])
        XCTAssertEqual(ymd(parser.parse("3/4/25")), [2025, 4, 3])
        XCTAssertEqual(ymd(parser.parse("03-04-2025")), [2025, 4, 3])
        XCTAssertEqual(ymd(parser.parse("03.04.2025")), [2025, 4, 3])
        XCTAssertEqual(ymd(parser.parse("2025-04-03")), [2025, 4, 3])
        XCTAssertEqual(ymd(parser.parse("03 Apr 2025")), [2025, 4, 3])
        XCTAssertEqual(ymd(parser.parse("03-APR-25")), [2025, 4, 3])
        XCTAssertEqual(ymd(parser.parse("20250403")), [2025, 4, 3])
    }

    func testMalayMonths() {
        XCTAssertEqual(ymd(parser.parse("15 Ogos 2025")), [2025, 8, 15])
        XCTAssertEqual(ymd(parser.parse("1 Mac 2025")), [2025, 3, 1])
        XCTAssertEqual(ymd(parser.parse("25 Dis 2024")), [2024, 12, 25])
        XCTAssertEqual(ymd(parser.parse("10 Mei 2025")), [2025, 5, 10])
    }

    func testTimeComponent() throws {
        let date = try XCTUnwrap(parser.parse("12 Oct 2025, 2:32 PM"))
        XCTAssertEqual(cal.component(.hour, from: date), 14)
        XCTAssertEqual(cal.component(.minute, from: date), 32)
        XCTAssertEqual(cal.component(.hour, from: try XCTUnwrap(parser.parse("12/10/2025 08:15"))), 8)
    }

    func testYearInferenceForStatementLines() {
        let january = MalaysianDateParser(referenceDate: KLCalendar.shared.date(2026, 1, 10))
        XCTAssertEqual(ymd(january.parse("28 DEC")), [2025, 12, 28])
        XCTAssertEqual(ymd(january.parse("05 JAN")), [2026, 1, 5])
        XCTAssertNil(MalaysianDateParser().parse("12 OCT")) // no reference → refuse to guess
        XCTAssertNil(january.parse("12/10")) // numeric without year is ambiguous
    }

    func testInvalidDates() {
        XCTAssertNil(parser.parse("31/02/2025"))
        XCTAssertNil(parser.parse("00/01/2025"))
        XCTAssertNil(parser.parse("13/13/2025"))
        XCTAssertNil(parser.parse("Opening Balance"))
        XCTAssertNil(parser.parse(""))
    }

    func testLeapYear() {
        XCTAssertEqual(ymd(parser.parse("29/02/2024")), [2024, 2, 29])
        XCTAssertNil(parser.parse("29/02/2025"))
    }
}

final class CSVReaderTests: XCTestCase {
    func testQuotedFieldsAndNewlines() {
        let rows = CSVReader.rows("a,b,c\r\n\"1,000.00\",\"say \"\"hi\"\"\",\"multi\nline\"\r\n")
        XCTAssertEqual(rows.count, 2)
        XCTAssertEqual(rows[1], ["1,000.00", "say \"hi\"", "multi\nline"])
    }

    func testBOMAndDelimiterDetection() {
        let rows = CSVReader.rows("\u{FEFF}Date;Amount\n01/10/2025;12,50\n")
        XCTAssertEqual(rows, [["Date", "Amount"], ["01/10/2025", "12,50"]])
        XCTAssertEqual(CSVReader.rows("a\tb\n1\t2")[1], ["1", "2"])
    }

    func testBlankLinesSkipped() {
        XCTAssertEqual(CSVReader.rows("a,b\n\n\n1,2\n").count, 2)
    }
}

final class CSVStatementImporterTests: XCTestCase {
    let importer = CSVStatementImporter()
    let savings = Account(name: "Synthetic Savings", type: .savings, institution: .maybank)

    func context(_ profileID: String, account: Account) -> ImportContext {
        ImportContext(account: account, profile: ImportProfile.profile(id: profileID)!, source: .bankStatementCSV,
                      statementDate: TestData.date(2025, 10, 31), now: TestData.date(2025, 11, 1))
    }

    func testBankDebitCreditStatement() throws {
        let result = try importer.parse(try TestData.fixture("synthetic_bank_debit_credit.csv"), context: context("maybank", account: savings))
        // Opening/closing balance lines and preamble are skipped, not imported.
        XCTAssertEqual(result.transactions.count, 10)
        XCTAssertTrue(result.skipped.contains { $0.reason == "Balance or summary line" })

        func find(_ text: String) -> TransactionRecord? { result.transactions.first { $0.transactionDescription.contains(text) } }
        let grocer = try XCTUnwrap(find("JAYA GROCER"))
        XCTAssertEqual(grocer.amount, TestData.rm("152.30"))
        XCTAssertEqual(grocer.direction, .outflow)
        XCTAssertEqual(grocer.kind, .expense)
        XCTAssertEqual(grocer.categoryID, BuiltInCategory.groceries.id)

        let zus = try XCTUnwrap(find("ZUS"))
        XCTAssertEqual(zus.channel, .duitNowQR)
        XCTAssertNotNil(zus.postingDate)

        XCTAssertEqual(find("SALARY")?.kind, .income)
        XCTAssertEqual(find("SALARY")?.amount, TestData.rm("6200.00"))
        XCTAssertEqual(find("OWN ACCOUNT")?.kind, .transfer)
        XCTAssertEqual(find("TNG EWALLET RELOAD")?.kind, .walletTopUp)
        XCTAssertEqual(find("REFUND")?.kind, .refund)
        XCTAssertEqual(find("SMS ALERT FEE")?.kind, .fee)

        // Two identical parking rows are distinct transactions with distinct fingerprints.
        let parking = result.transactions.filter { $0.transactionDescription.contains("PARKING") }
        XCTAssertEqual(parking.count, 2)
        XCTAssertNotEqual(parking[0].importFingerprint, parking[1].importFingerprint)

        let summary = LedgerCalculator().summarize(result.transactions)
        // 152.30 + 12.90 + 80.00 + 2.00 + 2.00 + 0.20 − 45.00 refund
        XCTAssertEqual(summary.netSpending, TestData.rm("204.40"))
        XCTAssertEqual(summary.income, TestData.rm("6200.00"))
        XCTAssertEqual(summary.walletTopUps, TestData.rm("100.00"))
        XCTAssertEqual(summary.transfersOut, TestData.rm("1000.00"))
    }

    func testReimportProducesSameFingerprints() throws {
        let text = try TestData.fixture("synthetic_bank_debit_credit.csv")
        let first = try importer.parse(text, context: context("maybank", account: savings))
        let second = try importer.parse(text, context: context("maybank", account: savings))
        XCTAssertEqual(first.transactions.map(\.importFingerprint), second.transactions.map(\.importFingerprint))
        let plan = ReconciliationEngine().plan(incoming: second.transactions, existing: first.transactions)
        XCTAssertTrue(plan.allSatisfy { if case .exactDuplicate = $0.disposition { return true } else { return false } })
    }

    func testEWalletSkipsFailedTransactions() throws {
        let wallet = Account(name: "TNG", type: .eWallet, institution: .touchNGo)
        let result = try importer.parse(try TestData.fixture("synthetic_ewallet.csv"), context: context("tng", account: wallet))
        XCTAssertEqual(result.transactions.count, 3)
        XCTAssertTrue(result.skipped.contains { $0.reason.hasPrefix("Transaction status") })
        let familyMart = try XCTUnwrap(result.transactions.first { $0.transactionDescription.contains("FAMILYMART") })
        XCTAssertEqual(familyMart.direction, .outflow)
        XCTAssertEqual(familyMart.amount, TestData.rm("8.50"))
        XCTAssertEqual(familyMart.externalReference, "TNG20251012001")
        XCTAssertEqual(familyMart.channel, .eWallet)
        let reload = try XCTUnwrap(result.transactions.first { $0.amount == TestData.rm("50.00") })
        XCTAssertEqual(reload.direction, .inflow)
        XCTAssertEqual(reload.kind, .transfer)
        XCTAssertEqual(result.transactions.first { $0.transactionDescription.contains("PLUS") }?.categoryID, BuiltInCategory.tolls.id)
    }

    func testCreditCardSignConvention() throws {
        let card = Account(name: "Card", type: .creditCard, institution: .maybank)
        let result = try importer.parse(try TestData.fixture("synthetic_credit_card.csv"), context: context("generic", account: card))
        XCTAssertEqual(result.transactions.count, 5)
        let payment = try XCTUnwrap(result.transactions.first { $0.transactionDescription.contains("PAYMENT") })
        XCTAssertEqual(payment.direction, .inflow)
        XCTAssertEqual(payment.kind, .creditCardRepayment)
        XCTAssertEqual(result.transactions.first { $0.transactionDescription == "LATE CHARGE" }?.kind, .fee)
        XCTAssertEqual(result.transactions.first { $0.transactionDescription.hasPrefix("REVERSAL") }?.kind, .reversal)
        let summary = LedgerCalculator().summarize(result.transactions)
        // 18.50 + 55.00 + 10.00 − 18.50 reversal; the RM 500 repayment is not spending or income.
        XCTAssertEqual(summary.netSpending, TestData.rm("65.00"))
        XCTAssertEqual(summary.income, .zero())
    }

    func testUnsupportedLayoutsFailClearly() {
        XCTAssertThrowsError(try importer.parse("foo,bar\n1,2\n", context: context("generic", account: savings))) {
            XCTAssertEqual($0 as? StatementImportError, .noHeaderRow)
        }
        XCTAssertThrowsError(try importer.parse("Date,Description,Amount\nnot a date,x,1.00\n", context: context("generic", account: savings))) {
            XCTAssertEqual($0 as? StatementImportError, .noTransactions)
        }
    }

    func testUnreadableAmountSkippedNotGuessed() throws {
        let csv = "Date,Description,Amount\n01/10/2025,GOOD ROW,-10.00\n02/10/2025,BAD ROW,-1O.OO\n"
        let result = try importer.parse(csv, context: context("generic", account: savings))
        XCTAssertEqual(result.transactions.count, 1)
        XCTAssertEqual(result.skipped.first?.reason, "Unreadable amount")
    }
}

final class StatementTextParserTests: XCTestCase {
    func testParsesTextStatementWithMarkersAndBalances() throws {
        let account = Account(name: "Synthetic", type: .savings)
        let context = ImportContext(account: account, profile: ImportProfile.profile(id: "generic")!, source: .bankStatementPDF,
                                    statementDate: TestData.date(2025, 10, 31), now: TestData.date(2025, 11, 1))
        let result = try StatementTextParser().parse(try TestData.fixture("synthetic_statement_text.txt"), context: context)
        XCTAssertEqual(result.transactions.count, 5)

        let lotus = result.transactions[0]
        XCTAssertEqual(lotus.amount, TestData.rm("45.50"))
        XCTAssertEqual(lotus.direction, .outflow)
        XCTAssertTrue(lotus.transactionDescription.contains("LOTUSS"), "continuation line appended")
        XCTAssertEqual(lotus.categoryID, BuiltInCategory.groceries.id)

        XCTAssertEqual(result.transactions[1].categoryID, BuiltInCategory.restaurants.id)
        XCTAssertEqual(result.transactions[2].direction, .inflow)

        // No marker: direction inferred from running balance change.
        let tnb = result.transactions[3]
        XCTAssertEqual(tnb.direction, .outflow)
        XCTAssertEqual(tnb.channel, .fpx)
        XCTAssertFalse(tnb.flags.contains(.directionUncertain))
        let transferIn = result.transactions[4]
        XCTAssertEqual(transferIn.direction, .inflow)
        XCTAssertFalse(transferIn.transactionDescription.contains("Page"), "page footer not appended")
    }

    func testUncertainDirectionFlagged() throws {
        let context = ImportContext(account: nil, profile: ImportProfile.profile(id: "generic")!, source: .bankStatementPDF, now: TestData.date(2025, 11, 1))
        let result = try StatementTextParser().parse("01/10/2025 MYSTERY ITEM 25.00\n", context: context)
        XCTAssertTrue(result.transactions[0].flags.contains(.directionUncertain))
        XCTAssertFalse(result.warnings.isEmpty)
    }

    func testReferenceNumbersNotMistakenForAmounts() throws {
        let context = ImportContext(account: nil, profile: ImportProfile.profile(id: "generic")!, source: .bankStatementPDF, now: TestData.date(2025, 11, 1))
        let result = try StatementTextParser().parse("02/10/2025 IBG 20251002123456 PAYMENT 75.00-\n", context: context)
        XCTAssertEqual(result.transactions.first?.amount, TestData.rm("75.00"))
    }
}
