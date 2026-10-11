import Foundation

/// Parses amounts as they appear in Malaysian bank statements, receipts and Shortcuts input.
///
/// Handles: "1,234.56", "RM 1,234.56", "RM1,234.56", "MYR 12.50", "-12.00", "12.00-",
/// "(12.00)", "12.00 DR", "12.00 CR", "12.5", "12". Optionally (lenient mode) "12,50".
///
/// Amounts with more than two decimal places are rejected rather than rounded.
public struct AmountParser: Sendable {
    public struct Result: Equatable, Sendable {
        public let money: Money
        /// Sign as written in the source: true when the text marked it negative / debit.
        public let isNegative: Bool
        /// Explicit DR/CR marker, when present.
        public let marker: DebitCreditMarker?
    }

    public enum DebitCreditMarker: String, Sendable { case debit, credit }

    public enum ParseError: Error, Equatable {
        case empty
        case invalidCharacters
        case tooManyDecimals
        case outOfRange
        case currencyMismatch(String)
    }

    /// Accept a single comma as decimal separator when there is no dot and exactly two digits follow
    /// (some device locales format Shortcuts amounts this way).
    public var lenientDecimalComma: Bool
    public var currency: CurrencyCode
    /// Upper bound protects against OCR garbage and unit mistakes (RM 10,000,000 by default).
    public var maximumMinorUnits: Int64

    public init(currency: CurrencyCode = .myr, lenientDecimalComma: Bool = false, maximumMinorUnits: Int64 = 1_000_000_000) {
        self.currency = currency
        self.lenientDecimalComma = lenientDecimalComma
        self.maximumMinorUnits = maximumMinorUnits
    }

    public func parse(_ input: String) throws -> Result {
        var text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { throw ParseError.empty }
        text = text.replacingOccurrences(of: "\u{00A0}", with: " ")
            .replacingOccurrences(of: "\u{2212}", with: "-") // unicode minus

        var negative = false
        var marker: DebitCreditMarker?

        let upper = text.uppercased()
        for (suffix, value) in [(" DR", DebitCreditMarker.debit), (" CR", .credit), ("DR", .debit), ("CR", .credit)] where upper.hasSuffix(suffix) {
            marker = value
            text = String(text.dropLast(suffix.count)).trimmingCharacters(in: .whitespaces)
            break
        }
        if marker == .debit { negative = true }

        if text.hasPrefix("(") && text.hasSuffix(")") {
            negative = true
            text = String(text.dropFirst().dropLast())
        }
        text = text.trimmingCharacters(in: .whitespaces)
        if text.hasPrefix("-") { negative = true; text.removeFirst() }
        if text.hasPrefix("+") { text.removeFirst() }
        if text.hasSuffix("-") { negative = true; text.removeLast() }

        // Currency symbol / code prefix or suffix.
        text = try stripCurrency(text.trimmingCharacters(in: .whitespaces))
        text = text.trimmingCharacters(in: .whitespaces)
        if text.hasPrefix("-") { negative = true; text.removeFirst() }

        guard !text.isEmpty else { throw ParseError.empty }
        let allowed = Set("0123456789.,")
        guard text.allSatisfy({ allowed.contains($0) }) else { throw ParseError.invalidCharacters }

        var normalized = text
        if lenientDecimalComma, !text.contains("."), text.filter({ $0 == "," }).count == 1,
           let commaIndex = text.firstIndex(of: ","), text.distance(from: commaIndex, to: text.endIndex) == 3 {
            normalized = text.replacingOccurrences(of: ",", with: ".")
        } else {
            // Commas are thousands separators: validate grouping.
            let integerPart = text.split(separator: ".", omittingEmptySubsequences: false).first.map(String.init) ?? ""
            if integerPart.contains(",") {
                let groups = integerPart.split(separator: ",", omittingEmptySubsequences: false)
                guard let first = groups.first, (1...3).contains(first.count),
                      groups.dropFirst().allSatisfy({ $0.count == 3 }) else { throw ParseError.invalidCharacters }
            }
            normalized = text.replacingOccurrences(of: ",", with: "")
        }

        let pieces = normalized.split(separator: ".", omittingEmptySubsequences: false)
        guard pieces.count <= 2, let wholePart = pieces.first else { throw ParseError.invalidCharacters }
        let fraction = pieces.count == 2 ? String(pieces[1]) : ""
        guard !(wholePart.isEmpty && fraction.isEmpty) else { throw ParseError.invalidCharacters }
        guard fraction.count <= currency.minorUnitDigits else { throw ParseError.tooManyDecimals }

        let paddedFraction = fraction + String(repeating: "0", count: currency.minorUnitDigits - fraction.count)
        let digits = (wholePart.isEmpty ? "0" : String(wholePart)) + paddedFraction
        guard digits.count <= 18, let value = Int64(digits) else { throw ParseError.outOfRange }
        guard value <= maximumMinorUnits else { throw ParseError.outOfRange }

        return Result(money: Money(minorUnits: value, currency: currency), isNegative: negative && value != 0, marker: marker)
    }

    private func stripCurrency(_ text: String) throws -> String {
        let upper = text.uppercased()
        let known: [(String, CurrencyCode)] = [("MYR", .myr), ("RM", .myr), ("SGD", .sgd), ("S$", .sgd), ("USD", .usd), ("US$", .usd), ("$", .usd)]
        for (token, code) in known {
            if upper.hasPrefix(token) {
                guard code == currency else { throw ParseError.currencyMismatch(code.rawValue) }
                return String(text.dropFirst(token.count))
            }
            if upper.hasSuffix(token) {
                guard code == currency else { throw ParseError.currencyMismatch(code.rawValue) }
                return String(text.dropLast(token.count))
            }
        }
        return text
    }
}
