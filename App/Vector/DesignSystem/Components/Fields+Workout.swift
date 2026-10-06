import SwiftUI

// Shared Fields pieces for the active workout and the workout summary.
// Everything here builds on the tokens in Tokens.swift; nothing overrides them.

// MARK: - Tokens (workout)

extension VColor {
    // Derived from the base tokens (never literal values) so a palette change
    // in Tokens.swift flows through.
    /// Quiet capsule fill on the training field: training ink at 10%.
    static let trainingQuietFill = inkTraining.opacity(0.10)
    /// Unfilled ring track on the training field: training ink at 14%.
    static let trainingTrack = inkTraining.opacity(0.14)
    /// Outline of an upcoming set's check: tertiary ink at 45%.
    static let checkOutline = textTertiary.opacity(0.45)
}

// MARK: - Field quiet capsule

/// Quiet capsule tinted for the training field (−15 s / +15 s / Skip rest):
/// training ink text on training ink at 10%. Always at least 44 pt tall.
struct FieldQuietCapsuleButtonStyle: ButtonStyle {
    var tone: FieldTone = .training
    var fullWidth = true

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(VFont.secondaryEmphasized.monospacedDigit())
            .foregroundStyle(tone.ink)
            .lineLimit(1)
            .minimumScaleFactor(0.8)
            .padding(.horizontal, Space.sm)
            .frame(maxWidth: fullWidth ? .infinity : nil, minHeight: Size.minTouch)
            .background(VColor.trainingQuietFill, in: Capsule())
            .contentShape(Capsule())
            .opacity(configuration.isPressed ? 0.7 : 1)
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .animation(configuration.isPressed ? Motion.press : Motion.snappy, value: configuration.isPressed)
    }
}

extension ButtonStyle where Self == FieldQuietCapsuleButtonStyle {
    static var fieldQuietCapsule: FieldQuietCapsuleButtonStyle { FieldQuietCapsuleButtonStyle() }
}

// MARK: - Countdown ring

/// A single round-cap ring with content in the middle. Used for the rest
/// countdown (and sets done when not resting) in the workout header.
/// `progress` is the filled fraction, 0...1.
struct FieldRing<Center: View>: View {
    var progress: Double
    var tint: Color = VColor.accent
    var track: Color = VColor.trainingTrack
    var lineWidth: CGFloat = 8
    @ViewBuilder var center: () -> Center

    var body: some View {
        let shape = Circle().inset(by: lineWidth / 2)
        ZStack {
            shape.stroke(track, lineWidth: lineWidth)
            shape
                .trim(from: 0, to: min(max(progress, 0), 1))
                .stroke(tint, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                .rotationEffect(.degrees(-90))
            center()
                .padding(lineWidth + Space.xxs)
        }
    }
}

// MARK: - Record label

/// Small "Record" marker under a set or beside a record. A seal, not a trophy:
/// records are data, not a prize.
struct RecordLabel: View {
    var title = "Record"

    var body: some View {
        Label {
            Text(title)
        } icon: {
            Image(systemName: "checkmark.seal")
        }
        .labelStyle(TightLabelStyle())
        .font(VFont.captionEmphasized)
        .foregroundStyle(VColor.inkTraining)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Personal record")
    }
}

/// Icon and title with a 4 pt gap (the system label spacing is too loose for inline markers).
struct TightLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: Space.xxs) {
            configuration.icon
            configuration.title
        }
    }
}

// MARK: - Hero number

/// The big number on a hero field ("8,640 kg"): 56 pt rounded bold that
/// scales with Dynamic Type, with the unit in the secondary hero ink.
struct HeroNumber: View {
    var value: String
    var unit: String?
    @ScaledMetric(relativeTo: .largeTitle) private var size: CGFloat = 56
    @ScaledMetric(relativeTo: .title3) private var unitSize: CGFloat = 22

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: Space.xxs) {
            Text(value)
                .font(.system(size: size, weight: .bold, design: .rounded).monospacedDigit())
                .foregroundStyle(VColor.heroText)
                .contentTransition(.numericText())
            if let unit {
                Text(unit)
                    .font(.system(size: unitSize, weight: .semibold, design: .rounded))
                    .foregroundStyle(VColor.heroTextSecondary)
            }
        }
        .lineLimit(1)
        .minimumScaleFactor(0.6)
        .accessibilityElement(children: .combine)
    }
}
