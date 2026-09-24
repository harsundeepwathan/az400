import type { Metadata } from "next";
import { JobForm } from "@/components/jobs/job-form";
import { PageHeader } from "@/components/ui/display";
import { todayForUser } from "@/lib/server-date";
import { requireOnboardedUser } from "@/lib/session";
import { saveJobAction } from "../actions";

export const metadata: Metadata = { title: "Save a job" };

export default async function NewJobPage() {
  const { profile } = await requireOnboardedUser();
  return (
    <>
      <PageHeader title="Save a job" description="Paste the job description and fill in what you know. Requirements are extracted automatically; you can edit them afterwards." />
      <JobForm action={saveJobAction.bind(null, null)} defaults={{ currency: profile.salary_currency, today: await todayForUser() }} submitLabel="Save job" />
    </>
  );
}
