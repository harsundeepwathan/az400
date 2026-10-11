import SwiftUI
import KiraCore

/// Money text with tabular digits and a VoiceOver phrasing ("2,845 ringgit 60 sen").
struct MoneyText: View {
    let money: Money
    var style: MoneyFormatter = .standard
    var font: Font = .body

    var body: some View {
        Text(style.string(from: money))
            .font(font)
            .monospacedDigit()
            .accessibilityLabel(MoneyFormatter.standard.accessibilityString(from: money))
    }
}

/// A grouped surface. Used for top-level sections only — never nested inside another card.
struct Surface<Content: View>: View {
    var padding: CGFloat = KiraSpacing.l
    var radius: CGFloat = KiraRadius.card
    @ViewBuilder var content: Content

    var body: some View {
        content
            .padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(KiraColor.surface, in: RoundedRectangle(cornerRadius: radius, style: .continuous))
    }
}

struct SectionHeader: View {
    let title: String
    var actionTitle: String?
    var action: (() -> Void)?

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title).font(.kiraSection).foregroundStyle(KiraColor.textPrimary)
                .accessibilityAddTraits(.isHeader)
            Spacer()
            if let actionTitle, let action {
                Button(actionTitle, action: action).font(.subheadline.weight(.medium)).tint(KiraColor.accent)
            }
        }
    }
}

/// Category glyph in a soft tinted circle.
struct CategoryIcon: View {
    let category: CategoryDefinition?
    var size: CGFloat = 40

    var body: some View {
        let definition = category ?? BuiltInCategory.other.definition
        Image(systemName: definition.symbol)
            .font(.system(size: size * 0.42, weight: .medium))
            .foregroundStyle(definition.color)
            .frame(width: size, height: size)
            .background(definition.softColor, in: Circle())
            .accessibilityHidden(true)
    }
}

/// Status pill. Always text + colour, never colour alone.
struct StatusBadge: View {
    let status: TransactionStatus

    var body: some View {
        switch status {
        case .confirmed, .superseded:
            EmptyView()
        case .reconciled:
            Label("Matched", systemImage: "checkmark.seal").labelStyle(.iconOnly)
                .font(.caption).foregroundStyle(KiraColor.accent)
                .accessibilityLabel("Matched with statement")
        case .pending:
            pill("Pending", fg: KiraColor.warning, bg: KiraColor.warningSoft)
        case .draft:
            pill("Not paid yet", fg: KiraColor.textSecondary, bg: KiraColor.track)
        }
    }

    private func pill(_ text: String, fg: Color, bg: Color) -> some View {
        Text(text).font(.caption2.weight(.semibold)).foregroundStyle(fg)
            .padding(.horizontal, 6).padding(.vertical, 2)
            .background(bg, in: Capsule())
    }
}

/// Linear progress with an expected-pace marker. Colour shifts only when meaningful,
/// and the state is also stated in text by the caller.
struct BudgetBar: View {
    let fraction: Double
    var pace: Double?
    var height: CGFloat = 10

    var body: some View {
        GeometryReader { proxy in
            let clamped = min(max(fraction, 0), 1)
            ZStack(alignment: .leading) {
                Capsule().fill(KiraColor.track)
                Capsule().fill(fillColor).frame(width: max(proxy.size.width * clamped, clamped > 0 ? height : 0))
                if let pace {
                    Rectangle().fill(KiraColor.textPrimary.opacity(0.35))
                        .frame(width: 2, height: height + 6)
                        .offset(x: proxy.size.width * min(max(pace, 0), 1) - 1)
                }
            }
        }
        .frame(height: height)
        .animation(.smooth(duration: 0.5), value: fraction)
        .accessibilityElement()
        .accessibilityLabel("Budget used")
        .accessibilityValue(PercentFormatter.string(fraction))
    }

    private var fillColor: Color {
        if fraction > 1 { return KiraColor.error }
        if fraction >= 0.85 { return KiraColor.warning }
        return KiraColor.accent
    }
}

struct EmptyStateView: View {
    let symbol: String
    let title: String
    let message: String
    var actionTitle: String?
    var action: (() -> Void)?

    var body: some View {
        VStack(spacing: KiraSpacing.m) {
            Image(systemName: symbol)
                .font(.system(size: 34, weight: .light))
                .foregroundStyle(KiraColor.accent)
                .frame(width: 72, height: 72)
                .background(KiraColor.accentSoft, in: Circle())
            Text(title).font(.headline).foregroundStyle(KiraColor.textPrimary)
            Text(message).font(.subheadline).foregroundStyle(KiraColor.textSecondary).multilineTextAlignment(.center)
            if let actionTitle, let action {
                Button(actionTitle, action: action).buttonStyle(KiraPrimaryButtonStyle()).padding(.top, KiraSpacing.s)
            }
        }
        .padding(KiraSpacing.xl)
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .combine)
    }
}

struct KiraPrimaryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.body.weight(.semibold))
            .foregroundStyle(.white)
            .padding(.horizontal, KiraSpacing.xl)
            .padding(.vertical, 14)
            .frame(minHeight: 50)
            .background(KiraColor.accent.opacity(configuration.isPressed ? 0.85 : 1), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .scaleEffect(configuration.isPressed ? 0.98 : 1)
            .animation(.snappy(duration: 0.15), value: configuration.isPressed)
    }
}

/// Small explanatory banner (confidence notes, limitations).
struct NoticeBanner: View {
    enum Tone { case info, caution, error }
    let tone: Tone
    let text: String

    var body: some View {
        HStack(alignment: .top, spacing: KiraSpacing.s) {
            Image(systemName: icon).foregroundStyle(foreground)
            Text(text).font(.footnote).foregroundStyle(KiraColor.textPrimary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(KiraSpacing.m)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(background, in: RoundedRectangle(cornerRadius: KiraRadius.small, style: .continuous))
        .accessibilityElement(children: .combine)
    }

    private var icon: String {
        switch tone {
        case .info: return "info.circle"
        case .caution: return "exclamationmark.triangle"
        case .error: return "xmark.octagon"
        }
    }
    private var foreground: Color {
        switch tone {
        case .info: return KiraColor.accent
        case .caution: return KiraColor.warning
        case .error: return KiraColor.error
        }
    }
    private var background: Color {
        switch tone {
        case .info: return KiraColor.accentSoft
        case .caution: return KiraColor.warningSoft
        case .error: return KiraColor.errorSoft
        }
    }
}

extension View {
    /// Standard screen background.
    func kiraScreen() -> some View {
        self.background(KiraColor.background.ignoresSafeArea())
            .scrollContentBackground(.hidden)
    }
}

extension Date {
    var kiraShort: String { formatted(.dateTime.day().month(.abbreviated)) }
    var kiraMedium: String { formatted(.dateTime.day().month(.abbreviated).year()) }
    var kiraWithTime: String { formatted(.dateTime.day().month(.abbreviated).hour().minute()) }
}
