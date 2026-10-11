import Foundation

/// Central input hygiene for every untrusted string: QR payloads, OCR output, CSV cells,
/// Shortcuts parameters and user text.
public enum InputSanitizer {
    /// Removes control/format characters (incl. bidi overrides), collapses whitespace and limits length.
    public static func cleanText(_ text: String, maxLength: Int = 200) -> String {
        let filtered = text.unicodeScalars.filter { scalar in
            if scalar == " " { return true }
            if CharacterSet.controlCharacters.contains(scalar) { return false }
            // Unicode "Cf" format characters include RTL/LTR overrides used for spoofing.
            if scalar.properties.generalCategory == .format { return false }
            return true
        }
        let collapsed = String(String.UnicodeScalarView(filtered))
            .split(whereSeparator: { $0.isWhitespace })
            .joined(separator: " ")
        return String(collapsed.prefix(maxLength))
    }

    /// Optional variant: returns nil for empty results.
    public static func cleanOptional(_ text: String?, maxLength: Int = 200) -> String? {
        guard let text else { return nil }
        let cleaned = cleanText(text, maxLength: maxLength)
        return cleaned.isEmpty ? nil : cleaned
    }

    /// Neutralises spreadsheet formula injection when exporting to CSV (OWASP "CSV Injection").
    public static func csvSafeCell(_ value: String) -> String {
        var cell = value
        if let first = cell.first, ["=", "+", "-", "@", "\t", "\r"].contains(first) {
            // Allow plain negative numbers through untouched.
            let isNumber = Double(cell.replacingOccurrences(of: ",", with: "")) != nil
            if !isNumber { cell = "'" + cell }
        }
        if cell.contains(",") || cell.contains("\"") || cell.contains("\n") || cell.contains("\r") {
            cell = "\"" + cell.replacingOccurrences(of: "\"", with: "\"\"") + "\""
        }
        return cell
    }

    /// Masks account / card numbers for display and logs: keeps the last four digits.
    public static func maskAccountNumber(_ value: String) -> String {
        let digits = value.filter(\.isNumber)
        guard digits.count > 4 else { return digits }
        return String(repeating: "•", count: 4) + " " + digits.suffix(4)
    }

    /// Redacts long digit runs (account numbers, IC numbers, phone numbers) from free text before logging.
    public static func redactForLogging(_ text: String) -> String {
        var output = ""
        var run = ""
        func flush() {
            output += run.count >= 6 ? String(repeating: "#", count: run.count) : run
            run = ""
        }
        for character in text {
            if character.isNumber { run.append(character) } else { flush(); output.append(character) }
        }
        flush()
        return output
    }
}
