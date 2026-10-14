import SwiftUI
import Charts
import Accessibility
import KiraCore

/// Analytics that answer questions, not decoration. Every figure comes from KiraCore's
/// LedgerCalculator via AnalyticsEngine, so it always agrees with Home and Budgets.
struct InsightsView: View {
    @Environment(FinanceStore.self) private var store
    @State private var period: Period = .thisMonth
    @State private var showingBudgetEditor = false
    @State private var showingPaywall = false

    enum Period: String, CaseIterable, Identifiable {
        case thisMonth = "This month", lastMonth = "Last month", last3 = "3 months"
        var id: String { rawValue }
    }

    private var analytics: AnalyticsEngine { AnalyticsEngine(ledger: store.ledger) }

    private var interval: DateInterval {
        let calendar = KLCalendar.shared
        let now = store.now()
        switch period {
        case .thisMonth: return calendar.monthInterval(containing: now)
        case .lastMonth: return calendar.previousMonthInterval(before: now)
        case .last3: return DateInterval(start: calendar.addingMonths(-2, to: calendar.monthInterval(containing: now).start), end: calendar.monthInterval(containing: now).end)
        }
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: KiraSpacing.xl) {
                    Picker("Period", selection: $period) { ForEach(Period.allCases) { Text($0.rawValue).tag($0) } }
                        .pickerStyle(.segmented)

                    if store.visibleTransactions.isEmpty {
                        Surface { EmptyStateView(symbol: "chart.bar", title: "No data yet", message: "Insights appear once you’ve recorded some spending.") }
                    } else {
                        budgetsSection
                        trendSection
                        categorySection
                        merchantSection
                        patternsSection
                        planningLinks
                    }
                }
                .padding(KiraSpacing.l)
            }
            .kiraScreen()
            .navigationTitle("Insights")
            .sheet(isPresented: $showingBudgetEditor) { NavigationStack { BudgetEditorView() } }
            .sheet(isPresented: $showingPaywall) { PaywallView() }
        }
    }

    // MARK: Budgets

    private var budgetsSection: some View {
        VStack(alignment: .leading, spacing: KiraSpacing.m) {
            SectionHeader(title: "Budgets", actionTitle: "Edit") { showingBudgetEditor = true }
            Surface {
                VStack(alignment: .leading, spacing: KiraSpacing.l) {
                    let budgets = ([store.monthlyBudget].compactMap { $0 }) + store.categoryBudgets
                    if budgets.isEmpty {
                        Text("Set a monthly budget to see how you’re pacing.").font(.subheadline).foregroundStyle(KiraColor.textSecondary)
                    }
                    ForEach(budgets) { budget in
                        let status = store.budgetStatus(budget)
                        VStack(alignment: .leading, spacing: 6) {
                            HStack {
                                Text(budget.categoryID.flatMap { store.category($0)?.name } ?? "All spending").font(.subheadline.weight(.medium))
                                Spacer()
                                Text("\(status.spent.formatted) of \(MoneyFormatter.compact.string(from: status.effectiveLimit))")
                                    .font(.subheadline).monospacedDigit().foregroundStyle(KiraColor.textSecondary)
                            }
                            BudgetBar(fraction: status.fractionUsed ?? 0, pace: status.fractionElapsed, height: 8)
                            Text(statusText(status)).font(.caption).foregroundStyle(status.level == .onTrack ? KiraColor.textSecondary : KiraColor.warning)
                        }
                        .accessibilityElement(children: .combine)
                    }
                }
            }
        }
    }

    private func statusText(_ status: BudgetStatus) -> String {
        switch status.level {
        case .overBudget: return "Over by \(status.remaining.magnitude.formatted)"
        case .nearingLimit: return "\(status.remaining.formatted) left · on pace for \(status.projectedSpend.formatted)"
        case .onTrack:
            var text = "\(status.remaining.formatted) left"
            if status.rolloverAmount.minorUnits != 0 { text += " · includes \(status.rolloverAmount.formatted) rollover" }
            return text
        }
    }

    // MARK: Trend (single series → accent colour, no legend needed)

    private var trendSection: some View {
        let points = analytics.monthlyTrend(store.transactions, endingAt: store.now(), months: 6)
        return VStack(alignment: .leading, spacing: KiraSpacing.m) {
            SectionHeader(title: "Monthly spending")
            Surface {
                VStack(alignment: .leading, spacing: KiraSpacing.s) {
                    // HIG › Charts: summarise the main message before the chart.
                    Text(Self.trendSummary(points)).font(.subheadline).foregroundStyle(KiraColor.textSecondary)
                    Chart(points) { point in
                        BarMark(x: .value("Month", point.monthStart, unit: .month),
                                y: .value("Spending", Double(point.spending.minorUnits) / 100), width: .ratio(0.55))
                            .foregroundStyle(KiraColor.accent.opacity(point.id == points.last?.id ? 1 : 0.55))
                            .cornerRadius(4)
                            .accessibilityLabel(point.monthStart.formatted(.dateTime.month(.wide)))
                            .accessibilityValue(point.spending.formatted)
                    }
                    // Bar charts start at zero; familiar tick sequence via automatic values.
                    .chartYScale(domain: .automatic(includesZero: true))
                    .chartYAxis {
                        AxisMarks(position: .leading, values: .automatic(desiredCount: 3)) { value in
                            AxisGridLine().foregroundStyle(KiraColor.separator)
                            AxisValueLabel { if let amount = value.as(Double.self) { Text("RM\(Int(amount))").font(.caption2) } }
                        }
                    }
                    .chartXAxis { AxisMarks(values: .stride(by: .month)) { _ in AxisValueLabel(format: .dateTime.month(.abbreviated)) } }
                    .frame(height: 180)
                    // Audio Graphs for VoiceOver users.
                    .accessibilityChartDescriptor(SpendingTrendDescriptor(points: points))
                }
            }
        }
    }

    static func trendSummary(_ points: [MonthlyPoint]) -> String {
        guard let last = points.last, points.count >= 2 else { return "Your spending by month." }
        let previous = points[points.count - 2]
        guard let ratio = last.spending.ratio(to: previous.spending) else { return "\(last.spending.formatted) so far this month." }
        let change = ratio - 1
        let direction = change >= 0 ? "up" : "down"
        return "\(last.spending.formatted) so far this month, \(direction) \(PercentFormatter.string(abs(change))) on last month’s total."
    }

    // MARK: Categories — ranked bars beat a pie for comparing magnitudes.

    private var categorySection: some View {
        let shares = analytics.categoryBreakdown(store.transactions, filter: TransactionFilter(dateInterval: interval))
        return VStack(alignment: .leading, spacing: KiraSpacing.m) {
            SectionHeader(title: "Where it went")
            Surface {
                VStack(spacing: KiraSpacing.m) {
                    if shares.isEmpty { Text("No spending in this period.").font(.subheadline).foregroundStyle(KiraColor.textSecondary) }
                    ForEach(shares.prefix(8)) { share in
                        let category = store.category(share.categoryID)
                        HStack(spacing: KiraSpacing.m) {
                            CategoryIcon(category: category, size: 32)
                            VStack(alignment: .leading, spacing: 4) {
                                HStack {
                                    Text(category?.name ?? "Other").font(.subheadline)
                                    Spacer()
                                    MoneyText(money: share.amount, font: .subheadline.weight(.medium))
                                }
                                GeometryReader { proxy in
                                    Capsule().fill(KiraColor.accent)
                                        .frame(width: max(proxy.size.width * share.share / (shares.first?.share ?? 1), 4), height: 6)
                                }
                                .frame(height: 6)
                            }
                        }
                        .accessibilityElement(children: .combine)
                        .accessibilityValue("\(PercentFormatter.string(share.share)) of spending")
                    }
                }
            }
        }
    }

    private var merchantSection: some View {
        let merchants = analytics.topMerchants(store.transactions, filter: TransactionFilter(dateInterval: interval), limit: 5)
        return Group {
            if !merchants.isEmpty {
                VStack(alignment: .leading, spacing: KiraSpacing.m) {
                    SectionHeader(title: "Top merchants")
                    Surface {
                        VStack(spacing: KiraSpacing.m) {
                            ForEach(merchants) { merchant in
                                HStack {
                                    Text(merchant.displayName).font(.subheadline)
                                    Text("\(merchant.count)×").font(.caption).foregroundStyle(KiraColor.textSecondary)
                                    Spacer()
                                    MoneyText(money: merchant.amount, font: .subheadline.weight(.medium))
                                }
                            }
                        }
                    }
                }
            }
        }
    }

    private var patternsSection: some View {
        let filter = TransactionFilter(dateInterval: interval)
        let split = analytics.weekdayWeekend(store.transactions, filter: filter)
        let savings = analytics.savingsRate(store.transactions, filter: filter)
        let channels = analytics.byPaymentChannel(store.transactions, filter: filter)
        let recurring = analytics.recurringCharges(store.transactions)
        return VStack(alignment: .leading, spacing: KiraSpacing.m) {
            SectionHeader(title: "Patterns")
            Surface {
                VStack(alignment: .leading, spacing: KiraSpacing.m) {
                    LabeledContent("Average weekday") { MoneyText(money: split.weekdayAverage) }
                    LabeledContent("Average weekend day") { MoneyText(money: split.weekendAverage) }
                    if let savings {
                        LabeledContent("Savings rate", value: PercentFormatter.string(savings))
                    }
                    if !channels.isEmpty {
                        Divider()
                        ForEach(Array(channels.prefix(4)), id: \.0) { pair in
                            LabeledContent(pair.0.displayName) { MoneyText(money: pair.1) }
                        }
                    }
                    if !recurring.isEmpty {
                        Divider()
                        Text("Looks recurring").font(.subheadline.weight(.medium))
                        ForEach(recurring.prefix(4)) { charge in
                            LabeledContent("\(charge.displayName) · next ~\(charge.nextExpectedDate.kiraShort)") { MoneyText(money: charge.typicalAmount) }
                        }
                    }
                }
                .font(.subheadline)
            }
        }
    }

    private var planningLinks: some View {
        VStack(alignment: .leading, spacing: KiraSpacing.m) {
            SectionHeader(title: "Plan ahead")
            Surface(padding: 0) {
                VStack(spacing: 0) {
                    gatedLink("Cash-flow forecast", symbol: "waveform.path.ecg", feature: .cashFlowForecast) { CashFlowView() }
                    Divider().padding(.leading, 52)
                    gatedLink("Commitments & loans", symbol: "calendar.badge.clock", feature: .manualTracking) { CommitmentsView() }
                }
            }
        }
    }

    @ViewBuilder
    private func gatedLink<Destination: View>(_ title: String, symbol: String, feature: Feature, @ViewBuilder destination: @escaping () -> Destination) -> some View {
        let row = HStack {
            Image(systemName: symbol).foregroundStyle(KiraColor.accent).frame(width: 28)
            Text(title).foregroundStyle(KiraColor.textPrimary)
            Spacer()
            if !store.gate.isAvailable(feature) { Text(feature.requiredTier.displayName).font(.caption.weight(.semibold)).foregroundStyle(KiraColor.accent) }
            Image(systemName: "chevron.right").font(.footnote).foregroundStyle(KiraColor.textSecondary)
        }
        .padding(KiraSpacing.l)
        .contentShape(Rectangle())

        if store.gate.isAvailable(feature) {
            NavigationLink(destination: destination) { row }.buttonStyle(.plain)
        } else {
            Button { showingPaywall = true } label: { row }.buttonStyle(.plain)
        }
    }
}


/// Audio Graph description of the monthly spending chart (HIG › Charts › Accessibility).
struct SpendingTrendDescriptor: AXChartDescriptorRepresentable {
    let points: [MonthlyPoint]

    func makeChartDescriptor() -> AXChartDescriptor {
        let values = points.map { Double($0.spending.minorUnits) / 100 }
        let xAxis = AXCategoricalDataAxisDescriptor(title: "Month", categoryOrder: points.map { $0.monthStart.formatted(.dateTime.month(.wide)) })
        let yAxis = AXNumericDataAxisDescriptor(title: "Spending in ringgit", range: 0...(values.max() ?? 1), gridlinePositions: []) { value in
            MoneyFormatter.standard.accessibilityString(from: Money(minorUnits: Int64(value * 100)))
        }
        let series = AXDataSeriesDescriptor(name: "Spending", isContinuous: false, dataPoints: zip(points, values).map { point, value in
            AXDataPoint(x: point.monthStart.formatted(.dateTime.month(.wide)), y: value)
        })
        return AXChartDescriptor(title: "Monthly spending", summary: InsightsView.trendSummary(points), xAxis: xAxis, yAxis: yAxis, additionalAxes: [], series: [series])
    }
}
