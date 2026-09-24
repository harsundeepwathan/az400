// Shared domain constants. Safe to import from client and server code.

export const STAGES = [
  "interested",
  "preparing",
  "applied",
  "recruiter_screen",
  "interview",
  "final_interview",
  "background_checks",
  "offer",
  "rejected",
  "withdrawn",
  "archived",
] as const;
export type Stage = (typeof STAGES)[number];

export const STAGE_LABELS: Record<Stage, string> = {
  interested: "Interested",
  preparing: "Preparing",
  applied: "Applied",
  recruiter_screen: "Recruiter screen",
  interview: "Interview",
  final_interview: "Final interview",
  background_checks: "Background checks",
  offer: "Offer",
  rejected: "Rejected",
  withdrawn: "Withdrawn",
  archived: "Archived",
};

/** Forward-progress stages in pipeline order. Terminal outcomes are excluded. */
export const PROGRESS_STAGES = [
  "interested",
  "preparing",
  "applied",
  "recruiter_screen",
  "interview",
  "final_interview",
  "background_checks",
  "offer",
] as const satisfies readonly Stage[];

export const CLOSED_STAGES: readonly Stage[] = ["rejected", "withdrawn", "archived"];
export const ACTIVE_STAGES: readonly Stage[] = [
  "applied",
  "recruiter_screen",
  "interview",
  "final_interview",
  "background_checks",
  "offer",
];
export const INTERVIEW_STAGES: readonly Stage[] = ["recruiter_screen", "interview", "final_interview"];

export function progressIndex(stage: Stage): number {
  return (PROGRESS_STAGES as readonly Stage[]).indexOf(stage);
}

export const RECOMMENDATIONS = ["strong_apply", "apply", "stretch", "low_value"] as const;
export type Recommendation = (typeof RECOMMENDATIONS)[number];
export const RECOMMENDATION_LABELS: Record<Recommendation, string> = {
  strong_apply: "Strong apply",
  apply: "Apply",
  stretch: "Stretch",
  low_value: "Low-value application",
};

export const MATCH_TYPES = ["strong", "transferable", "unclear", "missing"] as const;
export type MatchType = (typeof MATCH_TYPES)[number];

export const SOURCE_TYPES = ["skill", "employment", "certification", "education", "project", "evidence", "summary"] as const;
export type SourceType = (typeof SOURCE_TYPES)[number];

export const WORKPLACE_TYPES = ["remote", "hybrid", "onsite", "unknown"] as const;
export type WorkplaceType = (typeof WORKPLACE_TYPES)[number];
export const WORKPLACE_PREFERENCES = ["remote", "hybrid", "onsite", "flexible"] as const;

export const EMPLOYMENT_TYPES = ["full_time", "part_time", "contract", "temporary", "internship"] as const;
export const EMPLOYMENT_TYPE_LABELS: Record<(typeof EMPLOYMENT_TYPES)[number], string> = {
  full_time: "Full-time",
  part_time: "Part-time",
  contract: "Contract",
  temporary: "Temporary",
  internship: "Internship",
};

export const TASK_KINDS = [
  "follow_up",
  "interview_prep",
  "application_deadline",
  "recruiter_response",
  "offer_deadline",
  "custom",
] as const;
export type TaskKind = (typeof TASK_KINDS)[number];
export const TASK_KIND_LABELS: Record<TaskKind, string> = {
  follow_up: "Follow-up",
  interview_prep: "Interview prep",
  application_deadline: "Application deadline",
  recruiter_response: "Recruiter response",
  offer_deadline: "Offer deadline",
  custom: "Task",
};

export const INTERVIEW_KINDS = ["recruiter_screen", "technical", "behavioural", "panel", "final", "other"] as const;
export const INTERVIEW_KIND_LABELS: Record<(typeof INTERVIEW_KINDS)[number], string> = {
  recruiter_screen: "Recruiter screen",
  technical: "Technical",
  behavioural: "Behavioural",
  panel: "Panel",
  final: "Final",
  other: "Other",
};

export const CONTACT_ROLES = ["recruiter", "hiring_manager", "interviewer", "referral", "other"] as const;
export const CONTACT_ROLE_LABELS: Record<(typeof CONTACT_ROLES)[number], string> = {
  recruiter: "Recruiter",
  hiring_manager: "Hiring manager",
  interviewer: "Interviewer",
  referral: "Referral",
  other: "Other",
};

export const VERIFICATION_STATUSES = ["verified", "unverified", "rejected"] as const;
export const CONFIDENCE_LEVELS = ["high", "medium", "low"] as const;
export const EVIDENCE_SOURCES = ["resume", "user_entered", "interview_reflection"] as const;
export const EVIDENCE_SOURCE_LABELS: Record<(typeof EVIDENCE_SOURCES)[number], string> = {
  resume: "Resume",
  user_entered: "Added by you",
  interview_reflection: "Interview reflection",
};
