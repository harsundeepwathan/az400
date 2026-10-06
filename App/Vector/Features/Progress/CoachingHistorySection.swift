import SwiftUI
import VectorCore

/// Progress → Coaching: every weekly decision Vector made, what the user did
/// with it, and whether applied calorie changes worked. Pro; free users see
/// what it is, not fake locked content. Hairline rows on the plain ground.
struct CoachingHistorySection: View {
    @Environment(AppModel.self) private var model
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var showsAll = false

    private static let collapsedCount = 3

    var body: some View {
        let recent = Array(model.coachDecisions.reversed().prefix(12))
        let canExpand = model.isPro && recent.count > Self.collapsedCount
        VStack(alignment: .leading, spacing: 0) {
            RowHairline()
            VStack(alignment: .leading, spacing: Space.xs) {
                CanvasTitle("Coaching", actionTitle: canExpand ? (showsAll ? "Show less" : "See all") : nil) {
                    withAnimation(Motion.adaptive(Motion.smooth, reduceMotion: reduceMotion)) { showsAll.toggle() }
                }
                if !model.isPro {
                    FieldLockedRow(title: "Your digital coach",
                                   message: "Weekly decisions with the evidence behind them, a history of every adjustment, and whether each one worked.") {
                        model.presentPaywall(.coach)
                    }
                } else if recent.isEmpty {
                    Text("Your weekly check-in decisions will appear here, with the outcome of each calorie change about two weeks after you apply it.")
                        .font(VFont.secondary)
                        .foregroundStyle(VColor.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                } else {
                    let outcomes = Dictionary(model.decisionOutcomes.map { ($0.decision.id, $0) }, uniquingKeysWith: { a, _ in a })
                    let shown = showsAll ? recent : Array(recent.prefix(Self.collapsedCount))
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(Array(shown.enumerated()), id: \.element.id) { index, decision in
                            if index > 0 { RowHairline() }
                            DecisionRow(decision: decision, outcome: outcomes[decision.id])
                        }
                    }
                }
                if !model.discomfortNotes.isEmpty {
                    DiscomfortNotesList()
                        .padding(.top, Space.lg)
                }
            }
            .padding(.horizontal, Space.fieldInset)
            .padding(.vertical, Space.xl)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct DecisionRow: View {
    var decision: CoachDecision
    var outcome: DecisionOutcome?
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title)
                .font(VFont.body)
                .foregroundStyle(VColor.textPrimary)
                .fixedSize(horizontal: false, vertical: true)
            Text(detail)
                .font(VFont.secondary)
                .foregroundStyle(VColor.textSecondary)
                .lineLimit(4)
                .fixedSize(horizontal: false, vertical: true)
            if let outcome {
                Text(outcome.verdict == .measuring ? outcome.summary : "Outcome: \(outcome.summary)")
                    .font(VFont.secondary)
                    .foregroundStyle(VColor.textPrimary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.vertical, Space.sm)
        .frame(maxWidth: .infinity, minHeight: Size.minTouch, alignment: .leading)
        .accessibilityElement(children: .combine)
    }

    /// "28 Sep · reason".
    private var detail: String {
        let date = Format.shortDate(decision.date, calendar: model.calendar)
        return decision.reason.isEmpty ? date : "\(date) · \(decision.reason)"
    }

    private var title: String {
        switch (decision.kind, decision.status) {
        case (.calorieAdjustment, .applied):
            "Calories \(Format.integer(decision.previousCalories)) → \(Format.integer(decision.newCalories)) kcal"
        case (.calorieAdjustment, .rejected):
            "Calorie change suggested, kept \(Format.integer(decision.previousCalories)) kcal"
        case (.improveAdherence, _): "Focus on consistency"
        case (.noChange, _): "On track, no change"
        }
    }
}
