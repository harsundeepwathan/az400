import SwiftUI
import VectorCore

/// Progress → Coaching: every weekly decision Vector made, what the user did
/// with it, and whether applied calorie changes worked. Pro; free users see
/// what it is, not fake locked content.
struct CoachingHistorySection: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(alignment: .leading, spacing: Space.sm) {
            SectionHeader("Coaching")
            if !model.isPro {
                LockedFeatureCard(feature: .aiCoach, headline: "Unlock your digital coach",
                                  message: "Weekly decisions with the evidence behind them, a history of every adjustment, and whether each one worked.") {
                    model.presentPaywall(.coach)
                }
            } else if model.coachDecisions.isEmpty {
                Text("Your weekly check-in decisions will appear here, with the outcome of each calorie change about two weeks after you apply it.")
                    .font(VFont.secondary)
                    .foregroundStyle(VColor.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .card()
            } else {
                VStack(alignment: .leading, spacing: Space.sm) {
                    let outcomes = Dictionary(model.decisionOutcomes.map { ($0.decision.id, $0) }, uniquingKeysWith: { a, _ in a })
                    let recent = Array(model.coachDecisions.reversed().prefix(12))
                    ForEach(Array(recent.enumerated()), id: \.element.id) { index, decision in
                        if index > 0 { Hairline() }
                        DecisionRow(decision: decision, outcome: outcomes[decision.id])
                    }
                }
                .card()
            }
            if !model.discomfortNotes.isEmpty {
                DiscomfortNotesList().card()
            }
        }
    }
}

private struct DecisionRow: View {
    var decision: CoachDecision
    var outcome: DecisionOutcome?
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(alignment: .firstTextBaseline) {
                Text(title).font(VFont.secondaryEmphasized).foregroundStyle(VColor.textPrimary)
                Spacer()
                Text(decision.date.formatted(date: .abbreviated, time: .omitted))
                    .font(VFont.caption).foregroundStyle(VColor.textSecondary)
            }
            if !decision.reason.isEmpty {
                Text(decision.reason)
                    .font(VFont.caption)
                    .foregroundStyle(VColor.textSecondary)
                    .lineLimit(3)
            }
            if let outcome {
                Text(outcome.verdict == .measuring ? outcome.summary : "Outcome: \(outcome.summary)")
                    .font(VFont.caption)
                    .foregroundStyle(VColor.textPrimary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .accessibilityElement(children: .combine)
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
