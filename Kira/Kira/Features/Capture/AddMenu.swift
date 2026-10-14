import SwiftUI
import KiraCore

/// Ways to add a transaction, ordered by least effort.
enum CaptureFlow: String, Identifiable, CaseIterable {
    case manual, scan, receipt, statement, shortcuts
    var id: String { rawValue }

    var title: String {
        switch self {
        case .manual: return "Add Manually"
        case .scan: return "Scan DuitNow QR"
        case .receipt: return "Import Receipt"
        case .statement: return "Import Statement"
        case .shortcuts: return "Set Up Apple Pay Logging"
        }
    }

    var subtitle: String {
        switch self {
        case .manual: return "Cash, transfers, anything"
        case .scan: return "Saves a draft before you pay"
        case .receipt: return "Screenshot or photo of a receipt"
        case .statement: return "CSV or PDF from your bank or e-wallet"
        case .shortcuts: return "Log Apple Pay taps with Shortcuts"
        }
    }

    var symbol: String {
        switch self {
        case .manual: return "square.and.pencil"
        case .scan: return "qrcode.viewfinder"
        case .receipt: return "doc.text.viewfinder"
        case .statement: return "tray.and.arrow.down"
        case .shortcuts: return "wave.3.right"
        }
    }
}

/// HIG › Tab bars: "Use a tab bar to support navigation, not to provide actions." Adding a
/// transaction is an action, so it lives in the toolbar as a standard Add (+) pull-down menu
/// on the Summary and Activity screens rather than as a tab.
struct AddMenuModifier: ViewModifier {
    /// Item-driven presentation: sheets for most flows, full screen for the camera.
    @State private var flow: CaptureFlow?
    @State private var cameraFlow: CaptureFlow?

    func body(content: Content) -> some View {
        content
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Menu {
                        Section {
                            menuButton(.manual)
                            menuButton(.scan)
                        }
                        Section("Import") {
                            menuButton(.receipt)
                            menuButton(.statement)
                        }
                        Section {
                            menuButton(.shortcuts)
                        }
                    } label: {
                        Label("Add", systemImage: "plus")
                    }
                    .accessibilityHint("Add a transaction, scan a QR code or import a statement")
                }
            }
            .sheet(item: $flow) { flow in
                CaptureFlowView(flow: flow)
            }
            // HIG › Sheets: camera views suit a full-screen modal.
            .fullScreenCover(item: $cameraFlow) { flow in
                CaptureFlowView(flow: flow)
            }
    }

    private func menuButton(_ option: CaptureFlow) -> some View {
        Button {
            if option == .scan { cameraFlow = option } else { flow = option }
        } label: {
            Label { Text(option.title); Text(option.subtitle) } icon: { Image(systemName: option.symbol) }
        }
    }
}

extension View {
    func kiraAddMenu() -> some View { modifier(AddMenuModifier()) }
}

/// Hosts one capture flow in its own navigation stack with a standard Close button.
struct CaptureFlowView: View {
    @Environment(\.dismiss) private var dismiss
    let flow: CaptureFlow

    var body: some View {
        NavigationStack {
            switch flow {
            case .manual:
                // The editor supplies its own Close and Save buttons.
                TransactionEditorView(mode: .create(nil))
            case .scan:
                DuitNowScanFlow { dismiss() }.toolbar { CloseToolbarItem { dismiss() } }
            case .receipt:
                ReceiptImportView { dismiss() }.toolbar { CloseToolbarItem { dismiss() } }
            case .statement:
                StatementImportView { dismiss() }.toolbar { CloseToolbarItem { dismiss() } }
            case .shortcuts:
                ShortcutsGuideView().toolbar { CloseToolbarItem { dismiss() } }
            }
        }
    }
}
