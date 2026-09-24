import type { Metadata } from "next";
import { Download } from "lucide-react";
import { DeleteAccountForm, PreferencesForm } from "@/components/profile/settings-forms";
import { ProfileForm } from "@/components/profile/profile-form";
import { buttonClass } from "@/components/ui/button";
import { Badge, Card, CardHeader, PageHeader } from "@/components/ui/display";
import { env } from "@/lib/env";
import { requireOnboardedUser } from "@/lib/session";
import { updateProfileAction } from "@/app/profile-actions";
import { deleteAccountAction, saveSettingsAction } from "./actions";

export const metadata: Metadata = { title: "Settings" };

export default async function SettingsPage() {
  const { user, profile, settings, targetRoles } = await requireOnboardedUser();
  const e = env();
  return (
    <>
      <PageHeader title="Settings" description={`Signed in as ${user.email}.`} />
      <div className="space-y-4">
        <Card>
          <CardHeader title="Search profile" description="Used in fit analysis and your daily plan." />
          <ProfileForm action={updateProfileAction} initial={{ ...profile, target_roles: targetRoles }} submitLabel="Save profile" />
        </Card>
        <Card>
          <CardHeader title="Preferences" />
          <PreferencesForm action={saveSettingsAction} initial={settings} />
        </Card>
        <Card>
          <CardHeader title="AI provider" />
          <dl className="grid gap-2 text-sm sm:grid-cols-3">
            <div><dt className="text-muted">Provider</dt><dd>{e.AI_PROVIDER === "mock" ? <Badge tone="warning">Mock (offline demo)</Badge> : <Badge tone="accent">OpenAI-compatible</Badge>}</dd></div>
            <div><dt className="text-muted">Model</dt><dd>{e.AI_PROVIDER === "mock" ? "Deterministic templates" : e.AI_MODEL}</dd></div>
            <div><dt className="text-muted">Hourly limit</dt><dd>{e.AI_RATE_LIMIT_PER_HOUR} operations</dd></div>
          </dl>
          <p className="mt-3 text-xs text-muted">
            Only the data an operation needs is sent: job text, requirements and your career facts. Contact details are never sent. Resume and job text are marked as untrusted data in every prompt. JobPilot makes no claims about how your provider uses data; check its terms.
          </p>
        </Card>
        <Card>
          <CardHeader title="Your data" description="Download everything JobPilot stores about you as JSON." />
          <a href="/api/export" className={buttonClass("secondary")} download>
            <Download className="h-4 w-4" aria-hidden /> Export my data
          </a>
        </Card>
        <Card className="border-danger/30">
          <CardHeader title="Delete account" description="Permanently deletes your account, resumes, uploaded files, jobs, applications, notes and analytics. This cannot be undone." />
          <DeleteAccountForm action={deleteAccountAction} email={user.email} />
        </Card>
      </div>
    </>
  );
}
