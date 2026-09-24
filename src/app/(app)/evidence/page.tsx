import type { Metadata } from "next";
import Link from "next/link";
import { ActionButton } from "@/components/action-button";
import { ButtonLink } from "@/components/ui/button";
import { Badge, EmptyState, PageHeader } from "@/components/ui/display";
import { listEvidence } from "@/lib/data/evidence";
import { EVIDENCE_SOURCE_LABELS } from "@/lib/domain";
import { requireOnboardedUser } from "@/lib/session";
import { importEvidenceAction } from "../resumes/actions";
import { setEvidenceStatusAction } from "./actions";

export const metadata: Metadata = { title: "Evidence vault" };

const STATUS_TONE = { verified: "success", unverified: "warning", rejected: "neutral" } as const;
const STATUS_LABEL = { verified: "Verified", unverified: "Needs review", rejected: "Rejected" } as const;

export default async function EvidencePage() {
  const { user } = await requireOnboardedUser();
  const items = await listEvidence(user.id);
  const unverified = items.filter((i) => i.verification_status === "unverified").length;

  return (
    <>
      <PageHeader
        title="Career evidence vault"
        description="Concrete, verifiable examples of your work. Fit analysis cites these, and only verified items are used for interview STAR stories."
        actions={
          <>
            <ActionButton action={importEvidenceAction} pendingText="Importing…">Import from resume</ActionButton>
            <ButtonLink href="/evidence/new">Add evidence</ButtonLink>
          </>
        }
      />
      {items.length === 0 ? (
        <EmptyState
          title="Your vault is empty"
          description="Import the achievements from your primary resume as drafts, or add an example yourself. Nothing is marked verified until you confirm it."
          action={<ButtonLink href="/evidence/new">Add evidence</ButtonLink>}
        />
      ) : (
        <>
          {unverified > 0 && (
            <p className="mb-4 text-sm text-muted">{unverified} item{unverified === 1 ? "" : "s"} need your review. Add the situation and result, then mark as verified.</p>
          )}
          <ul className="grid gap-3 md:grid-cols-2">
            {items.map((item) => (
              <li key={item.id} className="flex flex-col rounded-lg border border-line bg-surface p-4">
                <div className="flex flex-wrap items-center gap-2">
                  <Badge tone={STATUS_TONE[item.verification_status]}>{STATUS_LABEL[item.verification_status]}</Badge>
                  <Badge>{EVIDENCE_SOURCE_LABELS[item.source]}</Badge>
                  <Badge>Confidence: {item.confidence}</Badge>
                </div>
                <Link href={`/evidence/${item.id}`} className="mt-2 font-medium hover:underline">{item.title}</Link>
                {item.organization && <p className="text-sm text-muted">{item.organization}</p>}
                <dl className="mt-2 space-y-1 text-sm">
                  {item.situation && <div><dt className="inline font-medium">Situation: </dt><dd className="inline text-muted">{item.situation}</dd></div>}
                  {item.action && <div><dt className="inline font-medium">Action: </dt><dd className="inline text-muted">{item.action}</dd></div>}
                  {item.result && <div><dt className="inline font-medium">Result: </dt><dd className="inline text-muted">{item.result}</dd></div>}
                  {item.metric && <div><dt className="inline font-medium">Metric: </dt><dd className="inline text-muted">{item.metric}</dd></div>}
                </dl>
                {item.skills.length > 0 && <p className="mt-2 text-xs text-muted">{item.skills.join(" · ")}</p>}
                <div className="mt-auto flex flex-wrap gap-2 pt-3">
                  {item.verification_status !== "verified" && (
                    <ActionButton action={setEvidenceStatusAction.bind(null, item.id, "verified")}>Mark verified</ActionButton>
                  )}
                  <ButtonLink href={`/evidence/${item.id}`} size="sm" variant="ghost">Edit</ButtonLink>
                </div>
              </li>
            ))}
          </ul>
        </>
      )}
    </>
  );
}
