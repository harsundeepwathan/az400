import SwiftUI
import KiraCore

/// The capture hub: every way to get a transaction into Kira, ordered by least effort.
struct CaptureSheet: View {
    @Environment(FinanceStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @State private var destination: Destination?

    enum Destination: String, Identifiable {
        case manual, scan, receipt, statement, shortcuts
        var id: String { rawValue }
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    option(.manual, title: "Add manually", subtitle: "Cash, transfers, anything", symbol: "square.and.pencil")
                    option(.scan, title: "Scan DuitNow QR", subtitle: "Saves a draft before you pay in your bank app", symbol: "qrcode.viewfinder")
                    option(.receipt, title: "Import receipt", subtitle: "Screenshot or photo of a payment receipt", symbol: "doc.text.viewfinder")
                    option(.statement, title: "Import statement", subtitle: "CSV or PDF from your bank or e-wallet", symbol: "tray.and.arrow.down")
                }
                Section {
                    option(.shortcuts, title: "Apple Pay automation", subtitle: "Log taps automatically with Shortcuts", symbol: "wave.3.right")
                } footer: {
                    Text("Kira never asks for your online banking login and can’t see your bank account directly.")
                }
            }
            .listStyle(.insetGrouped)
            .kiraScreen()
            .navigationTitle("Add")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Close") { dismiss() } } }
            .navigationDestination(item: $destination) { destination in
                switch destination {
                case .manual: TransactionEditorView(mode: .create(nil)) { dismiss() }
                case .scan: DuitNowScanFlow { dismiss() }
                case .receipt: ReceiptImportView { dismiss() }
                case .statement: StatementImportView { dismiss() }
                case .shortcuts: ShortcutsGuideView()
                }
            }
        }
    }

    private func option(_ destination: Destination, title: String, subtitle: String, symbol: String) -> some View {
        Button { self.destination = destination } label: {
            HStack(spacing: KiraSpacing.m) {
                Image(systemName: symbol).font(.title3).foregroundStyle(KiraColor.accent)
                    .frame(width: 40, height: 40).background(KiraColor.accentSoft, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.kiraRowTitle).foregroundStyle(KiraColor.textPrimary)
                    Text(subtitle).font(.caption).foregroundStyle(KiraColor.textSecondary)
                }
                Spacer()
                Image(systemName: "chevron.right").font(.footnote.weight(.semibold)).foregroundStyle(KiraColor.textSecondary)
            }
            .padding(.vertical, 4)
        }
        .listRowBackground(KiraColor.surface)
    }
}
