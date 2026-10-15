import SwiftUI
import VectorCore

/// A front and back figure whose muscles fill with the training colour by
/// how many hard sets they got (deeper = more, up to 20 a week). A simple,
/// geometric figure: rounded shapes on a 100 × 220 grid, scaled to fit.
struct MuscleMap: View {
    /// Weekly hard sets per muscle.
    var sets: [MuscleGroup: Double]
    var tint: Color = WidgetTint.training.color

    var body: some View {
        HStack(spacing: Space.md) {
            figure(Self.front, caption: "Front")
            figure(Self.back, caption: "Back")
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Muscles trained")
        .accessibilityValue(spokenSummary)
    }

    private func figure(_ parts: [Part], caption: String) -> some View {
        VStack(spacing: 6) {
            GeometryReader { proxy in
                let scale = min(proxy.size.width / 100, proxy.size.height / 220)
                let offsetX = (proxy.size.width - 100 * scale) / 2
                ZStack(alignment: .topLeading) {
                    ForEach(parts) { part in
                        RoundedRectangle(cornerRadius: part.corner * scale, style: .continuous)
                            .fill(fill(for: part.muscle))
                            .frame(width: part.rect.width * scale, height: part.rect.height * scale)
                            .rotationEffect(.degrees(part.angle))
                            .position(x: offsetX + part.rect.midX * scale, y: part.rect.midY * scale)
                    }
                }
            }
            .aspectRatio(100 / 220, contentMode: .fit)
            Text(caption)
                .font(.caption)
                .foregroundStyle(WColor.textSecondary)
        }
        .frame(maxWidth: .infinity)
    }

    private func fill(for muscle: MuscleGroup?) -> Color {
        guard let muscle else { return WColor.quiet }
        let value = sets[muscle] ?? 0
        guard value > 0 else { return WColor.track }
        let level = min(value / MuscleVolume.recommendedWeeklySets.upperBound, 1)
        return tint.opacity(0.25 + 0.75 * level)
    }

    private var spokenSummary: String {
        let trained = sets.filter { $0.value > 0 }.sorted { $0.value > $1.value }
        guard !trained.isEmpty else { return "None yet this week" }
        return trained.map { "\($0.key.displayName) \(Int($0.value.rounded())) sets" }.joined(separator: ", ")
    }

    // MARK: Figures

    struct Part: Identifiable {
        let id = UUID()
        var muscle: MuscleGroup?
        var rect: CGRect
        var corner: CGFloat = 8
        var angle: Double = 0
    }

    private static func p(_ muscle: MuscleGroup?, _ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat,
                          corner: CGFloat = 8, angle: Double = 0) -> Part {
        Part(muscle: muscle, rect: CGRect(x: x, y: y, width: w, height: h), corner: corner, angle: angle)
    }

    /// Head, then each muscle as a mirrored pair where there are two.
    static let front: [Part] = [
        p(nil, 40, 2, 20, 22, corner: 10),
        p(.shoulders, 18, 30, 18, 16, corner: 8), p(.shoulders, 64, 30, 18, 16, corner: 8),
        p(.chest, 34, 32, 15, 20, corner: 6), p(.chest, 51, 32, 15, 20, corner: 6),
        p(.biceps, 14, 48, 12, 26, corner: 6, angle: 6), p(.biceps, 74, 48, 12, 26, corner: 6, angle: -6),
        p(.forearms, 10, 77, 11, 28, corner: 5, angle: 6), p(.forearms, 79, 77, 11, 28, corner: 5, angle: -6),
        p(.core, 37, 55, 26, 42, corner: 8),
        p(.quads, 32, 102, 16, 52, corner: 8, angle: 3), p(.quads, 52, 102, 16, 52, corner: 8, angle: -3),
        p(.calves, 33, 160, 13, 44, corner: 6), p(.calves, 54, 160, 13, 44, corner: 6)
    ]

    static let back: [Part] = [
        p(nil, 40, 2, 20, 22, corner: 10),
        p(.shoulders, 18, 30, 18, 16, corner: 8), p(.shoulders, 64, 30, 18, 16, corner: 8),
        p(.back, 34, 30, 32, 16, corner: 6),
        p(.back, 33, 48, 15, 34, corner: 7, angle: 4), p(.back, 52, 48, 15, 34, corner: 7, angle: -4),
        p(.triceps, 14, 48, 12, 26, corner: 6, angle: 6), p(.triceps, 74, 48, 12, 26, corner: 6, angle: -6),
        p(.forearms, 10, 77, 11, 28, corner: 5, angle: 6), p(.forearms, 79, 77, 11, 28, corner: 5, angle: -6),
        p(.glutes, 34, 84, 15, 18, corner: 8), p(.glutes, 51, 84, 15, 18, corner: 8),
        p(.hamstrings, 32, 104, 16, 50, corner: 8, angle: 3), p(.hamstrings, 52, 104, 16, 50, corner: 8, angle: -3),
        p(.calves, 33, 160, 13, 44, corner: 6), p(.calves, 54, 160, 13, 44, corner: 6)
    ]
}
