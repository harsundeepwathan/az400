import SwiftUI
import UIKit

// MARK: - Color

/// Semantic color tokens ("Fields · Cobalt"). Blue, white and black: a white
/// ground (true black in dark) with one near-black hero field holding the
/// day's rings, then full-bleed tinted fields per area in pale cobalt and
/// cool grey. Black ink, one cobalt accent for every action. Status is always
/// paired with an icon or label. Contrast notes are in docs/02-design-system.md.
///
/// Legacy names (`background`, `surface`, `surfaceSunken`, `training`…) map
/// onto this palette so every screen picks it up.
enum VColor {
    // Ground
    /// The screen ground. Fields sit on it edge to edge.
    static let ground = Color(light: 0xFFFFFF, dark: 0x000000)
    static let background = ground
    /// Legacy cell fill: a faint cool-grey wash.
    static let surface = Color(light: 0xF4F5F8, dark: 0x111318)
    static let surfaceRaised = Color(light: 0xFFFFFF, dark: 0x181B22)
    /// Fills for inputs, wells and chips.
    static let surfaceSunken = Color(light: 0xECEEF3, dark: 0x1C1F27)
    /// Hairlines: ink at 10% (white at 10% in dark), so they read on any field.
    static let separator = Color(light: 0x0B0C0F, dark: 0xFFFFFF, lightAlpha: 0.10, darkAlpha: 0.10)
    /// Unfilled part of bars and tracks on the ground or a field.
    static let track = Color(light: 0x0B0C0F, dark: 0xFFFFFF, lightAlpha: 0.08, darkAlpha: 0.12)
    /// Quiet capsule buttons: ink at 6% (white at 10% in dark).
    static let quietFill = Color(light: 0x0B0C0F, dark: 0xFFFFFF, lightAlpha: 0.06, darkAlpha: 0.10)

    // Text
    static let textPrimary = Color(light: 0x0B0C0F, dark: 0xF4F5F7)
    static let textSecondary = Color(light: 0x5A5F69, dark: 0xA3A8B3)
    static let textTertiary = Color(light: 0x6B707B, dark: 0x8A8F9A)
    /// Ink on the accent: white in light mode, deep navy on the brighter dark-mode accent.
    static let textOnAccent = Color(light: 0xFFFFFF, dark: 0x050A1F)

    // Accent: cobalt, the one action colour (primary buttons, links, selection, tab selection).
    static let accent = Color(light: 0x2346E0, dark: 0x7C93FF)
    static let accentText = Color(light: 0x1F3FD0, dark: 0x8FA2FF)
    static let accentSoft = Color(light: 0xEEF2FF, dark: 0x111833)

    // Hero field: the near-black band at the top of Today with the rings.
    static let heroField = Color(light: 0x0B0C0F, dark: 0x0E1220)
    static let heroText = Color.white
    static let heroTextSecondary = Color(light: 0xA9AFBC, dark: 0x9AA2B8)
    /// Ring track on the hero field (white at 12%).
    static let heroTrack = Color.white.opacity(0.12)
    /// Legend hairlines on the hero field (white at 14%).
    static let heroHairline = Color.white.opacity(0.14)
    /// Quiet fill on the hero field (avatar).
    static let heroQuiet = Color.white.opacity(0.14)

    // Rings: cobalt, sky and white; they always sit on the dark hero field.
    static let ringWorkouts = Color(light: 0x4F6BFF, dark: 0x4F6BFF)
    static let ringCalories = Color(light: 0x8DBBFF, dark: 0x8DBBFF)
    static let ringProtein = Color(light: 0xF4F5F7, dark: 0xF4F5F7)

    // Area fields and their ink (category label, links, highlighted data).
    static let fieldTraining = Color(light: 0xEEF2FF, dark: 0x0D1328)
    static let inkTraining = Color(light: 0x1F3FD0, dark: 0x8FA2FF)
    static let fieldNutrition = Color(light: 0xF4F5F8, dark: 0x111318)
    static let inkNutrition = Color(light: 0x0B0C0F, dark: 0xF4F5F7)
    static let fieldBody = Color(light: 0xF7F8FB, dark: 0x0C0E13)
    static let inkBody = Color(light: 0x1F3FD0, dark: 0x8FA2FF)

    // Status: always paired with an icon or label, never color alone.
    static let success = accent
    static let successSoft = accentSoft
    static let warning = Color(light: 0xA65A00, dark: 0xFFB340)
    static let warningSoft = Color(light: 0xFDF0DE, dark: 0x33240C)
    static let danger = Color(light: 0xD70015, dark: 0xFF6961)
    static let dangerSoft = Color(light: 0xFDECEA, dark: 0x3A1714)

    // Categories (legacy names): the area's ink colour.
    static let coach = accent
    static let training = inkTraining
    static let nutrition = inkNutrition
    static let body = inkBody

    // Macros and calories: three blues and black, always direct-labeled.
    static let protein = Color(light: 0x2346E0, dark: 0x7C93FF)
    static let carbs = Color(light: 0x6FA3FF, dark: 0x9CC2FF)
    static let fat = Color(light: 0x0B0C0F, dark: 0xD6D9E0)
    static let calories = Color(light: 0x1A2A6C, dark: 0xB7C4FF)

    // Data visualization
    static let chartPrimary = accent
    static let chartMuted = Color(light: 0xD8DCE6, dark: 0x2A2F3B)
    static let chartGrid = separator
    static let chartTarget = accentSoft

    // Pro
    static let pro = accent
}

// MARK: - Widgets

/// The widget dashboard (Today): white tiles on a cool grey canvas in light
/// mode, near-black tiles in dark. Each area keeps one hue everywhere it
/// appears, glowing softly from one corner of its tile.
enum WColor {
    static let canvas = Color(light: 0xF2F4F8, dark: 0x07090D)
    static let tile = Color(light: 0xFFFFFF, dark: 0x12151C)
    /// Hairline around every tile.
    static let edge = Color(light: 0x121722, dark: 0xFFFFFF, lightAlpha: 0.06, darkAlpha: 0.07)
    /// Panels and chips inside a tile.
    static let inner = Color(light: 0x121722, dark: 0xFFFFFF, lightAlpha: 0.045, darkAlpha: 0.06)
    static let innerStrong = Color(light: 0x121722, dark: 0xFFFFFF, lightAlpha: 0.07, darkAlpha: 0.09)
    /// Unfilled ring and bar tracks.
    static let track = Color(light: 0x121722, dark: 0xFFFFFF, lightAlpha: 0.08, darkAlpha: 0.10)
    /// The earlier side of a comparison, rest-day dots.
    static let quiet = Color(light: 0x121722, dark: 0xFFFFFF, lightAlpha: 0.20, darkAlpha: 0.24)
    static let divider = Color(light: 0x121722, dark: 0xFFFFFF, lightAlpha: 0.08, darkAlpha: 0.08)

    static let textPrimary = Color(light: 0x121722, dark: 0xF3F5F9)
    static let textSecondary = Color(light: 0x5E6878, dark: 0xA3ACBB)

    /// Selected tab and the Start button: ink on light, white on dark.
    static let strong = Color(light: 0x121722, dark: 0xF3F5F9)
    static let onStrong = Color(light: 0xFFFFFF, dark: 0x0B0D12)
    /// The quick-add button in the tab bar.
    static let add = Color(light: 0x3D6BFF, dark: 0x3D6BFF)
    /// Rises (never colour alone: always with an arrow and a sign).
    static let rise = Color(light: 0x23864C, dark: 0x4CC27A)
    static let riseSoft = Color(light: 0x23864C, dark: 0x4CC27A, lightAlpha: 0.12, darkAlpha: 0.16)

    // Macro rings in the Calories tile, direct-labelled with P, C and F.
    static let protein = Color(light: 0x3D6BFF, dark: 0x6E8DFF)
    static let carbs = Color(light: 0xD98B1E, dark: 0xF2A541)
    static let fat = Color(light: 0xD9497A, dark: 0xFF7AA8)
}

/// An area's hue: `ink` for text and icons (4.5:1 on its tile), `accent`
/// for marks and fills, `glow` for the corner wash.
enum WidgetTint {
    case insight, training, calories, body

    var ink: Color {
        switch self {
        case .insight: Color(light: 0xA65F0C, dark: 0xF2A541)
        case .training: Color(light: 0x2F55E0, dark: 0x8AA2FF)
        case .calories: Color(light: 0x2F55E0, dark: 0x6E9BFF)
        case .body: Color(light: 0x147662, dark: 0x3CCFAE)
        }
    }

    var accent: Color {
        switch self {
        case .insight: Color(light: 0xE08A1E, dark: 0xF2A541)
        case .training: Color(light: 0x3D6BFF, dark: 0x6E8DFF)
        case .calories: Color(light: 0x3D6BFF, dark: 0x4F7BFF)
        case .body: Color(light: 0x1E9E86, dark: 0x3CCFAE)
        }
    }

    /// Second stop of the calorie ring's gradient; the accent elsewhere.
    var accentEnd: Color {
        self == .calories ? Color(light: 0x25B7FF, dark: 0x3CC8FF) : accent
    }

    var glow: Color {
        switch self {
        case .insight: Color(light: 0xFFE7C7, dark: 0xF2A541, lightAlpha: 1, darkAlpha: 0.30)
        case .training: Color(light: 0xE9EDF5, dark: 0xA0ACC4, lightAlpha: 1, darkAlpha: 0.16)
        case .calories: Color(light: 0xDCE6FF, dark: 0x3D6BFF, lightAlpha: 1, darkAlpha: 0.38)
        case .body: Color(light: 0xD3F2EA, dark: 0x1E9E86, lightAlpha: 1, darkAlpha: 0.40)
        }
    }

    /// The insight glows from the top right; everything else from the top left.
    var glowCorner: UnitPoint { self == .insight ? .topTrailing : .topLeading }
}

extension Color {
    init(light: UInt32, dark: UInt32, lightAlpha: CGFloat = 1, darkAlpha: CGFloat = 1) {
        self = Color(UIColor { traits in
            traits.userInterfaceStyle == .dark
                ? UIColor(hex: dark, alpha: darkAlpha)
                : UIColor(hex: light, alpha: lightAlpha)
        })
    }
}

extension UIColor {
    convenience init(hex: UInt32, alpha: CGFloat = 1) {
        self.init(
            red: CGFloat((hex >> 16) & 0xFF) / 255,
            green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255,
            alpha: alpha
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
    /// Horizontal content inset inside a full-bleed field (fields themselves have no side padding).
    static let fieldInset: CGFloat = 20
    /// Vertical padding at the top and bottom of a field.
    static let fieldVertical: CGFloat = 24
}

// MARK: - Radius

enum Radius {
    static let xs: CGFloat = 6
    static let sm: CGFloat = 10
    /// Buttons and controls; stays inside the 14 pt cell corner.
    static let md: CGFloat = 12
    /// Grouped cells.
    static let lg: CGFloat = 14
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
    /// Small sentence-case label (never uppercased or tracked: no eyebrows).
    static let sectionHeading = Font.system(.footnote, design: .default, weight: .semibold)
    static let headline = Font.system(.headline, design: .default, weight: .semibold)
    static let body = Font.system(.body)
    static let bodyEmphasized = Font.system(.body, design: .default, weight: .semibold)
    static let secondary = Font.system(.subheadline)
    static let secondaryEmphasized = Font.system(.subheadline, design: .default, weight: .semibold)
    static let caption = Font.system(.caption, design: .default, weight: .medium)
    static let captionEmphasized = Font.system(.caption, design: .default, weight: .semibold)

    /// Hero number (rest countdown, the weekly decision): rounded bold, large, tabular.
    static let metricHero = Font.system(.largeTitle, design: .rounded, weight: .bold).monospacedDigit()
    /// Card metric (volume, workouts).
    static let metric = Font.system(.title2, design: .rounded, weight: .bold).monospacedDigit()
    static let metricSmall = Font.system(.headline, design: .rounded, weight: .bold).monospacedDigit()
    /// Inline data in tables and rows.
    static let data = Font.system(.body, design: .default, weight: .semibold).monospacedDigit()
    static let dataSecondary = Font.system(.subheadline, design: .default, weight: .regular).monospacedDigit()

    // Fields
    /// The coach statement on the plain ground (28 pt bold).
    static let statement = Font.system(.title, design: .default, weight: .bold)
    /// A field's own title, e.g. the next workout's name (28 pt bold, scales with Dynamic Type).
    static let fieldTitle = Font.system(.title, design: .default, weight: .bold)
    /// Ring legend values on the hero field (22 pt rounded bold).
    static let ringValue = Font.system(.title2, design: .rounded, weight: .bold).monospacedDigit()
    /// The target after a ring legend value ("/ 2,300").
    static let ringTarget = Font.system(.subheadline, design: .rounded, weight: .semibold).monospacedDigit()
    /// Big field numbers: kcal left, body weight (34 pt rounded bold).
    static let fieldNumber = Font.system(.largeTitle, design: .rounded, weight: .bold).monospacedDigit()
    /// Paired stats inside a field ("7 days ago", "8,420 kg").
    static let fieldStat = Font.system(.title3, design: .rounded, weight: .bold).monospacedDigit()
    /// Macro values in the nutrition field.
    static let macroValue = Font.system(.headline, design: .rounded, weight: .bold).monospacedDigit()
    /// The calorie change in the check-in row ("2,300 → 2,550").
    static let changeValue = Font.system(.title, design: .rounded, weight: .bold).monospacedDigit()
    /// Small field labels (legend names, stat captions).
    static let fieldCaption = Font.system(.footnote)
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
    /// "What Vector recommends" marker. Deliberately not a sparkle: Vector's
    /// recommendations come from rules, not magic.
    static let recommendation = "scope"
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
