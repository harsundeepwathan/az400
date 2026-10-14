import SwiftUI
import KiraCore

enum AppTab: Hashable {
    case summary, activity, insights, accounts, search
}

/// Four navigation tabs plus a dedicated Search tab at the trailing end (HIG › Tab bars,
/// Search fields). Adding transactions is an action, so it lives in each screen's toolbar
/// (see `AddMenuModifier`), not in the tab bar. On iOS 26 the tab bar floats on Liquid Glass
/// and minimises while scrolling; earlier versions get the standard tab bar.
struct RootView: View {
    @Environment(FinanceStore.self) private var store
    @State private var selection: AppTab = .summary
    @AppStorage("kira.onboarded") private var onboarded = false

    var body: some View {
        TabView(selection: $selection) {
            Tab("Summary", systemImage: "house", value: AppTab.summary) {
                HomeView(openTab: { selection = $0 })
            }
            Tab("Activity", systemImage: "list.bullet.rectangle.portrait", value: AppTab.activity) {
                ActivityView()
            }
            Tab("Insights", systemImage: "chart.bar.xaxis", value: AppTab.insights) {
                InsightsView()
            }
            Tab("Accounts", systemImage: "wallet.bifold", value: AppTab.accounts) {
                AccountsView()
            }
            // Standard-style search tab: opens a landing page with recent merchants as suggestions.
            Tab(value: AppTab.search, role: .search) {
                SearchView()
            }
        }
        .kiraTabBarMinimizesOnScroll()
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
