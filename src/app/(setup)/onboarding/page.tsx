import type { Metadata } from "next";
import { redirect } from "next/navigation";
import { ProfileForm } from "@/components/profile/profile-form";
import { requireUser } from "@/lib/auth";
import { getProfileBundle } from "@/lib/data/profile";
import { todayForUser } from "@/lib/server-date";
import { completeOnboardingAction } from "@/app/profile-actions";

export const metadata: Metadata = { title: "Set up your search" };

export default async function OnboardingPage() {
  const user = await requireUser();
  const { profile, targetRoles } = await getProfileBundle(user.id);
  if (profile.onboarding_completed_at) redirect("/today");
  const today = await todayForUser();
  return (
    <>
      <p className="text-sm font-medium text-accent">Step 1 of 2 · Your search</p>
      <h1 className="mt-1 text-2xl font-semibold">Set up your job search</h1>
      <p className="mt-2 text-sm text-muted">
        These preferences shape fit analysis and your daily plan. You can change them any time in Settings. Next, you will add your resume.
      </p>
      <div className="mt-6 rounded-lg border border-line bg-surface p-5 sm:p-6">
        <ProfileForm
          action={completeOnboardingAction}
          submitLabel="Save and continue"
          initial={{ ...profile, target_roles: targetRoles, search_started_on: profile.search_started_on ?? today }}
        />
      </div>
    </>
  );
}
