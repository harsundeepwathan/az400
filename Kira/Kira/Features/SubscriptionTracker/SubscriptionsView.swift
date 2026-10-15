import SwiftUI
import Charts
import KiraCore

/// Navigation value for a subscription's detail screen.
struct SubscriptionRoute: Hashable {
    let id: UUID
}

/// Navigation value for the renewal calendar.
struct SubscriptionCalendarRoute: Hashable {}

/// Tracked subscriptions: monthly cost, what renews next, anything that needs attention, and
/// recurring charges Kira found that aren't tracked yet.
struct SubscriptionsView: View {
    @Environment(FinanceStore.self) private var store
    @State private var sheet: SubscriptionSheet?
    @State private var sort: SortOrder = .upcoming
    @State private var pendingCancel: ServiceSubscription?

    enum SortOrder: String, CaseIterable, Identifiable {
        case upcoming = "Upcoming", cost = "Monthly Cost", name = "Name"
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
        let dueSoon = store.renewalsNext30Days
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
                Section {
                    SubscriptionStatTiles(summary: summary, dueSoon: dueSoon, dueSubscriptions: dueSubscriptions(dueSoon))
                        .listRowInsets(EdgeInsets())
                        .listRowBackground(Color.clear)
                }
                Section {
                    SubscriptionTrendView()
                } header: {
                    Text("Spending Trends")
                }
                alertsSection
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
            ToolbarItem(placement: .primaryAction) {
                NavigationLink(value: SubscriptionCalendarRoute()) {
                    Label("Renewal Calendar", systemImage: "calendar")
                }
                .disabled(store.subscriptions.isEmpty)
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
        .navigationDestination(for: SubscriptionCalendarRoute.self) { _ in
            SubscriptionCalendarView()
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

    private func dueSubscriptions(_ renewals: [UpcomingRenewal]) -> [ServiceSubscription] {
        var seen = Set<UUID>()
        return renewals.compactMap { renewal in
            guard seen.insert(renewal.subscriptionID).inserted else { return nil }
            return store.subscription(renewal.subscriptionID)
        }
    }

    private func sorted(_ subscriptions: [ServiceSubscription]) -> [ServiceSubscription] {
        let engine = store.subscriptionEngine
        switch sort {
        case .upcoming:
            return subscriptions.sorted { engine.billingSchedule($0).nextRenewal < engine.billingSchedule($1).nextRenewal }
        case .cost:
            return subscriptions.sorted { engine.monthlyCost($0).minorUnits > engine.monthlyCost($1).minorUnits }
        case .name:
            return subscriptions.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        }
    }
}

// MARK: - Rows

/// Two summary tiles: what plans cost per month, and what's due in the next 30 days.
/// Trials and foreign-currency plans are called out rather than hidden.
struct SubscriptionStatTiles: View {
    let summary: SubscriptionSummary
    let dueSoon: [UpcomingRenewal]
    /// Services behind `dueSoon`, soonest first, each once.
    let dueSubscriptions: [ServiceSubscription]

    var body: some View {
        let dueTotal = dueSoon.filter { $0.amount.currency == .myr }.map(\.amount).sum()
        VStack(alignment: .leading, spacing: KiraSpacing.s) {
            HStack(alignment: .top, spacing: KiraSpacing.m) {
                tile(title: "Per Month", symbol: "repeat", amount: summary.monthlyTotal) {
                    Text("\(summary.activeCount) active · \(summary.yearlyTotal.formatted)/yr")
                        .font(.caption).foregroundStyle(KiraColor.textSecondary)
                        .lineLimit(1).minimumScaleFactor(0.8)
                }
                tile(title: "Due in 30 Days", symbol: "calendar", amount: dueTotal) {
                    if dueSubscriptions.isEmpty {
                        Text("Nothing due").font(.caption).foregroundStyle(KiraColor.textSecondary)
                    } else {
                        HStack(spacing: 6) {
                            ServiceIconStack(subscriptions: dueSubscriptions, size: 22, limit: 3)
                            Text("\(dueSoon.count) bill\(dueSoon.count == 1 ? "" : "s")")
                                .font(.caption).foregroundStyle(KiraColor.textSecondary)
                        }
                    }
                }
            }
            if summary.trialCount > 0 && summary.monthlyAfterTrials != summary.monthlyTotal {
                Label("\(summary.monthlyAfterTrials.formatted)/mo after \(summary.trialCount == 1 ? "your free trial ends" : "\(summary.trialCount) free trials end")",
                      systemImage: "gift")
                    .font(.footnote).foregroundStyle(KiraColor.warning)
                    .padding(.horizontal, KiraSpacing.xs)
            }
            if summary.foreignCurrencyCount > 0 {
                Label("\(summary.foreignCurrencyCount) billed in another currency isn’t included", systemImage: "dollarsign.circle")
                    .font(.footnote).foregroundStyle(KiraColor.textSecondary)
                    .padding(.horizontal, KiraSpacing.xs)
            }
        }
    }

    private func tile<Footer: View>(title: String, symbol: String, amount: Money, @ViewBuilder footer: () -> Footer) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Label(title, systemImage: symbol)
                .font(.subheadline.weight(.medium))
                .foregroundStyle(KiraColor.textSecondary)
            MoneyText(money: amount, font: .system(.title, design: .rounded).weight(.bold))
                .minimumScaleFactor(0.6).lineLimit(1)
            footer()
                .frame(minHeight: 26, alignment: .leading)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(KiraSpacing.l)
        .background(KiraColor.surface, in: RoundedRectangle(cornerRadius: KiraRadius.card, style: .continuous))
        .accessibilityElement(children: .combine)
    }
}

/// Recorded subscription charges per month. Only real, matched transactions are plotted —
/// never the schedule — so the chart is empty until statements or payments are recorded.
struct SubscriptionTrendView: View {
    @Environment(FinanceStore.self) private var store
    @State private var range: Range = .sixMonths
    /// Month under the person's finger while scrubbing the chart.
    @State private var selectedMonth: Date?

    enum Range: Int, CaseIterable, Identifiable {
        case threeMonths = 3, sixMonths = 6, year = 12
        var id: Int { rawValue }
        var label: String { self == .year ? "1Y" : "\(rawValue)M" }
    }

    var body: some View {
        let points = store.subscriptionSpend(months: range.rawValue)
        let hasData = points.contains { !$0.amount.isZero }
        let selected = selectedMonth.flatMap { month in
            points.first { KLCalendar.shared.calendar.isDate($0.monthStart, equalTo: month, toGranularity: .month) }
        }
        VStack(alignment: .leading, spacing: KiraSpacing.m) {
            Picker("Range", selection: $range) {
                ForEach(Range.allCases) { Text($0.label).tag($0) }
            }
            .pickerStyle(.segmented)

            if hasData {
                headline(points, selected: selected)
                chart(points, selected: selected)
            } else {
                ContentUnavailableView {
                    Label("No Charges Yet", systemImage: "chart.line.uptrend.xyaxis")
                } description: {
                    Text("Charges appear here once Kira matches them in imported statements or logged payments.")
                }
                .frame(minHeight: 160)
            }
        }
        .padding(.vertical, KiraSpacing.xs)
        .sensoryFeedback(.selection, trigger: selected?.monthStart)
    }

    /// HIG › Charts: lead with the takeaway. While scrubbing, it shows the selected month instead.
    private func headline(_ points: [MonthlyAmount], selected: MonthlyAmount?) -> some View {
        let total = points.map(\.amount).sum()
        let average = Money(minorUnits: total.minorUnits / Int64(max(points.count, 1)))
        return VStack(alignment: .leading, spacing: 2) {
            Text(selected.map { $0.monthStart.formatted(.dateTime.month(.wide).year()) } ?? "Average a month")
                .font(.subheadline).foregroundStyle(KiraColor.textSecondary)
            MoneyText(money: selected?.amount ?? average, font: .system(.title2, design: .rounded).weight(.bold))
                .contentTransition(.numericText())
            Text(selected.map { isCurrentMonth($0) ? "Charged so far this month" : "Charged that month" }
                 ?? "\(total.formatted) charged in the last \(points.count) months")
                .font(.caption).foregroundStyle(KiraColor.textSecondary)
        }
        .accessibilityElement(children: .combine)
    }

    private func chart(_ points: [MonthlyAmount], selected: MonthlyAmount?) -> some View {
        Chart {
            ForEach(Array(zip(points, [nil] + points.dropLast().map(Optional.some))), id: \.0.id) { point, previous in
                let value = Double(point.amount.minorUnits) / 100
                // Labels go below a point that dropped, so they don't sit on the line.
                let dropped = previous.map { point.amount.minorUnits < $0.amount.minorUnits } ?? false
                AreaMark(x: .value("Month", point.monthStart, unit: .month), y: .value("Charged", value))
                    .foregroundStyle(LinearGradient(colors: [KiraColor.accent.opacity(0.28), KiraColor.accent.opacity(0.02)],
                                                    startPoint: .top, endPoint: .bottom))
                    .interpolationMethod(.monotone)  // never overshoots between real values
                LineMark(x: .value("Month", point.monthStart, unit: .month), y: .value("Charged", value))
                    .foregroundStyle(KiraColor.accent)
                    .lineStyle(StrokeStyle(lineWidth: 2.5, lineCap: .round, lineJoin: .round))
                    .interpolationMethod(.monotone)  // never overshoots between real values
                PointMark(x: .value("Month", point.monthStart, unit: .month), y: .value("Charged", value))
                    // The current month is still in progress: drawn hollow and called "so far".
                    .symbol {
                        Circle()
                            .strokeBorder(KiraColor.accent, lineWidth: 2)
                            .background(Circle().fill(isCurrentMonth(point) ? KiraColor.surface : KiraColor.accent))
                            .frame(width: 8, height: 8)
                    }
                    .annotation(position: dropped ? .bottom : .top, spacing: 6) {
                        if points.count <= 6 && selected == nil {
                            Text(point.amount.formatted)
                                .font(.caption2.weight(.medium)).monospacedDigit()
                                .foregroundStyle(KiraColor.textSecondary)
                        }
                    }
                    .accessibilityLabel(point.monthStart.formatted(.dateTime.month(.wide).year()) + (isCurrentMonth(point) ? ", so far" : ""))
                    .accessibilityValue(point.amount.formatted)
            }
            if let selected {
                RuleMark(x: .value("Month", selected.monthStart, unit: .month))
                    .foregroundStyle(KiraColor.textTertiary)
                    .lineStyle(StrokeStyle(lineWidth: 1, dash: [3, 3]))
            }
        }
        .chartXSelection(value: $selectedMonth)
        .chartYScale(domain: .automatic(includesZero: true))
        .chartYAxis(.hidden)
        .chartXAxis {
            AxisMarks(values: .stride(by: .month, count: range == .year ? 2 : 1)) { _ in
                AxisValueLabel(format: .dateTime.month(.abbreviated))
            }
        }
        .chartPlotStyle { $0.padding(.horizontal, 12) }
        .frame(height: 170)
        .accessibilityChartDescriptor(SubscriptionTrendDescriptor(points: points))
    }

    private func isCurrentMonth(_ point: MonthlyAmount) -> Bool {
        KLCalendar.shared.calendar.isDate(point.monthStart, equalTo: store.now(), toGranularity: .month)
    }

    static func summary(_ points: [MonthlyAmount]) -> String {
        let nonZero = points.filter { !$0.amount.isZero }
        let total = points.map(\.amount).sum()
        guard !nonZero.isEmpty else { return "No recorded charges." }
        let average = Money(minorUnits: total.minorUnits / Int64(points.count))
        return "\(total.formatted) charged over \(points.count) months, about \(average.formatted) a month."
    }
}

struct SubscriptionTrendDescriptor: AXChartDescriptorRepresentable {
    let points: [MonthlyAmount]

    func makeChartDescriptor() -> AXChartDescriptor {
        let values = points.map { Double($0.amount.minorUnits) / 100 }
        let months = points.map { $0.monthStart.formatted(.dateTime.month(.wide).year()) }
        let xAxis = AXCategoricalDataAxisDescriptor(title: "Month", categoryOrder: months)
        let yAxis = AXNumericDataAxisDescriptor(title: "Charged in ringgit", range: 0...max(values.max() ?? 1, 1), gridlinePositions: []) { value in
            MoneyFormatter.standard.accessibilityString(from: Money(minorUnits: Int64(value * 100)))
        }
        let series = AXDataSeriesDescriptor(name: "Subscription charges", isContinuous: true,
                                            dataPoints: zip(months, values).map { AXDataPoint(x: $0, y: $1) })
        return AXChartDescriptor(title: "Subscription spending", summary: SubscriptionTrendView.summary(points),
                                 xAxis: xAxis, yAxis: yAxis, additionalAxes: [], series: [series])
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
                Text(subscription.cycle.displayName).font(.caption).foregroundStyle(KiraColor.textSecondary)
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
            var parts = ["Renews on \(engine.billingSchedule(subscription).nextRenewal.formatted(date: .abbreviated, time: .omitted))"]
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
            ServiceIcon(subscription: subscription, size: 36)
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
            ServiceIcon(service: suggestion.service, name: suggestion.name, size: 36)
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

/// Status capsule with a symbol, so it doesn't rely on colour alone.
struct SubscriptionStatusPill: View {
    let status: ServiceSubscriptionStatus
    var prominent = false

    var body: some View {
        Label(status.displayName.uppercased(), systemImage: symbol)
            .labelStyle(.titleAndIcon)
            .font((prominent ? Font.caption : .caption2).weight(.semibold))
            .foregroundStyle(tint)
            .padding(.horizontal, prominent ? 10 : 6).padding(.vertical, prominent ? 4 : 2)
            .background(tint.opacity(0.14), in: Capsule())
    }

    private var symbol: String {
        switch status {
        case .active: return "checkmark.circle.fill"
        case .trial: return "gift.fill"
        case .paused: return "pause.circle.fill"
        case .cancelled: return "xmark.circle.fill"
        }
    }

    private var tint: Color {
        switch status {
        case .active: return KiraColor.positive
        case .trial: return KiraColor.warning
        case .paused, .cancelled: return KiraColor.textSecondary
        }
    }
}
