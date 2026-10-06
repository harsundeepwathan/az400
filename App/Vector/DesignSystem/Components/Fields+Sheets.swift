import SwiftUI

// Building blocks for the Fields sheets (weekly check-in, paywall,
// onboarding): the dark hero field outside Today, inline sheet titles,
// the round close button, evidence rows and the pinned action bar.

// MARK: - Hero field

/// The dark hero band holding a screen's one decision or promise.
/// Full bleed, no radius, white ink. Content is inset `Space.fieldInset`.
struct HeroField<Content: View>: View {
    var spacing: CGFloat = Space.sm
    @ViewBuilder var content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: spacing) {
            content()
        }
        .padding(.horizontal, Space.fieldInset)
        .padding(.vertical, Space.fieldVertical)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(VColor.heroField)
        .accessibilityElement(children: .contain)
    }
}

/// The category line at the top of a hero field ("Calories", "On track"),
/// in the field's secondary ink with an SF Symbol.
struct HeroLabel: View {
    var title: String
    var symbol: String

    init(_ title: String, symbol: String) {
        self.title = title
        self.symbol = symbol
    }

    var body: some View {
        Label(title, systemImage: symbol)
            .font(VFont.secondaryEmphasized)
            .foregroundStyle(VColor.heroTextSecondary)
            .accessibilityAddTraits(.isHeader)
    }
}

/// White 14% hairline for use inside the hero field.
struct HeroHairline: View {
    var body: some View {
        Rectangle().fill(VColor.heroHairline).frame(height: 0.5)
    }
}

// MARK: - Sheet chrome

/// Inline sheet title with a secondary subtitle ("Weekly check-in" /
/// "Week of 28 Sep"). Use as the `.principal` toolbar item.
struct SheetTitle: View {
    var title: String
    var subtitle: String?

    var body: some View {
        VStack(spacing: 0) {
            Text(title)
                .font(VFont.headline)
                .foregroundStyle(VColor.textPrimary)
            if let subtitle {
                Text(subtitle)
                    .font(VFont.caption)
                    .foregroundStyle(VColor.textSecondary)
            }
        }
        .lineLimit(1)
        .minimumScaleFactor(0.8)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isHeader)
    }
}

/// Round quiet close button (xmark on ink at 6%) with a 44 pt target.
struct SheetCloseButton: View {
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: "xmark")
                .font(.system(.footnote, weight: .bold))
                .foregroundStyle(VColor.textSecondary)
                .frame(width: 30, height: 30)
                .background(VColor.quietFill, in: Circle())
                .frame(width: Size.minTouch, height: Size.minTouch)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Close")
    }
}

/// Bottom bar for a screen's pinned actions: on `.bar` material with a
/// top hairline. Place inside `.safeAreaInset(edge: .bottom, spacing: 0)`.
struct PinnedActionBar<Content: View>: View {
    var spacing: CGFloat = Space.xxs
    @ViewBuilder var content: () -> Content

    var body: some View {
        VStack(spacing: spacing) {
            content()
        }
        .padding(.horizontal, Space.fieldInset)
        .padding(.top, Space.sm)
        .padding(.bottom, Space.xs)
        .frame(maxWidth: .infinity)
        .background(.bar)
        .overlay(alignment: .top) { Hairline() }
    }
}

/// Plain accent text button with a 44 pt target ("Keep current").
struct TextActionButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(VFont.bodyEmphasized)
            .foregroundStyle(VColor.accentText)
            .frame(maxWidth: .infinity, minHeight: Size.minTouch)
            .contentShape(Rectangle())
            .opacity(configuration.isPressed ? 0.6 : 1)
            .animation(configuration.isPressed ? Motion.press : Motion.snappy, value: configuration.isPressed)
    }
}

extension ButtonStyle where Self == TextActionButtonStyle {
    static var textAction: TextActionButtonStyle { TextActionButtonStyle() }
}

// MARK: - Evidence

/// A disclosure on the plain ground: a heading with a trailing "Show" /
/// "Hide" accent link, then hairline rows. Keeps the native disclosure
/// semantics for VoiceOver.
struct FieldDisclosureStyle: DisclosureGroupStyle {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func makeBody(configuration: Configuration) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                withAnimation(Motion.adaptive(Motion.smooth, reduceMotion: reduceMotion)) {
                    configuration.isExpanded.toggle()
                }
            } label: {
                HStack(alignment: .firstTextBaseline) {
                    configuration.label
                        .font(VFont.title3.weight(.bold))
                        .foregroundStyle(VColor.textPrimary)
                    Spacer(minLength: Space.sm)
                    Text(configuration.isExpanded ? "Hide" : "Show")
                        .font(VFont.secondaryEmphasized)
                        .foregroundStyle(VColor.accentText)
                        .accessibilityHidden(true)
                }
                .frame(minHeight: Size.minTouch)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityValue(configuration.isExpanded ? "Expanded" : "Collapsed")
            .accessibilityHint(configuration.isExpanded ? "Hides the evidence" : "Shows the evidence")
            if configuration.isExpanded {
                configuration.content
                    .padding(.top, Space.xxs)
                    .transition(.opacity)
            }
        }
    }
}

/// One evidence line: label leading in secondary, value trailing in bold
/// tabular figures, hairline below. Stacks at large text sizes.
struct EvidenceRow: View {
    var label: String
    var value: String
    var showsDivider = true

    var body: some View {
        VStack(spacing: 0) {
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .firstTextBaseline, spacing: Space.md) {
                    labelText
                    Spacer(minLength: Space.sm)
                    valueText.multilineTextAlignment(.trailing)
                }
                VStack(alignment: .leading, spacing: 2) {
                    labelText
                    valueText
                }
            }
            .padding(.vertical, Space.sm)
            .frame(minHeight: Size.minTouch)
            if showsDivider { Hairline() }
        }
        .accessibilityElement(children: .combine)
    }

    private var labelText: some View {
        Text(label)
            .font(VFont.secondary)
            .foregroundStyle(VColor.textSecondary)
            .fixedSize(horizontal: false, vertical: true)
    }

    private var valueText: some View {
        Text(value)
            .font(VFont.secondaryEmphasized.monospacedDigit())
            .foregroundStyle(VColor.textPrimary)
            .fixedSize(horizontal: false, vertical: true)
    }
}

// MARK: - Settings rows

/// Leading SF Symbol in secondary ink for inset grouped settings rows.
struct SettingsLabel: View {
    var title: String
    var symbol: String
    var tint: Color = VColor.textPrimary

    init(_ title: String, symbol: String, tint: Color = VColor.textPrimary) {
        self.title = title
        self.symbol = symbol
        self.tint = tint
    }

    var body: some View {
        Label {
            Text(title).foregroundStyle(tint)
        } icon: {
            Image(systemName: symbol)
                .foregroundStyle(tint == VColor.textPrimary ? VColor.textSecondary : tint)
        }
    }
}
