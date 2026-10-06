import XCTest
@testable import VectorCore

final class CoachSummaryArchiveTests: XCTestCase {
    var directory: URL!
    var archive: CoachSummaryArchive!
    /// Tuesday 6 October 2026, 08:00 UTC.
    let morning = Date(timeIntervalSince1970: 1_791_273_600)

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        archive = CoachSummaryArchive(fileURL: directory.appendingPathComponent("coach.json"))
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    func digest(workouts: Int) -> CoachDigest {
        CoachDigest(date: "2026-10-06", goal: "build_muscle", unit: "kg",
                    training: .init(workoutsLast7d: workouts, workoutsPrev7d: 3, plannedPerWeek: 4, volumeChangePct: 6.5,
                                    prsLast14d: [.init(exercise: "Back Squat", weight: 82.5, reps: 8)],
                                    mainLift: .init(exercise: "Back Squat", e1rmNow: 101.3, e1rm30dAgo: nil)),
                    nutrition: .init(daysLoggedLast7d: 6, avgCalories: 2240, targetCalories: 2300, avgProtein: nil,
                                     targetProtein: 150, proteinDaysHit: 2),
                    body: .init(trendWeightNow: 77.4, trendWeight14dAgo: nil, weighInsLast14d: 11),
                    recommendations: ["Increase Back Squat to 85 kg × 8"])
    }

    func testServerDayIsUTC() {
        XCTAssertEqual(CoachSummaryArchive.serverDay(morning), "2026-10-06")
        XCTAssertEqual(CoachSummaryArchive.serverDay(morning.addingTimeInterval(-8.5 * 3600)), "2026-10-05")
    }

    func testFreshSummaryStoresItsDigestAndACachedOneShowsIt() {
        let written = digest(workouts: 2)
        let fresh = CoachSummary(text: "Two sessions.", cached: false, generatedAt: morning)
        XCTAssertEqual(archive.digestShown(for: fresh, sent: written, userID: "u1", now: morning),
                       CoachDigestShown(digest: written, isExact: true))
        XCTAssertEqual(archive.load()?.day, "2026-10-06")

        // Later the same day: one more workout logged, the server returns the stored summary.
        let later = digest(workouts: 3)
        let cached = CoachSummary(text: "Two sessions.", cached: true, generatedAt: morning.addingTimeInterval(0.0004))
        let shown = archive.digestShown(for: cached, sent: later, userID: "u1", now: morning.addingTimeInterval(4 * 3600))
        XCTAssertEqual(shown, CoachDigestShown(digest: written, isExact: true), "the digest the summary was written from, not today's")
    }

    func testCachedSummaryWithoutAMatchShowsCurrentDigestFlagged() {
        let current = digest(workouts: 3)
        let cached = CoachSummary(text: "Two sessions.", cached: true, generatedAt: morning)

        // Nothing stored (written on another device).
        XCTAssertEqual(archive.digestShown(for: cached, sent: current, userID: "u1", now: morning),
                       CoachDigestShown(digest: current, isExact: false))

        // Stored for yesterday.
        let yesterday = CoachSummary(text: "Old.", cached: false, generatedAt: morning.addingTimeInterval(-86_400))
        _ = archive.digestShown(for: yesterday, sent: digest(workouts: 1), userID: "u1", now: morning)
        XCTAssertFalse(archive.digestShown(for: cached, sent: current, userID: "u1", now: morning).isExact)

        // Stored for today but another account.
        let other = CoachSummary(text: "Other.", cached: false, generatedAt: morning)
        _ = archive.digestShown(for: other, sent: digest(workouts: 1), userID: "u2", now: morning)
        XCTAssertEqual(archive.digestShown(for: cached, sent: current, userID: "u1", now: morning).digest, current)

        // Same day and account but a different summary (regenerated elsewhere).
        _ = archive.digestShown(for: other, sent: digest(workouts: 1), userID: "u1", now: morning)
        let regenerated = CoachSummary(text: "New.", cached: true, generatedAt: morning.addingTimeInterval(600))
        XCTAssertFalse(archive.digestShown(for: regenerated, sent: current, userID: "u1", now: morning).isExact)
    }

    func testClearRemovesTheStoredDigest() {
        let fresh = CoachSummary(text: "Two sessions.", cached: false, generatedAt: morning)
        _ = archive.digestShown(for: fresh, sent: digest(workouts: 2), userID: "u1", now: morning)
        XCTAssertNotNil(archive.load())
        archive.clear()
        XCTAssertNil(archive.load())
        let cached = CoachSummary(text: "Two sessions.", cached: true, generatedAt: morning)
        XCTAssertFalse(archive.digestShown(for: cached, sent: digest(workouts: 3), userID: "u1", now: morning).isExact)
    }

    func testCorruptFileIsIgnored() throws {
        try Data("not json".utf8).write(to: archive.fileURL)
        XCTAssertNil(archive.load())
        let cached = CoachSummary(text: "Two sessions.", cached: true, generatedAt: morning)
        XCTAssertFalse(archive.digestShown(for: cached, sent: digest(workouts: 3), userID: nil, now: morning).isExact)
    }
}

final class MeasurementInputTests: XCTestCase {
    let us = Locale(identifier: "en_US")
    let de = Locale(identifier: "de_DE")

    func testParsesTheLocaleDecimalSeparatorAndDot() {
        XCTAssertEqual(MeasurementInput.parse("82.5", locale: us), .value(82.5))
        XCTAssertEqual(MeasurementInput.parse(" 80 ", locale: us), .value(80))
        XCTAssertEqual(MeasurementInput.parse("82,5", locale: de), .value(82.5))
        XCTAssertEqual(MeasurementInput.parse("82.5", locale: de), .value(82.5))
        XCTAssertEqual(MeasurementInput.parse(".5", locale: us), .value(0.5))
        XCTAssertEqual(MeasurementInput.parse("80.", locale: us), .value(80))
    }

    func testBlankIsEmptyAndNonsenseIsInvalid() {
        XCTAssertEqual(MeasurementInput.parse("", locale: us), .empty)
        XCTAssertEqual(MeasurementInput.parse("   ", locale: us), .empty)
        for text in ["0", "-5", "abc", "8.2.5", ".", "1,000", "1e3", "inf", "NaN", "٨٢"] {
            XCTAssertEqual(MeasurementInput.parse(text, locale: us), .invalid, text)
        }
        XCTAssertEqual(MeasurementInput.parse("1.000,5", locale: de), .invalid, "grouping is rejected, not guessed")
    }

    func testTextRoundTrips() {
        XCTAssertEqual(MeasurementInput.text(82.54, locale: us), "82.5")
        XCTAssertEqual(MeasurementInput.text(82.54, locale: de), "82,5")
        XCTAssertEqual(MeasurementInput.text(80, locale: de), "80")
        XCTAssertEqual(MeasurementInput.text(31.496, locale: us), "31.5")
        for value in [82.5, 80, 31.5, 0.5] {
            XCTAssertEqual(MeasurementInput.parse(MeasurementInput.text(value, locale: de), locale: de), .value(value))
        }
    }
}
