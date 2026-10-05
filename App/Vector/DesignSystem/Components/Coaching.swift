import SwiftUI
import VectorCore

/// A coaching insight with its evidence one tap away. Pro-only insights are
/// shown to free users as a teaser: the headline is visible (proving the
/// value exists in *their* data) while the detail is locked.
struct InsightCard: View {
    var insight: CoachInsight
    var isLocked = false
    var onAction: ((CoachInsight.Action) -> Void)?
    var onUnlock: (() -> Void)?
    @State private var showsEvidence = false

    var body: some View {
        VStack(alignment: .leading, spacing: Space.sm) {
            HStack(spacing: Space.sm) {
                IconBadge(symbol: insight.symbol, tint: tint, fill: tint.opacity(0.14), size: 32)
                VStack(alignment: .leading, spacing: 1) {
                    Text(insight.title)
                        .font(VFont.secondaryEmphasized)
                        .foregroundStyle(VColor.textPrimary)
                    Text(insight.category.rawValue.capitalized)
                        .font(VFont.caption)
                        .foregroundStyle(VColor.textSecondary)
                }
                Spacer()
                if insight.requiresPro { ProBadge() }
            }

            Text(insight.message)
                .font(VFont.body)
                .foregroundStyle(VColor.textPrimary)
                .fixedSize(horizontal: false, vertical: true)
                .redacted(reason: isLocked ? .placeholder : [])
                .overlay(alignment: .center) {
                    if isLocked {
                        Button {
                            onUnlock?()
                        } label: {
                            Label("Unlock with Pro", systemImage: Icon.lock)
                                .font(VFont.secondaryEmphasized)
                        }
                        .buttonStyle(.secondary(compact: true))
                    }
                }

            if !isLocked {
                if let suggestion = insight.suggestion {
                    Label(suggestion, systemImage: "lightbulb")
                        .font(VFont.secondary)
                        .foregroundStyle(VColor.textSecondary)
                }

                if showsEvidence {
                    EvidenceList(evidence: insight.evidence)
                        .transition(.opacity.combined(with: .move(edge: .top)))
                }

                HStack {
                    Button {
                        withAnimation(Motion.smooth) { showsEvidence.toggle() }
                    } label: {
                        Label(showsEvidence ? "Hide data" : "Why?", systemImage: showsEvidence ? "chevron.up" : Icon.info)
                            .font(VFont.secondaryEmphasized)
                            .foregroundStyle(VColor.textSecondary)
                            .frame(minHeight: Size.minTouch)
                    }
                    .buttonStyle(.plain)
                    Spacer()
                    if let action = insight.action, let title = insight.actionTitle, let onAction {
                        Button(title) { onAction(action) }
                            .font(VFont.secondaryEmphasized)
                            .foregroundStyle(VColor.accentText)
                            .frame(minHeight: Size.minTouch)
                    }
                }
            }
        }
        .card()
        .accessibilityElement(children: .contain)
    }

    private var tint: Color {
        switch insight.tone {
        case .positive: VColor.success
        case .neutral: VColor.accentText
        case .attention: VColor.warning
        }
    }
}

struct EvidenceList: View {
    var evidence: [Evidence]

    var body: some View {
        VStack(spacing: 0) {
            ForEach(Array(evidence.enumerated()), id: \.offset) { index, item in
                HStack {
                    Text(item.label)
                        .font(VFont.secondary)
                        .foregroundStyle(VColor.textSecondary)
                    Spacer()
                    Text(item.value)
                        .font(VFont.secondaryEmphasized.monospacedDigit())
                        .foregroundStyle(VColor.textPrimary)
                        .multilineTextAlignment(.trailing)
                }
                .padding(.vertical, Space.xs)
                .accessibilityElement(children: .combine)
                if index < evidence.count - 1 { Hairline() }
            }
        }
        .padding(.horizontal, Space.sm)
        .background(VColor.surfaceSunken, in: RoundedRectangle(cornerRadius: Radius.sm, style: .continuous))
    }
}

/// Next-session recommendation with the reasoning stated plainly and the
/// option to accept or adjust it.
struct AIRecommendationCard: View {
    var recommendation: ProgressionRecommendation
    var unit: WeightUnit
    var isAccepted = false
    var onAccept: (() -> Void)?
    var onModify: (() -> Void)?

    var body: some View {
        VStack(alignment: .leading, spacing: Space.sm) {
            HStack {
                Label("NEXT SESSION", systemImage: Icon.sparkles)
                    .font(VFont.sectionHeading)
                    .tracking(0.6)
                    .foregroundStyle(VColor.accentText)
                Spacer()
                Text(recommendation.action.title)
                    .font(VFont.captionEmphasized)
                    .foregroundStyle(VColor.textSecondary)
            }

            HStack(alignment: .firstTextBaseline, spacing: Space.xs) {
                Text(headline)
                    .font(VFont.metric)
                    .foregroundStyle(VColor.textPrimary)
                Text("× \(recommendation.sets) sets")
                    .font(VFont.secondary)
                    .foregroundStyle(VColor.textSecondary)
            }

            Text(recommendation.reason)
                .font(VFont.secondary)
                .foregroundStyle(VColor.textPrimary)
                .fixedSize(horizontal: false, vertical: true)

            EvidenceList(evidence: recommendation.evidence)

            if onAccept != nil || onModify != nil {
                HStack(spacing: Space.sm) {
                    if let onModify {
                        Button("Adjust", action: onModify).buttonStyle(.secondary(compact: false))
                    }
                    if let onAccept {
                        Button(action: onAccept) {
                            Label(isAccepted ? "Accepted" : "Use this", systemImage: isAccepted ? Icon.check : Icon.sparkles)
                        }
                        .buttonStyle(.primary)
                        .disabled(isAccepted)
                    }
                }
            }
        }
        .card()
        .sensoryFeedback(.success, trigger: isAccepted)
    }

    private var headline: String {
        if let weight = recommendation.weight, weight > 0 {
            return "\(Format.weight(weight, unit: unit)) × \(recommendation.reps)"
        }
        return "\(recommendation.reps) reps"
    }
}

// MARK: - Empty, loading, error

/// Empty states always lead to an action. There are no dead ends.
struct EmptyStateView: View {
    var symbol: String
    var title: String
    var message: String
    var actionTitle: String?
    var action: (() -> Void)?

    var body: some View {
        VStack(spacing: Space.sm) {
            IconBadge(symbol: symbol, size: 52)
                .padding(.bottom, Space.xxs)
            Text(title)
                .font(VFont.headline)
                .foregroundStyle(VColor.textPrimary)
                .multilineTextAlignment(.center)
            Text(message)
                .font(VFont.secondary)
                .foregroundStyle(VColor.textSecondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            if let actionTitle, let action {
                Button(actionTitle, action: action)
                    .buttonStyle(.primary(compact: true))
                    .padding(.top, Space.xs)
            }
        }
        .padding(.vertical, Space.lg)
        .padding(.horizontal, Space.md)
        .frame(maxWidth: .infinity)
        .card()
    }
}

struct ErrorStateView: View {
    var title: String
    var message: String
    var retryTitle = "Try again"
    var retry: () -> Void

    var body: some View {
        VStack(spacing: Space.sm) {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(.title2, weight: .semibold))
                .foregroundStyle(VColor.warning)
            Text(title).font(VFont.headline).foregroundStyle(VColor.textPrimary)
            Text(message)
                .font(VFont.secondary)
                .foregroundStyle(VColor.textSecondary)
                .multilineTextAlignment(.center)
            Button(retryTitle, action: retry).buttonStyle(.secondary(compact: true))
        }
        .padding(Space.lg)
        .frame(maxWidth: .infinity)
    }
}

/// Shimmering placeholder for content that is computing or loading.
struct Shimmer: ViewModifier {
    var active: Bool
    @State private var phase: CGFloat = -1
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        content
            .redacted(reason: active ? .placeholder : [])
            .overlay {
                if active && !reduceMotion {
                    GeometryReader { proxy in
                        LinearGradient(colors: [.clear, VColor.surface.opacity(0.6), .clear],
                                       startPoint: .leading, endPoint: .trailing)
                            .frame(width: proxy.size.width * 0.6)
                            .offset(x: phase * proxy.size.width * 1.4)
                    }
                    .mask(content.redacted(reason: .placeholder))
                    .allowsHitTesting(false)
                    .onAppear {
                        withAnimation(.linear(duration: 1.2).repeatForever(autoreverses: false)) { phase = 1 }
                    }
                }
            }
    }
}

extension View {
    func skeleton(_ active: Bool) -> some View { modifier(Shimmer(active: active)) }
}

/// A Pro feature presented with a preview of what it does, never a blank lock screen.
struct LockedFeatureCard: View {
    var feature: ProFeature
    var headline: String
    var message: String
    var onUnlock: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: Space.sm) {
            HStack {
                IconBadge(symbol: feature.symbol)
                Spacer()
                ProBadge()
            }
            Text(headline).font(VFont.headline).foregroundStyle(VColor.textPrimary)
            Text(message)
                .font(VFont.secondary)
                .foregroundStyle(VColor.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            Button("See what's included", action: onUnlock)
                .buttonStyle(.secondary(compact: true))
        }
        .card()
    }
}

/// Transient top banner (PRs, saves, undo).
struct Toast: View {
    var symbol: String
    var title: String
    var subtitle: String?
    var tint: Color = VColor.accentText

    var body: some View {
        HStack(spacing: Space.sm) {
            Image(systemName: symbol)
                .font(.system(.headline, weight: .bold))
                .foregroundStyle(tint)
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(VFont.secondaryEmphasized).foregroundStyle(VColor.textPrimary)
                if let subtitle {
                    Text(subtitle).font(VFont.caption).foregroundStyle(VColor.textSecondary)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, Space.md)
        .padding(.vertical, Space.sm)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: Radius.md, style: .continuous))
        .shadow(color: .black.opacity(0.12), radius: 16, y: 6)
        .accessibilityElement(children: .combine)
    }
}
