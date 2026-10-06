# 7. Digital-coach audit

Vector today, measured against: *Train. Eat. Progress. Vector figures out what to change next.* Coaching responsibilities: **Plan · Execute · Track · Analyze · Adjust · Explain**.

## 1. Coaching capabilities that already exist

| Responsibility | What exists | Where |
|---|---|---|
| Plan | Program generated from goal, experience, days and equipment; five goals set protein and calorie direction; Mifflin-St Jeor starting targets | `PlanGenerator`, `NutritionEngine.targets`, `Profile.swift` |
| Execute | Pre-filled sets with targets, LAST → TODAY strip, RPE, set types, supersets, per-exercise rest, no rest after warm-ups, Watch logging | `ActiveWorkout`, `ExerciseLogCard`, `VectorWatch` |
| Track | Sessions, sets, RPE, food (search, barcode, AI scan with corrections), weigh-ins, measurements, photos | `AppData` |
| Analyze | Double progression with evidence; e1RM, volume, PRs, weekly sets per muscle; smoothed weight trend; protein adherence; nutrition charts | `ProgressionEngine`, `AnalyticsEngine`, `NutritionChartEngine` |
| Adjust | Weekly calorie check-in (energy balance, capped ±250 kcal, Apply / Keep) | `AdaptiveNutritionEngine` |
| Explain | Evidence on every recommendation, insight and brief line; Claude weekly summary written from a structured digest | `Evidence`, `InsightEngine`, `DailyBriefEngine`, `backend/api/src/coach.ts` |

The architecture already follows the deterministic-engine-plus-AI-explainer split: the AI never decides progression or calories.

## 2. Missing coaching capabilities

1. **Adherence-gated decisions.** The calorie check-in changes targets after 10 logged days even when intake was far from target. A coach would say "follow the current target first".
2. **Goal *ranges*.** Goals have a single target rate, so "on track" means a point, not a band (+0.2–0.3 kg/week).
3. **Training adherence.** Planned vs completed sessions per week isn't computed anywhere.
4. **A weekly check-in that reviews everything.** The current check-in covers nutrition only. Training adherence, strength trend, weekly weight averages and the decision aren't in one review.
5. **Explicit "no change".** The check-in can say "no change needed", but Today and the coach don't present "everything is on track" as a deliberate decision.
6. **Confidence.** There is no shared notion of insufficient, low, moderate or high confidence, and no baseline checklist ("2 more weigh-ins").
7. **Decision memory and outcomes.** Applied check-ins are stored (`checkIns`), but there is no general decision log, no record of rejections, and no "did it work?" evaluation.
8. **Conservative progression under fatigue.** Reps falling at the same load at RPE ~10 isn't caught until the e1RM has dropped 5% over three sessions. Progression also allows a load increase after a top-of-range session at RPE 9.
9. **In-session feedback.** Completing a set shows nothing about the target ("target achieved", "next set 82.5 × 6–8").
10. **Contextual protein.** "32 g left; aim for ~30–35 g with your next meal" isn't offered.
11. **Accountability.** "1 session left this week" and "2 more weigh-ins for your check-in" aren't shown.

## 3. Existing data that supports the engine

Everything the deterministic engine needs is already stored locally:
- **Sessions:** `WorkoutSession.exercises[].sets[]` with weight, reps, RPE, kind and completion time, plus template ids. This gives volume, e1RM, PRs and per-week frequency.
- **Plan:** `TrainingProgram.daysPerWeek`, `UserProfile.daysPerWeek`, the goal and its target rate.
- **Food:** `FoodEntry` (date, meal, macros, source), so daily totals, logged days and adherence can be derived.
- **Body:** `BodyWeightEntry` (EWMA trend) and `BodyMeasurementEntry`.
- **History:** `NutritionTargets` plus `NutritionCheckIn` (previous and recommended calories, applied flag), which seeds the decision log.

## 4. Missing data relationships

- **Decision → outcome.** A recommendation needs its baseline metrics stored (rate before, adherence, confidence) so the outcome can be measured later.
- **Decision → target change.** Target changes aren't linked to the decision that caused them. `profile.targets` is overwritten without history; the decision log becomes that history.
- **Rejected recommendations.** These are lost, and the brief requires measuring trust (acceptance rate).
- **Progression accepted vs ignored.** `targetOverrides` records acceptance implicitly; neither path emits analytics.
- **Discomfort notes.** There is nowhere to record "shoulder discomfort on bench" without implying a diagnosis.

## 5. Safety gaps

| Gap | Risk | Fix (P0) |
|---|---|---|
| No pain or discomfort path | A user who reports pain gets nothing, or later an AI answer | "Report discomfort" records exercise, location and timing, then shows fixed, non-diagnostic guidance to stop or modify and see a qualified professional. Never sent to the AI. |
| Calorie floor only (1,200 kcal) | Aggressive deficits for small users | Keep the floor. Cap loss at 1% bodyweight per week. Never recommend below the floor; say "speak to a professional" instead. |
| Coach summary prompt | Covered: no medical advice, no diagnosis, no supplements or medication, refers to a professional | Keep; extend the rule to pain wording |
| Progression at RPE 10 with falling reps | Pushes load on fatigue | New hold/reduce rule (§7) |
| Avoided exercises described as "injury" | Implies medical handling | Label as "Avoid (preference or discomfort)" |

There is no form analysis, injury diagnosis or medical claim anywhere in the app or backend today.

## 6. Features to deprioritise

- **Insight cards** that restate data (volume trend, protein streak) instead of driving a decision. Fold them into the check-in and brief; don't add more.
- **Muscle-balance chart as a headline.** It stays in Progress → Strength; it isn't a weekly decision.
- **Watch enhancements beyond logging,** until P0 is validated (P2).
- **More AI surfaces** (chat, open-ended Q&A). The AI explains decisions; it doesn't make them.

## 7. Proposed deterministic coaching engine

All in `VectorCore`, pure and unit tested. The AI only receives the result.

```
Inputs (AppData) ──► Measurements  ──► Assessments ──► Decision ──► Explanation
                      (code)            (code)          (code)       (code text; AI optional)
```

- **`CoachMetrics`** (pure functions over a window):
  - Weekly weight averages and the trend rate in kg/week and %/week.
  - Calorie adherence: share of days in the window logged within ±10% of target.
  - Protein adherence: share of days at ≥90% of target.
  - Logging coverage: share of days with food logged.
  - Training adherence: completed ÷ planned sessions per week.
  - Volume change, and main-lift e1RM change.
- **`GoalBand`:** a target rate range per goal in %bodyweight per week.
  - Build muscle +0.15 to +0.40
  - Lose fat −0.30 to −0.75
  - Gain strength 0 to +0.25
  - Maintain and recomposition −0.15 to +0.15
- **`CoachConfidence`:** insufficient, low, moderate or high.
  - Based on days of data, weigh-ins and logging coverage.
  - Below "moderate", no target ever changes.
  - Insufficient data produces a baseline checklist ("2 more weigh-ins").
- **`WeeklyCheckInEngine`:** builds the full review (training, nutrition, body weight, goal) and makes one decision.
  1. **Insufficient data:** list exactly what's missing; no decision.
  2. **Adherence too low:** calorie adherence below 80%, so keep targets and focus on consistency.
  3. **On track:** the rate is within the goal band, so no changes; continue current targets.
  4. **Adjust calories:** toward the band midpoint, using expenditure estimated from intake and trend.
     - The change is ±100–250 kcal, rounded to 50.
     - The floor is 1,200 kcal, and loss is capped at 1% of bodyweight per week.
     - Requires at least moderate confidence.
- **`CoachDecision` log:** id, date, kind, before and after values, reason, evidence, confidence, status (proposed, applied, kept or rejected) and a baseline metrics snapshot.
- **`OutcomeEvaluator`:** at least 14 days after an applied calorie change, compare the trend rate after vs before and classify it as effective, partially effective, not effective or too early.
- **Progression v2:**
  - Increase only when the top of the range is hit on all sets and the last RPE is ≤ 8.5 (or unrecorded).
  - At RPE 9–9.5, repeat the load once.
  - Reps falling across 3 sessions at the same load with RPE ≥ 9.5 → hold or reduce.
  - The existing 5% e1RM deload stays.
- **`SetFeedback`:** after each set, "target achieved", "above target" or "below target", plus the next set's target and the rest time.

## 8. Required UI changes (P0)

- **Today:** greeting, today's workout and start button, nutrition (kcal and protein with a next-meal suggestion), and a Vector Coach card. The card shows one decision or "Everything is on track", plus accountability lines.
- **Weekly Coach Check-In** (replaces the nutrition-only card): sections for training, nutrition, body weight and goal, then the decision and Apply / Keep. Free users see the week in numbers; the decision and Apply are Pro.
- **Workout:** a one-line set feedback after each set, and "Report discomfort" in the exercise menu.
- **Progress:** sections reordered as Body, Strength, Consistency and Coaching. Coaching shows the decision history and outcomes.
- **Paywall:** "Unlock your digital coach" (adaptive calories, progression, weekly check-in, decision history).

## 9. Roadmap

**P0: digital coach MVP.** Today coaching; progression v2; nutrition, protein and training adherence; weight trends and goal bands; confidence; Weekly Coach Check-In with Apply / Keep; adaptive calories gated on adherence; a decision log with explanations; the discomfort safety path; Pro gating; coaching analytics events.

**P1.** Outcome tracking surfaced in Progress → Coaching and in the AI weekly summary; accountability nudges via notifications (opt-in, at most one a week); advanced training recommendations (volume landmarks per muscle, deload weeks); long-term trends; personalised expenditure (learned from the decision log rather than formulas).

**P2 (only after P0 is validated with real users).** Adaptive programming, recovery analysis, optional form analysis (observations only, never safety claims), deeper personalisation, Watch coaching.
