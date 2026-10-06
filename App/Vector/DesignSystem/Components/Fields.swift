import Charts
import SwiftUI
import VectorCore

// MARK: - Field section

/// The three area fields. Each owns a tinted ground and an ink colour for
/// its category label, so colour does the wayfinding.
enum FieldTone {
    case training, nutrition, body

    var fill: Color {
        switch self {
        case .training: VColor.fieldTraining
        case .nutrition: VColor.fieldNutrition
        case .body: VColor.fieldBody
        }
    }

    var ink: Color {
        switch self {
        case .training: VColor.inkTraining
        case .nutrition: VColor.inkNutrition
        case .body: VColor.inkBody
        }
    }
}

/// A full-bleed tinted band with no radius: one per area. The edges between
/// fields are the separators. Place it in a container with no horizontal
/// padding; content is inset `Space.fieldInset` inside the band.
struct FieldSection<Content: View>: View {
    var tone: FieldTone
    var symbol: String
    var title: String
    var detail: String?
    var action: (() -> Void)?
    var spacing: CGFloat
    @ViewBuilder var content: () -> Content

    init(_ tone: FieldTone, symbol: String, title: String, detail: String? = nil, spacing: CGFloat = Space.sm,
         action: (() -> Void)? = nil, @ViewBuilder content: @escaping () -> Content) {
        self.tone = tone
        self.symbol = symbol
        self.title = title
        self.detail = detail
        self.action = action
        self.spacing = spacing
        self.content = content
    }

    var body: some View {
        VStack(alignment: .leading, spacing: spacing) {
            CategoryHeader(symbol: symbol, title: title, tint: tone.ink, detail: detail, action: action)
                .frame(minHeight: Size.minTouch)
            content()
        }
        .padding(.horizontal, Space.fieldInset)
        // The header row is 44 pt tall (the trailing link's target), so trim the top to keep the 24 pt rhythm.
        .padding(.top, Space.fieldVertical - Space.sm)
        .padding(.bottom, Space.fieldVertical)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(tone.fill)
        .accessibilityElement(children: .contain)
    }
}

// MARK: - Activity rings

/// One ring of `ActivityRings`.
struct ActivityRing: Identifiable, Hashable {
    var id: String { label }
    var label: String
    /// 0...1 is the plan; above 1 the ring overlaps itself at 55% opacity.
    var progress: Double
    var color: Color
}

/// Three concentric rings (outer first): 17 pt round-cap strokes on a white
/// 12% track. Past 100% a ring keeps going and overlaps at 55% opacity, so
/// exceeding a target stays visible. Rings fill in on appear and on change,
/// and set instantly under Reduce Motion.
struct ActivityRings: View {
    var rings: [ActivityRing]
    var diameter: CGFloat = 168
    var lineWidth: CGFloat = 17
    var gap: CGFloat = 3
    var track: Color = VColor.heroTrack
    /// The VoiceOver summary, e.g. "Workouts 3 of 4, calories 1,640 of 2,300…".
    var accessibilitySummary: String
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var shown: [Double] = []

    var body: some View {
        ZStack {
            ForEach(Array(rings.enumerated()), id: \.element.id) { index, ring in
                let size = diameter - CGFloat(index) * 2 * (lineWidth + gap)
                let value = index < shown.count ? shown[index] : 0
                RingArc(progress: value, color: ring.color, track: track, lineWidth: lineWidth)
                    .frame(width: size, height: size)
            }
        }
        .frame(width: diameter, height: diameter)
        .onAppear { update(animated: Motion.gentle) }
        .onChange(of: rings.map(\.progress)) { _, _ in update(animated: Motion.smooth) }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Activity rings")
        .accessibilityValue(accessibilitySummary)
    }

    private func update(animated animation: Animation) {
        // Cap at two laps; beyond that the overlap carries no extra meaning.
        let target = rings.map { min(max($0.progress, 0), 2) }
        if shown.count != target.count { shown = Array(repeating: 0, count: target.count) }
        if reduceMotion {
            shown = target
        } else {
            withAnimation(animation) { shown = target }
        }
    }
}

/// A single ring arc. `progress` is animatable so the trim interpolates.
private struct RingArc: View, Animatable {
    var progress: Double
    var color: Color
    var track: Color
    var lineWidth: CGFloat

    var animatableData: Double {
        get { progress }
        set { progress = newValue }
    }

    var body: some View {
        let style = StrokeStyle(lineWidth: lineWidth, lineCap: .round)
        let shape = Circle().inset(by: lineWidth / 2)
        ZStack {
            shape.stroke(track, lineWidth: lineWidth)
            shape
                .trim(from: 0, to: min(progress, 1))
                .stroke(color, style: style)
            if progress > 1 {
                shape
                    .trim(from: 0, to: min(progress - 1, 1))
                    .stroke(color.opacity(0.55), style: style)
            }
        }
        .rotationEffect(.degrees(-90))
    }
}

/// One legend row beside the rings: a coloured dot and label, then the value
/// with its target ("1,640 / 2,300"). Sits on the hero field.
struct RingLegendRow: View {
    var label: String
    var value: String
    var target: String
    var color: Color
    /// Spoken value, e.g. "1,640 of 2,300 kilocalories".
    var accessibilityValue: String

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                Circle().fill(color).frame(width: 8, height: 8)
                Text(label)
                    .font(VFont.fieldCaption)
                    .foregroundStyle(VColor.heroTextSecondary)
                    .lineLimit(2)
            }
            (Text(value).font(VFont.ringValue).foregroundStyle(VColor.heroText)
                + Text(" / \(target)").font(VFont.ringTarget).foregroundStyle(VColor.heroTextSecondary))
                .lineLimit(1)
                .minimumScaleFactor(0.7)
                .contentTransition(.numericText())
        }
        .padding(.vertical, 9)
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(label)
        .accessibilityValue(accessibilityValue)
    }
}

// MARK: - Macro column

/// One macro in the nutrition field's three-column grid: dot and name,
/// value over target, then a thin capsule bar.
struct MacroColumn: View {
    var title: String
    var consumed: Double
    var target: Double
    var tint: Color
    var unit = "g"
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var shown: Double = 0

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                Circle().fill(tint).frame(width: 7, height: 7)
                Text(title)
                    .font(VFont.fieldCaption)
                    .foregroundStyle(VColor.textSecondary)
            }
            (Text(Format.integer(consumed)).font(VFont.macroValue).foregroundStyle(VColor.textPrimary)
                + Text(" / \(Format.integer(target)) \(unit)").font(VFont.fieldCaption.monospacedDigit())
                .foregroundStyle(VColor.textSecondary))
                .lineLimit(1)
                .minimumScaleFactor(0.75)
            GeometryReader { proxy in
                ZStack(alignment: .leading) {
                    Capsule().fill(VColor.track)
                    Capsule()
                        .fill(tint)
                        .frame(width: max(proxy.size.width * min(shown, 1), shown > 0 ? 5 : 0))
                }
            }
            .frame(height: 5)
            .padding(.top, 4)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .onAppear { set(ratio, animation: Motion.gentle) }
        .onChange(of: ratio) { _, value in set(value, animation: Motion.smooth) }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(title)
        .accessibilityValue("\(Format.integer(consumed)) of \(Format.integer(target)) \(unit == "g" ? "grams" : unit)")
    }

    private var ratio: Double { target > 0 ? consumed / target : 0 }

    private func set(_ value: Double, animation: Animation) {
        if reduceMotion { shown = value } else { withAnimation(animation) { shown = value } }
    }
}

// MARK: - Trend sparkline

/// Small trend line over a faint series (body weight). No axes; the number
/// beside it carries the value.
struct TrendSparkline: View {
    var points: [ChartPoint]
    var trend: [ChartPoint]
    var tint: Color

    var body: some View {
        Chart {
            ForEach(points) { point in
                LineMark(x: .value("Date", point.date), y: .value("Value", point.value),
                         series: .value("Series", "Weigh-ins"))
                    .foregroundStyle(tint.opacity(0.3))
                    .lineStyle(StrokeStyle(lineWidth: 1.5, lineCap: .round, lineJoin: .round))
            }
            ForEach(trend) { point in
                LineMark(x: .value("Date", point.date), y: .value("Value", point.value),
                         series: .value("Series", "Trend"))
                    .foregroundStyle(tint)
                    .lineStyle(StrokeStyle(lineWidth: 2.5, lineCap: .round, lineJoin: .round))
                    .interpolationMethod(.monotone)
            }
            if let last = trend.last {
                PointMark(x: .value("Date", last.date), y: .value("Value", last.value))
                    .foregroundStyle(tint)
                    .symbolSize(40)
            }
        }
        .chartXAxis(.hidden)
        .chartYAxis(.hidden)
        .chartYScale(domain: domain)
        .chartLegend(.hidden)
        .accessibilityHidden(true)
    }

    private var domain: ClosedRange<Double> {
        let values = (points + trend).map(\.value)
        guard let low = values.min(), let high = values.max() else { return 0...1 }
        let pad = max((high - low) * 0.2, 0.2)
        return (low - pad)...(high + pad)
    }
}

// MARK: - Paired stats

/// Two stats inside a field split by a vertical hairline ("7 days ago ·
/// Last Lower A" | "8,420 kg · Previous volume"). Stacks at large text sizes.
struct FieldStatPair: View {
    struct Stat {
        var value: String
        var label: String
    }

    var leading: Stat
    var trailing: Stat

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .top, spacing: 0) {
                stat(leading)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Rectangle()
                    .fill(VColor.separator)
                    .frame(width: 0.5)
                    .padding(.trailing, 14)
                stat(trailing)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .fixedSize(horizontal: false, vertical: true)
            VStack(alignment: .leading, spacing: Space.sm) {
                stat(leading)
                stat(trailing)
            }
        }
    }

    private func stat(_ stat: Stat) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(stat.value)
                .font(VFont.fieldStat)
                .foregroundStyle(VColor.textPrimary)
            Text(stat.label)
                .font(VFont.fieldCaption)
                .foregroundStyle(VColor.textSecondary)
        }
        .accessibilityElement(children: .combine)
    }
}
