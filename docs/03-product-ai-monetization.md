# 3. Product rules: workouts, AI, monetization

## 3.1 Active workout (the most important screen)

Design goals, in order: **one-tap set completion, big targets, no interruptions, and state that survives anything.**

- Every set is pre-filled from the progression engine (Pro) or last session (free; the main lift still gets the smart target). Most sets therefore need exactly one tap on ✓.
- Completing a set gives a medium haptic and a bounce on the check. Focus moves to the next incomplete set, and the view scrolls when the exercise changes. The rest timer starts with the exercise's rest time, and a time-sensitive local notification is scheduled for when it ends.
- **PRs are detected live** against prior bests, with a success haptic, a toast and an inline `PR` badge on the set.
- Editing a set's weight carries the change forward to later, untouched sets at the old weight, which is how lifters actually adjust.
- The keyboard toolbar has −/+ buttons stepping by the exercise's plate increment (2.5 kg barbell, 2 kg dumbbell, 5 kg machine) and Next / Done.
- Tapping the set number toggles warm-up (warm-ups are excluded from volume and PRs). Long-press a set to delete it.
- The rest timer floats above the content, so it stays visible while scrolling to any exercise. It offers −15 / +15 / Skip and fires a haptic at zero in the foreground.
- **Minimize** keeps the workout running as a mini player above the tab bar, and the Live Activity / Dynamic Island shows the exercise, set and rest countdown.
- The whole `ActiveWorkout` is persisted after every change. **Finish** only confirms when sets are incomplete, and only completed sets are saved.

## 3.2 Progressive overload engine (`ProgressionEngine`)

Inputs per exercise: last performance, the prescribed rep range, estimated 1RM (Epley, capped at 12 reps), the volume trend over 3 sessions, and successful vs failed sets.

| Situation | Action | Example reason shown to the user |
|---|---|---|
| No history | Establish baseline | "Pick a load you could lift for about 10 reps." |
| All prescribed sets at the top of the range | **+1 load increment** (fixed reps stay, ranges reset to the bottom) | "You completed 80 kg × 8 across all 3 sets twice in a row." |
| All sets inside the range | +1 rep | "All sets landed in your 8–12 range at 60 kg. Add a rep before adding load." |
| A set below the range | Repeat load | "Last time you got 8, 7, 6 at 80 kg. Repeat the weight and aim for 7 on every set." |
| Below the range two sessions running | −1 increment | "80 kg fell short of 7 reps in two sessions in a row…" |
| e1RM fell 3 sessions running (≥ 5%) | Deload to ~90% | "Estimated 1RM has fallen three sessions in a row (101 → 98 → 95 kg)…" |

Every recommendation carries **evidence** (last session, e1RM, volume trend, successful sets). Users can **accept** it or **adjust** it, and the chosen target pre-fills the next workout and is cleared once used.

## 3.3 AI meal scanner

Flow: Scan Meal → camera (or library) → **Analyzing** (photo with a sweeping scan line and honest status steps: identifying, estimating portions, calculating) → **Review** → Add Meal.

Review is built for fast correction:
- "AI estimate. Review portions for better accuracy." is always visible, totals are shown as `~630 kcal`, and items under 60% confidence get a "Not sure. Please check" flag.
- Change a food: the model's own alternatives appear first, then full search.
- Change a portion: ±25 g buttons plus a slider (5 g steps) with live macro updates.
- Remove a food (✕) or add a missing one. Pick the meal, then **Add Meal**. Entries are tagged `aiScan` (✦ in the log).
- Errors (no food detected, offline, quota) always offer **Search Food Instead**.

Integration: `RemoteMealRecognizer` posts a downscaled JPEG to your backend (`VectorMealScanEndpoint` in Info.plist), which calls the vision model. The JSON contract is documented in `MealRecognition.swift`. With no endpoint configured, the app uses `DemoMealRecognizer`.

## 3.4 AI coach (`InsightEngine`)

Deterministic rules over workouts, volume, strength, missed sessions, nutrition adherence, protein and body-weight trend. Each `CoachInsight` has a title, a plain message, **evidence rows**, an optional suggestion and an action:

- Template volume trend: "Your back squat volume increased 18% over your last three Lower A sessions."
- Protein streak: "You've hit your protein target 5 days in a row."
- Protein shortfall: "You've averaged only 104g protein against your 150g target this week."
- Muscle imbalance: "Your chest volume has increased 24% over four weeks while back volume remained flat."
- Performance decline: "Your performance on Bench Press has declined across three sessions." → deload
- Progression opportunities: "We found 4 progression opportunities based on your training."
- Training gap and body-weight trend vs goal.

Principle: **never magical, never unexplained.** A language model may later rephrase tone, but every claim originates in a rule with its data attached.

## 3.5 Monetization

### Free vs Pro

| Free (forever) | Pro |
|---|---|
| Unlimited workout logging | Smart targets for **every** exercise (free: main lift only) |
| Program + templates (3 custom routines) | Unlimited routines & programs |
| Exercise history (last 90 days) | Unlimited history |
| Calorie & macro logging, search, barcode, quick add, saved meals | Unlimited AI meal scans (free: 3/week) |
| Basic progress (summary, volume, frequency, body weight, PRs; 7D–3M) | Strength curves, muscle balance, 6M / 1Y / ALL |
| Free coach insights (volume trend, streaks, training gap) | All coach insights, incl. nutrition, imbalance, deload, body-weight trend |
| Exercise alternatives (top 3) | Ranked alternatives with reasons, injury/preference aware |

### Upgrade moments (in-product, after value)

`EntitlementPolicy.shouldShowUpgradeMoment` requires a free user with **≥ 3 finished workouts**, **≥ 1 real progression opportunity**, **no active workout**, and **no moment in the last 7 days**. Today then shows:

> **You're getting stronger.** We found 4 progression opportunities based on your last 12 workouts. **[See recommendations]**

The recommendations screen shows the **first recommendation in full** (value first), then explains Pro. Other moments include a locked insight teaser (the headline is visible, proving it's about *their* data), the meal-scan quota, locked analytics previews, the routine limit and full history. **None of these can appear during a workout.**

### Paywall

"TRAIN SMARTER. GET STRONGER." The subheading adapts to why the paywall opened. It shows five benefits, then the Annual plan (emphasized, preselected) and Monthly.

Honesty rules, enforced in code (`PurchaseService`):
- Prices come only from StoreKit. "Save X%" is computed from the two real prices and hidden if not positive.
- A free trial is shown only when StoreKit reports intro-offer eligibility, with renewal terms spelled out under the CTA.
- No countdowns, fake strike-through prices or dark patterns. Close and Restore are always visible.
- Local testing uses `App/Vector/Resources/Vector.storekit` (Annual $59.99 with a 1-week trial, Monthly $9.99).
