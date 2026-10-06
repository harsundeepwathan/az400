import SwiftUI
import VectorCore

/// "What should I do today?" One headline, up to four lines, each built from
/// the user's own data. Tap a line to see the numbers behind it.
struct TodayBriefCard: View {
    var brief: DailyBrief
    @Environment(AppModel.self) private var model
    @State private var expanded: String?

    var body: some View {
        VStack(alignment: .leading, spacing: Space.md) {
            Text(brief.headline)
                .font(VFont.title)
                .foregroundStyle(VColor.textPrimary)
                .accessibilityAddTraits(.isHeader)
            if brief.lines.isEmpty {
                Text(emptyMessage)
                    .font(VFont.body)
                    .foregroundStyle(VColor.textSecondary)
            }
            ForEach(brief.lines) { line in
                VStack(alignment: .leading, spacing: Space.xs) {
                    Button {
                        withAnimation(Motion.snappy) { expanded = expanded == line.id ? nil : line.id }
                    } label: {
                        HStack(alignment: .firstTextBaseline, spacing: Space.sm) {
                            Image(systemName: symbol(line.kind))
                                .foregroundStyle(tint(line.kind))
                                .frame(width: 22)
                                .accessibilityHidden(true)
                            Text(line.text)
                                .font(VFont.body)
                                .foregroundStyle(VColor.textPrimary)
                                .multilineTextAlignment(.leading)
                                .fixedSize(horizontal: false, vertical: true)
                            Spacer(minLength: 0)
                            Image(systemName: "chevron.down")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(VColor.textTertiary)
                                .rotationEffect(.degrees(expanded == line.id ? 180 : 0))
                                .accessibilityHidden(true)
                        }
                        .frame(minHeight: Size.minTouch)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityHint(expanded == line.id ? "Hides the data behind this" : "Shows the data behind this")
                    if expanded == line.id {
                        VStack(alignment: .leading, spacing: 4) {
                            ForEach(line.evidence, id: \.self) { item in
                                HStack(alignment: .firstTextBaseline) {
                                    Text(item.label).foregroundStyle(VColor.textSecondary)
                                    Spacer()
                                    Text(item.value).foregroundStyle(VColor.textPrimary).multilineTextAlignment(.trailing)
                                }
                                .font(VFont.caption.monospacedDigit())
                            }
                        }
                        .padding(Space.sm)
                        .background(VColor.surfaceSunken, in: RoundedRectangle(cornerRadius: Radius.sm, style: .continuous))
                        .padding(.leading, 22 + Space.sm)
                        .transition(.opacity.combined(with: .move(edge: .top)))
                    }
                }
            }
        }
        .card()
        .onAppear { if !brief.lines.isEmpty { model.track(.aiRecommendationViewed, ["surface": "today"]) } }
    }

    private var emptyMessage: String {
        model.sessions.isEmpty
            ? "Log your first workout and meals. Recommendations here come from your own numbers, so they start after a few days."
            : "Keep logging: protein, strength and weight trends appear here as soon as there's enough data."
    }

    private func symbol(_ kind: DailyBrief.Line.Kind) -> String {
        switch kind {
        case .training: Icon.train
        case .nutrition: "fork.knife"
        case .progress: "chart.line.uptrend.xyaxis"
        case .bodyWeight: "scalemass"
        }
    }

    private func tint(_ kind: DailyBrief.Line.Kind) -> Color {
        switch kind {
        case .training: VColor.accentText
        case .nutrition: VColor.protein
        case .progress: VColor.success
        case .bodyWeight: VColor.textSecondary
        }
    }
}

/// The weekly adaptive check-in: what happened, what it means, one decision.
struct NutritionCheckInCard: View {
    var result: CheckInResult
    @Environment(AppModel.self) private var model
    @State private var showsDetail = false

    var body: some View {
        switch result {
        case let .ready(checkIn, reason, evidence):
            VStack(alignment: .leading, spacing: Space.md) {
                HStack(alignment: .firstTextBaseline) {
                    Label("Weekly check-in", systemImage: "arrow.triangle.2.circlepath")
                        .font(VFont.headline)
                        .foregroundStyle(VColor.textPrimary)
                    Spacer()
                    if checkIn.change != 0 {
                        Text("\(checkIn.change > 0 ? "+" : "\u{2212}")\(Format.integer(abs(checkIn.change))) kcal")
                            .font(VFont.headline.monospacedDigit())
                            .foregroundStyle(VColor.accentText)
                    }
                }
                Text(reason)
                    .font(VFont.secondary)
                    .foregroundStyle(VColor.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                DisclosureGroup("The numbers", isExpanded: $showsDetail) {
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(evidence, id: \.self) { item in
                            LabeledContent(item.label, value: item.value)
                        }
                        Text("Expenditure is estimated from your logged food and weight trend (about 7,700 kcal per kg). It's an estimate, and it improves the more consistently you log.")
                            .foregroundStyle(VColor.textTertiary)
                            .padding(.top, 2)
                    }
                    .font(VFont.caption.monospacedDigit())
                    .padding(.top, Space.xs)
                }
                .font(VFont.secondaryEmphasized)
                .tint(VColor.textSecondary)
                if checkIn.change == 0 {
                    Button("Got It") { model.keepTargets(checkIn) }
                        .buttonStyle(.secondary)
                } else {
                    HStack(spacing: Space.sm) {
                        Button("Keep Current") { model.keepTargets(checkIn) }
                            .buttonStyle(.secondary)
                        Button("Update to \(Format.integer(checkIn.recommendedCalories))") { model.applyCheckIn(checkIn) }
                            .buttonStyle(.primary)
                    }
                }
            }
            .card()
            .onAppear { model.track(.nutritionCheckInViewed, ["ready": true]) }
        case let .needsMoreData(missing, evidence):
            VStack(alignment: .leading, spacing: Space.xs) {
                Label("Weekly check-in", systemImage: "arrow.triangle.2.circlepath")
                    .font(VFont.headline)
                    .foregroundStyle(VColor.textPrimary)
                Text("Your calorie target adapts to how your weight actually responds. \(missing)")
                    .font(VFont.secondary)
                    .foregroundStyle(VColor.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: Space.md) {
                    ForEach(evidence, id: \.self) { item in
                        VStack(alignment: .leading, spacing: 0) {
                            Text(item.value).font(VFont.secondaryEmphasized.monospacedDigit()).foregroundStyle(VColor.textPrimary)
                            Text(item.label).font(VFont.caption).foregroundStyle(VColor.textSecondary)
                        }
                    }
                }
                .padding(.top, 2)
                HStack(spacing: Space.xs) {
                    QuickActionButton(title: "Log Weight", symbol: "scalemass") { model.sheet = .bodyWeight }
                }
            }
            .card()
        }
    }
}
