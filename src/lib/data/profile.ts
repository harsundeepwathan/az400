import "server-only";
import { withUser } from "../db";

export type Profile = {
  user_id: string;
  full_name: string;
  current_title: string;
  preferred_locations: string[];
  workplace_preference: "remote" | "hybrid" | "onsite" | "flexible";
  target_salary: number | null;
  salary_currency: string;
  employment_types: string[];
  willing_to_relocate: boolean;
  work_authorization_notes: string;
  search_started_on: string | null;
  onboarding_completed_at: string | null;
};

export type Settings = {
  weekly_application_goal: number;
  follow_up_after_days: number;
  ai_assistance_enabled: boolean;
};

export type ProfileBundle = { profile: Profile; settings: Settings; targetRoles: string[] };

/** Creates the profile and settings rows on first use (works for both auth modes). */
export async function getProfileBundle(userId: string): Promise<ProfileBundle> {
  return withUser(userId, async (db) => {
    await db.query("insert into profiles (user_id) values ($1) on conflict do nothing", [userId]);
    await db.query("insert into user_settings (user_id) values ($1) on conflict do nothing", [userId]);
    const profile = await db.one<Profile>(
      `select user_id, full_name, current_title, preferred_locations, workplace_preference, target_salary,
              salary_currency, employment_types, willing_to_relocate, work_authorization_notes,
              to_char(search_started_on, 'YYYY-MM-DD') as search_started_on, onboarding_completed_at
         from profiles where user_id = $1`,
      [userId],
    );
    const settings = await db.one<Settings>(
      "select weekly_application_goal, follow_up_after_days, ai_assistance_enabled from user_settings where user_id = $1",
      [userId],
    );
    const roles = await db.query<{ title: string }>("select title from target_roles where user_id = $1 order by position", [userId]);
    return { profile: profile!, settings: settings!, targetRoles: roles.map((r) => r.title) };
  });
}

export type ProfileInput = Omit<Profile, "user_id" | "onboarding_completed_at"> & { target_roles: string[] };

export async function saveProfile(userId: string, input: ProfileInput, completeOnboarding: boolean) {
  await withUser(userId, async (db) => {
    await db.query(
      `update profiles set full_name = $2, current_title = $3, preferred_locations = $4, workplace_preference = $5,
              target_salary = $6, salary_currency = $7, employment_types = $8, willing_to_relocate = $9,
              work_authorization_notes = $10, search_started_on = $11,
              onboarding_completed_at = case when $12::boolean then coalesce(onboarding_completed_at, now()) else onboarding_completed_at end
        where user_id = $1`,
      [
        userId, input.full_name, input.current_title, input.preferred_locations, input.workplace_preference,
        input.target_salary, input.salary_currency, input.employment_types, input.willing_to_relocate,
        input.work_authorization_notes, input.search_started_on, completeOnboarding,
      ],
    );
    await db.query("delete from target_roles where user_id = $1", [userId]);
    for (const [i, title] of input.target_roles.entries()) {
      await db.query("insert into target_roles (user_id, title, position) values ($1, $2, $3)", [userId, title, i]);
    }
  });
}

export async function saveSettings(userId: string, s: Settings) {
  await withUser(userId, (db) =>
    db.query(
      "update user_settings set weekly_application_goal = $2, follow_up_after_days = $3, ai_assistance_enabled = $4 where user_id = $1",
      [userId, s.weekly_application_goal, s.follow_up_after_days, s.ai_assistance_enabled],
    ),
  );
}
