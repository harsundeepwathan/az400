import SwiftUI
import VectorCore

/// "Am I actually progressing?" Volume is shown with context (vs the
/// previous period), next to frequency, strength (estimated 1RM), body
/// weight trend, PRs and per-muscle weekly sets, then calories and protein.
struct ProgressDashboardView: View {
    @Environment(AppModel.self) private var model
    @State private var range: TimeRange = .month
    @State private var strengthExerciseID: String?
    @State private var detail: ChartDetail?

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: Space.section) {
                    RangePicker(selection: $range,
                                isLocked: { $0.requiresPro && !model.isPro },
                                onLockedTap: { model.presentPaywall(.history) })

                    if model.sessions.isEmpty {
                        EmptyStateView(symbol: Icon.progress, title: "Ready for your first session?",
                                       message: "Start your first workout and we'll begin building your strength profile.",
                                       actionTitle: "Start Workout") {
                            if let next = model.nextWorkout { model.startWorkout(next) } else { model.startEmptyWorkout() }
                        }
                    } else {
                        summary
                        charts
                        personalRecords
                        muscleBalance
                    }
                    BodyProgressLinks()

                    // Shown with or without workouts; hides itself until a meal is logged.
                    NutritionChartsSection()
                }
                .padding(.horizontal, Space.gutter)
                .padding(.bottom, Space.xl)
                .animation(Motion.smooth, value: range)
            }
            .screenBackground()
            .navigationTitle("Progress")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button { model.sheet = .coach } label: {
                        Label("Coach", systemImage: Icon.sparkles)
                    }
                }
            }
            .sheet(item: $detail) { ChartDetailView(detail: $0) }
        }
    }

    // MARK: Summary

    private var summary: some View {
        let summary = model.analytics.summary(model.sessions, range: range, now: model.now())
        return VStack(alignment: .leading, spacing: Space.xs) {
            LazyVGrid(columns: [GridItem(.flexible(), spacing: Space.sm), GridItem(.flexible())], spacing: Space.sm) {
                MetricCard(label: "Workouts", value: "\(summary.workouts)", symbol: "calendar")
                MetricCard(label: "Volume", value: Format.volume(summary.volume, unit: model.unit, includeUnit: false),
                           unit: model.unit.symbol, delta: summary.volumeChange, symbol: "scalemass")
                MetricCard(label: "PRs", value: "\(summary.personalRecords)", symbol: Icon.trophy)
                MetricCard(label: "Avg duration", value: Format.duration(summary.averageDuration), symbol: Icon.timer)
            }
            if summary.volumeChange != nil {
                Text("Volume change is \(range.comparisonLabel).")
                    .font(VFont.caption)
                    .foregroundStyle(VColor.textTertiary)
                    .padding(.horizontal, Space.xxs)
            }
        }
    }

    // MARK: Charts

    @ViewBuilder
    private var charts: some View {
        let volume = model.analytics.volumeSeries(model.sessions, range: range, now: model.now())
        let frequency = model.analytics.frequencySeries(model.sessions, range: range, now: model.now())
        let bodyWeight = model.analytics.bodyWeightSeries(model.bodyWeights, range: range, now: model.now())

        VStack(alignment: .leading, spacing: Space.sm) {
            SectionHeader("Training")
            ChartCard(title: "Training volume", subtitle: "Total \(model.unit.symbol) lifted per \(range.bucket == .day ? "day" : "week")",
                      onExpand: { detail = ChartDetail(kind: .volume, range: range) }) {
                ProgressChart(points: volume, style: .bars, unit: range.bucket, valueFormatter: { Format.compact($0) })
            }
            ChartCard(title: "Workout frequency", subtitle: "Sessions per week · goal \(model.profile?.daysPerWeek ?? 4)",
                      onExpand: { detail = ChartDetail(kind: .frequency, range: range) }) {
                ProgressChart(points: frequency, style: .bars, unit: .weekOfYear,
                              valueFormatter: { Format.integer($0) }, height: 120,
                              target: Double(model.profile?.daysPerWeek ?? 4)...Double(model.profile?.daysPerWeek ?? 4) + 0.08)
            }
        }

        strengthCard

        if !bodyWeight.isEmpty {
            ChartCard(title: "Body weight", subtitle: "Dots are weigh-ins, the line is your trend",
                      onExpand: { detail = ChartDetail(kind: .bodyWeight, range: range) }) {
                ProgressChart(points: bodyWeight, style: .trend(smoothed: model.analytics.smoothedTrend(bodyWeight)),
                              valueFormatter: { Format.estimate($0, unit: model.unit) })
            } accessory: {
                Button("Log") { model.sheet = .bodyWeight }
                    .font(VFont.secondaryEmphasized)
                    .frame(minHeight: Size.minTouch)
            }
        }
    }

    @ViewBuilder
    private var strengthCard: some View {
        let exercises = model.analytics.trackedExercises(model.sessions).filter(\.isCompound)
        if model.isPro, let selected = strengthExerciseID.flatMap({ model.catalog[$0] }) ?? exercises.first {
            let points = model.analytics.strengthSeries(model.sessions, exerciseID: selected.id, range: range, now: model.now())
            ChartCard(title: "Strength progress", subtitle: "Estimated 1RM",
                      onExpand: { detail = ChartDetail(kind: .strength(selected.id), range: range) }) {
                if points.count >= 2 {
                    ProgressChart(points: points, style: .line, valueFormatter: { Format.estimate($0, unit: model.unit) })
                } else {
                    Text("Log \(selected.name) a few more times to see a trend.")
                        .font(VFont.secondary)
                        .foregroundStyle(VColor.textSecondary)
                        .frame(maxWidth: .infinity, minHeight: 120)
                }
            } accessory: {
                Menu {
                    ForEach(exercises) { exercise in
                        Button(exercise.name) { strengthExerciseID = exercise.id }
                    }
                } label: {
                    HStack(spacing: 4) {
                        Text(selected.name).lineLimit(1)
                        Image(systemName: "chevron.up.chevron.down").imageScale(.small)
                    }
                    .font(VFont.secondaryEmphasized)
                    .frame(minHeight: Size.minTouch)
                }
            }
        } else if !model.isPro {
            LockedFeatureCard(feature: .advancedAnalytics, headline: "See your strength curve",
                              message: "Track estimated 1RM for every lift so you know you're getting stronger, not just doing more.") {
                model.presentPaywall(.analytics)
            }
        }
    }

    // MARK: PRs

    private var personalRecords: some View {
        let records = Array(model.analytics.personalRecords(model.sessions).prefix(5))
        return VStack(alignment: .leading, spacing: Space.sm) {
            SectionHeader("Personal records")
            if records.isEmpty {
                EmptyStateView(symbol: Icon.trophy, title: "Your first PR is close",
                               message: "Beat a previous best weight or rep count and it shows up here.")
            } else {
                VStack(spacing: 0) {
                    ForEach(Array(records.enumerated()), id: \.element.id) { index, record in
                        Button {
                            model.sheet = .exercise(record.exerciseID)
                        } label: {
                            HStack(spacing: Space.sm) {
                                IconBadge(symbol: Icon.trophy, tint: VColor.warning, fill: VColor.warningSoft, size: 34)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(record.exerciseName).font(VFont.bodyEmphasized).foregroundStyle(VColor.textPrimary)
                                    Text(Format.relativeDays(from: record.date, to: model.now(), calendar: model.calendar))
                                        .font(VFont.caption)
                                        .foregroundStyle(VColor.textSecondary)
                                }
                                Spacer()
                                VStack(alignment: .trailing, spacing: 2) {
                                    Text(record.weight > 0 ? "\(Format.weight(record.weight, unit: model.unit)) × \(record.reps)" : "\(record.reps) reps")
                                        .font(VFont.data)
                                        .foregroundStyle(VColor.textPrimary)
                                    Text(record.improvementLabel(unit: model.unit))
                                        .font(VFont.captionEmphasized.monospacedDigit())
                                        .foregroundStyle(VColor.success)
                                }
                            }
                            .padding(.horizontal, Space.md)
                            .padding(.vertical, Space.sm)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        if index < records.count - 1 { Hairline(leading: 62) }
                    }
                }
                .card(padding: 0)
            }
        }
    }

    // MARK: Muscles

    private var muscleBalance: some View {
        let volumes = model.analytics.weeklySetsPerMuscle(model.sessions, now: model.now())
        return VStack(alignment: .leading, spacing: Space.sm) {
            SectionHeader("Weekly sets per muscle")
            if model.isPro {
                VStack(alignment: .leading, spacing: Space.sm) {
                    ForEach(volumes) { volume in MuscleVolumeRow(volume: volume) }
                    HStack(spacing: Space.xs) {
                        RoundedRectangle(cornerRadius: 2).fill(VColor.chartTarget).frame(width: 14, height: 10)
                        Text("10–20 hard sets per week is the evidence-based range for growth. Secondary muscles count as half a set.")
                            .font(VFont.caption)
                            .foregroundStyle(VColor.textSecondary)
                    }
                    .padding(.top, Space.xxs)
                }
                .card()
            } else {
                LockedFeatureCard(feature: .advancedAnalytics, headline: "Find your weak points",
                                  message: "See weekly sets for every muscle against the optimal range, and spot imbalances before they stall you.") {
                    model.presentPaywall(.analytics)
                }
            }
        }
    }
}

private struct MuscleVolumeRow: View {
    var volume: MuscleVolume
    private let scaleMax: Double = 24

    var body: some View {
        HStack(spacing: Space.sm) {
            Text(volume.muscle.displayName)
                .font(VFont.secondary)
                .foregroundStyle(VColor.textPrimary)
                .frame(width: 92, alignment: .leading)
            GeometryReader { proxy in
                let width = proxy.size.width
                ZStack(alignment: .leading) {
                    Capsule().fill(VColor.surfaceSunken)
                    Rectangle()
                        .fill(VColor.chartTarget)
                        .frame(width: width * (10 / scaleMax))
                        .offset(x: width * (10 / scaleMax))
                    Capsule()
                        .fill(volume.status == .optimal ? VColor.accent : VColor.chartMuted)
                        .frame(width: max(width * min(volume.sets / scaleMax, 1), volume.sets > 0 ? 6 : 0))
                }
            }
            .frame(height: 10)
            Text(Format.number1Trimmed(volume.sets))
                .font(VFont.secondaryEmphasized.monospacedDigit())
                .foregroundStyle(VColor.textPrimary)
                .frame(width: 36, alignment: .trailing)
            statusIcon
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(volume.muscle.displayName): \(Format.number1Trimmed(volume.sets)) sets, \(statusText)")
    }

    private var statusText: String {
        switch volume.status {
        case .low: "below range"
        case .optimal: "in range"
        case .high: "above range"
        }
    }

    private var statusIcon: some View {
        Image(systemName: volume.status == .optimal ? "checkmark.circle.fill" : (volume.status == .low ? "arrow.down.circle" : "arrow.up.circle"))
            .foregroundStyle(volume.status == .optimal ? VColor.success : VColor.warning)
            .font(.system(.footnote))
            .frame(width: 18)
    }
}

/// Card wrapper for a chart with an expand affordance.
struct ChartCard<Content: View, Accessory: View>: View {
    var title: String
    var subtitle: String
    var onExpand: (() -> Void)?
    var content: Content
    var accessory: Accessory

    init(title: String, subtitle: String, onExpand: (() -> Void)? = nil,
         @ViewBuilder content: () -> Content, @ViewBuilder accessory: () -> Accessory = { EmptyView() }) {
        self.title = title
        self.subtitle = subtitle
        self.onExpand = onExpand
        self.content = content()
        self.accessory = accessory()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Space.sm) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(VFont.headline).foregroundStyle(VColor.textPrimary)
                    Text(subtitle).font(VFont.caption).foregroundStyle(VColor.textSecondary)
                }
                Spacer()
                accessory
                if let onExpand {
                    Button(action: onExpand) {
                        Image(systemName: "arrow.up.left.and.arrow.down.right")
                            .font(.system(.footnote, weight: .semibold))
                            .foregroundStyle(VColor.textSecondary)
                            .frame(width: Size.minTouch, height: Size.minTouch)
                    }
                    .accessibilityLabel("Expand \(title)")
                }
            }
            content
        }
        .card()
    }
}

extension Format {
    static func number1Trimmed(_ value: Double) -> String {
        value.rounded() == value ? String(Int(value)) : String(format: "%.1f", value)
    }
}

#Preview {
    ProgressDashboardView().environment(AppModel.preview(pro: true))
}
