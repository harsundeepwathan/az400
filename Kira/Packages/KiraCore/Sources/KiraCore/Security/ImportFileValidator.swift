import Foundation

/// Validates imported files before any parser touches them.
public struct ImportFileValidator: Sendable {
    public enum FileKind: String, Sendable, CaseIterable {
        case csv, pdf, image, text
    }

    public enum ValidationError: Error, Equatable, Sendable {
        case empty
        case tooLarge(limitBytes: Int)
        case unsupportedType(String)
        case contentMismatch(expected: FileKind)
        case undecodableText
        case tooManyRows(limit: Int)
    }

    public var maximumBytes: Int
    public var maximumRows: Int

    public init(maximumBytes: Int = 15 * 1024 * 1024, maximumRows: Int = 20_000) {
        self.maximumBytes = maximumBytes
        self.maximumRows = maximumRows
    }

    public func kind(forExtension ext: String) throws -> FileKind {
        switch ext.lowercased() {
        case "csv", "tsv": return .csv
        case "txt": return .text
        case "pdf": return .pdf
        case "jpg", "jpeg", "png", "heic", "heif": return .image
        case "xlsx", "xls": throw ValidationError.unsupportedType("Excel files aren’t supported yet. Export the statement as CSV or PDF.")
        default: throw ValidationError.unsupportedType(ext)
        }
    }

    /// Checks size and magic bytes so a renamed file cannot reach the wrong parser.
    public func validate(data: Data, fileExtension: String) throws -> FileKind {
        guard !data.isEmpty else { throw ValidationError.empty }
        guard data.count <= maximumBytes else { throw ValidationError.tooLarge(limitBytes: maximumBytes) }
        let kind = try kind(forExtension: fileExtension)
        let head = [UInt8](data.prefix(12))
        switch kind {
        case .pdf:
            guard head.starts(with: Array("%PDF-".utf8)) else { throw ValidationError.contentMismatch(expected: .pdf) }
        case .image:
            let isJPEG = head.starts(with: [0xFF, 0xD8, 0xFF])
            let isPNG = head.starts(with: [0x89, 0x50, 0x4E, 0x47])
            let isHEIF = head.count >= 12 && String(bytes: head[4..<8], encoding: .ascii) == "ftyp"
            guard isJPEG || isPNG || isHEIF else { throw ValidationError.contentMismatch(expected: .image) }
        case .csv, .text:
            // Binary files (zip/xlsx, executables) contain NUL bytes early on.
            if head.starts(with: [0x50, 0x4B, 0x03, 0x04]) { throw ValidationError.contentMismatch(expected: kind) }
            guard decodeText(data) != nil else { throw ValidationError.undecodableText }
        }
        return kind
    }

    /// Decodes UTF-8 (with/without BOM), UTF-16 (BOM) or Windows-1252, which covers bank CSV exports.
    public func decodeText(_ data: Data) -> String? {
        let bytes = [UInt8](data.prefix(4))
        if bytes.starts(with: [0xFF, 0xFE]) || bytes.starts(with: [0xFE, 0xFF]) {
            return String(data: data, encoding: .utf16)
        }
        if data.prefix(4096).contains(0) { return nil }
        if let utf8 = String(data: data, encoding: .utf8) {
            return utf8.hasPrefix("\u{FEFF}") ? String(utf8.dropFirst()) : utf8
        }
        return Self.decodeWindows1252(data)
    }

    /// Manual Windows-1252 decoding (not available in every Foundation implementation).
    static func decodeWindows1252(_ data: Data) -> String {
        let high: [UInt32] = [0x20AC, 0xFFFD, 0x201A, 0x0192, 0x201E, 0x2026, 0x2020, 0x2021, 0x02C6, 0x2030, 0x0160, 0x2039, 0x0152, 0xFFFD, 0x017D, 0xFFFD,
                              0xFFFD, 0x2018, 0x2019, 0x201C, 0x201D, 0x2022, 0x2013, 0x2014, 0x02DC, 0x2122, 0x0161, 0x203A, 0x0153, 0xFFFD, 0x017E, 0x0178]
        var scalars = String.UnicodeScalarView()
        for byte in data {
            let value: UInt32 = (0x80...0x9F).contains(byte) ? high[Int(byte) - 0x80] : UInt32(byte)
            scalars.append(Unicode.Scalar(value) ?? "\u{FFFD}")
        }
        return String(scalars)
    }
}
