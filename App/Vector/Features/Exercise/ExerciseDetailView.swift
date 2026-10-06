import Charts
import SwiftUI
import VectorCore

/// Push value for an exercise. Hosts that push it (Train, the exercise
/// sheet) register `navigationDestination(for: ExerciseRoute.self)`.
struct ExerciseRoute: Hashable {
    var id: String
}

/// Exercise sheet (from anywhere in the app, or from an active workout):
/// a navigation stack around `ExerciseDetailScreen` with a Done button.
struct ExerciseDetailView: View {
    var exercise: Exercise
    /// Set when opened from an active workout; enables in-place replacement.
    var workoutIndex: Int?
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ExerciseDetailScreen(exercise: exercise, workoutIndex: workoutIndex, onReplaced: { dismiss() })
                .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
                .navigationDestination(for: ExerciseRoute.self) { route in
                    if let other = model.catalog[route.id] {
                        ExerciseDetailScreen(exercise: other)
                    }
                }
        }
    }
}

/// Exercise detail ("Fields"). A training field holds the title, one
/// metadata line, the estimated max (labelled as an estimate) with its
/// chart, and the next-session recommendation with a "Why" disclosure.
/// Then, on the open canvas: recent sessions, records, how to (demo and
/// numbered steps) and alternatives, with "Avoid (preference or
/// discomfort)" kept below them.
struct ExerciseDetailScreen: View {
    var exercise: Exercise
    /// Set when opened from an active workout; alternatives replace in place.
    var workoutIndex: Int?
    /// Called after an in-workout replacement so the sheet can close.
    var onReplaced: () -> Void = {}
    @Environment(AppModel.self) private var model
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var showsWhy = false
    @State private var showsReplace = false
    @State private var showsAllSessions = false
    @State private var adjusting: ProgressionRecommendation?

    private var history: [ExercisePerformance] { model.history(for: exercise.id) }
    private var isAvoided: Bool { model.profile?.avoidedExerciseIDs.contains(exercise.id) ?? false }

    var body: some View {
        let history = self.history
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                ExerciseHero(exercise: exercise, history: history, showsWhy: $showsWhy, adjusting: $adjusting)
                if !history.isEmpty {
                    recentSessions(history)
                    records(history)
                }
                howTo(showsTopRule: !history.isEmpty)
                alternatives
            }
            .padding(.bottom, Space.xl)
        }
        .screenBackground()
        .navigationTitle(exercise.name)
        .navigationBarTitleDisplayMode(.inline)
        .fieldTitleInBody()
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) { menu }
        }
        .navigationDestination(isPresented: $showsAllSessions) {
            ExerciseSessionsView(exercise: exercise)
        }
        .sheet(item: $adjusting) { rec in
            AdjustTargetView(recommendation: rec).presentationDetents([.height(360)])
        }
        .sheet(isPresented: $showsReplace) {
            ReplaceExerciseView(exercise: exercise, workoutIndex: workoutIndex, onReplaced: onReplaced)
        }
        .sensoryFeedback(.selection, trigger: showsWhy)
    }

    private var menu: some View {
        Menu {
            let isFavorite = model.isFavorite(exerciseID: exercise.id)
            Button(isFavorite ? "Remove from favourites" : "Add to favourites", systemImage: isFavorite ? "star.slash" : "star") {
                model.toggleFavorite(exerciseID: exercise.id)
            }
            Button(workoutIndex == nil ? "Find alternatives" : "Replace exercise", systemImage: Icon.swap) {
                showsReplace = true
            }
            Divider()
            Button(isAvoided ? "Allow in plans" : "Avoid (preference or discomfort)",
                   systemImage: isAvoided ? "checkmark.circle" : "hand.raised") {
                model.toggleAvoided(exercise.id)
            }
        } label: {
            CanvasMoreMenuLabel()
        }
        .accessibilityLabel("Exercise options")
    }

    // MARK: Recent sessions

    private func recentSessions(_ history: [ExercisePerformance]) -> some View {
        CanvasSection("Recent sessions", actionTitle: history.count > 3 || model.hasHiddenHistory ? "See all" : nil,
                      showsTopRule: false) {
            showsAllSessions = true
        } content: {
            VStack(spacing: 0) {
                ForEach(Array(history.prefix(3).enumerated()), id: \.element.sessionID) { index, performance in
                    ExerciseSessionRow(performance: performance)
                        .overlay(alignment: .top) { if index > 0 { Hairline() } }
                }
            }
        }
    }

    // MARK: Records

    @ViewBuilder
    private func records(_ history: [ExercisePerformance]) -> some View {
        let bestMax = history.map(\.estimatedOneRepMax).max() ?? 0
        let heaviest = history.compactMap(\.log.heaviestSet).max { lhs, rhs in
            lhs.weight == rhs.weight ? lhs.reps < rhs.reps : lhs.weight < rhs.weight
        }
        let mostVolume = history.map(\.volume).max() ?? 0
        let candidates: [(String, String)?] = [
            bestMax > 0 ? ("Best estimated max", Format.estimate(bestMax, unit: model.unit)) : nil,
            heaviest.map { set in
                set.weight > 0
                    ? ("Heaviest set", "\(Format.weight(set.weight, unit: model.unit)) × \(set.reps)")
                    : ("Best set", "\(set.reps) reps")
            },
            mostVolume > 0 ? ("Most volume in a session", Format.volume(mostVolume, unit: model.unit)) : nil
        ]
        let rows = candidates.compactMap { $0 }
        if !rows.isEmpty {
            CanvasSection("Records") {
                VStack(spacing: 0) {
                    ForEach(Array(rows.enumerated()), id: \.offset) { index, row in
                        CanvasRow(title: row.0, value: row.1)
                            .overlay(alignment: .top) { if index > 0 { Hairline() } }
                    }
                }
            }
        }
    }

    // MARK: How to

    private func howTo(showsTopRule: Bool) -> some View {
        CanvasSection("How to", showsTopRule: showsTopRule) {
            VStack(alignment: .leading, spacing: Space.md) {
                ExerciseDemoView(exercise: exercise, height: 200)
                    .padding(.top, Space.xxs)
                if !exercise.instructions.isEmpty {
                    CanvasNumberedSteps(steps: exercise.instructions)
                }
                Text(restLine)
                    .font(VFont.secondary.monospacedDigit())
                    .foregroundStyle(VColor.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    /// "Default rest 3:00 · steps of 2.5 kg"
    private var restLine: String {
        var parts = ["Default rest \(Format.clock(TimeInterval(exercise.defaultRestSeconds)))"]
        if exercise.loadIncrement > 0 {
            parts.append("steps of \(Format.weight(exercise.loadIncrement, unit: model.unit))")
        }
        return parts.joined(separator: " · ")
    }

    // MARK: Alternatives

    private var alternatives: some View {
        let options = Array(model.alternatives(for: exercise).prefix(3))
        return CanvasSection("Alternatives", actionTitle: options.isEmpty ? nil : "See all") {
            showsReplace = true
        } content: {
            VStack(spacing: 0) {
                if options.isEmpty {
                    Text("No alternatives with your equipment yet.")
                        .font(VFont.secondary)
                        .foregroundStyle(VColor.textSecondary)
                        .padding(.vertical, Space.xs)
                }
                ForEach(Array(options.enumerated()), id: \.element.id) { index, option in
                    alternativeRow(option)
                        .overlay(alignment: .top) {
                            if index > 0 { Hairline(leading: ExerciseThumbnail.rowSize + Space.sm) }
                        }
                }
            }
            VStack(alignment: .leading, spacing: 2) {
                Button {
                    model.toggleAvoided(exercise.id)
                } label: {
                    Label(isAvoided ? "Allow \(exercise.name) in plans" : "Avoid \(exercise.name) (preference or discomfort)",
                          systemImage: isAvoided ? "checkmark.circle" : "hand.raised")
                        .font(VFont.secondaryEmphasized)
                        .foregroundStyle(VColor.accentText)
                        .multilineTextAlignment(.leading)
                        .frame(maxWidth: .infinity, minHeight: Size.minTouch, alignment: .leading)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                Text("Avoided exercises are never suggested as alternatives.")
                    .font(VFont.fieldCaption)
                    .foregroundStyle(VColor.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.top, Space.sm)
        }
    }

    @ViewBuilder
    private func alternativeRow(_ option: Substitution) -> some View {
        let subtitle = (option.exercise.primaryMuscles.map(\.displayName).joined(separator: ", ")
                        + " · " + option.exercise.equipment.displayName.lowercased())
        let label = HStack(spacing: Space.sm) {
            ExerciseThumbnail(exercise: option.exercise, size: ExerciseThumbnail.rowSize)
            CanvasRow(title: option.exercise.name, subtitle: subtitle, showsChevron: true)
        }
        .padding(.vertical, Space.xxs)

        if let workoutIndex {
            Button {
                model.replaceExercise(at: workoutIndex, with: option.exercise)
                Haptics.light()
                onReplaced()
            } label: {
                label
            }
            .buttonStyle(.pressable)
            .accessibilityHint("Replaces \(exercise.name) in this workout")
        } else {
            NavigationLink(value: ExerciseRoute(id: option.exercise.id)) {
                label
            }
            .buttonStyle(.pressable)
        }
    }
}

// MARK: - Hero

/// The training field: title, metadata, the estimated max with its chart,
/// and the next-session recommendation (or the Pro preview).
private struct ExerciseHero: View {
    var exercise: Exercise
    var history: [ExercisePerformance]
    @Binding var showsWhy: Bool
    @Binding var adjusting: ProgressionRecommendation?
    @Environment(AppModel.self) private var model
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(exercise.name)
                .font(VFont.fieldTitle)
                .foregroundStyle(VColor.textPrimary)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityAddTraits(.isHeader)
            Text(metadata)
                .font(VFont.secondary.monospacedDigit())
                .foregroundStyle(VColor.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 2)

            estimate
                .padding(.top, 18)

            let points = chartPoints
            if points.count >= 2 {
                EstimatedMaxChart(points: points, unit: model.unit)
                    .padding(.top, Space.sm)
            }

            if let rec = model.recommendation(for: exercise.id) {
                Hairline()
                    .padding(.top, Space.md)
                if model.showsRecommendation(for: exercise.id) {
                    recommendation(rec)
                } else {
                    locked
                }
            }
        }
        .padding(.horizontal, Space.fieldInset)
        .padding(.top, Space.xs)
        .padding(.bottom, Space.lg)
        .frame(maxWidth: .infinity, alignment: .leading)
        .fieldHeroBackground(VColor.fieldTraining)
    }

    /// "Quads, glutes · barbell · rest 3:00"
    private var metadata: String {
        var parts: [String] = []
        let muscles = exercise.primaryMuscles.map(\.displayName).joined(separator: ", ")
        if !muscles.isEmpty { parts.append(muscles) }
        parts.append(exercise.equipment.displayName.lowercased())
        parts.append("rest \(Format.clock(TimeInterval(exercise.defaultRestSeconds)))")
        return parts.joined(separator: " · ")
    }

    // MARK: Estimate

    @ViewBuilder private var estimate: some View {
        if let latest = history.first, latest.estimatedOneRepMax > 0 {
            let source = latest.workingSets.max {
                OneRepMax.estimate(weight: $0.weight, reps: $0.reps) < OneRepMax.estimate(weight: $1.weight, reps: $1.reps)
            }
            VStack(alignment: .leading, spacing: Space.xxs) {
                (Text(Format.estimate(latest.estimatedOneRepMax, unit: model.unit, includeUnit: false))
                    .font(VFont.fieldNumber)
                    .foregroundStyle(VColor.textPrimary)
                 + Text(" \(model.unit.symbol)")
                    .font(VFont.headline)
                    .foregroundStyle(VColor.textSecondary))
                    .contentTransition(.numericText())
                    .accessibilityLabel("Estimated max \(Format.estimate(latest.estimatedOneRepMax, unit: model.unit))")
                Text(source.map { "Estimated max from \(Format.weight($0.weight, unit: model.unit)) × \($0.reps). An estimate, not a tested lift." }
                     ?? "Estimated max. An estimate, not a tested lift.")
                    .font(VFont.secondary)
                    .foregroundStyle(VColor.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        } else if let latest = history.first, let best = latest.workingSets.max(by: { $0.reps < $1.reps }) {
            // Bodyweight work: no load, so no estimated max. Show the best set.
            VStack(alignment: .leading, spacing: Space.xxs) {
                (Text("\(best.reps)")
                    .font(VFont.fieldNumber)
                    .foregroundStyle(VColor.textPrimary)
                 + Text(" reps")
                    .font(VFont.headline)
                    .foregroundStyle(VColor.textSecondary))
                Text("Best set last session, \(Format.shortDate(latest.date, calendar: model.calendar)).")
                    .font(VFont.secondary)
                    .foregroundStyle(VColor.textSecondary)
            }
            .accessibilityElement(children: .combine)
        } else {
            Text("No sessions yet. Log \(exercise.name) once and your estimated max, records and history appear here.")
                .font(VFont.secondary)
                .foregroundStyle(VColor.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// Oldest first, at most the last 12 sessions with a load.
    private var chartPoints: [ChartPoint] {
        history.prefix(12).reversed()
            .filter { $0.estimatedOneRepMax > 0 }
            .map { ChartPoint(date: $0.date, value: $0.estimatedOneRepMax) }
    }

    // MARK: Recommendation

    private func recommendation(_ rec: ProgressionRecommendation) -> some View {
        let isAccepted = model.target(for: exercise.id) != nil
        return VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .center, spacing: Space.sm) {
                Image(systemName: Icon.recommendation)
                    .font(.system(.body, weight: .semibold))
                    .foregroundStyle(VColor.inkTraining)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text(headline(rec))
                        .font(VFont.bodyEmphasized.monospacedDigit())
                        .foregroundStyle(VColor.textPrimary)
                        .fixedSize(horizontal: false, vertical: true)
                    Text(rec.reason)
                        .font(VFont.fieldCaption)
                        .foregroundStyle(VColor.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityElement(children: .combine)
                Button {
                    withAnimation(Motion.adaptive(Motion.smooth, reduceMotion: reduceMotion)) { showsWhy.toggle() }
                } label: {
                    Text(showsWhy ? "Hide" : "Why")
                        .font(VFont.secondaryEmphasized)
                        .foregroundStyle(VColor.accentText)
                        .frame(minWidth: Size.minTouch, minHeight: Size.minTouch, alignment: .trailing)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(showsWhy ? "Hide reasoning" : "Why this recommendation")
                .accessibilityAddTraits(showsWhy ? .isSelected : [])
            }
            .padding(.top, Space.sm)

            if showsWhy {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(rec.evidence.enumerated()), id: \.offset) { index, item in
                        HStack(alignment: .firstTextBaseline, spacing: Space.sm) {
                            Text(item.label)
                                .font(VFont.secondary)
                                .foregroundStyle(VColor.textSecondary)
                            Spacer(minLength: Space.sm)
                            Text(item.value)
                                .font(VFont.secondaryEmphasized.monospacedDigit())
                                .foregroundStyle(VColor.textPrimary)
                                .multilineTextAlignment(.trailing)
                        }
                        .padding(.vertical, Space.xs)
                        .overlay(alignment: .top) { if index > 0 { Hairline() } }
                        .accessibilityElement(children: .combine)
                    }
                    if rec.weight != nil {
                        HStack(spacing: Space.md) {
                            Button {
                                model.accept(rec)
                            } label: {
                                Label(isAccepted ? "Accepted" : "Use this", systemImage: isAccepted ? Icon.check : Icon.recommendation)
                            }
                            .buttonStyle(.outlinedCapsule)
                            .disabled(isAccepted)
                            Button("Adjust") { adjusting = rec }
                                .font(VFont.secondaryEmphasized)
                                .foregroundStyle(VColor.accentText)
                                .frame(minHeight: Size.minTouch)
                                .buttonStyle(.plain)
                        }
                        .padding(.top, Space.sm)
                    }
                }
                .padding(.leading, Space.lg + Space.sm)
                .padding(.top, Space.xs)
                .transition(.opacity)
            }
        }
        .sensoryFeedback(.success, trigger: isAccepted)
    }

    /// "Next: 82.5 kg × 8 on all 3 sets"
    private func headline(_ rec: ProgressionRecommendation) -> String {
        if let weight = rec.weight, weight > 0 {
            return "Next: \(Format.weight(weight, unit: model.unit)) × \(rec.reps) on all \(rec.sets) sets"
        }
        return "Next: \(rec.action.title.lowercased()), \(rec.reps) reps × \(rec.sets) sets"
    }

    /// Free tier, not the main lift: show what Pro adds, never a blank lock.
    private var locked: some View {
        Button {
            model.presentPaywall(.coach)
        } label: {
            HStack(alignment: .center, spacing: Space.sm) {
                Image(systemName: Icon.lock)
                    .foregroundStyle(VColor.inkTraining)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Know exactly what to lift next")
                        .font(VFont.bodyEmphasized)
                        .foregroundStyle(VColor.textPrimary)
                    Text("Pro recommends your next weight and reps after every session, and tells you why.")
                        .font(VFont.fieldCaption)
                        .foregroundStyle(VColor.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                Text("See Pro")
                    .font(VFont.secondaryEmphasized)
                    .foregroundStyle(VColor.accentText)
            }
            .padding(.top, Space.sm)
            .frame(minHeight: Size.minTouch)
            .contentShape(Rectangle())
        }
        .buttonStyle(.pressable)
        .accessibilityElement(children: .combine)
        .accessibilityHint("Opens Vector Pro")
    }
}

// MARK: - Estimated max chart

/// Estimated max per session: `LineMark` + `PointMark`, the latest point
/// emphasised, dashed hairline grid with trailing labels, dates below.
private struct EstimatedMaxChart: View {
    var points: [ChartPoint]
    var unit: WeightUnit
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let last = points.last
        Chart {
            ForEach(points) { point in
                LineMark(x: .value("Date", point.date), y: .value("Estimated max", unit.fromKilograms(point.value)))
                    .foregroundStyle(VColor.chartPrimary)
                    .lineStyle(StrokeStyle(lineWidth: 2.5, lineCap: .round, lineJoin: .round))
                PointMark(x: .value("Date", point.date), y: .value("Estimated max", unit.fromKilograms(point.value)))
                    .foregroundStyle(VColor.chartPrimary)
                    .symbolSize(point.id == last?.id ? 90 : 30)
            }
        }
        .chartYScale(domain: domain)
        .chartXAxis {
            AxisMarks(values: .automatic(desiredCount: 5)) { _ in
                AxisValueLabel(format: .dateTime.day().month(.abbreviated))
                    .font(.system(.caption2))
                    .foregroundStyle(VColor.textSecondary)
            }
        }
        .chartYAxis {
            AxisMarks(position: .trailing, values: .automatic(desiredCount: 3)) { value in
                AxisGridLine(stroke: StrokeStyle(lineWidth: 0.5, dash: [2, 3]))
                    .foregroundStyle(VColor.chartGrid)
                AxisValueLabel {
                    if let number = value.as(Double.self) {
                        Text(Format.integer(number))
                            .font(.system(.caption2).monospacedDigit())
                            .foregroundStyle(VColor.textSecondary)
                    }
                }
            }
        }
        .frame(height: 150)
        .animation(Motion.adaptive(Motion.chart, reduceMotion: reduceMotion), value: points)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Estimated max chart")
        .accessibilityValue(summary)
    }

    private var domain: ClosedRange<Double> {
        let values = points.map { unit.fromKilograms($0.value) }
        guard let low = values.min(), let high = values.max() else { return 0...1 }
        let pad = max((high - low) * 0.25, 2.5)
        return (low - pad)...(high + pad)
    }

    private var summary: String {
        guard let first = points.first, let last = points.last else { return "No data" }
        return "\(points.count) sessions from \(Format.shortDate(first.date)) to \(Format.shortDate(last.date)). "
            + "From \(Format.estimate(first.value, unit: unit)) to \(Format.estimate(last.value, unit: unit)), estimated."
    }
}

// MARK: - Session rows

/// "Mon 28 Sep" / "80 × 8, 8, 8 · RPE 8, 8.5, 9" with the session's
/// estimated max on the trailing side.
private struct ExerciseSessionRow: View {
    var performance: ExercisePerformance
    @Environment(AppModel.self) private var model

    var body: some View {
        let rpes = performance.workingSets.compactMap(\.rpe).map(Format.rpe)
        let subtitle = performance.summary(unit: model.unit) + (rpes.isEmpty ? "" : " · RPE " + rpes.joined(separator: ", "))
        let estimated = performance.estimatedOneRepMax
        CanvasRow(title: performance.date.formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated)),
                  subtitle: subtitle,
                  value: estimated > 0 ? Format.estimate(estimated, unit: model.unit, includeUnit: false) : nil,
                  valueCaption: estimated > 0 ? "est. max" : nil)
    }
}

/// Every logged session for one exercise, newest first.
private struct ExerciseSessionsView: View {
    var exercise: Exercise
    @Environment(AppModel.self) private var model

    var body: some View {
        let history = model.history(for: exercise.id)
        List {
            if model.hasHiddenHistory {
                Button {
                    model.presentPaywall(.history)
                } label: {
                    Label("Older sessions are kept safely. Pro shows your full history.", systemImage: Icon.lock)
                        .font(VFont.secondary)
                        .foregroundStyle(VColor.accentText)
                        .frame(maxWidth: .infinity, minHeight: Size.minTouch, alignment: .leading)
                }
                .listRowBackground(VColor.ground)
            }
            ForEach(history, id: \.sessionID) { performance in
                ExerciseSessionRow(performance: performance)
                    .listRowBackground(VColor.ground)
                    .listRowSeparatorTint(VColor.separator)
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .screenBackground()
        .navigationTitle("Sessions")
        .navigationBarTitleDisplayMode(.inline)
    }
}

/// Ranked alternatives. Everyone sees sensible swaps; Pro adds the full
/// ranked list with the reasoning and preference/discomfort awareness.
struct ReplaceExerciseView: View {
    var exercise: Exercise
    var workoutIndex: Int?
    var onReplaced: () -> Void
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        let alternatives = model.alternatives(for: exercise)
        NavigationStack {
            List {
                Section {
                    ForEach(alternatives) { option in
                        Button {
                            if let workoutIndex {
                                model.replaceExercise(at: workoutIndex, with: option.exercise)
                                Haptics.light()
                                dismiss()
                                onReplaced()
                            } else {
                                dismiss()
                                model.sheet = .exercise(option.exercise.id)
                            }
                        } label: {
                            HStack(alignment: .top, spacing: Space.sm) {
                                ExerciseThumbnail(exercise: option.exercise, size: 44)
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(option.exercise.name).font(VFont.bodyEmphasized).foregroundStyle(VColor.textPrimary)
                                    if model.isPro {
                                        Text(option.reasons.joined(separator: " · "))
                                            .font(VFont.secondary)
                                            .foregroundStyle(VColor.textSecondary)
                                    } else {
                                        Text(option.exercise.equipment.displayName)
                                            .font(VFont.secondary)
                                            .foregroundStyle(VColor.textSecondary)
                                    }
                                }
                                Spacer()
                                if let last = model.history(for: option.exercise.id).first {
                                    Text(last.summary(unit: model.unit))
                                        .font(VFont.caption.monospacedDigit())
                                        .foregroundStyle(VColor.textTertiary)
                                }
                            }
                            .padding(.vertical, Space.xxs)
                        }
                    }
                } header: {
                    Text("Same muscles, equipment you have")
                } footer: {
                    if !model.isPro && workoutIndex == nil {
                        Button("Smart swaps with reasons are part of Pro") { model.presentPaywall(.substitution) }
                            .font(VFont.caption)
                    }
                }

                Section {
                    Button {
                        model.toggleAvoided(exercise.id)
                    } label: {
                        let avoided = model.profile?.avoidedExerciseIDs.contains(exercise.id) ?? false
                        Label(avoided ? "Allow \(exercise.name) in plans" : "Avoid \(exercise.name) (preference or discomfort)",
                              systemImage: avoided ? "checkmark.circle" : "hand.raised")
                    }
                } footer: {
                    Text("Avoided exercises are never suggested as alternatives.")
                }
            }
            .navigationTitle("Alternatives")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } } }
        }
    }
}
