import Foundation

/// Latest value for a body site and how it moved over a window.
public struct MeasurementSummary: Identifiable, Hashable, Sendable {
    public var site: BodySite
    /// Most recent logged value in centimetres.
    public var latestCm: Double
    public var latestDate: Date
    /// Last minus first logged value inside the window (cm). Nil with fewer
    /// than two logged values in the window.
    public var changeCm: Double?
    public var id: BodySite { site }
}

/// Tape measurements and progress photos. Trends come only from values the
/// user actually logged: an unmeasured site is skipped, never treated as zero
/// and never interpolated.
public struct MeasurementsEngine: Sendable {
    public let calendar: Calendar

    public init(calendar: Calendar = .current) {
        self.calendar = calendar
    }

    // MARK: Measurements

    /// Logged values for one site in the range, oldest first.
    public func series(_ entries: [BodyMeasurementEntry], site: BodySite, range: TimeRange, now: Date) -> [ChartPoint] {
        let logged = entries.filter { $0[site] != nil }
        let interval = range.interval(endingAt: now, calendar: calendar, earliest: logged.map(\.date).min())
        return logged
            .filter { interval.contains($0.date) }
            .sorted { $0.date < $1.date }
            .compactMap { entry in entry[site].map { ChartPoint(date: entry.date, value: $0) } }
    }

    /// Every site with at least one logged value, in the standard order.
    public func trackedSites(_ entries: [BodyMeasurementEntry]) -> [BodySite] {
        BodySite.allCases.filter { site in entries.contains { $0[site] != nil } }
    }

    public func summaries(_ entries: [BodyMeasurementEntry], range: TimeRange, now: Date) -> [MeasurementSummary] {
        trackedSites(entries).compactMap { site in
            guard let latest = entries.filter({ $0[site] != nil }).max(by: { $0.date < $1.date }),
                  let value = latest[site] else { return nil }
            let points = series(entries, site: site, range: range, now: now)
            let change = points.count >= 2 ? points[points.count - 1].value - points[0].value : nil
            return MeasurementSummary(site: site, latestCm: value, latestDate: latest.date, changeCm: change)
        }
    }

    /// Adds a measuring session. A second session on the same day updates
    /// that day's entry: newly entered sites overwrite, untouched ones stay.
    /// Returns the updated list and the id of the entry that was written.
    public func upserting(_ entry: BodyMeasurementEntry, into entries: [BodyMeasurementEntry]) -> (entries: [BodyMeasurementEntry], id: UUID) {
        var result = entries
        guard !entry.isEmpty else { return (result, entry.id) }
        if let index = result.firstIndex(where: { $0.id == entry.id }) {
            result[index] = entry
            return (result.sorted { $0.date < $1.date }, entry.id)
        }
        if let index = result.firstIndex(where: { calendar.isDate($0.date, inSameDayAs: entry.date) }) {
            for site in entry.measuredSites { result[index][site] = entry[site] }
            result[index].date = max(result[index].date, entry.date)
            return (result.sorted { $0.date < $1.date }, result[index].id)
        }
        result.append(entry)
        return (result.sorted { $0.date < $1.date }, entry.id)
    }

    // MARK: Photos

    /// Days that have at least one photo of `pose`, newest first.
    public func photoDays(_ photos: [ProgressPhoto], pose: PhotoPose) -> [Date] {
        let days = Set(photos.filter { $0.pose == pose }.map { calendar.startOfDay(for: $0.date) })
        return days.sorted(by: >)
    }

    /// The latest photo of `pose` taken on `day`.
    public func photo(_ photos: [ProgressPhoto], pose: PhotoPose, on day: Date) -> ProgressPhoto? {
        photos
            .filter { $0.pose == pose && calendar.isDate($0.date, inSameDayAs: day) }
            .max { $0.date < $1.date }
    }

    /// Default pair for the compare view: the earliest and the latest day
    /// with a photo of `pose`. Nil until there are two different days.
    public func defaultComparison(_ photos: [ProgressPhoto], pose: PhotoPose) -> (before: Date, after: Date)? {
        let days = photoDays(photos, pose: pose)
        guard let latest = days.first, let earliest = days.last, latest != earliest else { return nil }
        return (earliest, latest)
    }
}

extension Format {
    /// "84.5 cm", "33.3 in". One decimal is as precise as a tape gets.
    public static func length(_ centimeters: Double, unit: LengthUnit = .centimeters, includeUnit: Bool = true) -> String {
        let formatter = NumberFormatter()
        formatter.locale = locale
        formatter.numberStyle = .decimal
        formatter.usesGroupingSeparator = false
        formatter.maximumFractionDigits = 1
        let text = formatter.string(from: NSNumber(value: unit.fromCentimeters(centimeters))) ?? "\(centimeters)"
        return includeUnit ? "\(text) \(unit.symbol)" : text
    }

    /// "+1.5 cm", "−2 cm", "0 cm". True minus sign, like `signedPercent`.
    public static func signedLength(_ centimeters: Double, unit: LengthUnit = .centimeters) -> String {
        let value = unit.fromCentimeters(centimeters)
        let magnitude = length(abs(centimeters), unit: unit)
        if (value * 10).rounded() > 0 { return "+" + magnitude }
        if (value * 10).rounded() < 0 { return "\u{2212}" + magnitude }
        return length(0, unit: unit)
    }
}
