import SwiftUI

/// Card surface. In light mode it lifts with a soft shadow; in dark mode
/// shadows disappear against black, so a hairline stroke defines the edge.
struct CardModifier: ViewModifier {
    var padding: CGFloat = Space.md
    var elevation: Elevation = .card
    var radius: CGFloat = Radius.lg
    var fill: Color = VColor.surface
    @Environment(\.colorScheme) private var colorScheme

    func body(content: Content) -> some View {
        let shadow = elevation.shadow
        return content
            .padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(fill, in: RoundedRectangle(cornerRadius: radius, style: .continuous))
            .overlay {
                if colorScheme == .dark && elevation != .flat {
                    RoundedRectangle(cornerRadius: radius, style: .continuous)
                        .strokeBorder(VColor.separator, lineWidth: 0.5)
                }
            }
            .shadow(color: colorScheme == .dark ? .clear : shadow.color, radius: shadow.radius, y: shadow.y)
    }
}

extension View {
    func card(padding: CGFloat = Space.md, elevation: Elevation = .card, radius: CGFloat = Radius.lg,
              fill: Color = VColor.surface) -> some View {
        modifier(CardModifier(padding: padding, elevation: elevation, radius: radius, fill: fill))
    }

    /// Standard screen background.
    func screenBackground() -> some View {
        background(VColor.background.ignoresSafeArea())
    }
}

/// Uppercase eyebrow with an optional trailing action. Used to label
/// dashboard sections ("TODAY'S TRAINING").
struct SectionHeader: View {
    var title: String
    var actionTitle: String?
    var action: (() -> Void)?

    init(_ title: String, actionTitle: String? = nil, action: (() -> Void)? = nil) {
        self.title = title
        self.actionTitle = actionTitle
        self.action = action
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title.uppercased())
                .font(VFont.sectionHeading)
                .tracking(0.6)
                .foregroundStyle(VColor.textSecondary)
                .accessibilityAddTraits(.isHeader)
            Spacer()
            if let actionTitle, let action {
                Button(actionTitle, action: action)
                    .font(VFont.secondaryEmphasized)
                    .foregroundStyle(VColor.accentText)
                    .frame(minHeight: Size.minTouch)
            }
        }
        .padding(.horizontal, Space.xxs)
    }
}

/// Small rounded label, e.g. muscle groups or meta information.
struct Chip: View {
    var text: String
    var symbol: String?
    var tint: Color = VColor.textSecondary
    var fill: Color = VColor.surfaceSunken

    var body: some View {
        HStack(spacing: Space.xxs) {
            if let symbol {
                Image(systemName: symbol).imageScale(.small)
            }
            Text(text)
        }
        .font(VFont.captionEmphasized)
        .foregroundStyle(tint)
        .padding(.horizontal, Space.xs)
        .padding(.vertical, 5)
        .background(fill, in: Capsule())
    }
}

struct MuscleChips: View {
    var muscles: [String]
    var limit = 3

    var body: some View {
        HStack(spacing: Space.xs) {
            ForEach(muscles.prefix(limit), id: \.self) { muscle in
                Chip(text: muscle)
            }
            if muscles.count > limit {
                Chip(text: "+\(muscles.count - limit)")
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Targets " + muscles.joined(separator: ", "))
    }
}

/// Tinted circular icon used as a leading accessory in rows and cards.
struct IconBadge: View {
    var symbol: String
    var tint: Color = VColor.accentText
    var fill: Color = VColor.accentSoft
    var size: CGFloat = Size.iconBadge

    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: size * 0.42, weight: .semibold))
            .foregroundStyle(tint)
            .frame(width: size, height: size)
            .background(fill, in: RoundedRectangle(cornerRadius: size * 0.3, style: .continuous))
            .accessibilityHidden(true)
    }
}

struct ProBadge: View {
    var body: some View {
        Text("PRO")
            .font(.system(.caption2, design: .rounded, weight: .heavy))
            .tracking(0.8)
            .foregroundStyle(VColor.surface)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(VColor.pro, in: Capsule())
            .accessibilityLabel("Pro feature")
    }
}

/// Thin hairline divider aligned to content.
struct Hairline: View {
    var leading: CGFloat = 0
    var body: some View {
        Rectangle()
            .fill(VColor.separator)
            .frame(height: 0.5)
            .padding(.leading, leading)
    }
}
