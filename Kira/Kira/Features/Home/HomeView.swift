import SwiftUI
import KiraCore

/// Home: immediate clarity on this month — spending, budget, cash position, recent activity.
struct HomeView: View {
    @Environment(FinanceStore.self) private var store
    var openTab: (AppTab) -> Void
    @State private var addingManually = false
    @State private var selected: TransactionRecord?
    @State private var showingBudgetEditor = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: KiraSpacing.xl) {
                    if store.visibleTransactions.isEmpty && store.accounts.isEmpty {
                        Surface {
                            EmptyStateView(symbol: "leaf", title: "Start with one transaction",
                                           message: "Use + to add a payment, scan a DuitNow QR, or import a bank statement. Kira keeps everything on your iPhone.",
                                           actionTitle: "Add Transaction", action: { addingManually = true })
                        }
                    } else {
                        spendingHero
                        if !store.needsReview.isEmpty { reviewBanner }
                        healthSection
                        insightsSection
                        recentSection
                    }
                }
                .padding(.horizontal, KiraSpacing.l)
                .padding(.bottom, KiraSpacing.xxl)
            }
            .kiraScreen()
            // HIG › Toolbars: a large title keeps people oriented and collapses on scroll.
            .navigationTitle("Summary")
            .navigationBarTitleDisplayMode(.large)
            .kiraNavigationSubtitle("\(Self.greeting(for: store.now())) · \(store.now().formatted(.dateTime.weekday(.wide).day().month(.wide)))")
            .kiraAddMenu()
            .sheet(isPresented: $addingManually) { CaptureFlowView(flow: .manual) }
            .sheet(item: $selected) { record in
                NavigationStack { TransactionDetailView(transactionID: record.id) }
            }
            .sheet(isPresented: $showingBudgetEditor) {
                NavigationStack { BudgetEditorView() }
            }
        }
    }

    // MARK: Sections

    private var spendingHero: some View {
        let summary = store.summary(for: store.currentMonth)
        let previous = store.summary(for: store.comparablePreviousMonth)
        let monthName = KLCalendar.shared.monthName(store.now())
        let change = summary.netSpending.ratio(to: previous.netSpending).map { $0 - 1 }

        return VStack(alignment: .leading, spacing: KiraSpacing.m) {
            Text("\(monthName) spending").font(.subheadline.weight(.medium)).foregroundStyle(KiraColor.textSecondary)
            MoneyText(money: summary.netSpending, font: .kiraHero)
                .foregroundStyle(KiraColor.textPrimary)
                .contentTransition(.numericText())

            if let budget = store.monthlyBudget {
                let status = store.budgetStatus(budget)
                BudgetBar(fraction: status.fractionUsed ?? 0, pace: status.fractionElapsed)
                Text(budgetLine(status))
                    .font(.subheadline).foregroundStyle(status.level == .overBudget ? KiraColor.error : KiraColor.textSecondary)
            } else {
                Button { showingBudgetEditor = true } label: {
                    Label("Set a monthly budget", systemImage: "target")
                        .font(.subheadline.weight(.medium))
                }
            }

            HStack(spacing: KiraSpacing.l) {
                if let change, previous.countedTransactions > 0 {
                    Label("\(change >= 0 ? "+" : "")\(PercentFormatter.string(change)) vs same point last month",
                          systemImage: change > 0 ? "arrow.up.right" : "arrow.down.right")
                        .font(.footnote).foregroundStyle(KiraColor.textSecondary)
                }
                if summary.pendingIncluded > 0 {
                    Text("Includes \(summary.pendingIncluded) pending").font(.footnote).foregroundStyle(KiraColor.warning)
                }
            }
        }
        .padding(KiraSpacing.xl)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(KiraColor.surface, in: RoundedRectangle(cornerRadius: KiraRadius.hero, style: .continuous))
    }

    private func budgetLine(_ status: BudgetStatus) -> String {
        let limit = MoneyFormatter.compact.string(from: status.effectiveLimit)
        let used = PercentFormatter.string(status.fractionUsed ?? 0)
        if status.remaining.isNegative {
            return "\(status.remaining.magnitude.formatted) over your \(limit) budget · \(used) used"
        }
        return "\(status.remaining.formatted) remaining from your \(limit) budget · \(used) used"
    }

    private var reviewBanner: some View {
        Button { openTab(.activity) } label: {
            HStack {
                Image(systemName: "tray.full").foregroundStyle(KiraColor.warning)
                Text("\(store.needsReview.count) to review").font(.subheadline.weight(.medium)).foregroundStyle(KiraColor.textPrimary)
                Text("Pending payments, drafts and uncertain details").font(.footnote).foregroundStyle(KiraColor.textSecondary).lineLimit(1)
                Spacer()
                Image(systemName: "chevron.right").font(.footnote).foregroundStyle(KiraColor.textSecondary)
            }
            .padding(KiraSpacing.m)
            .background(KiraColor.warningSoft, in: RoundedRectangle(cornerRadius: KiraRadius.small, style: .continuous))
        }
        .buttonStyle(.plain)
    }

    private var healthSection: some View {
        let summary = store.summary(for: store.currentMonth)
        let forecast = store.forecast()
        return VStack(alignment: .leading, spacing: KiraSpacing.m) {
            SectionHeader(title: "This month")
            Surface {
                VStack(spacing: 0) {
                    HealthRow(title: "Income received", value: summary.income, kind: .actual)
                    Divider().overlay(KiraColor.separator)
                    HealthRow(title: "Upcoming commitments", value: forecast.scheduledCommitments, kind: .scheduled)
                    Divider().overlay(KiraColor.separator)
                    HealthRow(title: "Expected income still to come", value: forecast.expectedIncome, kind: .scheduled)
                    Divider().overlay(KiraColor.separator)
                    HealthRow(title: "Projected month-end cash", value: forecast.endBalance, kind: .estimated)
                    if store.outstandingCardBalances.minorUnits > 0 {
                        Divider().overlay(KiraColor.separator)
                        HealthRow(title: "Credit cards outstanding", value: store.outstandingCardBalances, kind: .actual)
                    }
                    if summary.debtRepayments.minorUnits > 0 {
                        Divider().overlay(KiraColor.separator)
                        HealthRow(title: "Loan repayments (not spending)", value: summary.debtRepayments, kind: .actual)
                    }
                }
            }
            if forecast.confidence != .high {
                NoticeBanner(tone: .caution, text: forecast.assumptions.first ?? "Forecast is approximate.")
            }
        }
    }

    @ViewBuilder
    private var insightsSection: some View {
        let insights = store.insights()
        if !insights.isEmpty {
            VStack(alignment: .leading, spacing: KiraSpacing.m) {
                SectionHeader(title: "Insights")
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: KiraSpacing.m) {
                        ForEach(insights) { insight in InsightCard(insight: insight, category: store.category(insight.categoryID)) }
                    }
                }
                .scrollClipDisabled()
            }
        }
    }

    private var recentSection: some View {
        VStack(alignment: .leading, spacing: KiraSpacing.m) {
            SectionHeader(title: "Latest", actionTitle: "See all") { openTab(.activity) }
            Surface(padding: 0) {
                VStack(spacing: 0) {
                    let recent = Array(store.visibleTransactions.prefix(6))
                    if recent.isEmpty {
                        Text("No transactions yet").font(.subheadline).foregroundStyle(KiraColor.textSecondary).padding(KiraSpacing.l)
                    }
                    ForEach(Array(recent.enumerated()), id: \.element.id) { index, record in
                        Button { selected = record } label: { TransactionRow(record: record).padding(.horizontal, KiraSpacing.l) }
                            .buttonStyle(.plain)
                        if index < recent.count - 1 { Divider().overlay(KiraColor.separator).padding(.leading, 68) }
                    }
                }
            }
        }
    }

    static func greeting(for date: Date) -> String {
        let hour = KLCalendar.shared.calendar.component(.hour, from: date)
        switch hour {
        case 5..<12: return "Good morning"
        case 12..<18: return "Good afternoon"
        default: return "Good evening"
        }
    }
}

/// Row labelled by certainty so forecasts are never mistaken for confirmed balances.
private struct HealthRow: View {
    enum Kind { case actual, scheduled, estimated }
    let title: String
    let value: Money
    let kind: Kind

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.subheadline).foregroundStyle(KiraColor.textPrimary)
                Text(kindLabel).font(.caption).foregroundStyle(KiraColor.textSecondary)
            }
            Spacer()
            MoneyText(money: value, font: .body.weight(.semibold))
                .foregroundStyle(kind == .estimated ? KiraColor.textSecondary : KiraColor.textPrimary)
        }
        .padding(.vertical, KiraSpacing.m)
        .accessibilityElement(children: .combine)
    }

    private var kindLabel: String {
        switch kind {
        case .actual: return "Recorded"
        case .scheduled: return "Scheduled"
        case .estimated: return "Estimate"
        }
    }
}

private struct InsightCard: View {
    let insight: Insight
    let category: CategoryDefinition?

    var body: some View {
        VStack(alignment: .leading, spacing: KiraSpacing.s) {
            Image(systemName: icon).font(.headline).foregroundStyle(tint)
            Text(insight.title).font(.headline).foregroundStyle(KiraColor.textPrimary).fixedSize(horizontal: false, vertical: true)
            Text(insight.detail).font(.footnote).foregroundStyle(KiraColor.textSecondary).fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(KiraSpacing.l)
        .frame(width: 250, alignment: .topLeading)
        .frame(minHeight: 150, alignment: .topLeading)
        .background(KiraColor.surface, in: RoundedRectangle(cornerRadius: KiraRadius.card, style: .continuous))
        .accessibilityElement(children: .combine)
    }

    private var icon: String {
        switch insight.kind {
        case .categoryChange: return category?.symbol ?? "chart.line.uptrend.xyaxis"
        case .upcomingCommitments: return "calendar"
        case .merchantSpend: return "storefront"
        case .discretionaryRemaining: return "leaf"
        case .budgetPace: return "speedometer"
        case .recurringFound: return "repeat"
        }
    }

    private var tint: Color {
        switch insight.tone {
        case .caution: return KiraColor.warning
        case .positive, .neutral: return KiraColor.accent
        }
    }
}
