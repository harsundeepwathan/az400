import SwiftUI
import StoreKit
import KiraCore

/// Plans and purchase. Prices come from the App Store; proposed launch pricing is RM6.90 (Plus)
/// and RM12.90 (Premium) per month, configured in App Store Connect.
struct PaywallView: View {
    @Environment(SubscriptionManager.self) private var subscriptions
    @Environment(\.dismiss) private var dismiss
    @State private var purchasing: String?

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: KiraSpacing.xl) {
                    Text("Do more with less typing").font(.largeTitle.weight(.bold))
                    plan(.plus, features: ["Unlimited statement & receipt imports", "Apple Pay Shortcuts capture", "Advanced reconciliation", "Custom category rules", "Detailed analytics"])
                    plan(.premium, features: ["Everything in Plus", "Cash-flow forecasting", "Debt & loan analytics", "Multi-account insights", "Advanced reports"])
                    Text("Free always includes manual tracking, budgets, the dashboard, 3 imports a month, and full export and deletion of your data — even if you cancel.")
                        .font(.footnote).foregroundStyle(KiraColor.textSecondary)
                    if let error = subscriptions.errorMessage { NoticeBanner(tone: .error, text: error) }
                    HStack {
                        Button("Restore purchases") { Task { await subscriptions.restore() } }
                        Spacer()
                        Link("Terms", destination: URL(string: "https://www.apple.com/legal/internet-services/itunes/dev/stdeula/")!)
                    }
                    .font(.footnote)
                    Text("Subscriptions renew monthly until cancelled. Manage or cancel in Settings › Apple ID › Subscriptions.")
                        .font(.caption).foregroundStyle(KiraColor.textSecondary)
                }
                .padding(KiraSpacing.l)
            }
            .kiraScreen()
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Close") { dismiss() } } }
            .task { if subscriptions.products.isEmpty { await subscriptions.loadProducts() } }
        }
    }

    private func plan(_ tier: SubscriptionTier, features: [String]) -> some View {
        let product = subscriptions.products.first { SubscriptionManager.tier(for: $0.id) == tier }
        let isCurrent = subscriptions.tier == tier
        return Surface {
            VStack(alignment: .leading, spacing: KiraSpacing.m) {
                HStack {
                    Text("Kira \(tier.displayName)").font(.title3.weight(.semibold))
                    Spacer()
                    Text(product.map { "\($0.displayPrice)/month" } ?? "—").font(.headline).monospacedDigit()
                }
                ForEach(features, id: \.self) { Label($0, systemImage: "checkmark").font(.subheadline) }
                Button {
                    guard let product else { return }
                    purchasing = product.id
                    Task { await subscriptions.purchase(product); purchasing = nil }
                } label: {
                    Text(isCurrent ? "Current plan" : (purchasing == product?.id ? "Purchasing…" : "Choose \(tier.displayName)")).frame(maxWidth: .infinity)
                }
                .buttonStyle(KiraPrimaryButtonStyle())
                .disabled(product == nil || isCurrent || purchasing != nil)
            }
        }
    }
}
