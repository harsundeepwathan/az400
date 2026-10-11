import Foundation
import PDFKit
import KiraCore

/// Extracts text from statement PDFs. Text-based PDFs use PDFKit directly; image-only (scanned)
/// pages fall back to on-device OCR. Password-protected PDFs must be unlocked by the user first.
enum PDFTextExtractor {
    enum PDFError: LocalizedError {
        case unreadable
        case locked
        case tooManyPages(Int)

        var errorDescription: String? {
            switch self {
            case .unreadable: return "This PDF couldn’t be opened."
            case .locked: return "This PDF is password-protected. Enter its password to import it."
            case .tooManyPages(let limit): return "Statements longer than \(limit) pages aren’t supported yet."
            }
        }
    }

    static let maximumPages = 30

    static func extract(data: Data, password: String? = nil) async throws -> (text: String, usedOCR: Bool) {
        guard let document = PDFDocument(data: data) else { throw PDFError.unreadable }
        if document.isLocked {
            guard let password, document.unlock(withPassword: password) else { throw PDFError.locked }
        }
        guard document.pageCount <= maximumPages else { throw PDFError.tooManyPages(maximumPages) }

        var pages: [String] = []
        var usedOCR = false
        for index in 0..<document.pageCount {
            guard let page = document.page(at: index) else { continue }
            let text = page.string ?? ""
            if text.trimmingCharacters(in: .whitespacesAndNewlines).count > 20 {
                pages.append(text)
            } else {
                // Scanned page: render at 2× and OCR on-device.
                let bounds = page.bounds(for: .mediaBox)
                let image = page.thumbnail(of: CGSize(width: bounds.width * 2, height: bounds.height * 2), for: .mediaBox)
                if let cgImage = image.cgImage, let lines = try? await ReceiptOCR.recognize(cgImage) {
                    pages.append(lines.map(\.text).joined(separator: "\n"))
                    usedOCR = true
                }
            }
        }
        return (pages.joined(separator: "\n"), usedOCR)
    }
}
