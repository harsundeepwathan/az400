import SwiftUI
import KiraCore

/// Add or edit a subscription. Picking a known service fills the name, icon and category;
/// the price is always entered by the user because plans and prices vary.
struct SubscriptionEditorView: View {
    @Environment(FinanceStore.self) private var store
    @Environment(\.dismiss) private var dismiss

    /// One-time seeds: edits stay local until Save.
    @State private var draft: ServiceSubscription
    @State private var amountText: String
    @State private var currency: CurrencyCode
    @State private var cycleChoice: CycleChoice
    @State private var reminderChoice: Int
    @State private var error: String?
    private let isNew: Bool

    enum CycleChoice: String, CaseIterable, Identifiable {
        case weekly = "Weekly", monthly = "Monthly", quarterly = "Every 3 Months", halfYearly = "Every 6 Months", yearly = "Yearly"
        var id: String { rawValue }

        var cycle: BillingCycle {
            switch self {
            case .weekly: return .weekly
            case .monthly: return .monthly
            case .quarterly: return .quarterly
            case .halfYearly: return .everyMonths(6)
            case .yearly: return .yearly
            }
        }

        init(_ cycle: BillingCycle) {
            switch cycle {
            case .weekly: self = .weekly
            case .monthly: self = .monthly
            case .quarterly: self = .quarterly
            case .yearly: self = .yearly
            case .everyMonths(let months): self = months == 6 ? .halfYearly : (months == 3 ? .quarterly : (months >= 12 ? .yearly : .monthly))
            }
        }
    }

    /// -1 = no reminder.
    private static let reminderOptions: [(Int, String)] = [(-1, "None"), (0, "On the day"), (1, "1 day before"), (2, "2 days before"), (3, "3 days before"), (7, "1 week before")]
    private static let currencies: [CurrencyCode] = [.myr, .usd, .sgd]

    /// - Parameters:
    ///   - subscription: existing subscription to edit, or nil for a new one.
    ///   - isNew: force "new" behaviour for a prefilled draft (e.g. from a suggestion).
    init(subscription: ServiceSubscription?, isNew: Bool = false) {
        let seed = subscription ?? ServiceSubscription(name: "", amount: .zero(), nextRenewal: KLCalendar.shared.addingMonths(1, to: Date()))
        _draft = State(initialValue: seed)
        _amountText = State(initialValue: seed.amount.isZero ? "" : MoneyFormatter(signStyle: .never, spaceAfterSymbol: false).string(from: seed.amount)
            .replacingOccurrences(of: MoneyFormatter.standard.symbol(for: seed.amount.currency), with: ""))
        _currency = State(initialValue: seed.amount.currency)
        _cycleChoice = State(initialValue: CycleChoice(seed.cycle))
        _reminderChoice = State(initialValue: seed.reminderDaysBefore ?? -1)
        self.isNew = isNew || subscription == nil
    }

    var body: some View {
        Form {
            Section {
                NavigationLink {
                    ServicePickerView { service in apply(service) }
                } label: {
                    HStack {
                        ServiceIcon(service: SubscriptionCatalog.service(id: draft.serviceID), name: draft.name.isEmpty ? "?" : draft.name, size: 32)
                        Text(SubscriptionCatalog.service(id: draft.serviceID)?.name ?? "Choose a Service")
                            .foregroundStyle(draft.serviceID == nil ? KiraColor.textSecondary : KiraColor.textPrimary)
                    }
                }
                TextField("Name", text: $draft.name).textInputAutocapitalization(.words)
            }

            Section {
                HStack {
                    Picker("Currency", selection: $currency) {
                        ForEach(Self.currencies, id: \.self) { Text(MoneyFormatter.standard.symbol(for: $0)).tag($0) }
                    }
                    .labelsHidden()
                    .fixedSize()
                    TextField("Price", text: $amountText).keyboardType(.decimalPad).monospacedDigit()
                }
                Picker("Billing", selection: $cycleChoice) {
                    ForEach(CycleChoice.allCases) { Text($0.rawValue).tag($0) }
                }
                Picker("Status", selection: $draft.status) {
                    ForEach([ServiceSubscriptionStatus.active, .trial, .paused], id: \.self) { Text($0.displayName).tag($0) }
                    if draft.status == .cancelled { Text(ServiceSubscriptionStatus.cancelled.displayName).tag(ServiceSubscriptionStatus.cancelled) }
                }
                if draft.status == .trial {
                    DatePicker("Trial ends", selection: Binding(get: { draft.trialEndsAt ?? draft.nextRenewal }, set: { draft.trialEndsAt = $0 }),
                               displayedComponents: .date)
                } else {
                    DatePicker("Next renewal", selection: $draft.nextRenewal, displayedComponents: .date)
                }
                if let error { Text(error).font(.footnote).foregroundStyle(KiraColor.error) }
            } header: {
                Text("Price")
            } footer: {
                if currency != .myr { Text("Plans billed in \(currency.rawValue) are listed but not added to RM totals.") }
            }

            Section {
                Picker("Paid from", selection: $draft.accountID) {
                    Text("Not specified").tag(UUID?.none)
                    ForEach(store.activeAccounts) { Text($0.name).tag(Optional($0.id)) }
                }
                Toggle("Billed through Apple", isOn: $draft.billedThroughApple)
                Stepper(value: $draft.shareCount, in: 1...12) {
                    VStack(alignment: .leading) {
                        Text(draft.shareCount == 1 ? "Just me" : "Split with \(draft.shareCount - 1) other\(draft.shareCount == 2 ? "" : "s")")
                        if draft.shareCount > 1, let share = sharePreview {
                            Text("Your share \(share.formatted)").font(.caption).foregroundStyle(KiraColor.textSecondary)
                        }
                    }
                }
            } header: {
                Text("Payment")
            }

            Section {
                Picker("Remind me", selection: $reminderChoice) {
                    ForEach(Self.reminderOptions, id: \.0) { Text($0.1).tag($0.0) }
                }
            } footer: {
                Text("Reminders show the service name only, never the amount.")
            }

            Section {
                Picker("Category", selection: $draft.categoryID) {
                    ForEach(store.categories) { Label($0.name, systemImage: $0.symbol).tag($0.id) }
                }
                TextField("Statement text (optional)", text: Binding(get: { draft.matchPattern ?? "" }, set: { draft.matchPattern = $0.nilIfBlank }))
                    .textInputAutocapitalization(.characters)
                TextField("Notes", text: Binding(get: { draft.notes ?? "" }, set: { draft.notes = $0.nilIfBlank }), axis: .vertical)
                    .lineLimit(1...4)
            } footer: {
                Text("Statement text helps Kira find this subscription’s charges, e.g. “GOOGLE *YOUTUBE”.")
            }
        }
        .navigationTitle(isNew ? "New Subscription" : "Edit Subscription")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            CloseToolbarItem { dismiss() }
            ConfirmToolbarItem(title: isNew ? "Add" : "Save", action: save)
        }
        .sensoryFeedback(trigger: error) { _, new in new == nil ? nil : .warning }
    }

    private var sharePreview: Money? {
        guard let amount = try? AmountParser(currency: currency).parse(amountText).money else { return nil }
        var preview = draft
        preview.amount = amount
        return store.subscriptionEngine.yourShare(preview)
    }

    private func apply(_ service: SubscriptionService?) {
        guard let service else { draft.serviceID = nil; return }
        draft.serviceID = service.id
        if draft.name.isEmpty || SubscriptionCatalog.services.contains(where: { $0.name == draft.name }) { draft.name = service.name }
        draft.categoryID = service.categoryID
        draft.billedThroughApple = service.billedThroughAppleByDefault
    }

    private func save() {
        guard !draft.name.trimmingCharacters(in: .whitespaces).isEmpty else { error = "Enter a name or choose a service."; return }
        let parsed: Money
        do {
            parsed = try AmountParser(currency: currency).parse(amountText).money
            guard !parsed.isZero else { error = "Enter the price you pay."; return }
        } catch AmountParser.ParseError.tooManyDecimals {
            error = "Use at most two decimal places."; return
        } catch {
            self.error = "Enter a price like 54.90."; return
        }
        var subscription = draft
        subscription.amount = parsed
        subscription.cycle = cycleChoice.cycle
        subscription.reminderDaysBefore = reminderChoice < 0 ? nil : reminderChoice
        if subscription.status == .trial && subscription.trialEndsAt == nil { subscription.trialEndsAt = subscription.nextRenewal }
        if subscription.status != .trial { subscription.trialEndsAt = nil }
        if isNew { subscription.createdAt = store.now() }
        store.save(subscription: subscription)
        if subscription.reminderDaysBefore != nil {
            Task { _ = await SubscriptionReminders.requestAuthorizationIfNeeded()
                await SubscriptionReminders.reschedule(store.subscriptions, engine: store.subscriptionEngine, now: store.now()) }
        }
        dismiss()
    }
}

/// Searchable list of known services, plus a custom option.
struct ServicePickerView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""
    var onPick: (SubscriptionService?) -> Void

    var body: some View {
        List {
            Section {
                Button {
                    onPick(nil)
                    dismiss()
                } label: {
                    Label("Something Else", systemImage: "square.and.pencil")
                }
            }
            Section("Services") {
                ForEach(SubscriptionCatalog.search(query)) { service in
                    Button {
                        onPick(service)
                        dismiss()
                    } label: {
                        HStack(spacing: KiraSpacing.m) {
                            ServiceIcon(service: service, name: service.name, size: 32)
                            Text(service.name).foregroundStyle(KiraColor.textPrimary)
                        }
                    }
                }
            }
        }
        .navigationTitle("Service")
        .navigationBarTitleDisplayMode(.inline)
        .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .always), prompt: "Netflix, Spotify, iCloud+…")
    }
}
