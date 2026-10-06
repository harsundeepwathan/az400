import Charts
import SwiftUI
import VectorCore

// Fields building blocks for the Nutrition and Progress screens: the hero
// number, thin capsule bars, the in-field range picker, open-canvas titles
// and rows, honest Pro rows, and the Swift Charts marks from the screen
// notes (weight dots + trend, bars with the current period in accent,
// estimated max line).

// MARK: - Metrics

enum FieldMetric {
    /// The screen's hero number ("660 kcal left"), scaled with Dynamic Type
    /// via `@ScaledMetric(relativeTo: .largeTitle)`.
    static let heroNumber: CGFloat = 48
    /// Thin capsule bars in a field (calories, macros).
    static let barHeight: CGFloat = 6
    /// Leading icon column for push rows.
    static let rowIcon: CGFloat = 28
}

extension VFont {
    /// Rounded bold tabular numerals at a scaled size (see `FieldMetric.heroNumber`).
    static func fieldHero(_ size: CGFloat) -> Font {
        .system(size: size, weight: .bold, design: .rounded).monospacedDigit()
    }

    /// Open-canvas section title ("Consistency", "Breakfast"): 22 pt bold.
    static let canvasTitle = Font.system(.title2, design: .default, weight: .bold)
}

// MARK: - Bar

/// Thin capsule bar on a track. Fills in on appear and on change; sets
/// instantly under Reduce Motion. Past 100% it stays full (the number beside
/// it carries the overshoot).
struct FieldBar: View {
    var progress: Double
    var tint: Color
    var track: Color = VColor.track
    var height: CGFloat = FieldMetric.barHeight
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var shown: Double = 0

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Capsule().fill(track)
                Capsule()
                    .fill(tint)
                    .frame(width: max(proxy.size.width * min(max(shown, 0), 1), shown > 0 ? height : 0))
            }
        }
        .frame(height: height)
        .onAppear { set(progress, animation: Motion.gentle) }
        .onChange(of: progress) { _, value in set(value, animation: Motion.smooth) }
        .accessibilityHidden(true)
    }

    private func set(_ value: Double, animation: Animation) {
        if reduceMotion { shown = value } else { withAnimation(animation) { shown = value } }
    }
}

/// One full-width macro row in the nutrition field: dot and name, value
/// over target on the right, then a thin bar.
struct MacroRow: View {
    var title: String
    var consumed: Double
    var target: Double
    var tint: Color
    var unit = "g"

    var body: some View {
        VStack(alignment: .leading, spacing: Space.xs) {
            HStack(alignment: .firstTextBaseline, spacing: Space.xs) {
                HStack(spacing: 6) {
                    Circle().fill(tint).frame(width: 8, height: 8)
                    Text(title)
                        .font(VFont.secondaryEmphasized)
                        .foregroundStyle(VColor.textPrimary)
                }
                Spacer(minLength: Space.xs)
                (Text(Format.integer(consumed)).font(VFont.macroValue).foregroundStyle(VColor.textPrimary)
                    + Text(" / \(Format.integer(target)) \(unit)").font(VFont.fieldCaption.monospacedDigit())
                    .foregroundStyle(VColor.textSecondary))
                    .lineLimit(1)
                    .contentTransition(.numericText())
            }
            FieldBar(progress: target > 0 ? consumed / target : 0, tint: tint)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(title)
        .accessibilityValue("\(Format.integer(consumed)) of \(Format.integer(target)) \(unit == "g" ? "grams" : unit)")
    }
}

// MARK: - Range picker

/// Segmented range control that sits inside a field: a track tinted with
/// the field's ink at 10%, the selected segment on the ground colour.
/// Locked ranges show a lock and call `onLockedTap` (the paywall) instead of
/// silently doing nothing.
struct FieldRangePicker: View {
    var ranges: [TimeRange] = TimeRange.allCases
    @Binding var selection: TimeRange
    var tint: Color = VColor.textPrimary
    var isLocked: (TimeRange) -> Bool = { _ in false }
    var onLockedTap: () -> Void = {}
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Namespace private var namespace

    var body: some View {
        HStack(spacing: 2) {
            ForEach(ranges) { range in
                let locked = isLocked(range)
                let selected = selection == range
                Button {
                    if locked {
                        onLockedTap()
                    } else if !selected {
                        withAnimation(Motion.adaptive(Motion.snappy, reduceMotion: reduceMotion)) { selection = range }
                    }
                } label: {
                    HStack(spacing: 3) {
                        Text(range.label)
                        if locked {
                            Image(systemName: Icon.lock)
                                .imageScale(.small)
                                .accessibilityHidden(true)
                        }
                    }
                    .font(VFont.captionEmphasized.monospacedDigit())
                    .foregroundStyle(selected ? VColor.textPrimary : VColor.textSecondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                    .frame(maxWidth: .infinity, minHeight: Size.minTouch - 4)
                    .background {
                        if selected {
                            Capsule()
                                .fill(VColor.surfaceRaised)
                                .matchedGeometryEffect(id: "selection", in: namespace)
                        }
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(range.label)
                .accessibilityValue(locked ? "Pro" : "")
                .accessibilityHint(locked ? "Opens Vector Pro" : "")
                .accessibilityAddTraits(selected ? .isSelected : [])
            }
        }
        .padding(2)
        .background(tint.opacity(0.10), in: Capsule())
        .sensoryFeedback(.selection, trigger: selection)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Range")
    }
}

// MARK: - Canvas title and rows

/// A sentence-case section title on the open canvas or inside a field, with
/// an optional trailing text action ("See all").
struct CanvasTitle: View {
    var title: String
    var font: Font = VFont.canvasTitle
    var actionTitle: String?
    var action: (() -> Void)?

    init(_ title: String, font: Font = VFont.canvasTitle, actionTitle: String? = nil, action: (() -> Void)? = nil) {
        self.title = title
        self.font = font
        self.actionTitle = actionTitle
        self.action = action
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: Space.sm) {
            Text(title)
                .font(font)
                .foregroundStyle(VColor.textPrimary)
                .accessibilityAddTraits(.isHeader)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: Space.sm)
            if let actionTitle, let action {
                Button(actionTitle, action: action)
                    .buttonStyle(.borderless)
                    .font(VFont.secondaryEmphasized)
                    .foregroundStyle(VColor.accentText)
                    .frame(minHeight: Size.minTouch)
            }
        }
    }
}

/// Hairline inset to the text edge, tinted for the surface it sits on.
struct RowHairline: View {
    var leading: CGFloat = 0
    var color: Color = VColor.separator

    var body: some View {
        Rectangle()
            .fill(color)
            .frame(height: 0.5)
            .padding(.leading, leading)
            .accessibilityHidden(true)
    }
}

/// Push row label: optional leading symbol in a tint, title, trailing detail
/// and a chevron. Wrap it in a `NavigationLink` or `Button`.
struct FieldRowLabel: View {
    var symbol: String?
    var tint: Color = VColor.textSecondary
    var title: String
    var detail: String?

    var body: some View {
        HStack(spacing: Space.sm) {
            if let symbol {
                Image(systemName: symbol)
                    .font(.system(.body, weight: .regular))
                    .foregroundStyle(tint)
                    .frame(width: FieldMetric.rowIcon)
                    .accessibilityHidden(true)
            }
            Text(title)
                .font(VFont.body)
                .foregroundStyle(VColor.textPrimary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: Space.sm)
            if let detail {
                Text(detail)
                    .font(VFont.secondary.monospacedDigit())
                    .foregroundStyle(VColor.textSecondary)
                    .multilineTextAlignment(.trailing)
            }
            Image(systemName: Icon.chevron)
                .font(.system(.footnote, weight: .semibold))
                .foregroundStyle(VColor.textTertiary)
                .accessibilityHidden(true)
        }
        .padding(.vertical, Space.sm)
        .frame(minHeight: Size.minTouch + Space.xs)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
    }
}

/// A Pro feature described in place, with no fake or blurred content: what
/// it does, then an outlined capsule to see the plan.
struct FieldLockedRow: View {
    var title: String
    var message: String
    var onUnlock: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: Space.xs) {
            HStack(alignment: .firstTextBaseline, spacing: Space.xs) {
                Text(title)
                    .font(VFont.bodyEmphasized)
                    .foregroundStyle(VColor.textPrimary)
                    .fixedSize(horizontal: false, vertical: true)
                ProBadge()
            }
            .accessibilityElement(children: .combine)
            Text(message)
                .font(VFont.secondary)
                .foregroundStyle(VColor.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            Button("See what's included", action: onUnlock)
                .buttonStyle(.outlinedCapsule)
                .padding(.top, Space.xxs)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// "**12** workouts · **74,250** kg · **4** records": rounded bold values with
/// secondary units, on one line that wraps at large text sizes.
struct StatLine: View {
    struct Item: Hashable {
        var value: String
        var label: String
    }

    var lead: String?
    var items: [Item]

    var body: some View {
        line
            .fixedSize(horizontal: false, vertical: true)
            .accessibilityLabel(spoken)
    }

    private var line: Text {
        var text = secondary(lead.map { $0 + " " } ?? "")
        for (index, item) in items.enumerated() {
            if index > 0 { text = text + secondary(" · ") }
            let value: Text = Text(item.value).font(VFont.macroValue).foregroundStyle(VColor.textPrimary)
            text = text + value
            text = text + secondary(" " + item.label)
        }
        return text
    }

    private func secondary(_ string: String) -> Text {
        Text(string).font(VFont.secondary).foregroundStyle(VColor.textSecondary)
    }

    private var spoken: String {
        ((lead.map { [$0] } ?? []) + items.map { "\($0.value) \($0.label)" }).joined(separator: ", ")
    }
}

// MARK: - Charts

/// Body weight: weigh-ins as faint dots, the smoothed trend as a line, and
/// the latest trend value emphasised. The trend line only draws from three
/// weigh-ins; with fewer it says so instead of inventing a line.
struct WeightTrendChart: View {
    var points: [ChartPoint]
    var trend: [ChartPoint]
    var tint: Color
    var valueFormatter: (Double) -> String
    var height: CGFloat = 170

    @State private var selectedDate: Date?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var showsTrend: Bool { points.count >= 3 && trend.count >= 2 }

    private var selected: ChartPoint? {
        guard let selectedDate else { return nil }
        return points.min { abs($0.date.timeIntervalSince(selectedDate)) < abs($1.date.timeIntervalSince(selectedDate)) }
    }

    var body: some View {
        Chart {
            ForEach(points) { point in
                PointMark(x: .value("Date", point.date), y: .value("Weight", point.value))
                    .foregroundStyle(tint.opacity(0.3))
                    .symbolSize(30)
            }
            if showsTrend {
                ForEach(trend) { point in
                    LineMark(x: .value("Date", point.date), y: .value("Trend", point.value))
                        .foregroundStyle(tint)
                        .lineStyle(StrokeStyle(lineWidth: 2.5, lineCap: .round, lineJoin: .round))
                        .interpolationMethod(.monotone)
                }
                if let last = trend.last {
                    PointMark(x: .value("Date", last.date), y: .value("Trend", last.value))
                        .foregroundStyle(tint)
                        .symbolSize(60)
                }
            }
            if let selected {
                RuleMark(x: .value("Selected", selected.date))
                    .foregroundStyle(VColor.textTertiary.opacity(0.5))
                    .lineStyle(StrokeStyle(lineWidth: 1))
                    .annotation(position: .top, spacing: 4, overflowResolution: .init(x: .fit(to: .chart), y: .disabled)) {
                        ChartTooltip(title: Format.shortDate(selected.date), value: valueFormatter(selected.value))
                    }
            }
        }
        .chartYScale(domain: domain)
        .chartXAxis {
            AxisMarks(values: .automatic(desiredCount: 5)) { _ in
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
        .chartXSelection(value: $selectedDate)
        .frame(height: height)
        .animation(Motion.adaptive(Motion.chart, reduceMotion: reduceMotion), value: points)
        .sensoryFeedback(.selection, trigger: selected?.id)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Body weight chart")
        .accessibilityValue(summary)
    }

    private var domain: ClosedRange<Double> {
        let values = (points + (showsTrend ? trend : [])).map(\.value)
        guard let low = values.min(), let high = values.max() else { return 0...1 }
        let pad = max((high - low) * 0.15, 0.3)
        return (low - pad)...(high + pad)
    }

    private var summary: String {
        guard let first = points.first, let last = points.last else { return "No weigh-ins in this range" }
        var text = "\(points.count) weigh-ins from \(Format.shortDate(first.date)) to \(Format.shortDate(last.date)). "
            + "Latest \(valueFormatter(last.value))."
        if showsTrend, let trendLast = trend.last { text += " Trend \(valueFormatter(trendLast.value))." }
        return text
    }
}

/// Bars per period with the highlighted one (the current period, or the
/// one being inspected) in accent and the rest muted. Up to eight bars carry
/// their value above; denser ranges show it on scrub. An optional dashed
/// goal rule sits behind them.
struct PeriodBarChart: View {
    var points: [ChartPoint]
    var unit: Calendar.Component
    var valueFormatter: (Double) -> String
    var goal: Double?
    var goalLabel: String = "Goal"
    var accessibilityTitle: String
    var height: CGFloat = 150

    @State private var selectedDate: Date?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var showsValues: Bool { points.count <= 8 }

    private var selected: ChartPoint? {
        guard let selectedDate else { return nil }
        // The bar whose period contains the scrub position.
        return points.last { $0.date <= selectedDate } ?? points.first
    }

    private var highlighted: ChartPoint? { selected ?? points.last }

    /// Label every bar when there are few; otherwise thin the axis out.
    private var labelStride: Int { max(1, Int((Double(points.count) / 5).rounded(.up))) }

    var body: some View {
        Chart {
            if let goal {
                RuleMark(y: .value(goalLabel, goal))
                    .foregroundStyle(VColor.textTertiary)
                    .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 3]))
            }
            ForEach(points) { point in
                let isHighlighted = point.id == highlighted?.id
                if showsValues {
                    BarMark(x: .value("Period", point.date, unit: unit), y: .value("Value", point.value), width: .ratio(0.78))
                        .foregroundStyle(isHighlighted ? VColor.accent : VColor.chartMuted)
                        .cornerRadius(4, style: .continuous)
                        .annotation(position: .top, alignment: .center, spacing: 4) {
                            Text(valueFormatter(point.value))
                                .font(VFont.caption.monospacedDigit().weight(isHighlighted ? .bold : .semibold))
                                .foregroundStyle(isHighlighted ? VColor.textPrimary : VColor.textSecondary)
                        }
                } else {
                    BarMark(x: .value("Period", point.date, unit: unit), y: .value("Value", point.value), width: .ratio(0.7))
                        .foregroundStyle(isHighlighted ? VColor.accent : VColor.chartMuted)
                        .cornerRadius(3, style: .continuous)
                }
            }
            if !showsValues, let selected {
                RuleMark(x: .value("Selected", selected.date, unit: unit))
                    .foregroundStyle(.clear)
                    .annotation(position: .top, spacing: 2, overflowResolution: .init(x: .fit(to: .chart), y: .disabled)) {
                        ChartTooltip(title: Format.shortDate(selected.date), value: valueFormatter(selected.value))
                    }
            }
        }
        .chartYScale(domain: 0...yMax)
        .chartYAxis(.hidden)
        .chartXAxis {
            AxisMarks(values: .stride(by: unit, count: labelStride)) { _ in
                AxisValueLabel(format: .dateTime.day().month(.abbreviated), centered: labelStride == 1)
                    .font(.system(.caption2))
                    .foregroundStyle(VColor.textTertiary)
            }
        }
        .chartXSelection(value: $selectedDate)
        .frame(height: height)
        .animation(Motion.adaptive(Motion.chart, reduceMotion: reduceMotion), value: points)
        .sensoryFeedback(.selection, trigger: selected?.id)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityTitle)
        .accessibilityValue(summary)
    }

    /// Headroom for the value labels and the goal rule.
    private var yMax: Double {
        let top = max(points.map(\.value).max() ?? 0, goal ?? 0)
        return top > 0 ? top * (showsValues ? 1.22 : 1.08) : 1
    }

    private var summary: String {
        guard let first = points.first, let last = points.last else { return "No data" }
        var text = "\(points.count) periods from \(Format.shortDate(first.date)) to \(Format.shortDate(last.date)). "
            + "Current \(valueFormatter(last.value))."
        if let goal { text += " \(goalLabel) \(valueFormatter(goal))." }
        return text
    }
}

/// Estimated max per session: a line with points. Labelled as an estimate
/// by the caller.
struct EstimateLineChart: View {
    var points: [ChartPoint]
    var tint: Color
    var valueFormatter: (Double) -> String
    var height: CGFloat = 150

    @State private var selectedDate: Date?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var selected: ChartPoint? {
        guard let selectedDate else { return nil }
        return points.min { abs($0.date.timeIntervalSince(selectedDate)) < abs($1.date.timeIntervalSince(selectedDate)) }
    }

    var body: some View {
        Chart {
            ForEach(points) { point in
                LineMark(x: .value("Date", point.date), y: .value("Estimated max", point.value))
                    .foregroundStyle(tint)
                    .lineStyle(StrokeStyle(lineWidth: 2.5, lineCap: .round, lineJoin: .round))
                    .interpolationMethod(.monotone)
                PointMark(x: .value("Date", point.date), y: .value("Estimated max", point.value))
                    .foregroundStyle(point.id == points.last?.id ? tint : tint.opacity(0.55))
                    .symbolSize(point.id == points.last?.id ? 60 : 24)
            }
            if let selected {
                RuleMark(x: .value("Selected", selected.date))
                    .foregroundStyle(VColor.textTertiary.opacity(0.5))
                    .lineStyle(StrokeStyle(lineWidth: 1))
                    .annotation(position: .top, spacing: 4, overflowResolution: .init(x: .fit(to: .chart), y: .disabled)) {
                        ChartTooltip(title: Format.shortDate(selected.date), value: valueFormatter(selected.value))
                    }
            }
        }
        .chartYScale(domain: .automatic(includesZero: false))
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
        .chartXSelection(value: $selectedDate)
        .frame(height: height)
        .animation(Motion.adaptive(Motion.chart, reduceMotion: reduceMotion), value: points)
        .sensoryFeedback(.selection, trigger: selected?.id)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Estimated max chart")
        .accessibilityValue(summary)
    }

    private var summary: String {
        guard let first = points.first, let last = points.last else { return "No data" }
        let best = points.map(\.value).max() ?? last.value
        return "\(points.count) sessions from \(Format.shortDate(first.date)) to \(Format.shortDate(last.date)). "
            + "Latest estimate \(valueFormatter(last.value)), best \(valueFormatter(best))."
    }
}

/// Seven day cells for "Days on calorie target": filled in the calorie
/// colour when on target, an empty track when logged but off target, and a
/// dashed outline when not logged, each with its weekday initial below.
struct DayTargetStrip: View {
    struct Day: Identifiable, Hashable {
        enum Status: Hashable { case onTarget, offTarget, notLogged }
        var date: Date
        var status: Status
        var id: Date { date }
    }

    var days: [Day]
    var calendar: Calendar
    var tint: Color = VColor.calories

    var body: some View {
        HStack(spacing: 6) {
            ForEach(days) { day in
                VStack(spacing: 5) {
                    cell(day.status)
                        .frame(height: 28)
                    Text(initial(day.date))
                        .font(VFont.caption)
                        .foregroundStyle(VColor.textSecondary)
                }
                .frame(maxWidth: .infinity)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Last \(days.count) days")
        .accessibilityValue(days.map { "\(weekday($0.date)) \(spoken($0.status))" }.joined(separator: ", "))
    }

    @ViewBuilder private func cell(_ status: Day.Status) -> some View {
        let shape = RoundedRectangle(cornerRadius: Radius.xs, style: .continuous)
        switch status {
        case .onTarget: shape.fill(tint)
        case .offTarget: shape.fill(VColor.track)
        case .notLogged: shape.strokeBorder(VColor.separator, style: StrokeStyle(lineWidth: 1, dash: [3, 3]))
        }
    }

    private func initial(_ date: Date) -> String {
        let symbols = calendar.veryShortWeekdaySymbols
        let index = calendar.component(.weekday, from: date) - 1
        return symbols.indices.contains(index) ? symbols[index] : ""
    }

    private func weekday(_ date: Date) -> String {
        let symbols = calendar.weekdaySymbols
        let index = calendar.component(.weekday, from: date) - 1
        return symbols.indices.contains(index) ? symbols[index] : Format.shortDate(date, calendar: calendar)
    }

    private func spoken(_ status: Day.Status) -> String {
        switch status {
        case .onTarget: "on target"
        case .offTarget: "off target"
        case .notLogged: "not logged"
        }
    }
}
