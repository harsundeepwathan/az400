import SwiftUI
import UniformTypeIdentifiers
import KiraCore

struct SettingsView: View {
    @Environment(FinanceStore.self) private var store
    @Environment(AppLock.self) private var lock
    @Environment(SubscriptionManager.self) private var subscriptions
    @State private var showingPaywall = false
    @State private var exportDocument: ExportDocument?
    @State private var confirmDelete = false
    @State private var deleteConfirmationText = ""
    @State private var lockToggle = false

    var body: some View {
        List {
            Section("Plan") {
                LabeledContent("Current plan", value: store.tier.displayName)
                Button(store.tier == .premium ? "Manage subscription" : "See Plus and Premium") { showingPaywall = true }
            }

            Section {
                Toggle("Lock with \(lock.biometryName)", isOn: $lockToggle)
                    .onChange(of: lockToggle) { _, new in
                        guard new != lock.isEnabled else { return }
                        Task {
                            let ok = await lock.setEnabled(new)
                            if !ok { lockToggle = lock.isEnabled }
                            try? store.repository.logAudit(action: "applock.\(lock.isEnabled ? "on" : "off")", detail: "")
                        }
                    }
                    .disabled(!lock.canAuthenticate)
            } header: { Text("Security") } footer: {
                Text("Your data is stored only on this iPhone and encrypted by iOS when the phone is locked.")
            }

            Section("Capture") {
                NavigationLink("Apple Pay automation") { ShortcutsGuideView() }
                NavigationLink("Category rules") { RulesView() }
                if store.inboxPendingCount > 0 {
                    Text("\(store.inboxPendingCount) captured payment(s) waiting for Kira Plus").font(.footnote).foregroundStyle(KiraColor.warning)
                }
            }

            Section {
                Button("Export transactions (CSV)") {
                    exportDocument = ExportDocument(data: Data(store.exportCSV().utf8), type: .commaSeparatedText, name: "kira-transactions.csv")
                }
                Button("Export everything (JSON)") {
                    if let data = try? store.exportJSON() { exportDocument = ExportDocument(data: data, type: .json, name: "kira-export.json") }
                }
                NavigationLink("Privacy & data") { PrivacyInfoView() }
                Button("Delete all data", role: .destructive) { confirmDelete = true }
            } header: { Text("Your data") } footer: {
                Text("Export and deletion are always free, whatever your plan.")
            }

            Section("About") {
                LabeledContent("Version", value: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "–")
                NavigationLink("What Kira can and can’t do") { LimitationsView() }
            }
        }
        .listStyle(.insetGrouped)
        .kiraScreen()
        .navigationTitle("Settings")
        .onAppear { lockToggle = lock.isEnabled }
        .sheet(isPresented: $showingPaywall) { PaywallView() }
        .fileExporter(isPresented: Binding(get: { exportDocument != nil }, set: { if !$0 { exportDocument = nil } }),
                      document: exportDocument, contentType: exportDocument?.type ?? .data, defaultFilename: exportDocument?.name) { _ in
            exportDocument = nil
        }
        .alert("Delete all data?", isPresented: $confirmDelete) {
            TextField("Type DELETE", text: $deleteConfirmationText)
            Button("Delete everything", role: .destructive) {
                guard deleteConfirmationText == "DELETE" else { return }
                do { try store.deleteAllData() } catch { store.lastErrorMessage = error.localizedDescription }
                deleteConfirmationText = ""
            }
            Button("Cancel", role: .cancel) { deleteConfirmationText = "" }
        } message: {
            Text("This permanently removes every transaction, account, budget and rule from this iPhone. Export first if you want a copy. Type DELETE to confirm.")
        }
    }
}

struct ExportDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.commaSeparatedText, .json, .data] }
    let data: Data
    let type: UTType
    let name: String

    init(data: Data, type: UTType, name: String) {
        self.data = data
        self.type = type
        self.name = name
    }

    init(configuration: ReadConfiguration) throws {
        data = configuration.file.regularFileContents ?? Data()
        type = .data
        name = "export"
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: data)
    }
}

/// User-created categorisation rules (layer 1). Custom rules are a Plus feature; rules learned
/// from corrections are always kept and shown here so users can remove them.
struct RulesView: View {
    @Environment(FinanceStore.self) private var store
    @State private var pattern = ""
    @State private var categoryID = BuiltInCategory.other.id

    var body: some View {
        List {
            if store.gate.isAvailable(.customRules) {
                Section("New rule") {
                    TextField("When merchant contains…", text: $pattern)
                    Picker("Categorise as", selection: $categoryID) { ForEach(store.categories) { Text($0.name).tag($0.id) } }
                    Button("Add rule") {
                        let cleaned = InputSanitizer.cleanText(pattern, maxLength: 60)
                        guard cleaned.count >= 2 else { return }
                        store.save(rule: MerchantRule(pattern: cleaned, matchType: .contains, categoryID: categoryID))
                        pattern = ""
                    }
                }
            } else {
                Section { NoticeBanner(tone: .info, text: "Custom rules are part of Kira Plus. Corrections you make are still remembered below.") }
            }
            Section("Rules") {
                if store.rules.isEmpty { Text("No rules yet. Change a transaction’s category and Kira will remember it.").foregroundStyle(KiraColor.textSecondary) }
                ForEach(store.rules.sorted { $0.createdAt > $1.createdAt }) { rule in
                    VStack(alignment: .leading) {
                        Text("“\(rule.pattern)” → \(store.category(rule.categoryID)?.name ?? rule.categoryID)")
                        Text(rule.learnedFromCorrection ? "Learned from your correction" : "Created by you").font(.caption).foregroundStyle(KiraColor.textSecondary)
                    }
                    .swipeActions { Button("Delete", role: .destructive) { store.deleteRule(rule) } }
                }
            }
        }
        .kiraScreen()
        .navigationTitle("Category rules")
    }
}

struct PrivacyInfoView: View {
    var body: some View {
        List {
            Section("Where your data lives") {
                Text("All financial data is stored on this iPhone in an encrypted store protected by iOS Data Protection (Complete). It is unreadable while your phone is locked.")
                Text("Kira has no servers of its own and no analytics or advertising SDKs. Optional cloud sync is off and not yet available.")
            }
            Section("What Kira reads") {
                Text("Receipts, QR codes and statements you choose are processed on-device with Apple frameworks. Nothing is sent to an AI service.")
                Text("Kira never asks for your online banking username or password.")
            }
            Section("Your rights (PDPA)") {
                Text("You can export all your data at any time (Settings › Your data) and delete it permanently. Deletion removes the database, the capture inbox, saved secrets and preferences from this device.")
            }
        }
        .kiraScreen()
        .navigationTitle("Privacy & data")
    }
}

struct LimitationsView: View {
    var body: some View {
        List {
            Section("Apple Pay") {
                Text("iOS doesn’t give budgeting apps your Apple Pay history. Kira uses a Shortcuts automation that runs when you tap a card in a shop. It may not run for online or in-app Apple Pay, and sometimes iOS sends it blank details. Those entries stay “Pending” until confirmed.")
                Text("FinanceKit (Apple’s transaction API) isn’t available for Malaysian cards today.")
            }
            Section("DuitNow & banks") {
                Text("Scanning a DuitNow QR doesn’t pay or prove payment. Kira saves a draft; you pay in your banking app and then share the receipt or confirm.")
                Text("Malaysian banks and e-wallets don’t offer Kira a transaction feed. Import statements (CSV or PDF) or receipts instead. Bank layouts vary — always check the preview.")
            }
            Section("Balances & forecasts") {
                Text("Kira can’t see your bank balance. Forecasts start from balances you enter and are estimates with a stated confidence.")
                Text("EPF, SOCSO and EIS figures are approximations. PCB/MTD is never calculated — enter it from your payslip.")
            }
        }
        .kiraScreen()
        .navigationTitle("Limitations")
    }
}
