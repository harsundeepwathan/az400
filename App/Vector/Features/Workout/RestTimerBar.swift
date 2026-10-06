import SwiftUI
import VectorCore

/// The ring in the workout header. While resting it counts the rest down
/// (the arc empties as time runs out); otherwise it shows the current
/// exercise's sets done. The rest lives here, in the header, so it adds no
/// floating chrome while the current exercise is on screen.
struct WorkoutHeaderRing: View {
    var setsDone: Int
    var setsTotal: Int
    @Environment(AppModel.self) private var model
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @ScaledMetric(relativeTo: .title2) private var scaledDiameter: CGFloat = 96

    private var diameter: CGFloat { min(scaledDiameter, 152) }

    var body: some View {
        Group {
            if let timer = model.restTimer {
                // Reduce Motion: tick once a second instead of sweeping smoothly.
                TimelineView(.periodic(from: timer.startedAt, by: reduceMotion ? 1 : 0.25)) { context in
                    let remaining = timer.remaining(at: context.date).rounded(.up)
                    FieldRing(progress: 1 - timer.progress(at: context.date)) {
                        center(Format.clock(remaining), caption: "rest", countsDown: true)
                    }
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel("Rest")
                    .accessibilityValue("\(Int(remaining)) seconds left")
                    .accessibilityAddTraits(.updatesFrequently)
                }
            } else {
                FieldRing(progress: setsTotal == 0 ? 0 : Double(setsDone) / Double(setsTotal)) {
                    center("\(setsDone)/\(setsTotal)", caption: "sets", countsDown: false)
                }
                .animation(Motion.adaptive(Motion.smooth, reduceMotion: reduceMotion), value: setsDone)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("Sets done")
                .accessibilityValue("\(setsDone) of \(setsTotal)")
            }
        }
        .frame(width: diameter, height: diameter)
    }

    private func center(_ value: String, caption: String, countsDown: Bool) -> some View {
        VStack(spacing: 0) {
            Text(value)
                .font(VFont.metric)
                .foregroundStyle(VColor.textPrimary)
                .contentTransition(.numericText(countsDown: countsDown))
            Text(caption)
                .font(VFont.fieldCaption)
                .foregroundStyle(VColor.textSecondary)
        }
        .lineLimit(1)
        .minimumScaleFactor(0.6)
    }
}

/// −15 s / +15 s / Skip rest: quiet capsules under the header ring.
struct RestControls: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        HStack(spacing: Space.xs) {
            adjustButton(-15)
            adjustButton(15)
            Button("Skip rest") { model.skipRest() }
                .buttonStyle(.fieldQuietCapsule)
        }
    }

    private func adjustButton(_ seconds: Int) -> some View {
        Button {
            model.adjustRest(by: TimeInterval(seconds))
            Haptics.light()
        } label: {
            Text(seconds > 0 ? "+\(seconds) s" : "\u{2212}\(abs(seconds)) s")
        }
        .buttonStyle(.fieldQuietCapsule)
        .accessibilityLabel(seconds > 0 ? "Add \(seconds) seconds" : "Remove \(abs(seconds)) seconds")
    }
}

/// Compact rest countdown pinned to the bottom edge. Shown only when the
/// header ring has scrolled out of view, so rest is never lost; the matching
/// local notification fires if the phone is locked.
struct RestTimerBar: View {
    @Environment(AppModel.self) private var model
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        if let timer = model.restTimer {
            VStack(spacing: 0) {
                Hairline()
                TimelineView(.periodic(from: timer.startedAt, by: reduceMotion ? 1 : 0.25)) { context in
                    let remaining = timer.remaining(at: context.date).rounded(.up)
                    HStack(spacing: Space.sm) {
                        FieldRing(progress: 1 - timer.progress(at: context.date), lineWidth: 4) { EmptyView() }
                            .frame(width: 28, height: 28)
                            .accessibilityHidden(true)
                        VStack(alignment: .leading, spacing: 0) {
                            Text("Rest")
                                .font(VFont.fieldCaption)
                                .foregroundStyle(VColor.textSecondary)
                            Text(Format.clock(remaining))
                                .font(VFont.metricSmall)
                                .foregroundStyle(VColor.textPrimary)
                                .contentTransition(.numericText(countsDown: true))
                        }
                        .accessibilityElement(children: .ignore)
                        .accessibilityLabel("Rest")
                        .accessibilityValue("\(Int(remaining)) seconds left")
                        .accessibilityAddTraits(.updatesFrequently)
                        Spacer(minLength: Space.xs)
                        adjustButton(-15)
                        adjustButton(15)
                        Button("Skip") { model.skipRest() }
                            .buttonStyle(FieldQuietCapsuleButtonStyle(fullWidth: false))
                            .accessibilityLabel("Skip rest")
                    }
                }
                .padding(.horizontal, Space.fieldInset)
                .padding(.vertical, Space.xs)
            }
            .background(.bar)
            .accessibilityElement(children: .contain)
        }
    }

    private func adjustButton(_ seconds: Int) -> some View {
        Button {
            model.adjustRest(by: TimeInterval(seconds))
            Haptics.light()
        } label: {
            Text(seconds > 0 ? "+\(seconds)" : "\u{2212}\(abs(seconds))")
                .frame(minWidth: Size.minTouch)
        }
        .buttonStyle(FieldQuietCapsuleButtonStyle(fullWidth: false))
        .accessibilityLabel(seconds > 0 ? "Add \(seconds) seconds" : "Remove \(abs(seconds)) seconds")
    }
}
