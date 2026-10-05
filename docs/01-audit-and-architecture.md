# 1. Audit, architecture & information architecture

## 1.1 Audit of the starting point

| Area | Finding |
|---|---|
| Repository | `harsundeepwathan/az400` contained only `FileA.txt` and `FileB.txt`. There was no app source, project file, assets or backend. |
| Framework | None present. Rebuilt as **SwiftUI (iOS 17+) + Swift Charts + Observation**, with a pure-Swift domain package. |
| Screens / navigation | None in code. The brief describes the previous product: a giant workout carousel on Train, large disconnected cards on Today, and "total kg lifted" as the headline progress metric. These are treated as the UX problems to solve (§1.3). |
| Reusable components | None existed. The component library in `App/Vector/DesignSystem` was created from scratch (§2). |
| Backend logic | None existed, so nothing could be broken. All workout, nutrition and analytics logic now lives in `VectorCore` and is covered by unit tests. |

## 1.2 Architecture

```
┌──────────────────────────── App/Vector (SwiftUI) ────────────────────────────┐
│ Features/            Today · Train · Workout · Exercise · Nutrition · Scanner │
│                      Progress · Coach · Summary · Onboarding · Profile · Paywall
│ DesignSystem/        Tokens (color, type, space, radius, elevation, motion)   │
│                      Components (cards, buttons, rings, charts, insight, …)   │
│ App/                 AppModel (@Observable, intents) · Routing · RootView     │
│ Platform/            Notifications · Live Activity · HealthKit · StoreKit 2   │
└──────────────┬───────────────────────────────────────────────────────────────┘
               │ depends on
┌──────────────▼──────────── Packages/VectorCore (Foundation only) ────────────┐
│ Models/      Exercise, templates, programs, sessions, sets, food, profile     │
│ Engines/     Progression · Analytics · Insight (AI coach) · Nutrition ·       │
│              Substitution · PlanGenerator · Format · OneRepMax                │
│ Session/     ActiveWorkout state machine · RestTimer                          │
│ Services/    Persistence (DataStore) · MealRecognizing · Entitlements          │
│ Data/        Exercise catalog · Food database · SampleData                     │
└───────────────────────────────────────────────────────────────────────────────┘
App/VectorWidgets   Today widget · Workout Live Activity / Dynamic Island
App/Shared          WidgetSnapshot · WorkoutActivityAttributes (app + extension)
```

Separation rules:

- **Presentation** (`Features`, `DesignSystem`): views only. Each feature screen file stays focused, and shared pieces become components.
- **Business logic** (`VectorCore/Engines`, `Session`): pure value types and deterministic functions, so they're testable on Linux CI with no UI.
- **Data** (`VectorCore/Services/Persistence`): `DataStore` protocol. `JSONFileStore` writes atomically and `InMemoryStore` backs previews and UI tests.
- **AI services** (`MealRecognizing`, `InsightEngine`): `MealRecognizing` is a protocol with remote and demo implementations. The model sits behind the app's backend so no API key ships in the binary. The coach is a deterministic rules engine. An LLM may rephrase its output but never originates a claim (§3.4).
- **Platform effects** (`Platform/`) are injected into `AppModel`, so previews run with none of them.

State flow: views call **intent methods** on `AppModel`. Each intent goes through `commit`, which mutates `AppData`, recomputes insights off the main actor, debounces an atomic save, and refreshes the widget snapshot. The in-progress workout is persisted after every set, so a crash or a killed app never loses training.

## 1.3 UX problems addressed

| Problem in previous product | Resolution |
|---|---|
| Today was a set of large, disconnected cards with little information each. | A compact command center with four stacked sections, each answering one of the four daily questions. The training card carries the session, its muscles, recency, previous volume, the main-lift target and the CTA. |
| Train used a horizontal carousel, so only one workout was visible and the program was hidden. | A vertical rotation. The next workout gets a hero card with an exercise preview, the rest are compact rows with context menus (Start, Make Next, Edit, Duplicate, Delete). |
| "Total kg lifted" was the headline progress metric with no context. | Volume always comes with a delta vs the previous equal window, sits beside frequency, PRs and duration, and is backed by estimated-1RM strength curves and weekly sets per muscle. |
| Paywalls interrupted flows. | No paywall, upsell row or locked control ever appears inside an active workout. Upgrade moments appear only after value has been shown (§3.2). |
| Empty screens were dead ends ("Nothing logged this week"). | Every empty state is an action: *Ready for your first session? → Start Workout*. |
| AI calorie estimates were presented as exact. | "AI estimate" disclaimer, `~` on totals, a low-confidence flag per item, and one-tap corrections. |

## 1.4 Information architecture

Five tabs on the native `TabView`. A minimized workout docks above the tab bar as a mini player.

| Tab | Question it answers | Contents |
|---|---|---|
| **Today** | All four, briefly | Greeting & date · Today's training (next / in progress / done) · Daily nutrition (calories, macros, Scan / Log / Quick Add) · Upgrade moment (conditional) · Daily insight · This week strip + weigh-in |
| **Train** | What am I training? | Current program · Next workout hero · Rotation list · My workouts · Create / Browse / Empty workout → Template detail → **Active Workout** → **Summary** |
| **Nutrition** | What should I eat / how am I doing? | Day pager · Calories remaining + macro rings · **Scan Meal** · Search / Barcode / Quick Add / Saved meals · Breakfast / Lunch / Dinner / Snacks · Nutrition insight |
| **Progress** | Am I progressing? | 7D–ALL range · Summary metrics · Volume / Frequency / Strength / Body weight charts (tap → detail with data table) · Personal records · Weekly sets per muscle · Coach |
| **Profile** | — | Subscription · Training, nutrition and body settings · Apple Health · Data export / reset |

Global (root-presented, reachable from any tab and from deep links): Exercise detail, Food search, Quick add, Barcode, Saved meals, Coach, Next-session recommendations, Body weight entry, Paywall; full-screen Workout, Meal scanner, Workout summary.

Deep links (`vector://workout`, `vector://scan`, `vector://nutrition`) serve widgets and the Live Activity.
