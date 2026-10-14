import SwiftUI
import KiraCore

/// Create or edit a transaction with strict input validation.
struct TransactionEditorView: View {
    enum Mode {
        case create(TransactionRecord?)
        case edit(TransactionRecord)
    }

    @Environment(FinanceStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    let mode: Mode
    var onSaved: (() -> Void)?

    @State private var amountText = ""
    @State private var direction: TransactionDirection = .outflow
    @State private var kind: TransactionKind = .expense
    @State private var merchant = ""
    @State private var categoryID: String?
    @State private var date = Date()
    @State private var accountID: UUID?
    @State private var channel: PaymentChannel = .card
    @State private var notes = ""
    @State private var amountError: String?
    @State private var loaded = false
    @FocusState private var amountFocused: Bool

    private var original: TransactionRecord? {
        switch mode {
        case .create(let draft): return draft
        case .edit(let record): return record
        }
    }

    var body: some View {
        Form {
            Section {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text("RM").font(.title2.weight(.semibold)).foregroundStyle(KiraColor.textSecondary)
                    TextField("0.00", text: $amountText)
                        .font(.kiraHero).monospacedDigit()
                        .keyboardType(.decimalPad)
                        .focused($amountFocused)
                        .accessibilityLabel("Amount in ringgit")
                }
                if let amountError {
                    Text(amountError).font(.footnote).foregroundStyle(KiraColor.error)
                }
                Picker("Direction", selection: $direction) {
                    Text("Money out").tag(TransactionDirection.outflow)
                    Text("Money in").tag(TransactionDirection.inflow)
                }
                .pickerStyle(.segmented)
            }

            Section {
                TextField("Merchant or payee", text: $merchant)
                    .textInputAutocapitalization(.words)
                    .onSubmit(suggestCategory)
                Picker("Type", selection: $kind) {
                    ForEach(kindsForDirection, id: \.self) { Text($0.displayName).tag($0) }
                }
                if kind == .expense || kind == .refund || kind == .fee || kind == .reversal {
                    Picker("Category", selection: $categoryID) {
                        Text("Suggest for me").tag(String?.none)
                        ForEach(store.categories) { category in
                            Label(category.name, systemImage: category.symbol).tag(Optional(category.id))
                        }
                    }
                }
                DatePicker("Date", selection: $date, in: ...Date().addingTimeInterval(86_400))
            }

            Section {
                Picker("Account", selection: $accountID) {
                    Text("Not specified").tag(UUID?.none)
                    ForEach(store.activeAccounts) { Text($0.name).tag(Optional($0.id)) }
                }
                Picker("Paid with", selection: $channel) {
                    ForEach(PaymentChannel.allCases, id: \.self) { Text($0.displayName).tag($0) }
                }
                TextField("Notes", text: $notes, axis: .vertical).lineLimit(1...4)
            }
        }
        .kiraScreen()
        .navigationTitle(isEditing ? "Edit transaction" : "New transaction")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            CloseToolbarItem { dismiss() }
            ConfirmToolbarItem(title: "Save", action: save)
        }
        .onAppear(perform: loadIfNeeded)
        .sensoryFeedback(trigger: amountError) { _, new in new == nil ? nil : .warning }
        .onChange(of: direction) { _, new in
            if let expected = kind.expectedDirection, expected != new { kind = new == .outflow ? .expense : .income }
        }
    }

    private var isEditing: Bool { if case .edit = mode { return true } else { return false } }

    private var kindsForDirection: [TransactionKind] {
        TransactionKind.allCases.filter { $0.expectedDirection == nil || $0.expectedDirection == direction }
    }

    private func loadIfNeeded() {
        guard !loaded else { return }
        loaded = true
        guard let record = original else { amountFocused = true; return }
        if !record.flags.contains(.amountMissing) {
            amountText = MoneyFormatter(signStyle: .never, spaceAfterSymbol: false).string(from: record.amount).replacingOccurrences(of: "RM", with: "")
        }
        direction = record.direction
        kind = record.kind
        merchant = record.merchant ?? ""
        categoryID = record.categoryID
        date = record.transactionDate
        accountID = record.accountID
        channel = record.channel
        notes = record.notes ?? ""
    }

    private func suggestCategory() {
        guard categoryID == nil, !merchant.isEmpty else { return }
        let result = store.categoryEngine.categorise(merchant: merchant, description: merchant, rules: store.rules)
        if result.confidence >= store.categoryEngine.reviewThreshold { categoryID = result.categoryID }
        if let hint = result.kindHint, hint.expectedDirection == nil || hint.expectedDirection == direction { kind = hint }
    }

    private func save() {
        let parsed: Money
        do {
            let result = try AmountParser().parse(amountText)
            guard !result.money.isZero else { amountError = "Enter an amount above RM 0."; return }
            parsed = result.money
        } catch AmountParser.ParseError.tooManyDecimals {
            amountError = "Use at most two decimal places."; return
        } catch {
            amountError = "Enter an amount like 12.50."; return
        }
        amountError = nil

        let cleanMerchant = InputSanitizer.cleanOptional(merchant, maxLength: 80)
        let cleanNotes = InputSanitizer.cleanOptional(notes, maxLength: 500)
        let now = Date()

        if case .edit(let previous) = mode {
            var record = previous
            record.amount = parsed
            record.direction = direction
            record.kind = kind
            record.merchant = cleanMerchant
            record.categoryID = categoryID ?? previous.categoryID
            record.transactionDate = date
            record.accountID = accountID
            record.channel = channel
            record.notes = cleanNotes
            store.update(record, previous: previous)
        } else {
            var record = original ?? TransactionRecord(amount: parsed, direction: direction, kind: kind, transactionDate: date)
            record.amount = parsed
            record.direction = direction
            record.kind = kind
            record.merchant = cleanMerchant
            record.transactionDescription = cleanMerchant ?? ""
            record.categoryID = categoryID
            record.categoryIsUserSet = categoryID != nil
            record.transactionDate = date
            record.accountID = accountID
            record.channel = channel
            record.notes = cleanNotes
            record.status = .confirmed
            record.flags.remove(.amountMissing)
            record.flags.remove(.unconfirmedPayment)
            record.createdAt = original?.createdAt ?? now
            record.updatedAt = now
            store.addManual(record)
        }
        onSaved?()
        dismiss()
    }
}
