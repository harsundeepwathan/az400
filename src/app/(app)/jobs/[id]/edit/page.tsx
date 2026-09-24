import type { Metadata } from "next";
import { notFound } from "next/navigation";
import { JobForm } from "@/components/jobs/job-form";
import { PageHeader } from "@/components/ui/display";
import { getJob } from "@/lib/data/jobs";
import { todayForUser } from "@/lib/server-date";
import { requireOnboardedUser } from "@/lib/session";
import { uuidSchema } from "@/lib/validation";
import { saveJobAction } from "../../actions";

export const metadata: Metadata = { title: "Edit job" };

export default async function EditJobPage({ params }: { params: Promise<{ id: string }> }) {
  const { user, profile } = await requireOnboardedUser();
  const { id } = await params;
  if (!uuidSchema.safeParse(id).success) notFound();
  const job = await getJob(user.id, id);
  if (!job) notFound();
  return (
    <>
      <PageHeader title={`Edit: ${job.title}`} />
      <JobForm action={saveJobAction.bind(null, id)} initial={job} defaults={{ currency: profile.salary_currency, today: await todayForUser() }} submitLabel="Save changes" />
    </>
  );
}
