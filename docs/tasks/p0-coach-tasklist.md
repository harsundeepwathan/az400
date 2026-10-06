# P0 digital-coach task list

Source: §9 of `docs/07-coaching-audit.md`. "Core" means pure Swift in `VectorCore`, built and unit tested on Linux. "UI" means SwiftUI in `App/Vector`, written but **not compiled or run** (no Xcode in this environment).

| # | Task | Core | UI |
|---|---|---|---|
| 1 | Coaching metrics: calorie/protein adherence (unlogged days count against, today excluded), logging coverage, EWMA weight trend, weekly averages, training adherence, volume change | ✅ `CoachMetrics` | n/a |
| 2 | Goal ranges per goal, in %bodyweight/week | ✅ `TrainingGoal.band` | Shown in the check-in "Goal" row |
| 3 | Confidence: insufficient / low / moderate / high; no target change below moderate | ✅ `WeeklyCheckInEngine.confidence` | Shown on the check-in card |
| 4 | Weekly Coach Check-In: training, nutrition, body weight, goal, one decision | ✅ `WeeklyCheckInEngine.review` | ✅ `WeeklyCheckInCard` (replaces the nutrition-only card) |
| 5 | Adherence gate: below 80% calorie adherence, never change calories | ✅ | — |
| 6 | Adaptive calories: ±100–250 kcal toward the band midpoint, rounded to 50, 1,200 floor, loss capped at 1%/week; "watch" for one more week when the trend is short | ✅ | Apply Adjustment / Keep Current (Pro) |
| 7 | Explicit "Everything is on track" | ✅ `.onTrack`, `TodayCoachEngine` | ✅ `VectorCoachCard` |
| 8 | Recommendation explanations with evidence | ✅ reason + `Evidence` on every decision | ✅ "Evidence" disclosure |
| 9 | Decision memory (applied / rejected) with baseline snapshot | ✅ `CoachDecision`, `AppData.coachDecisions`, SyncMerge union + tombstones | ✅ Progress → Coaching |
| 10 | Outcome evaluation ≥ 14 days after a calorie change | ✅ `OutcomeEvaluator` | ✅ Shown in history and on the next check-in |
| 11 | Progression v2: top-set RPE > 8.5 repeats once; falling reps at RPE ≥ 9.5 over 3 sessions reduce load | ✅ `ProgressionEngine` | Uses existing surfaces |
| 12 | Set feedback after each set | ✅ `SetFeedback` | ✅ line under the completed set |
| 13 | Protein next-meal suggestion | ✅ `ProteinNudge` | ✅ Today nutrition card |
| 14 | Accountability without guilt ("1 of 4 workouts left", "5 more weigh-ins") | ✅ `TodayCoachEngine` | ✅ `VectorCoachCard` |
| 15 | Safety: "Report discomfort" with the fixed pain script; notes never reach the backend, analytics or AI; "Avoid (preference or discomfort)" | ✅ `SafetyGuidance`, `DiscomfortNote` | ✅ exercise menu, `DiscomfortReportSheet`, notes list |
| 16 | Pro gating: free sees the week in numbers; decision, Apply and history are Pro. Paywall "Unlock your digital coach" | n/a | ✅ |
| 17 | Analytics: the 11 coaching events on iOS and backend, with a parity test | ✅ | Events fired from the check-in, Apply/Keep and progression accept/adjust |

## Not done in P0 (deliberately)
- Progress isn't fully reorganised into Body / Strength / Consistency / Coaching. The Coaching section is added at the end; the reorder needs on-device review.
- The AI weekly summary doesn't yet receive the decision or its outcome (P1: "Outcome tracking surfaced… in the AI weekly summary").
- `recommendation_generated` is fired when the check-in card first appears, not when the engine computes, so it slightly overlaps `recommendation_viewed`.

## Found while wiring
The previous `AppModel+Loop.swift` called `AppModel.commit`, which is `private` to `AppModel.swift`. That would not have compiled. The new code uses the internal `mutate` wrapper, and the old check-in code was removed.

## Validation still needed
- Compile and run on a Mac; check the Today, workout, check-in, paywall and Progress screens in light, dark and Dynamic Type.
- Validate P0 with real users before any P2 work (per the brief).
