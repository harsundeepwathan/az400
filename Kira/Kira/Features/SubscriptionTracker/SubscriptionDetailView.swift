import SwiftUI
import KiraCore

/// One subscription: cost breakdown, next renewal, matched charge history and actions.
/// Kira can't cancel with the provider, so it explains where to do that.
struct SubscriptionDetailView: View {
    @Environment(FinanceStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    let subscriptionID: UUID
    @State private var editing: ServiceSubscription?
    @State private var confirmingCancel = false
    @State private var confirmingDelete = false

    /// Opens Apple ID › Subscriptions in the App Store.
    private static let appleSubscriptionsURL = URL(string: "https://apps.apple.com/account/subscriptions")!

    var body: some View {
        Group {
            if let subscription = store.subscription(subscriptionID) {
                content(subscription)
            } else {
                ContentUnavailableView("Subscription Not Found", systemImage: "questionmark.circle", description: Text("It may have been deleted."))
            }
        }
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button("Edit") { editing = store.subscription(subscriptionID) }
                    .disabled(store.subscription(subscriptionID) == nil)
            }
        }
        .sheet(item: $editing) { subscription in
            NavigationStack { SubscriptionEditorView(subscription: subscription) }
        }
    }

    private func content(_ subscription: ServiceSubscription) -> some View {
        let engine = store.subscriptionEngine
        let schedule = engine.billingSchedule(subscription)
        let charges = engine.matchedCharges(for: subscription, in: store.transactions)
        let alerts = store.subscriptionAlerts.filter { $0.subscriptionID == subscription.id }
        return List {
            Section {
                VStack(spacing: KiraSpacing.s) {
                    ServiceIcon(subscription: subscription, size: 64)
                    Text(subscription.name).font(.title2.weight(.semibold)).multilineTextAlignment(.center)
                    HStack(alignment: .firstTextBaseline, spacing: 2) {
                        MoneyText(money: subscription.amount, font: .kiraFigure)
                        Text(subscription.cycle.shortSuffix).font(.subheadline).foregroundStyle(KiraColor.textSecondary)
                    }
                    if subscription.status != .active { SubscriptionStatusPill(status: subscription.status) }
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, KiraSpacing.s)
                .listRowBackground(Color.clear)
            }

            if !alerts.isEmpty {
                Section {
                    ForEach(alerts) { alert in
                        VStack(alignment: .leading, spacing: KiraSpacing.s) {
                            SubscriptionAlertRow(alert: alert, subscription: subscription)
                            if case .priceChanged(_, let newPrice) = alert.kind {
                                Button("Update Price to \(newPrice.formatted)") {
                                    var updated = subscription
                                    updated.amount = newPrice
                                    store.save(subscription: updated)
                                }
                                .font(.subheadline.weight(.medium))
                            }
                        }
                    }
                }
            }

            Section {
                if subscription.isLive {
                    LabeledContent(subscription.status == .trial ? "First charge" : "Next renewal") {
                        Text(schedule.nextRenewal.formatted(date: .abbreviated, time: .omitted))
                    }
                }
                LabeledContent("Billing", value: subscription.cycle.displayName)
                LabeledContent("Per month") { MoneyText(money: engine.monthlyCost(subscription)) }
                LabeledContent("Per year") { MoneyText(money: engine.yearlyCost(subscription)) }
                if subscription.shareCount > 1 {
                    LabeledContent("Your share (split \(subscription.shareCount) ways)") { MoneyText(money: engine.yourShare(subscription)) }
                }
                if let account = store.account(subscription.accountID) { LabeledContent("Paid from", value: account.name) }
                LabeledContent("Category", value: store.category(subscription.categoryID)?.name ?? "Subscriptions")
                LabeledContent("Reminder", value: subscription.reminderDaysBefore.map { $0 == 0 ? "On the day" : "\($0) day\($0 == 1 ? "" : "s") before" } ?? "Off")
                if subscription.amount.currency != .myr {
                    Text("Billed in \(subscription.amount.currency.rawValue), so it isn’t included in RM totals or forecasts.")
                        .font(.footnote).foregroundStyle(KiraColor.textSecondary)
                }
            }

            Section {
                if charges.isEmpty {
                    Text("No charges found in your recorded transactions yet. Import a statement or log payments to see the history here.")
                        .font(.subheadline).foregroundStyle(KiraColor.textSecondary)
                } else {
                    ForEach(charges.prefix(12)) { charge in
                        LabeledContent {
                            MoneyText(money: charge.amount)
                        } label: {
                            Text(charge.transactionDate.formatted(date: .abbreviated, time: .omitted))
                            Text(charge.source.displayName)
                        }
                    }
                }
            } header: {
                Text("Charge History")
            } footer: {
                if !charges.isEmpty {
                    Text("Matched by merchant name and a price within 30% of what you track.")
                }
            }

            Section {
                if subscription.billedThroughApple {
                    Link(destination: Self.appleSubscriptionsURL) {
                        Label("Manage in App Store", systemImage: "arrow.up.forward.app")
                    }
                }
                if subscription.isLive {
                    Button("Mark as Paused") {
                        var updated = subscription
                        updated.status = .paused
                        store.save(subscription: updated)
                    }
                    Button("Mark as Cancelled", role: .destructive) { confirmingCancel = true }
                } else {
                    Button(subscription.status == .paused ? "Resume" : "Mark as Active Again") {
                        var updated = subscription
                        updated.status = .active
                        updated.cancelledAt = nil
                        store.save(subscription: updated)
                    }
                }
                Button("Delete", role: .destructive) { confirmingDelete = true }
            } footer: {
                Text(subscription.billedThroughApple
                     ? "Kira can’t cancel subscriptions. Cancel in Apple ID › Subscriptions, then mark it cancelled here."
                     : "Kira can’t cancel subscriptions. Cancel in \(subscription.name)’s app or website, then mark it cancelled here.")
            }
        }
        .listStyle(.insetGrouped)
        .confirmationDialog("Mark \(subscription.name) as cancelled?", isPresented: $confirmingCancel, titleVisibility: .visible) {
            Button("Mark as Cancelled", role: .destructive) { store.markCancelled(subscription) }
        } message: {
            Text("This only updates Kira. Cancel with the provider too, or you’ll still be charged.")
        }
        .confirmationDialog("Delete \(subscription.name)?", isPresented: $confirmingDelete, titleVisibility: .visible) {
            Button("Delete", role: .destructive) {
                store.deleteSubscription(subscription)
                dismiss()
            }
        } message: {
            Text("Its charges stay in Activity. To keep a record, mark it cancelled instead.")
        }
    }
}
