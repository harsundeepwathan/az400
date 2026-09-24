import { describe, expect, it } from "vitest";
import { detectUnsupportedClaims } from "@/lib/claims";
import { checkMaterials, checkPrep, groundRequirements } from "@/lib/ai/postprocess";
import type { MaterialsInput, PrepInput } from "@/lib/ai/schemas";

const profile = "Led migration of 40 services to Kubernetes, cutting cost by 28%. Built Terraform modules. Python scripting.";
const job = "We need Kubernetes, Terraform, Rust and Snowflake experience.";

describe("detectUnsupportedClaims", () => {
  it("accepts claims that are backed by the profile", () => {
    expect(detectUnsupportedClaims("I migrated 40 services to Kubernetes and cut cost by 28%.", profile, job)).toEqual([]);
  });
  it("flags fabricated metrics", () => {
    const claims = detectUnsupportedClaims("I cut cost by 45% across 40 services.", profile, job);
    expect(claims.map((c) => c.claim)).toEqual(["45%"]);
  });
  it("flags job-description skills that the profile does not contain", () => {
    const claims = detectUnsupportedClaims("Deep experience with Rust and Snowflake.", profile, job);
    expect(claims.map((c) => c.claim).sort()).toEqual(["rust", "snowflake"]);
  });
  it("ignores years and allowed context such as the company name", () => {
    expect(detectUnsupportedClaims("Since 2019 I have admired Snowflake.", profile, job, ["Snowflake Inc"])).toEqual([]);
  });
});

const materialsInput: MaterialsInput = {
  job: { title: "Platform Engineer", company: "Acme", description: job, requirements: [{ id: "r1", text: "Kubernetes", kind: "must" }] },
  profile: { current_title: "Platform Engineer", years_experience: 8, summary: "" },
  supported: [],
  gaps: [],
  bullets: [{ id: "e1:a0", employment_id: "e1", role: "Engineer at Northwind", text: "Led migration of 40 services to Kubernetes, cutting cost by 28%" }],
  sources: [{ id: "e1", type: "employment", label: "Engineer at Northwind", text: profile, verified: true }],
};

describe("checkMaterials", () => {
  const draft = {
    summary: "Platform engineer with Kubernetes and Rust expertise.",
    bullet_suggestions: [
      { bullet_id: "e1:a0", suggested: "Led Kubernetes migration of 40 services, cutting cost by 50%", rationale: "" },
      { bullet_id: "invented", suggested: "Built a Snowflake warehouse", rationale: "" },
    ],
    keywords: ["Kubernetes", "Rust", "Terraform"],
    cover_letter: "Dear team, I migrated 40 services to Kubernetes.",
    outreach_message: "Hello!",
  };

  it("drops suggestions for bullets that do not exist", () => {
    const { materials } = checkMaterials(draft, materialsInput);
    expect(materials.bullet_suggestions.map((s) => s.bullet_id)).toEqual(["e1:a0"]);
    expect(materials.bullet_suggestions[0]!.original).toContain("28%");
  });
  it("flags a rewrite that changes the facts of its original bullet", () => {
    const { materials } = checkMaterials(draft, materialsInput);
    expect(materials.bullet_suggestions[0]!.unsupported.map((c) => c.claim)).toContain("50%");
  });
  it("keeps only keywords the profile supports and reports unsupported sections", () => {
    const { materials, warnings } = checkMaterials(draft, materialsInput);
    expect(materials.keywords).toEqual(["Kubernetes", "Terraform"]);
    expect(warnings).toEqual([{ section: "Tailored summary", claims: [expect.objectContaining({ claim: "rust" })] }]);
  });
});

describe("checkPrep", () => {
  const input: PrepInput = {
    job: { title: "t", company: "c", description: "", requirements: [] },
    supported: [],
    gaps: [],
    evidence: [
      { id: "ev1", title: "Verified", situation: "S", action: "A", result: "R", verified: true },
      { id: "ev2", title: "Unverified", situation: "", action: "x", result: "", verified: false },
    ],
    interview_kind: null,
  };
  it("keeps STAR stories only for verified evidence and restores the original facts", () => {
    const { prep, warnings } = checkPrep(
      {
        technical_questions: [], behavioural_questions: [], company_questions: [], questions_to_ask: [], risk_areas: [],
        star_stories: [
          { evidence_id: "ev1", prompt: "p", situation: "embellished", action: "embellished", result: "tripled revenue" },
          { evidence_id: "ev2", prompt: "p", situation: "", action: "", result: "" },
          { evidence_id: "ghost", prompt: "p", situation: "", action: "", result: "" },
        ],
      },
      input,
    );
    expect(prep.star_stories).toEqual([{ evidence_id: "ev1", prompt: "p", situation: "S", action: "A", result: "R" }]);
    expect(warnings).toHaveLength(2);
  });
});

describe("groundRequirements", () => {
  it("removes requirements that are not in the job description", () => {
    const jd = "Requirements: 5+ years of Go. Experience with Kubernetes clusters.";
    const grounded = groundRequirements(
      { requirements: [{ text: "5+ years of Go", kind: "must" }, { text: "Kubernetes clusters experience", kind: "must" }, { text: "PhD in physics", kind: "must" }] },
      jd,
    );
    expect(grounded.requirements.map((r) => r.text)).toEqual(["5+ years of Go", "Kubernetes clusters experience"]);
  });
});
