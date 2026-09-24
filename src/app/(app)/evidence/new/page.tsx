import type { Metadata } from "next";
import { EvidenceForm } from "@/components/evidence/evidence-form";
import { PageHeader } from "@/components/ui/display";
import { requireOnboardedUser } from "@/lib/session";
import { saveEvidenceAction } from "../actions";

export const metadata: Metadata = { title: "Add evidence" };

export default async function NewEvidencePage() {
  await requireOnboardedUser();
  return (
    <>
      <PageHeader title="Add evidence" description="Describe one concrete example using Situation, Action and Result. Be specific and only include what you can back up." />
      <EvidenceForm action={saveEvidenceAction.bind(null, null)} />
    </>
  );
}
