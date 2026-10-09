import StoreKit
import SwiftUI
import VectorCore

/// Premium paywall in the tile design. Honest by construction: prices come
/// from the App Store, savings are computed from real prices, the trial only
/// shows if StoreKit says the user is eligible, and there are no countdowns.
/// The example check-in in the blue hero tile is labelled as an example.
struct PaywallView: View {
    var trigger: PaywallTrigger
    @Environment(AppModel.self) private var model
    @Environment(PurchaseService.self) private var purchases
    @Environment(\.dismiss) private var dismiss
    @State private var plan: PurchaseService.Plan = .annual

    private struct Benefit: Identifiable {
        var id: String { title }
        var symbol: String
        var title: String
        var detail: String
    }

    private let benefits: [Benefit] = [
        Benefit(symbol: Icon.recommendation, title: "One clear decision every week",
                detail: "Adjust calories, progress a lift, or change nothing"),
        Benefit(symbol: "checkmark.seal", title: "Evidence with every decision",
                detail: "See the trend, adherence and confidence behind it"),
        Benefit(symbol: "arrow.right", title: "Apply it in one tap",
                detail: "Targets update for the week ahead"),
        Benefit(symbol: "clock", title: "Coaching history",
                detail: "What changed each week, and whether it worked"),
        Benefit(symbol: "chart.line.uptrend.xyaxis", title: "Progression for every lift",
                detail: "The next weight and reps for every exercise, explained"),
        Benefit(symbol: Icon.scan, title: "More meal scans",
                detail: "Up to 30 a day. Scans are estimates you can edit")
    ]

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    header
                    exampleCheckIn
                    benefitList
                    plans
                    alwaysFree
                }
                .padding(.bottom, Space.lg)
            }
            .widgetCanvas()
            .safeAreaInset(edge: .bottom, spacing: 0) { purchaseBar }
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    SheetCloseButton { dismiss() }
                }
                ToolbarItem(placement: .primaryAction) {
                    Button("Restore") { Task { await purchases.restore() } }
                        .font(.body)
                        .foregroundStyle(WidgetTint.training.ink)
                        .disabled(purchases.state == .purchasing)
                }
            }
            .task { await purchases.load() }
            .onChange(of: purchases.isPro) { _, isPro in if isPro { dismiss() } }
        }
    }

    // MARK: Header

    private var header: some View {
        VStack(alignment: .leading, spacing: Space.xs) {
            Text("Vector Pro")
                .font(.system(.subheadline, weight: .semibold))
                .foregroundStyle(WidgetTint.training.ink)
            Text("Unlock your digital coach")
                .font(.system(.largeTitle, weight: .bold))
                .foregroundStyle(WColor.textPrimary)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityAddTraits(.isHeader)
            Text(contextLine)
                .font(.body)
                .foregroundStyle(WColor.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, Space.gutter + 4)
        .padding(.top, Space.xs)
        .padding(.bottom, Space.xs)
    }

    /// A static, clearly labelled example of what a check-in looks like.
    /// It is not the user's data.
    private var exampleCheckIn: some View {
        WidgetHero(label: "Example check-in", symbol: Icon.recommendation, spacing: Space.xxs) {
            HStack(alignment: .firstTextBaseline, spacing: Space.xs) {
                Text("2,300")
                Image(systemName: "arrow.right")
                    .font(.system(.title2, weight: .semibold))
                    .foregroundStyle(WColor.onHeroSecondary)
                Text("2,550")
            }
            .font(.system(.largeTitle, weight: .bold).monospacedDigit())
            .foregroundStyle(WColor.onHero)
            .lineLimit(1)
            .minimumScaleFactor(0.7)
            Text("kcal a day")
                .font(.body)
                .foregroundStyle(WColor.onHeroSecondary)
            Text("Weight trend \u{2212}0.17 kg a week for 20 days, below the build-muscle range. High confidence.")
                .font(.subheadline)
                .foregroundStyle(WColor.onHero)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, Space.xs)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Example check-in: change calories from 2,300 to 2,550 a day. Weight trend minus 0.17 kilograms a week for 20 days, below the build-muscle range. High confidence.")
    }

    /// The subheading speaks to why the paywall was opened.
    private var contextLine: String {
        switch trigger {
        case .progressionMoment:
            let count = model.progressionOpportunities.count
            return "You have \(count) progression \(count == 1 ? "opportunity" : "opportunities") waiting. Pro shows you every one, every session."
        case .mealScanQuota:
            return "You've used this week's free scans. Pro makes meal logging a photo, every time."
        case .analytics, .history:
            return "See your full history, strength curves and muscle balance."
        default:
            return "Each week Vector reads your training, food and weight, then makes one decision and shows why."
        }
    }

    // MARK: Benefits

    private var benefitList: some View {
        WidgetSection(title: "What Pro adds", symbol: "plus.circle", spacing: Space.md) {
            ForEach(benefits) { benefit in
                HStack(alignment: .top, spacing: Space.sm) {
                    Image(systemName: benefit.symbol)
                        .font(.system(.body, weight: .semibold))
                        .foregroundStyle(WColor.onSelected)
                        .frame(width: 36, height: 36)
                        .background(WColor.selected, in: RoundedRectangle(cornerRadius: 11, style: .continuous))
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(benefit.title)
                            .font(.system(.body, weight: .semibold))
                            .foregroundStyle(WColor.textPrimary)
                        Text(benefit.detail)
                            .font(.subheadline)
                            .foregroundStyle(WColor.textSecondary)
                    }
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .accessibilityElement(children: .combine)
            }
        }
    }

    private var alwaysFree: some View {
        Text("Always free: unlimited workout logging, templates, exercise history, calorie tracking and \(EntitlementPolicy.freeMealScansPerWeek) AI meal scans a week.")
            .font(.footnote)
            .foregroundStyle(WColor.textSecondary)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, Space.gutter + 4)
            .padding(.top, Space.xxs)
    }

    // MARK: Plans

    /// Two selectable rows in one tile; the chosen one turns soft blue.
    private var plans: some View {
        VStack(alignment: .leading, spacing: 2) {
            WidgetChoiceRow(title: "Annual", detail: annualLine, isSelected: plan == .annual) { plan = .annual }
            WidgetChoiceRow(title: "Monthly",
                            detail: purchases.displayPrice(.monthly).map { "\($0) a month" } ?? "Loading price\u{2026}",
                            isSelected: plan == .monthly) { plan = .monthly }
            if case .failed(let message) = purchases.state {
                Label(message, systemImage: "exclamationmark.triangle")
                    .font(.footnote)
                    .foregroundStyle(VColor.danger)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(Space.sm)
            }
        }
        .padding(4)
        .widgetSurface()
        .sensoryFeedback(.selection, trigger: plan)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Plans")
    }

    /// "$59.99 a year · about $5.00 a month · save 50%", all from StoreKit.
    private var annualLine: String {
        guard let price = purchases.displayPrice(.annual) else { return "Loading price\u{2026}" }
        var parts = ["\(price) a year"]
        if let monthly = purchases.annualMonthlyEquivalent() { parts.append("about \(monthly) a month") }
        if let saving = purchases.annualSavingsPercent() { parts.append("save \(saving)%") }
        return parts.joined(separator: " \u{00B7} ")
    }

    // MARK: Purchase

    private var purchaseBar: some View {
        let trial = plan == .annual ? purchases.trialDescription() : nil
        return WidgetActionBar {
            Button {
                Task { if await purchases.purchase(plan) { model.setTier(.pro) } }
            } label: {
                if purchases.state == .purchasing {
                    ProgressView().tint(WColor.onStrong)
                        .accessibilityLabel("Purchasing")
                } else {
                    Text(trial.map { "Start \($0)" } ?? "Subscribe")
                }
            }
            .buttonStyle(.widgetPrimary)
            .disabled(purchases.displayPrice(plan) == nil || purchases.state == .purchasing)
            Text(renewalText(trial: trial))
                .font(.caption)
                .foregroundStyle(WColor.textSecondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: Space.xs) {
                Link("Terms", destination: AppConfig.termsURL)
                Text("\u{00B7}").foregroundStyle(WColor.textSecondary).accessibilityHidden(true)
                Link("Privacy", destination: AppConfig.privacyURL)
            }
            .font(.caption)
            .tint(WidgetTint.training.ink)
            .frame(minHeight: Size.minTouch)
        }
    }

    private func renewalText(trial: String?) -> String {
        guard let price = purchases.displayPrice(plan) else { return "Prices load from the App Store." }
        let period = plan == .annual ? "year" : "month"
        if let trial {
            return "\(sentenceCase(trial)), then \(price) a \(period). Cancel anytime in Settings, at least 24 hours before renewal."
        }
        return "\(price) a \(period), renews automatically. Cancel anytime in Settings."
    }

    /// "7-day free trial" stays as is; only the first letter is raised.
    private func sentenceCase(_ text: String) -> String {
        guard let first = text.first else { return text }
        return first.uppercased() + text.dropFirst()
    }
}
