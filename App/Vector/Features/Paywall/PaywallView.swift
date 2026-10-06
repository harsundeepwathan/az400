import StoreKit
import SwiftUI
import VectorCore

/// Premium paywall. Honest by construction: prices come from the App
/// Store, savings are computed from real prices, the trial only shows if
/// StoreKit says the user is eligible, and there are no countdowns.
struct PaywallView: View {
    var trigger: PaywallTrigger
    @Environment(AppModel.self) private var model
    @Environment(PurchaseService.self) private var purchases
    @Environment(\.dismiss) private var dismiss
    @State private var plan: PurchaseService.Plan = .annual

    private let benefits: [(String, String, String)] = [
        ("arrow.triangle.2.circlepath", "Weekly Coach Check-In", "One clear decision each week, or a clear \"no change\""),
        ("flame", "Adaptive calorie targets", "Adjusted to how your weight actually responds, only when you're consistent"),
        ("chart.line.uptrend.xyaxis", "Progression for every lift", "The exact weight and reps for every exercise, explained"),
        ("clock.arrow.circlepath", "Coaching history and outcomes", "Every adjustment, and whether it worked"),
        (Icon.scan, "More meal scans", "Up to 30 a day: photo to logged meal in seconds"),
        ("chart.bar.xaxis", "Advanced trends", "Strength curves, muscle balance, full history")
    ]

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: Space.lg) {
                    header
                    VStack(alignment: .leading, spacing: Space.md) {
                        ForEach(benefits, id: \.1) { benefit in
                            let (symbol, title, detail) = benefit
                            HStack(alignment: .top, spacing: Space.md) {
                                IconBadge(symbol: symbol, size: 34)
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(title).font(VFont.bodyEmphasized).foregroundStyle(VColor.textPrimary)
                                    Text(detail).font(VFont.secondary).foregroundStyle(VColor.textSecondary)
                                }
                            }
                            .accessibilityElement(children: .combine)
                        }
                    }
                    plans
                    footnote
                }
                .padding(.horizontal, Space.gutter)
                .padding(.bottom, 160)
            }
            .screenBackground()
            .safeAreaInset(edge: .bottom) { purchaseBar }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button {
                        dismiss()
                    } label: {
                        Image(systemName: "xmark")
                            .font(.system(.body, weight: .semibold))
                            .foregroundStyle(VColor.textSecondary)
                    }
                    .accessibilityLabel("Close")
                }
                ToolbarItem(placement: .primaryAction) {
                    Button("Restore") { Task { await purchases.restore() } }
                        .font(VFont.secondary)
                }
            }
            .task { await purchases.load() }
            .onChange(of: purchases.isPro) { _, isPro in if isPro { dismiss() } }
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: Space.sm) {
            HStack(spacing: Space.xs) {
                Text("Vector").font(VFont.headline).foregroundStyle(VColor.accentText)
                ProBadge()
            }
            .padding(.top, Space.md)
            Text("UNLOCK YOUR\nDIGITAL COACH.")
                .font(.system(.largeTitle, weight: .heavy))
                .foregroundStyle(VColor.textPrimary)
                .fixedSize(horizontal: false, vertical: true)
            Text(contextLine)
                .font(VFont.body)
                .foregroundStyle(VColor.textSecondary)
        }
    }

    /// The subheading speaks to why the paywall was opened.
    private var contextLine: String {
        switch trigger {
        case .progressionMoment:
            "You have \(model.progressionOpportunities.count) progression opportunities waiting. Pro shows you every one, every session."
        case .mealScanQuota:
            "You've used this week's free scans. Pro makes meal logging a photo, every time."
        case .analytics, .history:
            "See your full history, strength curves and muscle balance."
        case .coach:
            "Your fitness coach, built around your data. Train, eat, log, and Vector works out what to change next."
        default:
            "Your fitness coach, built around your data."
        }
    }

    private var plans: some View {
        VStack(spacing: Space.sm) {
            planCard(.annual,
                     title: "Annual",
                     price: purchases.displayPrice(.annual).map { "\($0) / year" } ?? "Loading price…",
                     detail: purchases.annualMonthlyEquivalent().map { "\($0) / month, billed yearly" },
                     badge: purchases.annualSavingsPercent().map { "Save \($0)%" } ?? "Best value")
            planCard(.monthly,
                     title: "Monthly",
                     price: purchases.displayPrice(.monthly).map { "\($0) / month" } ?? "Loading price…",
                     detail: "Cancel anytime",
                     badge: nil)
            if case .failed(let message) = purchases.state {
                Text(message).font(VFont.caption).foregroundStyle(VColor.danger)
            }
        }
    }

    private func planCard(_ option: PurchaseService.Plan, title: String, price: String, detail: String?, badge: String?) -> some View {
        let selected = plan == option
        return Button {
            withAnimation(Motion.snappy) { plan = option }
        } label: {
            HStack(spacing: Space.md) {
                Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                    .font(.title2)
                    .foregroundStyle(selected ? VColor.accentText : VColor.separator)
                VStack(alignment: .leading, spacing: 2) {
                    HStack {
                        Text(title).font(VFont.headline).foregroundStyle(VColor.textPrimary)
                        if let badge {
                            Text(badge)
                                .font(VFont.captionEmphasized)
                                .foregroundStyle(VColor.textOnAccent)
                                .padding(.horizontal, 8)
                                .padding(.vertical, 3)
                                .background(VColor.accent, in: Capsule())
                        }
                    }
                    Text(price).font(VFont.secondaryEmphasized).foregroundStyle(VColor.textPrimary)
                    if let detail { Text(detail).font(VFont.caption).foregroundStyle(VColor.textSecondary) }
                }
                Spacer()
            }
            .padding(Space.md)
            .background(VColor.surface, in: RoundedRectangle(cornerRadius: Radius.md, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: Radius.md, style: .continuous)
                    .strokeBorder(selected ? VColor.accentText : VColor.separator, lineWidth: selected ? 2 : 1)
            }
        }
        .buttonStyle(.pressable)
        .accessibilityAddTraits(selected ? .isSelected : [])
        .sensoryFeedback(.selection, trigger: selected)
    }

    private var purchaseBar: some View {
        let trial = plan == .annual ? purchases.trialDescription() : nil
        return VStack(spacing: Space.xs) {
            Button {
                Task { if await purchases.purchase(plan) { model.setTier(.pro) } }
            } label: {
                if purchases.state == .purchasing {
                    ProgressView().tint(VColor.textOnAccent)
                } else {
                    Text(trial.map { "Start \($0)" } ?? "Continue")
                }
            }
            .buttonStyle(.primary)
            .disabled(purchases.displayPrice(plan) == nil || purchases.state == .purchasing)
            Text(renewalText(trial: trial))
                .font(VFont.caption)
                .foregroundStyle(VColor.textSecondary)
                .multilineTextAlignment(.center)
        }
        .padding(.horizontal, Space.gutter)
        .padding(.vertical, Space.sm)
        .background(.bar)
    }

    private func renewalText(trial: String?) -> String {
        let price = purchases.displayPrice(plan) ?? ""
        let period = plan == .annual ? "year" : "month"
        if let trial {
            return "\(trial.capitalized), then \(price)/\(period). Cancel anytime in Settings, at least 24 hours before renewal."
        }
        return "\(price)/\(period), renews automatically. Cancel anytime in Settings."
    }

    private var footnote: some View {
        VStack(alignment: .leading, spacing: Space.xs) {
            Text("Always free").font(VFont.captionEmphasized).foregroundStyle(VColor.textSecondary)
            Text("Unlimited workout logging, templates, exercise history, calorie tracking and \(EntitlementPolicy.freeMealScansPerWeek) AI meal scans a week.")
                .font(VFont.caption)
                .foregroundStyle(VColor.textSecondary)
            HStack(spacing: Space.md) {
                Link("Terms", destination: AppConfig.termsURL)
                Link("Privacy", destination: AppConfig.privacyURL)
            }
            .font(VFont.caption)
        }
    }
}
