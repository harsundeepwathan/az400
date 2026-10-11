import Foundation

/// Cleans raw statement / receipt merchant strings into a comparable key.
///
/// "GRAB* A-5XYZ123 KUALA LUMPUR MY" → "GRAB"
/// "ZUS COFFEE - SS15 SUBANG"          → "ZUS COFFEE SS15 SUBANG"
/// "LOTUSS STORES (M) SDN BHD"         → "LOTUSS STORES"
public enum MerchantNormalizer {
    private static let corporateSuffixes = ["SDN BHD", "SDN. BHD.", "BHD", "BERHAD", "(M)", "PLT", "ENTERPRISE", "TRADING", "RESOURCES"]
    private static let noisePrefixes = ["POS ", "PURCHASE ", "DEBIT CARD ", "VISA ", "MASTERCARD ", "MC ", "IBG ", "DUITNOW QR ", "DUITNOW ", "QR PAYMENT ",
                                        "QRPAY ", "SALE ", "PEMBELIAN ", "BELIAN ", "PAYMENT TO ", "PYMT ", "FPX ", "JOMPAY "]
    private static let trailingNoise: Set<String> = ["MY", "MYS", "MAL", "MALAYSIA", "KUALA", "LUMPUR", "KL", "SELANGOR", "PETALING", "JAYA", "PJ"]

    public static func key(_ raw: String) -> String {
        var text = raw.uppercased()
            .replacingOccurrences(of: "’", with: "'")
            .replacingOccurrences(of: "&AMP;", with: "&")

        // "GRAB*ABC123" / "SQ *SHOP": keep the brand before the asterisk.
        if let star = text.firstIndex(of: "*") {
            let head = text[..<star].trimmingCharacters(in: .whitespaces)
            if head.count >= 2 { text = head }
        }

        var changed = true
        while changed {
            changed = false
            for prefix in noisePrefixes where text.hasPrefix(prefix) {
                text = String(text.dropFirst(prefix.count)); changed = true
            }
        }
        for suffix in corporateSuffixes {
            text = text.replacingOccurrences(of: suffix, with: " ")
        }

        // Keep letters, digits, '&' and spaces; drop punctuation.
        let scalars = text.unicodeScalars.map { scalar -> Character in
            if CharacterSet.alphanumerics.contains(scalar) || scalar == "&" { return Character(scalar) }
            return " "
        }
        var tokens = String(scalars).split(separator: " ").map(String.init)
        // Drop reference-like tokens (long digit runs or mixed tokens with 4+ digits).
        tokens = tokens.filter { token in
            let digitCount = token.filter(\.isNumber).count
            return !(digitCount >= 4 && digitCount * 2 >= token.count)
        }
        while let last = tokens.last, tokens.count > 1, trailingNoise.contains(last) { tokens.removeLast() }
        return tokens.joined(separator: " ")
    }

    /// Title-cases a cleaned key for display ("ZUS COFFEE" → "Zus Coffee"), preserving short all-caps brands.
    public static func displayName(_ raw: String) -> String {
        let cleaned = key(raw)
        guard !cleaned.isEmpty else { return raw.trimmingCharacters(in: .whitespaces) }
        return cleaned.split(separator: " ").map { word -> String in
            if word.count <= 3 && word.allSatisfy(\.isLetter) && ["KFC", "AEON", "MR", "DIY", "TNB", "IKEA"].contains(String(word)) {
                return String(word)
            }
            return word.prefix(1) + word.dropFirst().lowercased()
        }.joined(separator: " ")
    }
}

/// Token-based similarity used by reconciliation and rule matching.
public enum TextSimilarity {
    /// Jaccard similarity over normalised merchant tokens, boosted when one key contains the other.
    public static func merchant(_ lhs: String?, _ rhs: String?) -> Double {
        guard let lhs, let rhs else { return 0 }
        let a = MerchantNormalizer.key(lhs), b = MerchantNormalizer.key(rhs)
        guard !a.isEmpty, !b.isEmpty else { return 0 }
        if a == b { return 1 }
        if a.contains(b) || b.contains(a) { return 0.85 }
        let ta = Set(a.split(separator: " ")), tb = Set(b.split(separator: " "))
        let jaccard = Double(ta.intersection(tb).count) / Double(ta.union(tb).count)
        return max(jaccard, 1 - Double(levenshtein(a, b)) / Double(max(a.count, b.count)))
    }

    public static func levenshtein(_ lhs: String, _ rhs: String) -> Int {
        let a = Array(lhs), b = Array(rhs)
        if a.isEmpty { return b.count }
        if b.isEmpty { return a.count }
        var previous = Array(0...b.count)
        var current = Array(repeating: 0, count: b.count + 1)
        for i in 1...a.count {
            current[0] = i
            for j in 1...b.count {
                current[j] = min(previous[j] + 1, current[j - 1] + 1, previous[j - 1] + (a[i - 1] == b[j - 1] ? 0 : 1))
            }
            swap(&previous, &current)
        }
        return previous[b.count]
    }
}
