import SwiftUI
import KiraCore

/// Navigation value for a subscription's detail screen.
struct SubscriptionRoute: Hashable {
    let id: UUID
}

/// Tracked subscriptions: monthly cost, what renews next, anything that needs attention, and
/// recurring charges Kira found that aren't tracked yet.
struct SubscriptionsView: View {
    @Environment(FinanceStore.self) private var store
    @State private var sheet: SubscriptionSheet?
    @State private var sort: SortOrder = .nextRenewal
    @State private var pendingCancel: ServiceSubscription?

    enum SortOrder: String, CaseIterable, Identifiable {
        case nextRenewal = "Next Renewal", cost = "Monthly Cost", name = "Name"
        var id: String { rawValue }
    }

    enum SubscriptionSheet: Identifiable {
        case add
        case edit(ServiceSubscription)
        case fromSuggestion(SubscriptionSuggestion)

        var id: String {
            switch self {
            case .add: return "add"
            case .edit(let subscription): return "edit-\(subscription.id)"
            case .fromSuggestion(let suggestion): return "suggestion-\(suggestion.id)"
            }
        }
    }

    var body: some View {
        let summary = store.subscriptionSummary
        let suggestions = store.subscriptionSuggestions
        List {
            if store.subscriptions.isEmpty {
                Section {
                    ContentUnavailableView {
                        Label("No Subscriptions", systemImage: "repeat.circle")
                    } description: {
                        Text("Track Netflix, Spotify, iCloud+ and other plans to see what you pay each month and get a reminder before they renew.")
                    } actions: {
                        Button("Add Subscription") { sheet = .add }.kiraProminentButton()
                    }
                }
            } else {
                Section { SubscriptionTotalsView(summary: summary) }
                alertsSection
                upcomingSection(summary)
                listSections
            }
            if !suggestions.isEmpty {
                Section {
                    ForEach(suggestions) { suggestion in
                        SuggestionRow(suggestion: suggestion) { sheet = .fromSuggestion(suggestion) }
                    }
                } header: {
                    Text("Found in Your Transactions")
                } footer: {
                    Text("Recurring charges that look like subscriptions. Add them to track renewals.")
                }
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle("Subscriptions")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button("Add Subscription", systemImage: "plus") { sheet = .add }
            }
            ToolbarItem(placement: .secondaryAction) {
                Picker("Sort By", selection: $sort) {
                    ForEach(SortOrder.allCases) { Text($0.rawValue).tag($0) }
                }
            }
        }
        .navigationDestination(for: SubscriptionRoute.self) { route in
            SubscriptionDetailView(subscriptionID: route.id)
        }
        .sheet(item: $sheet) { sheet in
            switch sheet {
            case .add:
                NavigationStack { SubscriptionEditorView(subscription: nil) }
            case .edit(let subscription):
                NavigationStack { SubscriptionEditorView(subscription: subscription) }
            case .fromSuggestion(let suggestion):
                NavigationStack { SubscriptionEditorView(subscription: store.subscriptionEngine.subscription(from: suggestion, now: store.now()), isNew: true) }
            }
        }
        .confirmationDialog("Mark as cancelled?", isPresented: Binding(get: { pendingCancel != nil }, set: { if !$0 { pendingCancel = nil } }),
                            titleVisibility: .visible, presenting: pendingCancel) { subscription in
            Button("Mark \(subscription.name) as Cancelled", role: .destructive) { store.markCancelled(subscription) }
        } message: { _ in
            Text("This only updates Kira. Cancel with the provider too, or you’ll still be charged.")
        }
    }

    // MARK: Sections

    @ViewBuilder
    private var alertsSection: some View {
        // Resolve subscriptions first so each ForEach element is exactly one row.
        let alerts = store.subscriptionAlerts
            .filter { if case .renewsSoon = $0.kind { return false } else { return true } }
            .compactMap { alert in store.subscription(alert.subscriptionID).map { (alert: alert, subscription: $0) } }
        if !alerts.isEmpty {
            Section("Needs Attention") {
                ForEach(alerts, id: \.alert.id) { item in
                    NavigationLink(value: SubscriptionRoute(id: item.subscription.id)) {
                        SubscriptionAlertRow(alert: item.alert, subscription: item.subscription)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func upcomingSection(_ summary: SubscriptionSummary) -> some View {
        let upcoming = summary.upcoming.prefix(5)
            .compactMap { renewal in store.subscription(renewal.subscriptionID).map { (renewal: renewal, subscription: $0) } }
        if !upcoming.isEmpty {
            Section("Renewing Soon") {
                ForEach(upcoming, id: \.renewal.id) { item in
                    NavigationLink(value: SubscriptionRoute(id: item.subscription.id)) {
                        UpcomingRenewalRow(renewal: item.renewal, subscription: item.subscription, now: store.now())
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var listSections: some View {
        let live = sorted(store.liveSubscriptions)
        let inactive = store.subscriptions.filter { !$0.isLive }.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        if !live.isEmpty {
            Section("Active") {
                ForEach(live) { subscription in
                    NavigationLink(value: SubscriptionRoute(id: subscription.id)) {
                        SubscriptionRow(subscription: subscription)
                    }
                    .swipeActions(edge: .trailing) {
                        Button("Mark Cancelled", systemImage: "xmark.circle") { pendingCancel = subscription }.tint(.orange)
                        Button("Edit", systemImage: "pencil") { sheet = .edit(subscription) }.tint(.gray)
                    }
                }
            }
        }
        if !inactive.isEmpty {
            Section("Paused & Cancelled") {
                ForEach(inactive) { subscription in
                    NavigationLink(value: SubscriptionRoute(id: subscription.id)) {
                        SubscriptionRow(subscription: subscription)
                    }
                    .swipeActions(edge: .trailing) {
                        Button("Delete", systemImage: "trash", role: .destructive) { store.deleteSubscription(subscription) }
                    }
                }
            }
        }
    }

    private func sorted(_ subscriptions: [ServiceSubscription]) -> [ServiceSubscription] {
        let engine = store.subscriptionEngine
        switch sort {
        case .nextRenewal:
            return subscriptions.sorted { engine.billingSchedule($0).nextRenewal < engine.billingSchedule($1).nextRenewal }
        case .cost:
            return subscriptions.sorted { engine.monthlyCost($0).minorUnits > engine.monthlyCost($1).minorUnits }
        case .name:
            return subscriptions.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        }
    }
}

// MARK: - Rows

/// Monthly and yearly totals, with trials and foreign-currency plans called out rather than hidden.
struct SubscriptionTotalsView: View {
    let summary: SubscriptionSummary

    var body: some View {
        VStack(alignment: .leading, spacing: KiraSpacing.s) {
            Text("Per month").font(.subheadline).foregroundStyle(KiraColor.textSecondary)
            MoneyText(money: summary.monthlyTotal, font: .kiraHero)
            Text("\(summary.yearlyTotal.formatted) a year · \(summary.activeCount) active")
                .font(.subheadline).foregroundStyle(KiraColor.textSecondary)
            if summary.trialCount > 0 && summary.monthlyAfterTrials != summary.monthlyTotal {
                Label("\(summary.monthlyAfterTrials.formatted)/mo after \(summary.trialCount == 1 ? "your free trial ends" : "\(summary.trialCount) free trials end")",
                      systemImage: "gift")
                    .font(.footnote).foregroundStyle(KiraColor.warning)
            }
            if summary.foreignCurrencyCount > 0 {
                Label("\(summary.foreignCurrencyCount) billed in another currency isn’t included", systemImage: "dollarsign.circle")
                    .font(.footnote).foregroundStyle(KiraColor.textSecondary)
            }
        }
        .padding(.vertical, KiraSpacing.xs)
        .accessibilityElement(children: .combine)
    }
}

struct SubscriptionRow: View {
    @Environment(FinanceStore.self) private var store
    let subscription: ServiceSubscription

    var body: some View {
        let engine = store.subscriptionEngine
        HStack(spacing: KiraSpacing.m) {
            ServiceIcon(subscription: subscription)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(subscription.name).font(.body).lineLimit(1)
                    if subscription.status != .active { SubscriptionStatusPill(status: subscription.status) }
                }
                Text(detail(engine)).font(.caption).foregroundStyle(KiraColor.textSecondary).lineLimit(1)
            }
            Spacer(minLength: KiraSpacing.s)
            VStack(alignment: .trailing, spacing: 2) {
                MoneyText(money: subscription.amount, font: .body.weight(.semibold))
                    .foregroundStyle(subscription.isLive ? KiraColor.textPrimary : KiraColor.textSecondary)
                Text(subscription.cycle.shortSuffix).font(.caption2).foregroundStyle(KiraColor.textSecondary)
            }
        }
        .accessibilityElement(children: .combine)
    }

    private func detail(_ engine: SubscriptionEngine) -> String {
        switch subscription.status {
        case .cancelled:
            return subscription.cancelledAt.map { "Cancelled \($0.kiraMedium)" } ?? "Cancelled"
        case .paused:
            return "Paused"
        case .trial:
            return "Trial ends \((subscription.trialEndsAt ?? subscription.nextRenewal).kiraShort)"
        case .active:
            var parts = ["Renews \(engine.billingSchedule(subscription).nextRenewal.kiraShort)"]
            if subscription.shareCount > 1 { parts.append("your share \(engine.yourShare(subscription).formatted)") }
            return parts.joined(separator: " · ")
        }
    }
}

struct UpcomingRenewalRow: View {
    let renewal: UpcomingRenewal
    let subscription: ServiceSubscription
    let now: Date

    var body: some View {
        HStack(spacing: KiraSpacing.m) {
            ServiceIcon(subscription: subscription, size: 32)
            VStack(alignment: .leading, spacing: 2) {
                Text(subscription.name)
                Text(renewal.isTrialConversion ? "First charge after trial · \(relativeDay)" : relativeDay)
                    .font(.caption).foregroundStyle(renewal.isTrialConversion ? KiraColor.warning : KiraColor.textSecondary)
            }
            Spacer()
            MoneyText(money: renewal.amount, font: .subheadline.weight(.semibold))
        }
        .accessibilityElement(children: .combine)
    }

    private var relativeDay: String {
        let days = KLCalendar.shared.dayDistance(from: now, to: renewal.date)
        switch days {
        case 0: return "Today"
        case 1: return "Tomorrow"
        default: return "\(renewal.date.formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated))) · in \(days) days"
        }
    }
}

struct SubscriptionAlertRow: View {
    let alert: SubscriptionAlert
    let subscription: ServiceSubscription

    var body: some View {
        HStack(spacing: KiraSpacing.m) {
            Image(systemName: symbol).foregroundStyle(tint).font(.title3).frame(width: 28)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.subheadline.weight(.medium))
                Text(detail).font(.caption).foregroundStyle(KiraColor.textSecondary)
            }
        }
        .accessibilityElement(children: .combine)
    }

    private var symbol: String {
        switch alert.kind {
        case .renewsSoon: return "calendar"
        case .trialEnding: return "gift"
        case .priceChanged: return "arrow.up.arrow.down.circle"
        case .noRecentCharge: return "questionmark.circle"
        case .duplicate: return "square.on.square"
        }
    }

    private var tint: Color {
        switch alert.kind {
        case .priceChanged, .trialEnding, .duplicate: return KiraColor.warning
        default: return KiraColor.accent
        }
    }

    private var title: String {
        switch alert.kind {
        case .renewsSoon(let date): return "\(subscription.name) renews \(date.kiraShort)"
        case .trialEnding(let date): return "\(subscription.name) trial ends \(date.kiraShort)"
        case .priceChanged(_, let to): return "\(subscription.name) charged \(to.formatted)"
        case .noRecentCharge: return "Still subscribed to \(subscription.name)?"
        case .duplicate: return "\(subscription.name) is tracked twice"
        }
    }

    private var detail: String {
        switch alert.kind {
        case .renewsSoon: return "Reminder set \(subscription.reminderDaysBefore ?? 0) days before renewal."
        case .trialEnding: return "You’ll be charged \(subscription.amount.formatted) unless you cancel with the provider."
        case .priceChanged(let from, _): return "You’re tracking \(from.formatted). Review the price."
        case .noRecentCharge(let expected): return "No charge around \(expected.kiraShort) in your imported statements."
        case .duplicate: return "Two active entries for the same service."
        }
    }
}

struct SuggestionRow: View {
    let suggestion: SubscriptionSuggestion
    var onAdd: () -> Void

    var body: some View {
        HStack(spacing: KiraSpacing.m) {
            ServiceIcon(service: suggestion.service, name: suggestion.name, size: 32)
            VStack(alignment: .leading, spacing: 2) {
                Text(suggestion.name)
                Text("\(suggestion.occurrences) charges · last \(suggestion.lastCharge.kiraShort)")
                    .font(.caption).foregroundStyle(KiraColor.textSecondary)
            }
            Spacer()
            Button("Add", action: onAdd)
                .buttonStyle(.bordered)
                .accessibilityLabel("Add \(suggestion.name), \(suggestion.amount.formatted) \(suggestion.cycle.displayName.lowercased())")
        }
    }
}

struct SubscriptionStatusPill: View {
    let status: ServiceSubscriptionStatus

    var body: some View {
        let tint: Color = status == .trial ? KiraColor.warning : KiraColor.textSecondary
        Text(status.displayName)
            .font(.caption2.weight(.semibold))
            .foregroundStyle(tint)
            .padding(.horizontal, 6).padding(.vertical, 2)
            .background(tint.opacity(0.14), in: Capsule())
    }
}

/// App-icon-style tile for a service: catalog symbol in the service's tint, or a monogram.
struct ServiceIcon: View {
    let service: SubscriptionService?
    let name: String
    var size: CGFloat = 40
    @ScaledMetric(relativeTo: .body) private var scale = 1.0

    init(subscription: ServiceSubscription, size: CGFloat = 40) {
        self.service = SubscriptionCatalog.service(id: subscription.serviceID)
        self.name = subscription.name
        self.size = size
    }

    init(service: SubscriptionService?, name: String, size: CGFloat = 40) {
        self.service = service
        self.name = name
        self.size = size
    }

    var body: some View {
        let side = size * scale
        let tint = KiraColor.tint(service?.tint ?? "slate")
        ZStack {
            RoundedRectangle(cornerRadius: side * 0.26, style: .continuous).fill(tint.opacity(0.15))
            if let service {
                Image(systemName: service.symbol).font(.system(size: side * 0.44, weight: .semibold)).foregroundStyle(tint)
            } else {
                Text(String(name.prefix(1)).uppercased()).font(.system(size: side * 0.46, weight: .bold, design: .rounded)).foregroundStyle(tint)
            }
        }
        .frame(width: side, height: side)
        .accessibilityHidden(true)
    }
}
