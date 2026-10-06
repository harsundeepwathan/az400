# P1 task list

Source: the P1 line of `docs/05-launch-audit.md`, quoted per task. Each task names its owner (see `docs/06-team.md`), the files it may touch, and the evidence required to pass. Anything that can't be verified in a Linux cloud session is marked **blocked** or **unverified** instead of being claimed done.

## Shared contract: coach summary (T3 ↔ T4)

`POST /v1/coach/summary` (Bearer auth, **Pro only**, verified server-side tier).

Request:
```json
{ "digest": {
  "date": "2026-10-06", "goal": "build_muscle", "unit": "kg",
  "training": { "workouts_last_7d": 4, "workouts_prev_7d": 3, "planned_per_week": 4,
                "volume_change_pct": 6.5,
                "prs_last_14d": [{ "exercise": "Back Squat", "weight": 82.5, "reps": 8 }],
                "main_lift": { "exercise": "Back Squat", "e1rm_now": 101.3, "e1rm_30d_ago": 96.3 } },
  "nutrition": { "days_logged_last_7d": 6, "avg_calories": 2240, "target_calories": 2300,
                 "avg_protein": 128, "target_protein": 150, "protein_days_hit": 2 },
  "body": { "trend_weight_now": 77.4, "trend_weight_14d_ago": 77.9, "weigh_ins_last_14d": 11 },
  "recommendations": ["Increase Back Squat to 85 kg × 8"]
} }
```
- `goal` ∈ `build_muscle | lose_fat | gain_strength | maintain | recomposition`; `unit` ∈ `kg | lb`.
- Nullable: `volume_change_pct`, `main_lift`, `main_lift.e1rm_30d_ago`, `avg_calories`, `avg_protein`, `trend_weight_now`, `trend_weight_14d_ago`.
- At most 5 PRs and 5 recommendations; strings ≤ 120 chars; numbers finite and ≥ 0 (except `volume_change_pct`).

Response `200`: `{ "summary": "…", "cached": false, "generated_at": "2026-10-06T07:12:00.000Z" }`. The summary is ≤ 600 characters, 2–4 sentences, and uses only numbers present in the digest.

Errors: `402 {"error":"pro_required"}`, `400 invalid_request`, `429 rate_limited`, `503 busy`.

---

### [ ] T1: App Store Server Notifications → subscription table
> "App Store Server Notifications → subscription table"

Owner: backend-architect. Files: `backend/api/**`.
- `POST /v1/apple/notifications` (no user auth) accepts `{signedPayload}` (App Store Server Notifications V2).
- Verify the payload JWS with the same certificate-chain verification as purchases. Then decode and verify `data.signedTransactionInfo` (and `signedRenewalInfo` if present).
- Check `bundleId` and environment; upsert `subscriptions` by `original_transaction_id` (expiry, revocation, product).
- Handle `DID_RENEW`, `EXPIRED`, `REFUND`, `REVOKE`, `DID_CHANGE_RENEWAL_STATUS`, `SUBSCRIBED`, `DID_FAIL_TO_RENEW`, `GRACE_PERIOD_EXPIRED`.
- Idempotent by `notificationUUID` (new table via migration `002_*.sql`).
- Unknown transactions (never linked to a user) are stored for later linking or acknowledged without error. Never 5xx on a valid payload Apple will retry forever.

**Evidence:** `npm test` passes with new tests: renewal extends expiry, refund revokes, duplicate notification ignored, forged chain rejected, wrong bundle rejected.

### [ ] T2: Cost dashboard SQL views
> "cost dashboard SQL views"

Owner: backend-architect. Files: `backend/api/migrations/**`, tests.
- Views: `ai_cost_by_month` (by tier), `ai_cost_per_active_user_30d`, `ai_top_users_30d` (by cost, user id only), `ai_scan_quality_30d` (failure and refusal rate, cache-hit rate, share of scans corrected, mean absolute calorie error from `meal_scans.correction`).
- Document the queries in the backend README.

**Evidence:** tests insert known rows and assert each view's numbers.

### [ ] T3: Claude-written coach summary, backend (cached daily)
> "Claude-written coach summary from a structured digest (cached daily)"

Owner: ai-engineer with backend-architect. Files: `backend/api/**`.
- Implements the shared contract above.
- Zod-validated digest. Pro-only by verified entitlement. One generation per user per UTC day (`coach_summaries` table, unique `(user_id, day)`), returned with `cached: true` afterwards.
- The usage and cost row goes into `ai_requests` with `kind = 'coach_summary'` (extend the check constraint in a migration).
- Prompt: cached system prompt.
  - The model may only use numbers from the digest, must explain why, and must not give medical advice.
  - Structured output `{summary}`; post-validate length.
  - Reject output that contains a number not present in the digest (simple numeric check), then retry once or fail with `503`.
- Same model/beta/fallback setup as the meal scan.

**Evidence:** `npm test` with a fake Claude client covers: Pro gating (402), validation (400), cache hit on second call the same day (no second model call), cost row written, invented-number output rejected.

### [x] T4: Coach summary, iOS side (digest + card) (core verified; UI unverified)
Owner: mobile-app-builder. Files: `Packages/VectorCore/**` (new `CoachDigest` builder and tests, `APIClient.coachSummary`), `App/Vector/Features/Coach/**`, minimal `App/Vector/App/*` wiring.
- `CoachDigestBuilder` builds the contract's digest from `CoachContext` using existing engines, with JSON keys exactly as above.
- `APIClient.coachSummary(digest:)`.
- `CoachView` shows a "This week" summary card for Pro + signed-in users: loading state, cached text, an "AI summary of your logged data" label, and a link to the data. Free users see nothing new (no fake locked text).

**Evidence:** `swift test` covers digest JSON shape (golden test against the contract example's keys), nil handling, and the API client mapping (402 → Pro required). UI is **unverified (needs Xcode)**.

**Status:** `CoachDigestBuilder` (`Engines/CoachDigest.swift`), `APIClient.coachSummary(digest:)` with `CoachSummaryError.proRequired` for `402 pro_required` (the scan-quota 402 mapping is unchanged), tests in `CoachDigestTests.swift`, all passing with `swift test`. The card (`Features/Coach/CoachSummaryCard.swift`) and the wiring (`App/AppModel+Coach.swift`) were written but **not compiled or run (UI unverified, no Xcode)**. No analytics event was added: event names mirror the backend list.
Digest rules: weights in the user's unit; nutrition covers the 7 complete days before today; `e1rm_30d_ago` is the oldest session in the last 30 days (as on Today); trend weights need a weigh-in in the last 14 days (now) or 14–28 days ago (then).

### [x] T5: Measurements and progress photos (on device) (UI unverified)
> "measurements and progress photos (on device)"

Owner: mobile-app-builder with privacy-engineer. Files: `Packages/VectorCore/**` (models, `AppData` optional fields, `SyncMerge`, analytics), `App/Vector/Features/Progress/**` (new files preferred), `App/Vector/App/*` wiring.
- **Measurements:** waist, hips, chest, arm, thigh, neck in cm, displayed in the user's unit. Each is optional per entry, and trends come from logged values only.
- **Photos:** stored only in the app container with complete file protection, excluded from backup, never uploaded and never in the iCloud JSON. Metadata (id, date, pose: front/side/back) lives in `AppData`. Show a side-by-side compare of two dates. Deleting removes the file.

**Evidence:** `swift test` covers model decoding with missing fields (old data), SyncMerge union/tombstones for measurements, and per-measurement trend series. UI is **unverified**.

Status: core done and tested (`MeasurementsTests`, 14 tests: legacy decoding, partial entries, measurement union/tombstones, photo metadata kept device-local, `SyncMerge.cloudCopy`, logged-values-only series, same-day upsert, cm/in formatting, compare-day selection). App: `AppModel+Body.swift` (`ProgressPhotoStore`: Application Support/ProgressPhotos, `.completeFileProtection`, excluded from backup, ~2048 px JPEG re-encode), `Features/Progress/MeasurementsView.swift`, `Features/Progress/ProgressPhotosView.swift` (PhotosPicker + camera, pose, delete removes file, side-by-side compare), entry point on the Progress dashboard. **UI unverified (needs Xcode).** Follow-up outside T5's files: `Platform/CloudSync.swift` `write` should write `SyncMerge.cloudCopy(toWrite)` so photo metadata never reaches the iCloud JSON file (other devices already ignore it on merge).

### [x] T6: Protein-adherence and calorie charts (core verified; UI unverified)
> "protein-adherence and calorie charts"

Owner: mobile-app-builder. Files: `Packages/VectorCore/Sources/VectorCore/Engines/AnalyticsEngine.swift` (or a new file), tests, `App/Vector/Features/Progress/**`.
- Daily calories vs target and daily protein vs target over 1W/1M/3M, counting logged days only (unlogged days are gaps, not zeros).
- Protein adherence: days hit / days logged, plus the current streak.
- Charts follow the Ink system (monochrome, data colours only for macros).

**Evidence:** `swift test` covers series bucketing, gaps for unlogged days and adherence maths. UI is **unverified**.

**Status:** `NutritionChartEngine` (`Engines/NutritionCharts.swift`): 7D/1M daily, 3M weekly averages of logged days; unlogged days and weeks are absent (gaps), not zero; adherence = days hit / days logged, with today counted only once hit, plus the existing protein streak. Tests in `NutritionChartTests.swift`, all passing. The Progress section (`Features/Progress/NutritionChartsSection.swift`, one insertion in `ProgressDashboardView`) was written but **not compiled or run (UI unverified, no Xcode)**. This deliberately differs from design-system §2.7 ("empty buckets render as zero") for nutrition, as this task requires.

### [ ] T7: Real Terms and Privacy pages
> "real Terms and Privacy pages"

Owner: privacy-engineer. Files: `web/legal/**`, `docs/legal/**`.
- The privacy policy must match what the app and backend actually collect and keep: Apple `sub` only, subscription records, AI usage, scan results and corrections without photos, analytics with opt-out, iCloud and on-device logs, Open Food Facts lookups, Anthropic as processor, deletion behaviour, and retention.
- Terms: subscriptions via Apple, AI estimates are not medical advice, acceptable use.
- Ship as static HTML (minimal, Ink style) ready to host, with the URLs to put in `VectorTermsURL` / `VectorPrivacyURL`. Mark both **"Draft: requires legal review before publishing."**

**Evidence:** each data claim cites the code or migration that implements it (a checklist at the bottom of the doc).

### [ ] T8: App icon
> "app icon and screenshots"

Owner: ui-designer. Files: `design/icon/**`, `App/Vector/Resources/Assets.xcassets/AppIcon.appiconset/**`.
- Ink style: a monochrome mark, recognisable at 29 pt, no text, no gradients.
- SVG source plus a 1024×1024 PNG. Contents.json uses the single-size universal iOS icon, with light, dark and tinted variants.

**Evidence:** rendered PNGs at 1024, 180 and 58 px, viewed and attached. Screenshots are **blocked** (need the simulator).

### Blocked in this environment (not attempted)
- Build in Xcode and fix compile errors (requires a Mac).
- HealthKit steps and resting heart rate (needs a device or simulator to verify).
- App Attest (needs a real device; server verification is planned once a device can produce attestations).
- App Store screenshots (needs the simulator).
