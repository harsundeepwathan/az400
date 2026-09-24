import { z } from "zod";
import {
  CONFIDENCE_LEVELS, CONTACT_ROLES, EMPLOYMENT_TYPES, INTERVIEW_KINDS, VERIFICATION_STATUSES, WORKPLACE_PREFERENCES, WORKPLACE_TYPES,
} from "./domain";

const isoDate = z.string().regex(/^\d{4}-\d{2}-\d{2}$/, "Use a valid date");
const optionalDate = isoDate.nullable();
const money = z.number().int("Enter a whole number").min(0, "Must be positive").max(100_000_000).nullable();
const currency = z.string().regex(/^[A-Z]{3}$/, "Use a 3-letter currency code, e.g. USD");

export const credentialsSchema = z.object({
  email: z.string().trim().toLowerCase().email("Enter a valid email address").max(320),
  password: z.string().min(10, "Use at least 10 characters").max(200),
});

export const profileSchema = z.object({
  full_name: z.string().min(1, "Enter your name").max(200),
  current_title: z.string().max(200),
  target_roles: z.array(z.string().max(200)).min(1, "Add at least one target job title").max(10),
  preferred_locations: z.array(z.string().max(200)).max(10),
  workplace_preference: z.enum(WORKPLACE_PREFERENCES),
  target_salary: money,
  salary_currency: currency,
  employment_types: z.array(z.enum(EMPLOYMENT_TYPES)).min(1, "Choose at least one employment type"),
  willing_to_relocate: z.boolean(),
  work_authorization_notes: z.string().max(2000),
  search_started_on: optionalDate,
});

export const settingsSchema = z.object({
  weekly_application_goal: z.number().int().min(0).max(100),
  follow_up_after_days: z.number().int().min(1).max(60),
  ai_assistance_enabled: z.boolean(),
});

const url = z
  .string()
  .max(2000)
  .refine((v) => v === "" || /^https?:\/\//i.test(v), "Use a full http(s) link");

export const jobSchema = z
  .object({
    title: z.string().min(1, "Enter the job title").max(300),
    company: z.string().min(1, "Enter the company").max(300),
    url,
    location: z.string().max(300),
    workplace_type: z.enum(WORKPLACE_TYPES),
    salary_min: money,
    salary_max: money,
    currency,
    description: z.string().max(60000, "The description is too long (60,000 characters max)"),
    source: z.string().max(200),
    discovered_on: isoDate,
    closes_on: optionalDate,
    contact_name: z.string().max(200),
    contact_email: z.string().max(320).refine((v) => v === "" || z.string().email().safeParse(v).success, "Enter a valid email"),
    notes: z.string().max(10000),
  })
  .refine((j) => j.salary_min === null || j.salary_max === null || j.salary_min <= j.salary_max, {
    message: "Minimum salary must not exceed maximum",
    path: ["salary_max"],
  });

export const evidenceSchema = z.object({
  title: z.string().min(1, "Give this evidence a title").max(300),
  organization: z.string().max(300),
  situation: z.string().max(4000),
  action: z.string().max(4000),
  result: z.string().max(4000),
  skills: z.array(z.string().max(100)).max(30),
  metric: z.string().max(300),
  confidence: z.enum(CONFIDENCE_LEVELS),
  verification_status: z.enum(VERIFICATION_STATUSES),
  notes: z.string().max(4000),
});

export const applicationDetailsSchema = z.object({
  resume_version_id: z.string().uuid().nullable(),
  applied_on: optionalDate,
  next_action: z.string().max(300),
  next_action_on: optionalDate,
  follow_up_on: optionalDate,
  salary_expectation: z.string().max(200),
  rejection_reason: z.string().max(500),
  offer_details: z.string().max(4000),
  offer_deadline: optionalDate,
  notes: z.string().max(20000),
});

export const contactSchema = z.object({
  name: z.string().min(1, "Enter a name").max(200),
  role: z.enum(CONTACT_ROLES),
  email: z.string().max(320).refine((v) => v === "" || z.string().email().safeParse(v).success, "Enter a valid email"),
  phone: z.string().max(50),
  profile_url: url,
  notes: z.string().max(2000),
});

export const interviewSchema = z.object({
  date: isoDate,
  time: z.string().regex(/^\d{2}:\d{2}$/, "Use a valid time"),
  kind: z.enum(INTERVIEW_KINDS),
  interviewers: z.string().max(500),
  location: z.string().max(500),
  notes: z.string().max(10000),
});

export const taskSchema = z.object({
  title: z.string().min(1, "Describe the reminder").max(300),
  due_on: isoDate,
  application_id: z.string().uuid().nullable(),
});

export const uuidSchema = z.string().uuid();
