# 2. Design system: Vector

Source of truth: `App/Vector/DesignSystem/Tokens.swift` and `DesignSystem/Components/`.

**Character:** athletic, precise, calm. Neutral surfaces carry the content, electric blue marks the one thing to do next, and numbers are the hero. Depth comes from soft shadows in light mode and hairline strokes in dark mode, never stacked gradients.

## 2.1 Color

Every token has a hand-picked dark value, so dark mode is designed rather than inverted.

| Token | Light | Dark | Role / contrast |
|---|---|---|---|
| `background` | `#F4F5F7` | `#0A0B0D` | Screen |
| `surface` | `#FFFFFF` | `#16181C` | Cards |
| `surfaceRaised` | `#FFFFFF` | `#1E2126` | Tooltips, popovers |
| `surfaceSunken` | `#EEF0F3` | `#23262C` | Fields, tracks, chips |
| `separator` | `#E3E6EA` | `#2A2E35` | Hairlines, dark-mode card edge |
| `textPrimary` | `#0B0D10` | `#F5F7FA` | ≥ 15:1 |
| `textSecondary` | `#5B6270` | `#9AA3B2` | 6.1:1 / 7.0:1 on surface |
| `textTertiary` | `#737A88` | `#7D8594` | 4.5:1 / 4.8:1, non-essential only |
| `accent` (fill) | `#1F62FF` | `#2F6FEB` | White text 4.9:1 / 4.6:1 |
| `accentText` | `#1F62FF` | `#4D8BFF` | 4.9:1 / 5.5:1 on surface |
| `accentSoft` | `#E8EFFF` | `#16264A` | Tinted fills |
| `success` | `#1A7F4B` | `#34C77B` | 5.0:1 / 8.1:1 |
| `warning` | `#B45F00` | `#F2A93B` | 4.6:1 / 8.9:1 |
| `danger` | `#C8261B` | `#FF6B5E` | 5.6:1 / 6.4:1 |

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
| `metricHero` | Large Title / Rounded Bold, tabular | Calories left, rest countdown, workout clock |
| `metric` | Title 2 / Rounded Bold, tabular | Metric cards |
| `metricSmall` | Headline / Rounded Semibold, tabular | Ring centers, inline stats |
| `data` / `dataSecondary` | Body Semibold / Subheadline, tabular | Set tables, rows |

Rounded numerals on metrics give the data a friendly, athletic voice, while text stays in SF Pro for sophistication.

## 2.3 Spacing, radius, size, elevation

- **Spacing (8 pt grid):** 4 · 8 · 12 · 16 · 24 · 32 · 48. Screen gutter is 16 and section rhythm is 28.
- **Radius:** 6 (tooltips) · 10 (fields, chips, set rows) · 14 (buttons, list cards) · 20 (cards) · 28 (camera frame). All continuous corners.
- **Sizes:** minimum touch target 44×44; primary button 52 high; compact button 40 high but still 44 hit area; set-row controls 44 high, with a 48-wide check button.
- **Elevation:** `flat`; `card` (5% black, 10 blur, y2); `floating` (14%, 24 blur, y8; rest timer, mini player, toasts). In dark mode shadows drop to clear and cards get a 0.5 pt `separator` stroke.

## 2.4 Motion & haptics

| Token | Curve | Use |
|---|---|---|
| `snappy` | snappy 0.28 s | Taps, toggles, selection |
| `smooth` | smooth 0.35 s | Layout changes, sheet content |
| `gentle` | ease 0.45 s | Rings / bars filling on appear |
| `celebrate` | spring 0.45 s, damping 0.62 | Set completion, PRs, summary |
| `chart` | easeOut 0.5 s | Range changes |

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
