import type { Metadata } from "next";
import Link from "next/link";
import { NewVersionForm } from "@/components/resume/new-version-form";
import { ButtonLink } from "@/components/ui/button";
import { Badge, Card, CardHeader, EmptyState, PageHeader } from "@/components/ui/display";
import { listJobs } from "@/lib/data/jobs";
import { listResumes, listVersions } from "@/lib/data/resumes";
import { formatDate } from "@/lib/dates";
import { requireOnboardedUser } from "@/lib/session";
import { createVersionAction } from "./actions";

export const metadata: Metadata = { title: "Resumes" };

const STATUS: Record<string, { tone: "success" | "warning" | "danger" | "neutral"; label: string }> = {
  parsed: { tone: "success", label: "Extracted" },
  partial: { tone: "warning", label: "Partly extracted" },
  unreadable: { tone: "danger", label: "Unreadable" },
  manual: { tone: "neutral", label: "Manual" },
};

export default async function ResumesPage({ searchParams }: { searchParams: Promise<{ job?: string }> }) {
  const { user } = await requireOnboardedUser();
  const [resumes, versions, jobs] = await Promise.all([listResumes(user.id), listVersions(user.id), listJobs(user.id)]);
  const { job } = await searchParams;

  return (
    <>
      <PageHeader
        title="Resumes"
        description="Your primary resume is the source of truth for fit analysis. Versions are tailored copies you can print and attach to applications."
        actions={<ButtonLink href="/resumes/new">Add resume</ButtonLink>}
      />

      {resumes.length === 0 ? (
        <EmptyState
          title="No resume yet"
          description="Upload a PDF or DOCX, paste your resume text, or enter it manually. Fit analysis needs at least one resume."
          action={<ButtonLink href="/resumes/new">Add your resume</ButtonLink>}
        />
      ) : (
        <>
          <ul className="grid gap-3 md:grid-cols-2">
            {resumes.map((r) => (
              <li key={r.id}>
                <Link href={`/resumes/${r.id}`} className="block rounded-lg border border-line bg-surface p-4 hover:border-accent">
                  <div className="flex flex-wrap items-center gap-2">
                    <span className="font-medium">{r.title}</span>
                    {r.is_primary && <Badge tone="accent">Primary</Badge>}
                    <Badge tone={STATUS[r.parse_status]!.tone}>{STATUS[r.parse_status]!.label}</Badge>
                  </div>
                  <p className="mt-1 text-sm text-muted">
                    {r.employment_count} roles · {r.skill_count} skills · updated {formatDate(new Date(r.updated_at).toISOString().slice(0, 10))}
                  </p>
                </Link>
              </li>
            ))}
          </ul>

          <Card className="mt-8">
            <CardHeader title="Resume versions" description="Create a tailored copy, edit the wording and order of your bullets, then print or save it as PDF. Each application records which version you used." />
            <NewVersionForm
              action={createVersionAction}
              resumes={resumes}
              jobs={jobs.map((j) => ({ id: j.id, label: `${j.title} — ${j.company}` }))}
              defaultJobId={job}
            />
            {versions.length === 0 ? (
              <p className="mt-4 text-sm text-muted">No versions yet.</p>
            ) : (
              <div className="mt-5 relative overflow-x-auto" tabIndex={0} role="region" aria-label="Resume versions">
                <table className="w-full text-left text-sm">
                  <thead className="border-b border-line text-xs uppercase tracking-wide text-muted">
                    <tr><th className="py-2 pr-3 font-medium">Version</th><th className="py-2 pr-3 font-medium">Tailored for</th><th className="py-2 pr-3 font-medium">Used in</th><th className="py-2 font-medium">Updated</th></tr>
                  </thead>
                  <tbody className="divide-y divide-line">
                    {versions.map((v) => (
                      <tr key={v.id}>
                        <td className="py-2 pr-3"><Link href={`/resumes/versions/${v.id}`} className="font-medium text-accent hover:underline">{v.name}</Link></td>
                        <td className="py-2 pr-3 text-muted">{v.job_label ?? "General"}</td>
                        <td className="py-2 pr-3 tabular-nums">{v.application_count} application{v.application_count === 1 ? "" : "s"}</td>
                        <td className="py-2 text-muted">{formatDate(new Date(v.updated_at).toISOString().slice(0, 10))}</td>
                      </tr>
                    ))}
                  </tbody>
                </table>
              </div>
            )}
          </Card>
        </>
      )}
    </>
  );
}
