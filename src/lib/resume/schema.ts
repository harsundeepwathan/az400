import { z } from "zod";

const text = (max: number) => z.string().trim().max(max);
const dateText = z
  .string()
  .trim()
  .regex(/^(\d{4}(-\d{2})?)?$/, "Use YYYY or YYYY-MM")
  .default("");
const lines = (maxItems: number, maxLen: number) => z.array(text(maxLen)).max(maxItems).default([]);
const optionalId = z.string().uuid().optional();

export const contactSchema = z.object({
  name: text(200).default(""),
  email: text(320).default(""),
  phone: text(50).default(""),
  location: text(200).default(""),
  links: lines(10, 500),
});

export const employmentSchema = z.object({
  id: optionalId,
  employer: text(300).default(""),
  title: text(300).default(""),
  location: text(200).default(""),
  start_date: dateText,
  end_date: dateText,
  is_current: z.boolean().default(false),
  responsibilities: lines(40, 1000),
  achievements: lines(40, 1000),
});

export const educationSchema = z.object({
  id: optionalId,
  institution: text(300).default(""),
  qualification: text(300).default(""),
  field_of_study: text(300).default(""),
  start_date: dateText,
  end_date: dateText,
  notes: text(2000).default(""),
});

export const certificationSchema = z.object({
  id: optionalId,
  name: text(300).min(1),
  issuer: text(300).default(""),
  issued_on: dateText,
  expires_on: dateText,
});

export const skillSchema = z.object({
  id: optionalId,
  name: text(100).min(1),
  category: text(100).default(""),
});

export const projectSchema = z.object({
  id: optionalId,
  name: text(300).min(1),
  description: text(4000).default(""),
  skills: lines(30, 100),
  url: text(500).default(""),
});

export const resumeDraftSchema = z.object({
  title: text(200).min(1, "Give this resume a name"),
  contact: contactSchema,
  summary: text(5000).default(""),
  employment: z.array(employmentSchema).max(40).default([]),
  education: z.array(educationSchema).max(20).default([]),
  certifications: z.array(certificationSchema).max(50).default([]),
  skills: z.array(skillSchema).max(200).default([]),
  projects: z.array(projectSchema).max(30).default([]),
  languages: lines(20, 100),
});

export type ResumeDraft = z.infer<typeof resumeDraftSchema>;
export type EmploymentDraft = z.infer<typeof employmentSchema>;

export type ParseStatus = "parsed" | "partial" | "unreadable" | "manual";

export type ParseResult = {
  status: ParseStatus;
  draft: ResumeDraft;
  warnings: string[];
};

export function emptyDraft(title = "My resume"): ResumeDraft {
  return {
    title,
    contact: { name: "", email: "", phone: "", location: "", links: [] },
    summary: "",
    employment: [],
    education: [],
    certifications: [],
    skills: [],
    projects: [],
    languages: [],
  };
}
