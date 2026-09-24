import { readFileSync } from "node:fs";
import path from "node:path";
import { describe, expect, it } from "vitest";
import { validateResumeFile, MAX_RESUME_BYTES } from "@/lib/resume/file";
import { normaliseDate, parseResumeText } from "@/lib/resume/parse";

const sample = readFileSync(path.join(__dirname, "..", "fixtures", "sample-resume.txt"), "utf8");

describe("parseResumeText", () => {
  it("extracts structured sections from a well-formed resume", () => {
    const { status, draft, warnings } = parseResumeText(sample);
    expect(status).toBe("parsed");
    expect(warnings).toEqual([]);
    expect(draft.contact.email).toBe("alex.morgan@example.com");
    expect(draft.employment).toHaveLength(2);
    expect(draft.employment[0]).toMatchObject({ title: "Senior Platform Engineer", employer: "Northwind Payments", start_date: "2021-03", is_current: true });
    expect(draft.employment[1]).toMatchObject({ start_date: "2017-01", end_date: "2021-02", is_current: false });
    expect(draft.skills.map((s) => s.name)).toContain("Kubernetes");
    expect(draft.certifications).toHaveLength(2);
    expect(draft.languages).toEqual(["English", "Spanish"]);
  });

  it("never invents content: every achievement exists verbatim in the source", () => {
    const { draft } = parseResumeText(sample);
    for (const e of draft.employment) for (const line of [...e.achievements, ...e.responsibilities]) expect(sample).toContain(line);
  });

  it("puts bullets with metrics in achievements and others in responsibilities", () => {
    const { draft } = parseResumeText(sample);
    expect(draft.employment[0]!.achievements.some((a) => a.includes("28%"))).toBe(true);
    expect(draft.employment[0]!.responsibilities.some((r) => r.includes("Mentored four engineers"))).toBe(true);
  });

  it("falls back to 'unreadable' for scanned or near-empty text", () => {
    expect(parseResumeText("").status).toBe("unreadable");
    expect(parseResumeText("   \n  12 34 \n").status).toBe("unreadable");
    const garbage = "%%%% ### 1234 5678 //// ;;;; ".repeat(20);
    const result = parseResumeText(garbage);
    expect(result.status).toBe("unreadable");
    expect(result.warnings[0]).toMatch(/Paste your resume text/);
    expect(result.draft.employment).toEqual([]);
  });

  it("returns a partial result with a warning when no headings are recognised", () => {
    const text = "Jordan Lee\njordan@example.com\n" + "I have worked on many interesting things across several companies over the years. ".repeat(5);
    const result = parseResumeText(text);
    expect(result.status).toBe("partial");
    expect(result.draft.contact.email).toBe("jordan@example.com");
    expect(result.warnings.join(" ")).toMatch(/No section headings/);
  });
});

describe("normaliseDate", () => {
  it.each([
    ["Mar 2021", "2021-03", false],
    ["September 2019", "2019-09", false],
    ["03/2020", "2020-03", false],
    ["2018", "2018", false],
    ["Present", "", true],
  ])("%s → %s", (input, date, current) => {
    expect(normaliseDate(input)).toEqual({ date, current });
  });
});

describe("validateResumeFile", () => {
  const pdf = new Uint8Array([0x25, 0x50, 0x44, 0x46, 0x2d]);
  const zip = new Uint8Array([0x50, 0x4b, 0x03, 0x04, 0x00]);
  it("accepts PDF and DOCX with matching magic bytes", () => {
    expect(validateResumeFile("cv.pdf", 1000, pdf)).toEqual({ ok: true, kind: "pdf" });
    expect(validateResumeFile("CV.DOCX", 1000, zip)).toEqual({ ok: true, kind: "docx" });
  });
  it("rejects spoofed, oversized, empty and unsupported files", () => {
    expect(validateResumeFile("cv.pdf", 1000, zip).ok).toBe(false);
    expect(validateResumeFile("cv.docx", 1000, pdf).ok).toBe(false);
    expect(validateResumeFile("cv.pdf", MAX_RESUME_BYTES + 1, pdf).ok).toBe(false);
    expect(validateResumeFile("cv.pdf", 0, pdf).ok).toBe(false);
    expect(validateResumeFile("cv.exe", 1000, pdf).ok).toBe(false);
    expect(validateResumeFile("cv.doc", 1000, pdf)).toMatchObject({ ok: false, error: expect.stringMatching(/Legacy/) });
  });
});

describe("wrapped bullets", () => {
  it("joins a lowercase continuation line to the previous bullet", () => {
    const text = `${sample.split("Experience")[0]}Experience\nEngineer | Acme | London\nJan 2020 – Present\n• Designed a deployment pipeline that\nshipped every service automatically\n• Reduced costs by 20%\n\nSkills\nGo, Python`;
    const { draft } = parseResumeText(text);
    expect(draft.employment[0]!.responsibilities).toEqual(["Designed a deployment pipeline that shipped every service automatically"]);
    expect(draft.employment[0]!.achievements).toEqual(["Reduced costs by 20%"]);
  });
});
