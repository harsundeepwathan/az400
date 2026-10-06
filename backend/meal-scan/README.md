# Vector meal-scan service

Small Node service that turns a meal photo into itemised calorie and macro estimates with Claude (vision + structured outputs). It exists so the Anthropic API key never ships inside the iOS app.

```
POST /v1/meal-scan        X-Vector-Key: <shared secret>
{ "image": "<base64 JPEG/PNG/WebP>" }
→ 200 { "items": [{ "name", "grams", "calories", "protein", "carbs", "fat", "confidence", "alternatives": [..] }] }
```

An empty `items` list means no food was found; the app then offers search instead. Other codes: 400 bad request, 401 wrong key, 413 image too large, 429 rate limited (10/min per IP), 502/503 upstream problems.

## Run

```bash
npm install
npm run build
ANTHROPIC_API_KEY=sk-ant-... VECTOR_APP_KEY=<random secret> npm start   # :8787
npm test                                                                 # offline tests with a fake client
```

In the app, set `VectorMealScanEndpoint` to `https://<host>/v1/meal-scan` and `VectorMealScanKey` to the same secret (both in `project.yml`).

## Model choices

- `claude-opus-5-5` with structured outputs (JSON schema) so every response parses.
- `effort: "low"` because the user is waiting on the camera screen. Raise it only if a labelled photo set shows better portion accuracy.
- Server-side fallbacks (`fallbacks: "default"`) so a safety-classifier false positive on a food photo doesn't fail the scan.
- The system prompt is byte-stable and marked for prompt caching.

## Before production

- Replace the shared secret with App Attest / DeviceCheck so only genuine app installs can call the endpoint.
- Enforce the free-tier weekly scan quota server-side (the app enforces it client-side today) and return 402 when exceeded.
- Move the in-memory rate limiter to a shared store if you run more than one instance.
