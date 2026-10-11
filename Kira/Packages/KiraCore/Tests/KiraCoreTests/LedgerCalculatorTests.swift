import XCTest
@testable import KiraCore

final class LedgerCalculatorTests: XCTestCase {
    let ledger = LedgerCalculator()

    func testExpensesAndIncome() {
        let records = [
            TestData.tx("100.00"),
            TestData.tx("50.50", category: BuiltInCategory.coffee.id),
            TestData.tx("5000.00", .inflow, .income, category: nil)
        ]
        let summary = ledger.summarize(records)
        XCTAssertEqual(summary.netSpending, TestData.rm("150.50"))
        XCTAssertEqual(summary.income, TestData.rm("5000.00"))
        XCTAssertEqual(summary.spendingByCategory[BuiltInCategory.coffee.id], TestData.rm("50.50"))
    }

    func testRefundReducesSpendingInOriginalCategory() {
        let purchase = TestData.tx("200.00", category: BuiltInCategory.shopping.id)
        let refund = TestData.tx("80.00", .inflow, .refund, category: nil, linked: purchase.id)
        let summary = ledger.summarize([purchase, refund])
        XCTAssertEqual(summary.grossSpending, TestData.rm("200.00"))
        XCTAssertEqual(summary.refunds, TestData.rm("80.00"))
        XCTAssertEqual(summary.netSpending, TestData.rm("120.00"))
        XCTAssertEqual(summary.spendingByCategory[BuiltInCategory.shopping.id], TestData.rm("120.00"))
    }

    func testReversalCancelsCharge() {
        let charge = TestData.tx("18.50", category: BuiltInCategory.coffee.id)
        let reversal = TestData.tx("18.50", .inflow, .reversal, category: BuiltInCategory.coffee.id)
        XCTAssertEqual(ledger.summarize([charge, reversal]).netSpending, .zero())
    }

    func testCreditCardRepaymentIsNotSpending() {
        // Purchase on card, then repayment from savings: spending must be counted once.
        let cardPurchase = TestData.tx("300.00", account: UUID())
        let repaymentFromSavings = TestData.tx("300.00", .outflow, .creditCardRepayment, category: nil)
        let repaymentOnCard = TestData.tx("300.00", .inflow, .creditCardRepayment, category: nil)
        let summary = ledger.summarize([cardPurchase, repaymentFromSavings, repaymentOnCard])
        XCTAssertEqual(summary.netSpending, TestData.rm("300.00"))
        XCTAssertEqual(summary.creditCardRepayments, TestData.rm("300.00"))
        XCTAssertEqual(summary.income, .zero())
    }

    func testInternalTransferIsNeitherSpendingNorIncome() {
        let out = TestData.tx("1000.00", .outflow, .transfer, category: nil)
        let into = TestData.tx("1000.00", .inflow, .transfer, category: nil)
        let summary = ledger.summarize([out, into])
        XCTAssertEqual(summary.netSpending, .zero())
        XCTAssertEqual(summary.income, .zero())
        XCTAssertEqual(summary.transfersOut, TestData.rm("1000.00"))
        XCTAssertEqual(summary.transfersIn, TestData.rm("1000.00"))
    }

    func testWalletTopUpThenWalletSpendCountsOnce() {
        let topUp = TestData.tx("100.00", .outflow, .walletTopUp, category: nil)
        let walletSpend = TestData.tx("30.00", category: BuiltInCategory.foodDelivery.id, channel: .eWallet)
        let summary = ledger.summarize([topUp, walletSpend])
        XCTAssertEqual(summary.netSpending, TestData.rm("30.00"))
        XCTAssertEqual(summary.walletTopUps, TestData.rm("100.00"))
    }

    func testDebtPrincipalSeparateFromConsumption() {
        let instalment = TestData.tx("1200.00", .outflow, .debtRepayment, category: nil)
        let interest = TestData.tx("15.00", .outflow, .fee, category: nil)
        let summary = ledger.summarize([instalment, interest])
        XCTAssertEqual(summary.netSpending, TestData.rm("15.00"))
        XCTAssertEqual(summary.debtRepayments, TestData.rm("1200.00"))
        XCTAssertEqual(summary.spendingByCategory[BuiltInCategory.debtInterestFees.id], TestData.rm("15.00"))
        XCTAssertEqual(summary.externalCashOutflow, TestData.rm("1215.00"))
    }

    func testDraftsSupersededAndUnknownAmountsExcluded() {
        let records = [
            TestData.tx("10.00"),
            TestData.tx("99.00", status: .draft),
            TestData.tx("50.00", status: .superseded),
            TestData.tx("0.00", status: .pending, flags: [.amountMissing])
        ]
        let summary = ledger.summarize(records)
        XCTAssertEqual(summary.netSpending, TestData.rm("10.00"))
        XCTAssertEqual(summary.countedTransactions, 1)
        XCTAssertEqual(summary.excludedTransactions, 3)
    }

    func testPendingPolicy() {
        let records = [TestData.tx("10.00"), TestData.tx("20.00", status: .pending)]
        XCTAssertEqual(LedgerCalculator().summarize(records).netSpending, TestData.rm("30.00"))
        XCTAssertEqual(LedgerCalculator().summarize(records).pendingIncluded, 1)
        XCTAssertEqual(LedgerCalculator(policy: LedgerPolicy(includePending: false)).summarize(records).netSpending, TestData.rm("10.00"))
    }

    func testForeignCurrencyNotMixedIntoMYRTotals() {
        var foreign = TestData.tx("10.00")
        foreign.amount = Money(minorUnits: 1000, currency: .sgd)
        let summary = ledger.summarize([TestData.tx("5.00"), foreign])
        XCTAssertEqual(summary.netSpending, TestData.rm("5.00"))
        XCTAssertEqual(summary.excludedTransactions, 1)
    }

    func testFilterByDateAccountAndCategory() {
        let account = UUID()
        let records = [
            TestData.tx("10.00", on: TestData.date(2025, 9, 30), account: account),
            TestData.tx("20.00", on: TestData.date(2025, 10, 1, 0, 5), account: account),
            TestData.tx("40.00", on: TestData.date(2025, 10, 31, 23, 59), category: BuiltInCategory.petrol.id, account: account),
            TestData.tx("80.00", on: TestData.date(2025, 11, 1, 0, 0), account: account)
        ]
        let october = KLCalendar.shared.monthInterval(containing: TestData.date(2025, 10, 15))
        XCTAssertEqual(ledger.summarize(records, filter: TransactionFilter(dateInterval: october)).netSpending, TestData.rm("60.00"))
        XCTAssertEqual(ledger.summarize(records, filter: TransactionFilter(dateInterval: october, categoryIDs: [BuiltInCategory.petrol.id])).netSpending, TestData.rm("40.00"))
        XCTAssertEqual(ledger.summarize(records, filter: TransactionFilter(accountIDs: [UUID()])).netSpending, .zero())
    }

    func testMerchantQueryFilter() {
        let records = [TestData.tx("10.00", merchant: "ZUS Coffee"), TestData.tx("20.00", merchant: "Petronas")]
        XCTAssertEqual(ledger.summarize(records, filter: TransactionFilter(merchantQuery: "zus")).netSpending, TestData.rm("10.00"))
    }
}

final class TransferClassifierTests: XCTestCase {
    let classifier = TransferClassifier()

    func testKeywordClassification() {
        XCTAssertEqual(classifier.classify(description: "PAYMENT - THANK YOU", direction: .inflow, accountType: .creditCard).kind, .creditCardRepayment)
        XCTAssertEqual(classifier.classify(description: "TNG EWALLET RELOAD", direction: .outflow, accountType: .savings).kind, .walletTopUp)
        XCTAssertEqual(classifier.classify(description: "REFUND SHOPEE ORDER", direction: .inflow, accountType: .savings).kind, .refund)
        XCTAssertEqual(classifier.classify(description: "REVERSAL STARBUCKS", direction: .inflow, accountType: .creditCard).kind, .reversal)
        XCTAssertEqual(classifier.classify(description: "LATE CHARGE", direction: .outflow, accountType: .creditCard).kind, .fee)
        XCTAssertEqual(classifier.classify(description: "SALARY OCT", direction: .inflow, accountType: .savings).kind, .income)
        XCTAssertEqual(classifier.classify(description: "GAJI BULAN 10", direction: .inflow, accountType: .savings).kind, .income)
        XCTAssertEqual(classifier.classify(description: "PTPTN BAYARAN", direction: .outflow, accountType: .savings).kind, .debtRepayment)
        XCTAssertEqual(classifier.classify(description: "JAYA GROCER", direction: .outflow, accountType: .savings).kind, .expense)
    }

    func testDirectionMismatchFallsThrough() {
        // "REFUND" on an outflow is not a refund inflow.
        XCTAssertEqual(classifier.classify(description: "REFUND DEPOSIT", direction: .outflow, accountType: .savings).kind, .expense)
    }

    func testPairsOwnAccountTransfersUnambiguously() {
        let savings = Account(name: "Savings", type: .savings)
        let card = Account(name: "Card", type: .creditCard)
        let wallet = Account(name: "TNG", type: .eWallet, institution: .touchNGo)
        let out1 = TestData.tx("500.00", on: TestData.date(2025, 10, 5), account: savings.id)
        let in1 = TestData.tx("500.00", .inflow, .income, on: TestData.date(2025, 10, 6), account: card.id)
        let out2 = TestData.tx("50.00", on: TestData.date(2025, 10, 7), account: savings.id)
        let in2 = TestData.tx("50.00", .inflow, .income, on: TestData.date(2025, 10, 7), account: wallet.id)
        let pairs = classifier.pairTransfers([out1, in1, out2, in2], accounts: [savings, card, wallet])
        XCTAssertEqual(pairs.count, 2)
        XCTAssertEqual(pairs.first { $0.outflowID == out1.id }?.suggestedKind, .creditCardRepayment)
        XCTAssertEqual(pairs.first { $0.outflowID == out2.id }?.suggestedKind, .walletTopUp)
    }

    func testAmbiguousPairsAreNotSuggested() {
        let a = Account(name: "A", type: .savings), b = Account(name: "B", type: .current), c = Account(name: "C", type: .current)
        let out = TestData.tx("100.00", account: a.id)
        let in1 = TestData.tx("100.00", .inflow, .income, account: b.id)
        let in2 = TestData.tx("100.00", .inflow, .income, account: c.id)
        XCTAssertTrue(classifier.pairTransfers([out, in1, in2], accounts: [a, b, c]).isEmpty)
    }
}
