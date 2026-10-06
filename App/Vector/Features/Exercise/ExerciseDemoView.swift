import SwiftUI
import VectorCore

/// Two-frame demonstration (start and end position) that alternates like a
/// slow loop. Under Reduce Motion the frames sit side by side instead.
/// Falls back to the exercise's symbol when there are no photos or the
/// device is offline.
struct ExerciseDemoView: View {
    var exercise: Exercise
    var height: CGFloat = 200
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let urls = exercise.imageURLs
        Group {
            if urls.count >= 2 {
                if reduceMotion {
                    HStack(spacing: 2) {
                        frame(urls[0], label: "Start")
                        frame(urls[1], label: "Finish")
                    }
                } else {
                    TimelineView(.periodic(from: .now, by: 1.2)) { context in
                        let showEnd = Int(context.date.timeIntervalSinceReferenceDate / 1.2) % 2 == 1
                        ZStack {
                            frame(urls[0], label: nil).opacity(showEnd ? 0 : 1)
                            frame(urls[1], label: nil).opacity(showEnd ? 1 : 0)
                        }
                        .animation(.easeInOut(duration: 0.45), value: showEnd)
                        .overlay(alignment: .bottomLeading) {
                            Text(showEnd ? "Finish" : "Start")
                                .font(VFont.captionEmphasized)
                                .foregroundStyle(.white)
                                .padding(.horizontal, Space.xs)
                                .padding(.vertical, 4)
                                .background(.black.opacity(0.45), in: Capsule())
                                .padding(Space.sm)
                                .contentTransition(.opacity)
                        }
                    }
                }
            } else if let url = urls.first {
                frame(url, label: nil)
            } else {
                placeholder
            }
        }
        .frame(height: height)
        .frame(maxWidth: .infinity)
        .background(VColor.surfaceSunken)
        .clipShape(RoundedRectangle(cornerRadius: Radius.lg, style: .continuous))
        .accessibilityElement()
        .accessibilityLabel("Demonstration of \(exercise.name)")
        .accessibilityAddTraits(.isImage)
    }

    private func frame(_ url: URL, label: String?) -> some View {
        AsyncImage(url: url, transaction: Transaction(animation: Motion.smooth)) { phase in
            switch phase {
            case .success(let image):
                image.resizable().scaledToFill()
            case .failure:
                placeholder
            default:
                Rectangle().fill(VColor.surfaceSunken).skeleton(true)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .clipped()
        .overlay(alignment: .bottomLeading) {
            if let label {
                Text(label)
                    .font(VFont.captionEmphasized)
                    .foregroundStyle(.white)
                    .padding(.horizontal, Space.xs)
                    .padding(.vertical, 4)
                    .background(.black.opacity(0.45), in: Capsule())
                    .padding(Space.xs)
            }
        }
    }

    private var placeholder: some View {
        ZStack {
            LinearGradient(colors: [VColor.accentSoft, VColor.surface], startPoint: .topLeading, endPoint: .bottomTrailing)
            Image(systemName: exercise.symbol)
                .font(.system(size: 64, weight: .light))
                .foregroundStyle(VColor.accentText)
        }
    }
}

/// Small square thumbnail (first frame) for lists.
struct ExerciseThumbnail: View {
    var exercise: Exercise
    var size: CGFloat = 40

    var body: some View {
        Group {
            if let url = exercise.imageURLs.first {
                AsyncImage(url: url) { phase in
                    if let image = phase.image {
                        image.resizable().scaledToFill()
                    } else {
                        IconBadge(symbol: exercise.symbol, tint: VColor.textSecondary, fill: VColor.surfaceSunken, size: size)
                    }
                }
            } else {
                IconBadge(symbol: exercise.symbol, tint: VColor.textSecondary, fill: VColor.surfaceSunken, size: size)
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: size * 0.3, style: .continuous))
        .accessibilityHidden(true)
    }
}
