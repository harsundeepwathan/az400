import type { Metadata } from "next";
import { NewResumeFlow } from "@/components/resume/new-resume-flow";
import { PageHeader } from "@/components/ui/display";
import { requireOnboardedUser } from "@/lib/session";
import { createResumeAction, parseResumeAction } from "../actions";

export const metadata: Metadata = { title: "Add resume" };

export default async function NewResumePage() {
  await requireOnboardedUser();
  return (
    <>
      <PageHeader title="Add a resume" description="JobPilot extracts your resume into a structured career profile. You review and edit everything before it is saved." />
      <NewResumeFlow parse={parseResumeAction} save={createResumeAction} />
    </>
  );
}
