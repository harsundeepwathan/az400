import type { Metadata } from "next";
import { ButtonLink } from "@/components/ui/button";
import { Alert, Badge, Card, CardHeader, EmptyState, PageHeader } from "@/components/ui/display";
import { computeAnalytics, MIN_SAMPLE, type GroupRow, type Rate } from "@/lib/analytics";
import { loadAnalyticsData } from "@/lib/data/insights";
import { formatDate } from "@/lib/dates";
import { STAGE_LABELS } from "@/lib/domain";
import { todayForUser } from "@/lib/server-date";
import { requireOnboardedUser } from "@/lib/session";

export const metadata: Metadata = { title: "Analytics" };

function RateValue({ rate, label }: { rate: Rate; label: string }) {
  return (
    <div className="rounded-lg border border-line bg-surface p-4">
      <p className="text-sm text-muted">{label}</p>
      <p className="mt-1 text-2xl font-semibold tabular-nums">
        {rate.percent === null ? "—" : `${rate.percent}%`}
      </p>
      <p className="text-xs tabular-nums text-muted">{rate.numerator} of {rate.denominator}</p>
      {rate.sample === "insufficient" && <Badge tone="warning" className="mt-2">Too few to conclude</Badge>}
      {rate.sample === "early" && <Badge tone="neutral" className="mt-2">Early signal</Badge>}
      {rate.sample === "none" && <Badge tone="neutral" className="mt-2">No data yet</Badge>}
    </div>
  );
}

function RateCell({ rate }: { rate: Rate }) {
  if (rate.percent === null) return <span className="text-muted">—</span>;
  return (
    <span className="tabular-nums">
      {rate.numerator}/{rate.denominator} <span className="text-muted">({rate.percent}%)</span>
      {rate.sample === "insufficient" && <span className="ml-1 text-xs text-warning" title="Fewer than 5 applications">*</span>}
    </span>
  );
}

function GroupTable({ rows, label }: { rows: GroupRow[]; label: string }) {
  if (rows.length === 0) return <p className="text-sm text-muted">No submitted applications yet.</p>;
  return (
    <div className="relative overflow-x-auto" tabIndex={0} role="region" aria-label={`${label} breakdown`}>
      <table className="w-full min-w-[420px] text-left text-sm">
        <thead className="border-b border-line text-xs uppercase tracking-wide text-muted">
          <tr><th className="py-2 pr-3 font-medium">{label}</th><th className="py-2 pr-3 font-medium">Applied</th><th className="py-2 pr-3 font-medium">Reached screen</th><th className="py-2 font-medium">Reached interview</th></tr>
        </thead>
        <tbody className="divide-y divide-line">
          {rows.map((r) => (
            <tr key={r.key}>
              <td className="py-2 pr-3">{r.key}</td>
              <td className="py-2 pr-3 tabular-nums">{r.applied}</td>
              <td className="py-2 pr-3"><RateCell rate={r.screens} /></td>
              <td className="py-2"><RateCell rate={r.interviews} /></td>
            </tr>
          ))}
        </tbody>
      </table>
    </div>
  );
}

function BarList({ items }: { items: Array<{ label: string; value: number }> }) {
  const max = Math.max(1, ...items.map((i) => i.value));
  return (
    <ul className="space-y-2">
      {items.map((i) => (
        <li key={i.label} className="grid grid-cols-[8.5rem_1fr_2rem] items-center gap-2 text-sm" title={`${i.label}: ${i.value}`}>
          <span className="truncate text-muted">{i.label}</span>
          <span className="h-3 rounded-r bg-subtle" aria-hidden>
            <span className="block h-3 rounded-r bg-accent" style={{ width: `${(i.value / max) * 100}%` }} />
          </span>
          <span className="text-right tabular-nums">{i.value}</span>
        </li>
      ))}
    </ul>
  );
}

export default async function AnalyticsPage() {
  const { user } = await requireOnboardedUser();
  const [{ apps, targetRoles }, today] = await Promise.all([loadAnalyticsData(user.id), todayForUser()]);
  if (apps.length === 0) {
    return (
      <>
        <PageHeader title="Analytics" />
        <EmptyState title="Nothing to measure yet" description="Analytics are calculated from the stage changes you record on applications. Start tracking an application to see your pipeline here." action={<ButtonLink href="/applications">Open applications</ButtonLink>} />
      </>
    );
  }
  const a = computeAnalytics(apps, targetRoles, today);
  const maxWeek = Math.max(1, ...a.byWeek.map((w) => w.count));
  const small = a.totals.submitted < MIN_SAMPLE;

  return (
    <>
      <PageHeader title="Analytics" description="Calculated from your recorded stage changes. Counts are always shown next to percentages." />
      {small && (
        <Alert tone="warning" className="mb-4" title="Small sample">
          You have {a.totals.submitted} submitted application{a.totals.submitted === 1 ? "" : "s"}. Rates based on fewer than {MIN_SAMPLE} are shown but should not guide decisions yet.
        </Alert>
      )}

      <section aria-labelledby="conv-h" className="mb-6">
        <h2 id="conv-h" className="mb-3 text-sm font-semibold uppercase tracking-wide text-muted">Conversion</h2>
        <div className="grid grid-cols-2 gap-3 lg:grid-cols-4">
          <RateValue rate={a.conversion.response} label="Response rate" />
          <RateValue rate={a.conversion.applicationToScreen} label="Application → screen" />
          <RateValue rate={a.conversion.screenToInterview} label="Screen → interview" />
          <RateValue rate={a.conversion.interviewToOffer} label="Interview → offer" />
        </div>
      </section>

      <div className="grid gap-4 lg:grid-cols-2">
        <Card>
          <CardHeader title="Applications by week" description="Last 12 weeks, by date first moved to Applied." />
          <div className="flex h-40 items-end gap-1.5" role="img" aria-label={`Applications per week: ${a.byWeek.map((w) => `week of ${formatDate(w.week)}: ${w.count}`).join("; ")}`}>
            {a.byWeek.map((w) => (
              <div key={w.week} className="group relative flex h-full flex-1 flex-col justify-end" title={`Week of ${formatDate(w.week)}: ${w.count}`}>
                <div className="rounded-t bg-accent group-hover:bg-accent-strong" style={{ height: `${(w.count / maxWeek) * 100}%`, minHeight: w.count ? 4 : 0 }} />
              </div>
            ))}
          </div>
          <div className="mt-1 flex justify-between border-t border-line pt-1 text-xs text-muted">
            <span>{formatDate(a.byWeek[0]!.week)}</span><span>This week</span>
          </div>
          <details className="mt-3 text-sm">
            <summary className="cursor-pointer text-muted">Show as table</summary>
            <table className="mt-2 w-full text-left"><tbody>{a.byWeek.map((w) => <tr key={w.week}><td className="py-0.5">Week of {formatDate(w.week)}</td><td className="text-right tabular-nums">{w.count}</td></tr>)}</tbody></table>
          </details>
        </Card>

        <Card>
          <CardHeader title="Current pipeline" description={`${a.totals.tracked} tracked applications.`} />
          <BarList items={a.pipeline.filter((p) => p.count > 0).map((p) => ({ label: STAGE_LABELS[p.stage], value: p.count }))} />
        </Card>

        <Card><CardHeader title="By target role" /><GroupTable rows={a.byRole} label="Role" /></Card>
        <Card><CardHeader title="By job source" /><GroupTable rows={a.bySource} label="Source" /></Card>
        <Card><CardHeader title="Resume-version performance" /><GroupTable rows={a.byResumeVersion} label="Version" /></Card>

        <Card>
          <CardHeader title="Average time in stage" description="Days between recorded stage changes. Current, unfinished stages are excluded." />
          <table className="w-full text-left text-sm">
            <tbody className="divide-y divide-line">
              {a.timeInStage.filter((s) => s.samples > 0).map((s) => (
                <tr key={s.stage}>
                  <td className="py-1.5">{STAGE_LABELS[s.stage]}</td>
                  <td className="py-1.5 text-right tabular-nums">{s.days} days <span className="text-xs text-muted">(n={s.samples})</span></td>
                </tr>
              ))}
            </tbody>
          </table>
          {a.timeInStage.every((s) => s.samples === 0) && <p className="text-sm text-muted">Not enough stage changes yet.</p>}
        </Card>

        <Card>
          <CardHeader title="Rejection reasons" />
          {a.rejectionReasons.length === 0 ? <p className="text-sm text-muted">No rejections recorded.</p> : <BarList items={a.rejectionReasons.map((r) => ({ label: r.reason, value: r.count }))} />}
        </Card>
      </div>
      <p className="mt-4 text-xs text-muted">* Fewer than {MIN_SAMPLE} applications in this group: too few to draw conclusions.</p>
    </>
  );
}
