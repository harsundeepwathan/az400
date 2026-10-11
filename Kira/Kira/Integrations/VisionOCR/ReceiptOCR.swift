import Foundation
import Vision
import UIKit
import KiraCore

/// On-device text recognition with Apple Vision. Images never leave the device.
enum ReceiptOCR {
    enum OCRError: LocalizedError {
        case unreadableImage
        case noText

        var errorDescription: String? {
            switch self {
            case .unreadableImage: return "This image couldn’t be read."
            case .noText: return "No text was found. Try a clearer screenshot."
            }
        }
    }

    /// Languages requested, filtered to what this device's Vision revision supports
    /// (Malay is used when available; English always).
    static func languages(for request: VNRecognizeTextRequest) -> [String] {
        let supported = (try? request.supportedRecognitionLanguages()) ?? ["en-US"]
        return ["en-US", "ms-MY", "ms"].filter { supported.contains($0) }
    }

    static func recognize(_ image: CGImage) async throws -> [OCRLine] {
        // Vision work is synchronous and CPU-heavy: run it off the main actor.
        nonisolated(unsafe) let image = image
        return try await Task.detached(priority: .userInitiated) {
            let request = VNRecognizeTextRequest()
            request.recognitionLevel = .accurate
            request.usesLanguageCorrection = false // correction "fixes" amounts and references
            request.recognitionLanguages = languages(for: request)
            try VNImageRequestHandler(cgImage: image, options: [:]).perform([request])
            let observations = request.results ?? []
            // Reading order: top-to-bottom, then left-to-right (Vision's origin is bottom-left).
            let sorted = observations.sorted {
                abs($0.boundingBox.midY - $1.boundingBox.midY) > 0.01 ? $0.boundingBox.midY > $1.boundingBox.midY : $0.boundingBox.minX < $1.boundingBox.minX
            }
            let lines = sorted.compactMap { observation -> OCRLine? in
                guard let candidate = observation.topCandidates(1).first else { return nil }
                return OCRLine(candidate.string, confidence: Double(candidate.confidence))
            }
            guard !lines.isEmpty else { throw OCRError.noText }
            return lines
        }.value
    }

    static func recognize(data: Data) async throws -> [OCRLine] {
        guard let image = UIImage(data: data)?.cgImage else { throw OCRError.unreadableImage }
        return try await recognize(image)
    }

    /// Reads QR payloads from a screenshot or photo (e.g. a saved DuitNow QR image).
    static func detectQRCodes(data: Data) async throws -> [String] {
        guard let decoded = UIImage(data: data)?.cgImage else { throw OCRError.unreadableImage }
        nonisolated(unsafe) let image = decoded
        return try await Task.detached(priority: .userInitiated) {
            let request = VNDetectBarcodesRequest()
            request.symbologies = [.qr]
            try VNImageRequestHandler(cgImage: image, options: [:]).perform([request])
            return (request.results ?? []).compactMap(\.payloadStringValue)
        }.value
    }
}
