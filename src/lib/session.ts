import "server-only";
import { cache } from "react";
import { redirect } from "next/navigation";
import { requireUser } from "./auth";
import { getProfileBundle } from "./data/profile";

/** Signed-in user plus profile; redirects to onboarding until it is complete. */
export const requireOnboardedUser = cache(async () => {
  const user = await requireUser();
  const bundle = await getProfileBundle(user.id);
  if (!bundle.profile.onboarding_completed_at) redirect("/onboarding");
  return { user, ...bundle };
});
