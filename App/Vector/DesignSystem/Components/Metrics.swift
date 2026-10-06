import SwiftUI
import VectorCore

/// Label + large value (+ optional unit and delta). The atom of every dashboard.
struct MetricView: View {
    var label: String
    var value: String
    var unit: String?
    var delta: Double?
    var deltaCaption: String?
    var alignment: HorizontalAlignment = .leading
    var font: Font = VFont.metric

    var body: some View {
        VStack(alignment: alignment, spacing: 2) {
            Text(label)
                .font(VFont.caption)
                .foregroundStyle(VColor.textSecondary)
            HStack(alignment: .firstTextBaseline, spacing: 3) {
                Text(value)
                    .font(font)
                    .foregroundStyle(VColor.textPrimary)
                    .contentTransition(.numericText())
                if let unit {
                    Text(unit)
                        .font(VFont.secondary)
                        .foregroundStyle(VColor.textSecondary)
                }
            }
            .lineLimit(1)
            .minimumScaleFactor(0.7)
            if let delta {
                DeltaBadge(delta: delta, caption: deltaCaption)
            }
        }
        .accessibilityElement(children: .combine)
    }
}

/// Grid tile wrapping a MetricView.
struct MetricCard: View {
    var label: String
    var value: String
    var unit: String?
    var delta: Double?
    var symbol: String?

    var body: some View {
        VStack(alignment: .leading, spacing: Space.xs) {
            if let symbol {
                Image(systemName: symbol)
                    .font(.system(.footnote, weight: .semibold))
                    .foregroundStyle(VColor.accentText)
                    .accessibilityHidden(true)
            }
            MetricView(label: label, value: value, unit: unit, delta: delta)
        }
        .card(padding: Space.md)
    }
}

/// Signed change indicator. Direction is shown by arrow + sign, not color alone.
struct DeltaBadge: View {
    var delta: Double
    var caption: String?
    /// For metrics where down is good (e.g. body weight when cutting).
    var invert = false

    private var isPositive: Bool { invert ? delta < 0 : delta > 0 }
    private var isFlat: Bool { abs(delta) < 0.0005 }

    var body: some View {
        HStack(spacing: 3) {
            Image(systemName: isFlat ? "minus" : (delta > 0 ? "arrow.up.right" : "arrow.down.right"))
                .font(.system(.caption2, weight: .bold))
            Text(Format.signedPercent(delta))
                .font(VFont.captionEmphasized.monospacedDigit())
            if let caption {
                Text(caption)
                    .font(VFont.caption)
                    .foregroundStyle(VColor.textSecondary)
            }
        }
        .foregroundStyle(isFlat ? VColor.textSecondary : (isPositive ? VColor.success : VColor.warning))
        .accessibilityElement(children: .combine)
    }
}

// MARK: - Rings & bars

/// Circular progress ring. Overshoot past 100% wraps with a darker overlap
/// so exceeding a target is visible, not hidden.
struct ProgressRing: View {
    var progress: Double
    var tint: Color
    var lineWidth: CGFloat = 10
    var track: Color = VColor.surfaceSunken
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var animated: Double = 0

    var body: some View {
        ZStack {
            Circle().stroke(track, lineWidth: lineWidth)
            Circle()
                .trim(from: 0, to: min(animated, 1))
                .stroke(tint, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                .rotationEffect(.degrees(-90))
            if animated > 1 {
                Circle()
                    .trim(from: 0, to: min(animated - 1, 1))
                    .stroke(tint.opacity(0.55), style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                    .rotationEffect(.degrees(-90))
            }
        }
        .onAppear { withAnimation(Motion.adaptive(Motion.gentle, reduceMotion: reduceMotion)) { animated = progress } }
        .onChange(of: progress) { _, value in
            withAnimation(Motion.adaptive(Motion.smooth, reduceMotion: reduceMotion)) { animated = value }
        }
        .accessibilityHidden(true)
    }
}

/// Ring with a value in the middle, used for a single macro or calories.
struct MacroRing: View {
    var title: String
    var consumed: Double
    var target: Double
    var unit: String
    var tint: Color
    var size: CGFloat = 72

    var body: some View {
        VStack(spacing: Space.xs) {
            ZStack {
                ProgressRing(progress: target > 0 ? consumed / target : 0, tint: tint, lineWidth: size * 0.11)
                VStack(spacing: 0) {
                    Text(Format.integer(consumed))
                        .font(VFont.metricSmall)
                        .foregroundStyle(VColor.textPrimary)
                        .contentTransition(.numericText())
                    Text("/ \(Format.integer(target))\(unit)")
                        .font(.system(.caption2).monospacedDigit())
                        .foregroundStyle(VColor.textSecondary)
                }
                .minimumScaleFactor(0.6)
                .padding(size * 0.14)
            }
            .frame(width: size, height: size)
            Text(title)
                .font(VFont.captionEmphasized)
                .foregroundStyle(VColor.textSecondary)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(title): \(Format.integer(consumed)) of \(Format.integer(target)) \(unit == "g" ? "grams" : unit)")
    }
}

/// Horizontal labeled bar: "Protein   112 / 150g".
struct MacroBar: View {
    var title: String
    var consumed: Double
    var target: Double
    var tint: Color
    var unit = "g"
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var animated: Double = 0

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                HStack(spacing: 6) {
                    Circle().fill(tint).frame(width: 8, height: 8)
                    Text(title)
                        .font(VFont.secondaryEmphasized)
                        .foregroundStyle(VColor.textPrimary)
                }
                Spacer(minLength: Space.xs)
                Text("\(Format.integer(consumed))")
                    .font(VFont.secondaryEmphasized.monospacedDigit())
                    .foregroundStyle(VColor.textPrimary)
                + Text(" /\(Format.integer(target))\(unit)")
                    .font(VFont.dataSecondary)
                    .foregroundStyle(VColor.textSecondary)
            }
            GeometryReader { proxy in
                ZStack(alignment: .leading) {
                    Capsule().fill(VColor.surfaceSunken)
                    Capsule()
                        .fill(tint)
                        .frame(width: max(proxy.size.width * min(animated, 1), animated > 0 ? 6 : 0))
                }
            }
            .frame(height: 6)
        }
        .onAppear { withAnimation(Motion.adaptive(Motion.gentle, reduceMotion: reduceMotion)) { animated = ratio } }
        .onChange(of: ratio) { _, value in
            withAnimation(Motion.adaptive(Motion.smooth, reduceMotion: reduceMotion)) { animated = value }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(title)
        .accessibilityValue("\(Format.integer(consumed)) of \(Format.integer(target)) grams")
    }

    private var ratio: Double { target > 0 ? consumed / target : 0 }
}

/// Calories ring + the three macro bars. Shared by Today and Nutrition.
struct NutritionSummary: View {
    var day: DailyNutrition
    var compact = false

    var body: some View {
        HStack(alignment: .center, spacing: Space.lg) {
            ZStack {
                ProgressRing(progress: day.calorieProgress, tint: VColor.calories, lineWidth: compact ? 11 : 13)
                VStack(spacing: 0) {
                    Text(Format.integer(abs(day.caloriesRemaining)))
                        .font(compact ? VFont.metric : VFont.metricHero)
                        .foregroundStyle(VColor.textPrimary)
                        .contentTransition(.numericText())
                        .minimumScaleFactor(0.6)
                    Text(day.caloriesRemaining >= 0 ? "kcal left" : "kcal over")
                        .font(VFont.caption)
                        .foregroundStyle(day.caloriesRemaining >= 0 ? VColor.textSecondary : VColor.warning)
                }
                .padding(Space.sm)
            }
            .frame(width: compact ? 112 : 136, height: compact ? 112 : 136)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Calories")
            .accessibilityValue("\(Format.integer(day.consumed.calories)) of \(Format.integer(day.targets.calories)), "
                                + "\(Format.integer(abs(day.caloriesRemaining))) \(day.caloriesRemaining >= 0 ? "remaining" : "over")")

            VStack(spacing: Space.sm) {
                MacroBar(title: "Protein", consumed: day.consumed.protein, target: day.targets.protein, tint: VColor.protein)
                MacroBar(title: "Carbs", consumed: day.consumed.carbs, target: day.targets.carbs, tint: VColor.carbs)
                MacroBar(title: "Fat", consumed: day.consumed.fat, target: day.targets.fat, tint: VColor.fat)
            }
        }
    }
}

/// Linear progress used for workout completion.
struct LinearProgress: View {
    var progress: Double
    var tint: Color = VColor.accent
    var height: CGFloat = 4

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Capsule().fill(VColor.surfaceSunken)
                Capsule().fill(tint).frame(width: proxy.size.width * min(max(progress, 0), 1))
            }
        }
        .frame(height: height)
        .animation(Motion.smooth, value: progress)
        .accessibilityElement()
        .accessibilityLabel("Progress")
        .accessibilityValue("\(Int(progress * 100)) percent")
    }
}

struct PRBadge: View {
    var label = "PR"

    var body: some View {
        HStack(spacing: 3) {
            Image(systemName: Icon.trophy).font(.system(.caption2, weight: .bold))
            Text(label).font(.system(.caption2, design: .rounded, weight: .heavy))
        }
        .foregroundStyle(VColor.warning)
        .padding(.horizontal, 7)
        .padding(.vertical, 3)
        .background(VColor.warningSoft, in: Capsule())
        .accessibilityLabel("Personal record")
    }
}
