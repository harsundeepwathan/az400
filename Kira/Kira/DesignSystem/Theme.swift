import SwiftUI
import UIKit
import KiraCore

/// Semantic colour tokens. Every view uses these — never raw hex — so dark mode is a
/// deliberate second palette rather than an automatic inversion.
enum KiraColor {
    static let background = dynamic(light: 0xF7F8F5, dark: 0x0F1411)
    static let surface = dynamic(light: 0xFFFFFF, dark: 0x1A201C)
    static let surfaceRaised = dynamic(light: 0xFFFFFF, dark: 0x222A25)
    static let textPrimary = dynamic(light: 0x16271F, dark: 0xEEF2EE)
    static let textSecondary = dynamic(light: 0x68766D, dark: 0xA3B0A7)
    static let accent = dynamic(light: 0x326B50, dark: 0x7CC49C)
    static let accentSoft = dynamic(light: 0xE4EFE7, dark: 0x1F3529)
    static let blueSoft = dynamic(light: 0xDCE8F2, dark: 0x1C2C3A)
    static let warning = dynamic(light: 0xD69A43, dark: 0xE3AE5E)
    static let warningSoft = dynamic(light: 0xF8ECD9, dark: 0x3A2E1A)
    static let error = dynamic(light: 0xC45B56, dark: 0xE07C76)
    static let errorSoft = dynamic(light: 0xF6E1E0, dark: 0x3A2120)
    static let separator = dynamic(light: 0xE6E9E3, dark: 0x2C342F)
    static let track = dynamic(light: 0xECEFEA, dark: 0x2A322D)

    /// Category tint tokens (icons only — charts use the single accent series).
    static func tint(_ token: String) -> Color {
        switch token {
        case "green": return dynamic(light: 0x326B50, dark: 0x7CC49C)
        case "amber": return dynamic(light: 0xB27A2A, dark: 0xE3AE5E)
        case "blue": return dynamic(light: 0x3B6E99, dark: 0x8DB7DD)
        case "rose": return dynamic(light: 0xA9566C, dark: 0xE09AAC)
        case "violet": return dynamic(light: 0x6B5BA8, dark: 0xB0A4E6)
        case "red": return dynamic(light: 0xC45B56, dark: 0xE07C76)
        default: return dynamic(light: 0x5D6B63, dark: 0xA3B0A7)
        }
    }

    static func softTint(_ token: String) -> Color {
        switch token {
        case "green": return accentSoft
        case "amber": return warningSoft
        case "blue": return blueSoft
        case "rose": return dynamic(light: 0xF5E4E8, dark: 0x3A2229)
        case "violet": return dynamic(light: 0xEAE6F6, dark: 0x2A2540)
        case "red": return errorSoft
        default: return dynamic(light: 0xEDF0EC, dark: 0x262E29)
        }
    }

    private static func dynamic(light: UInt32, dark: UInt32) -> Color {
        Color(uiColor: UIColor { traits in
            UIColor(hex: traits.userInterfaceStyle == .dark ? dark : light)
        })
    }
}

extension UIColor {
    convenience init(hex: UInt32) {
        self.init(red: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255, blue: CGFloat(hex & 0xFF) / 255, alpha: 1)
    }
}

enum KiraRadius {
    static let small: CGFloat = 12
    static let card: CGFloat = 20
    static let hero: CGFloat = 24
}

enum KiraSpacing {
    static let xs: CGFloat = 4
    static let s: CGFloat = 8
    static let m: CGFloat = 12
    static let l: CGFloat = 16
    static let xl: CGFloat = 24
    static let xxl: CGFloat = 32
}

/// Typography scale built on SF Pro (system font) so Dynamic Type works everywhere.
extension Font {
    /// Hero figures ("RM 2,845.60"). Rounded design, tabular digits applied at the call site.
    static let kiraHero = Font.system(.largeTitle, design: .rounded).weight(.semibold)
    static let kiraFigure = Font.system(.title2, design: .rounded).weight(.semibold)
    static let kiraSection = Font.system(.title3).weight(.semibold)
    static let kiraRowTitle = Font.body.weight(.medium)
    static let kiraCaption = Font.footnote
}

/// Haptics used sparingly: success on save, warning on errors, selection on toggles.
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
