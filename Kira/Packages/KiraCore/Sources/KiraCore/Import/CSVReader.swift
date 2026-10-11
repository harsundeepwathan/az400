import Foundation

/// RFC 4180 CSV reader: quoted fields, escaped quotes, embedded newlines, CRLF, BOM,
/// and auto-detected delimiter (comma, semicolon or tab).
public enum CSVReader {
    public static func detectDelimiter(_ text: String) -> Character {
        let sample = text.split(separator: "\n", maxSplits: 10, omittingEmptySubsequences: true).prefix(10)
        let candidates: [Character] = [",", ";", "\t", "|"]
        return candidates.max { lhs, rhs in
            sample.reduce(0) { $0 + $1.filter { $0 == lhs }.count } < sample.reduce(0) { $0 + $1.filter { $0 == rhs }.count }
        } ?? ","
    }

    public static func rows(_ text: String, delimiter: Character? = nil) -> [[String]] {
        let source = text.hasPrefix("\u{FEFF}") ? String(text.dropFirst()) : text
        let separator = delimiter ?? detectDelimiter(source)
        var rows: [[String]] = []
        var row: [String] = []
        var field = ""
        var inQuotes = false
        var iterator = Array(source).makeIterator()
        var pending: Character? = nil

        func nextCharacter() -> Character? {
            if let value = pending { pending = nil; return value }
            return iterator.next()
        }

        while let character = nextCharacter() {
            if inQuotes {
                if character == "\"" {
                    if let next = nextCharacter() {
                        if next == "\"" { field.append("\"") } else { inQuotes = false; pending = next }
                    } else {
                        inQuotes = false
                    }
                } else {
                    field.append(character)
                }
                continue
            }
            switch character {
            case "\"" where field.isEmpty:
                inQuotes = true
            case separator:
                row.append(field); field = ""
            case "\r\n", "\n", "\r":
                row.append(field); field = ""
                if !(row.count == 1 && row[0].isEmpty) { rows.append(row) }
                row = []
            default:
                field.append(character)
            }
        }
        if !field.isEmpty || !row.isEmpty {
            row.append(field)
            if !(row.count == 1 && row[0].isEmpty) { rows.append(row) }
        }
        return rows.map { $0.map { $0.trimmingCharacters(in: .whitespaces) } }
    }
}
