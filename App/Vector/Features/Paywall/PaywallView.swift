import StoreKit
import SwiftUI
import VectorCore

/// Premium paywall ("Fields"). Honest by construction: prices come from the
/// App Store, savings are computed from real prices, the trial only shows if
/// StoreKit says the user is eligible, and there are no countdowns. The
/// example check-in on the hero field is labelled as an example.
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
                VStack(alignment: .leading, spacing: 0) {
                    hero
                    benefitList
                    alwaysFree
                    plans
                }
                .padding(.bottom, Space.lg)
            }
            .screenBackground()
            .safeAreaInset(edge: .bottom, spacing: 0) { purchaseBar }
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    SheetCloseButton { dismiss() }
                }
                ToolbarItem(placement: .primaryAction) {
                    Button("Restore") { Task { await purchases.restore() } }
                        .font(VFont.body)
                        .foregroundStyle(VColor.accentText)
                        .disabled(purchases.state == .purchasing)
                }
            }
            .task { await purchases.load() }
            .onChange(of: purchases.isPro) { _, isPro in if isPro { dismiss() } }
        }
    }

    // MARK: Hero

    private var hero: some View {
        HeroField(spacing: Space.sm) {
            Text("Unlock your digital coach")
                .font(VFont.largeTitle)
                .foregroundStyle(VColor.heroText)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityAddTraits(.isHeader)
            Text(contextLine)
                .font(VFont.body)
                .foregroundStyle(VColor.heroText)
                .fixedSize(horizontal: false, vertical: true)
            HeroHairline()
                .padding(.vertical, Space.xs)
            exampleCheckIn
        }
    }

    /// A static, clearly labelled example of what a check-in looks like.
    /// It is not the user's data.
    private var exampleCheckIn: some View {
        VStack(alignment: .leading, spacing: Space.xxs) {
            Text("Example check-in")
                .font(VFont.fieldCaption)
                .foregroundStyle(VColor.heroTextSecondary)
            Text("2,300 \u{2192} 2,550 kcal a day")
                .font(VFont.metric)
                .foregroundStyle(VColor.heroText)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
            Text("Weight trend \u{2212}0.17 kg a week for 20 days, below the build-muscle range. High confidence.")
                .font(VFont.secondary)
                .foregroundStyle(VColor.heroTextSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityElement(children: .combine)
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
        VStack(alignment: .leading, spacing: 0) {
            Text("What Pro adds")
                .font(VFont.title)
                .foregroundStyle(VColor.textPrimary)
                .accessibilityAddTraits(.isHeader)
                .padding(.bottom, Space.sm)
            ForEach(Array(benefits.enumerated()), id: \.element.id) { index, benefit in
                HStack(alignment: .center, spacing: Space.md) {
                    Image(systemName: benefit.symbol)
                        .font(.system(.title3, weight: .semibold))
                        .foregroundStyle(VColor.accentText)
                        .frame(width: 32)
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(benefit.title)
                            .font(VFont.body)
                            .foregroundStyle(VColor.textPrimary)
                        Text(benefit.detail)
                            .font(VFont.secondary)
                            .foregroundStyle(VColor.textSecondary)
                    }
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .padding(.vertical, Space.sm)
                .overlay(alignment: .bottom) {
                    if index < benefits.count - 1 { Hairline(leading: 32 + Space.md) }
                }
                .accessibilityElement(children: .combine)
            }
        }
        .padding(.horizontal, Space.fieldInset)
        .padding(.top, Space.lg)
    }

    private var alwaysFree: some View {
        Text("Always free: unlimited workout logging, templates, exercise history, calorie tracking and \(EntitlementPolicy.freeMealScansPerWeek) AI meal scans a week.")
            .font(VFont.secondary)
            .foregroundStyle(VColor.textSecondary)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, Space.fieldInset)
            .padding(.top, Space.md)
            .padding(.bottom, Space.lg)
    }

    // MARK: Plans

    /// A full-bleed band with two selectable rows (checkmark on the chosen one).
    private var plans: some View {
        VStack(alignment: .leading, spacing: 0) {
            planRow(.annual, title: "Annual", price: annualLine)
            Hairline()
            planRow(.monthly, title: "Monthly",
                    price: purchases.displayPrice(.monthly).map { "\($0) a month" } ?? "Loading price\u{2026}")
            if case .failed(let message) = purchases.state {
                Label(message, systemImage: "exclamationmark.triangle")
                    .font(VFont.caption)
                    .foregroundStyle(VColor.danger)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, Space.sm)
            }
        }
        .padding(.horizontal, Space.fieldInset)
        .padding(.vertical, Space.sm)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(VColor.surface)
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

    private func planRow(_ option: PurchaseService.Plan, title: String, price: String) -> some View {
        let selected = plan == option
        return Button {
            plan = option
        } label: {
            HStack(spacing: Space.md) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(VFont.headline)
                        .foregroundStyle(VColor.textPrimary)
                    Text(price)
                        .font(VFont.secondary.monospacedDigit())
                        .foregroundStyle(VColor.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: Space.sm)
                Image(systemName: "checkmark")
                    .font(.system(.body, weight: .semibold))
                    .foregroundStyle(VColor.accentText)
                    .opacity(selected ? 1 : 0)
                    .accessibilityHidden(true)
            }
            .padding(.vertical, Space.sm)
            .frame(minHeight: Size.minTouch)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(selected ? .isSelected : [])
        .sensoryFeedback(.selection, trigger: selected)
    }

    // MARK: Purchase

    private var purchaseBar: some View {
        let trial = plan == .annual ? purchases.trialDescription() : nil
        return PinnedActionBar(spacing: Space.xs) {
            Button {
                Task { if await purchases.purchase(plan) { model.setTier(.pro) } }
            } label: {
                if purchases.state == .purchasing {
                    ProgressView().tint(VColor.textOnAccent)
                        .accessibilityLabel("Purchasing")
                } else {
                    Text(trial.map { "Start \($0)" } ?? "Subscribe")
                }
            }
            .buttonStyle(.accentCapsule)
            .disabled(purchases.displayPrice(plan) == nil || purchases.state == .purchasing)
            Text(renewalText(trial: trial))
                .font(VFont.caption)
                .foregroundStyle(VColor.textSecondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: Space.xs) {
                Link("Terms", destination: AppConfig.termsURL)
                Text("\u{00B7}").foregroundStyle(VColor.textTertiary).accessibilityHidden(true)
                Link("Privacy", destination: AppConfig.privacyURL)
            }
            .font(VFont.caption)
            .tint(VColor.accentText)
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
