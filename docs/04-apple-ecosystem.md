# 4. Apple ecosystem

| Surface | Status | Implementation |
|---|---|---|
| **Apple Health / HealthKit** | Implemented, opt-in from Profile | `HealthKitService`: writes finished strength workouts (`HKWorkoutBuilder`, `.traditionalStrengthTraining`) and weigh-ins, and reads body mass. The app is fully functional without it. |
| **Live Activities & Dynamic Island** | Implemented | `WorkoutActivityAttributes` (shared). The app updates it on every set and rest change. The lock screen shows workout, exercise, set, live rest countdown and progress. The island shows the rest countdown (compact) and exercise plus timer (expanded). Tapping opens `vector://workout`. |
| **Widgets** | Implemented | `TodayWidget` (small, medium, rectangular, circular): next workout, calories, protein, Scan Meal deep link. It reads a `WidgetSnapshot` the app writes to the App Group container. |
| **Notifications** | Implemented | Time-sensitive "Rest complete" local notification. In the foreground only a sound plays, since the in-app timer already shows the countdown. |
| **Apple Watch** | Implemented (`App/VectorWatch`) | Start the next workout, page through exercises, adjust weight and reps with the Digital Crown, complete sets with a haptic, and run the rest timer ring with −15 / +15 / Skip. Taps apply on the watch immediately and sync to the phone over WatchConnectivity; the phone stays the source of truth. |
| **iCloud sync** | Implemented | One JSON document in the app's iCloud container. Every write merges first (`SyncMerge`: records unioned by id, tombstones for deletions, newer settings win), so two devices editing offline both keep their work. The in-progress workout stays on the device you're training on. |
| **Crash & performance diagnostics** | Implemented | MetricKit (crashes, hangs, launch time, memory), no third-party SDK. Payloads are kept on device with an upload hook. |

## Apple Watch details

`VectorCore` already declares `.watchOS(.v10)` and has no UIKit dependency, so the watch app can reuse the domain directly:

- `ActiveWorkout` is a `Codable` value type with mutating intents (`complete`, `setWeight`, `setReps`, `addSet`). The watch sends the same intents over `WatchConnectivity`, and the phone remains the source of truth.
- `RestTimer` is end-date based, so phone, watch and Live Activity render the same countdown without syncing ticks.
- Watch screens map 1:1 onto the requirements: **Start workout** (next template) → **Exercise** (name, set x of y, target) → **Log** (Digital Crown for weight/reps) → **Complete set** (a large ✓ with haptic) → **Rest timer** (ring plus ±15 / Skip).
- Next step: an `HKWorkoutSession` on the watch would add heart rate and calories to the saved workout. This is the planned "enhanced Apple Watch experience" in Pro.

## App Group & entitlements

`group.app.vector` (app and widgets), HealthKit and the `iCloud.app.vector` container (app) are declared in `project.yml`. Set your team ID and register the App Group and iCloud container in the developer portal before running on device.
