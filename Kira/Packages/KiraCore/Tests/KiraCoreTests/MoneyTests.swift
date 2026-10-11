import XCTest
@testable import KiraCore

final class MoneyTests: XCTestCase {
    func testDecimalConstructionIsExact() {
        XCTAssertEqual(Money(major: Decimal(string: "0.1")!)!.minorUnits, 10)
        XCTAssertEqual(Money(major: Decimal(string: "2845.60")!)!.minorUnits, 284_560)
        // 0.1 + 0.2 must be exactly 0.30 — the classic floating-point failure.
        XCTAssertEqual(TestData.rm("0.1") + TestData.rm("0.2"), TestData.rm("0.30"))
    }

    func testRejectsSubSenPrecision() {
        XCTAssertNil(Money(major: Decimal(string: "1.005")!))
    }

    func testRoundingHalfUpForDerivedValues() {
        XCTAssertEqual(Money.rounded(major: Decimal(string: "1.005")!).minorUnits, 101)
        XCTAssertEqual(Money.rounded(major: Decimal(string: "1.004")!).minorUnits, 100)
        XCTAssertEqual(TestData.rm("100.00").multiplied(by: Decimal(string: "0.18")!), TestData.rm("18.00"))
    }

    func testAllocationSumsExactly() {
        let parts = TestData.rm("100.00").allocated(into: 3)
        XCTAssertEqual(parts.map(\.minorUnits), [3334, 3333, 3333])
        XCTAssertEqual(parts.sum(), TestData.rm("100.00"))
        let negative = TestData.rm("1.00").negated.allocated(into: 3)
        XCTAssertEqual(negative.sum(), TestData.rm("1.00").negated)
    }

    func testFormattingMalaysian() {
        XCTAssertEqual(TestData.rm("2845.60").formatted, "RM 2,845.60")
        XCTAssertEqual(TestData.rm("0.05").formatted, "RM 0.05")
        XCTAssertEqual(TestData.rm("1234567.89").formatted, "RM 1,234,567.89")
        XCTAssertEqual(TestData.rm("12.00").negated.formatted, "-RM 12.00")
        XCTAssertEqual(MoneyFormatter(signStyle: .always).string(from: TestData.rm("5.00")), "+RM 5.00")
        XCTAssertEqual(MoneyFormatter.compact.string(from: TestData.rm("5000.00")), "RM 5,000")
        XCTAssertEqual(MoneyFormatter(spaceAfterSymbol: false).string(from: TestData.rm("9.90")), "RM9.90")
    }

    func testAccessibilityPhrasing() {
        XCTAssertEqual(MoneyFormatter.standard.accessibilityString(from: TestData.rm("2845.60")), "2,845 ringgit 60 sen")
        XCTAssertEqual(MoneyFormatter.standard.accessibilityString(from: TestData.rm("0.50")), "50 sen")
    }

    func testZeroExponentCurrency() {
        let yen = Money(major: 1500, currency: CurrencyCode(rawValue: "JPY"))!
        XCTAssertEqual(yen.minorUnits, 1500)
        XCTAssertEqual(yen.formatted, "JPY 1,500")
    }

    func testPercentFormatter() {
        XCTAssertEqual(PercentFormatter.string(0.18), "18%")
        XCTAssertEqual(PercentFormatter.string(0.0456, maximumFractionDigits: 1), "4.6%")
    }
}

final class AmountParserTests: XCTestCase {
    let parser = AmountParser()

    func testCommonMalaysianFormats() throws {
        XCTAssertEqual(try parser.parse("1,234.56").money.minorUnits, 123_456)
        XCTAssertEqual(try parser.parse("RM 1,234.56").money.minorUnits, 123_456)
        XCTAssertEqual(try parser.parse("RM12.50").money.minorUnits, 1250)
        XCTAssertEqual(try parser.parse("MYR 12.5").money.minorUnits, 1250)
        XCTAssertEqual(try parser.parse("12").money.minorUnits, 1200)
        XCTAssertEqual(try parser.parse(".50").money.minorUnits, 50)
    }

    func testSignConventions() throws {
        XCTAssertTrue(try parser.parse("-12.00").isNegative)
        XCTAssertTrue(try parser.parse("12.00-").isNegative)
        XCTAssertTrue(try parser.parse("(12.00)").isNegative)
        XCTAssertTrue(try parser.parse("-RM12.00").isNegative)
        let debit = try parser.parse("12.00 DR")
        XCTAssertEqual(debit.marker, .debit)
        XCTAssertTrue(debit.isNegative)
        let credit = try parser.parse("12.00CR")
        XCTAssertEqual(credit.marker, .credit)
        XCTAssertFalse(credit.isNegative)
    }

    func testRejectsInvalidInput() {
        XCTAssertThrowsError(try parser.parse(""))
        XCTAssertThrowsError(try parser.parse("12.345")) { XCTAssertEqual($0 as? AmountParser.ParseError, .tooManyDecimals) }
        XCTAssertThrowsError(try parser.parse("12a.00"))
        XCTAssertThrowsError(try parser.parse("1,23.00")) // bad grouping
        XCTAssertThrowsError(try parser.parse("US$12.00")) { XCTAssertEqual($0 as? AmountParser.ParseError, .currencyMismatch("USD")) }
        XCTAssertThrowsError(try parser.parse("99999999999.00")) { XCTAssertEqual($0 as? AmountParser.ParseError, .outOfRange) }
    }

    func testLenientDecimalCommaOnlyWhenEnabled() throws {
        XCTAssertThrowsError(try parser.parse("12,50"))
        XCTAssertEqual(try AmountParser(lenientDecimalComma: true).parse("12,50").money.minorUnits, 1250)
        // Thousands grouping is still honoured in lenient mode.
        XCTAssertEqual(try AmountParser(lenientDecimalComma: true).parse("1,250").money.minorUnits, 125_000)
    }
}
