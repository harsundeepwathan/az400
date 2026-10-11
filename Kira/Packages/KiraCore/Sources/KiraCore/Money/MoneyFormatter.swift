import Foundation

/// Deterministic Malaysian money formatting. Implemented without `NumberFormatter` so output
/// is identical across devices, locales and platforms (and so tests are stable).
public struct MoneyFormatter: Sendable {
    public enum SignStyle: Sendable {
        /// "-RM 12.00"
        case minusOnly
        /// "+RM 12.00" / "-RM 12.00"
        case always
        /// "RM 12.00" regardless of sign (caller conveys direction elsewhere)
        case never
    }

    public var signStyle: SignStyle
    /// Separate the symbol from the digits ("RM 12.00" vs "RM12.00").
    public var spaceAfterSymbol: Bool
    /// Drop ".00" for whole amounts (used in compact chart labels only).
    public var omitZeroMinorUnits: Bool

    public init(signStyle: SignStyle = .minusOnly, spaceAfterSymbol: Bool = true, omitZeroMinorUnits: Bool = false) {
        self.signStyle = signStyle
        self.spaceAfterSymbol = spaceAfterSymbol
        self.omitZeroMinorUnits = omitZeroMinorUnits
    }

    public static let standard = MoneyFormatter()
    public static let compact = MoneyFormatter(omitZeroMinorUnits: true)

    public func symbol(for currency: CurrencyCode) -> String {
        switch currency.rawValue {
        case "MYR": return "RM"
        case "SGD": return "S$"
        case "USD": return "US$"
        default: return currency.rawValue
        }
    }

    public func string(from money: Money) -> String {
        let digits = money.currency.minorUnitDigits
        let absolute = money.minorUnits == .min ? UInt64(Int64.max) + 1 : UInt64(abs(money.minorUnits))
        var divisor: UInt64 = 1
        for _ in 0..<digits { divisor *= 10 }
        let major = absolute / divisor
        let minor = absolute % divisor

        var body = MoneyFormatter.groupThousands(major)
        if digits > 0 && !(omitZeroMinorUnits && minor == 0) {
            let minorString = String(minor)
            body += "." + String(repeating: "0", count: digits - minorString.count) + minorString
        }

        let symbol = symbol(for: money.currency) + (spaceAfterSymbol ? " " : "")
        let sign: String
        switch signStyle {
        case .minusOnly: sign = money.minorUnits < 0 ? "-" : ""
        case .always: sign = money.minorUnits < 0 ? "-" : (money.minorUnits > 0 ? "+" : "")
        case .never: sign = ""
        }
        return sign + symbol + body
    }

    /// VoiceOver-friendly phrasing, e.g. "2,845 ringgit 60 sen".
    public func accessibilityString(from money: Money) -> String {
        guard money.currency == .myr else { return string(from: money) }
        let absolute = abs(money.minorUnits)
        let ringgit = absolute / 100
        let sen = absolute % 100
        var parts: [String] = []
        if ringgit > 0 || sen == 0 { parts.append("\(MoneyFormatter.groupThousands(UInt64(ringgit))) ringgit") }
        if sen > 0 { parts.append("\(sen) sen") }
        return (money.minorUnits < 0 ? "minus " : "") + parts.joined(separator: " ")
    }

    static func groupThousands(_ value: UInt64) -> String {
        let raw = String(value)
        var result = ""
        for (index, character) in raw.enumerated() {
            if index > 0 && (raw.count - index) % 3 == 0 { result.append(",") }
            result.append(character)
        }
        return result
    }
}

public extension Money {
    var formatted: String { MoneyFormatter.standard.string(from: self) }
}

/// Percentage formatting helper ("18%", "-4.5%").
public enum PercentFormatter {
    public static func string(_ fraction: Double, maximumFractionDigits: Int = 0) -> String {
        let value = fraction * 100
        let factor = pow(10.0, Double(maximumFractionDigits))
        let rounded = (value * factor).rounded() / factor
        if maximumFractionDigits == 0 || rounded == rounded.rounded() {
            return "\(Int(rounded))%"
        }
        return String(format: "%.\(maximumFractionDigits)f%%", rounded)
    }
}
