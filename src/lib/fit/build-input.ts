import type { Profile } from "../data/profile";
import type { Job } from "../data/jobs";
import { buildSources, yearsOfExperience, type CareerProfile } from "./corpus";
import type { FitInput, Requirement } from "./types";

/** Assembles the minimal data needed for a fit analysis. No contact details are included. */
export function buildFitInput(job: Job, requirements: Requirement[], profile: Profile, targetRoles: string[], career: CareerProfile): FitInput {
  return {
    job: {
      title: job.title,
      company: job.company,
      location: job.location,
      workplace_type: job.workplace_type,
      salary_max: job.salary_max,
      currency: job.currency,
      description: job.description,
      requirements,
    },
    profile: {
      current_title: profile.current_title || career.employment[0]?.title || "",
      target_titles: targetRoles,
      preferred_locations: profile.preferred_locations,
      workplace_preference: profile.workplace_preference,
      willing_to_relocate: profile.willing_to_relocate,
      work_authorization_notes: profile.work_authorization_notes,
      target_salary: profile.target_salary,
      salary_currency: profile.salary_currency,
      years_experience: yearsOfExperience(career.employment),
    },
    sources: buildSources(career),
  };
}
