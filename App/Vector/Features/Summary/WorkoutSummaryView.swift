import SwiftUI
import VectorCore

/// The reward moment, on Fields: a hero field with what you did and how it
/// compares, then new records and the best set per exercise as hairline
/// rows, and what to do next. One filled "Done" pinned at the bottom; Share
/// in the toolbar. The seal bounces once; nothing else moves.
struct WorkoutSummaryView: View {
    var summary: WorkoutSummary
    @Environment(AppModel.self) private var model
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var appeared = false
    @State private var shareImage: Image?

    private var session: WorkoutSession { summary.session }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    hero
                    if !summary.records.isEmpty {
                        records
                        Hairline()
                    }
                    bestSets
                    if let next = summary.nextStep, next.action != .establishBaseline {
                        Hairline()
                        insight(next)
                    }
                }
                .padding(.bottom, Space.xl)
            }
            .background(VColor.ground.ignoresSafeArea())
            .navigationBarTitleDisplayMode(.inline)
            // The bar takes the hero colour so the field runs up under the status bar.
            .toolbarBackground(VColor.heroField, for: .navigationBar)
            .toolbarBackground(.visible, for: .navigationBar)
            .toolbarColorScheme(.dark, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    if let shareImage {
                        ShareLink(item: shareImage, preview: SharePreview("\(session.name) complete", image: shareImage)) {
                            Image(systemName: "square.and.arrow.up")
                                .font(.system(.body, weight: .semibold))
                                .foregroundStyle(VColor.heroText)
                                .frame(width: Size.minTouch, height: Size.minTouch)
                        }
                        .accessibilityLabel("Share workout")
                    }
                }
            }
            .safeAreaInset(edge: .bottom, spacing: 0) {
                VStack(spacing: 0) {
                    Hairline()
                    Button("Done") { model.cover = nil }
                        .buttonStyle(.accentCapsule)
                        .padding(.horizontal, Space.fieldInset)
                        .padding(.vertical, Space.sm)
                }
                .background(.bar)
            }
            .onAppear {
                withAnimation(Motion.adaptive(Motion.celebrate, reduceMotion: reduceMotion).delay(0.1)) { appeared = true }
                renderShareImage()
            }
            .sensoryFeedback(.success, trigger: appeared)
        }
    }

    // MARK: Hero

    private var hero: some View {
        VStack(alignment: .leading, spacing: 0) {
            Image(systemName: "checkmark.seal")
                .font(.system(.largeTitle, weight: .semibold))
                .foregroundStyle(VColor.ringWorkouts)
                // One bounce on arrival; none under Reduce Motion.
                .symbolEffect(.bounce, value: reduceMotion ? false : appeared)
                .accessibilityHidden(true)
            Text("Workout complete")
                .font(VFont.largeTitle)
                .foregroundStyle(VColor.heroText)
                .padding(.top, Space.md)
                .accessibilityAddTraits(.isHeader)
            Text(dateLine)
                .font(VFont.secondary)
                .foregroundStyle(VColor.heroTextSecondary)
                .padding(.top, Space.xxs)
            HeroNumber(value: Format.volume(session.volume, unit: model.unit, includeUnit: false), unit: model.unit.symbol)
                .padding(.top, Space.lg)
                .accessibilityLabel("Total volume \(Format.volume(session.volume, unit: model.unit))")
            if let change = summary.volumeChange {
                comparison(change)
                    .padding(.top, Space.xs)
            }
            Rectangle()
                .fill(VColor.heroHairline)
                .frame(height: 0.5)
                .padding(.top, Space.lg)
            statLine
                .padding(.top, Space.md)
        }
        .padding(.horizontal, Space.fieldInset)
        .padding(.top, Space.xs)
        .padding(.bottom, Space.fieldVertical)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(VColor.heroField)
        .scaleEffect(appeared || reduceMotion ? 1 : 0.98, anchor: .top)
        .opacity(appeared || reduceMotion ? 1 : 0)
    }

    /// "Lower A · Monday 5 October · 44 min".
    private var dateLine: String {
        [session.name, Format.longDate(session.startedAt, calendar: model.calendar), Format.duration(session.duration)]
            .joined(separator: " · ")
    }

    private func comparison(_ change: Double) -> some View {
        let up = change >= 0
        let text = "\(Format.signedPercent(change)) volume vs last \(session.name)"
        return Label {
            Text(text)
        } icon: {
            Image(systemName: up ? "arrow.up.right" : "arrow.down.right")
        }
        .labelStyle(TightLabelStyle())
        .font(VFont.secondaryEmphasized.monospacedDigit())
        // Cobalt on the hero field when up; a drop is plain information, not an alarm.
        .foregroundStyle(up ? VColor.ringWorkouts : VColor.heroTextSecondary)
        .accessibilityLabel(previousLabel.map { "\(text), \($0)" } ?? text)
    }

    private var previousLabel: String? {
        summary.previous.map { "last time \(Format.volume($0.volume, unit: model.unit)) on \(Format.shortDate($0.startedAt, calendar: model.calendar))" }
    }

    /// "6 exercises · 18 sets · 2 new records", numbers in white.
    private var statLine: some View {
        let records = summary.records.count
        let parts: [(String, String)] = [
            ("\(session.exercises.count)", session.exercises.count == 1 ? "exercise" : "exercises"),
            ("\(session.completedSetCount)", session.completedSetCount == 1 ? "set" : "sets"),
            ("\(records)", records == 1 ? "new record" : "new records")
        ]
        var line = Text("")
        for (offset, part) in parts.enumerated() {
            if offset > 0 { line = line + Text(" · ").foregroundStyle(VColor.heroTextSecondary) }
            line = line
                + Text(part.0).font(VFont.bodyEmphasized.monospacedDigit()).foregroundStyle(VColor.heroText)
                + Text(" \(part.1)").foregroundStyle(VColor.heroTextSecondary)
        }
        return line
            .font(VFont.body)
            .fixedSize(horizontal: false, vertical: true)
    }

    // MARK: Records

    private var records: some View {
        VStack(alignment: .leading, spacing: 0) {
            sectionTitle("New records")
            ForEach(Array(summary.records.enumerated()), id: \.element.id) { index, record in
                if index > 0 { Hairline(leading: Space.lg + Space.sm) }
                HStack(alignment: .center, spacing: Space.sm) {
                    Image(systemName: "checkmark.seal")
                        .font(.system(.title3, weight: .regular))
                        .foregroundStyle(VColor.inkTraining)
                        .frame(width: Space.lg)
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(record.exerciseName)
                            .font(VFont.body)
                            .foregroundStyle(VColor.textPrimary)
                        Text("\(record.improvementLabel(unit: model.unit)) on your best")
                            .font(VFont.fieldCaption.monospacedDigit())
                            .foregroundStyle(VColor.textSecondary)
                    }
                    Spacer(minLength: Space.sm)
                    Text(setText(weight: record.weight, reps: record.reps, includeUnit: true))
                        .font(VFont.data)
                        .foregroundStyle(VColor.textPrimary)
                }
                .padding(.vertical, Space.sm)
                .accessibilityElement(children: .combine)
                .accessibilityLabel("New record, \(record.exerciseName)")
                .accessibilityValue("\(setText(weight: record.weight, reps: record.reps, includeUnit: true)), \(record.improvementLabel(unit: model.unit)) on your best")
            }
        }
        .padding(.horizontal, Space.fieldInset)
        .padding(.top, Space.lg)
        .padding(.bottom, Space.md)
    }

    // MARK: Best sets

    private var bestSets: some View {
        VStack(alignment: .leading, spacing: 0) {
            sectionTitle("Best sets")
            ForEach(Array(session.exercises.enumerated()), id: \.element.id) { index, log in
                let name = model.catalog[log.exerciseID]?.name ?? log.exerciseID
                let working = log.completedWorkingSets
                let counted = working.isEmpty ? log.sets : working
                let detail = "\(counted.count) \(counted.count == 1 ? "set" : "sets") · "
                    + counted.map { "\($0.reps)" }.joined(separator: ", ")
                let best = log.heaviestSet.map { setText(weight: $0.weight, reps: $0.reps, includeUnit: false) } ?? "Warm-up only"
                if index > 0 { Hairline() }
                HStack(alignment: .center, spacing: Space.sm) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(name)
                            .font(VFont.body)
                            .foregroundStyle(VColor.textPrimary)
                        Text(detail)
                            .font(VFont.fieldCaption.monospacedDigit())
                            .foregroundStyle(VColor.textSecondary)
                    }
                    Spacer(minLength: Space.sm)
                    Text(best)
                        .font(VFont.data)
                        .foregroundStyle(log.heaviestSet == nil ? VColor.textSecondary : VColor.textPrimary)
                }
                .padding(.vertical, Space.sm)
                .accessibilityElement(children: .combine)
            }
        }
        .padding(.horizontal, Space.fieldInset)
        .padding(.top, Space.lg)
        .padding(.bottom, Space.md)
    }

    // MARK: Next step

    private func insight(_ rec: ProgressionRecommendation) -> some View {
        let name = model.catalog[rec.exerciseID]?.name ?? "your main lift"
        let target = rec.weight.map { "\(Format.weight($0, unit: model.unit)) × \(rec.reps)" } ?? "\(rec.reps) reps"
        let message: String = switch rec.action {
        case .increaseLoad: "Your \(name.lowercased()) performance improved again. Consider increasing to \(target) next session."
        case .increaseReps: "Solid \(name.lowercased()) session. Aim for \(target) next time before adding load."
        case .deload: "Your \(name.lowercased()) has dipped for three sessions. A lighter session at \(target) will help you recover."
        default: "Next \(name.lowercased()) target: \(target)."
        }
        return VStack(alignment: .leading, spacing: Space.xs) {
            Label("Next time", systemImage: Icon.recommendation)
                .font(VFont.secondaryEmphasized)
                .foregroundStyle(VColor.inkTraining)
                .accessibilityAddTraits(.isHeader)
            Text(message)
                .font(VFont.body)
                .foregroundStyle(VColor.textPrimary)
                .fixedSize(horizontal: false, vertical: true)
            Text(rec.reason)
                .font(VFont.secondary)
                .foregroundStyle(VColor.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, Space.fieldInset)
        .padding(.vertical, Space.lg)
        .accessibilityElement(children: .combine)
    }

    // MARK: Helpers

    private func sectionTitle(_ title: String) -> some View {
        Text(title)
            .font(VFont.title3.weight(.bold))
            .foregroundStyle(VColor.textPrimary)
            .padding(.bottom, Space.xs)
            .accessibilityAddTraits(.isHeader)
    }

    private func setText(weight: Double, reps: Int, includeUnit: Bool) -> String {
        weight > 0 ? "\(Format.weight(weight, unit: model.unit, includeUnit: includeUnit)) × \(reps)" : "\(reps) reps"
    }

    @MainActor
    private func renderShareImage() {
        let card = ShareCard(summary: summary, unit: model.unit)
            .environment(\.colorScheme, .dark)
        let renderer = ImageRenderer(content: card)
        renderer.scale = 3
        if let image = renderer.uiImage { shareImage = Image(uiImage: image) }
    }
}

/// Image for sharing: the hero field with the sentence-case wordmark.
/// Rendered offscreen at a fixed size, always in the dark appearance.
private struct ShareCard: View {
    var summary: WorkoutSummary
    var unit: WeightUnit

    var body: some View {
        VStack(alignment: .leading, spacing: Space.md) {
            Text("Vector")
                .font(VFont.secondaryEmphasized)
                .foregroundStyle(VColor.heroTextSecondary)
            Text(summary.session.name)
                .font(VFont.largeTitle)
                .foregroundStyle(VColor.heroText)
            HStack(spacing: Space.lg) {
                stat("Volume", Format.volume(summary.session.volume, unit: unit))
                stat("Sets", "\(summary.session.completedSetCount)")
                stat("Time", Format.duration(summary.session.duration))
            }
            if !summary.records.isEmpty {
                Label("\(summary.records.count) new record\(summary.records.count == 1 ? "" : "s")", systemImage: "checkmark.seal")
                    .font(VFont.bodyEmphasized)
                    .foregroundStyle(VColor.ringWorkouts)
            }
        }
        .padding(Space.lg)
        .frame(width: 360, alignment: .leading)
        .background(VColor.heroField)
        .dynamicTypeSize(.large)
    }

    private func stat(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(value).font(VFont.fieldStat).foregroundStyle(VColor.heroText)
            Text(label).font(VFont.fieldCaption).foregroundStyle(VColor.heroTextSecondary)
        }
    }
}
