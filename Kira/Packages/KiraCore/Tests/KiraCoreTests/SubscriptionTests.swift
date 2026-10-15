import XCTest
@testable import KiraCore

final class SubscriptionTests: XCTestCase {
    let engine = SubscriptionEngine()
    let cal = KLCalendar.shared

    func sub(_ name: String, _ amount: String, cycle: BillingCycle = .monthly, next: Date = TestData.date(2025, 10, 25),
             status: ServiceSubscriptionStatus = .active, service: String? = nil, share: Int = 1, trialEnds: Date? = nil,
             updated: Date = TestData.date(2025, 1, 1)) -> ServiceSubscription {
        ServiceSubscription(name: name, serviceID: service, amount: TestData.rm(amount), cycle: cycle, nextRenewal: next,
                            startDate: TestData.date(2025, 1, 1), status: status, trialEndsAt: trialEnds, shareCount: share,
                            createdAt: updated, updatedAt: updated)
    }

    // MARK: Cost

    func testMonthlyAndYearlyCostsAreExact() {
        XCTAssertEqual(engine.monthlyCost(sub("Netflix", "54.90")), TestData.rm("54.90"))
        XCTAssertEqual(engine.yearlyCost(sub("Netflix", "54.90")), TestData.rm("658.80"))
        let yearly = sub("iCloud+", "119.88", cycle: .yearly)
        XCTAssertEqual(engine.monthlyCost(yearly), TestData.rm("9.99"))
        XCTAssertEqual(engine.yearlyCost(yearly), TestData.rm("119.88"))
        XCTAssertEqual(engine.monthlyCost(sub("Gym", "30.00", cycle: .weekly)), TestData.rm("130.00"))
        XCTAssertEqual(engine.monthlyCost(sub("Quarterly", "45.00", cycle: .quarterly)), TestData.rm("15.00"))
    }

    func testFamilyPlanShare() {
        let family = sub("Spotify Family", "54.90", share: 4)
        XCTAssertEqual(engine.yourShare(family), TestData.rm("13.73"), "13.725 rounds half-up")
        XCTAssertEqual(engine.monthlyCost(family), TestData.rm("13.73"))
    }

    // MARK: Dates

    func testMonthEndRenewalsKeepAnchorDay() {
        let s = sub("Month end", "10.00", next: TestData.date(2025, 1, 31))
        let feb = engine.renewal(after: s.nextRenewal, for: s)
        XCTAssertEqual(cal.calendar.component(.day, from: feb), 28)
        let mar = engine.renewal(after: feb, for: s)
        XCTAssertEqual(cal.calendar.component(.day, from: mar), 31, "returns to the 31st after February")
    }

    func testStaleRenewalRollsForward() {
        let s = sub("Netflix", "54.90", next: TestData.date(2025, 7, 16))
        let rolled = engine.rolledForward(s, now: TestData.date(2025, 10, 20))
        XCTAssertEqual(cal.calendar.dateComponents([.month, .day], from: rolled.nextRenewal), DateComponents(month: 11, day: 16))
    }

    func testRenewalsInWindow() {
        let weekly = sub("Weekly", "5.00", cycle: .weekly, next: TestData.date(2025, 10, 21))
        let window = DateInterval(start: TestData.date(2025, 10, 20, 0), end: TestData.date(2025, 11, 20, 0))
        XCTAssertEqual(engine.renewals(of: weekly, in: window).count, 5)
        XCTAssertTrue(engine.renewals(of: sub("Off", "5.00", status: .cancelled), in: window).isEmpty)
    }

    // MARK: Summary

    func testSummaryCountsOnlyBillingInRinggit() {
        var usd = sub("ChatGPT Plus", "20.00")
        usd.amount = Money(minorUnits: 2000, currency: .usd)
        let subs = [
            sub("Netflix", "54.90", next: TestData.date(2025, 10, 25)),
            sub("iCloud+", "119.88", cycle: .yearly, next: TestData.date(2026, 3, 1)),
            sub("Viu", "15.90", status: .trial, trialEnds: TestData.date(2025, 10, 28)),
            sub("Paused", "30.00", status: .paused),
            sub("Gone", "30.00", status: .cancelled),
            usd
        ]
        let summary = engine.summary(subs, now: TestData.date(2025, 10, 20))
        XCTAssertEqual(summary.monthlyTotal, TestData.rm("64.89"), "54.90 + 9.99; trial, paused, cancelled excluded")
        XCTAssertEqual(summary.monthlyAfterTrials, TestData.rm("80.79"))
        XCTAssertEqual(summary.activeCount, 3)
        XCTAssertEqual(summary.trialCount, 1)
        XCTAssertEqual(summary.foreignCurrencyCount, 1)
        XCTAssertEqual(summary.upcoming.first?.amount, TestData.rm("54.90"))
        let viu = summary.upcoming.first { $0.amount == TestData.rm("15.90") }
        XCTAssertEqual(viu?.isTrialConversion, true)
    }

    // MARK: Catalog & matching

    func testCatalogMatchesStatementText() {
        XCTAssertEqual(SubscriptionCatalog.match("NETFLIX.COM SINGAPORE")?.id, "netflix")
        XCTAssertEqual(SubscriptionCatalog.match("GOOGLE *YOUTUBE PREMIUM")?.id, "youtube-premium")
        XCTAssertEqual(SubscriptionCatalog.match("SPOTIFY P2AB3CD4EF")?.id, "spotify")
        XCTAssertEqual(SubscriptionCatalog.match("GRABUNLIMITED")?.id, "grab-unlimited")
        XCTAssertNil(SubscriptionCatalog.match("JAYA GROCER"))
        XCTAssertFalse(SubscriptionCatalog.search("net").isEmpty)
    }

    func testMatchedChargesRequireMerchantAndCloseAmount() {
        let netflix = sub("Netflix", "54.90", service: "netflix")
        let records = [
            TestData.tx("54.90", on: TestData.date(2025, 9, 25), category: nil, merchant: "NETFLIX.COM"),
            TestData.tx("59.90", on: TestData.date(2025, 10, 25), category: nil, merchant: "NETFLIX.COM"),
            TestData.tx("200.00", on: TestData.date(2025, 10, 2), category: nil, merchant: "NETFLIX.COM"),
            TestData.tx("54.90", on: TestData.date(2025, 10, 3), category: nil, merchant: "Spotify"),
            TestData.tx("54.90", on: TestData.date(2025, 10, 4), category: nil, merchant: "NETFLIX.COM", status: .draft)
        ]
        let matched = engine.matchedCharges(for: netflix, in: records)
        XCTAssertEqual(matched.map(\.amount), [TestData.rm("59.90"), TestData.rm("54.90")])
    }

    // MARK: Alerts

    func testAlerts() {
        let now = TestData.date(2025, 10, 20)
        let netflix = sub("Netflix", "54.90", next: TestData.date(2025, 10, 21), service: "netflix")
        let trial = sub("Viu", "15.90", status: .trial, service: "viu", trialEnds: TestData.date(2025, 10, 22))
        let charges = [TestData.tx("59.90", on: TestData.date(2025, 9, 21), category: nil, merchant: "NETFLIX.COM", source: .bankStatementCSV)]
        let alerts = engine.alerts([netflix, trial], transactions: charges, now: now)
        XCTAssertTrue(alerts.contains { $0.subscriptionID == netflix.id && $0.kind == .renewsSoon(netflix.nextRenewal) })
        XCTAssertTrue(alerts.contains { $0.subscriptionID == netflix.id && $0.kind == .priceChanged(from: TestData.rm("54.90"), to: TestData.rm("59.90")) })
        XCTAssertTrue(alerts.contains { $0.subscriptionID == trial.id && $0.kind == .trialEnding(TestData.date(2025, 10, 22)) })
    }

    func testNoRecentChargeNeedsStatementCoverage() {
        let now = TestData.date(2025, 10, 20)
        let spotify = sub("Spotify", "17.90", next: TestData.date(2025, 11, 5), service: "spotify")
        // Without imported statements after 5 Oct, Kira can't know — no alert.
        XCTAssertFalse(engine.alerts([spotify], transactions: [], now: now).contains { if case .noRecentCharge = $0.kind { return true } else { return false } })
        // A statement covering mid-October with no Spotify charge on ~5 Oct → alert.
        let statement = [TestData.tx("10.00", on: TestData.date(2025, 10, 15), merchant: "Jaya Grocer", source: .bankStatementCSV)]
        XCTAssertTrue(engine.alerts([spotify], transactions: statement, now: now).contains { if case .noRecentCharge = $0.kind { return true } else { return false } })
        // …unless the charge is there.
        let charged = statement + [TestData.tx("17.90", on: TestData.date(2025, 10, 5), category: nil, merchant: "SPOTIFY", source: .bankStatementCSV)]
        XCTAssertFalse(engine.alerts([spotify], transactions: charged, now: now).contains { if case .noRecentCharge = $0.kind { return true } else { return false } })
    }

    func testDuplicateServiceAlert() {
        let a = sub("Netflix", "54.90", service: "netflix", updated: TestData.date(2025, 1, 1))
        let b = sub("Netflix (2)", "54.90", service: "netflix", updated: TestData.date(2025, 2, 1))
        let alerts = engine.alerts([a, b], transactions: [], now: TestData.date(2025, 10, 1))
        XCTAssertTrue(alerts.contains { $0.subscriptionID == b.id && $0.kind == .duplicate(otherID: a.id) })
    }

    // MARK: Suggestions

    func testSuggestionsFromStatementHistory() {
        let records = [
            TestData.tx("54.90", on: TestData.date(2025, 8, 25), category: BuiltInCategory.subscriptions.id, merchant: "NETFLIX.COM"),
            TestData.tx("54.90", on: TestData.date(2025, 9, 25), category: BuiltInCategory.subscriptions.id, merchant: "NETFLIX.COM"),
            TestData.tx("12.00", on: TestData.date(2025, 8, 3), merchant: "Kedai Ali"),
            TestData.tx("12.00", on: TestData.date(2025, 9, 3), merchant: "Kedai Ali")
        ]
        let suggestions = engine.suggestions(transactions: records, existing: [])
        XCTAssertEqual(suggestions.map(\.name), ["Netflix"], "unknown merchant with 2 charges is not suggested")
        XCTAssertEqual(suggestions.first?.cycle, .monthly)
        XCTAssertEqual(suggestions.first?.amount, TestData.rm("54.90"))

        let tracked = sub("Netflix", "54.90", service: "netflix")
        XCTAssertTrue(engine.suggestions(transactions: records, existing: [tracked]).isEmpty)

        let draft = engine.subscription(from: suggestions[0], now: TestData.date(2025, 10, 20))
        XCTAssertEqual(draft.serviceID, "netflix")
        XCTAssertGreaterThanOrEqual(draft.nextRenewal, TestData.date(2025, 10, 20, 0))
    }

    // MARK: Forecast integration

    func testCommitmentForForecast() throws {
        let quarterly = sub("Quarterly", "45.00", cycle: .quarterly, next: TestData.date(2025, 11, 10))
        let commitment = try XCTUnwrap(engine.commitment(for: quarterly))
        XCTAssertEqual(commitment.type, .subscription)
        let year = DateInterval(start: TestData.date(2025, 10, 1, 0), end: TestData.date(2026, 10, 1, 0))
        let dates = cal.occurrences(of: commitment.recurrence, startDate: commitment.startDate, endDate: nil, in: year)
        XCTAssertEqual(dates.map { cal.calendar.component(.month, from: $0) }, [11, 2, 5, 8])
        XCTAssertNil(engine.commitment(for: sub("Off", "5.00", status: .cancelled)))

        let trial = sub("Viu", "15.90", next: TestData.date(2025, 10, 22), status: .trial, trialEnds: TestData.date(2025, 11, 1))
        XCTAssertEqual(try XCTUnwrap(engine.commitment(for: trial)).startDate, cal.startOfDay(TestData.date(2025, 11, 1)))
    }

    func testSubscriptionRoundTripsThroughJSON() throws {
        let s = sub("Netflix", "54.90", cycle: .everyMonths(6), service: "netflix", share: 2)
        let data = try JSONEncoder().encode(s)
        XCTAssertEqual(try JSONDecoder().decode(ServiceSubscription.self, from: data), s)
        XCTAssertTrue(FeatureGate(tier: .free).isAvailable(.subscriptionTracking))
    }
}
