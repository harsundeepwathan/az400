import type { SourceItem } from "./types";

export type CareerProfile = {
  resume: { id: string; summary: string } | null;
  employment: Array<{
    id: string;
    employer: string;
    title: string;
    start_date: string;
    end_date: string;
    is_current: boolean;
    responsibilities: string[];
    achievements: string[];
  }>;
  education: Array<{ id: string; institution: string; qualification: string; field_of_study: string }>;
  certifications: Array<{ id: string; name: string; issuer: string }>;
  skills: Array<{ id: string; name: string; category: string }>;
  projects: Array<{ id: string; name: string; description: string; skills: string[] }>;
  evidence: Array<{
    id: string;
    title: string;
    organization: string;
    situation: string;
    action: string;
    result: string;
    skills: string[];
    metric: string;
    verification_status: string;
  }>;
};

/**
 * Builds the catalogue of citable facts. Contact details are deliberately
 * excluded: they are never needed for matching and are never sent to an AI
 * provider. Rejected evidence is excluded entirely.
 */
export function buildSources(profile: CareerProfile): SourceItem[] {
  const sources: SourceItem[] = [];
  for (const e of profile.employment) {
    sources.push({
      id: e.id,
      type: "employment",
      label: [e.title, e.employer].filter(Boolean).join(" at ") || "Untitled role",
      text: [...e.responsibilities, ...e.achievements].join(" \n"),
      verified: true,
    });
  }
  for (const s of profile.skills) sources.push({ id: s.id, type: "skill", label: s.name, text: s.category, verified: true });
  for (const c of profile.certifications) {
    sources.push({ id: c.id, type: "certification", label: c.name, text: c.issuer, verified: true });
  }
  for (const ed of profile.education) {
    sources.push({
      id: ed.id,
      type: "education",
      label: [ed.qualification, ed.institution].filter(Boolean).join(", ") || "Education",
      text: ed.field_of_study,
      verified: true,
    });
  }
  for (const p of profile.projects) {
    sources.push({ id: p.id, type: "project", label: p.name, text: `${p.description} ${p.skills.join(", ")}`, verified: true });
  }
  for (const ev of profile.evidence) {
    if (ev.verification_status === "rejected") continue;
    sources.push({
      id: ev.id,
      type: "evidence",
      label: ev.title,
      text: [ev.organization, ev.situation, ev.action, ev.result, ev.metric, ev.skills.join(", ")].filter(Boolean).join(" \n"),
      verified: ev.verification_status === "verified",
    });
  }
  if (profile.resume?.summary) {
    sources.push({ id: profile.resume.id, type: "summary", label: "Professional summary", text: profile.resume.summary, verified: false });
  }
  return sources;
}

function toMonthIndex(date: string, isEnd: boolean): number | null {
  const m = date.match(/^(\d{4})(?:-(\d{2}))?$/);
  if (!m) return null;
  const month = m[2] ? Number(m[2]) - 1 : isEnd ? 11 : 0;
  return Number(m[1]) * 12 + month;
}

/** Total years covered by employment dates, with overlapping roles merged. */
export function yearsOfExperience(employment: CareerProfile["employment"], today = new Date()): number | null {
  const nowIndex = today.getUTCFullYear() * 12 + today.getUTCMonth();
  const intervals: Array<[number, number]> = [];
  for (const e of employment) {
    const start = toMonthIndex(e.start_date, false);
    const end = e.is_current ? nowIndex : toMonthIndex(e.end_date, true);
    if (start === null || end === null || end < start) continue;
    intervals.push([start, end]);
  }
  if (intervals.length === 0) return null;
  intervals.sort((a, b) => a[0] - b[0]);
  let total = 0;
  let [curStart, curEnd] = intervals[0]!;
  for (const [s, e] of intervals.slice(1)) {
    if (s <= curEnd + 1) curEnd = Math.max(curEnd, e);
    else {
      total += curEnd - curStart + 1;
      [curStart, curEnd] = [s, e];
    }
  }
  total += curEnd - curStart + 1;
  return Math.round((total / 12) * 10) / 10;
}

/** All profile text, used to check generated content for unsupported claims. */
export function corpusText(sources: SourceItem[]): string {
  return sources.map((s) => `${s.label}\n${s.text}`).join("\n");
}
