import Foundation

/// Calendar helpers pinned to Malaysia time (UTC+8, no DST) so period boundaries do not
/// shift when the device travels or when tests run on a UTC CI machine.
public struct KLCalendar: Sendable {
    public let calendar: Calendar

    public init(timeZone: TimeZone = TimeZone(identifier: "Asia/Kuala_Lumpur") ?? TimeZone(secondsFromGMT: 8 * 3600)!) {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        calendar.locale = Locale(identifier: "en_MY")
        calendar.firstWeekday = 2 // Monday
        self.calendar = calendar
    }

    public static let shared = KLCalendar()

    public func date(_ year: Int, _ month: Int, _ day: Int, _ hour: Int = 12, _ minute: Int = 0) -> Date {
        calendar.date(from: DateComponents(year: year, month: month, day: day, hour: hour, minute: minute))!
    }

    public func startOfDay(_ date: Date) -> Date { calendar.startOfDay(for: date) }

    public func monthInterval(containing date: Date) -> DateInterval {
        calendar.dateInterval(of: .month, for: date)!
    }

    public func weekInterval(containing date: Date) -> DateInterval {
        calendar.dateInterval(of: .weekOfYear, for: date)!
    }

    public func previousMonthInterval(before date: Date) -> DateInterval {
        let start = monthInterval(containing: date).start
        return monthInterval(containing: calendar.date(byAdding: .day, value: -1, to: start)!)
    }

    public func addingDays(_ days: Int, to date: Date) -> Date {
        calendar.date(byAdding: .day, value: days, to: date)!
    }

    public func addingMonths(_ months: Int, to date: Date) -> Date {
        calendar.date(byAdding: .month, value: months, to: date)!
    }

    public func daysInMonth(containing date: Date) -> Int {
        calendar.range(of: .day, in: .month, for: date)!.count
    }

    /// Whole calendar days between two dates (start-of-day based).
    public func dayDistance(from: Date, to: Date) -> Int {
        calendar.dateComponents([.day], from: startOfDay(from), to: startOfDay(to)).day ?? 0
    }

    public func isWeekend(_ date: Date) -> Bool { calendar.isDateInWeekend(date) }

    public func monthName(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "MMMM"
        return formatter.string(from: date)
    }

    /// Occurrence dates of a recurrence inside `[interval.start, interval.end)`, honouring start/end bounds.
    public func occurrences(of recurrence: Recurrence, startDate: Date, endDate: Date?, in interval: DateInterval) -> [Date] {
        let lower = max(startOfDay(startDate), interval.start)
        let upperBound = endDate.map { min(addingDays(1, to: startOfDay($0)), interval.end) } ?? interval.end
        guard lower < upperBound else { return [] }

        var results: [Date] = []
        switch recurrence {
        case .once(let date):
            if date >= lower && date < upperBound { results.append(date) }
        case .monthly(let day):
            var cursor = monthInterval(containing: lower).start
            while cursor < upperBound {
                let clampedDay = min(max(day, 1), daysInMonth(containing: cursor))
                let occurrence = calendar.date(byAdding: .day, value: clampedDay - 1, to: cursor)!
                let atNoon = calendar.date(bySettingHour: 12, minute: 0, second: 0, of: occurrence)!
                if atNoon >= lower && atNoon < upperBound { results.append(atNoon) }
                cursor = addingMonths(1, to: cursor)
            }
        case .weekly(let weekday):
            var cursor = startOfDay(lower)
            while cursor < upperBound {
                if calendar.component(.weekday, from: cursor) == weekday {
                    results.append(calendar.date(bySettingHour: 12, minute: 0, second: 0, of: cursor)!)
                }
                cursor = addingDays(1, to: cursor)
            }
        case .yearly(let month, let day):
            let startYear = calendar.component(.year, from: lower)
            let endYear = calendar.component(.year, from: upperBound)
            for year in startYear...endYear {
                let first = date(year, month, 1)
                let clamped = min(day, daysInMonth(containing: first))
                let occurrence = date(year, month, clamped)
                if occurrence >= lower && occurrence < upperBound { results.append(occurrence) }
            }
        }
        return results
    }
}
