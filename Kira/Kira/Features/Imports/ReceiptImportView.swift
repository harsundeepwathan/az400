import SwiftUI
import PhotosUI
import UniformTypeIdentifiers
import KiraCore

/// Receipt screenshot/photo → on-device OCR → extracted fields → reconciliation review.
struct ReceiptImportView: View {
    @Environment(FinanceStore.self) private var store
    var onFinished: () -> Void

    @State private var photoItem: PhotosPickerItem?
    @State private var isWorking = false
    @State private var extraction: ReceiptExtraction?
    @State private var errorMessage: String?
    @State private var accountID: UUID?
    @State private var review: ImportReview?

    var body: some View {
        Form {
            Section {
                PhotosPicker(selection: $photoItem, matching: .images) {
                    Label(extraction == nil ? "Choose receipt screenshot" : "Choose a different image", systemImage: "photo.on.rectangle")
                }
                if isWorking { HStack { ProgressView(); Text("Reading on your iPhone…").foregroundStyle(KiraColor.textSecondary) } }
            } footer: {
                Text("Text is recognised on-device with Apple Vision. The image isn’t uploaded or stored.")
            }

            if let errorMessage { Section { NoticeBanner(tone: .error, text: errorMessage) } }

            if let extraction {
                Section("What Kira found") {
                    LabeledContent("Amount") {
                        if let amount = extraction.amount { MoneyText(money: amount) } else { Text("Not found").foregroundStyle(KiraColor.error) }
                    }
                    LabeledContent("Paid to", value: extraction.counterparty ?? "Not found")
                    LabeledContent("Date", value: extraction.date?.kiraWithTime ?? "Not found — today will be used")
                    LabeledContent("Reference", value: extraction.reference ?? "Not found")
                    LabeledContent("Status", value: statusText(extraction.status))
                    if let channel = extraction.channel { LabeledContent("Method", value: channel.displayName) }
                    LabeledContent("Confidence", value: PercentFormatter.string(extraction.confidence))
                }
                if extraction.confidence < 0.7 {
                    Section { NoticeBanner(tone: .caution, text: "Some details are uncertain. You can correct them after saving.") }
                }
                Section {
                    Picker("Account", selection: $accountID) {
                        Text("Not specified").tag(UUID?.none)
                        ForEach(store.activeAccounts) { Text($0.name).tag(Optional($0.id)) }
                    }
                    Button("Continue", action: prepare).disabled(!extraction.isUsable)
                } footer: {
                    if extraction.status == .failed { Text("This receipt shows a failed payment, so nothing will be recorded.") }
                }
            }
        }
        .kiraScreen()
        .navigationTitle("Import receipt")
        .navigationBarTitleDisplayMode(.inline)
        .onChange(of: photoItem) { _, item in Task { await read(item) } }
        .navigationDestination(item: $review) { review in
            ReconciliationReviewView(review: review, onCommitted: onFinished)
        }
    }

    private func statusText(_ status: ReceiptPaymentStatus) -> String {
        switch status {
        case .successful: return "Successful"
        case .failed: return "Failed"
        case .pending: return "Pending"
        case .unknown: return "Not shown"
        }
    }

    private func read(_ item: PhotosPickerItem?) async {
        guard let item else { return }
        isWorking = true
        defer { isWorking = false }
        errorMessage = nil
        extraction = nil
        do {
            guard let data = try await item.loadTransferable(type: Data.self) else { throw ReceiptOCR.OCRError.unreadableImage }
            _ = try ImportFileValidator().validate(data: data, fileExtension: Self.imageExtension(data))
            let lines = try await ReceiptOCR.recognize(data: data)
            extraction = ReceiptTextExtractor().extract(lines)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    static func imageExtension(_ data: Data) -> String {
        let head = [UInt8](data.prefix(4))
        if head.starts(with: [0x89, 0x50]) { return "png" }
        if head.starts(with: [0xFF, 0xD8]) { return "jpg" }
        return "heic"
    }

    private func prepare() {
        guard let extraction else { return }
        guard store.canImport else {
            errorMessage = "You’ve used this month’s free imports. Kira Plus includes unlimited imports — or add it manually."
            return
        }
        do {
            let record = try ReceiptTransactionFactory.record(from: extraction, accountID: accountID, engine: store.categoryEngine, rules: store.rules)
            review = store.prepareReview([record], source: .receiptImage, profileID: nil, fileName: "Receipt")
        } catch {
            errorMessage = "This receipt can’t be recorded: \(error.localizedDescription)"
        }
    }
}

extension ImportReview: Hashable {
    static func == (lhs: ImportReview, rhs: ImportReview) -> Bool { lhs.id == rhs.id }
    func hash(into hasher: inout Hasher) { hasher.combine(id) }
}
