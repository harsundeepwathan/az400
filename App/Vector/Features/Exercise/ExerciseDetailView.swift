import SwiftUI
import VectorCore

/// Exercise sheet: what it is, how you've done, what to do next, and
/// what to swap it for.
struct ExerciseDetailView: View {
    var exercise: Exercise
    /// Set when opened from an active workout; enables in-place replacement.
    var workoutIndex: Int?
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var tab: Tab = .summary
    @State private var showsReplace = false
    @State private var adjusting: ProgressionRecommendation?

    enum Tab: String, CaseIterable, Identifiable {
        case summary = "Summary", history = "History", howTo = "How to"
        var id: String { rawValue }
    }

    private var history: [ExercisePerformance] { model.history(for: exercise.id) }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: Space.lg) {
                    hero
                    Picker("Section", selection: $tab) {
                        ForEach(Tab.allCases) { Text($0.rawValue).tag($0) }
                    }
                    .pickerStyle(.segmented)

                    switch tab {
                    case .summary: summary
                    case .history: historyList
                    case .howTo: instructions
                    }

                    Button {
                        showsReplace = true
                    } label: {
                        Label(workoutIndex == nil ? "Find Alternatives" : "Replace Exercise", systemImage: Icon.swap)
                    }
                    .buttonStyle(.secondary)
                }
                .padding(.horizontal, Space.gutter)
                .padding(.bottom, Space.xl)
                .animation(Motion.smooth, value: tab)
            }
            .screenBackground()
            .navigationTitle(exercise.name)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
            .sheet(item: $adjusting) { rec in
                AdjustTargetView(recommendation: rec).presentationDetents([.height(360)])
            }
            .sheet(isPresented: $showsReplace) {
                ReplaceExerciseView(exercise: exercise, workoutIndex: workoutIndex) { dismiss() }
            }
        }
    }

    // MARK: Sections

    private var hero: some View {
        VStack(alignment: .leading, spacing: Space.sm) {
            ZStack {
                RoundedRectangle(cornerRadius: Radius.lg, style: .continuous)
                    .fill(LinearGradient(colors: [VColor.accentSoft, VColor.surface], startPoint: .topLeading, endPoint: .bottomTrailing))
                Image(systemName: exercise.symbol)
                    .font(.system(size: 72, weight: .light))
                    .foregroundStyle(VColor.accentText)
                    .symbolEffect(.pulse, options: .repeating.speed(0.4))
                    .accessibilityHidden(true)
            }
            .frame(height: 160)
            HStack(spacing: Space.xs) {
                ForEach(exercise.primaryMuscles, id: \.self) {
                    Chip(text: $0.displayName, tint: VColor.accentText, fill: VColor.accentSoft)
                }
                ForEach(exercise.secondaryMuscles, id: \.self) { Chip(text: $0.displayName) }
            }
            Text("\(exercise.equipment.displayName) · \(exercise.pattern.displayName)")
                .font(VFont.secondary)
                .foregroundStyle(VColor.textSecondary)
        }
    }

    @ViewBuilder
    private var summary: some View {
        if history.isEmpty {
            EmptyStateView(symbol: "chart.xyaxis.line", title: "No history yet",
                           message: "Log \(exercise.name) once and we'll track your best sets, estimated 1RM and trends here.")
        } else {
            let best = history.flatMap(\.workingSets).max { lhs, rhs in
                lhs.weight == rhs.weight ? lhs.reps < rhs.reps : lhs.weight < rhs.weight
            }
            let bestE1RM = history.map(\.estimatedOneRepMax).max() ?? 0
            let points = history.reversed().map { ChartPoint(date: $0.date, value: $0.estimatedOneRepMax) }
            let volumes = history.reversed().map { ChartPoint(date: $0.date, value: $0.volume) }

            LazyVGrid(columns: [GridItem(.flexible(), spacing: Space.sm), GridItem(.flexible())], spacing: Space.sm) {
                MetricCard(label: "Personal best",
                           value: best.map { "\(Format.weight($0.weight, unit: model.unit, includeUnit: false)) × \($0.reps)" } ?? "—",
                           unit: best.map { _ in model.unit.symbol }, symbol: Icon.trophy)
                MetricCard(label: "Estimated 1RM", value: Format.estimate(bestE1RM, unit: model.unit, includeUnit: false),
                           unit: model.unit.symbol, symbol: "bolt.fill")
            }

            if let rec = model.recommendation(for: exercise.id) {
                if model.isPro || model.program?.nextWorkout?.exercises.first?.exerciseID == exercise.id {
                    AIRecommendationCard(recommendation: rec, unit: model.unit,
                                         isAccepted: model.target(for: exercise.id) != nil,
                                         onAccept: rec.weight == nil ? nil : { model.accept(rec) },
                                         onModify: { adjusting = rec })
                } else {
                    LockedFeatureCard(feature: .progressiveOverload, headline: "Know exactly what to lift next",
                                      message: "Pro analyses every set you log and recommends the next weight and reps, and tells you why.") {
                        model.presentPaywall(.coach)
                    }
                }
            }

            VStack(alignment: .leading, spacing: Space.sm) {
                Text("Estimated 1RM").font(VFont.headline).foregroundStyle(VColor.textPrimary)
                ProgressChart(points: points, style: .line, valueFormatter: { Format.estimate($0, unit: model.unit) }, height: 150)
            }
            .card()

            VStack(alignment: .leading, spacing: Space.sm) {
                HStack {
                    Text("Volume per session").font(VFont.headline).foregroundStyle(VColor.textPrimary)
                    Spacer()
                    if let trend = model.progression.volumeTrend(history) {
                        DeltaBadge(delta: trend, caption: "last 3")
                    }
                }
                ProgressChart(points: volumes, style: .bars, valueFormatter: { Format.compact($0) }, height: 120)
            }
            .card()
        }
    }

    private var historyList: some View {
        VStack(spacing: 0) {
            if history.isEmpty {
                EmptyStateView(symbol: "clock", title: "Nothing logged yet", message: "Your sets will appear here after your first session.")
            }
            ForEach(Array(history.prefix(20).enumerated()), id: \.element.sessionID) { index, performance in
                VStack(alignment: .leading, spacing: Space.xs) {
                    HStack {
                        Text(Format.shortDate(performance.date, calendar: model.calendar))
                            .font(VFont.secondaryEmphasized)
                            .foregroundStyle(VColor.textPrimary)
                        Spacer()
                        Text("e1RM \(Format.estimate(performance.estimatedOneRepMax, unit: model.unit))")
                            .font(VFont.caption.monospacedDigit())
                            .foregroundStyle(VColor.textSecondary)
                    }
                    Text(performance.workingSets.map {
                        "\(Format.weight($0.weight, unit: model.unit, includeUnit: false))×\($0.reps)"
                    }.joined(separator: "   "))
                    .font(VFont.dataSecondary)
                    .foregroundStyle(VColor.textSecondary)
                }
                .padding(.vertical, Space.sm)
                .padding(.horizontal, Space.md)
                if index < min(history.count, 20) - 1 { Hairline(leading: Space.md) }
            }
            if model.hasHiddenHistory {
                Button("See full history with Pro") { model.presentPaywall(.history) }
                    .font(VFont.secondaryEmphasized)
                    .frame(minHeight: Size.minTouch)
            }
        }
        .card(padding: 0)
    }

    private var instructions: some View {
        VStack(alignment: .leading, spacing: Space.md) {
            ForEach(Array(exercise.instructions.enumerated()), id: \.offset) { index, step in
                HStack(alignment: .top, spacing: Space.sm) {
                    Text("\(index + 1)")
                        .font(VFont.captionEmphasized)
                        .foregroundStyle(VColor.accentText)
                        .frame(width: 24, height: 24)
                        .background(VColor.accentSoft, in: Circle())
                    Text(step)
                        .font(VFont.body)
                        .foregroundStyle(VColor.textPrimary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Hairline()
            HStack {
                Label("Default rest \(Format.clock(TimeInterval(exercise.defaultRestSeconds)))", systemImage: Icon.timer)
                Spacer()
                if exercise.loadIncrement > 0 {
                    Text("Steps of \(Format.weight(exercise.loadIncrement, unit: model.unit))")
                }
            }
            .font(VFont.secondary)
            .foregroundStyle(VColor.textSecondary)
        }
        .card()
    }
}

/// Ranked alternatives. Everyone sees sensible swaps; Pro adds the full
/// ranked list with the reasoning and injury/preference awareness.
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
                                IconBadge(symbol: option.exercise.symbol, size: 36)
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
                        Label(avoided ? "Allow \(exercise.name) in plans" : "Avoid \(exercise.name) (injury or preference)",
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
