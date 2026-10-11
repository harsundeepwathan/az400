import Foundation

/// Stable, non-cryptographic fingerprint (FNV-1a 64) used to recognise re-imports of the same
/// statement line. Not used for any security purpose.
public enum Fingerprint {
    public static func fnv1a(_ text: String) -> String {
        var hash: UInt64 = 0xcbf29ce484222325
        for byte in text.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x100000001b3
        }
        return String(format: "%016llx", hash)
    }

    /// Fingerprint for a statement row. `occurrence` distinguishes genuinely identical rows in the
    /// same file (two RM 2.00 parking charges on the same day).
    public static func statementRow(accountID: UUID?, date: Date, direction: TransactionDirection, amount: Money,
                                    description: String, reference: String?, occurrence: Int, calendar: KLCalendar = .shared) -> String {
        let day = calendar.calendar.dateComponents([.year, .month, .day], from: date)
        let parts = [
            accountID?.uuidString ?? "-",
            "\(day.year ?? 0)-\(day.month ?? 0)-\(day.day ?? 0)",
            direction.rawValue,
            "\(amount.minorUnits)\(amount.currency.rawValue)",
            MerchantNormalizer.key(description),
            reference ?? "",
            "\(occurrence)"
        ]
        return fnv1a(parts.joined(separator: "|"))
    }
}
