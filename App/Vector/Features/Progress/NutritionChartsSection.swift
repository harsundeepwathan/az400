import Charts
import SwiftUI
import VectorCore

/// Calories and protein against target, from logged days only: an unlogged
/// day is a gap on the chart, never a zero bar. Protein adherence is days
/// on target over days logged, next to the current streak.
struct NutritionChartsSection: View {
    @Environment(AppModel.self) private var model
    @State private var range: TimeRange = .month
    @State private var detail: NutritionChartDetail?

    var body: some View {
        if let targets = model.nutritionTargets, !model.foodEntries.isEmpty {
            let engine = NutritionChartEngine(calendar: model.calendar)
            let now = model.now()
            let series = engine.series(model.foodEntries, targets: targets, range: range, now: now)
            let adherence = engine.proteinAdherence(model.foodEntries, targets: targets, range: range, now: now)

            VStack(alignment: .leading, spacing: Space.sm) {
                SectionHeader("Nutrition")
                NutritionRangePicker(selection: $range)

                LazyVGrid(columns: [GridItem(.flexible(), spacing: Space.sm), GridItem(.flexible())], spacing: Space.sm) {
                    MetricCard(label: "Protein days on target",
                               value: adherence.daysLogged > 0 ? "\(adherence.daysHit) of \(adherence.daysLogged)" : "No days logged",
                               symbol: "checkmark.circle")
                    MetricCard(label: "Protein streak", value: "\(adherence.streak)",
                               unit: adherence.streak == 1 ? "day" : "days", symbol: Icon.flame)
                }

                ForEach(NutritionMetric.allCases) { metric in
                    ChartCard(title: metric.title, subtitle: metric.subtitle(range: range, targets: targets),
                              onExpand: series.isEmpty ? nil : { detail = NutritionChartDetail(metric: metric, range: range) }) {
                        if series.isEmpty {
                            Text("No meals logged in this period.")
                                .font(VFont.secondary)
                                .foregroundStyle(VColor.textSecondary)
                                .frame(maxWidth: .infinity, minHeight: 120)
                        } else {
                            NutritionBarChart(series: series, metric: metric)
                        }
                    }
                }

                Text("Days without a logged meal are left blank, not counted as zero. Targets are your current targets.")
                    .font(VFont.caption)
                    .foregroundStyle(VColor.textTertiary)
                    .padding(.horizontal, Space.xxs)
            }
            .animation(Motion.smooth, value: range)
            .sheet(item: $detail) { NutritionChartDetailView(detail: $0) }
        }
    }
}

// MARK: - Metric

enum NutritionMetric: String, CaseIterable, Identifiable, Hashable {
    case calories, protein

    var id: String { rawValue }

    var title: String {
        switch self {
        case .calories: "Calories"
        case .protein: "Protein"
        }
    }

    /// Calories are orange (`VColor.calories`); protein keeps its macro colour.
    var color: Color {
        switch self {
        case .calories: VColor.calories
        case .protein: VColor.protein
        }
    }

    func value(_ bucket: NutritionBucket) -> Double {
        switch self {
        case .calories: bucket.calories
        case .protein: bucket.protein
        }
    }

    func target(_ targets: NutritionTargets) -> Double {
        switch self {
        case .calories: targets.calories
        case .protein: targets.protein
        }
    }

    func format(_ value: Double) -> String {
        switch self {
        case .calories: "\(Format.integer(value)) kcal"
        case .protein: Format.grams(value)
        }
    }

    func subtitle(range: TimeRange, targets: NutritionTargets) -> String {
        let per = range.bucket == .day ? "Daily total" : "Weekly average of logged days"
        return "\(per) · target \(format(target(targets)))"
    }
}

struct NutritionChartDetail: Identifiable, Hashable {
    var metric: NutritionMetric
    var range: TimeRange
    var id: String { "\(metric.rawValue)-\(range.rawValue)" }
}

// MARK: - Range picker

/// 7D · 1M · 3M. Same look as the dashboard's `RangePicker`, limited to the
/// ranges nutrition charts support (all free).
struct NutritionRangePicker: View {
    @Binding var selection: TimeRange

    var body: some View {
        HStack(spacing: 2) {
            ForEach(NutritionChartEngine.ranges) { range in
                Button {
                    withAnimation(Motion.snappy) { selection = range }
                } label: {
                    Text(range.label)
                        .font(VFont.captionEmphasized.monospacedDigit())
                        .foregroundStyle(selection == range ? VColor.textPrimary : VColor.textSecondary)
                        .frame(maxWidth: .infinity, minHeight: 32)
                        .background {
                            if selection == range {
                                RoundedRectangle(cornerRadius: Radius.xs, style: .continuous).fill(VColor.surface)
                            }
                        }
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(range.label)
                .accessibilityAddTraits(selection == range ? .isSelected : [])
            }
        }
        .padding(3)
        .background(VColor.surfaceSunken, in: RoundedRectangle(cornerRadius: Radius.sm, style: .continuous))
        .frame(minHeight: Size.minTouch)
        .sensoryFeedback(.selection, trigger: selection)
    }
}

// MARK: - Chart

/// Bars for logged buckets only, on an axis spanning the whole range so
/// missing days stay visible as gaps, with the target as a dashed rule.
struct NutritionBarChart: View {
    var series: NutritionSeries
    var metric: NutritionMetric
    var height: CGFloat = 160

    @State private var selectedDate: Date?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var target: Double { metric.target(series.targets) }

    private var selected: NutritionBucket? {
        guard let selectedDate else { return nil }
        return series.buckets.min { abs($0.date.timeIntervalSince(selectedDate)) < abs($1.date.timeIntervalSince(selectedDate)) }
    }

    var body: some View {
        Chart {
            ForEach(series.buckets) { bucket in
                BarMark(x: .value("Date", bucket.date, unit: series.bucket),
                        y: .value(metric.title, metric.value(bucket)),
                        width: .ratio(0.62))
                    .foregroundStyle(selected == nil || selected?.id == bucket.id ? metric.color : VColor.chartMuted)
                    .cornerRadius(4, style: .continuous)
            }
            RuleMark(y: .value("Target", target))
                .foregroundStyle(VColor.textTertiary)
                .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 3]))
                .annotation(position: .top, alignment: .leading, spacing: 2) {
                    Text("Target")
                        .font(.system(.caption2))
                        .foregroundStyle(VColor.textTertiary)
                }
            if let selected {
                RuleMark(x: .value("Selected", selected.date, unit: series.bucket))
                    .foregroundStyle(VColor.textTertiary.opacity(0.5))
                    .lineStyle(StrokeStyle(lineWidth: 1))
                    .annotation(position: .top, spacing: 4, overflowResolution: .init(x: .fit(to: .chart), y: .disabled)) {
                        ChartTooltip(title: NutritionChartText.bucketTitle(selected, component: series.bucket),
                                     value: metric.format(metric.value(selected)))
                    }
            }
        }
        .chartXScale(domain: series.interval.start...series.interval.end)
        .chartYScale(domain: .automatic(includesZero: true))
        .chartXAxis {
            AxisMarks(values: .automatic(desiredCount: 4)) { _ in
                AxisValueLabel(format: .dateTime.day().month(.abbreviated))
                    .font(.system(.caption2))
                    .foregroundStyle(VColor.textTertiary)
            }
        }
        .chartYAxis {
            AxisMarks(position: .trailing, values: .automatic(desiredCount: 3)) { value in
                AxisGridLine(stroke: StrokeStyle(lineWidth: 0.5, dash: [2, 3]))
                    .foregroundStyle(VColor.chartGrid)
                AxisValueLabel {
                    if let number = value.as(Double.self) {
                        Text(metric == .calories ? Format.compact(number) : Format.grams(number))
                            .font(.system(.caption2).monospacedDigit())
                            .foregroundStyle(VColor.textTertiary)
                    }
                }
            }
        }
        .chartXSelection(value: $selectedDate)
        .frame(height: height)
        .animation(Motion.adaptive(Motion.chart, reduceMotion: reduceMotion), value: series)
        .sensoryFeedback(.selection, trigger: selected?.id)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(NutritionChartText.summary(series, metric: metric))
    }
}

enum NutritionChartText {
    static func bucketTitle(_ bucket: NutritionBucket, component: Calendar.Component) -> String {
        guard component != .day else { return Format.shortDate(bucket.date) }
        return "Week of \(Format.shortDate(bucket.date)) · \(bucket.loggedDays) \(bucket.loggedDays == 1 ? "day" : "days") logged"
    }

    static func summary(_ series: NutritionSeries, metric: NutritionMetric) -> String {
        let values = series.buckets.map(metric.value)
        guard !values.isEmpty else { return "\(metric.title): no meals logged in this period." }
        let days = series.buckets.reduce(0) { $0 + $1.loggedDays }
        let average = values.reduce(0, +) / Double(values.count)
        return "\(metric.title) on \(days) logged \(days == 1 ? "day" : "days"). "
            + "Average \(metric.format(average)) against a target of \(metric.format(metric.target(series.targets)))."
    }
}

// MARK: - Detail

/// Full-height chart plus the logged values as a table.
struct NutritionChartDetailView: View {
    @State var detail: NutritionChartDetail
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                if let targets = model.nutritionTargets {
                    let series = NutritionChartEngine(calendar: model.calendar)
                        .series(model.foodEntries, targets: targets, range: detail.range, now: model.now())
                    Section {
                        NutritionRangePicker(selection: $detail.range)
                            .listRowInsets(EdgeInsets(top: Space.sm, leading: Space.md, bottom: Space.sm, trailing: Space.md))
                        NutritionBarChart(series: series, metric: detail.metric, height: 260)
                            .padding(.vertical, Space.sm)
                    }
                    Section {
                        if series.isEmpty {
                            Text("No meals logged in this period.").foregroundStyle(VColor.textSecondary)
                        }
                        ForEach(series.buckets.reversed()) { bucket in
                            HStack {
                                Text(NutritionChartText.bucketTitle(bucket, component: series.bucket))
                                    .foregroundStyle(VColor.textSecondary)
                                Spacer()
                                Text(detail.metric.format(detail.metric.value(bucket))).font(VFont.data)
                            }
                            .accessibilityElement(children: .combine)
                        }
                    } header: {
                        Text("Logged days")
                    } footer: {
                        Text("Target \(detail.metric.format(detail.metric.target(targets))). Days without a logged meal are not shown.")
                    }
                }
            }
            .navigationTitle(detail.metric.title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        }
    }
}
