import Foundation

/// ISO 4217 currency code. Kira defaults to MYR; other currencies are stored verbatim
/// but never silently converted.
public struct CurrencyCode: RawRepresentable, Hashable, Codable, Sendable, CustomStringConvertible {
    public let rawValue: String
    /// Number of minor-unit digits (ISO 4217 exponent).
    public let minorUnitDigits: Int

    public init(rawValue: String) {
        let code = rawValue.uppercased()
        self.rawValue = code
        self.minorUnitDigits = CurrencyCode.exponents[code] ?? 2
    }

    public init(from decoder: Decoder) throws {
        self.init(rawValue: try decoder.singleValueContainer().decode(String.self))
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }

    public var description: String { rawValue }

    public static let myr = CurrencyCode(rawValue: "MYR")
    public static let sgd = CurrencyCode(rawValue: "SGD")
    public static let usd = CurrencyCode(rawValue: "USD")

    /// ISO 4217 numeric → alpha mapping for the codes we expect in QR payloads.
    public static func fromNumeric(_ numeric: String) -> CurrencyCode? {
        switch numeric {
        case "458": return .myr
        case "702": return .sgd
        case "840": return .usd
        case "360": return CurrencyCode(rawValue: "IDR")
        case "764": return CurrencyCode(rawValue: "THB")
        default: return nil
        }
    }

    private static let exponents: [String: Int] = [
        "MYR": 2, "SGD": 2, "USD": 2, "EUR": 2, "GBP": 2, "THB": 2,
        "IDR": 2, "JPY": 0, "KRW": 0, "BHD": 3, "KWD": 3
    ]
}

/// An exact monetary amount stored as an integer count of minor units (sen for MYR).
///
/// `Money` is signed so it can represent net figures, but transaction records store a
/// non-negative magnitude plus an explicit direction — see `TransactionRecord`.
public struct Money: Hashable, Codable, Sendable, Comparable {
    public let minorUnits: Int64
    public let currency: CurrencyCode

    public init(minorUnits: Int64, currency: CurrencyCode = .myr) {
        self.minorUnits = minorUnits
        self.currency = currency
    }

    /// Creates money from a `Decimal` major-unit value. Fails if the value has more
    /// precision than the currency supports (we never silently round user input).
    public init?(major: Decimal, currency: CurrencyCode = .myr) {
        var scaled = major * Money.pow10(currency.minorUnitDigits)
        var rounded = Decimal()
        NSDecimalRound(&rounded, &scaled, 0, .plain)
        guard rounded == scaled else { return nil }
        guard let value = Int64(exactly: NSDecimalNumber(decimal: rounded)) else { return nil }
        self.init(minorUnits: value, currency: currency)
    }

    /// Creates money from a `Decimal`, rounding half-up (away from zero) to the currency precision.
    /// Use only for derived values (e.g. interest, percentages), never for user-entered amounts.
    public static func rounded(major: Decimal, currency: CurrencyCode = .myr) -> Money {
        var scaled = major * pow10(currency.minorUnitDigits)
        var rounded = Decimal()
        NSDecimalRound(&rounded, &scaled, 0, .plain)
        return Money(minorUnits: NSDecimalNumber(decimal: rounded).int64Value, currency: currency)
    }

    public static func zero(_ currency: CurrencyCode = .myr) -> Money { Money(minorUnits: 0, currency: currency) }

    public var decimalValue: Decimal {
        Decimal(minorUnits) / Money.pow10(currency.minorUnitDigits)
    }

    public var isZero: Bool { minorUnits == 0 }
    public var isNegative: Bool { minorUnits < 0 }
    public var magnitude: Money { Money(minorUnits: minorUnits == .min ? .max : abs(minorUnits), currency: currency) }
    public var negated: Money { Money(minorUnits: -minorUnits, currency: currency) }

    // MARK: Arithmetic (currency-checked)

    public static func + (lhs: Money, rhs: Money) -> Money {
        precondition(lhs.currency == rhs.currency, "Cannot add \(lhs.currency) and \(rhs.currency)")
        let (value, overflow) = lhs.minorUnits.addingReportingOverflow(rhs.minorUnits)
        precondition(!overflow, "Money overflow")
        return Money(minorUnits: value, currency: lhs.currency)
    }

    public static func - (lhs: Money, rhs: Money) -> Money {
        precondition(lhs.currency == rhs.currency, "Cannot subtract \(rhs.currency) from \(lhs.currency)")
        let (value, overflow) = lhs.minorUnits.subtractingReportingOverflow(rhs.minorUnits)
        precondition(!overflow, "Money overflow")
        return Money(minorUnits: value, currency: lhs.currency)
    }

    public static func += (lhs: inout Money, rhs: Money) { lhs = lhs + rhs }
    public static func -= (lhs: inout Money, rhs: Money) { lhs = lhs - rhs }

    public static func < (lhs: Money, rhs: Money) -> Bool {
        precondition(lhs.currency == rhs.currency, "Cannot compare \(lhs.currency) and \(rhs.currency)")
        return lhs.minorUnits < rhs.minorUnits
    }

    /// Multiplies by an exact decimal factor, rounding half-up to minor units.
    public func multiplied(by factor: Decimal) -> Money {
        Money.rounded(major: decimalValue * factor, currency: currency)
    }

    /// Splits into `parts` amounts that sum exactly to `self` (remainder spread over the first parts).
    public func allocated(into parts: Int) -> [Money] {
        precondition(parts > 0)
        let base = minorUnits / Int64(parts)
        let remainder = Int(minorUnits % Int64(parts))
        return (0..<parts).map { index in
            let extra: Int64 = index < abs(remainder) ? (remainder > 0 ? 1 : -1) : 0
            return Money(minorUnits: base + extra, currency: currency)
        }
    }

    /// Ratio of self to another amount, or nil when dividing by zero.
    public func ratio(to other: Money) -> Double? {
        precondition(currency == other.currency)
        guard other.minorUnits != 0 else { return nil }
        return Double(minorUnits) / Double(other.minorUnits)
    }

    static func pow10(_ exponent: Int) -> Decimal {
        var result = Decimal(1)
        for _ in 0..<max(exponent, 0) { result *= 10 }
        return result
    }
}

public extension Sequence where Element == Money {
    /// Sums amounts. All elements must share `currency`.
    func sum(currency: CurrencyCode = .myr) -> Money {
        reduce(Money.zero(currency), +)
    }
}
