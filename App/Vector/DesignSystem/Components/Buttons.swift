import SwiftUI

/// Filled accent button for the single most important action on a screen.
struct PrimaryButtonStyle: ButtonStyle {
    var height: CGFloat = Size.buttonHeight
    var fullWidth = true
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(VFont.bodyEmphasized)
            .foregroundStyle(VColor.textOnAccent)
            .frame(maxWidth: fullWidth ? .infinity : nil, minHeight: height)
            .padding(.horizontal, Space.lg)
            .background(isEnabled ? VColor.accent : VColor.textTertiary,
                        in: RoundedRectangle(cornerRadius: Radius.md, style: .continuous))
            .scaleEffect(configuration.isPressed ? 0.98 : 1)
            .opacity(configuration.isPressed ? 0.92 : 1)
            .animation(configuration.isPressed ? Motion.press : Motion.snappy, value: configuration.isPressed)
    }
}

/// Tinted button for secondary actions that still deserve emphasis.
struct SecondaryButtonStyle: ButtonStyle {
    var height: CGFloat = Size.buttonHeight
    var fullWidth = true

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(VFont.bodyEmphasized)
            .foregroundStyle(VColor.accentText)
            .frame(maxWidth: fullWidth ? .infinity : nil, minHeight: height)
            .padding(.horizontal, Space.md)
            .background(VColor.accentSoft, in: RoundedRectangle(cornerRadius: Radius.md, style: .continuous))
            .scaleEffect(configuration.isPressed ? 0.98 : 1)
            .animation(configuration.isPressed ? Motion.press : Motion.snappy, value: configuration.isPressed)
    }
}

/// Neutral button on sunken fill, used in quick-action grids and toolbars.
struct QuietButtonStyle: ButtonStyle {
    var height: CGFloat = Size.compactButtonHeight

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(VFont.secondaryEmphasized)
            .foregroundStyle(VColor.textPrimary)
            .frame(maxWidth: .infinity, minHeight: max(height, Size.minTouch))
            .padding(.horizontal, Space.sm)
            .background(VColor.surfaceSunken.opacity(configuration.isPressed ? 0.7 : 1),
                        in: RoundedRectangle(cornerRadius: Radius.sm, style: .continuous))
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .animation(configuration.isPressed ? Motion.press : Motion.snappy, value: configuration.isPressed)
    }
}

/// Subtle scale feedback for tappable cards and rows.
struct PressableStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .contentShape(Rectangle())
            .scaleEffect(configuration.isPressed ? 0.985 : 1)
            .opacity(configuration.isPressed ? 0.9 : 1)
            .animation(configuration.isPressed ? Motion.press : Motion.snappy, value: configuration.isPressed)
    }
}

extension ButtonStyle where Self == PrimaryButtonStyle {
    static var primary: PrimaryButtonStyle { PrimaryButtonStyle() }
    static func primary(compact: Bool) -> PrimaryButtonStyle {
        PrimaryButtonStyle(height: compact ? Size.compactButtonHeight : Size.buttonHeight, fullWidth: !compact)
    }
}

extension ButtonStyle where Self == SecondaryButtonStyle {
    static var secondary: SecondaryButtonStyle { SecondaryButtonStyle() }
    static func secondary(compact: Bool) -> SecondaryButtonStyle {
        SecondaryButtonStyle(height: compact ? Size.compactButtonHeight : Size.buttonHeight, fullWidth: !compact)
    }
}

extension ButtonStyle where Self == QuietButtonStyle {
    static var quiet: QuietButtonStyle { QuietButtonStyle() }
}

extension ButtonStyle where Self == PressableStyle {
    static var pressable: PressableStyle { PressableStyle() }
}

/// Convenience wrapper for the canonical primary CTA with an optional symbol.
struct PrimaryButton: View {
    var title: String
    var symbol: String?
    var action: () -> Void

    init(_ title: String, symbol: String? = nil, action: @escaping () -> Void) {
        self.title = title
        self.symbol = symbol
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            HStack(spacing: Space.xs) {
                if let symbol { Image(systemName: symbol) }
                Text(title)
            }
        }
        .buttonStyle(.primary)
    }
}

/// Vertical icon + label tile used for quick actions (Scan Meal, Log Food…).
struct QuickActionButton: View {
    var title: String
    var symbol: String
    var prominent = false
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 6) {
                Image(systemName: symbol)
                    .font(.system(.title3, weight: .semibold))
                    .foregroundStyle(prominent ? VColor.textOnAccent : VColor.accentText)
                Text(title)
                    .font(VFont.captionEmphasized)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
            .foregroundStyle(prominent ? VColor.textOnAccent : VColor.textPrimary)
            .frame(maxWidth: .infinity, minHeight: 64)
            .background(prominent ? VColor.accent : VColor.surfaceSunken,
                        in: RoundedRectangle(cornerRadius: Radius.md, style: .continuous))
        }
        .buttonStyle(.pressable)
    }
}
