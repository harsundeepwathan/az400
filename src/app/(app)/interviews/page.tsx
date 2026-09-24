import type { Metadata } from "next";
import Link from "next/link";
import { StageBadge } from "@/components/badges";
import { ButtonLink } from "@/components/ui/button";
import { Card, CardHeader, EmptyState, PageHeader } from "@/components/ui/display";
import { listApplications, listInterviews } from "@/lib/data/applications";
import { INTERVIEW_KIND_LABELS, INTERVIEW_STAGES } from "@/lib/domain";
import { userTimeZone } from "@/lib/server-date";
import { requireOnboardedUser } from "@/lib/session";

export const metadata: Metadata = { title: "Interviews" };

export default async function InterviewsPage() {
  const { user } = await requireOnboardedUser();
  const [interviews, apps, tz] = await Promise.all([listInterviews(user.id), listApplications(user.id), userTimeZone()]);
  const now = new Date();
  const upcoming = interviews.filter((i) => new Date(i.scheduled_at) >= now);
  const past = interviews.filter((i) => new Date(i.scheduled_at) < now).reverse();
  const withInterviews = new Set(interviews.map((i) => i.application_id));
  const unscheduled = apps.filter((a) => INTERVIEW_STAGES.includes(a.stage) && !withInterviews.has(a.id));
  const fmt = (d: string) => new Date(d).toLocaleString("en-GB", { dateStyle: "full", timeStyle: "short", timeZone: tz });

  if (interviews.length === 0 && unscheduled.length === 0) {
    return (
      <>
        <PageHeader title="Interviews" />
        <EmptyState title="No interviews yet" description="When an application reaches the screen or interview stage, schedule it from the application workspace to get preparation reminders and a prep pack." action={<ButtonLink href="/applications">Open applications</ButtonLink>} />
      </>
    );
  }

  const Row = ({ i }: { i: (typeof interviews)[number] }) => (
    <li className="flex flex-wrap items-center justify-between gap-3 py-3">
      <div>
        <Link href={`/applications/${i.application_id}`} className="font-medium hover:underline">{i.company} · {i.job_title}</Link>
        <p className="text-sm text-muted">{INTERVIEW_KIND_LABELS[i.kind as keyof typeof INTERVIEW_KIND_LABELS]} · {fmt(i.scheduled_at)}</p>
      </div>
      <ButtonLink href={`/applications/${i.application_id}/interview`} size="sm" variant="secondary">{new Date(i.scheduled_at) >= now ? "Prepare" : "Notes & reflection"}</ButtonLink>
    </li>
  );

  return (
    <>
      <PageHeader title="Interviews" description="Upcoming interviews, preparation and post-interview reflections." />
      <div className="space-y-4">
        <Card>
          <CardHeader title={`Upcoming (${upcoming.length})`} />
          {upcoming.length === 0 ? <p className="text-sm text-muted">Nothing scheduled.</p> : <ul className="-my-3 divide-y divide-line">{upcoming.map((i) => <Row key={i.id} i={i} />)}</ul>}
        </Card>
        {unscheduled.length > 0 && (
          <Card>
            <CardHeader title="In an interview stage, not yet scheduled" />
            <ul className="-my-3 divide-y divide-line">
              {unscheduled.map((a) => (
                <li key={a.id} className="flex flex-wrap items-center justify-between gap-3 py-3">
                  <span><Link href={`/applications/${a.id}`} className="font-medium hover:underline">{a.company} · {a.job_title}</Link> <StageBadge stage={a.stage} /></span>
                  <ButtonLink href={`/applications/${a.id}/interview`} size="sm" variant="secondary">Prepare</ButtonLink>
                </li>
              ))}
            </ul>
          </Card>
        )}
        {past.length > 0 && (
          <Card>
            <CardHeader title={`Past (${past.length})`} />
            <ul className="-my-3 divide-y divide-line">{past.map((i) => <Row key={i.id} i={i} />)}</ul>
          </Card>
        )}
      </div>
    </>
  );
}
