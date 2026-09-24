import type { Metadata } from "next";
import { notFound } from "next/navigation";
import { PrintButton } from "@/components/print-button";
import { requireUser } from "@/lib/auth";
import { getResume, getVersion } from "@/lib/data/resumes";
import { uuidSchema } from "@/lib/validation";

export const metadata: Metadata = { title: "Print resume" };

export default async function PrintVersionPage({ params }: { params: Promise<{ id: string }> }) {
  const user = await requireUser();
  const { id } = await params;
  if (!uuidSchema.safeParse(id).success) notFound();
  const version = await getVersion(user.id, id);
  if (!version) notFound();
  const base = await getResume(user.id, version.resume_id);
  const contact = base?.contact;

  return (
    <div className="min-h-screen bg-white">
      <div className="no-print flex items-center justify-between border-b border-line bg-canvas px-4 py-3">
        <p className="text-sm text-muted">Use your browser&apos;s print dialog and choose “Save as PDF”.</p>
        <PrintButton />
      </div>
      <article className="mx-auto max-w-[800px] px-8 py-10 text-[13px] leading-relaxed text-black">
        <header className="border-b border-gray-300 pb-3">
          <h1 className="text-2xl font-semibold">{contact?.name || "Your name"}</h1>
          <p className="mt-1 text-gray-700">
            {[contact?.location, contact?.email, contact?.phone, ...(contact?.links ?? [])].filter(Boolean).join(" · ")}
          </p>
        </header>
        {version.summary && (
          <section className="mt-4">
            <h2 className="text-xs font-semibold uppercase tracking-wider text-gray-600">Summary</h2>
            <p className="mt-1">{version.summary}</p>
          </section>
        )}
        {version.content.employment.length > 0 && (
          <section className="mt-4">
            <h2 className="text-xs font-semibold uppercase tracking-wider text-gray-600">Experience</h2>
            {version.content.employment.map((e) => (
              <div key={e.employment_id} className="mt-3 break-inside-avoid">
                <div className="flex flex-wrap justify-between gap-2">
                  <h3 className="font-semibold">{e.heading}</h3>
                  <span className="text-gray-600">{e.dates}</span>
                </div>
                <ul className="mt-1 list-disc pl-5">{e.bullets.map((b, i) => <li key={i}>{b}</li>)}</ul>
              </div>
            ))}
          </section>
        )}
        {base && base.education.length > 0 && (
          <section className="mt-4">
            <h2 className="text-xs font-semibold uppercase tracking-wider text-gray-600">Education</h2>
            {base.education.map((ed, i) => (
              <p key={i} className="mt-1">{[ed.qualification, ed.field_of_study, ed.institution].filter(Boolean).join(", ")}{ed.end_date ? ` (${ed.end_date})` : ""}</p>
            ))}
          </section>
        )}
        {base && base.certifications.length > 0 && (
          <section className="mt-4">
            <h2 className="text-xs font-semibold uppercase tracking-wider text-gray-600">Certifications</h2>
            <p className="mt-1">{base.certifications.map((c) => [c.name, c.issuer, c.issued_on].filter(Boolean).join(", ")).join(" · ")}</p>
          </section>
        )}
        {version.content.skills.length > 0 && (
          <section className="mt-4">
            <h2 className="text-xs font-semibold uppercase tracking-wider text-gray-600">Skills</h2>
            <p className="mt-1">{version.content.skills.join(" · ")}</p>
          </section>
        )}
        {base && base.languages.length > 0 && (
          <section className="mt-4">
            <h2 className="text-xs font-semibold uppercase tracking-wider text-gray-600">Languages</h2>
            <p className="mt-1">{base.languages.join(", ")}</p>
          </section>
        )}
      </article>
    </div>
  );
}
