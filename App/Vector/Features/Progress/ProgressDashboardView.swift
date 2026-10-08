import SwiftUI
import VectorCore

/// "Am I actually progressing?" (widgets). The large title, Coach link and
/// range picker on the canvas, then tiles: Body weight (trend chart,
/// measurements, photos), Strength (volume per week, personal records and,
/// for Pro, estimated max and weekly sets per muscle), Consistency,
/// Nutrition and Coaching.
struct ProgressDashboardView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var range: TimeRange = .month
    @State private var detail: ChartDetail?

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    ProgressBodyField(range: $range, onDetail: { detail = $0 })
                    StrengthField(range: range, onDetail: { detail = $0 })
                        .padding(.horizontal, Space.gutter)
                    ConsistencySection(range: range, onDetail: { detail = $0 })
                    // Shown with or without workouts; hides itself until a meal is logged.
                    NutritionChartsSection()
                    CoachingHistorySection()
                }
                .padding(.bottom, Space.xl)
                .animation(Motion.adaptive(Motion.smooth, reduceMotion: reduceMotion), value: range)
            }
            .background(WColor.canvas.ignoresSafeArea())
            .navigationTitle("Progress")
            .toolbar(.hidden, for: .navigationBar)
            .sheet(item: $detail) { ChartDetailView(detail: $0) }
        }
    }
}

// MARK: - Body field (hero)

private struct ProgressBodyField: View {
    @Binding var range: TimeRange
    var onDetail: (ChartDetail) -> Void
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            WidgetScreenHeader(title: "Progress") {
                Button { model.sheet = .coach } label: {
                    Label("Coach", systemImage: Icon.recommendation)
                        .font(.system(.subheadline, weight: .semibold))
                        .foregroundStyle(WColor.textPrimary)
                        .padding(.horizontal, 14)
                        .frame(height: 38)
                        .background(WColor.innerStrong, in: Capsule())
                        .frame(minHeight: Size.minTouch)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.pressable)
            }

            FieldRangePicker(selection: $range, tint: WidgetTint.body.ink,
                             isLocked: { $0.requiresPro && !model.isPro },
                             onLockedTap: { model.presentPaywall(.history) })
                .padding(.horizontal, 4)

            WidgetTile(tint: .body, title: "Body weight", symbol: "figure.stand") {
                Button { model.sheet = .bodyWeight } label: {
                    WidgetChip(title: "Weigh in", symbol: "plus")
                        .frame(minHeight: Size.minTouch)
                }
                .buttonStyle(.pressable)
            } content: {
                weight
                    .padding(.top, Space.xs)
                links
                    .padding(.top, Space.sm)
            }
        }
        .padding(.horizontal, Space.gutter)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder private var weight: some View {
        let now = model.now()
        let points = model.analytics.bodyWeightSeries(model.bodyWeights, range: range, now: now)
        if let latest = model.latestBodyWeight {
            let trend = CoachMetrics(calendar: model.calendar).weightTrend(model.bodyWeights, days: 28, now: now)
            HStack(alignment: .firstTextBaseline, spacing: Space.sm) {
                (Text(Format.weight(latest.kilograms, unit: model.unit, includeUnit: false))
                    .font(VFont.fieldNumber)
                    .foregroundStyle(VColor.textPrimary)
                 + Text(" \(model.unit.symbol)")
                    .font(VFont.headline)
                    .foregroundStyle(VColor.textSecondary))
                    .accessibilityLabel("Latest weigh-in \(Format.weight(latest.kilograms, unit: model.unit))")
                if let trend {
                    Label(signed(trend.kgPerWeek) + " a week", systemImage: arrow(trend.kgPerWeek))
                        .font(VFont.bodyEmphasized.monospacedDigit())
                        .foregroundStyle(WidgetTint.body.ink)
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                        .accessibilityLabel("Trend \(signed(trend.kgPerWeek)) a week")
                }
                Spacer(minLength: 0)
                if !points.isEmpty {
                    Button { onDetail(ChartDetail(kind: .bodyWeight, range: range)) } label: {
                        Image(systemName: "arrow.up.left.and.arrow.down.right")
                            .font(.system(.footnote, weight: .semibold))
                            .foregroundStyle(VColor.textSecondary)
                            .frame(width: Size.minTouch, height: Size.minTouch)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Body weight data")
                }
            }

            if points.isEmpty {
                note("No weigh-ins in this range.")
            } else {
                WeightTrendChart(points: points, trend: model.analytics.smoothedTrend(points), tint: WidgetTint.body.accent,
                                 valueFormatter: { Format.estimate($0, unit: model.unit) })
                    .padding(.top, Space.xs)
                if points.count < 3 {
                    note("Log 3 weigh-ins to see a trend line.")
                }
            }
        } else {
            note("Log your weight to see your trend.")
        }
    }

    private var links: some View {
        VStack(spacing: 0) {
            NavigationLink {
                MeasurementsView()
            } label: {
                FieldRowLabel(symbol: "ruler", tint: WidgetTint.body.ink, title: "Measurements", detail: measurementsDetail)
            }
            RowHairline(leading: FieldMetric.rowIcon + Space.sm)
            NavigationLink {
                ProgressPhotosView()
            } label: {
                FieldRowLabel(symbol: "camera", tint: WidgetTint.body.ink, title: "Progress photos", detail: photosDetail)
            }
        }
        .buttonStyle(.plain)
    }

    private var measurementsDetail: String? {
        guard let latest = model.bodyMeasurements.last else { return nil }
        return Format.relativeDays(from: latest.date, to: model.now(), calendar: model.calendar)
    }

    private var photosDetail: String? {
        let count = model.progressPhotos.count
        return count == 0 ? nil : "\(count)"
    }

    private func note(_ text: String) -> some View {
        Text(text)
            .font(VFont.secondary)
            .foregroundStyle(VColor.textSecondary)
            .fixedSize(horizontal: false, vertical: true)
    }

    private func signed(_ kgPerWeek: Double) -> String {
        let sign = kgPerWeek >= 0 ? "+" : "\u{2212}"
        return "\(sign)\(Format.weight(abs(kgPerWeek), unit: model.unit))"
    }

    private func arrow(_ kgPerWeek: Double) -> String {
        if abs(kgPerWeek) < 0.01 { return "arrow.right" }
        return kgPerWeek > 0 ? "arrow.up.right" : "arrow.down.right"
    }
}

// MARK: - Strength field

private struct StrengthField: View {
    var range: TimeRange
    var onDetail: (ChartDetail) -> Void
    @Environment(AppModel.self) private var model
    @State private var strengthExerciseID: String?

    var body: some View {
        WidgetTile(tint: .training, title: "Strength", symbol: "dumbbell.fill") {
            if model.sessions.isEmpty {
                empty
            } else {
                volume
                records
                    .padding(.top, Space.lg)
                if model.isPro {
                    estimatedMax
                        .padding(.top, Space.lg)
                    muscleBalance
                        .padding(.top, Space.lg)
                } else {
                    FieldLockedRow(title: "Strength curves and muscle balance",
                                   message: "Estimated max for every lift, and weekly sets for each muscle against the range that builds it.") {
                        model.presentPaywall(.analytics)
                    }
                    .padding(.top, Space.lg)
                }
            }
        }
    }

    private var empty: some View {
        VStack(alignment: .leading, spacing: Space.xs) {
            Text("Ready for your first session?")
                .font(VFont.fieldTitle)
                .foregroundStyle(VColor.textPrimary)
                .fixedSize(horizontal: false, vertical: true)
            Text("Start your first workout and we'll begin building your strength profile.")
                .font(VFont.secondary)
                .foregroundStyle(VColor.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            Button {
                if let next = model.nextWorkout { model.startWorkout(next) } else { model.startEmptyWorkout() }
            } label: {
                Label("Start workout", systemImage: "play.fill")
            }
            .buttonStyle(.widgetPrimary)
            .padding(.top, Space.xs)
        }
    }

    // MARK: Volume

    private var volume: some View {
        let now = model.now()
        let summary = model.analytics.summary(model.sessions, range: range, now: now)
        let points = model.weeklyVolume(range: range)
        return VStack(alignment: .leading, spacing: Space.xs) {
            CanvasTitle("Training volume", actionTitle: "Details") {
                onDetail(ChartDetail(kind: .volume, range: range))
            }
            StatLine(lead: rangePhrase, items: [
                .init(value: Format.volume(summary.volume, unit: model.unit, includeUnit: false), label: model.unit.symbol),
                .init(value: "\(summary.workouts)", label: summary.workouts == 1 ? "workout" : "workouts"),
                .init(value: "\(summary.personalRecords)", label: summary.personalRecords == 1 ? "record" : "records")
            ])
            if let change = summary.volumeChange {
                Label("Volume \(Format.signedPercent(change)) \(range.comparisonLabel)",
                      systemImage: abs(change) < 0.0005 ? "minus" : (change > 0 ? "arrow.up.right" : "arrow.down.right"))
                    .font(VFont.fieldCaption.monospacedDigit())
                    .foregroundStyle(VColor.textSecondary)
            }
            PeriodBarChart(points: points, unit: range == .week ? .day : .weekOfYear,
                           valueFormatter: { Format.compact($0) },
                           accessibilityTitle: "Training volume in \(model.unit.symbol) per \(range == .week ? "day" : "week")")
                .padding(.top, Space.sm)
        }
    }

    private var rangePhrase: String {
        switch range {
        case .week: "Past 7 days"
        case .month: "Past month"
        case .threeMonths: "Past 3 months"
        case .sixMonths: "Past 6 months"
        case .year: "Past year"
        case .all: "All time"
        }
    }

    // MARK: Records

    private var records: some View {
        let records = Array(model.analytics.personalRecords(model.sessions).prefix(5))
        return VStack(alignment: .leading, spacing: 0) {
            CanvasTitle("Personal records")
                .padding(.bottom, Space.xxs)
            if records.isEmpty {
                Text("Beat a previous best weight or rep count and it shows up here.")
                    .font(VFont.secondary)
                    .foregroundStyle(VColor.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                ForEach(Array(records.enumerated()), id: \.element.id) { index, record in
                    if index > 0 { RowHairline() }
                    Button {
                        model.sheet = .exercise(record.exerciseID)
                    } label: {
                        HStack(alignment: .firstTextBaseline, spacing: Space.sm) {
                            Text(record.exerciseName)
                                .font(VFont.body)
                                .foregroundStyle(VColor.textPrimary)
                                .fixedSize(horizontal: false, vertical: true)
                            Spacer(minLength: Space.sm)
                            Text(record.weight > 0 ? "\(Format.weight(record.weight, unit: model.unit)) × \(record.reps)" : "\(record.reps) reps")
                                .font(VFont.data)
                                .foregroundStyle(VColor.textPrimary)
                            Image(systemName: Icon.chevron)
                                .font(.system(.footnote, weight: .semibold))
                                .foregroundStyle(VColor.textTertiary)
                                .accessibilityHidden(true)
                        }
                        .padding(.vertical, Space.sm)
                        .frame(minHeight: Size.minTouch + Space.xs)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityElement(children: .combine)
                    .accessibilityValue("\(record.improvementLabel(unit: model.unit)), "
                                        + Format.relativeDays(from: record.date, to: model.now(), calendar: model.calendar))
                    .accessibilityHint("Shows the exercise")
                }
            }
        }
    }

    // MARK: Estimated max (Pro)

    @ViewBuilder private var estimatedMax: some View {
        let exercises = model.analytics.trackedExercises(model.sessions).filter(\.isCompound)
        if let selected = strengthExerciseID.flatMap({ model.catalog[$0] }) ?? exercises.first {
            let points = model.analytics.strengthSeries(model.sessions, exerciseID: selected.id, range: range, now: model.now())
            VStack(alignment: .leading, spacing: Space.xs) {
                HStack(alignment: .firstTextBaseline, spacing: Space.sm) {
                    Text("Estimated max")
                        .font(VFont.canvasTitle)
                        .foregroundStyle(VColor.textPrimary)
                        .accessibilityAddTraits(.isHeader)
                    Spacer(minLength: Space.sm)
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
                        .foregroundStyle(VColor.accentText)
                        .frame(minHeight: Size.minTouch)
                    }
                    .accessibilityLabel("Exercise, \(selected.name)")
                }
                if let last = points.last {
                    (Text(Format.estimate(last.value, unit: model.unit, includeUnit: false))
                        .font(VFont.fieldStat)
                        .foregroundStyle(VColor.textPrimary)
                     + Text(" \(model.unit.symbol) estimated").font(VFont.secondary).foregroundStyle(VColor.textSecondary))
                        .accessibilityLabel("Latest estimated max \(Format.estimate(last.value, unit: model.unit))")
                }
                if points.count >= 2 {
                    EstimateLineChart(points: points, tint: WidgetTint.training.accent,
                                      valueFormatter: { Format.estimate($0, unit: model.unit) })
                        .padding(.top, Space.xs)
                    Button("Details") { onDetail(ChartDetail(kind: .strength(selected.id), range: range)) }
                        .buttonStyle(.borderless)
                        .font(VFont.secondaryEmphasized)
                        .foregroundStyle(VColor.accentText)
                        .frame(minHeight: Size.minTouch)
                        .accessibilityLabel("\(selected.name) estimated max data")
                } else {
                    Text("Log \(selected.name) a few more times to see a trend.")
                        .font(VFont.secondary)
                        .foregroundStyle(VColor.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Text("Estimated from your best set in each session. Not a tested max.")
                    .font(VFont.fieldCaption)
                    .foregroundStyle(VColor.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    // MARK: Muscles (Pro)

    private var muscleBalance: some View {
        let volumes = model.analytics.weeklySetsPerMuscle(model.sessions, now: model.now())
        return VStack(alignment: .leading, spacing: Space.sm) {
            CanvasTitle("Weekly sets per muscle")
            ForEach(volumes) { volume in MuscleVolumeRow(volume: volume) }
            HStack(alignment: .top, spacing: Space.xs) {
                RoundedRectangle(cornerRadius: 2).fill(VColor.chartTarget).frame(width: 14, height: 10)
                    .padding(.top, 3)
                    .accessibilityHidden(true)
                Text("10–20 hard sets per week is the evidence-based range for growth. Secondary muscles count as half a set.")
                    .font(VFont.fieldCaption)
                    .foregroundStyle(VColor.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.top, Space.xxs)
        }
    }
}

private struct MuscleVolumeRow: View {
    var volume: MuscleVolume
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    private let scaleMax: Double = 24

    var body: some View {
        Group {
            if dynamicTypeSize.isAccessibilitySize {
                VStack(alignment: .leading, spacing: Space.xxs) {
                    HStack { name; Spacer(); count; statusIcon }
                    bar
                }
            } else {
                HStack(spacing: Space.sm) {
                    name.frame(width: 92, alignment: .leading)
                    bar
                    count.frame(width: 36, alignment: .trailing)
                    statusIcon
                }
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(volume.muscle.displayName): \(Format.number1Trimmed(volume.sets)) sets, \(statusText)")
    }

    private var name: some View {
        Text(volume.muscle.displayName)
            .font(VFont.secondary)
            .foregroundStyle(VColor.textPrimary)
            .lineLimit(1)
            .minimumScaleFactor(0.8)
    }

    private var count: some View {
        Text(Format.number1Trimmed(volume.sets))
            .font(VFont.secondaryEmphasized.monospacedDigit())
            .foregroundStyle(VColor.textPrimary)
    }

    private var bar: some View {
        GeometryReader { proxy in
            let width = proxy.size.width
            ZStack(alignment: .leading) {
                Capsule().fill(VColor.track)
                Rectangle()
                    .fill(VColor.chartTarget)
                    .frame(width: width * (10 / scaleMax))
                    .offset(x: width * (10 / scaleMax))
                Capsule()
                    .fill(volume.status == .optimal ? VColor.accent : VColor.chartMuted)
                    .frame(width: max(width * min(volume.sets / scaleMax, 1), volume.sets > 0 ? 6 : 0))
            }
        }
        .frame(height: 8)
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

// MARK: - Consistency

/// Workouts per week against the plan's goal, then the last seven days on
/// the calorie target. On the plain ground.
private struct ConsistencySection: View {
    var range: TimeRange
    var onDetail: (ChartDetail) -> Void
    @Environment(AppModel.self) private var model

    var body: some View {
        let days = model.foodEntries.isEmpty ? [] : model.calorieTargetDays(count: 7)
        if !model.sessions.isEmpty || !days.isEmpty {
            VStack(alignment: .leading, spacing: Space.xs) {
                CanvasTitle("Consistency", actionTitle: model.sessions.isEmpty ? nil : "Details") {
                    onDetail(ChartDetail(kind: .frequency, range: range))
                }
                if !model.sessions.isEmpty { workouts }
                if !days.isEmpty {
                    calorieDays(days)
                        .padding(.top, model.sessions.isEmpty ? 0 : Space.lg)
                }
            }
            .padding(.horizontal, Space.fieldInset)
            .padding(.vertical, Space.lg)
            .frame(maxWidth: .infinity, alignment: .leading)
            .widgetSurface()
        }
    }

    private var workouts: some View {
        let points = model.analytics.frequencySeries(model.sessions, range: range, now: model.now())
        let total = Int(points.reduce(0) { $0 + $1.value })
        let goal = model.profile?.daysPerWeek ?? 4
        return VStack(alignment: .leading, spacing: Space.sm) {
            StatLine(items: [
                .init(value: "\(total)", label: "\(total == 1 ? "workout" : "workouts") in \(points.count) \(points.count == 1 ? "week" : "weeks")"),
                .init(value: "\(goal)", label: "a week planned")
            ])
            PeriodBarChart(points: points, unit: .weekOfYear, valueFormatter: { Format.integer($0) },
                           goal: Double(goal), goalLabel: "Goal", accessibilityTitle: "Workouts per week", height: 120)
                .padding(.top, Space.xs)
        }
    }

    private func calorieDays(_ days: [DayTargetStrip.Day]) -> some View {
        let hit = days.filter { $0.status == .onTarget }.count
        return VStack(alignment: .leading, spacing: Space.sm) {
            HStack(alignment: .firstTextBaseline) {
                Text("Days on calorie target")
                    .font(VFont.headline)
                    .foregroundStyle(VColor.textPrimary)
                    .accessibilityAddTraits(.isHeader)
                Spacer(minLength: Space.sm)
                Text("\(hit) of \(days.count)")
                    .font(VFont.macroValue)
                    .foregroundStyle(VColor.textPrimary)
            }
            .accessibilityElement(children: .combine)
            DayTargetStrip(days: days, calendar: model.calendar)
            Text("On target is within 10% of your calorie target. Days under 800 kcal count as not fully logged (dashed).")
                .font(VFont.fieldCaption)
                .foregroundStyle(VColor.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

// MARK: - Chart block

/// A chart on the open canvas: title, subtitle, optional accessory and a
/// "Details" action, then the chart. No container.
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
            HStack(alignment: .firstTextBaseline, spacing: Space.sm) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(VFont.headline)
                        .foregroundStyle(VColor.textPrimary)
                        .accessibilityAddTraits(.isHeader)
                    Text(subtitle)
                        .font(VFont.fieldCaption)
                        .foregroundStyle(VColor.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: Space.xs)
                accessory
                if let onExpand {
                    Button("Details", action: onExpand)
                        .buttonStyle(.borderless)
                        .font(VFont.secondaryEmphasized)
                        .foregroundStyle(VColor.accentText)
                        .frame(minHeight: Size.minTouch)
                        .accessibilityLabel("\(title) details")
                }
            }
            content
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

extension Format {
    static func number1Trimmed(_ value: Double) -> String {
        value.rounded() == value ? String(Int(value)) : String(format: "%.1f", value)
    }
}

#Preview("Progress · Pro") {
    ProgressDashboardView().environment(AppModel.preview(pro: true))
}

#Preview("Progress · Free · Dark") {
    ProgressDashboardView().environment(AppModel.preview()).preferredColorScheme(.dark)
}

#Preview("Progress · Empty") {
    ProgressDashboardView().environment(AppModel.preview(empty: true))
}
