> **Draft: requires legal review before publishing.** This text describes what the Vector app and its backend actually do, as of the code in this repository. It is not legal advice. Everything in [square brackets] is a placeholder to fill in, and the jurisdiction-specific sections (legal bases, rights, transfers) must be checked by counsel for every market you launch in.

# Vector Privacy Policy

Last updated: [Date]

Vector ("the app") is made by [Company legal name] ("we", "us"), [Registered address]. You can reach us at [Contact email]. [If required: our data protection officer / EU or UK representative is [Name, contact].]

## The short version

- **Your training and food logs are not on our servers.** They stay on your device and, if you use iCloud, in your own private iCloud storage. The exception is the optional Pro coach summary (section 2.4): we keep its text, which quotes some of your numbers.
- **An account is optional.** You only need one for AI meal scans and to link a Pro subscription. We get a private, app-specific identifier from Sign in with Apple (pseudonymous, not anonymous). We never receive your name or email.
- **Meal photos go to our AI provider for analysis and are not stored.** We keep the result (the foods and the nutrition estimate) and how you corrected it, so we can measure and improve accuracy.
- **Usage analytics are on by default, and you can turn them off.** Turning them off also deletes the analytics we have already stored for your account.
- **Deleting your account deletes your personal data on our servers.** What is kept: AI usage and cost records with your identifier removed, and, if your App Store subscription is still active, the renewal records Apple keeps sending us (section 6).
- We do not sell your data, we do not use it for advertising, and we do not track you across other companies' apps or websites.

## 1. What stays on your device (and your iCloud)

These are stored by the app on your iPhone, and shared with your paired Apple Watch, home-screen widgets and Live Activity when you use them. We have no copy of them.

| Data | Where it lives |
|---|---|
| Your profile: the name you type, goal, experience, training days, equipment, sex, birth year, height, weight, target weight, nutrition targets, dietary preferences | On device; in your iCloud if iCloud Sync is on |
| Workouts, sets, notes, programs, templates, custom exercises, favourites, rest preferences | On device; in your iCloud if iCloud Sync is on |
| Food logs, saved meals, favourite foods, body-weight entries, weekly nutrition check-ins | On device; in your iCloud if iCloud Sync is on |
| Progress photos and body measurements | Photos: on this device only, never uploaded and never in iCloud. Measurements: on device and in your iCloud if iCloud Sync is on |
| Crash and performance diagnostics from Apple's MetricKit | On device only |
| Analytics events waiting to be sent (at most 500) | On device until uploaded or until you turn analytics off |
| Your sign-in session tokens | In the device Keychain, this device only, not in backups |

**iCloud Sync.** If you are signed in to iCloud and leave iCloud Sync on (Profile › iCloud Sync), the app keeps one file with the data above in the app's private container in *your* iCloud account, so your devices stay in step. That storage is provided by Apple under Apple's terms and privacy policy, and we cannot read it. You can turn iCloud Sync off at any time.

**Progress photos** are saved inside the app's own storage with iOS complete file protection, are excluded from device backups, are never uploaded to us, and are never included in the iCloud sync file. Deleting a photo in the app deletes the file.

**Diagnostics.** The app subscribes to Apple's MetricKit, which delivers crash, hang, launch-time and memory reports at most once a day. The app keeps these reports on your device. We do not currently upload them. [If you later add an upload endpoint, update this section first.] Separately, if you have chosen to share analytics with app developers in iOS Settings, Apple may share crash data with us under Apple's terms.

**Exporting and erasing local data.** Profile lets you export your data as a JSON file and "Reset Everything", which erases your logs on this device and removes them from your iCloud copy so your other devices delete them too.

## 2. What we store on our servers

Our backend runs on [Hosting provider] with a PostgreSQL database hosted by [Database provider], in [Region/country]. It only exists to run sign-in, AI features, subscriptions and analytics. It stores the following.

### 2.1 Account (only if you sign in)

- **Apple user identifier.** When you sign in with Apple, Apple gives us a stable, app-specific identifier for you (the `sub` value). We verify the sign-in with Apple and store that identifier only. We do not store your name or email, even if Apple offers them.
- **Account dates and preference:** when the account was created, when it was last used, and whether you have opted out of analytics.
- **Session tokens.** Refresh tokens are stored only as one-way hashes. They expire after 60 days and are replaced every time they are used.

### 2.2 Subscription records

When you buy or restore Vector Pro, the app sends us the transaction that Apple signed, and Apple's servers also notify us directly when a subscription renews, expires, is refunded or changes (App Store Server Notifications). We check Apple's signature on both and store: the original transaction ID, product, environment (production or sandbox), purchase date, expiry date, any refund/revocation date, whether auto-renew is on, any billing grace period, and the dates Apple signed this information. We also keep a log of the notifications Apple sent (notification ID, type, date and original transaction ID, but no account identifier) for 90 days. We use this to decide whether your account has Pro. **We never see your payment details.** Apple handles all billing.

### 2.3 AI meal scans

When you scan a meal:

1. The app shrinks the photo (about 1024 pixels, JPEG) and sends it to our backend over HTTPS with your sign-in token.
2. Our backend sends the photo to **Anthropic** (our AI provider, see section 3) and receives a list of foods with estimated portions, calories and macros.
3. **The photo is not stored.** We keep only a SHA-256 fingerprint of it for 24 hours of duplicate detection (the same photo sent twice returns the earlier result instead of a second AI call). This fingerprint cannot be turned back into the photo.

We store:

- **The scan result:** the foods, estimated grams, calories, protein, carbs, fat, confidence and alternative names the AI returned.
- **Your correction, if you log the meal:** counts of items renamed, removed, added or with changed portions or macros, the number of items detected and logged, and the estimated vs. logged calories. We do not receive the names of the foods you change them to, or your notes.
- **Usage and cost records** for every AI request: time, kind of request, status (success, no food found, refused, error, cached), your tier (free or Pro), the model that answered, token counts, cost, response time, photo size in bytes, the photo fingerprint and an error code if it failed. We use these to enforce fair-use limits (free: 3 scans per 7 days; Pro: a daily fair-use ceiling) and to monitor what the service costs.

### 2.4 AI coach summary (Pro)

If you have Pro and are signed in, the app can request a short weekly summary of your progress. The app sends a **structured digest** of numbers it has already calculated on your device (for example workouts this week, average calories vs. target, protein days hit, weight trend, your goal and top recommendations). The digest also contains **exercise names**, including names you gave custom exercises, and the app's own recommendation sentences. It does not send your food logs or food names, notes, measurements or photos. Our backend passes the digest to Anthropic without your account identifier, stores the **generated summary text** for that day (so it is created only once; the text can quote numbers from your digest, such as weights or calories), and records a usage and cost row as in 2.3. The digest itself is not stored on our servers.

### 2.5 Product analytics

If you are signed in and analytics are on, the app sends usage events such as "app opened", "workout started/completed", "set logged", "food logged", "AI scan" and "paywall viewed". Events carry coarse properties only, such as counts (sets, exercises, items), duration in minutes, workout source, meal slot, goal and experience level, whether a set was a personal record, and the app version. **Events never contain food names, notes, photos or other free text.** Event names are on a fixed allow-list on the server, and anything else is rejected.

Analytics events are linked to your account identifier (so they are pseudonymous, not anonymous). We use them to understand which features help people and to fix product problems. We do not share them with advertisers or data brokers, and we use no third-party analytics or advertising SDKs.

**Opting out.** Turn off Profile › Account › "Share usage analytics". The app immediately stops recording events and discards any it hasn't sent yet. It tells our server, which records your choice, **deletes all analytics events already stored for your account**, and ignores any events that still arrive.

### 2.6 Server logs and security

For every request our server writes one log line: a request ID, method, path, status, response time and (if signed in) your account ID. Request bodies, tokens and photos are never logged. To limit abuse, the server counts requests per IP address in memory for one minute on the sign-in and App Store notification endpoints. IP addresses are not written to our database. Our hosting provider may process IP addresses and keep its own logs under its terms. Log retention: [Log retention period, set in the hosting provider].

## 3. Who else processes your data

| Recipient | What they receive | Why |
|---|---|---|
| **Anthropic, PBC** (AI model provider), as our processor | Meal photos you scan; coach digests if you use the Pro summary. No account identifier is sent. | To produce the food estimate or summary. [Confirm the Anthropic commercial terms and DPA: data is not used to train models, retention period, sub-processors, region.] |
| **Apple** | Sign in with Apple, App Store purchases, iCloud storage, Apple Health, MetricKit | Apple provides these services under its own terms and privacy policy. |
| **Open Food Facts** (open food database) | When you search foods or scan a barcode, **your device** sends the search text or barcode **directly** to Open Food Facts. It does not go through our servers. Open Food Facts receives your IP address as with any web request. | To find products and nutrition data. Open Food Facts has its own privacy policy. |
| **[Hosting provider], [Database provider]** | Everything in section 2, as our processors | To run the service |

We do not sell or rent personal data, and we do not share it for cross-context behavioural advertising. We may disclose data if the law requires it, or as part of a merger or acquisition under the same protections. [Legal to confirm wording.]

## 4. Apple Health

Apple Health is **opt-in**. If you allow it, Vector **writes** your finished strength workouts (type, start and end time, workout name) and the weigh-ins you log, and **reads** body weight to keep your trend up to date. Data from Apple Health stays on your device and in your app data as described in section 1. It is never sent to our servers, never used for advertising or marketing, and never sold. You can change access at any time in the Health app › Sharing › Apps › Vector.

## 5. Camera and photos

The camera is used to photograph meals for AI estimates, to read food barcodes and to take progress photos. The photo library is used only when you choose a meal photo or a progress photo. Meal photos are sent for analysis as described in 2.3 and are not stored by the app or on our servers. Progress photos stay on your device (section 1).

## 6. Deleting your account

In Profile › Account › Delete Account, the app asks our server to delete your account. This **immediately and permanently deletes**:

- your account record and Apple identifier,
- all your session tokens (any signed-in device is signed out),
- your subscription records,
- your meal-scan results and corrections,
- your analytics events,
- your coach summaries.

**What is kept:** AI usage and cost records (section 2.3) stay **with your account identifier removed**, so our cost totals remain accurate. They still contain the time, tier, model, token counts, cost, status and photo fingerprint and size, but nothing that links them to you. Server log lines written before deletion are kept until they expire under the log retention above.

**What is separate:**
- **Your logs on your device and iCloud.** After deleting your account, the app offers to erase them as well. You can also keep them and keep using the app without an account.
- **Your subscription.** Deleting your account does not cancel an App Store subscription. Cancel it in Settings › [your name] › Subscriptions. While it stays active, Apple keeps sending us renewal notifications, and we store the subscription record again (original transaction ID, product and dates) **without any link to an account**. If you sign in again later, it can be linked to your new account; otherwise it lapses when the subscription ends.
- **Sign in with Apple.** To stop Vector from using your Apple ID, go to Settings › [your name] › Sign-In & Security › Sign in with Apple. [Planned: automatic revocation of the Apple token on account deletion.]

## 7. How long we keep data

| Data | Kept |
|---|---|
| Account, subscription records, scan results, corrections and coach summaries | Until you delete your account (see section 6 for subscriptions that are still active). [Decide whether inactive accounts are deleted after a period, e.g. [N] months, and implement it before stating it.] |
| Refresh tokens | Expire after 60 days and are replaced on each use. Records are removed when the account is deleted. |
| Photo fingerprint used for duplicate detection | Used for 24 hours. Kept afterwards inside the de-identified usage record. |
| Analytics events | Until you opt out or delete your account. [Decide whether to add a fixed limit, e.g. [N] months.] |
| AI usage and cost records | Kept for cost accounting. De-identified when you delete your account. [Retention period, if any.] |
| App Store notification log | 90 days. |
| Server logs | [Log retention period] |
| Meal photos | Not stored by us. At Anthropic: [per our agreement with Anthropic]. |
| On-device and iCloud data | Until you delete it, reset the app or delete the app. iCloud copies are managed in your iCloud settings. |

## 8. Your rights

Depending on where you live, you may have the right to access, correct, delete, export or restrict the use of your personal data, to object to processing, and to complain to a data protection authority. Most of your data is already in your hands: export it from Profile, and delete it with Delete Account and Reset Everything. For anything else, email [Contact email]. We will respond within [30 days / the period required by law in [Jurisdiction]]. Because we do not store your name or email, we may need you to send the request from within the app or prove you control the account.

[Legal bases (if GDPR/UK GDPR applies), for counsel to confirm: providing the service you requested (account, scans, subscriptions); our legitimate interests, with an opt-out (analytics, security, cost monitoring); your explicit consent (Apple Health data, which stays on device). Add US state notices (e.g. CCPA/CPRA, Washington My Health My Data Act) if relevant, because body weight, nutrition and fitness data can be treated as consumer health data.]

## 9. International transfers

Our servers are in [Region/country]. Anthropic may process data in [Region(s)]. [If you serve the EU/UK: describe transfer safeguards such as Standard Contractual Clauses.]

## 10. Security

Traffic between the app and our servers uses HTTPS. Sign-in uses short-lived access tokens (1 hour) and rotating refresh tokens stored as hashes, and a reused refresh token signs out the whole session family. Subscription transactions are verified against Apple's certificate chain. AI provider keys are kept on the server and never in the app. No system is perfectly secure, and we will notify you and the authorities of a breach where the law requires it.

## 11. Children

Vector is not intended for children under [13 / 16 / the minimum age in [Jurisdiction]], and we do not knowingly collect their data. [Legal to confirm the age and the App Store age rating.]

## 12. Changes

We will update this page and the "Last updated" date when our practices change, and tell you in the app before material changes take effect.

## 13. Contact

[Company legal name], [Registered address], [Contact email].

---

## Implementation references

Every factual claim above, mapped to the code that implements it. Last checked against `feature/vector-ios-app` after P1 (T1–T8 and the review fixes). Re-check this list before publishing and after any change to these files.

**On device / iCloud**
- [x] Training, food, body-weight, profile and check-in data are one local JSON document: `Packages/VectorCore/Sources/VectorCore/Services/Persistence.swift` (`AppData`, `JSONFileStore.applicationSupport`).
- [x] Profile fields listed: `Packages/VectorCore/Sources/VectorCore/Models/Profile.swift` (`UserProfile`).
- [x] iCloud Sync uses the app's private ubiquity container, one file, merge before write, user toggle: `App/Vector/Platform/CloudSync.swift` (`ICloudDocumentSync`, `CloudSyncPreference`), `App/Vector/Features/Profile/ProfileView.swift` (toggle), `project.yml` (`NSUbiquitousContainerIsDocumentScopePublic: false`).
- [x] Reset Everything tombstones all records so other devices delete them: `App/Vector/App/AppModel.swift` (`resetAll`). Export: `exportData` in the same file.
- [x] Session tokens in Keychain, this device only, not backed up: `App/Vector/Platform/KeychainTokenStore.swift` (`kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`).
- [x] Pending analytics kept on device, max 500, cleared on opt-out: `Packages/VectorCore/Sources/VectorCore/Services/Analytics.swift` (`EventQueue.maxQueued`, `clear`), `App/Vector/Platform/KeychainTokenStore.swift` (`EventQueueFile`), `App/Vector/App/AppModel+Account.swift` (`setAnalyticsEnabled`).
- [x] MetricKit diagnostics stored in the on-device caches folder; `upload` hook exists but is never assigned: `App/Vector/Platform/Diagnostics.swift`, `App/Vector/App/VectorApp.swift` (only calls `start()`).
- [x] Progress photos on device only, complete file protection, excluded from backup, EXIF dropped by re-encoding, never in the iCloud file; measurements in `AppData`: `App/Vector/App/AppModel+Body.swift` (`ProgressPhotoStore`), `Packages/VectorCore/Sources/VectorCore/Services/SyncMerge.swift` (`cloudCopy`, photos kept local in `merge`), `App/Vector/Platform/CloudSync.swift` (`write` uses `cloudCopy`).

**Server: account and tokens**
- [x] Only Apple `sub` stored, no email or name: `backend/api/src/auth.ts` (`verifyAppleIdentity` returns `payload.sub`, `signInWithApple` inserts `apple_sub` only), `backend/api/migrations/001_init.sql` (`users` table has no email/name columns).
- [x] `created_at`, `last_seen_at`, `analytics_opt_out`: `001_init.sql` (`users`).
- [x] Refresh tokens stored as SHA-256, 60-day expiry, rotation and reuse detection; access tokens 1 hour: `backend/api/src/auth.ts` (`REFRESH_TOKEN_TTL_DAYS`, `ACCESS_TOKEN_TTL_SECONDS`, `refreshSession`), `001_init.sql` (`refresh_tokens.token_hash`).
- [x] A deleted account's access token stops working: `backend/api/src/auth.ts` (`authenticate` checks the user row).

**Server: subscriptions**
- [x] Fields stored and Apple chain verification: `backend/api/src/appStore.ts` (`verifySignedTransaction`, `recordTransaction`), `001_init.sql` (`subscriptions`). No payment details are present in the StoreKit payload stored.
- [x] App stamps purchases with the account id: `App/Vector/Platform/PurchaseService.swift` (`appAccountToken`).

**Server: AI meal scans**
- [x] Photo downscaled to 1024 px JPEG at 0.7: `App/Vector/Features/Scanner/MealScannerFlow.swift`.
- [x] Photo sent to Anthropic, not stored; only SHA-256 kept; 24 h duplicate cache: `backend/api/src/mealScan.ts` (`scanMeal`, `CACHE_HOURS`), `backend/api/src/analyze.ts` (`analyzeMeal`), `001_init.sql` (`ai_requests.image_sha256`, comment "Meal photos are never stored").
- [x] No account identifier sent to Anthropic: `backend/api/src/analyze.ts` (request contains only the system prompt, the image and a fixed instruction).
- [x] Scan result fields stored: `backend/api/src/analyze.ts` (`MealItem`), `001_init.sql` (`meal_scans.items`).
- [x] Correction fields (counts and calories, no names): `backend/api/src/mealScan.ts` (`ScanCorrection`, `recordCorrection`), `Packages/VectorCore/Sources/VectorCore/Services/MealRecognition.swift` (`ScanCorrection`).
- [x] Usage and cost row fields: `001_init.sql` (`ai_requests`), `backend/api/src/mealScan.ts` (`cost`, updates after the call).
- [x] Quotas (3 per 7 days free, Pro daily ceiling): `backend/api/src/mealScan.ts` (`allowance`), `backend/api/src/config.ts`.
- [x] Coach summary (2.4): digest fields incl. exercise names (`Packages/VectorCore/Sources/VectorCore/Engines/CoachDigest.swift`), no account id sent and digest not stored, summary text stored once per user per day, cost row `kind = 'coach_summary'`: `backend/api/src/coach.ts`, `backend/api/migrations/003_coach_summaries.sql`; deleted with the account (`on delete cascade`).
- [x] App Store Server Notifications: verified, fields stored, unlinked records after deletion, 90-day notification log: `backend/api/src/appleNotifications.ts`, `backend/api/migrations/002_apple_notifications.sql` (and the retention change in `backend/api`).

**Server: analytics**
- [x] Allow-listed event names, property limits (no free text beyond 200-char strings): `backend/api/src/events.ts` (`EVENT_NAMES`, `Property`, `Event`), `Packages/VectorCore/Sources/VectorCore/Services/Analytics.swift`.
- [x] Properties actually sent are coarse counts/enums: `App/Vector/App/AppModel.swift`, `AppModel+Training.swift`, `AppModel+Loop.swift` (`track(...)` calls).
- [x] Events linked to `user_id`: `001_init.sql` (`analytics_events.user_id`), `App/Vector/Resources/PrivacyInfo.xcprivacy` (`ProductInteraction`, linked).
- [x] Opt-out deletes stored events and blocks new ones: `backend/api/src/app.ts` (`PATCH /v1/me`), `backend/api/src/events.ts` (`ingestEvents` checks `analytics_opt_out`), `App/Vector/App/AppModel+Account.swift` (`setAnalyticsEnabled`).
- [x] Analytics on by default: `App/Vector/Platform/KeychainTokenStore.swift` (`AnalyticsPreference.isEnabled` defaults to `true`).
- [x] Events only uploaded when signed in (queued while signed out): `App/Vector/App/VectorApp.swift` (`EventQueue` setup comment), `APIClient.send(events:)` requires auth.
- [x] No third-party analytics/ads SDKs, no tracking: `App/Vector/Resources/PrivacyInfo.xcprivacy` (`NSPrivacyTracking` false, no tracking domains); no such dependency in `project.yml`.

**Server: logs and security**
- [x] Log line fields, bodies/tokens/images never logged: `backend/api/src/http.ts` (`Router.handle` `finally` block).
- [x] IP counted in memory for the sign-in and notification endpoints: `backend/api/src/http.ts` (`IpRateLimiter`), `backend/api/src/app.ts` (`authLimiter`, `notificationLimiter`).
- [x] AI key only on the server: `backend/api/README.md` (`ANTHROPIC_API_KEY`), `backend/api/src/config.ts`.

**Third parties**
- [x] Open Food Facts called directly from the device, no key, our User-Agent: `Packages/VectorCore/Sources/VectorCore/Services/OpenFoodFacts.swift` (`search.openfoodfacts.org`, `world.openfoodfacts.org`).
- [x] Anthropic as the only AI provider: `backend/api/src/analyze.ts`, `backend/api/src/mealScan.ts` (`@anthropic-ai/sdk`).

**Apple Health**
- [x] Opt-in authorization; writes workouts and body mass, reads body mass only: `App/Vector/Platform/HealthService.swift` (`requestAuthorization(toShare: [workoutType, bodyMass], read: [bodyMass])`), `project.yml` (`NSHealthUpdateUsageDescription`).
- [x] Health data never sent to the server: no Health values in `APIClient.swift` requests or in analytics properties (see analytics items above).

**Camera and photos**
- [x] Purpose strings cover meals, barcodes and progress photos: `project.yml` (`NSCameraUsageDescription`, `NSPhotoLibraryUsageDescription`). The scanner keeps the image in memory only: `App/Vector/Features/Scanner/MealScannerFlow.swift`.

**Account deletion**
- [x] `DELETE /v1/me` deletes the user row; cascades to `refresh_tokens`, `subscriptions`, `meal_scans`, `analytics_events`; `ai_requests.user_id` set to null: `backend/api/src/app.ts`, `001_init.sql` (`on delete cascade` / `on delete set null`).
- [x] App offers to erase local data afterwards and warns that the subscription must be cancelled in Settings: `App/Vector/Features/Profile/AccountViews.swift`, `App/Vector/App/AppModel+Account.swift` (`deleteAccount`).
- [x] Apple token revocation not yet done: `backend/api/README.md` ("Not yet done (P1)").

**Not backed by code (placeholders or decisions, see report)**
- [ ] Retention limits for inactive accounts, analytics events, AI cost rows and server logs: no automated expiry job exists. Only the stated behaviour (kept until deletion/opt-out) is true today.
- [ ] Anthropic data handling (training use, retention, region): contractual, not visible in code.
- [ ] Hosting/database provider, region, transfer safeguards, breach notification, children's age, response time for requests: business and legal decisions.
