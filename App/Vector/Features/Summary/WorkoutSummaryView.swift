import SwiftUI
import VectorCore

/// The reward moment: what you did, how it compares, what to do next.
struct WorkoutSummaryView: View {
    var summary: WorkoutSummary
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var appeared = false
    @State private var shareImage: Image?

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: Space.lg) {
                    hero
                    metrics
                    if let change = summary.volumeChange {
                        comparison(change)
                    }
                    if !summary.records.isEmpty {
                        records
                    }
                    if let next = summary.nextStep, next.action != .establishBaseline {
                        insight(next)
                    }
                }
                .padding(.horizontal, Space.gutter)
                .padding(.bottom, 140)
            }
            .screenBackground()
            .safeAreaInset(edge: .bottom) {
                HStack(spacing: Space.sm) {
                    if let shareImage {
                        ShareLink(item: shareImage, preview: SharePreview("\(summary.session.name) complete", image: shareImage)) {
                            Label("Share", systemImage: "square.and.arrow.up")
                        }
                        .buttonStyle(.secondary)
                    }
                    PrimaryButton("Done") { model.cover = nil }
                }
                .padding(.horizontal, Space.gutter)
                .padding(.vertical, Space.sm)
                .background(.bar)
            }
            .onAppear {
                withAnimation(Motion.adaptive(Motion.celebrate, reduceMotion: reduceMotion).delay(0.1)) { appeared = true }
                renderShareImage()
            }
            .sensoryFeedback(.success, trigger: appeared)
        }
    }

    private var hero: some View {
        VStack(spacing: Space.sm) {
            ZStack {
                Circle()
                    .fill(VColor.successSoft)
                    .frame(width: 96, height: 96)
                    .scaleEffect(appeared ? 1 : 0.9)
                Image(systemName: "checkmark")
                    .font(.system(size: 40, weight: .bold))
                    .foregroundStyle(VColor.success)
                    .scaleEffect(appeared ? 1 : 0.7)
                    .opacity(appeared ? 1 : 0)
            }
            .accessibilityHidden(true)
            Text("Workout complete")
                .font(VFont.sectionHeading)
                .foregroundStyle(VColor.success)
            Text(summary.session.name)
                .font(VFont.largeTitle)
                .foregroundStyle(VColor.textPrimary)
            Text(Format.duration(summary.session.duration))
                .font(VFont.secondary)
                .foregroundStyle(VColor.textSecondary)
        }
        .padding(.top, Space.xl)
        .accessibilityElement(children: .combine)
    }

    private var metrics: some View {
        LazyVGrid(columns: [GridItem(.flexible(), spacing: Space.sm), GridItem(.flexible())], spacing: Space.sm) {
            MetricCard(label: "Total volume", value: Format.volume(summary.session.volume, unit: model.unit, includeUnit: false),
                       unit: model.unit.symbol, symbol: "scalemass")
            MetricCard(label: "Exercises", value: "\(summary.session.exercises.count)", symbol: "list.bullet")
            MetricCard(label: "Sets", value: "\(summary.session.completedSetCount)", symbol: Icon.check)
            MetricCard(label: "PRs", value: "\(summary.records.count)", symbol: Icon.trophy)
        }
        .opacity(appeared ? 1 : 0)
        .offset(y: appeared ? 0 : 12)
    }

    private func comparison(_ change: Double) -> some View {
        HStack(spacing: Space.sm) {
            IconBadge(symbol: change >= 0 ? "arrow.up.right" : "arrow.down.right",
                      tint: change >= 0 ? VColor.success : VColor.warning,
                      fill: change >= 0 ? VColor.successSoft : VColor.warningSoft)
            VStack(alignment: .leading, spacing: 2) {
                Text("\(Format.signedPercent(change)) volume vs last \(summary.session.name)")
                    .font(VFont.bodyEmphasized)
                    .foregroundStyle(VColor.textPrimary)
                if let previous = summary.previous {
                    Text("\(Format.volume(previous.volume, unit: model.unit)) on \(Format.shortDate(previous.startedAt, calendar: model.calendar))")
                        .font(VFont.secondary)
                        .foregroundStyle(VColor.textSecondary)
                }
            }
            Spacer()
        }
        .card()
    }

    private var records: some View {
        VStack(alignment: .leading, spacing: Space.sm) {
            SectionHeader("New personal records")
            VStack(spacing: 0) {
                ForEach(Array(summary.records.enumerated()), id: \.element.id) { index, record in
                    HStack {
                        PRBadge()
                        Text(record.exerciseName).font(VFont.bodyEmphasized).foregroundStyle(VColor.textPrimary)
                        Spacer()
                        VStack(alignment: .trailing, spacing: 1) {
                            Text(record.weight > 0 ? "\(Format.weight(record.weight, unit: model.unit)) × \(record.reps)" : "\(record.reps) reps")
                                .font(VFont.data)
                            Text(record.improvementLabel(unit: model.unit))
                                .font(VFont.captionEmphasized)
                                .foregroundStyle(VColor.success)
                        }
                    }
                    .padding(Space.md)
                    .scaleEffect(appeared ? 1 : 0.9)
                    .opacity(appeared ? 1 : 0)
                    .animation(Motion.adaptive(Motion.celebrate, reduceMotion: reduceMotion).delay(0.25 + Double(index) * 0.08), value: appeared)
                    if index < summary.records.count - 1 { Hairline(leading: Space.md) }
                }
            }
            .card(padding: 0)
        }
    }

    private func insight(_ rec: ProgressionRecommendation) -> some View {
        let name = model.catalog[rec.exerciseID]?.name ?? "your main lift"
        let target = rec.weight.map { "\(Format.weight($0, unit: model.unit)) × \(rec.reps)" } ?? "\(rec.reps) reps"
        let message: String = switch rec.action {
        case .increaseLoad: "Your \(name.lowercased()) performance improved again. Consider increasing to \(target) next session."
        case .increaseReps: "Solid \(name.lowercased()) session. Aim for \(target) next time before adding load."
        case .deload: "Your \(name.lowercased()) has dipped for three sessions. A lighter session at \(target) will help you recover."
        default: "Next \(name.lowercased()) target: \(target)."
        }
        return VStack(alignment: .leading, spacing: Space.sm) {
            Label("Summary", systemImage: Icon.recommendation)
                .font(VFont.sectionHeading)
                .foregroundStyle(VColor.accentText)
            Text(message)
                .font(VFont.body)
                .foregroundStyle(VColor.textPrimary)
                .fixedSize(horizontal: false, vertical: true)
            Text(rec.reason)
                .font(VFont.secondary)
                .foregroundStyle(VColor.textSecondary)
        }
        .card()
    }

    @MainActor
    private func renderShareImage() {
        let card = ShareCard(summary: summary, unit: model.unit)
        let renderer = ImageRenderer(content: card)
        renderer.scale = 3
        if let image = renderer.uiImage { shareImage = Image(uiImage: image) }
    }
}

/// Branded image for sharing. Rendered offscreen, always in dark style.
private struct ShareCard: View {
    var summary: WorkoutSummary
    var unit: WeightUnit

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("VECTOR").font(.system(size: 13, weight: .heavy)).tracking(3).foregroundStyle(.white.opacity(0.6))
            Text(summary.session.name).font(.system(size: 34, weight: .bold)).foregroundStyle(.white)
            HStack(spacing: 28) {
                stat("Volume", Format.volume(summary.session.volume, unit: unit))
                stat("Sets", "\(summary.session.completedSetCount)")
                stat("Time", Format.duration(summary.session.duration))
            }
            if !summary.records.isEmpty {
                Label("\(summary.records.count) new PR\(summary.records.count == 1 ? "" : "s")", systemImage: Icon.trophy)
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(.white)
            }
        }
        .padding(28)
        .frame(width: 360, alignment: .leading)
        .background(Color.black)
    }

    private func stat(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(value).font(.system(size: 20, weight: .bold).monospacedDigit()).foregroundStyle(.white)
            Text(label).font(.system(size: 12, weight: .medium)).foregroundStyle(.white.opacity(0.6))
        }
    }
}
