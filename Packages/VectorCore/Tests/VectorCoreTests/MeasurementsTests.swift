import XCTest
@testable import VectorCore

final class MeasurementsTests: XCTestCase {
    var calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        calendar.firstWeekday = 2
        return calendar
    }()
    // Monday 5 October 2026, 09:00 UTC.
    let now = Date(timeIntervalSince1970: 1_791_190_800)

    override func setUp() {
        Format.locale = Locale(identifier: "en_US")
    }

    func day(_ daysAgo: Double) -> Date { now.addingTimeInterval(-daysAgo * 86_400) }

    // MARK: Decoding

    func testOldDocumentsWithoutBodyFieldsStillDecode() throws {
        let legacy = #"{"schemaVersion":1,"customTemplates":[],"sessions":[],"foodEntries":[],"savedMeals":[],"bodyWeights":[],"scanDates":[],"dismissedInsightIDs":[],"tier":"free"}"#
        let data = try JSONFileStore.decoder.decode(AppData.self, from: Data(legacy.utf8))
        XCTAssertNil(data.bodyMeasurements)
        XCTAssertNil(data.progressPhotos)
    }

    func testEntryWithSomeSitesDecodesOthersAsNil() throws {
        let json = #"{"id":"6B1C1C9A-0D0B-4B0C-9E0B-6A5E7E2D2A11","date":"2026-10-05T09:00:00Z","waistCm":84.5}"#
        let entry = try JSONFileStore.decoder.decode(BodyMeasurementEntry.self, from: Data(json.utf8))
        XCTAssertEqual(entry.waistCm, 84.5)
        XCTAssertNil(entry.armCm)
        XCTAssertEqual(entry.measuredSites, [.waist])
    }

    func testRoundTripKeepsMeasurementsAndPhotos() throws {
        let entry = BodyMeasurementEntry(date: now, waistCm: 84, neckCm: 38)
        let photo = ProgressPhoto(date: now, pose: .side)
        let data = AppData(bodyMeasurements: [entry], progressPhotos: [photo])
        let decoded = try JSONFileStore.decoder.decode(AppData.self, from: JSONFileStore.encoder.encode(data))
        XCTAssertEqual(decoded.bodyMeasurements, [entry])
        XCTAssertEqual(decoded.progressPhotos, [photo])
        XCTAssertEqual(photo.fileName, "\(photo.id.uuidString).jpg")
    }

    func testSubscriptClearsNonPositiveValues() {
        var entry = BodyMeasurementEntry(date: now, waistCm: 80)
        entry[.waist] = 0
        entry[.arm] = .nan
        entry[.chest] = 101
        XCTAssertNil(entry.waistCm)
        XCTAssertNil(entry.armCm)
        XCTAssertEqual(entry.measuredSites, [.chest])
    }

    func testPhotoFileNameSafety() {
        XCTAssertTrue(ProgressPhoto(date: now, pose: .front).hasSafeFileName)
        XCTAssertFalse(ProgressPhoto(date: now, pose: .front, fileName: "../vector-data.json").hasSafeFileName)
        XCTAssertFalse(ProgressPhoto(date: now, pose: .front, fileName: "..").hasSafeFileName)
        XCTAssertFalse(ProgressPhoto(date: now, pose: .front, fileName: "").hasSafeFileName)
    }

    // MARK: Sync

    func testMeasurementsUnionAndTombstone() {
        let a = BodyMeasurementEntry(date: day(10), waistCm: 86)
        let b = BodyMeasurementEntry(date: day(3), waistCm: 85)
        let shared = BodyMeasurementEntry(date: day(20), chestCm: 100)
        let phone = AppData(modifiedAt: day(1), bodyMeasurements: [shared, b])
        var ipad = AppData(modifiedAt: day(2), bodyMeasurements: [a, shared])

        var merged = SyncMerge.merge(local: phone, remote: ipad)
        XCTAssertEqual(merged.bodyMeasurements?.map(\.id), [shared.id, a.id, b.id], "Unioned by id and sorted by date")

        ipad.bodyMeasurements = [shared]
        ipad.deletedIDs = [Tombstone.measurement(a.id)]
        merged = SyncMerge.merge(local: SyncMerge.merge(local: phone, remote: AppData(bodyMeasurements: [a])), remote: ipad)
        XCTAssertFalse(merged.bodyMeasurements?.contains { $0.id == a.id } ?? true, "A tombstone removes the entry everywhere")
        XCTAssertEqual(merged.bodyMeasurements?.count, 2)
        XCTAssertTrue(merged.deletedIDs?.contains(Tombstone.measurement(a.id)) ?? false)
    }

    func testNewerMeasurementEditWins() {
        let id = UUID()
        let phone = AppData(modifiedAt: day(1), bodyMeasurements: [BodyMeasurementEntry(id: id, date: day(5), waistCm: 84)])
        let ipad = AppData(modifiedAt: day(0), bodyMeasurements: [BodyMeasurementEntry(id: id, date: day(5), waistCm: 83)])
        XCTAssertEqual(SyncMerge.merge(local: phone, remote: ipad).bodyMeasurements?.first?.waistCm, 83)
        XCTAssertEqual(SyncMerge.merge(local: ipad, remote: phone).bodyMeasurements?.first?.waistCm, 83)
    }

    func testPhotoMetadataStaysOnDevice() {
        let mine = ProgressPhoto(date: day(1), pose: .front)
        let theirs = ProgressPhoto(date: day(2), pose: .back)
        let phone = AppData(modifiedAt: day(5), progressPhotos: [mine])
        let ipad = AppData(modifiedAt: day(0), progressPhotos: [theirs])
        XCTAssertEqual(SyncMerge.merge(local: phone, remote: ipad).progressPhotos, [mine],
                       "A newer remote document never brings in photos whose files aren't on this device")
        XCTAssertNil(SyncMerge.merge(local: AppData(), remote: ipad).progressPhotos)

        let cloud = SyncMerge.cloudCopy(phone)
        XCTAssertNil(cloud.progressPhotos)
        XCTAssertNil(cloud.activeWorkout)
    }

    func testResetTombstonesCoverBodyRecords() {
        let entry = BodyMeasurementEntry(date: now, armCm: 38)
        let photo = ProgressPhoto(date: now, pose: .front)
        let tombstones = Tombstone.all(in: AppData(bodyMeasurements: [entry], progressPhotos: [photo]))
        XCTAssertEqual(tombstones, [Tombstone.measurement(entry.id)], "Photo metadata is device-local and needs no tombstone")
    }

    // MARK: Trends

    func testSeriesUsesLoggedValuesOnly() {
        let engine = MeasurementsEngine(calendar: calendar)
        let entries = [
            BodyMeasurementEntry(date: day(40), waistCm: 90),           // outside 1M
            BodyMeasurementEntry(date: day(20), waistCm: 88, armCm: 37),
            BodyMeasurementEntry(date: day(10), armCm: 37.5),           // waist not measured
            BodyMeasurementEntry(date: day(2), waistCm: 86.5)
        ]
        let waist = engine.series(entries, site: .waist, range: .month, now: now)
        XCTAssertEqual(waist.map(\.value), [88, 86.5], "Unmeasured days are skipped, not zero")
        XCTAssertEqual(waist.map(\.date), [day(20), day(2)])
        XCTAssertEqual(engine.series(entries, site: .arm, range: .month, now: now).map(\.value), [37, 37.5])
        XCTAssertEqual(engine.series(entries, site: .waist, range: .all, now: now).count, 3)
        XCTAssertTrue(engine.series(entries, site: .neck, range: .all, now: now).isEmpty)
        XCTAssertEqual(engine.trackedSites(entries), [.waist, .arm])
    }

    func testSummariesLatestAndChange() {
        let engine = MeasurementsEngine(calendar: calendar)
        let entries = [
            BodyMeasurementEntry(date: day(25), waistCm: 88, chestCm: 100),
            BodyMeasurementEntry(date: day(4), waistCm: 86.5),
            BodyMeasurementEntry(date: day(60), neckCm: 39)
        ]
        let summaries = engine.summaries(entries, range: .month, now: now)
        XCTAssertEqual(summaries.map(\.site), [.waist, .chest, .neck])
        XCTAssertEqual(summaries[0].latestCm, 86.5)
        XCTAssertEqual(summaries[0].changeCm ?? 0, -1.5, accuracy: 1e-9)
        XCTAssertNil(summaries[1].changeCm, "One point is not a trend")
        XCTAssertEqual(summaries[2].latestCm, 39, "Latest value is shown even when outside the range")
        XCTAssertNil(summaries[2].changeCm)
    }

    func testUpsertMergesSameDay() {
        let engine = MeasurementsEngine(calendar: calendar)
        let morning = BodyMeasurementEntry(date: now, waistCm: 85, armCm: 37)
        var (entries, id) = engine.upserting(morning, into: [])
        XCTAssertEqual(id, morning.id)
        (entries, id) = engine.upserting(BodyMeasurementEntry(date: now.addingTimeInterval(3600), waistCm: 84.5, neckCm: 38), into: entries)
        XCTAssertEqual(entries.count, 1)
        XCTAssertEqual(id, morning.id)
        XCTAssertEqual(entries[0].waistCm, 84.5)
        XCTAssertEqual(entries[0].armCm, 37)
        XCTAssertEqual(entries[0].neckCm, 38)

        (entries, _) = engine.upserting(BodyMeasurementEntry(date: day(1), waistCm: 85.5), into: entries)
        XCTAssertEqual(entries.count, 2)
        XCTAssertEqual(entries.first?.date, day(1))
        XCTAssertEqual(engine.upserting(BodyMeasurementEntry(date: day(3)), into: entries).entries, entries, "Empty entries are ignored")
    }

    func testUnitsAndFormatting() {
        XCTAssertEqual(LengthUnit(.pounds), .inches)
        XCTAssertEqual(LengthUnit(.kilograms), .centimeters)
        XCTAssertEqual(LengthUnit.inches.toCentimeters(10), 25.4, accuracy: 1e-9)
        XCTAssertEqual(Format.length(84.5), "84.5 cm")
        XCTAssertEqual(Format.length(84.5, unit: .inches), "33.3 in")
        XCTAssertEqual(Format.signedLength(-1.5), "\u{2212}1.5 cm")
        XCTAssertEqual(Format.signedLength(2), "+2 cm")
        XCTAssertEqual(Format.signedLength(0.01), "0 cm")
    }

    // MARK: Photos

    func testPhotoCompareDays() {
        let engine = MeasurementsEngine(calendar: calendar)
        let early = ProgressPhoto(date: day(30), pose: .front)
        let laterSameDay = ProgressPhoto(date: day(2).addingTimeInterval(600), pose: .front)
        let sameDay = ProgressPhoto(date: day(2), pose: .front)
        let side = ProgressPhoto(date: day(10), pose: .side)
        let photos = [sameDay, early, side, laterSameDay]

        XCTAssertEqual(engine.photoDays(photos, pose: .front),
                       [calendar.startOfDay(for: day(2)), calendar.startOfDay(for: day(30))])
        XCTAssertEqual(engine.photo(photos, pose: .front, on: day(2))?.id, laterSameDay.id)
        let pair = engine.defaultComparison(photos, pose: .front)
        XCTAssertEqual(pair?.before, calendar.startOfDay(for: day(30)))
        XCTAssertEqual(pair?.after, calendar.startOfDay(for: day(2)))
        XCTAssertNil(engine.defaultComparison(photos, pose: .side), "Comparing needs two different days")
        XCTAssertNil(engine.defaultComparison(photos, pose: .back))
    }
}
