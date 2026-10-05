import SwiftUI
import VectorCore

/// Floating rest countdown. Pinned above the bottom edge so it stays
/// visible while scrolling to other exercises; the matching local
/// notification fires if the phone is locked.
struct RestTimerBar: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        if let timer = model.restTimer {
            TimelineView(.animation(minimumInterval: 0.25, paused: false)) { context in
                let remaining = timer.remaining(at: context.date)
                VStack(spacing: Space.sm) {
                    HStack(alignment: .center) {
                        VStack(alignment: .leading, spacing: 0) {
                            Text("REST")
                                .font(VFont.sectionHeading)
                                .tracking(0.8)
                                .foregroundStyle(VColor.textSecondary)
                            Text(Format.clock(remaining.rounded(.up)))
                                .font(VFont.metricHero)
                                .foregroundStyle(remaining <= 5 ? VColor.accentText : VColor.textPrimary)
                                .contentTransition(.numericText(countsDown: true))
                                .accessibilityLabel("Rest remaining \(Int(remaining.rounded(.up))) seconds")
                        }
                        Spacer()
                        HStack(spacing: Space.xs) {
                            adjustButton(-15)
                            adjustButton(15)
                            Button("Skip") { model.skipRest() }
                                .font(VFont.bodyEmphasized)
                                .buttonStyle(.secondary(compact: true))
                                .frame(width: 72)
                        }
                    }
                    LinearProgress(progress: timer.progress(at: context.date), height: 4)
                }
            }
            .padding(Space.md)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: Radius.lg, style: .continuous))
            .shadow(color: .black.opacity(0.15), radius: 20, y: 8)
            .task(id: timer) {
                // Fires the foreground "rest over" haptic exactly at the end date.
                let delay = timer.remaining(at: model.now())
                if delay > 0 { try? await Task.sleep(for: .seconds(delay)) }
                guard !Task.isCancelled else { return }
                model.restDidFinish()
            }
            .accessibilityElement(children: .contain)
            .accessibilityAddTraits(.updatesFrequently)
        }
    }

    private func adjustButton(_ seconds: Int) -> some View {
        Button {
            model.adjustRest(by: TimeInterval(seconds))
            Haptics.light()
        } label: {
            Text(seconds > 0 ? "+\(seconds)" : "\u{2212}\(abs(seconds))")
                .font(VFont.secondaryEmphasized.monospacedDigit())
                .frame(width: 52, height: Size.compactButtonHeight)
                .background(VColor.surfaceSunken, in: RoundedRectangle(cornerRadius: Radius.sm, style: .continuous))
        }
        .buttonStyle(.plain)
        .foregroundStyle(VColor.textPrimary)
        .frame(minHeight: Size.minTouch)
        .accessibilityLabel(seconds > 0 ? "Add \(seconds) seconds" : "Remove \(abs(seconds)) seconds")
    }
}
