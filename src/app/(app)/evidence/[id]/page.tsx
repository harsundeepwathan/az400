import type { Metadata } from "next";
import { notFound } from "next/navigation";
import { ActionButton } from "@/components/action-button";
import { EvidenceForm } from "@/components/evidence/evidence-form";
import { PageHeader } from "@/components/ui/display";
import { getEvidence } from "@/lib/data/evidence";
import { EVIDENCE_SOURCE_LABELS } from "@/lib/domain";
import { requireOnboardedUser } from "@/lib/session";
import { uuidSchema } from "@/lib/validation";
import { deleteEvidenceAction, saveEvidenceAction } from "../actions";

export const metadata: Metadata = { title: "Edit evidence" };

export default async function EvidenceItemPage({ params }: { params: Promise<{ id: string }> }) {
  const { user } = await requireOnboardedUser();
  const { id } = await params;
  if (!uuidSchema.safeParse(id).success) notFound();
  const item = await getEvidence(user.id, id);
  if (!item) notFound();
  return (
    <>
      <PageHeader
        title="Edit evidence"
        description={`Source: ${EVIDENCE_SOURCE_LABELS[item.source]}`}
        actions={<ActionButton action={deleteEvidenceAction.bind(null, id)} variant="danger" confirm="Delete this evidence item?">Delete</ActionButton>}
      />
      <EvidenceForm action={saveEvidenceAction.bind(null, id)} initial={item} />
    </>
  );
}
