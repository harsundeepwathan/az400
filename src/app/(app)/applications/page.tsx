import type { Metadata } from "next";
import Link from "next/link";
import { ApplicationBoard } from "@/components/applications/board";
import { FitScore, StageBadge } from "@/components/badges";
import { ButtonLink, buttonClass } from "@/components/ui/button";
import { EmptyState, PageHeader } from "@/components/ui/display";
import { Input, Select } from "@/components/ui/form";
import { listApplications } from "@/lib/data/applications";
import { formatDate } from "@/lib/dates";
import { STAGES, STAGE_LABELS } from "@/lib/domain";
import { isStage } from "@/lib/applications/stages";
import { requireOnboardedUser } from "@/lib/session";

export const metadata: Metadata = { title: "Applications" };

export default async function ApplicationsPage({ searchParams }: { searchParams: Promise<{ view?: string; q?: string; stage?: string }> }) {
  const { user } = await requireOnboardedUser();
  const { view = "board", q = "", stage = "" } = await searchParams;
  const stageFilter = isStage(stage) ? stage : "";
  const apps = await listApplications(user.id, { q: q.slice(0, 100), stage: stageFilter });
  const isList = view === "list";
  const qs = (v: string) => `/applications?${new URLSearchParams({ view: v, ...(q ? { q } : {}), ...(stageFilter ? { stage: stageFilter } : {}) })}`;

  return (
    <>
      <PageHeader
        title="Applications"
        description="Drag cards between stages or use the stage menu on each card. Every move is recorded for your analytics."
        actions={<ButtonLink href="/jobs">Start from a saved job</ButtonLink>}
      />
      <div className="mb-4 flex flex-wrap items-end gap-3">
        <nav aria-label="View" className="inline-flex rounded-md border border-line bg-subtle p-0.5">
          <Link href={qs("board")} aria-current={!isList ? "page" : undefined} className={`rounded px-3 py-1.5 text-sm ${!isList ? "bg-surface font-medium shadow-sm" : "text-muted"}`}>Board</Link>
          <Link href={qs("list")} aria-current={isList ? "page" : undefined} className={`rounded px-3 py-1.5 text-sm ${isList ? "bg-surface font-medium shadow-sm" : "text-muted"}`}>List</Link>
        </nav>
        <form role="search" className="flex flex-wrap items-end gap-2">
          <input type="hidden" name="view" value={isList ? "list" : "board"} />
          <label htmlFor="q" className="sr-only">Search applications</label>
          <Input id="q" name="q" type="search" defaultValue={q} placeholder="Search company, title, notes" className="w-56" />
          <label htmlFor="stage" className="sr-only">Filter by stage</label>
          <Select id="stage" name="stage" defaultValue={stageFilter} className="w-44">
            <option value="">All stages</option>
            {STAGES.map((s) => <option key={s} value={s}>{STAGE_LABELS[s]}</option>)}
          </Select>
          <button type="submit" className={buttonClass("secondary")}>Filter</button>
        </form>
      </div>

      {apps.length === 0 ? (
        q || stageFilter ? (
          <EmptyState title="No matching applications" description="Try a different search or stage." action={<ButtonLink href="/applications" variant="secondary">Clear filters</ButtonLink>} />
        ) : (
          <EmptyState title="No applications yet" description="Open a saved job and choose “Start application” to begin preparing and tracking it." action={<ButtonLink href="/jobs">Go to jobs</ButtonLink>} />
        )
      ) : isList ? (
        <div className="relative overflow-x-auto rounded-lg border border-line bg-surface" tabIndex={0} role="region" aria-label="Applications">
          <table className="w-full min-w-[640px] text-left text-sm">
            <thead className="border-b border-line text-xs uppercase tracking-wide text-muted">
              <tr>
                <th className="px-4 py-2 font-medium">Role</th>
                <th className="px-4 py-2 font-medium">Stage</th>
                <th className="px-4 py-2 font-medium">Applied</th>
                <th className="px-4 py-2 font-medium">Next action</th>
                <th className="px-4 py-2 text-right font-medium">Fit</th>
              </tr>
            </thead>
            <tbody className="divide-y divide-line">
              {apps.map((a) => (
                <tr key={a.id}>
                  <td className="px-4 py-2.5">
                    <Link href={`/applications/${a.id}`} className="font-medium hover:underline">{a.job_title}</Link>
                    <p className="text-xs text-muted">{a.company}</p>
                  </td>
                  <td className="px-4 py-2.5"><StageBadge stage={a.stage} /></td>
                  <td className="px-4 py-2.5 text-muted">{formatDate(a.applied_on)}</td>
                  <td className="px-4 py-2.5 text-muted">{a.next_action ? `${a.next_action}${a.next_action_on ? ` · ${formatDate(a.next_action_on)}` : ""}` : a.follow_up_on ? `Follow up ${formatDate(a.follow_up_on)}` : "—"}</td>
                  <td className="px-4 py-2.5 text-right"><FitScore score={a.fit_score} /></td>
                </tr>
              ))}
            </tbody>
          </table>
        </div>
      ) : (
        <ApplicationBoard applications={apps} />
      )}
    </>
  );
}
