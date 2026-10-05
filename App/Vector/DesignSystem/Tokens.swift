import SwiftUI
import UIKit

// MARK: - Color

/// Semantic color tokens. Every value has a hand-tuned light and dark
/// variant (dark mode is designed, not inverted). Contrast ratios are
/// documented in docs/02-design-system.md and meet WCAG AA for their role.
enum VColor {
    // Surfaces
    static let background = Color(light: 0xF4F5F7, dark: 0x0A0B0D)
    static let surface = Color(light: 0xFFFFFF, dark: 0x16181C)
    static let surfaceRaised = Color(light: 0xFFFFFF, dark: 0x1E2126)
    static let surfaceSunken = Color(light: 0xEEF0F3, dark: 0x23262C)
    static let separator = Color(light: 0xE3E6EA, dark: 0x2A2E35)

    // Text
    static let textPrimary = Color(light: 0x0B0D10, dark: 0xF5F7FA)
    static let textSecondary = Color(light: 0x5B6270, dark: 0x9AA3B2)
    static let textTertiary = Color(light: 0x737A88, dark: 0x7D8594)
    static let textOnAccent = Color.white

    // Brand
    /// Fill color for primary buttons and selected states (white text ≥ 4.5:1).
    static let accent = Color(light: 0x1F62FF, dark: 0x2F6FEB)
    /// Accent used for text and icons on surfaces (≥ 4.5:1 on surface).
    static let accentText = Color(light: 0x1F62FF, dark: 0x4D8BFF)
    static let accentSoft = Color(light: 0xE8EFFF, dark: 0x16264A)

    // Status: always paired with an icon or label, never color alone.
    static let success = Color(light: 0x1A7F4B, dark: 0x34C77B)
    static let successSoft = Color(light: 0xE6F4EC, dark: 0x12301F)
    static let warning = Color(light: 0xB45F00, dark: 0xF2A93B)
    static let warningSoft = Color(light: 0xFFF3E0, dark: 0x332410)
    static let danger = Color(light: 0xC8261B, dark: 0xFF6B5E)
    static let dangerSoft = Color(light: 0xFDECEA, dark: 0x3A1714)

    // Macros: validated as a categorical set (CVD-separable, always direct-labeled).
    static let protein = Color(light: 0x1F62FF, dark: 0x4D8BFF)
    static let carbs = Color(light: 0x0E9F8E, dark: 0x1FA896)
    static let fat = Color(light: 0xE08A00, dark: 0xC97D14)
    static let calories = textPrimary

    // Data visualization
    static let chartPrimary = accentText
    static let chartMuted = Color(light: 0xC9D2E3, dark: 0x343A46)
    static let chartGrid = separator
    static let chartTarget = Color(light: 0xD5F0E1, dark: 0x163323)

    // Pro
    static let pro = Color(light: 0x0B0D10, dark: 0xF5F7FA)
}

extension Color {
    init(light: UInt32, dark: UInt32) {
        self = Color(UIColor { traits in
            UIColor(hex: traits.userInterfaceStyle == .dark ? dark : light)
        })
    }
}

extension UIColor {
    convenience init(hex: UInt32) {
        self.init(
            red: CGFloat((hex >> 16) & 0xFF) / 255,
            green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255,
            alpha: 1
        )
    }
}

// MARK: - Spacing (8 pt grid, with 4 / 12 half-steps for tight layouts)

enum Space {
    static let xxs: CGFloat = 4
    static let xs: CGFloat = 8
    static let sm: CGFloat = 12
    static let md: CGFloat = 16
    static let lg: CGFloat = 24
    static let xl: CGFloat = 32
    static let xxl: CGFloat = 48

    /// Horizontal screen gutter.
    static let gutter: CGFloat = 16
    /// Vertical rhythm between dashboard sections.
    static let section: CGFloat = 28
}

// MARK: - Radius

enum Radius {
    static let xs: CGFloat = 6
    static let sm: CGFloat = 10
    static let md: CGFloat = 14
    static let lg: CGFloat = 20
    static let xl: CGFloat = 28
}

// MARK: - Size

enum Size {
    /// Minimum interactive target (Apple HIG).
    static let minTouch: CGFloat = 44
    static let buttonHeight: CGFloat = 52
    static let compactButtonHeight: CGFloat = 40
    static let setRowHeight: CGFloat = 52
    static let iconBadge: CGFloat = 36
}

// MARK: - Typography

/// Every style is built on a Dynamic Type text style so it scales with the
/// user's setting. Numeric styles use tabular figures so values don't jitter
/// as they change.
enum VFont {
    static let largeTitle = Font.system(.largeTitle, design: .default, weight: .bold)
    static let title = Font.system(.title2, design: .default, weight: .bold)
    static let title3 = Font.system(.title3, design: .default, weight: .semibold)
    /// Uppercase eyebrow used for dashboard section labels.
    static let sectionHeading = Font.system(.footnote, design: .default, weight: .semibold)
    static let headline = Font.system(.headline, design: .default, weight: .semibold)
    static let body = Font.system(.body)
    static let bodyEmphasized = Font.system(.body, design: .default, weight: .semibold)
    static let secondary = Font.system(.subheadline)
    static let secondaryEmphasized = Font.system(.subheadline, design: .default, weight: .semibold)
    static let caption = Font.system(.caption, design: .default, weight: .medium)
    static let captionEmphasized = Font.system(.caption, design: .default, weight: .semibold)

    /// Hero number (calories remaining, rest countdown).
    static let metricHero = Font.system(.largeTitle, design: .rounded, weight: .bold).monospacedDigit()
    /// Card metric (volume, workouts).
    static let metric = Font.system(.title2, design: .rounded, weight: .bold).monospacedDigit()
    static let metricSmall = Font.system(.headline, design: .rounded, weight: .semibold).monospacedDigit()
    /// Inline data in tables and rows.
    static let data = Font.system(.body, design: .default, weight: .semibold).monospacedDigit()
    static let dataSecondary = Font.system(.subheadline, design: .default, weight: .regular).monospacedDigit()
}

// MARK: - Elevation

enum Elevation {
    case flat, card, floating

    var shadow: (color: Color, radius: CGFloat, y: CGFloat) {
        switch self {
        case .flat: (.clear, 0, 0)
        case .card: (Color.black.opacity(0.05), 10, 2)
        case .floating: (Color.black.opacity(0.14), 24, 8)
        }
    }
}

// MARK: - Motion

enum Motion {
    static let snappy = Animation.snappy(duration: 0.28)
    static let smooth = Animation.smooth(duration: 0.35)
    static let gentle = Animation.easeInOut(duration: 0.45)
    static let celebrate = Animation.spring(response: 0.45, dampingFraction: 0.62)
    static let chart = Animation.easeOut(duration: 0.5)

    /// Respect Reduce Motion by collapsing to a quick cross-fade.
    static func adaptive(_ animation: Animation, reduceMotion: Bool) -> Animation {
        reduceMotion ? .easeInOut(duration: 0.15) : animation
    }
}

// MARK: - Iconography

/// SF Symbols used across the app, centralised so the icon language stays consistent.
enum Icon {
    static let today = "sun.max"
    static let train = "dumbbell"
    static let nutrition = "fork.knife"
    static let progress = "chart.line.uptrend.xyaxis"
    static let profile = "person.crop.circle"
    static let scan = "camera.viewfinder"
    static let search = "magnifyingglass"
    static let barcode = "barcode.viewfinder"
    static let quickAdd = "plus.forwardslash.minus"
    static let meal = "square.stack"
    static let sparkles = "sparkles"
    static let check = "checkmark"
    static let timer = "timer"
    static let swap = "arrow.triangle.swap"
    static let trophy = "trophy.fill"
    static let lock = "lock.fill"
    static let chevron = "chevron.right"
    static let flame = "flame.fill"
    static let more = "ellipsis"
    static let add = "plus"
    static let info = "info.circle"
}
