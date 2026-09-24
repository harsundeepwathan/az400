import Link from "next/link";
import { redirect } from "next/navigation";
import { getCurrentUser } from "@/lib/auth";
import { ButtonLink } from "@/components/ui/button";

const POINTS = [
  {
    title: "Know which jobs are worth it",
    body: "Compare each job description against your resume and evidence vault. Every match cites the fact it relies on; anything without a source is marked “Needs confirmation”.",
  },
  {
    title: "Know what to do today",
    body: "A short daily list built from your real deadlines, follow-ups and interviews — no more than three priorities.",
  },
  {
    title: "Know what is working",
    body: "Conversion rates by role, source and resume version, with raw counts and clear warnings when the sample is too small to mean anything.",
  },
];

export default async function LandingPage() {
  if (await getCurrentUser()) redirect("/today");
  return (
    <div className="min-h-screen">
      <header className="mx-auto flex max-w-5xl items-center justify-between px-4 py-5 sm:px-6">
        <span className="text-lg font-semibold">JobPilot</span>
        <nav aria-label="Account" className="flex gap-2">
          <ButtonLink href="/sign-in" variant="ghost">Sign in</ButtonLink>
          <ButtonLink href="/sign-up">Create account</ButtonLink>
        </nav>
      </header>
      <main className="mx-auto max-w-5xl px-4 pb-20 pt-10 sm:px-6 sm:pt-16">
        <p className="text-sm font-medium text-accent">Your personal job-hunt operating system</p>
        <h1 className="mt-3 max-w-3xl text-3xl font-semibold leading-tight sm:text-5xl">
          Know which jobs are worth applying for, what to do next, and what is actually working.
        </h1>
        <p className="mt-5 max-w-2xl text-base text-muted sm:text-lg">
          Upload your resume once, save the jobs you find, and get honest, evidence-backed guidance. JobPilot never invents experience,
          never promises applicant-tracking-system results, and keeps your data private.
        </p>
        <div className="mt-8 flex flex-wrap gap-3">
          <ButtonLink href="/sign-up">Get started</ButtonLink>
          <ButtonLink href="/sign-in" variant="secondary">I already have an account</ButtonLink>
        </div>

        <section aria-labelledby="how" className="mt-20">
          <h2 id="how" className="sr-only">How it helps</h2>
          <ul className="grid gap-6 sm:grid-cols-3">
            {POINTS.map((p) => (
              <li key={p.title} className="border-t-2 border-accent pt-4">
                <h3 className="font-semibold">{p.title}</h3>
                <p className="mt-2 text-sm text-muted">{p.body}</p>
              </li>
            ))}
          </ul>
        </section>

        <section className="mt-16 rounded-lg border border-line bg-surface p-6">
          <h2 className="font-semibold">Private by default</h2>
          <p className="mt-2 text-sm text-muted">
            Every record is isolated to your account with database row-level security. You can export everything or delete your account
            at any time from Settings. Resume and job text is treated as data, never as instructions, when AI assistance is used.
          </p>
          <p className="mt-3 text-sm">
            <Link href="/sign-up" className="font-medium text-accent hover:underline">Create your workspace →</Link>
          </p>
        </section>
      </main>
    </div>
  );
}
