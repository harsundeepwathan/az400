import XCTest
@testable import KiraCore

final class BudgetEngineTests: XCTestCase {
    let engine = BudgetEngine()

    func testMonthlyBudgetStatus() {
        let budget = Budget(limit: TestData.rm("5000.00"))
        let records = [
            TestData.tx("2845.60", on: TestData.date(2025, 10, 5)),
            TestData.tx("1000.00", .outflow, .creditCardRepayment, on: TestData.date(2025, 10, 6), category: nil),
            TestData.tx("200.00", .outflow, .walletTopUp, on: TestData.date(2025, 10, 6), category: nil),
            TestData.tx("1500.00", .outflow, .debtRepayment, on: TestData.date(2025, 10, 7), category: nil)
        ]
        let status = engine.status(for: budget, on: TestData.date(2025, 10, 15), transactions: records)
        // Only the real expense consumes budget.
        XCTAssertEqual(status.spent, TestData.rm("2845.60"))
        XCTAssertEqual(status.remaining, TestData.rm("2154.40"))
        XCTAssertEqual(status.fractionUsed!, 0.56912, accuracy: 0.0001)
        XCTAssertEqual(status.level, .onTrack)
        // 2845.60 over 15 days → ×31/15 projected.
        XCTAssertEqual(status.projectedSpend, TestData.rm("2845.60").multiplied(by: Decimal(31) / Decimal(15)))
    }

    func testCategoryBudgetAndAlerts() {
        let budget = Budget(categoryID: BuiltInCategory.foodDelivery.id, limit: TestData.rm("300.00"), alertThreshold: 0.8)
        let near = [TestData.tx("250.00", on: TestData.date(2025, 10, 3), category: BuiltInCategory.foodDelivery.id),
                    TestData.tx("999.00", on: TestData.date(2025, 10, 3), category: BuiltInCategory.groceries.id)]
        XCTAssertEqual(engine.status(for: budget, on: TestData.date(2025, 10, 10), transactions: near).level, .nearingLimit)
        let over = near + [TestData.tx("60.00", on: TestData.date(2025, 10, 4), category: BuiltInCategory.foodDelivery.id)]
        let status = engine.status(for: budget, on: TestData.date(2025, 10, 10), transactions: over)
        XCTAssertEqual(status.level, .overBudget)
        XCTAssertEqual(status.remaining, TestData.rm("-10.00"))
    }

    func testRolloverPolicies() {
        let records = [
            TestData.tx("700.00", on: TestData.date(2025, 8, 10)),   // Aug: 300 unused
            TestData.tx("1200.00", on: TestData.date(2025, 9, 10)),  // Sep: overspend
            TestData.tx("100.00", on: TestData.date(2025, 10, 2))
        ]
        let now = TestData.date(2025, 10, 15)
        let none = engine.status(for: Budget(limit: TestData.rm("1000.00"), rollover: .none), on: now, transactions: records)
        XCTAssertEqual(none.effectiveLimit, TestData.rm("1000.00"))

        // carryUnused: Aug leaves 300 → Sep limit 1300, spent 1200 → 100 carried to Oct.
        let unused = engine.status(for: Budget(limit: TestData.rm("1000.00"), rollover: .carryUnused), on: now, transactions: records)
        XCTAssertEqual(unused.rolloverAmount, TestData.rm("100.00"))
        XCTAssertEqual(unused.effectiveLimit, TestData.rm("1100.00"))

        // carryAll with a deeper overspend.
        let heavy = [TestData.tx("1500.00", on: TestData.date(2025, 9, 10)), TestData.tx("100.00", on: TestData.date(2025, 10, 2))]
        let all = engine.status(for: Budget(limit: TestData.rm("1000.00"), rollover: .carryAll), on: now, transactions: heavy)
        XCTAssertEqual(all.rolloverAmount, TestData.rm("-500.00"))
        XCTAssertEqual(all.effectiveLimit, TestData.rm("500.00"))
        let unusedHeavy = engine.status(for: Budget(limit: TestData.rm("1000.00"), rollover: .carryUnused), on: now, transactions: heavy)
        XCTAssertEqual(unusedHeavy.rolloverAmount, .zero())
    }

    func testWeeklyBudgetUsesMondayWeeks() {
        let budget = Budget(limit: TestData.rm("200.00"), period: .weekly)
        let wed = TestData.date(2025, 10, 15) // Wednesday
        let interval = engine.period(for: budget, containing: wed)
        XCTAssertEqual(KLCalendar.shared.calendar.component(.weekday, from: interval.start), 2)
        let records = [TestData.tx("50.00", on: TestData.date(2025, 10, 12)), TestData.tx("30.00", on: TestData.date(2025, 10, 13))]
        XCTAssertEqual(engine.status(for: budget, on: wed, transactions: records).spent, TestData.rm("30.00"))
    }

    func testAllocationSummary() {
        let total = Budget(limit: TestData.rm("5000.00"))
        let cats = [Budget(categoryID: "groceries", limit: TestData.rm("800.00")), Budget(categoryID: "petrol", limit: TestData.rm("300.00"))]
        let summary = engine.allocationSummary(total: total, categoryBudgets: cats)
        XCTAssertEqual(summary.allocated, TestData.rm("1100.00"))
        XCTAssertEqual(summary.unallocated, TestData.rm("3900.00"))
    }
}

final class CashFlowForecasterTests: XCTestCase {
    let forecaster = CashFlowForecaster()

    func testForecastWithScheduledItems() {
        let now = TestData.date(2025, 10, 20, 10)
        let savings = Account(name: "Savings", type: .savings, balance: TestData.rm("3000.00"), balanceVerifiedAt: TestData.date(2025, 10, 19))
        let card = Account(name: "Card", type: .creditCard, balance: TestData.rm("800.00"), balanceVerifiedAt: now)
        let spentToday = TestData.tx("50.00", on: TestData.date(2025, 10, 20, 9), account: savings.id)
        let rent = Commitment(name: "Rent", type: .rent, amount: TestData.rm("1500.00"), recurrence: .monthly(day: 25), startDate: TestData.date(2025, 1, 1))
        let cardBill = Commitment(name: "Card bill", type: .creditCard, amount: TestData.rm("800.00"), recurrence: .monthly(day: 28), startDate: TestData.date(2025, 1, 1))
        let salary = IncomeSource(name: "Salary", type: .basicSalary, expectedNet: TestData.rm("5000.00"), recurrence: .monthly(day: 31), startDate: TestData.date(2025, 1, 1))

        let result = forecaster.forecast(asOf: now, accounts: [savings, card], transactions: [spentToday], commitments: [rent, cardBill], incomes: [salary])
        XCTAssertEqual(result.startingBalance, TestData.rm("2950.00"), "verified balance minus spending recorded since")
        XCTAssertEqual(result.scheduledCommitments, TestData.rm("2300.00"))
        XCTAssertEqual(result.expectedIncome, TestData.rm("5000.00"))
        XCTAssertEqual(result.days.count, 12) // 20…31 Oct
        // Lowest point before salary: 2950 − 1500 − 800 = 650, minus RM 200 buffer = 450.
        XCTAssertEqual(result.safeToSpend, TestData.rm("450.00"))
        XCTAssertEqual(result.endBalance, TestData.rm("5650.00"))
        XCTAssertTrue(result.assumptions.contains { $0.contains("Less than a week") })
        XCTAssertEqual(result.confidence, .low)
    }

    func testStaleAndMissingBalancesLowerConfidence() {
        let now = TestData.date(2025, 10, 20)
        let stale = Account(name: "Old", type: .savings, balance: TestData.rm("100.00"), balanceVerifiedAt: TestData.date(2025, 9, 1))
        let missing = Account(name: "Unknown", type: .current)
        let result = forecaster.forecast(asOf: now, accounts: [stale, missing], transactions: [], commitments: [], incomes: [])
        XCTAssertEqual(result.confidence, .low)
        XCTAssertEqual(result.accountsMissingBalance, [missing.id])
        XCTAssertTrue(result.assumptions.contains { $0.contains("can’t see your bank balance") })
    }

    func testAlreadyPaidCommitmentNotDoubleCounted() {
        let now = TestData.date(2025, 10, 26)
        let savings = Account(name: "S", type: .savings, balance: TestData.rm("1000.00"), balanceVerifiedAt: now)
        let rent = Commitment(name: "Rent", type: .rent, amount: TestData.rm("500.00"), recurrence: .monthly(day: 27), startDate: TestData.date(2025, 1, 1))
        let paidEarly = TestData.tx("500.00", on: TestData.date(2025, 10, 25), account: savings.id)
        let result = forecaster.forecast(asOf: now, accounts: [savings], transactions: [paidEarly], commitments: [rent], incomes: [])
        XCTAssertEqual(result.scheduledCommitments, .zero())
    }

    func testDiscretionaryEstimateFromHistoryAndLowBalancePeriods() {
        let now = TestData.date(2025, 10, 20)
        let savings = Account(name: "S", type: .savings, balance: TestData.rm("300.00"), balanceVerifiedAt: now)
        var history: [TransactionRecord] = []
        for day in 0..<40 {
            history.append(TestData.tx("30.00", on: KLCalendar.shared.addingDays(-day - 1, to: now), category: BuiltInCategory.restaurants.id))
        }
        let result = forecaster.forecast(asOf: now, accounts: [savings], transactions: history, commitments: [], incomes: [])
        XCTAssertEqual(result.estimatedDiscretionary, TestData.rm("30.00").multiplied(by: 11))
        XCTAssertFalse(result.lowBalancePeriods.isEmpty)
        XCTAssertNotNil(result.lowestBalanceDate)
        XCTAssertEqual(result.confidence, .high)
    }

    func testMonthEndClampingInRecurrence() {
        let cal = KLCalendar.shared
        let feb = DateInterval(start: cal.date(2025, 2, 1, 0), end: cal.date(2025, 3, 1, 0))
        let dates = cal.occurrences(of: .monthly(day: 31), startDate: cal.date(2024, 1, 1), endDate: nil, in: feb)
        XCTAssertEqual(dates.map { cal.calendar.component(.day, from: $0) }, [28])
    }
}

final class AnalyticsTests: XCTestCase {
    let analytics = AnalyticsEngine()
    let october = KLCalendar.shared.monthInterval(containing: TestData.date(2025, 10, 15))

    func testBreakdownAndMerchants() {
        let records = [
            TestData.tx("60.00", category: BuiltInCategory.groceries.id, merchant: "Jaya Grocer"),
            TestData.tx("40.00", category: BuiltInCategory.groceries.id, merchant: "Jaya Grocer"),
            TestData.tx("100.00", category: BuiltInCategory.petrol.id, merchant: "Petronas"),
            TestData.tx("500.00", .outflow, .transfer, category: nil, merchant: "Own account")
        ]
        let breakdown = analytics.categoryBreakdown(records, filter: TransactionFilter(dateInterval: october))
        XCTAssertEqual(breakdown.map(\.categoryID), [BuiltInCategory.groceries.id, BuiltInCategory.petrol.id])
        XCTAssertEqual(breakdown[0].share, 0.5, accuracy: 0.0001)
        let merchants = analytics.topMerchants(records, filter: TransactionFilter(dateInterval: october))
        XCTAssertEqual(merchants.first?.displayName, "Jaya Grocer")
        XCTAssertEqual(merchants.first?.count, 2)
        XCTAssertFalse(merchants.contains { $0.displayName == "Own account" })
    }

    func testWeekdayWeekendAndSavingsRate() {
        let records = [
            TestData.tx("10.00", on: TestData.date(2025, 10, 11)), // Saturday
            TestData.tx("20.00", on: TestData.date(2025, 10, 13)), // Monday
            TestData.tx("1000.00", .inflow, .income, on: TestData.date(2025, 10, 1), category: nil),
            TestData.tx("300.00", .outflow, .debtRepayment, on: TestData.date(2025, 10, 2), category: nil)
        ]
        let split = analytics.weekdayWeekend(records, filter: TransactionFilter(dateInterval: october))
        XCTAssertEqual(split.weekend, TestData.rm("10.00"))
        XCTAssertEqual(split.weekday, TestData.rm("20.00"))
        XCTAssertEqual(analytics.savingsRate(records, filter: TransactionFilter(dateInterval: october))!, 0.67, accuracy: 0.0001)
        XCTAssertNil(analytics.savingsRate([TestData.tx("1.00")], filter: TransactionFilter()))
    }

    func testRecurringDetection() {
        let cal = KLCalendar.shared
        var records: [TransactionRecord] = []
        for month in 5...10 {
            records.append(TestData.tx("55.00", on: cal.date(2025, month, 16), category: BuiltInCategory.subscriptions.id, merchant: "Netflix"))
        }
        records.append(TestData.tx("12.00", on: cal.date(2025, 10, 1), merchant: "Random Kedai"))
        records.append(TestData.tx("31.00", on: cal.date(2025, 10, 9), merchant: "Random Kedai"))
        records.append(TestData.tx("8.00", on: cal.date(2025, 10, 10), merchant: "Random Kedai"))
        let recurring = analytics.recurringCharges(records)
        XCTAssertEqual(recurring.count, 1)
        XCTAssertEqual(recurring.first?.cadenceDays, 30)
        XCTAssertEqual(recurring.first?.typicalAmount, TestData.rm("55.00"))
    }

    func testMonthlyTrendUsesSameEngine() {
        let records = [TestData.tx("100.00", on: TestData.date(2025, 9, 5)), TestData.tx("50.00", on: TestData.date(2025, 10, 5))]
        let trend = analytics.monthlyTrend(records, endingAt: TestData.date(2025, 10, 20), months: 3)
        XCTAssertEqual(trend.map(\.spending), [.zero(), TestData.rm("100.00"), TestData.rm("50.00")])
    }
}

final class InsightGeneratorTests: XCTestCase {
    func testNoInsightsWithoutEnoughData() {
        let generator = InsightGenerator()
        let insights = generator.insights(now: TestData.date(2025, 10, 20), transactions: [TestData.tx("10.00", on: TestData.date(2025, 10, 2))], commitments: [], monthlyBudget: nil)
        XCTAssertTrue(insights.isEmpty)
    }

    func testCategoryIncreaseInsight() {
        var records: [TransactionRecord] = []
        for day in 1...12 {
            records.append(TestData.tx("10.00", on: TestData.date(2025, 9, day), category: BuiltInCategory.restaurants.id, merchant: "Mamak \(day)"))
            records.append(TestData.tx("11.80", on: TestData.date(2025, 10, day), category: BuiltInCategory.restaurants.id, merchant: "Mamak \(day)"))
        }
        let insights = InsightGenerator().insights(now: TestData.date(2025, 10, 12, 20), transactions: records, commitments: [], monthlyBudget: nil)
        let change = insights.first { $0.kind == .categoryChange }
        XCTAssertEqual(change?.title, "Restaurants & Mamak increased 18%")
    }

    func testCommitmentAndBudgetInsights() {
        let rent = Commitment(name: "Rent", type: .rent, amount: TestData.rm("700.00"), recurrence: .monthly(day: 28), startDate: TestData.date(2025, 1, 1))
        let car = Commitment(name: "Car", type: .carFinancing, amount: TestData.rm("40.00"), recurrence: .monthly(day: 27), startDate: TestData.date(2025, 1, 1))
        let insights = InsightGenerator().insights(now: TestData.date(2025, 10, 20), transactions: [TestData.tx("1000.00", on: TestData.date(2025, 10, 5))],
                                                   commitments: [rent, car], monthlyBudget: Budget(limit: TestData.rm("3000.00")))
        XCTAssertEqual(insights.first { $0.kind == .upcomingCommitments }?.title, "RM 740.00 in upcoming commitments")
        // 3000 − 1000 spent − 700 rent (car loan principal excluded from discretionary maths).
        XCTAssertEqual(insights.first { $0.kind == .discretionaryRemaining }?.title, "RM 1,300.00 left to spend")
    }
}
