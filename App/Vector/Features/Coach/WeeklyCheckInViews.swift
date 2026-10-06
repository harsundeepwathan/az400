import SwiftUI
import VectorCore

/// Today's Vector Coach card: one focus (or "Everything is on track"), plus
/// plain accountability facts. Never a list of advice.
struct VectorCoachCard: View {
    var coaching: TodayCoaching
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(alignment: .leading, spacing: Space.sm) {
            CategoryHeader(symbol: Icon.recommendation, title: "Coach", tint: VColor.coach,
                           detail: coaching.focus == .checkInReady ? "Check-in ready" : "Today")
            Text(coaching.headline)
                .font(VFont.title.weight(.bold))
                .foregroundStyle(VColor.textPrimary)
                .fixedSize(horizontal: false, vertical: true)
            if let detail = coaching.detail {
                Text(detail)
                    .font(VFont.secondary)
                    .foregroundStyle(VColor.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if case .learningBaseline(let items) = coaching.focus {
                BaselineChecklist(items: items)
            }
            if !coaching.accountability.isEmpty {
                Hairline()
                ForEach(coaching.accountability, id: \.self) { line in
                    Text(line)
                        .font(VFont.secondary)
                        .foregroundStyle(VColor.textPrimary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            action
        }
        .card()
        .accessibilityElement(children: .contain)
    }

    @ViewBuilder private var action: some View {
        switch coaching.focus {
        case .progression(let rec):
            Button("Why?") { model.sheet = .exercise(rec.exerciseID) }
                .buttonStyle(.secondary(compact: true))
        case .learningBaseline(let items) where items.contains(where: { $0.label == "weigh-ins" && !$0.isComplete }):
            Button("Log Weight") { model.sheet = .bodyWeight }
                .buttonStyle(.secondary(compact: true))
        default:
            EmptyView()
        }
    }
}

private struct BaselineChecklist: View {
    var items: [BaselineItem]

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(items) { item in
                HStack(spacing: Space.xs) {
                    Image(systemName: item.isComplete ? "checkmark.circle.fill" : "circle")
                        .foregroundStyle(item.isComplete ? VColor.success : VColor.textTertiary)
                    Text("\(item.done) of \(item.needed) \(item.label)")
                        .font(VFont.secondary.monospacedDigit())
                        .foregroundStyle(VColor.textPrimary)
                }
                .accessibilityElement(children: .combine)
            }
        }
    }
}

/// The Weekly Coach Check-In: training, nutrition, body weight, goal, then
/// one decision. Free users see their week in numbers; the decision and
/// Apply are Pro.
struct WeeklyCheckInCard: View {
    var review: WeeklyReview
    @Environment(AppModel.self) private var model
    @State private var showsEvidence = false
    @State private var tracked = false

    var body: some View {
        VStack(alignment: .leading, spacing: Space.md) {
            CategoryHeader(symbol: "arrow.triangle.2.circlepath", title: "Weekly Check-In", tint: VColor.coach,
                           detail: review.confidence.title)
            sections
            Hairline()
            if model.isPro {
                decision
            } else {
                locked
            }
        }
        .card()
        .onAppear {
            guard !tracked else { return }
            tracked = true
            if case .adjustCalories = review.recommendation {
                model.track(.recommendationGenerated, ["kind": "calorie_adjustment", "pro": .bool(model.isPro)])
            }
            model.trackReviewViewed(review)
        }
    }

    // MARK: Week in numbers (free)

    private var sections: some View {
        let unit = model.unit
        let training = review.training
        let nutrition = review.nutrition
        return VStack(alignment: .leading, spacing: Space.md) {
            row(Icon.train, VColor.training, "Training", "\(training.completed) of \(training.planned) workouts",
                detail: [training.volumeChange.map { "Volume \(Format.signedPercent($0))" },
                         strengthLine(training, unit: unit)].compactMap { $0 }.joined(separator: " · "))
            row(Icon.nutrition, VColor.nutrition, "Nutrition", "\(nutrition.calorieDaysOnTarget) of \(nutrition.windowDays) days on calories",
                detail: "Protein target hit on \(nutrition.proteinDaysOnTarget) of \(nutrition.windowDays) days")
            row("scalemass", VColor.body, "Body weight", weightLine(unit: unit), detail: review.body.trend.map { trendLine($0, unit: unit) } ?? "Log 3+ weigh-ins a week for a trend")
            row("flag", VColor.textSecondary, "Goal", review.goal.title, detail: goalLine(unit: unit))
        }
    }

    private func row(_ symbol: String, _ tint: Color, _ title: String, _ value: String, detail: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: Space.sm) {
            Image(systemName: symbol)
                .font(.body.weight(.semibold))
                .foregroundStyle(tint)
                .frame(width: 24)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: Space.xxs) {
                Text(title).font(VFont.secondary).foregroundStyle(VColor.textSecondary)
                Text(value).font(VFont.bodyEmphasized.monospacedDigit()).foregroundStyle(VColor.textPrimary)
                if !detail.isEmpty {
                    Text(detail).font(VFont.secondary.monospacedDigit()).foregroundStyle(VColor.textSecondary)
                }
            }
        }
        .accessibilityElement(children: .combine)
    }

    private func strengthLine(_ training: WeeklyReview.Training, unit: WeightUnit) -> String? {
        guard let lift = training.mainLift else { return nil }
        guard let before = training.e1rmBefore, let now = training.e1rmNow else { return nil }
        return "\(lift) estimated max \(Format.estimate(before, unit: unit, includeUnit: false)) → \(Format.estimate(now, unit: unit))"
    }

    private func weightLine(unit: WeightUnit) -> String {
        guard let current = review.body.currentWeekAverage else { return "No weigh-ins this week" }
        if let change = review.body.weeklyChange {
            return "\(Format.weight(current, unit: unit)) (\(change >= 0 ? "+" : "\u{2212}")\(Format.weight(abs(change), unit: unit, includeUnit: false)))"
        }
        return Format.weight(current, unit: unit)
    }

    private func trendLine(_ trend: WeightTrend, unit: WeightUnit) -> String {
        let sign = trend.kgPerWeek >= 0 ? "+" : "\u{2212}"
        return "Trend \(sign)\(Format.weight(abs(trend.kgPerWeek), unit: unit))/week over \(Int(trend.spanDays.rounded())) days"
    }

    private func goalLine(unit: WeightUnit) -> String {
        guard let band = review.bandKgPerWeek else { return "Range appears once there's a weight trend" }
        let status = switch review.goalStatus {
        case .within: "On track"
        case .below: "Below range"
        case .above: "Above range"
        case .unknown: "Not enough data"
        }
        let range = "\(Format.weight(band.lowerBound, unit: unit, includeUnit: false)) to \(Format.weight(band.upperBound, unit: unit))/week"
        return "\(status) · target \(range)"
    }

    // MARK: Decision (Pro)

    @ViewBuilder private var decision: some View {
        VStack(alignment: .leading, spacing: Space.sm) {
            switch review.recommendation {
            case .learningBaseline(let items):
                Text("Vector is learning your baseline. No changes yet.")
                    .font(VFont.bodyEmphasized).foregroundStyle(VColor.textPrimary)
                BaselineChecklist(items: items)
                Button("Done") { model.keepCurrentTargets(review) }.buttonStyle(.secondary)
            case .onTrack(let reason), .watch(let reason), .improveAdherence(let reason):
                Text(title).font(VFont.bodyEmphasized).foregroundStyle(VColor.textPrimary)
                explanation(reason)
                Button("Continue Current Plan") { model.applyReview(review) }.buttonStyle(.primary)
            case .adjustCalories(let from, let to, let reason):
                VStack(alignment: .leading, spacing: 2) {
                    Text("\(Format.integer(from)) → \(Format.integer(to))")
                        .font(VFont.metricHero).foregroundStyle(VColor.textPrimary)
                    Text("kcal a day").font(VFont.secondary).foregroundStyle(VColor.textSecondary)
                }
                .accessibilityElement(children: .combine)
                explanation(reason)
                AdaptiveStack {
                    Button("Keep Current") { model.keepCurrentTargets(review) }.buttonStyle(.secondary)
                    Button("Apply Adjustment") { model.applyReview(review) }.buttonStyle(.primary)
                }
            }
            if let outcome = review.previousOutcome {
                Text(outcome.summary)
                    .font(VFont.caption)
                    .foregroundStyle(VColor.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var title: String {
        switch review.recommendation {
        case .onTrack: "Everything is on track. No changes."
        case .watch: "Hold steady for one more week."
        case .improveAdherence: "Focus on consistency first."
        default: ""
        }
    }

    private func explanation(_ reason: String) -> some View {
        VStack(alignment: .leading, spacing: Space.xs) {
            Text(reason)
                .font(VFont.secondary)
                .foregroundStyle(VColor.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            DisclosureGroup("Evidence", isExpanded: $showsEvidence) {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(review.evidence, id: \.self) { LabeledContent($0.label, value: $0.value) }
                    Text("Expenditure is estimated from your logged food and weight trend. Calorie changes are limited to 100–250 kcal and never go below 1,200 kcal.")
                        .foregroundStyle(VColor.textTertiary)
                        .padding(.top, 2)
                }
                .font(VFont.caption.monospacedDigit())
                .padding(.top, Space.xs)
            }
            .font(VFont.secondaryEmphasized)
            .tint(VColor.textSecondary)
        }
    }

    // MARK: Locked (free)

    private var locked: some View {
        VStack(alignment: .leading, spacing: Space.sm) {
            HStack {
                Text("Unlock your digital coach").font(VFont.bodyEmphasized).foregroundStyle(VColor.textPrimary)
                Spacer()
                ProBadge()
            }
            Text("Pro reads this week's numbers and tells you what to change: calories, progression, or nothing at all.")
                .font(VFont.secondary)
                .foregroundStyle(VColor.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            AdaptiveStack {
                Button("Done") { model.keepCurrentTargets(review) }.buttonStyle(.secondary)
                Button("See Pro") { model.sheet = .paywall(.coach) }.buttonStyle(.primary)
            }
        }
    }
}
