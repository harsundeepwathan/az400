# Design: Apple Human Interface Guidelines conformance

Kira follows Apple's [Human Interface Guidelines](https://developer.apple.com/design/human-interface-guidelines/) and the current design language, **Liquid Glass** (iOS 26). The guidance below was read from Apple's HIG pages on 14 Oct 2026. Each row links a rule to where Kira implements it.

**Platform strategy:** build with the iOS 26 SDK (Xcode 26) and keep the deployment target at iOS 18. Standard components (tab bar, toolbars, sheets, menus, search) adopt Liquid Glass automatically on iOS 26. iOS 26-only APIs are behind `#available` in `DesignSystem/LiquidGlass.swift`, so iOS 18–25 get the classic appearance.

| HIG rule (paraphrased, source page) | Kira implementation |
|---|---|
| Use a tab bar for navigation, not actions (Tab bars) | The old **Capture** tab is removed. Adding is a standard **Add (+)** pull-down menu in the toolbar (`AddMenuModifier`) |
| Keep tabs few, use single-word labels and SF Symbols, prefer filled symbols (Tab bars) | Summary · Activity · Insights · Accounts, plus Search. The system fills the symbols in the tab bar |
| A search tab can sit at the trailing end; the standard style gives a landing page with suggestions (Tab bars, Search fields) | `Tab(role: .search)` → `SearchView` with frequent-merchant suggestions, search-as-you-type and a scope bar |
| The tab bar can minimise on scroll (Tab bars › iOS) | `.tabBarMinimizeBehavior(.onScrollDown)` on iOS 26 |
| Liquid Glass is the functional layer. Don't use it in the content layer; use it sparingly on custom controls (Materials) | No custom `glassEffect` on content. Cards use the grouped background colours. Glass appears only through system bars, menus and button styles |
| Don't put solid or semi-opaque backgrounds under controls; use scroll edge effects (Layout, Toolbars) | The custom reconciliation "Save" bar (`.background(.bar)`) was replaced by a toolbar confirm action. No custom bar backgrounds |
| Use standard Back and Close buttons, not text labels (Toolbars) | `CloseToolbarItem`: `Button(role: .close)` on iOS 26 (system ✕), "Cancel" before that |
| Use the prominent style for one key action such as Done or Save, on the trailing side (Toolbars, Sheets) | `ConfirmToolbarItem`: `Button(role: .confirm)` on iOS 26, always paired with Close |
| Use one prominent button for the most likely action in a view (Buttons) | `.kiraProminentButton()` → `.glassProminent` (iOS 26) / `.borderedProminent` |
| Use a large title to keep people oriented (Toolbars › iOS); keep titles short and don't use the app name (Toolbars › Titles) | Root screens use large titles. Summary shows the greeting and date as a subtitle (`navigationSubtitle`, iOS 26) |
| Use system colours and the grouped background set for grouped content; keep semantic meanings (Color) | `KiraColor` maps to `systemGroupedBackground`, `secondarySystemGroupedBackground`, `label`, `secondaryLabel`, `separator`, `tertiarySystemFill`, and system orange/red/green |
| Prefer system colours; custom colours need light, dark and increased-contrast variants (Color) | Kira has **no custom colours**. The app tint is the system accent (systemBlue), and every other colour is a dynamic system colour, so all variants come from iOS |
| Apply colour to Liquid Glass sparingly (Color › Liquid Glass color) | Toolbars and tab bars keep the default monochrome glass. The system tint marks only interactive elements and the single chart series. Money in uses systemGreen with a "+" sign |
| Don't rely on colour alone (Color › Inclusive color) | Status is always text and symbol (Pending, Not paid yet, Matched seal). The budget bar states its % in text |
| Use built-in text styles for Dynamic Type; keep truncation low at large sizes (Typography) | All text uses text styles (`.largeTitle`, `.title3`, `.body`, `.footnote`…). Money uses the rounded design with `monospacedDigit()`. A UI test runs at AccessibilityXXXL |
| Charts: summarise the main message, start bars at zero, use familiar ticks, support VoiceOver and Audio Graphs (Charts) | Trend chart has a one-line summary, `includesZero: true`, 3 automatic ticks, per-mark labels and an `AXChartDescriptor` |
| Sheets: Cancel/Close leading, Done trailing; support the medium detent; one sheet at a time (Sheets) | Capture flows open one sheet each with a standard Close. The camera scanner uses a full-screen cover, as the HIG suggests for camera views |
| Camera views suit a full-screen modal (Sheets) | `fullScreenCover` for DuitNow scanning |
| Use badges only for critical information (Tab bars) | No tab badges. The review count lives in content (Summary banner, Activity segment) |

## Still to do in Xcode
- **App icon:** create it in [Icon Composer](https://developer.apple.com/icon-composer/) (layered, Liquid Glass-ready) and replace the placeholder `AppIcon`.
- Check scroll-edge effects and title collapse on device; adjust `scrollEdgeEffectStyle` only if content looks crowded under the bars.
- Run with Reduce Transparency, Increase Contrast and Bold Text on.

## SwiftUI review (swiftui-expert-skill)

The project now vendors [AvdLee/SwiftUI-Agent-Skill](https://github.com/AvdLee/SwiftUI-Agent-Skill) and selected skills from [emilkowalski/skills](https://github.com/emilkowalski/skills) under `.claude/skills/` (MIT; pinned commits in `SOURCES.txt`). Applying its correctness checklist and references changed:

| Rule (skill reference) | Change |
|---|---|
| `@State` properties are `private`; seeds documented as one-time (state-management) | Editors and the reconciliation review take their model through `init` into private `@State` |
| `ForEach` uses stable identity, never indices or `\.offset` (list-patterns) | Reconciliation, onboarding steps and Summary rows iterate by ID |
| Constant number of views per `ForEach` element (list-patterns) | Optional rows resolved before the `ForEach`. Account sections only for types that exist |
| `sensoryFeedback` replaces UIKit feedback generators, iOS 17+ (latest-apis) | `FinanceStore` raises `FeedbackEvent`. `RootView` plays it. Views use `.sensoryFeedback(_:trigger:)` |
| Item-driven sheets; one enum instead of several booleans (sheet-navigation-patterns) | Summary uses a `SummarySheet` enum. The Add menu uses `sheet(item:)` and `fullScreenCover(item:)` |
| `@ScaledMetric` for non-text sizes (accessibility-patterns) | Category icons and empty-state badges scale with Dynamic Type |
| Previews use self-contained mock data (previews) | `Kira/Preview/PreviewData.swift`: in-memory store with synthetic data, plus light, dark and XXXL previews |
| Respect Reduce Motion (apple-design §14) | The budget bar's spring animation is disabled when Reduce Motion is on |

Flagged, not changed: `FileDocument` (used for exports) is soft-deprecated in SDK 27. Pushed capture screens still receive an `onFinished` closure, because `dismiss` inside a pushed view pops the stack rather than closing the sheet.
