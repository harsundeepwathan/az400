import SwiftUI
import KiraCore

/// Accounts, balances (user-entered, timestamped), and the way into settings.
struct AccountsView: View {
    @Environment(FinanceStore.self) private var store
    @State private var editing: Account?

    var body: some View {
        NavigationStack {
            List {
                if store.activeAccounts.isEmpty {
                    Section {
                        EmptyStateView(symbol: "building.columns", title: "Add your accounts",
                                       message: "Add bank accounts, cards and e-wallets so imports and transfers are matched correctly. Kira never connects to your bank.",
                                       actionTitle: "Add account") { editing = Account(name: "", type: .savings) }
                    }
                    .listRowBackground(Color.clear)
                } else {
                    // Only types that have accounts, so each element is exactly one Section.
                    ForEach(AccountType.allCases.filter { type in store.activeAccounts.contains { $0.type == type } }, id: \.self) { type in
                        Section(type.displayName) {
                            ForEach(store.activeAccounts.filter { $0.type == type }) { account in
                                Button { editing = account } label: { AccountRow(account: account) }.buttonStyle(.plain)
                            }
                        }
                    }
                    Section {
                        Button { editing = Account(name: "", type: .savings) } label: { Label("Add account", systemImage: "plus") }
                    }
                }

                Section {
                    NavigationLink { SubscriptionsView() } label: { Label("Subscriptions", systemImage: "repeat") }
                    NavigationLink { CommitmentsView() } label: { Label("Commitments & income", systemImage: "calendar.badge.clock") }
                    NavigationLink { SettingsView() } label: { Label("Settings & privacy", systemImage: "gearshape") }
                }
            }
            .listStyle(.insetGrouped)
            .kiraScreen()
            .navigationTitle("Accounts")
            .sheet(item: $editing) { account in NavigationStack { AccountEditorView(account: account) } }
        }
    }
}

private struct AccountRow: View {
    @Environment(FinanceStore.self) private var store
    let account: Account

    var body: some View {
        HStack {
            Image(systemName: symbol).foregroundStyle(KiraColor.accent).frame(width: 36, height: 36)
                .background(KiraColor.accentSoft, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            VStack(alignment: .leading, spacing: 2) {
                Text(account.name).font(.kiraRowTitle)
                Text([account.institution.displayName, account.lastFour.map { "•••• \($0)" }].compactMap { $0 }.joined(separator: " · "))
                    .font(.caption).foregroundStyle(KiraColor.textSecondary)
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 2) {
                if let balance = account.balance {
                    MoneyText(money: balance, font: .body.weight(.semibold))
                    Text(verifiedText).font(.caption2).foregroundStyle(isStale ? KiraColor.warning : KiraColor.textSecondary)
                } else {
                    Text("No balance").font(.caption).foregroundStyle(KiraColor.textSecondary)
                }
            }
        }
        .accessibilityElement(children: .combine)
    }

    private var symbol: String {
        switch account.type {
        case .savings, .current: return "building.columns"
        case .creditCard: return "creditcard"
        case .eWallet: return "wallet.pass"
        case .cash: return "banknote"
        case .loan: return "doc.text"
        }
    }

    private var isStale: Bool {
        guard let date = account.balanceVerifiedAt else { return true }
        return Date().timeIntervalSince(date) > 7 * 86_400
    }

    private var verifiedText: String {
        guard let date = account.balanceVerifiedAt else { return "Not confirmed" }
        return "Confirmed \(date.formatted(.relative(presentation: .named)))"
    }
}

struct AccountEditorView: View {
    @Environment(FinanceStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    /// One-time seed: edits stay local until Save.
    @State private var account: Account
    @State private var balanceText = ""
    @State private var walletNames = ""
    @State private var error: String?
    @State private var confirmArchive = false

    init(account: Account) {
        _account = State(initialValue: account)
    }

    var body: some View {
        Form {
            Section {
                TextField("Name (e.g. Maybank Savings)", text: $account.name)
                Picker("Type", selection: $account.type) { ForEach(AccountType.allCases, id: \.self) { Text($0.displayName).tag($0) } }
                Picker("Institution", selection: $account.institution) { ForEach(Institution.allCases, id: \.self) { Text($0.displayName).tag($0) } }
                TextField("Last 4 digits (optional)", text: Binding(get: { account.lastFour ?? "" }, set: { account.lastFour = String($0.filter(\.isNumber).prefix(4)).nilIfBlank }))
                    .keyboardType(.numberPad)
            }
            Section {
                TextField(account.type.isLiability ? "Amount owed (RM)" : "Current balance (RM)", text: $balanceText).keyboardType(.decimalPad)
                if let date = account.balanceVerifiedAt { Text("Last confirmed \(date.kiraWithTime)").font(.footnote).foregroundStyle(KiraColor.textSecondary) }
            } header: { Text("Balance") } footer: {
                Text("Kira can’t read your bank balance. Enter it from your banking app; forecasts use it from this moment.")
            }
            if account.type == .creditCard || account.type == .savings || account.type == .current {
                Section {
                    TextField("e.g. Maybank Visa Signature", text: $walletNames)
                } header: { Text("Name in Apple Wallet") } footer: {
                    Text("Used to match Apple Pay automation events to this card. Separate several names with commas.")
                }
            }
            Toggle("Include in cash-flow forecast", isOn: $account.includeInForecast)
            if let error { Text(error).foregroundStyle(KiraColor.error) }
            if store.account(account.id) != nil {
                Button("Archive account", role: .destructive) { confirmArchive = true }
            }
        }
        .kiraScreen()
        .navigationTitle(account.name.isEmpty ? "New account" : account.name)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            CloseToolbarItem { dismiss() }
            ConfirmToolbarItem(title: "Save", action: save)
        }
        .confirmationDialog("Archive this account? Its transactions are kept.", isPresented: $confirmArchive, titleVisibility: .visible) {
            Button("Archive", role: .destructive) { store.archive(account: account); dismiss() }
        }
        .onAppear {
            if let balance = account.balance { balanceText = MoneyFormatter(signStyle: .minusOnly, spaceAfterSymbol: false).string(from: balance).replacingOccurrences(of: "RM", with: "") }
            walletNames = account.walletCardNames.joined(separator: ", ")
        }
    }

    private func save() {
        guard !account.name.trimmingCharacters(in: .whitespaces).isEmpty else { error = "Give this account a name."; return }
        if balanceText.trimmingCharacters(in: .whitespaces).isEmpty {
            account.balance = nil
            account.balanceVerifiedAt = nil
        } else {
            do {
                let parsed = try AmountParser().parse(balanceText)
                let newBalance = parsed.isNegative ? parsed.money.negated : parsed.money
                if newBalance != account.balance { account.balanceVerifiedAt = Date() }
                account.balance = newBalance
            } catch {
                self.error = "Enter the balance like 1,234.56."
                return
            }
        }
        account.walletCardNames = walletNames.split(separator: ",").map { InputSanitizer.cleanText(String($0), maxLength: 60) }.filter { !$0.isEmpty }
        store.save(account: account)
        store.signal(.success)
        dismiss()
    }
}

extension String {
    var nilIfBlank: String? { trimmingCharacters(in: .whitespaces).isEmpty ? nil : self }
}
