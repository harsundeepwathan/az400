import SwiftUI
import KiraCore

enum AppTab: Hashable {
    case home, activity, capture, insights, accounts
}

/// Five destinations. "Capture" is a tab-bar button that opens a sheet rather than a screen,
/// so it is always one tap away but never replaces the user's context.
struct RootView: View {
    @Environment(FinanceStore.self) private var store
    @State private var selection: AppTab = .home
    @State private var previousSelection: AppTab = .home
    @State private var showingCapture = false
    @AppStorage("kira.onboarded") private var onboarded = false

    var body: some View {
        TabView(selection: $selection) {
            Tab("Home", systemImage: "house", value: AppTab.home) {
                HomeView(openCapture: { showingCapture = true }, openTab: { selection = $0 })
            }
            Tab("Activity", systemImage: "list.bullet.rectangle", value: AppTab.activity) {
                ActivityView()
            }
            Tab("Capture", systemImage: "plus.circle.fill", value: AppTab.capture) {
                Color.clear.accessibilityLabel("Add a transaction, scan a QR code or import a statement")
            }
            Tab("Insights", systemImage: "chart.bar.xaxis", value: AppTab.insights) {
                InsightsView()
            }
            Tab("Accounts", systemImage: "wallet.pass", value: AppTab.accounts) {
                AccountsView()
            }
        }
        .onChange(of: selection) { old, new in
            if new == .capture {
                selection = old
                showingCapture = true
                Haptics.selection()
            }
        }
        .sheet(isPresented: $showingCapture) {
            CaptureSheet()
                .presentationDetents([.medium, .large])
                .presentationDragIndicator(.visible)
                .presentationCornerRadius(KiraRadius.hero)
        }
        .fullScreenCover(isPresented: Binding(get: { !onboarded && !AppEnvironment.isUITesting }, set: { if !$0 { onboarded = true } })) {
            OnboardingView { onboarded = true }
        }
        .alert("Something went wrong", isPresented: Binding(get: { store.lastErrorMessage != nil }, set: { if !$0 { store.lastErrorMessage = nil } })) {
            Button("OK", role: .cancel) { store.lastErrorMessage = nil }
        } message: {
            Text(store.lastErrorMessage ?? "")
        }
    }
}
