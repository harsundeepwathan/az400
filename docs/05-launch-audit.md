# 5. Launch audit and roadmap

Audit of `feature/vector-ios-app` against the brief "Train. Eat. Progress. One app figures out the rest."

## 1. What exists

| Area | State |
|---|---|
| Stack | SwiftUI (iOS 17), Observation, Swift Charts, StoreKit 2, HealthKit, ActivityKit, WidgetKit, WatchConnectivity. Domain logic in `VectorCore` (Foundation-only Swift package). XcodeGen project. |
| Persistence | Local-first: one versioned JSON document (`AppData`), written atomically, merged into iCloud Drive with tombstones (`SyncMerge`). |
| Navigation | Today · Train · Nutrition · Progress · Profile tabs; root-level sheets and full-screen covers (`Routing.swift`); deep links. |
| Training | Programs generated from goal/equipment/days, templates, active workout (prefilled sets, live PRs, warm-up toggle, add/remove/reorder/replace), floating rest timer with notification and Live Activity, workout summary, 612-exercise library with demonstration photos. |
| Progression | `ProgressionEngine`: double progression, deloads, evidence on every recommendation; accept/adjust targets. |
| Nutrition | Meals, ~50 offline foods, Open Food Facts search and barcode, quick add, saved meals, copy yesterday, portion editor. |
| AI | Meal photo → Claude via `backend/meal-scan` (structured outputs, fallbacks). Coach = deterministic `InsightEngine` with evidence. |
| Progress | Summary vs previous period, volume, frequency, e1RM, body-weight trend, PRs, weekly sets per muscle. |
| Monetization | Free/Pro policy, StoreKit 2 paywall with honest pricing, upgrade moment after value. |
| Platform | Widgets, Live Activity, Watch app, HealthKit, MetricKit. |
| Tests | 51 core tests (Linux), 5 backend tests, 4 UI tests (not run). |

## 2. What is good (keep)

- The domain layer: pure, tested engines with evidence-backed outputs. This is the right base for the closed loop.
- Local-first workout logging: state is saved after every set, so the gym experience works offline.
- Honest AI and paywall handling (estimates are labelled, prices come from StoreKit).
- Design tokens and the component library.

## 3. What is weak

- **The app has never been compiled.** It was written without Xcode. This is the single biggest release risk.
- **The meal-scan backend has no user identity.** A shared secret is embedded in the app (extractable), and the free 3-scans-a-week quota is client-side only, so AI cost per user can't be enforced or measured.
- **Fake functionality reachable in Release builds.** Without a backend URL, the scanner silently uses the demo recognizer and returns the same plate. "Load sample data" ships in Profile.
- **The loop isn't closed.** Body-weight trend versus intake produces an insight, but calorie targets never adapt. Today shows separate cards rather than one recommendation.
- **Workout logging gaps:** no RPE/RIR, drop sets have no UI, no supersets, no exercise notes UI, no workout history screen, no favourite, recent or custom exercises, and rest preferences don't persist per exercise.
- **Goals:** no Maintain or Recomposition goal, no dietary preferences.
- **AI scan corrections:** grams and the food are editable, but calories and macros are not.
- **Performance:** `AppModel.sessions` and `nutrition(on:)` filter and sort the full history on every access, and they're read many times per render.

## 4. What is missing

Authentication; server-side quotas, usage and cost tracking; server data model and migrations; subscription verification on the server; analytics; account deletion; privacy manifest; measurements and progress photos; steps/readiness; adaptive nutrition targets; Today's unified recommendation; app icon; real Terms/Privacy URLs.

## 5. What should be removed or gated

- `DemoMealRecognizer` in Release (DEBUG/UI tests only). Without a backend, the scanner says it's unavailable.
- "Load sample data" and `-sampleData` in Release.
- The shared-secret header (`VectorMealScanKey`), replaced by user tokens.
- Hard-coded legal URLs, moved to configuration.
- `Sparkline` (unused component).

## 6. Current architecture

```
iOS app ── local JSON (AppData) ── iCloud Drive (merge-on-write)
   │
   └── backend/meal-scan (Node) ── Claude          Open Food Facts ◄── iOS (direct, no key)
         shared secret, in-memory rate limit, no DB
```

## 7. Target architecture (lean, for 100 → 10,000 users)

```
iOS app (local-first; iCloud for the user's own data)
   │  HTTPS, Bearer access token (Sign in with Apple)
   ▼
backend/api (Node + TypeScript, one service)
   ├── auth: Apple identity token → access JWT (1 h) + rotating refresh token
   ├── /v1/meal-scan: auth, per-user quota by verified tier, image checks, usage + cost logging
   ├── /v1/subscription: verifies StoreKit 2 signed transactions (Apple root CA chain)
   ├── /v1/events: batched product analytics
   └── DELETE /v1/me: account + data deletion
   ▼
PostgreSQL (Supabase or any managed Postgres), SQL migrations with constraints
   ▼
Claude (vision, structured outputs)        Open Food Facts (client-side)
```

**Decision: training and nutrition records stay local-first with iCloud for P0.** They're the user's health data, iCloud keeps them private and free to host, and logging stays instant offline. The server stores only what it must to operate a business: identity, verified subscription state, AI usage and cost, scan results and corrections (to improve accuracy), and analytics. Server-side sync of workouts and meals (for web or Android, or account-based restore) is P1. The schema is designed for it.

## 8. Roadmap

### P0: functional MVP

1. **Release honesty:** gate demo and sample paths behind DEBUG, scanner "unavailable" state, configurable legal URLs, privacy manifest, local data deletion.
2. **Workout core:** RPE/RIR, set types (warm-up, drop, failure), supersets, exercise notes, LAST/TODAY header, workout history and session detail, favourite, recent and custom exercises.
3. **Rest timer:** preset chips (30/60/90/120/180/custom) remembered per exercise; starts only after working sets.
4. **Goals:** Build muscle, Lose fat, Gain strength, Maintain, Recomposition; dietary preferences; RPE-aware progression.
5. **Closed loop:** weekly adaptive calorie check-in (weight trend + logged intake → estimated expenditure → new target, with reasons); Today's daily brief combining workout, nutrition, weight and progression from real data only.
6. **Nutrition:** favourite foods; editable calories and macros in AI scan review; correction tracking.
7. **Backend:** Postgres migrations; Sign in with Apple auth; server-enforced scan quotas by verified tier; usage and cost logging; rate limiting; StoreKit transaction verification; analytics ingestion; account deletion.
8. **iOS ↔ backend:** Sign in with Apple, Keychain tokens, API client with refresh, scanner using user tokens, subscription verification after purchase, analytics client with opt-out, delete account.
9. **Performance:** cache sessions and per-day nutrition in `AppModel`.

### P1: launch

Build in Xcode and fix compile errors (requires a Mac); App Store Server Notifications → subscription table; App Attest; measurements and progress photos (on device); HealthKit steps and resting heart rate; protein-adherence and calorie charts; Claude-written coach summary from a structured digest (cached daily); cost dashboard SQL views; app icon and screenshots; real Terms and Privacy pages.

### P2: post-launch

Server sync of workouts and nutrition; Watch heart rate (`HKWorkoutSession`); readiness score; social and sharing; web/Android.

## P0 status

| # | Item | Status | Verified by |
|---|---|---|---|
| 1 | Release honesty | Done. Demo recognizer and sample data are DEBUG-only; scanner says "unavailable" without a backend; legal URLs configurable; privacy manifest | Code review (app not compiled) |
| 2 | Workout core | Done. RPE (half steps) and RIR, set types (warm-up, working, drop, to failure), supersets, exercise notes, LAST → TODAY strip, history and session detail, favourite, recent and custom exercises | Core: `WorkoutCoreTests`. UI: not compiled |
| 3 | Rest timer | Done. Presets 0:30/1:00/1:30/2:00/3:00 plus custom, remembered per exercise; no rest after warm-ups or between superset members | Core: `WorkoutCoreTests` |
| 4 | Goals | Done. Five goals drive protein, calorie direction and target rate; dietary preferences in onboarding and Profile (used by coach food suggestions); progression repeats a top-of-range set logged at RPE ≥ 9.5 once before adding load | Core: `ClosedLoopTests`, `WorkoutCoreTests` |
| 5 | Closed loop | Done. Weekly adaptive calorie check-in (expenditure from intake + weight trend, capped 250 kcal, guard rails) and Today's daily brief from real data, each line with evidence | Core: `ClosedLoopTests` |
| 6 | Nutrition | Done. Favourite foods; editable calories and macros in scan review; correction summary sent per scan | Core: `ScanCorrectionTests` |
| 7 | Backend | Done. `backend/api`: Sign in with Apple, rotating refresh tokens, server quotas with advisory lock, usage and cost logging, 24 h result cache, StoreKit JWS verification, analytics, account deletion, SQL migrations | 25 tests on PostgreSQL 16 |
| 8 | iOS ↔ backend | Done. Keychain session, `APIClient` (refresh, single-flight), scanner on user tokens, purchases stamped with `appAccountToken` and verified server-side, analytics queue with opt-out, delete account | Core: `APIClientTests`. UI: not compiled |
| 9 | Performance | Done. `sessions`, per-day nutrition, recent exercises, brief and check-in are cached and invalidated on data change | Code review |

**Not verified anywhere yet:**
- compiling the SwiftUI app, widgets and watch app
- running the UI tests
- a live Claude call
- real Sign in with Apple and App Store transactions

These need a Mac with Xcode, an Anthropic key and an Apple developer account. They are the first P1 task.
