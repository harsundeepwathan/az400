import SwiftUI
import VectorCore

/// Today's coach statement. Sits on the plain ground between fields (no
/// card), so the decision stands apart from the trackers: one focus (or
/// "Everything is on track"), plain accountability facts, and the evidence
/// one tap away. Never a list of advice.
struct VectorCoachCard: View {
    var coaching: TodayCoaching
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(alignment: .leading, spacing: Space.xs) {
            Text(headline)
                .font(VFont.statement)
                .foregroundStyle(VColor.textPrimary)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityAddTraits(.isHeader)
            if let detail = coaching.detail {
                Text(detail)
                    .font(VFont.secondary)
                    .foregroundStyle(VColor.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if case .learningBaseline(let items) = coaching.focus {
                BaselineChecklist(items: items)
                    .padding(.top, Space.xxs)
            }
            if !coaching.accountability.isEmpty {
                VStack(alignment: .leading, spacing: Space.xxs) {
                    ForEach(coaching.accountability, id: \.self) { line in
                        Text(line)
                            .font(VFont.secondary)
                            .foregroundStyle(VColor.textPrimary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .padding(.top, Space.xxs)
            }
            ViewThatFits(in: .horizontal) {
                HStack(spacing: Space.xs) {
                    byline
                    Spacer(minLength: Space.sm)
                    action
                }
                VStack(alignment: .leading, spacing: 0) {
                    byline.frame(minHeight: Size.minTouch)
                    action
                }
            }
            .padding(.top, Space.xxs)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Coach")
    }

    private var byline: some View {
        Label("Coach", systemImage: Icon.recommendation)
            .font(VFont.secondary)
            .foregroundStyle(VColor.textSecondary)
            .accessibilityHidden(true)
    }

    /// The headline, with the progression target ("82.5 kg × 8") in the accent.
    private var headline: AttributedString {
        var text = AttributedString(coaching.headline)
        if case .progression(let rec) = coaching.focus, let weight = rec.weight {
            let target = "\(Format.weight(weight, unit: model.unit)) × \(rec.reps)"
            if let range = text.range(of: target) {
                text[range].foregroundColor = VColor.accentText
            }
        }
        return text
    }

    @ViewBuilder private var action: some View {
        switch coaching.focus {
        case .progression(let rec):
            CoachLink(title: "See the evidence") { model.sheet = .exercise(rec.exerciseID) }
        case .learningBaseline(let items) where items.contains(where: { $0.label == "weigh-ins" && !$0.isComplete }):
            CoachLink(title: "Log weight") { model.sheet = .bodyWeight }
        default:
            EmptyView()
        }
    }
}

/// Accent text link with a chevron and a 44 pt target.
private struct CoachLink: View {
    var title: String
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: Space.xxs) {
                Text(title)
                Image(systemName: Icon.chevron)
                    .font(.caption.weight(.semibold))
                    .accessibilityHidden(true)
            }
            .frame(minHeight: Size.minTouch)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .font(VFont.secondaryEmphasized)
        .foregroundStyle(VColor.accentText)
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


// MARK: - Weekly check-in sheet

extension View {
    /// Presents this week's check-in as a large sheet. The review is captured
    /// when the sheet opens, so acting on it (which records a decision and
    /// refreshes the model) can't swap the content out mid-dismissal.
    func weeklyCheckInSheet(isPresented: Binding<Bool>) -> some View {
        modifier(WeeklyCheckInPresenter(isPresented: isPresented))
    }
}

private struct WeeklyCheckInPresenter: ViewModifier {
    @Binding var isPresented: Bool
    @Environment(AppModel.self) private var model
    @State private var captured: WeeklyReview?

    func body(content: Content) -> some View {
        content
            .onChange(of: isPresented) { _, shows in
                if shows { captured = model.weeklyReview }
            }
            .sheet(isPresented: $isPresented, onDismiss: { captured = nil }) {
                if let review = captured ?? model.weeklyReview {
                    WeeklyCheckInSheet(review: review)
                }
            }
    }
}

/// The Weekly Coach Check-In ("Fields"): the decision on the dark hero
/// field with its reason and confidence, the evidence one tap away, then the
/// week in three area fields. Actions are pinned to the bottom.
///
/// Free users see their week in numbers and an honest description of what
/// Pro adds. The decision itself is never shown blurred or locked.
struct WeeklyCheckInSheet: View {
    var review: WeeklyReview
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var showsEvidence: Bool
    @State private var tracked = false
    @State private var showsPaywall = false
    @State private var applied = false

    init(review: WeeklyReview) {
        self.review = review
        // Expanded when there's a change to justify; collapsed otherwise.
        if case .adjustCalories = review.recommendation {
            _showsEvidence = State(initialValue: true)
        } else {
            _showsEvidence = State(initialValue: false)
        }
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    if model.isPro {
                        hero
                        evidence
                    }
                    yourWeek
                    if !model.isPro {
                        proOffer
                    }
                }
                .padding(.bottom, Space.lg)
            }
            .screenBackground()
            .safeAreaInset(edge: .bottom, spacing: 0) { actions }
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .principal) {
                    SheetTitle(title: "Weekly check-in", subtitle: weekLabel)
                }
                ToolbarItem(placement: .topBarTrailing) {
                    SheetCloseButton { dismiss() }
                }
            }
            .sheet(isPresented: $showsPaywall) {
                PaywallView(trigger: .coach)
            }
        }
        .presentationDetents([.large])
        .presentationDragIndicator(.visible)
        .sensoryFeedback(.success, trigger: applied)
        .onAppear {
            guard !tracked else { return }
            tracked = true
            if case .adjustCalories = review.recommendation {
                model.track(.recommendationGenerated, ["kind": "calorie_adjustment", "pro": .bool(model.isPro)])
            }
            model.trackReviewViewed(review)
        }
    }

    /// "Week of 28 Sep": the start of the reviewed week.
    private var weekLabel: String {
        let start = model.calendar.dateInterval(of: .weekOfYear, for: review.date)?.start ?? review.date
        return "Week of \(start.formatted(.dateTime.day().month(.abbreviated)))"
    }

    // MARK: Hero (Pro)

    @ViewBuilder private var hero: some View {
        HeroField(spacing: Space.sm) {
            switch review.recommendation {
            case .adjustCalories(let from, let to, let reason):
                HeroLabel("Calories", symbol: Icon.recommendation)
                VStack(alignment: .leading, spacing: 2) {
                    HStack(alignment: .firstTextBaseline, spacing: Space.xs) {
                        Text(Format.integer(from))
                        Image(systemName: "arrow.right")
                            .font(.system(.title2, weight: .semibold))
                            .foregroundStyle(VColor.heroTextSecondary)
                        Text(Format.integer(to))
                    }
                    .font(VFont.metricHero)
                    .foregroundStyle(VColor.heroText)
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
                    Text("kcal a day")
                        .font(VFont.body)
                        .foregroundStyle(VColor.heroTextSecondary)
                }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("Change calories from \(Format.integer(from)) to \(Format.integer(to)) kilocalories a day")
                reasonText(reason)
            case .onTrack(let reason):
                statement("On track", symbol: "checkmark.circle", title: "No changes this week.", reason: reason)
            case .watch(let reason):
                statement("Watching", symbol: "eye", title: "Hold steady for one more week.", reason: reason)
            case .improveAdherence(let reason):
                statement("Consistency", symbol: "calendar", title: "Focus on consistency first.", reason: reason)
            case .learningBaseline(let items):
                HeroLabel("Learning your baseline", symbol: "hourglass")
                heroTitle("No changes yet.")
                reasonText("Vector needs a little more of your data before it changes anything.")
                HeroBaselineChecklist(items: items)
                    .padding(.top, Space.xxs)
            }
            if let outcome = review.previousOutcome {
                Text(outcome.summary)
                    .font(VFont.secondary)
                    .foregroundStyle(VColor.heroTextSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HeroHairline()
                .padding(.top, Space.xs)
            Label {
                Text(confidenceLine)
            } icon: {
                Image(systemName: "checkmark.seal")
            }
            .font(VFont.secondary.monospacedDigit())
            .foregroundStyle(VColor.heroTextSecondary)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.top, Space.xxs)
        }
    }

    @ViewBuilder
    private func statement(_ label: String, symbol: String, title: String, reason: String) -> some View {
        HeroLabel(label, symbol: symbol)
        heroTitle(title)
        reasonText(reason)
    }

    private func heroTitle(_ text: String) -> some View {
        Text(text)
            .font(VFont.largeTitle)
            .foregroundStyle(VColor.heroText)
            .fixedSize(horizontal: false, vertical: true)
            .accessibilityAddTraits(.isHeader)
    }

    private func reasonText(_ text: String) -> some View {
        Text(text)
            .font(VFont.body)
            .foregroundStyle(VColor.heroText)
            .fixedSize(horizontal: false, vertical: true)
    }

    /// "High confidence · 19 weigh-ins over 20 days, 6 of 7 days on calories".
    private var confidenceLine: String {
        var basis: [String] = []
        if let trend = review.body.trend {
            basis.append("\(trend.weighIns) weigh-ins over \(Int(trend.spanDays.rounded())) days")
        }
        let nutrition = review.nutrition
        basis.append("\(nutrition.calorieDaysOnTarget) of \(nutrition.windowDays) days on calories")
        return "\(review.confidence.title) · \(basis.joined(separator: ", "))"
    }

    // MARK: Evidence (Pro)

    @ViewBuilder private var evidence: some View {
        if case .learningBaseline = review.recommendation {
            EmptyView()
        } else {
            VStack(alignment: .leading, spacing: 0) {
                DisclosureGroup(isExpanded: $showsEvidence) {
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(Array(review.evidence.enumerated()), id: \.offset) { _, item in
                            EvidenceRow(label: item.label, value: item.value)
                        }
                        Text("Expenditure is estimated from your logged food and weight trend. Calorie changes are limited to 100–250 kcal and never go below 1,200 kcal.")
                            .font(VFont.caption)
                            .foregroundStyle(VColor.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                            .padding(.top, Space.sm)
                    }
                } label: {
                    Text("Evidence")
                }
                .disclosureGroupStyle(FieldDisclosureStyle())
            }
            .padding(.horizontal, Space.fieldInset)
            .padding(.vertical, Space.md)
            Hairline()
        }
    }

    // MARK: Your week

    private var yourWeek: some View {
        let unit = model.unit
        let training = review.training
        let nutrition = review.nutrition

        return VStack(alignment: .leading, spacing: 0) {
            Text("Your week")
                .font(VFont.title)
                .foregroundStyle(VColor.textPrimary)
                .accessibilityAddTraits(.isHeader)
                .padding(.horizontal, Space.fieldInset)
                .padding(.top, Space.lg)
                .padding(.bottom, Space.md)

            FieldSection(.training, symbol: Icon.train, title: "Training", spacing: Space.xxs) {
                weekValue("\(training.completed) of \(training.planned) workouts")
                let detail = [training.volumeChange.map { "Volume \(Format.signedPercent($0))" },
                              strengthLine(training, unit: unit)].compactMap { $0 }.joined(separator: " · ")
                if !detail.isEmpty { weekDetail(detail) }
            }

            FieldSection(.nutrition, symbol: Icon.nutrition, title: "Nutrition", spacing: Space.xxs) {
                weekValue("\(nutrition.calorieDaysOnTarget) of \(nutrition.windowDays) days on calories")
                weekDetail("Protein target hit on \(nutrition.proteinDaysOnTarget) of \(nutrition.windowDays) days")
            }

            FieldSection(.body, symbol: "scalemass", title: "Body", spacing: Space.xxs) {
                bodyContent(unit: unit)
            }
        }
    }

    private func weekValue(_ text: String) -> some View {
        Text(text)
            .font(VFont.title.monospacedDigit())
            .foregroundStyle(VColor.textPrimary)
            .fixedSize(horizontal: false, vertical: true)
    }

    private func weekDetail(_ text: String) -> some View {
        Text(text)
            .font(VFont.secondary.monospacedDigit())
            .foregroundStyle(VColor.textSecondary)
            .fixedSize(horizontal: false, vertical: true)
    }

    @ViewBuilder private func bodyContent(unit: WeightUnit) -> some View {
        let now = model.now()
        let points = model.analytics.bodyWeightSeries(model.bodyWeights, range: .month, now: now)

        HStack(alignment: .bottom, spacing: Space.md) {
            VStack(alignment: .leading, spacing: Space.xxs) {
                weekValue(weightLine(unit: unit))
                Group {
                    if let trend = review.body.trend {
                        Text(signed(trend.kgPerWeek, unit: unit))
                            .font(VFont.secondaryEmphasized.monospacedDigit())
                            .foregroundStyle(VColor.inkBody)
                        + Text(" a week over \(Int(trend.spanDays.rounded())) days")
                            .font(VFont.secondary)
                            .foregroundStyle(VColor.textSecondary)
                    } else {
                        Text("Log 3+ weigh-ins a week for a trend")
                            .font(VFont.secondary)
                            .foregroundStyle(VColor.textSecondary)
                    }
                }
                .fixedSize(horizontal: false, vertical: true)
            }
            .accessibilityElement(children: .combine)
            Spacer(minLength: Space.md)
            if review.body.trend != nil, points.count >= 2 {
                TrendSparkline(points: points, trend: model.analytics.smoothedTrend(points), tint: VColor.inkBody)
                    .frame(maxWidth: 150)
                    .frame(height: 44)
            }
        }
        weekDetail(goalLine(unit: unit))
            .padding(.top, Space.xxs)
    }

    private func strengthLine(_ training: WeeklyReview.Training, unit: WeightUnit) -> String? {
        guard let lift = training.mainLift else { return nil }
        guard let before = training.e1rmBefore, let now = training.e1rmNow else { return nil }
        return "\(lift) est. max \(Format.estimate(before, unit: unit, includeUnit: false)) → \(Format.estimate(now, unit: unit))"
    }

    private func weightLine(unit: WeightUnit) -> String {
        guard let current = review.body.currentWeekAverage else { return "No weigh-ins this week" }
        if let change = review.body.weeklyChange {
            return "\(Format.weight(current, unit: unit)) (\(change >= 0 ? "+" : "\u{2212}")\(Format.weight(abs(change), unit: unit, includeUnit: false)))"
        }
        return Format.weight(current, unit: unit)
    }

    private func signed(_ kgPerWeek: Double, unit: WeightUnit) -> String {
        "\(kgPerWeek >= 0 ? "+" : "\u{2212}")\(Format.weight(abs(kgPerWeek), unit: unit))"
    }

    private func goalLine(unit: WeightUnit) -> String {
        let goal = review.goal.title
        guard let band = review.bandKgPerWeek else { return "\(goal): the range appears once there's a weight trend" }
        let status = switch review.goalStatus {
        case .within: "On track"
        case .below: "Below range"
        case .above: "Above range"
        case .unknown: "Not enough data"
        }
        let range = "\(Format.weight(band.lowerBound, unit: unit, includeUnit: false)) to \(Format.weight(band.upperBound, unit: unit)) a week"
        return "\(goal) · \(status) · target \(range)"
    }

    // MARK: Pro offer (free)

    /// What Pro would add, stated plainly. No blurred or fake decision.
    private var proOffer: some View {
        VStack(alignment: .leading, spacing: Space.xs) {
            Text("Unlock your digital coach")
                .font(VFont.title3)
                .foregroundStyle(VColor.textPrimary)
                .accessibilityAddTraits(.isHeader)
            Text("Pro reads these numbers each week and makes one decision: change your calories, progress a lift, or change nothing. It shows the evidence and how confident it is.")
                .font(VFont.secondary)
                .foregroundStyle(VColor.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            Button("See Vector Pro") {
                model.track(.paywallViewed, ["trigger": .string(PaywallTrigger.coach.rawValue)])
                showsPaywall = true
            }
            .buttonStyle(.outlinedCapsule)
            .padding(.top, Space.xxs)
        }
        .padding(.horizontal, Space.fieldInset)
        .padding(.top, Space.lg)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: Actions

    private var actions: some View {
        PinnedActionBar {
            if model.isPro, case .adjustCalories = review.recommendation {
                Button("Apply adjustment") {
                    model.applyReview(review)
                    applied = true
                    dismiss()
                }
                .buttonStyle(.accentCapsule)
                Button("Keep current") {
                    model.keepCurrentTargets(review)
                    dismiss()
                }
                .buttonStyle(.textAction)
            } else if model.isPro, !isBaseline {
                // On track, watch or consistency: acknowledging records the decision.
                Button("Done") {
                    model.applyReview(review)
                    dismiss()
                }
                .buttonStyle(.accentCapsule)
            } else {
                Button("Done") {
                    model.keepCurrentTargets(review)
                    dismiss()
                }
                .buttonStyle(.accentCapsule)
            }
        }
    }

    private var isBaseline: Bool {
        if case .learningBaseline = review.recommendation { return true }
        return false
    }
}

/// The baseline checklist in white ink, for the hero field.
private struct HeroBaselineChecklist: View {
    var items: [BaselineItem]

    var body: some View {
        VStack(alignment: .leading, spacing: Space.xxs) {
            ForEach(items) { item in
                HStack(spacing: Space.xs) {
                    Image(systemName: item.isComplete ? "checkmark.circle.fill" : "circle")
                        .foregroundStyle(item.isComplete ? VColor.ringWorkouts : VColor.heroTextSecondary)
                        .accessibilityHidden(true)
                    Text("\(item.done) of \(item.needed) \(item.label)")
                        .font(VFont.secondary.monospacedDigit())
                        .foregroundStyle(VColor.heroText)
                }
                .accessibilityElement(children: .combine)
                .accessibilityValue(item.isComplete ? "Complete" : "Not yet")
            }
        }
    }
}
