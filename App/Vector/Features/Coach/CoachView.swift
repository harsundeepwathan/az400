import SwiftUI
import VectorCore

/// The coaching layer: every insight with its evidence. Free users read
/// the free insights in full and see Pro ones as locked teasers, which
/// proves there is something specific to them behind the upgrade.
struct CoachView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: Space.md) {
                    Text("Built from your workouts, nutrition and body weight. Tap “Why?” on any insight to see the data behind it.")
                        .font(VFont.secondary)
                        .foregroundStyle(VColor.textSecondary)

                    if model.canShowCoachSummary {
                        CoachSummaryCard()
                    }

                    if model.isComputingInsights && model.insights.isEmpty {
                        ForEach(0..<2, id: \.self) { _ in
                            InsightCard(insight: CoachInsight(id: "placeholder", category: .training, tone: .neutral,
                                                              title: "Loading insight", message: "Analysing your recent training and nutrition data.",
                                                              evidence: [], priority: 0, requiresPro: false))
                                .skeleton(true)
                        }
                    } else if model.visibleInsights.isEmpty {
                        EmptyStateView(symbol: Icon.recommendation, title: "Nothing to flag right now",
                                       message: "Keep logging workouts and meals. Insights appear as soon as there's a pattern worth acting on.")
                    }

                    ForEach(model.visibleInsights) { insight in
                        InsightCard(
                            insight: insight,
                            isLocked: insight.requiresPro && !model.isPro,
                            onAction: { action in
                                dismiss()
                                model.handle(action)
                            },
                            onUnlock: { model.presentPaywall(.coach) }
                        )
                        .contextMenu {
                            Button("Hide", systemImage: "eye.slash") { withAnimation { model.dismiss(insight) } }
                        }
                    }
                }
                .padding(Space.gutter)
            }
            .screenBackground()
            .navigationTitle("Coach")
            .navigationBarTitleDisplayMode(.large)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() }.foregroundStyle(VColor.accentText) } }
        }
    }
}

/// Progressive overload recommendations for the whole program. Free users
/// get the first recommendation in full (value first), then the Pro pitch.
struct RecommendationsView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var adjusting: ProgressionRecommendation?

    private var ordered: [ProgressionRecommendation] {
        model.recommendations.sorted { lhs, rhs in
            rank(lhs.action) < rank(rhs.action)
        }
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: Space.md) {
                    Text("Calculated from your last sessions: completed sets, rep ranges, estimated 1RM and volume trend. Accepted targets pre-fill your next workout.")
                        .font(VFont.secondary)
                        .foregroundStyle(VColor.textSecondary)

                    ForEach(Array(ordered.enumerated()), id: \.element.exerciseID) { index, rec in
                        if model.isPro || index == 0 {
                            VStack(alignment: .leading, spacing: Space.xs) {
                                Text(model.catalog[rec.exerciseID]?.name ?? rec.exerciseID)
                                    .font(VFont.headline)
                                    .foregroundStyle(VColor.textPrimary)
                                    .padding(.horizontal, Space.xxs)
                                AIRecommendationCard(
                                    recommendation: rec, unit: model.unit,
                                    isAccepted: model.target(for: rec.exerciseID) != nil,
                                    onAccept: rec.weight == nil ? nil : { model.accept(rec) },
                                    onModify: { adjusting = rec }
                                )
                            }
                        } else if index == 1 {
                            ProUpsell(remaining: ordered.count - 1)
                        }
                    }

                    if ordered.isEmpty {
                        EmptyStateView(symbol: "chart.line.uptrend.xyaxis", title: "Train to unlock recommendations",
                                       message: "Complete a workout and we'll recommend the next weight and reps for every exercise.")
                    }
                }
                .padding(Space.gutter)
            }
            .screenBackground()
            .navigationTitle("Next session")
            .navigationBarTitleDisplayMode(.large)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
            .sheet(item: $adjusting) { rec in
                AdjustTargetView(recommendation: rec)
                    .presentationDetents([.height(360)])
            }
        }
    }

    private func rank(_ action: ProgressionRecommendation.Action) -> Int {
        switch action {
        case .increaseLoad: 0
        case .deload: 1
        case .increaseReps: 2
        case .reduceLoad: 3
        case .repeatLoad: 4
        case .establishBaseline: 5
        }
    }
}

private struct ProUpsell: View {
    var remaining: Int
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(alignment: .leading, spacing: Space.sm) {
            HStack {
                Text("\(remaining) more recommendations").font(VFont.headline).foregroundStyle(VColor.textPrimary)
                Spacer()
                ProBadge()
            }
            Text("Pro calculates the next weight and reps for every exercise in your program, with the reasoning shown, and pre-fills them when you start.")
                .font(VFont.secondary)
                .foregroundStyle(VColor.textSecondary)
            Button("Unlock all recommendations") { model.presentPaywall(.progressionMoment) }
                .buttonStyle(.accentCapsule)
        }
        .card()
    }
}

/// Modify a recommendation. The adjusted target pre-fills the next workout.
struct AdjustTargetView: View {
    var recommendation: ProgressionRecommendation
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var weight: Double = 0
    @State private var reps: Int = 8

    private var increment: Double {
        let step = model.catalog[recommendation.exerciseID]?.loadIncrement ?? 2.5
        return step > 0 ? step : 2.5
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: Space.lg) {
                stepper(title: model.unit.symbol, value: Format.weight(weight, unit: model.unit, includeUnit: false),
                        minus: { weight = max(weight - increment, 0) }, plus: { weight += increment })
                stepper(title: "reps", value: "\(reps)",
                        minus: { reps = max(reps - 1, 1) }, plus: { reps += 1 })
                Button("Use \(Format.weight(weight, unit: model.unit)) × \(reps)") {
                    model.setTarget(exerciseID: recommendation.exerciseID, weight: weight, reps: reps)
                    // Choosing a different target than recommended counts as declining it.
                    let matches = weight == recommendation.weight && reps == recommendation.reps
                    model.trackProgression(recommendation, accepted: matches)
                    dismiss()
                }
                .buttonStyle(.accentCapsule)
            }
            .padding(Space.gutter)
            .navigationTitle(model.catalog[recommendation.exerciseID]?.name ?? "Adjust")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } } }
            .onAppear {
                let current = model.target(for: recommendation.exerciseID)
                weight = current?.weight ?? recommendation.weight ?? 0
                reps = current?.reps ?? recommendation.reps
            }
        }
    }

    private func stepper(title: String, value: String, minus: @escaping () -> Void, plus: @escaping () -> Void) -> some View {
        HStack {
            Button(action: minus) { Image(systemName: "minus").frame(width: 56, height: 56) }
                .buttonStyle(QuietCapsuleButtonStyle())
                .frame(width: 64)
                .accessibilityLabel("Decrease \(title)")
            VStack(spacing: 0) {
                Text(value).font(VFont.metricHero).foregroundStyle(VColor.textPrimary).contentTransition(.numericText())
                Text(title).font(VFont.caption).foregroundStyle(VColor.textSecondary)
            }
            .frame(maxWidth: .infinity)
            Button(action: plus) { Image(systemName: "plus").frame(width: 56, height: 56) }
                .buttonStyle(QuietCapsuleButtonStyle())
                .frame(width: 64)
                .accessibilityLabel("Increase \(title)")
        }
        .sensoryFeedback(.selection, trigger: value)
    }
}
