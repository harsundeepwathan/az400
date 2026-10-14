import SwiftUI
import UIKit
import KiraCore

/// Semantic colour tokens, mapped onto Apple's dynamic system colours.
///
/// Per the Human Interface Guidelines (Color): use system colours so the app adapts to light,
/// dark and Increase Contrast automatically, use the *grouped* background set for grouped
/// content, and keep semantic meanings intact (separator is never text, secondaryLabel is
/// never a background). The brand green lives only in the asset-catalog AccentColor, which
/// ships light, dark and high-contrast variants.
enum KiraColor {
    /// Primary background of every screen (grouped layout).
    static let background = Color(uiColor: .systemGroupedBackground)
    /// Content-layer grouping: cards and inset list rows.
    static let surface = Color(uiColor: .secondarySystemGroupedBackground)
    /// Grouping inside a card.
    static let surfaceRaised = Color(uiColor: .tertiarySystemGroupedBackground)
    static let textPrimary = Color(uiColor: .label)
    static let textSecondary = Color(uiColor: .secondaryLabel)
    static let textTertiary = Color(uiColor: .tertiaryLabel)
    static let separator = Color(uiColor: .separator)
    /// Unfilled portion of progress bars.
    static let track = Color(uiColor: .tertiarySystemFill)

    /// App accent (brand green from the asset catalog). Used for interactivity and the single
    /// chart series — never for non-interactive body text.
    static let accent = Color.accentColor
    static var accentSoft: Color { Color.accentColor.opacity(0.14) }

    // Status colours: system colours, always paired with text or a symbol.
    static let warning = Color(uiColor: .systemOrange)
    static var warningSoft: Color { Color(uiColor: .systemOrange).opacity(0.14) }
    static let error = Color(uiColor: .systemRed)
    static var errorSoft: Color { Color(uiColor: .systemRed).opacity(0.12) }
    static let positive = Color(uiColor: .systemGreen)

    /// Category tint tokens → system colours (adapt to dark mode and Increase Contrast).
    static func tint(_ token: String) -> Color {
        switch token {
        case "green": return Color(uiColor: .systemGreen)
        case "amber": return Color(uiColor: .systemOrange)
        case "blue": return Color(uiColor: .systemBlue)
        case "rose": return Color(uiColor: .systemPink)
        case "violet": return Color(uiColor: .systemPurple)
        case "red": return Color(uiColor: .systemRed)
        default: return Color(uiColor: .systemGray)
        }
    }

    static func softTint(_ token: String) -> Color { tint(token).opacity(0.15) }
}

/// Corner radii. Content-layer cards use continuous corners; controls in toolbars and tab bars
/// get their (concentric) shapes from the system, so no radius is defined for them here.
enum KiraRadius {
    static let small: CGFloat = 12
    static let card: CGFloat = 22
    static let hero: CGFloat = 26
}

enum KiraSpacing {
    static let xs: CGFloat = 4
    static let s: CGFloat = 8
    static let m: CGFloat = 12
    static let l: CGFloat = 16
    static let xl: CGFloat = 24
    static let xxl: CGFloat = 32
}

/// Typography uses the built-in text styles only (HIG Typography), so Dynamic Type, Bold Text
/// and the larger accessibility sizes work everywhere. Hierarchy comes from style, weight and
/// colour; money uses the rounded design with tabular digits applied at the call site.
extension Font {
    static let kiraHero = Font.system(.largeTitle, design: .rounded).weight(.bold)
    static let kiraFigure = Font.system(.title2, design: .rounded).weight(.semibold)
    static let kiraSection = Font.title3.weight(.semibold)
    static let kiraRowTitle = Font.body
    static let kiraCaption = Font.footnote
}

/// Haptics used sparingly: success on save, warning on errors, selection on choices.
@MainActor
enum Haptics {
    static func success() { UINotificationFeedbackGenerator().notificationOccurred(.success) }
    static func warning() { UINotificationFeedbackGenerator().notificationOccurred(.warning) }
    static func selection() { UISelectionFeedbackGenerator().selectionChanged() }
}

extension CategoryDefinition {
    var color: Color { KiraColor.tint(tint) }
    var softColor: Color { KiraColor.softTint(tint) }
}
