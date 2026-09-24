import type { Metadata } from "next";
import Link from "next/link";
import { FitScore, RecommendationBadge, StageBadge } from "@/components/badges";
import { ButtonLink } from "@/components/ui/button";
import { EmptyState, PageHeader } from "@/components/ui/display";
import { Input } from "@/components/ui/form";
import { listJobs } from "@/lib/data/jobs";
import { formatDate } from "@/lib/dates";
import { requireOnboardedUser } from "@/lib/session";

export const metadata: Metadata = { title: "Jobs" };

export default async function JobsPage({ searchParams }: { searchParams: Promise<{ q?: string }> }) {
  const { user } = await requireOnboardedUser();
  const { q = "" } = await searchParams;
  const jobs = await listJobs(user.id, q.slice(0, 100));

  return (
    <>
      <PageHeader title="Jobs" description="Every job you have saved, with its latest evidence-matching score." actions={<ButtonLink href="/jobs/new">Save a job</ButtonLink>} />
      <form role="search" className="mb-4 max-w-sm">
        <label htmlFor="q" className="sr-only">Search jobs</label>
        <Input id="q" name="q" type="search" defaultValue={q} placeholder="Search by title or company" />
      </form>
      {jobs.length === 0 ? (
        q ? (
          <EmptyState title="No matching jobs" description={`Nothing matches “${q}”.`} action={<ButtonLink href="/jobs" variant="secondary">Clear search</ButtonLink>} />
        ) : (
          <EmptyState title="No jobs saved yet" description="Paste a job description to check your fit and start tracking it." action={<ButtonLink href="/jobs/new">Save your first job</ButtonLink>} />
        )
      ) : (
        <div className="overflow-hidden rounded-lg border border-line bg-surface">
          <ul className="divide-y divide-line">
            {jobs.map((j) => (
              <li key={j.id} className="flex flex-wrap items-center gap-x-4 gap-y-2 px-4 py-3">
                <div className="min-w-0 flex-1">
                  <Link href={`/jobs/${j.id}`} className="font-medium hover:underline">{j.title}</Link>
                  <p className="truncate text-sm text-muted">
                    {j.company}{j.location ? ` · ${j.location}` : ""}{j.closes_on ? ` · closes ${formatDate(j.closes_on)}` : ""}
                  </p>
                </div>
                <div className="flex items-center gap-3">
                  {j.recommendation && <RecommendationBadge recommendation={j.recommendation} />}
                  {j.stage && <StageBadge stage={j.stage} />}
                  <span className="w-20 text-right"><FitScore score={j.fit_score} /></span>
                </div>
              </li>
            ))}
          </ul>
        </div>
      )}
    </>
  );
}
