import SwiftUI
import UIKit

// MARK: - Color

/// Semantic color tokens ("Fields"). A plain ground (white, #0C0F0E in dark)
/// with one deep evergreen hero field holding the day's rings, then one
/// full-bleed tinted field per area: training green, nutrition peach, body
/// lavender. Each field has its own ink colour for the category label. One
/// green accent marks the action. Status is always paired with an icon or
/// label. Contrast notes are in docs/02-design-system.md.
///
/// Legacy names (`background`, `surface`, `surfaceSunken`, `training`…) map
/// onto the Fields palette so screens not yet redesigned keep compiling.
enum VColor {
    // Ground
    /// The screen ground. Fields sit on it edge to edge.
    static let ground = Color(light: 0xFFFFFF, dark: 0x0C0F0E)
    static let background = ground
    /// Legacy cell fill for screens not yet moved to fields: a faint ink wash
    /// so existing cards still read on the white ground.
    static let surface = Color(light: 0xF4F6F5, dark: 0x161B19)
    static let surfaceRaised = Color(light: 0xFFFFFF, dark: 0x1D2321)
    /// Fills for inputs, wells and chips.
    static let surfaceSunken = Color(light: 0xEBEEEC, dark: 0x1F2523)
    /// Hairlines: ink at 10% (white at 8% in dark), so they read on any field.
    static let separator = Color(light: 0x0F1412, dark: 0xFFFFFF, lightAlpha: 0.10, darkAlpha: 0.08)
    /// Unfilled part of bars and tracks on the ground or a field.
    static let track = Color(light: 0x0F1412, dark: 0xFFFFFF, lightAlpha: 0.08, darkAlpha: 0.10)
    /// Quiet capsule buttons: ink at 6% (white at 8% in dark).
    static let quietFill = Color(light: 0x0F1412, dark: 0xFFFFFF, lightAlpha: 0.06, darkAlpha: 0.08)

    // Text
    static let textPrimary = Color(light: 0x0F1412, dark: 0xEEF2F0)
    static let textSecondary = Color(light: 0x56605B, dark: 0x9DA8A3)
    static let textTertiary = Color(light: 0x6C7671, dark: 0x85908B)
    /// Ink on the accent: white in light mode, deep green on the brighter dark-mode accent.
    static let textOnAccent = Color(light: 0xFFFFFF, dark: 0x04150D)

    // Accent: the one action colour (primary buttons, links, selection, tab selection).
    static let accent = Color(light: 0x0F7A52, dark: 0x3FCB8A)
    static let accentText = accent
    static let accentSoft = Color(light: 0xE9F4EE, dark: 0x10201A)

    // Hero field: the evergreen band at the top of Today with the rings.
    static let heroField = Color(light: 0x0F3D30, dark: 0x0B2C23)
    static let heroText = Color.white
    static let heroTextSecondary = Color(light: 0xA8C9BC, dark: 0x93B8AA)
    /// Ring track on the hero field (white at 12%).
    static let heroTrack = Color.white.opacity(0.12)
    /// Legend hairlines on the hero field (white at 14%).
    static let heroHairline = Color.white.opacity(0.14)
    /// Quiet fill on the hero field (avatar).
    static let heroQuiet = Color.white.opacity(0.14)

    // Rings: same in both appearances (they always sit on the hero field).
    static let ringWorkouts = Color(light: 0x9EE07A, dark: 0x9EE07A)
    static let ringCalories = Color(light: 0xFF8A5C, dark: 0xFF8A5C)
    static let ringProtein = Color(light: 0x7CC3FF, dark: 0x7CC3FF)

    // Area fields and their ink (category label, links, highlighted data).
    static let fieldTraining = Color(light: 0xE9F4EE, dark: 0x10201A)
    static let inkTraining = Color(light: 0x0F6B48, dark: 0x5FD6A0)
    static let fieldNutrition = Color(light: 0xFFF1E8, dark: 0x22160F)
    static let inkNutrition = Color(light: 0xB4460F, dark: 0xFF9B66)
    static let fieldBody = Color(light: 0xF0EFFC, dark: 0x17162A)
    static let inkBody = Color(light: 0x4F45C2, dark: 0xABA3FF)

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

    // Macros: a categorical set, always direct-labeled.
    static let protein = Color(light: 0x2C6EE8, dark: 0x6AA9FF)
    static let carbs = Color(light: 0x0E9A8E, dark: 0x3FCFC1)
    static let fat = Color(light: 0xC98A06, dark: 0xF2BF4F)
    static let calories = Color(light: 0xE8611E, dark: 0xFF8A4F)

    // Data visualization
    static let chartPrimary = accent
    static let chartMuted = Color(light: 0xD5DAD7, dark: 0x2C3431)
    static let chartGrid = separator
    static let chartTarget = accentSoft

    // Pro
    static let pro = accent
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
