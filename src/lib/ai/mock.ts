import { heuristicFit } from "../fit/heuristic";
import { keywords } from "../fit/keywords";
import { extractRequirements } from "../fit/requirements";
import type { FitDraft, FitInput } from "../fit/types";
import type { AIProvider } from "./provider";
import type { MaterialsDraft, MaterialsInput, PrepDraft, PrepInput, RequirementsDraft } from "./schemas";

function withArticle(noun: string): string {
  return `${/^[aeiou]/i.test(noun) ? "an" : "a"} ${noun}`;
}

/**
 * Deterministic, offline provider. Output is assembled from templates and the
 * user's own words, so it is predictable in tests and never fabricates facts.
 * The UI labels every result it produces as demo output.
 */
export class MockProvider implements AIProvider {
  readonly name = "mock" as const;
  readonly model = "deterministic-templates";

  async extractRequirements(description: string): Promise<RequirementsDraft> {
    return { requirements: extractRequirements(description) };
  }

  async analyzeFit(input: FitInput): Promise<FitDraft> {
    return heuristicFit(input);
  }

  async applicationMaterials(input: MaterialsInput): Promise<MaterialsDraft> {
    const { job, profile, supported, bullets } = input;
    const jobTokens = keywords(`${job.description} ${job.requirements.map((r) => r.text).join(" ")}`);

    const relevant = bullets
      .map((b) => ({ bullet: b, overlap: [...keywords(b.text)].filter((t) => jobTokens.has(t)) }))
      .filter((x) => x.overlap.length > 0)
      .sort((a, b) => b.overlap.length - a.overlap.length);

    const strengths = supported.slice(0, 3).map((s) => s.source_label);
    const years = profile.years_experience ? `${Math.floor(profile.years_experience)}+ years of experience` : "experience";
    const role = profile.current_title || "Professional";
    const summary =
      `${role} with ${years}` +
      (strengths.length ? `, including ${strengths.join("; ")}.` : ".") +
      ` Interested in the ${job.title} role at ${job.company}.`;

    const bullet_suggestions = relevant.slice(0, 5).map(({ bullet, overlap }) => ({
      bullet_id: bullet.id,
      suggested: bullet.text,
      rationale: `Place this near the top of “${bullet.role}”: it shows ${overlap.slice(0, 3).join(", ")}, which this job asks for. Wording unchanged.`,
    }));

    const profileTokens = keywords(input.sources.map((s) => `${s.label} ${s.text}`).join(" "));
    const truthfulKeywords = [...jobTokens].filter((t) => profileTokens.has(t)).slice(0, 15);

    const evidenceLines = relevant.slice(0, 3).map(({ bullet }) => `- ${bullet.text}`);
    const cover_letter = [
      "Dear Hiring Manager,",
      "",
      `I am applying for the ${job.title} position at ${job.company}. I currently work as ${withArticle(role)} and the requirements in your description line up with work I have already done.`,
      "",
      evidenceLines.length ? "Relevant examples from my experience:" : "",
      ...evidenceLines,
      "",
      input.gaps.length
        ? `I have noted that the role also asks for ${input.gaps.slice(0, 2).join(" and ")}; I would welcome the chance to discuss how I would approach this.`
        : "",
      "",
      `Thank you for considering my application. I would be glad to talk about how I could contribute to ${job.company}.`,
      "",
      "Kind regards,",
    ]
      .filter((line, i, arr) => !(line === "" && arr[i - 1] === ""))
      .join("\n");

    const outreach_message = `Hello, I have applied for the ${job.title} role at ${job.company}. I am currently ${withArticle(role)}` +
      (strengths[0] ? ` and my background includes ${strengths[0]}.` : ".") +
      " Would you be open to a short conversation about the role?";

    return { summary, bullet_suggestions, keywords: truthfulKeywords, cover_letter, outreach_message };
  }

  async interviewPrep(input: PrepInput): Promise<PrepDraft> {
    const { job, evidence, gaps } = input;
    const must = job.requirements.filter((r) => r.kind === "must");
    const technical_questions = must.slice(0, 6).map((r) => ({
      question: `Walk me through a time you applied this in practice: “${r.text}”. What was your specific contribution?`,
      requirement: r.text,
    }));

    const text = job.description.toLowerCase();
    const behavioural = [
      "Tell me about a project you are proud of and the part you personally played.",
      "Describe a time you disagreed with a colleague or stakeholder. How did you resolve it?",
      "Tell me about a mistake you made at work and what you changed afterwards.",
    ];
    if (/lead|mentor|manag/.test(text)) behavioural.push("Describe how you have supported or developed other people on your team.");
    if (/stakeholder|cross-functional|partner/.test(text)) behavioural.push("Give an example of aligning several stakeholders with competing priorities.");
    if (/ambigu|fast-paced|startup|change/.test(text)) behavioural.push("Tell me about a time you had to deliver with unclear requirements.");
    if (/incident|on-call|reliab/.test(text)) behavioural.push("Walk me through a production incident you handled, from detection to follow-up.");

    const company_questions = [
      `Why do you want to work at ${job.company}, based on what you have read about them?`,
      `What interests you about the ${job.title} role specifically?`,
    ];
    const aboutSentence = job.description
      .split(/(?<=[.!?])\s+|\n/)
      .find((s) => new RegExp(`\\b(we|our|${job.company.replace(/[.*+?^${}()|[\]\\]/g, "\\$&")})\\b`, "i").test(s) && s.length > 40);
    if (aboutSentence) company_questions.push(`The job description says: “${aboutSentence.trim().slice(0, 200)}”. How would your experience help with that?`);

    const star_stories = evidence
      .filter((e) => e.verified)
      .slice(0, 4)
      .map((e) => ({
        evidence_id: e.id,
        prompt: `Use for questions about ${e.title.toLowerCase()}.`,
        situation: e.situation,
        action: e.action,
        result: e.result,
      }));

    const questions_to_ask = [
      "What would success look like in the first six months in this role?",
      "What are the biggest challenges the team is facing right now?",
      "How does the team decide what to work on and how is progress measured?",
      "What does the rest of the interview process look like?",
    ];

    const risk_areas = gaps.slice(0, 5).map((g) => ({
      area: g,
      preparation: "Be honest about your level here. Prepare a related example and explain how you would close the gap.",
    }));

    return {
      technical_questions,
      behavioural_questions: behavioural.slice(0, 7),
      company_questions,
      star_stories,
      questions_to_ask,
      risk_areas,
    };
  }
}
