import SwiftUI
import PhotosUI
import KiraCore

/// Scan → review → save draft. The draft is never counted as spending: the user pays in their
/// own banking app, then confirms (or imports the receipt, which matches and confirms the draft).
struct DuitNowScanFlow: View {
    @Environment(FinanceStore.self) private var store
    var onFinished: () -> Void

    @State private var payload: DuitNowQRPayload?
    @State private var errorMessage: String?
    @State private var cameraAllowed: Bool?
    @State private var photoItem: PhotosPickerItem?
    @State private var amountText = ""
    @State private var accountID: UUID?
    @State private var saved = false

    private let parser = DuitNowQRParser()

    var body: some View {
        Group {
            if let payload {
                review(payload)
            } else {
                scanner
            }
        }
        .kiraScreen()
        .navigationTitle("DuitNow QR")
        .navigationBarTitleDisplayMode(.inline)
        .task { await checkCamera() }
        .onChange(of: photoItem) { _, item in Task { await readPhoto(item) } }
    }

    // MARK: Scanner

    private var scanner: some View {
        VStack(spacing: KiraSpacing.l) {
            if cameraAllowed == true {
                QRScannerView(onScan: handle, onError: { errorMessage = $0 })
                    .clipShape(RoundedRectangle(cornerRadius: KiraRadius.hero, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: KiraRadius.hero, style: .continuous).strokeBorder(.white.opacity(0.6), lineWidth: 2).padding(48))
                    .frame(maxHeight: 420)
                    .accessibilityLabel("Camera viewfinder. Point at a DuitNow QR code.")
            } else if cameraAllowed == false {
                EmptyStateView(symbol: "camera", title: "Camera access is off",
                               message: "Allow camera access in Settings to scan QR codes, or choose a QR screenshot instead.")
            } else {
                ProgressView()
            }
            if let errorMessage { NoticeBanner(tone: .error, text: errorMessage) }
            PhotosPicker(selection: $photoItem, matching: .images) {
                Label("Choose QR from Photos", systemImage: "photo")
            }
            Text("Scanning only reads the merchant’s details. It doesn’t make or confirm a payment.")
                .font(.footnote).foregroundStyle(KiraColor.textSecondary).multilineTextAlignment(.center)
        }
        .padding(KiraSpacing.l)
    }

    private func checkCamera() async {
        switch QRScannerView.authorizationStatus {
        case .authorized: cameraAllowed = true
        case .notDetermined: cameraAllowed = await QRScannerView.requestAccess()
        default: cameraAllowed = false
        }
    }

    private func readPhoto(_ item: PhotosPickerItem?) async {
        guard let item, let data = try? await item.loadTransferable(type: Data.self) else { return }
        do {
            guard let code = try await ReceiptOCR.detectQRCodes(data: data).first else {
                errorMessage = "No QR code found in that image."; return
            }
            handle(code)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func handle(_ code: String) {
        do {
            let parsed = try parser.parse(code)
            payload = parsed
            errorMessage = nil
            amountText = parsed.amount.map { MoneyFormatter(signStyle: .never, spaceAfterSymbol: false).string(from: $0).replacingOccurrences(of: "RM", with: "") } ?? ""
        } catch let error as DuitNowQRParser.ParseError {
            errorMessage = Self.message(for: error)
            Haptics.warning()
        } catch {
            errorMessage = "This QR code couldn’t be read."
        }
    }

    static func message(for error: DuitNowQRParser.ParseError) -> String {
        switch error {
        case .notEMVQR: return "This isn’t a payment QR code."
        case .crcMismatch: return "This QR code failed its integrity check. It may be damaged or altered — don’t pay with it."
        case .missingMandatoryField(let field): return "This QR code is missing required information (\(field))."
        case .invalidAmount: return "The amount in this QR code is invalid."
        case .empty, .malformed, .crcMissing, .payloadTooLong: return "This QR code couldn’t be read."
        }
    }

    // MARK: Review

    private func review(_ payload: DuitNowQRPayload) -> some View {
        Form {
            Section {
                VStack(alignment: .leading, spacing: 6) {
                    Text(payload.merchantDescriptor ?? payload.merchantName).font(.title3.weight(.semibold))
                    Text([payload.merchantCity, payload.postalCode].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " "))
                        .font(.subheadline).foregroundStyle(KiraColor.textSecondary)
                    HStack(spacing: KiraSpacing.s) {
                        Label(payload.isDuitNow ? "DuitNow" : "Other EMV QR", systemImage: payload.isDuitNow ? "checkmark.shield" : "exclamationmark.shield")
                        Text(payload.initiation == .dynamicQR ? "Dynamic" : "Static")
                        if payload.isPersonToPerson { Text("Person-to-person") }
                    }
                    .font(.caption).foregroundStyle(KiraColor.textSecondary)
                }
            }
            Section("Amount") {
                if let amount = payload.amount {
                    MoneyText(money: amount, font: .kiraFigure)
                } else {
                    TextField("Amount you’ll pay (optional)", text: $amountText).keyboardType(.decimalPad)
                }
                Picker("Paying from", selection: $accountID) {
                    Text("Not specified").tag(UUID?.none)
                    ForEach(store.activeAccounts) { Text($0.name).tag(Optional($0.id)) }
                }
            }
            if !payload.warnings.isEmpty {
                Section { ForEach(payload.warnings, id: \.self) { NoticeBanner(tone: .caution, text: Self.text(for: $0)) } }
            }
            Section {
                Button(saved ? "Draft saved" : "Save as draft", action: { save(payload) })
                    .disabled(saved)
            } footer: {
                Text("Pay in your banking or e-wallet app as usual. Then share the receipt to Kira, or confirm the draft in Activity.")
            }
            if saved {
                Section { Button("Done", action: onFinished) }
            }
        }
    }

    static func text(for warning: DuitNowQRParser.Warning) -> String {
        switch warning {
        case .notDuitNow: return "Not a DuitNow code. Details may be incomplete."
        case .nonMalaysianCountry: return "This merchant is registered outside Malaysia."
        case .unsupportedCurrency: return "The currency isn’t Ringgit. It won’t be included in RM totals."
        case .amountOnStaticQR: return "A fixed amount was found on a static code. Check it matches what you’re paying."
        case .dynamicWithoutAmount: return "This dynamic code has no amount."
        case .merchantNameTruncated: return "The merchant name may be shortened."
        case .invalidPostalCode: return "The postcode in this code looks invalid."
        }
    }

    private func save(_ payload: DuitNowQRPayload) {
        var draft = DuitNowDraftFactory.draft(from: payload, accountID: accountID, scannedAt: Date(), engine: store.categoryEngine, rules: store.rules)
        if payload.amount == nil, let entered = try? AmountParser().parse(amountText).money, !entered.isZero {
            draft.amount = entered
            draft.flags.remove(.amountMissing)
        }
        store.upsert([draft])
        saved = true
        Haptics.success()
    }
}
