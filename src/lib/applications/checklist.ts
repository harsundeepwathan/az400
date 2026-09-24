export type ChecklistItem = { label: string; done: boolean };

export const DEFAULT_CHECKLIST: ChecklistItem[] = [
  { label: "Review the fit analysis and answer open questions", done: false },
  { label: "Select the evidence to emphasise", done: false },
  { label: "Choose or create a tailored resume version", done: false },
  { label: "Review the cover letter draft for accuracy", done: false },
  { label: "Submit the application", done: false },
  { label: "Record the application date and set a follow-up", done: false },
];
