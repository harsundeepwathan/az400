import SwiftUI
import KiraCore

/// Compact entry point on Summary: monthly subscription cost and the next renewal.
struct SubscriptionsSummaryCard: View {
    @Environment(FinanceStore.self) private var store

    var body: some View {
        let summary = store.subscriptionSummary
        let suggestionCount = store.subscriptions.isEmpty ? store.subscriptionSuggestions.count : 0
        VStack(alignment: .leading, spacing: KiraSpacing.m) {
            SectionHeader(title: "Subscriptions")
            NavigationLink {
                SubscriptionsView()
            } label: {
                HStack(spacing: KiraSpacing.m) {
                    Image(systemName: "repeat")
                        .font(.title3).foregroundStyle(KiraColor.accent)
                        .frame(width: 40, height: 40)
                        .background(KiraColor.accentSoft, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 2) {
                        if store.subscriptions.isEmpty {
                            Text("Track your subscriptions").foregroundStyle(KiraColor.textPrimary)
                            Text(suggestionCount > 0 ? "\(suggestionCount) found in your transactions" : "Netflix, Spotify, iCloud+ and more")
                                .font(.caption).foregroundStyle(KiraColor.textSecondary)
                        } else {
                            HStack(alignment: .firstTextBaseline, spacing: 2) {
                                MoneyText(money: summary.monthlyTotal, font: .headline)
                                Text("/mo").font(.caption).foregroundStyle(KiraColor.textSecondary)
                            }
                            .foregroundStyle(KiraColor.textPrimary)
                            Text(nextLine(summary)).font(.caption).foregroundStyle(KiraColor.textSecondary).lineLimit(1)
                        }
                    }
                    Spacer()
                    Image(systemName: "chevron.right").font(.footnote.weight(.semibold)).foregroundStyle(KiraColor.textTertiary)
                        .accessibilityHidden(true)
                }
                .padding(KiraSpacing.l)
                .background(KiraColor.surface, in: RoundedRectangle(cornerRadius: KiraRadius.card, style: .continuous))
            }
            .buttonStyle(.plain)
        }
    }

    private func nextLine(_ summary: SubscriptionSummary) -> String {
        guard let next = summary.upcoming.first, let subscription = store.subscription(next.subscriptionID) else {
            return "\(summary.activeCount) active · nothing renews in the next 30 days"
        }
        let days = KLCalendar.shared.dayDistance(from: store.now(), to: next.date)
        let when = days == 0 ? "today" : days == 1 ? "tomorrow" : "in \(days) days"
        return "\(subscription.name) renews \(when) · \(summary.activeCount) active"
    }
}
