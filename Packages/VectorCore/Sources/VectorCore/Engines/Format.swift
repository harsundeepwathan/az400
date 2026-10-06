import Foundation

/// Display formatting shared by the app, widgets and the watch so numbers
/// read identically everywhere. Locale-aware, but injectable for tests.
public enum Format {
    nonisolated(unsafe) public static var locale: Locale = .current

    private static func number(_ value: Double, maxFraction: Int, minFraction: Int = 0, grouping: Bool = true) -> String {
        let formatter = NumberFormatter()
        formatter.locale = locale
        formatter.numberStyle = .decimal
        formatter.usesGroupingSeparator = grouping
        formatter.minimumFractionDigits = minFraction
        formatter.maximumFractionDigits = maxFraction
        return formatter.string(from: NSNumber(value: value)) ?? "\(value)"
    }

    /// 82.5 kg, 80 kg, 181.9 lb. Plate-math friendly: at most one decimal.
    public static func weight(_ kilograms: Double, unit: WeightUnit = .kilograms, includeUnit: Bool = true) -> String {
        let value = unit.fromKilograms(kilograms)
        let text = number(value, maxFraction: unit == .kilograms ? 2 : 1, grouping: false)
        return includeUnit ? "\(text) \(unit.symbol)" : text
    }

    /// Estimated values (1RM, trends) rounded to 0.5 so they don't imply false precision.
    public static func estimate(_ kilograms: Double, unit: WeightUnit = .kilograms, includeUnit: Bool = true) -> String {
        let rounded = (unit.fromKilograms(kilograms) * 2).rounded() / 2
        let text = number(rounded, maxFraction: 1, grouping: false)
        return includeUnit ? "\(text) \(unit.symbol)" : text
    }

    /// 8,420 kg. Volume is always shown as a whole number.
    public static func volume(_ kilograms: Double, unit: WeightUnit = .kilograms, includeUnit: Bool = true) -> String {
        let text = number(unit.fromKilograms(kilograms).rounded(), maxFraction: 0)
        return includeUnit ? "\(text) \(unit.symbol)" : text
    }

    /// Compact volume for chart axes: 8.4k.
    public static func compact(_ value: Double) -> String {
        switch abs(value) {
        case 1_000_000...: return number(value / 1_000_000, maxFraction: 1) + "M"
        case 10_000...: return number(value / 1000, maxFraction: 0) + "k"
        case 1000...: return number(value / 1000, maxFraction: 1) + "k"
        default: return number(value, maxFraction: 0)
        }
    }

    /// "8", "8.5": RPE is logged in half steps.
    public static func rpe(_ value: Double) -> String { number(value, maxFraction: 1) }

    public static func integer(_ value: Double) -> String { number(value.rounded(), maxFraction: 0) }

    public static func grams(_ value: Double) -> String { number(value.rounded(), maxFraction: 0) + "g" }

    /// +8.4% / −3%. Uses a true minus sign for typographic polish.
    public static func signedPercent(_ fraction: Double) -> String {
        let percent = fraction * 100
        let magnitude = number(abs(percent), maxFraction: abs(percent) < 10 ? 1 : 0)
        if percent > 0.05 { return "+\(magnitude)%" }
        if percent < -0.05 { return "\u{2212}\(magnitude)%" }
        return "0%"
    }

    /// 00:18:42 for workouts, 1:32 for rest timers.
    public static func clock(_ interval: TimeInterval, alwaysShowHours: Bool = false) -> String {
        let total = max(Int(interval.rounded(.down)), 0)
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        let seconds = total % 60
        if hours > 0 || alwaysShowHours {
            return String(format: "%02d:%02d:%02d", hours, minutes, seconds)
        }
        return String(format: "%d:%02d", minutes, seconds)
    }

    /// "58 min", "1 h 4 min".
    public static func duration(_ interval: TimeInterval) -> String {
        let minutes = max(Int((interval / 60).rounded()), 0)
        if minutes < 60 { return "\(minutes) min" }
        let rest = minutes % 60
        return rest == 0 ? "\(minutes / 60) h" : "\(minutes / 60) h \(rest) min"
    }

    /// "Today", "Yesterday", "3 days ago", "2 weeks ago".
    public static func relativeDays(from date: Date, to now: Date, calendar: Calendar = .current) -> String {
        let start = calendar.startOfDay(for: date)
        let end = calendar.startOfDay(for: now)
        let days = calendar.dateComponents([.day], from: start, to: end).day ?? 0
        switch days {
        case ..<1: return "Today"
        case 1: return "Yesterday"
        case 2..<14: return "\(days) days ago"
        case 14..<60: return "\(days / 7) weeks ago"
        default: return "\(days / 30) months ago"
        }
    }

    /// "29 Sep".
    public static func shortDate(_ date: Date, calendar: Calendar = .current) -> String {
        let formatter = DateFormatter()
        formatter.locale = locale
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        formatter.setLocalizedDateFormatFromTemplate("dMMM")
        return formatter.string(from: date)
    }

    /// "Monday, 5 October".
    public static func longDate(_ date: Date, calendar: Calendar = .current) -> String {
        let formatter = DateFormatter()
        formatter.locale = locale
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        formatter.setLocalizedDateFormatFromTemplate("EEEEdMMMM")
        return formatter.string(from: date)
    }

    public static func greeting(for date: Date, calendar: Calendar = .current) -> String {
        switch calendar.component(.hour, from: date) {
        case 4..<12: return "Good morning"
        case 12..<17: return "Good afternoon"
        default: return "Good evening"
        }
    }
}
