import SwiftUI
import UniformTypeIdentifiers
import KiraCore

/// Statement import: pick institution profile + account, choose CSV/PDF, preview, reconcile.
struct StatementImportView: View {
    @Environment(FinanceStore.self) private var store
    var onFinished: () -> Void

    @State private var profileID = "generic"
    @State private var accountID: UUID?
    @State private var showingPicker = false
    @State private var isWorking = false
    @State private var errorMessage: String?
    @State private var review: ImportReview?
    @State private var pdfPassword = ""
    @State private var pendingPDF: (data: Data, name: String)?

    var body: some View {
        Form {
            Section {
                Picker("Bank or e-wallet", selection: $profileID) {
                    ForEach(ImportProfile.all) { Text($0.displayName).tag($0.id) }
                }
                Picker("Into account", selection: $accountID) {
                    Text("Choose…").tag(UUID?.none)
                    ForEach(store.activeAccounts) { Text($0.name).tag(Optional($0.id)) }
                }
            } footer: {
                Text("Choosing the account keeps transfers between your own accounts from being counted twice.")
            }

            Section {
                Button { showingPicker = true } label: { Label("Choose CSV or PDF statement", systemImage: "doc.badge.plus") }
                    .disabled(isWorking)
                if isWorking { HStack { ProgressView(); Text("Reading statement…").foregroundStyle(KiraColor.textSecondary) } }
                if let remaining = store.gate.remainingFreeImports(importsThisMonth: store.importsThisMonth()) {
                    Text("\(remaining) free import\(remaining == 1 ? "" : "s") left this month").font(.footnote).foregroundStyle(KiraColor.textSecondary)
                }
            } footer: {
                Text("Files are read on your iPhone. Excel files aren’t supported yet — export as CSV or PDF from your bank.")
            }

            if pendingPDF != nil {
                Section("Password-protected PDF") {
                    SecureField("PDF password", text: $pdfPassword).textContentType(.password)
                    Button("Unlock and import") { if let pending = pendingPDF { Task { await importPDF(pending.data, name: pending.name) } } }
                }
            }

            if let errorMessage { Section { NoticeBanner(tone: .error, text: errorMessage) } }
        }
        .kiraScreen()
        .navigationTitle("Import statement")
        .navigationBarTitleDisplayMode(.inline)
        .fileImporter(isPresented: $showingPicker, allowedContentTypes: [.commaSeparatedText, .pdf, .plainText, .tabSeparatedText]) { result in
            Task { await handle(result) }
        }
        .navigationDestination(item: $review) { review in
            ReconciliationReviewView(review: review, onCommitted: onFinished)
        }
    }

    private var context: ImportContext? {
        guard let profile = ImportProfile.profile(id: profileID) else { return nil }
        let source: ImportSource = profile.institution.isEWallet ? .eWalletStatement : .bankStatementCSV
        return ImportContext(account: store.account(accountID), profile: profile, source: source, rules: store.rules,
                             engine: store.categoryEngine, statementDate: nil, now: Date())
    }

    private func handle(_ result: Result<URL, Error>) async {
        errorMessage = nil
        guard store.canImport else {
            errorMessage = "You’ve used this month’s free imports. Kira Plus includes unlimited imports."
            return
        }
        guard case .success(let url) = result else { return }
        let accessing = url.startAccessingSecurityScopedResource()
        defer { if accessing { url.stopAccessingSecurityScopedResource() } }
        do {
            let data = try Data(contentsOf: url, options: [.mappedIfSafe])
            let validator = ImportFileValidator()
            let kind = try validator.validate(data: data, fileExtension: url.pathExtension)
            switch kind {
            case .csv, .text:
                guard let text = validator.decodeText(data), var context else { throw ImportFileValidator.ValidationError.undecodableText }
                if kind == .text {
                    context.source = context.profile.institution.isEWallet ? .eWalletStatement : .bankStatementPDF
                    present(try StatementTextParser().parse(text, context: context), context: context, fileName: url.lastPathComponent)
                } else {
                    present(try CSVStatementImporter().parse(text, context: context), context: context, fileName: url.lastPathComponent)
                }
            case .pdf:
                await importPDF(data, name: url.lastPathComponent)
            case .image:
                errorMessage = "For screenshots, use Import receipt."
            }
        } catch {
            errorMessage = Self.describe(error)
        }
    }

    private func importPDF(_ data: Data, name: String) async {
        isWorking = true
        defer { isWorking = false }
        do {
            let (text, usedOCR) = try await PDFTextExtractor.extract(data: data, password: pdfPassword.isEmpty ? nil : pdfPassword)
            pendingPDF = nil
            pdfPassword = ""
            guard var context else { return }
            context.source = context.profile.institution.isEWallet ? .eWalletStatement : .bankStatementPDF
            var result = try StatementTextParser().parse(text, context: context)
            if usedOCR { result.warnings.insert("Some pages were scanned images and were read with OCR. Check amounts carefully.", at: 0) }
            present(result, context: context, fileName: name)
        } catch PDFTextExtractor.PDFError.locked {
            pendingPDF = (data, name)
            errorMessage = PDFTextExtractor.PDFError.locked.localizedDescription
        } catch {
            errorMessage = Self.describe(error)
        }
    }

    private func present(_ result: ImportResult, context: ImportContext, fileName: String) {
        review = store.prepareReview(result.transactions, source: context.source, profileID: context.profile.id,
                                     fileName: fileName, warnings: result.warnings, skipped: result.skipped)
    }

    static func describe(_ error: Error) -> String {
        switch error {
        case StatementImportError.noHeaderRow:
            return "Kira couldn’t find the column headings (date, description, amount). This layout isn’t supported yet."
        case StatementImportError.missingColumns(let columns):
            return "This file is missing: \(columns.map(\.rawValue).joined(separator: ", "))."
        case StatementImportError.noTransactions:
            return "No transactions were found in this file."
        case ImportFileValidator.ValidationError.tooLarge:
            return "This file is too large to import."
        case ImportFileValidator.ValidationError.contentMismatch:
            return "This file’s contents don’t match its type."
        case ImportFileValidator.ValidationError.unsupportedType(let message):
            return message.contains(" ") ? message : "“.\(message)” files aren’t supported."
        default:
            return error.localizedDescription
        }
    }
}
