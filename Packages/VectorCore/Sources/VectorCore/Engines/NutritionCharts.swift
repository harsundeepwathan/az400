import Foundation

/// One chart bucket of logged nutrition. Values are per logged day: a daily
/// bucket is that day's total, a weekly bucket is the average of the days
/// logged that week. Buckets with no logged day are absent (a gap), never zero.
public struct NutritionBucket: Identifiable, Hashable, Sendable {
    public var date: Date
    public var calories: Double
    public var protein: Double
    /// Logged days that make up the bucket (1 for daily buckets).
    public var loggedDays: Int
    /// Logged days in the bucket that hit the protein target.
    public var proteinDaysHit: Int
    public var id: Date { date }

    public init(date: Date, calories: Double, protein: Double, loggedDays: Int, proteinDaysHit: Int) {
        self.date = date
        self.calories = calories
        self.protein = protein
        self.loggedDays = loggedDays
        self.proteinDaysHit = proteinDaysHit
    }
}

public struct NutritionSeries: Hashable, Sendable {
    /// The full chart window (from the first bucket's start), so gaps keep their place on the x-axis.
    public var interval: DateInterval
    public var bucket: Calendar.Component
    /// Logged buckets only, oldest first.
    public var buckets: [NutritionBucket]
    /// Current targets. Past targets are not stored, so charts compare against today's.
    public var targets: NutritionTargets

    public var calories: [ChartPoint] { buckets.map { ChartPoint(date: $0.date, value: $0.calories) } }
    public var protein: [ChartPoint] { buckets.map { ChartPoint(date: $0.date, value: $0.protein) } }
    public var isEmpty: Bool { buckets.isEmpty }
}

public struct ProteinAdherence: Hashable, Sendable {
    public var daysHit: Int
    public var daysLogged: Int
    /// Consecutive days hitting the target, ending today (or yesterday while today is in progress).
    public var streak: Int

    /// Days hit / days logged; nil when nothing was logged.
    public var rate: Double? { daysLogged > 0 ? Double(daysHit) / Double(daysLogged) : nil }
}

/// Daily calories and protein against target, from logged days only.
public struct NutritionChartEngine: Sendable {
    public let calendar: Calendar
    let nutrition: NutritionEngine

    /// The ranges the nutrition charts offer.
    public static let ranges: [TimeRange] = [.week, .month, .threeMonths]

    public init(calendar: Calendar = .current) {
        self.calendar = calendar
        nutrition = NutritionEngine(calendar: calendar)
    }

    /// Logged days inside `range`, oldest first. Today is included once it has an entry.
    public func loggedDays(_ entries: [FoodEntry], targets: NutritionTargets, range: TimeRange, now: Date) -> [DailyNutrition] {
        let interval = window(entries, range: range, now: now)
        var totals: [Date: Macros] = [:]
        for entry in entries where interval.contains(entry.date) {
            totals[calendar.startOfDay(for: entry.date), default: .zero] += entry.macros
        }
        return totals.keys.sorted().map { DailyNutrition(date: $0, consumed: totals[$0]!, targets: targets) }
    }

    /// 1W and 1M are daily; longer ranges are weekly averages of logged days.
    public func series(_ entries: [FoodEntry], targets: NutritionTargets, range: TimeRange, now: Date) -> NutritionSeries {
        let interval = window(entries, range: range, now: now)
        let component = range.bucket
        var grouped: [Date: [DailyNutrition]] = [:]
        for day in loggedDays(entries, targets: targets, range: range, now: now) {
            grouped[bucketStart(day.date, component: component), default: []].append(day)
        }
        let buckets = grouped.keys.sorted().map { start -> NutritionBucket in
            let days = grouped[start]!
            let count = Double(days.count)
            return NutritionBucket(date: start,
                                   calories: days.reduce(0) { $0 + $1.consumed.calories } / count,
                                   protein: days.reduce(0) { $0 + $1.consumed.protein } / count,
                                   loggedDays: days.count,
                                   proteinDaysHit: days.filter(\.hitProteinTarget).count)
        }
        // Widen to the first bucket's start so a partial first week still has room on the axis.
        let axis = DateInterval(start: bucketStart(interval.start, component: component), end: interval.end)
        return NutritionSeries(interval: axis, bucket: component, buckets: buckets, targets: targets)
    }

    /// Protein days hit / days logged in the range. Today counts only once
    /// it's hit, so an unfinished day never reads as a miss (same rule as the streak).
    public func proteinAdherence(_ entries: [FoodEntry], targets: NutritionTargets, range: TimeRange, now: Date) -> ProteinAdherence {
        let days = loggedDays(entries, targets: targets, range: range, now: now)
            .filter { !calendar.isDate($0.date, inSameDayAs: now) || $0.hitProteinTarget }
        return ProteinAdherence(daysHit: days.filter(\.hitProteinTarget).count, daysLogged: days.count,
                                streak: nutrition.proteinStreak(entries, now: now, targets: targets))
    }

    // MARK: Helpers

    func window(_ entries: [FoodEntry], range: TimeRange, now: Date) -> DateInterval {
        range.interval(endingAt: now, calendar: calendar, earliest: entries.map(\.date).min())
    }

    func bucketStart(_ date: Date, component: Calendar.Component) -> Date {
        if component == .day { return calendar.startOfDay(for: date) }
        return calendar.dateInterval(of: component, for: date)?.start ?? calendar.startOfDay(for: date)
    }
}
