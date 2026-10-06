import SwiftUI
import UIKit

// MARK: - Color

/// Semantic color tokens ("Ink"). The interface is monochrome: buttons,
/// links, tabs and selection are ink (black in light mode, near-white in
/// dark). Colour appears only when it carries data meaning: macros,
/// success, PRs/warnings and errors. Every value has a hand-tuned light and
/// dark variant; contrast ratios are in docs/02-design-system.md (WCAG AA).
enum VColor {
    // Surfaces: flat. Cards are a soft neutral on a white (or black) canvas, no shadows.
    static let background = Color(light: 0xFFFFFF, dark: 0x000000)
    static let surface = Color(light: 0xF5F5F7, dark: 0x141416)
    static let surfaceRaised = Color(light: 0xFFFFFF, dark: 0x1C1C1F)
    static let surfaceSunken = Color(light: 0xEBEBEE, dark: 0x232326)
    static let separator = Color(light: 0xE3E3E8, dark: 0x2C2C2F)

    // Text
    static let textPrimary = Color(light: 0x0A0A0A, dark: 0xF5F5F7)
    static let textSecondary = Color(light: 0x5F5F64, dark: 0xA1A1A6)
    static let textTertiary = Color(light: 0x6E6E73, dark: 0x8E8E93)
    /// Text on ink fills: white on black in light mode, black on near-white in dark.
    static let textOnAccent = Color(light: 0xFFFFFF, dark: 0x000000)

    // Ink: primary buttons, selected states, links, tab selection, focus.
    static let accent = Color(light: 0x0A0A0A, dark: 0xF5F5F7)
    static let accentText = Color(light: 0x0A0A0A, dark: 0xF5F5F7)
    static let accentSoft = Color(light: 0xEBEBEE, dark: 0x232326)

    // Status: always paired with an icon or label, never color alone.
    static let success = Color(light: 0x1A7F4B, dark: 0x34C77B)
    static let successSoft = Color(light: 0xE8F3EC, dark: 0x10261A)
    static let warning = Color(light: 0xA65A00, dark: 0xF2A93B)
    static let warningSoft = Color(light: 0xFBF1E3, dark: 0x2A1F0E)
    static let danger = Color(light: 0xC8261B, dark: 0xFF6B5E)
    static let dangerSoft = Color(light: 0xFDECEA, dark: 0x3A1714)

    // Macros: validated as a categorical set (CVD-separable, always direct-labeled).
    static let protein = Color(light: 0x1F62FF, dark: 0x4D8BFF)
    static let carbs = Color(light: 0x0E9F8E, dark: 0x1FA896)
    static let fat = Color(light: 0xE08A00, dark: 0xC97D14)
    static let calories = textPrimary

    // Data visualization
    static let chartPrimary = accentText
    static let chartMuted = Color(light: 0xD4D4D9, dark: 0x3A3A3E)
    static let chartGrid = separator
    static let chartTarget = Color(light: 0xDDEFE4, dark: 0x14301F)

    // Pro
    static let pro = textPrimary
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
    static let section: CGFloat = 36
}

// MARK: - Radius

enum Radius {
    static let xs: CGFloat = 6
    static let sm: CGFloat = 10
    static let md: CGFloat = 16
    static let lg: CGFloat = 22
    static let xl: CGFloat = 28
}

// MARK: - Size

enum Size {
    /// Minimum interactive target (Apple HIG).
    static let minTouch: CGFloat = 44
    static let buttonHeight: CGFloat = 52
    /// Never below `minTouch`.
    static let compactButtonHeight: CGFloat = 44
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

    /// Hero number (workout clock, rest countdown): light weight, large, tabular.
    static let metricHero = Font.system(.largeTitle, design: .default, weight: .light).monospacedDigit()
    /// Card metric (volume, workouts).
    static let metric = Font.system(.title2, design: .default, weight: .semibold).monospacedDigit()
    static let metricSmall = Font.system(.headline, design: .default, weight: .semibold).monospacedDigit()
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
        // Flat by design: cards separate by tone, not shadow.
        case .card: (.clear, 0, 0)
        case .floating: (Color.black.opacity(0.14), 24, 8)
        }
    }
}

// MARK: - Motion

/// Motion rules (Emil Kowalski / Apple): ease-out for anything entering,
/// press feedback faster than release, bounce only for rare moments (PRs,
/// workout complete), and never movement under Reduce Motion.
enum Motion {
    static let snappy = Animation.snappy(duration: 0.28)
    static let smooth = Animation.smooth(duration: 0.35)
    /// Strong ease-out: starts fast, so the moment the user is watching isn't delayed.
    static func easeOut(_ duration: Double) -> Animation { .timingCurve(0.23, 1, 0.32, 1, duration: duration) }
    /// Rings and bars filling in on appear.
    static let gentle = easeOut(0.45)
    /// Press-down feedback; the release uses `snappy`.
    static let press = easeOut(0.1)
    /// Rare moments only. Never on high-frequency actions like completing a set.
    static let celebrate = Animation.spring(response: 0.45, dampingFraction: 0.62)
    static let chart = easeOut(0.5)

    /// Slide in from an edge, or just fade when Reduce Motion is on.
    static func slide(_ edge: Edge, reduceMotion: Bool) -> AnyTransition {
        reduceMotion ? .opacity : .move(edge: edge).combined(with: .opacity)
    }

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
