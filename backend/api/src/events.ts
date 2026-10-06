import { z } from "zod";
import type { Db } from "./db.js";
import { HttpError } from "./http.js";

/** Events the app may send. Anything else is rejected rather than stored. */
export const EVENT_NAMES = [
  "onboarding_completed",
  "workout_started",
  "workout_completed",
  "set_logged",
  "food_logged",
  "ai_food_scan",
  "ai_food_scan_corrected",
  "ai_recommendation_viewed",
  "nutrition_checkin_viewed",
  "nutrition_checkin_applied",
  "paywall_viewed",
  "trial_started",
  "subscription_started",
  "subscription_cancelled",
  "app_opened",
  // Coaching
  "recommendation_generated",
  "recommendation_viewed",
  "recommendation_applied",
  "recommendation_rejected",
  "adjustment_created",
  "adjustment_outcome_measured",
  "weekly_checkin_completed",
  "training_progression_accepted",
  "training_progression_rejected",
  "calorie_adjustment_accepted",
  "calorie_adjustment_rejected",
] as const;

const Property = z.union([z.string().max(200), z.number().finite(), z.boolean(), z.null()]);
const Event = z.object({
  id: z.uuid(),
  name: z.enum(EVENT_NAMES),
  occurred_at: z.iso.datetime({ offset: true }),
  properties: z.record(z.string().regex(/^[a-z][a-z0-9_]{0,39}$/), Property).default({}).refine((p) => Object.keys(p).length <= 20, "too many properties"),
});
const Batch = z.object({
  app_version: z.string().max(32).optional(),
  events: z.array(Event).min(1).max(100),
});

/** Stores a batch idempotently. Returns how many were new; opted-out users store nothing. */
export async function ingestEvents(db: Db, userId: string, body: unknown, now: Date): Promise<{ accepted: number; stored: number }> {
  const parsed = Batch.safeParse(body);
  if (!parsed.success) throw new HttpError(400, "invalid_events", { issues: parsed.error.issues.slice(0, 5).map((i) => i.path.join(".") + ": " + i.message) });
  const { rows } = await db.query<{ analytics_opt_out: boolean }>("select analytics_opt_out from users where id = $1", [userId]);
  if (rows[0]?.analytics_opt_out) return { accepted: parsed.data.events.length, stored: 0 };

  // Clock skew happens; anything wildly outside "recently" is clamped to receipt time.
  const earliest = now.getTime() - 30 * 86_400_000;
  const latest = now.getTime() + 86_400_000;
  const events = parsed.data.events.map((event) => {
    const at = Date.parse(event.occurred_at);
    return { ...event, occurred_at: new Date(at < earliest || at > latest ? now.getTime() : at) };
  });
  const result = await db.query(
    `insert into analytics_events (id, user_id, name, properties, occurred_at, app_version)
     select e.id, $1, e.name, e.properties, e.occurred_at, $3
     from jsonb_to_recordset($2::jsonb) as e(id uuid, name text, properties jsonb, occurred_at timestamptz)
     on conflict (id) do nothing`,
    [userId, JSON.stringify(events), parsed.data.app_version ?? null],
  );
  return { accepted: events.length, stored: result.rowCount ?? 0 };
}
