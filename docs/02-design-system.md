> **Current direction: "Grouped" (Oct 2026).** The owner chose the category standard, played straight, measured against Apple Fitness/Health, Strong/Hevy, MacroFactor and Whoop/Oura (see `PRODUCT.md`). It replaces "Ink" below:
> - **Surfaces:** grey grouped ground (#F2F2F7, black in dark) with white cells (#1C1C1E in dark), 14 pt corners, no strokes or shadows.
> - **Tint:** one green for actions, selection, links and the tab bar (#008A55 fill / #007A4C text in light, #30D158 in dark, black text on it).
> - **Category colours:** each cell starts with a tinted category header (`CategoryHeader`): Coach and Training green, Nutrition orange, Body indigo. Macros stay blue / teal / amber, and the calorie ring is orange.
> - **Type:** large "Today" title, sentence-case section titles (no uppercase eyebrows), metrics in SF Pro Rounded bold.
> - **No sparkle icons:** recommendations use the `scope` (target) symbol, because they come from rules, not magic.
> - The full, code-derived system is in `DESIGN.md` (with `.impeccable/design.json`).
> Provenance: Impeccable direction round, seed key 3bffb586 (operate mode); the owner took the standing exit (category standard).
> The Ink notes below remain for history; where they conflict, this block wins.

# 2. Design system: Vector

Source of truth: `App/Vector/DesignSystem/Tokens.swift` and `DesignSystem/Components/`.

**Character: "Ink". Minimalist, clean, modern.** The interface is monochrome: ink on a white (or black) canvas, with flat neutral cards and generous space. **Colour only ever means data:** macros, success, PRs and warnings, errors. Primary buttons, links, tabs and selection are ink, so the one coloured thing on a screen is the information. No shadows on content, no gradients, no emojis, no decorative illustration.

Direction chosen with the vendored UI/UX Pro Max skill ("Minimalism & Swiss Style": spacious, high contrast, grid-based, essential). Its suggested energetic orange palette and condensed sports font were rejected as off-brief.

## 2.0 Current direction: Widgets (October 2026)

The app is moving to a widget dashboard, chosen by the owner from a reference. Today, Train, Nutrition, Progress, the active workout, the workout summary and Profile use it; other sheets still use the older tokens below until they're converted. The sections after this one describe the older system.

- **Canvas and tiles.** Light first: white tiles on `#F2F4F8`; near-black tiles (`#12151C`) on `#07090D` in dark mode. Tiles have 28 pt corners, a 1 pt edge at 6 to 7% ink, 16 pt inner padding and 12 pt between tiles. Tokens: `WColor` in `Tokens.swift`.
- **One colour: Vector blue** (`WidgetTint`). Today's insight is the one solid blue tile, with white text; every other tile is plain white (near-black in dark). `ink` is for text (4.5:1 on its tile), `accent` for marks, `fill` for the tile. No gradients; protein, carbs and fat are three strengths of the same blue. The selected tab is a soft blue pill.
- **Components** (`Widgets.swift`): `WidgetTile` (header with symbol, title, optional accessory and an arrow that opens the full screen), `GradientRing`, `WidgetMacroRing`, `WeekBars`, `WidgetSparkline`, `ComparisonBars`, `WidgetBar`, `PageDots`, `WidgetScreenHeader`, `FloatingTabBar`. Lists keep native swipe actions by drawing consecutive rows as one tile (`tileRow(.first/.middle/.last/.only)`); self-contained sections use `widgetSurface()`.
- **Actions.** One primary per tile: `widgetPrimary` (Vector blue fill, white label, 16 pt corners). Secondary: `widgetSecondary` (soft fill). No capsule buttons in new work.
- **Navigation.** A floating tab bar (Today, Train, Nutrition, Progress) with a + in the middle for quick logging (start or resume a workout, scan a meal, log food, quick add, weigh in). Profile opens from the avatar.
- **Today's insight** comes from `DailyHighlightEngine` in VectorCore: a positive, checkable comparison from the user's own logs, never invented, never a dip, rotating daily; milestones for the first two weeks; hidden when nothing qualifies.

## 2.1 Color

Every token has a hand-picked dark value, so dark mode is designed rather than inverted. Contrast ratios below were computed with the WCAG formula.

| Token | Light | Dark | Role / contrast |
|---|---|---|---|
| `background` | `#FFFFFF` | `#000000` | Screen canvas |
| `surface` | `#F5F5F7` | `#141416` | Cards (flat, no shadow) |
| `surfaceRaised` | `#FFFFFF` | `#1C1C1F` | Popovers, rest timer |
| `surfaceSunken` | `#EBEBEE` | `#232326` | Fields, tracks, chips |
| `separator` | `#E3E3E8` | `#2C2C2F` | Hairlines, current-exercise outline |
| `textPrimary` | `#0A0A0A` | `#F5F5F7` | 18.2:1 / 16.9:1 on surface |
| `textSecondary` | `#5F5F64` | `#A1A1A6` | 5.8:1 / 7.2:1 on surface |
| `textTertiary` | `#6E6E73` | `#8E8E93` | 4.7:1 / 5.6:1 on surface |
| `accent` (ink fill) | `#0A0A0A` | `#F5F5F7` | Primary buttons, selection. `textOnAccent` 19.8:1 / 19.3:1 |
| `accentText` (ink) | `#0A0A0A` | `#F5F5F7` | Links, selected tab, focus |
| `accentSoft` | `#EBEBEE` | `#232326` | Neutral tinted fills |
| `success` | `#1A7F4B` | `#34C77B` | 4.6:1 / 8.4:1 on surface |
| `warning` | `#A65A00` | `#F2A93B` | 4.7:1 / 9.2:1 |
| `danger` | `#C8261B` | `#FF6B5E` | 5.1:1 / 6.6:1 |

**Macros** form a categorical set: Protein `#1F62FF`/`#4D8BFF`, Carbs `#0E9F8E`/`#1FA896`, Fat `#E08A00`/`#C97D14`. I ran both modes through a CVD/lightness validator: worst adjacent CVD ΔE is 12.4 in light mode and 14.4 in dark. Macros are always direct-labeled, so identity is never carried by color alone. Status colors always ship with an icon or sign (↗ +8.4%, ✓, ⚠).

## 2.2 Typography

All styles derive from Dynamic Type text styles, so they scale up to AX sizes. Numeric styles use **tabular figures** (`.monospacedDigit()`) so values don't jitter as they change.

| Token | Base | Use |
|---|---|---|
| `largeTitle` | Large Title / Bold | Workout name on hero cards, onboarding questions |
| `title` | Title 2 / Bold | Greeting, card titles |
| `title3` | Title 3 / Semibold | Exercise names in the workout |
| `sectionHeading` | Footnote / Semibold, UPPERCASE, +0.6 tracking | Dashboard eyebrows ("TODAY'S TRAINING") |
| `headline` | Headline / Semibold | Card headers |
| `body` / `bodyEmphasized` | Body | Content, buttons |
| `secondary` | Subheadline | Supporting text |
| `caption` | Caption / Medium | Labels, metadata |
| `metricHero` | Large Title / Light, tabular | Workout clock, rest countdown |
| `metric` | Title 2 / Semibold, tabular | Metric cards, calories |
| `metricSmall` | Headline / Semibold, tabular | Ring centers, inline stats |
| `data` / `dataSecondary` | Body Semibold / Subheadline, tabular | Set tables, rows |

One family (SF Pro) throughout. Hierarchy comes from size and weight, not from typefaces or colour: big light numerals for clocks, semibold for data, tight bold titles.

## 2.3 Spacing, radius, size, elevation

- **Spacing (8 pt grid):** 4 · 8 · 12 · 16 · 24 · 32 · 48. Screen gutter is 16 and section rhythm is 36 (more air between sections).
- **Radius:** 6 (tooltips) · 10 (fields, chips, set rows) · 16 (buttons, list cards) · 22 (cards) · 28 (camera frame). All continuous corners.
- **Sizes:** minimum touch target 44×44; primary button 52 high; compact button 40 high but still 44 hit area; set-row controls 44 high, with a 48-wide check button.
- **Elevation:** content is flat; cards separate from the canvas by tone, not shadow. Only `floating` elements (rest timer, mini player, toasts) cast a soft shadow, because they sit above scrolling content.

### Never

- Gradients on buttons or backgrounds; coloured chrome (buttons, tabs, links are ink).
- Emojis anywhere in the UI or share images: SF Symbols only.
- Shadows on content cards; more than one accent colour on a screen that isn't data.
- Decorative illustrations, mascots or stock imagery.
- Text below 4.5:1 contrast.

## 2.4 Motion & haptics

| Token | Curve | Use |
|---|---|---|
| `snappy` | snappy 0.28 s | Taps, toggles, selection |
| `smooth` | smooth 0.35 s | Layout changes, sheet content |
| `gentle` | ease 0.45 s | Rings / bars filling on appear |
| `celebrate` | spring 0.45 s, damping 0.62 | Set completion, PRs, summary |
| `chart` | easeOut 0.5 s | Range changes |

Rules from the Emil Kowalski and Impeccable skills (`.claude/skills/`):
- Anything entering uses a strong ease-out (`Motion.easeOut`, cubic-bezier 0.23, 1, 0.32, 1). The built-in `easeIn` is never used on UI.
- Press feedback is faster than release: `Motion.press` (0.1 s) going down, `Motion.snappy` coming back.
- Bounce (`Motion.celebrate`) is for rare moments only (a PR, workout complete). Completing a set, which happens about 20 times a workout, is crisp.
- Nothing grows from nothing: entrances start at 0.7–0.97 scale, never 0.
- Slide-ins use `Motion.slide(edge:reduceMotion:)`, which becomes a fade under Reduce Motion.

`Motion.adaptive` collapses animations to a 0.15 s fade under **Reduce Motion**. The scanner sweep, shimmer and pulse are disabled entirely.

Haptics: selection ticks on pickers, ranges, steppers and tabs; medium impact on set complete; success notification on PRs, workout complete and a logged scan; warning on rest finished.

## 2.5 Iconography

SF Symbols only, centralized in `Icon` (today `sun.max`, train `dumbbell`, nutrition `fork.knife`, progress `chart.line.uptrend.xyaxis`, scan `camera.viewfinder`, …). They are rendered at text-relative weights, and badge icons sit in a 36 pt continuous square tinted with `accentSoft`.

## 2.6 Components

| Component | File | Notes |
|---|---|---|
| `card()` modifier, `SectionHeader`, `Chip`, `MuscleChips`, `IconBadge`, `ProBadge`, `Hairline` | `Surfaces.swift` | Card adapts elevation per scheme |
| `PrimaryButton`, `.primary` / `.secondary` / `.quiet` / `.pressable` styles, `QuickActionButton` | `Buttons.swift` | Pressed scale 0.98, disabled state |
| `MetricView`, `MetricCard`, `DeltaBadge`, `ProgressRing`, `MacroRing`, `MacroBar`, `NutritionSummary`, `LinearProgress`, `PRBadge` | `Metrics.swift` | Rings show overshoot past 100% |
| `RangePicker`, `ProgressChart`, `ChartTooltip`, `Sparkline` | `Charts.swift` | One axis, thin marks, scrub selection with haptic, VoiceOver summary |
| `InsightCard`, `EvidenceList`, `AIRecommendationCard`, `EmptyStateView`, `ErrorStateView`, `.skeleton()`, `LockedFeatureCard`, `Toast` | `Coaching.swift` | "Why?" reveals evidence |
| `SetRow`, `NumericField`, `ExerciseLogCard`, `RestTimerBar`, `WorkoutMiniPlayer` | `Features/Workout`, `App/RootView.swift` | Workout controls |
| `ChartCard` | `Features/Progress` | Chart container with an expand control |

## 2.7 Charts

- One measure per chart, one y-axis, trailing axis labels, dashed hairline grid.
- Bars have 4 pt rounded ends, are anchored to zero and occupy 62% of the bucket width. Lines are 2 pt with monotone interpolation. Points disappear when there are more than 24.
- Empty buckets render as zero so gaps are honest.
- Body weight shows raw weigh-ins as muted dots under a smoothed trend line (EWMA).
- Every chart has a tap-to-expand detail with the **underlying data as a table**.
- Target ranges (10–20 weekly sets) use a soft green band rather than a second color series.

## 2.8 Accessibility checklist (applies to every screen)

- Dynamic Type everywhere, with `minimumScaleFactor` only on single-line metrics.
- 44×44 minimum targets, including the check button, steppers and close buttons.
- Every icon-only button has an `accessibilityLabel`. Composite rows are combined into one element. Charts expose a spoken summary.
- Color is never the only signal (signs, arrows, icons, labels).
- Reduce Motion respected, and dark mode designed separately.
