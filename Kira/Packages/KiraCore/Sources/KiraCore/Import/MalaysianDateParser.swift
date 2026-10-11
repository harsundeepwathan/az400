import Foundation

/// Parses dates the way Malaysian banks and e-wallets print them. Day-first is assumed:
/// "03/04/2025" is 3 April, never 4 March. Supports English and Malay month abbreviations.
public struct MalaysianDateParser: Sendable {
    public let calendar: KLCalendar
    /// Used when a statement line omits the year ("12 OCT"). Lines whose month is after the
    /// reference month are assumed to be from the previous year (December lines on a January statement).
    public var referenceDate: Date?

    public init(calendar: KLCalendar = .shared, referenceDate: Date? = nil) {
        self.calendar = calendar
        self.referenceDate = referenceDate
    }

    private static let months: [String: Int] = [
        "JAN": 1, "JANUARY": 1, "JANUARI": 1,
        "FEB": 2, "FEBRUARY": 2, "FEBRUARI": 2,
        "MAR": 3, "MARCH": 3, "MAC": 3,
        "APR": 4, "APRIL": 4,
        "MAY": 5, "MEI": 5,
        "JUN": 6, "JUNE": 6,
        "JUL": 7, "JULY": 7, "JULAI": 7,
        "AUG": 8, "AUGUST": 8, "OGO": 8, "OGOS": 8,
        "SEP": 9, "SEPT": 9, "SEPTEMBER": 9,
        "OCT": 10, "OCTOBER": 10, "OKT": 10, "OKTOBER": 10,
        "NOV": 11, "NOVEMBER": 11,
        "DEC": 12, "DECEMBER": 12, "DIS": 12, "DISEMBER": 12
    ]

    /// Parses a date with optional time ("12/10/2025 14:32", "12 Oct 2025, 2:32 PM").
    public func parse(_ input: String) -> Date? {
        let text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        let (datePart, time) = splitTime(text)
        guard let (year, month, day) = parseDateComponents(datePart) else { return nil }
        guard (1...12).contains(month), day >= 1 else { return nil }
        let first = calendar.date(year, month, 1)
        guard day <= calendar.daysInMonth(containing: first) else { return nil }
        let hour = time?.hour ?? 12, minute = time?.minute ?? 0
        return calendar.date(year, month, day, hour, minute)
    }

    /// True when the string begins with something that looks like a date (used to detect statement rows).
    public func startsWithDate(_ line: String) -> (date: Date, remainder: String)? {
        let tokens = line.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
        // Try 3-token ("12 Oct 2025"), 2-token ("12 Oct") then 1-token ("12/10/2025") prefixes.
        for count in [3, 2, 1] where tokens.count > count {
            let candidate = tokens.prefix(count).joined(separator: " ")
            if count > 1, !tokens.prefix(count).dropFirst().first!.contains(where: \.isLetter) { continue }
            if let date = parse(candidate) {
                return (date, tokens.dropFirst(count).joined(separator: " "))
            }
        }
        return nil
    }

    private func splitTime(_ text: String) -> (String, (hour: Int, minute: Int)?) {
        let pattern = #"[,\sT]+(\d{1,2}):(\d{2})(?::\d{2})?\s*([AaPp][Mm])?\s*$"#
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              let range = Range(match.range, in: text),
              let hourRange = Range(match.range(at: 1), in: text),
              let minuteRange = Range(match.range(at: 2), in: text),
              var hour = Int(text[hourRange]), let minute = Int(text[minuteRange]) else {
            return (text, nil)
        }
        if let meridiemRange = Range(match.range(at: 3), in: text) {
            let meridiem = text[meridiemRange].uppercased()
            if meridiem == "PM" && hour < 12 { hour += 12 }
            if meridiem == "AM" && hour == 12 { hour = 0 }
        }
        guard hour < 24, minute < 60 else { return (text, nil) }
        return (String(text[..<range.lowerBound]), (hour, minute))
    }

    private func parseDateComponents(_ raw: String) -> (Int, Int, Int)? {
        let text = raw.trimmingCharacters(in: CharacterSet(charactersIn: " ,")).uppercased()
        let separators = CharacterSet(charactersIn: "/-. ")
        let parts = text.components(separatedBy: separators).filter { !$0.isEmpty }

        // ISO yyyy-MM-dd
        if parts.count == 3, parts[0].count == 4, let year = Int(parts[0]), let month = Int(parts[1]), let day = Int(parts[2]) {
            return (year, month, day)
        }
        // Compact yyyyMMdd / ddMMyyyy
        if parts.count == 1, parts[0].count == 8, parts[0].allSatisfy(\.isNumber) {
            let digits = parts[0]
            let first4 = Int(digits.prefix(4))!
            if first4 >= 1990 && first4 <= 2100 {
                return (first4, Int(digits.dropFirst(4).prefix(2))!, Int(digits.suffix(2))!)
            }
            return (Int(digits.suffix(4))!, Int(digits.dropFirst(2).prefix(2))!, Int(digits.prefix(2))!)
        }
        guard parts.count == 2 || parts.count == 3, let day = Int(parts[0]), (1...31).contains(day) else { return nil }

        let month: Int
        if let numeric = Int(parts[1]) {
            month = numeric
        } else if let named = Self.months[parts[1]] {
            month = named
        } else {
            return nil
        }

        let year: Int
        if parts.count == 3 {
            guard let value = Int(parts[2]) else { return nil }
            switch parts[2].count {
            case 2: year = 2000 + value
            case 4: year = value
            default: return nil
            }
        } else {
            guard parts[1].first?.isLetter == true else { return nil } // "12/10" alone is too ambiguous
            guard let reference = referenceDate else { return nil }
            let refYear = calendar.calendar.component(.year, from: reference)
            let refMonth = calendar.calendar.component(.month, from: reference)
            year = month > refMonth ? refYear - 1 : refYear
        }
        return (year, month, day)
    }
}
