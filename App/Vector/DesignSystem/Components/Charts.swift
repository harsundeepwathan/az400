import Charts
import SwiftUI
import VectorCore

/// Range selector (7D · 1M · 3M · 6M · 1Y · ALL). Locked ranges show a
/// lock glyph and route to the paywall instead of silently doing nothing.
struct RangePicker: View {
    @Binding var selection: TimeRange
    var isLocked: (TimeRange) -> Bool = { _ in false }
    var onLockedTap: () -> Void = {}
    @Namespace private var namespace

    var body: some View {
        HStack(spacing: 2) {
            ForEach(TimeRange.allCases) { range in
                let locked = isLocked(range)
                Button {
                    if locked {
                        onLockedTap()
                    } else {
                        withAnimation(Motion.snappy) { selection = range }
                    }
                } label: {
                    HStack(spacing: 2) {
                        Text(range.label)
                        if locked { Image(systemName: Icon.lock).imageScale(.small) }
                    }
                    .font(VFont.captionEmphasized.monospacedDigit())
                    .foregroundStyle(selection == range ? VColor.textPrimary : VColor.textSecondary)
                    .frame(maxWidth: .infinity, minHeight: 32)
                    .background {
                        if selection == range {
                            RoundedRectangle(cornerRadius: Radius.xs, style: .continuous)
                                .fill(VColor.surface)
                                .shadow(color: .black.opacity(0.08), radius: 2, y: 1)
                                .matchedGeometryEffect(id: "range", in: namespace)
                        }
                    }
                }
                .buttonStyle(.plain)
                .accessibilityLabel(range.label + (locked ? ", Pro" : ""))
                .accessibilityAddTraits(selection == range ? .isSelected : [])
            }
        }
        .padding(3)
        .background(VColor.surfaceSunken, in: RoundedRectangle(cornerRadius: Radius.sm, style: .continuous))
        .sensoryFeedback(.selection, trigger: selection)
    }
}

/// Chart kinds the app uses. One measure per chart, one axis, always.
enum ProgressChartStyle {
    case bars
    case line
    /// Raw points plus a smoothed trend line (body weight).
    case trend(smoothed: [ChartPoint])
}

/// Wrapper over Swift Charts with the app's mark specs: thin marks, rounded
/// bar ends, recessive grid, a scrub-to-inspect selection and an
/// accessibility summary.
struct ProgressChart: View {
    var points: [ChartPoint]
    var style: ProgressChartStyle
    var unit: Calendar.Component = .day
    var valueFormatter: (Double) -> String = { Format.compact($0) }
    var height: CGFloat = 160
    var target: ClosedRange<Double>?
    var showsSelection = true

    @State private var selectedDate: Date?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var selectedPoint: ChartPoint? {
        guard let selectedDate else { return nil }
        return points.min { abs($0.date.timeIntervalSince(selectedDate)) < abs($1.date.timeIntervalSince(selectedDate)) }
    }

    var body: some View {
        Chart {
            if let target {
                RectangleMark(yStart: .value("Low", target.lowerBound), yEnd: .value("High", target.upperBound))
                    .foregroundStyle(VColor.chartTarget)
            }
            ForEach(points) { point in
                switch style {
                case .bars:
                    BarMark(x: .value("Date", point.date, unit: unit), y: .value("Value", point.value), width: .ratio(0.62))
                        .foregroundStyle(selectedPoint == nil || selectedPoint?.id == point.id ? VColor.chartPrimary : VColor.chartMuted)
                        .cornerRadius(4, style: .continuous)
                case .line:
                    LineMark(x: .value("Date", point.date), y: .value("Value", point.value))
                        .foregroundStyle(VColor.chartPrimary)
                        .lineStyle(StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
                        .interpolationMethod(.monotone)
                    PointMark(x: .value("Date", point.date), y: .value("Value", point.value))
                        .foregroundStyle(VColor.chartPrimary)
                        .symbolSize(points.count > 24 ? 0 : 28)
                case .trend:
                    PointMark(x: .value("Date", point.date), y: .value("Value", point.value))
                        .foregroundStyle(VColor.chartMuted)
                        .symbolSize(18)
                }
            }
            if case .trend(let smoothed) = style {
                ForEach(smoothed) { point in
                    LineMark(x: .value("Date", point.date), y: .value("Trend", point.value))
                        .foregroundStyle(VColor.chartPrimary)
                        .lineStyle(StrokeStyle(lineWidth: 2, lineCap: .round))
                        .interpolationMethod(.monotone)
                }
            }
            if let selectedPoint, showsSelection {
                RuleMark(x: .value("Selected", selectedPoint.date, unit: isBars ? unit : .day))
                    .foregroundStyle(VColor.textTertiary.opacity(0.5))
                    .lineStyle(StrokeStyle(lineWidth: 1))
                    .annotation(position: .top, spacing: 4, overflowResolution: .init(x: .fit(to: .chart), y: .disabled)) {
                        ChartTooltip(title: Format.shortDate(selectedPoint.date), value: valueFormatter(selectedPoint.value))
                    }
            }
        }
        .chartYScale(domain: .automatic(includesZero: isBars))
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
                        Text(valueFormatter(number))
                            .font(.system(.caption2).monospacedDigit())
                            .foregroundStyle(VColor.textTertiary)
                    }
                }
            }
        }
        .chartXSelection(value: showsSelection ? $selectedDate : .constant(nil))
        .frame(height: height)
        .animation(Motion.adaptive(Motion.chart, reduceMotion: reduceMotion), value: points)
        .sensoryFeedback(.selection, trigger: selectedPoint?.id)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilitySummary)
    }

    private var isBars: Bool {
        if case .bars = style { return true }
        return false
    }

    private var accessibilitySummary: String {
        guard let first = points.first, let last = points.last else { return "No data" }
        let maxValue = points.map(\.value).max() ?? 0
        return "\(points.count) data points from \(Format.shortDate(first.date)) to \(Format.shortDate(last.date)). "
            + "Latest \(valueFormatter(last.value)), highest \(valueFormatter(maxValue))."
    }
}

struct ChartTooltip: View {
    var title: String
    var value: String

    var body: some View {
        VStack(spacing: 1) {
            Text(value).font(VFont.captionEmphasized.monospacedDigit()).foregroundStyle(VColor.textPrimary)
            Text(title).font(.system(.caption2)).foregroundStyle(VColor.textSecondary)
        }
        .padding(.horizontal, Space.xs)
        .padding(.vertical, 4)
        .background(VColor.surfaceRaised, in: RoundedRectangle(cornerRadius: Radius.xs, style: .continuous))
        .shadow(color: .black.opacity(0.1), radius: 6, y: 2)
    }
}

/// Small inline sparkline for rows (exercise history, PR list).
struct Sparkline: View {
    var values: [Double]
    var tint: Color = VColor.chartPrimary

    var body: some View {
        Chart(Array(values.enumerated()), id: \.offset) { item in
            LineMark(x: .value("i", item.offset), y: .value("v", item.element))
                .foregroundStyle(tint)
                .lineStyle(StrokeStyle(lineWidth: 1.5, lineCap: .round))
                .interpolationMethod(.monotone)
        }
        .chartXAxis(.hidden)
        .chartYAxis(.hidden)
        .chartYScale(domain: .automatic(includesZero: false))
        .accessibilityHidden(true)
    }
}
