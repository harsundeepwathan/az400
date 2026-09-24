import { emptyDraft, type EmploymentDraft, type ParseResult, type ResumeDraft } from "./schema";

/**
 * Deterministic, offline resume parser. It never invents content: every value
 * in the draft is copied from the input text. Anything it cannot place
 * confidently is reported as a warning so the user can fix it in the preview.
 */

type Section = "header" | "summary" | "experience" | "education" | "skills" | "certifications" | "projects" | "languages" | "achievements" | "other";

const HEADINGS: Array<[Section, RegExp]> = [
  ["summary", /^(professional |career |personal )?(summary|profile|about( me)?|objective|overview)$/],
  ["experience", /^((work|professional|relevant|employment|career) )?(experience|history|employment)( history)?$/],
  ["education", /^(education|academic (background|history)|education (and|&) training)$/],
  ["skills", /^((technical|core|key|professional) )?(skills|competencies|technologies|expertise)( (and|&) (tools|technologies))?$/],
  ["certifications", /^((licen[cs]es|licensing) (and|&) )?(certifications?|certificates|licen[cs]es)$/],
  ["projects", /^((selected|key|personal|notable) )?projects$/],
  ["languages", /^languages?$/],
  ["achievements", /^((key|selected|notable) )?(achievements|accomplishments|awards)( (and|&) awards)?$/],
  ["other", /^(interests|hobbies|references|volunteering|volunteer experience|publications)$/],
];

const MONTHS: Record<string, string> = {
  jan: "01", feb: "02", mar: "03", apr: "04", may: "05", jun: "06",
  jul: "07", aug: "08", sep: "09", sept: "09", oct: "10", nov: "11", dec: "12",
};

const DATE_TOKEN = String.raw`(?:(?:jan|feb|mar|apr|may|jun|jul|aug|sep|sept|oct|nov|dec)[a-z]*\.?\s+\d{4}|\d{1,2}[/.]\d{4}|\d{4})`;
const DATE_RANGE = new RegExp(
  String.raw`(${DATE_TOKEN})\s*(?:-|–|—|to|until)\s*(${DATE_TOKEN}|present|current|now|today)`,
  "i",
);
const SINGLE_YEAR = /\b(19|20)\d{2}\b/;
const BULLET = /^\s*(?:[-*•●▪◦‣∙·]|\d+[.)])\s+/;
const METRIC = /(\d+(?:[.,]\d+)?\s*(?:%|percent|x\b|k\b|m\b|million|billion)|[$£€]\s?\d|\b\d{2,}\b)/i;
const TITLE_WORDS = /\b(engineer|developer|manager|analyst|lead|director|designer|consultant|specialist|officer|head|architect|scientist|coordinator|administrator|intern|associate|vp|vice president|president|executive|assistant|advisor|owner|founder|programmer|technician|accountant|nurse|teacher|product|recruiter|supervisor|strategist|editor|writer|researcher)\b/i;
const INSTITUTION_WORDS = /\b(university|college|school|institute|academy|polytechnic)\b/i;
const DEGREE_WORDS = /\b(bachelor|master|b\.?sc|m\.?sc|b\.?a\.?|m\.?a\.?|mba|ph\.?d|diploma|degree|associate of|b\.?eng|m\.?eng|gcse|a-levels?|hnd)\b/i;

export function normaliseDate(token: string | undefined): { date: string; current: boolean } {
  if (!token) return { date: "", current: false };
  const t = token.trim().toLowerCase().replace(/\.$/, "");
  if (/^(present|current|now|today)$/.test(t)) return { date: "", current: true };
  const monthYear = t.match(/^([a-z]+)\.?\s+(\d{4})$/);
  if (monthYear) {
    const month = MONTHS[monthYear[1]!.slice(0, 3)];
    return { date: month ? `${monthYear[2]}-${month}` : monthYear[2]!, current: false };
  }
  const numeric = t.match(/^(\d{1,2})[/.](\d{4})$/);
  if (numeric) {
    const m = Number(numeric[1]);
    return { date: m >= 1 && m <= 12 ? `${numeric[2]}-${String(m).padStart(2, "0")}` : numeric[2]!, current: false };
  }
  const year = t.match(/^(\d{4})$/);
  return { date: year ? year[1]! : "", current: false };
}

function detectHeading(line: string): Section | null {
  const cleaned = line
    .trim()
    .replace(/[:：]\s*$/, "")
    .replace(/\s+/g, " ")
    .toLowerCase();
  if (cleaned.length === 0 || cleaned.length > 45) return null;
  for (const [section, re] of HEADINGS) if (re.test(cleaned)) return section;
  return null;
}

function stripBullet(line: string): string {
  return line.replace(BULLET, "").trim();
}

function splitList(value: string): string[] {
  return value
    .split(/[,;|•●▪·\n]|\s{3,}/)
    .map((s) => stripBullet(s).replace(/\.$/, "").trim())
    .filter((s) => s.length > 0 && s.length <= 60);
}

function dedupe(values: string[]): string[] {
  const seen = new Set<string>();
  return values.filter((v) => {
    const key = v.toLowerCase();
    if (seen.has(key)) return false;
    seen.add(key);
    return true;
  });
}

function extractContact(lines: string[], draft: ResumeDraft) {
  const all = lines.join("\n");
  draft.contact.email = all.match(/[A-Z0-9._%+-]+@[A-Z0-9.-]+\.[A-Z]{2,}/i)?.[0] ?? "";
  draft.contact.phone = all.match(/(?:\+?\d[\d ()-]{7,}\d)/)?.[0]?.trim() ?? "";
  draft.contact.links = dedupe(all.match(/\b(?:https?:\/\/|www\.|linkedin\.com\/|github\.com\/)[^\s,|]+/gi) ?? []).slice(0, 10);
  const nameLine = lines.find((l) => l.trim().length > 0);
  if (nameLine && /^[\p{L}'’.-]+(?:\s+[\p{L}'’.-]+){1,3}$/u.test(nameLine.trim()) && !detectHeading(nameLine)) {
    draft.contact.name = nameLine.trim();
  }
  const locationLine = lines
    .slice(0, 6)
    .flatMap((l) => l.split(/[|•·]/))
    .map((s) => s.trim())
    .find((s) => /^[\p{L} .'-]+,\s*[\p{L} .'-]+$/u.test(s) && s !== draft.contact.name);
  draft.contact.location = locationLine ?? "";
}

function assignHeaderParts(entry: EmploymentDraft, text: string) {
  const parts = text
    .split(/\s+(?:\||—|–|-|@|at)\s+|\s*[|—–]\s*|,\s+/i)
    .map((p) => p.trim())
    .filter(Boolean);
  for (const part of parts) {
    if (!entry.title && TITLE_WORDS.test(part)) entry.title = part;
    else if (!entry.employer) entry.employer = part;
    else if (!entry.location) entry.location = part;
  }
}

function parseExperience(lines: string[], warnings: string[]): EmploymentDraft[] {
  const entries: EmploymentDraft[] = [];
  let pendingHeader: string[] = [];
  let current: EmploymentDraft | null = null;
  let lastBulletOwner: EmploymentDraft | null = null;
  let lastPushed = "";

  const pushLine = (entry: EmploymentDraft, line: string) => {
    if (METRIC.test(line)) entry.achievements.push(line);
    else entry.responsibilities.push(line);
    lastPushed = line;
  };

  for (const raw of lines) {
    const line = raw.trim();
    if (!line) continue;
    const isBullet = BULLET.test(raw);
    const range = !isBullet ? line.match(DATE_RANGE) : null;

    if (range) {
      const start = normaliseDate(range[1]);
      const end = normaliseDate(range[2]);
      current = {
        employer: "",
        title: "",
        location: "",
        start_date: start.date,
        end_date: end.date,
        is_current: end.current,
        responsibilities: [],
        achievements: [],
      };
      const rest = line.replace(range[0], "").replace(/[\s|,—–-]+$/, "").replace(/^[\s|,—–-]+/, "").trim();
      const headerText = [...pendingHeader, rest].filter(Boolean).join(" | ");
      assignHeaderParts(current, headerText);
      pendingHeader = [];
      entries.push(current);
      continue;
    }

    if (isBullet) {
      if (current) pushLine(current, stripBullet(line));
      lastBulletOwner = current;
      continue;
    }

    // PDF extraction wraps long bullets; a lowercase continuation line belongs to the previous bullet.
    if (current && lastBulletOwner === current && /^[a-z(]/.test(line)) {
      const list = current.achievements.at(-1) === lastPushed ? current.achievements : current.responsibilities;
      const idx = list.lastIndexOf(lastPushed);
      if (idx >= 0) {
        list[idx] = `${lastPushed} ${line}`;
        lastPushed = list[idx]!;
        continue;
      }
    }
    lastBulletOwner = null;

    // A short non-bullet line directly after a header usually names the employer
    // or title that was not on the date line.
    if (current && (!current.employer || !current.title) && line.length <= 80 && current.responsibilities.length === 0 && current.achievements.length === 0) {
      assignHeaderParts(current, line);
      continue;
    }

    if (line.length <= 80 && !/[.!?]$/.test(line)) {
      // Possibly the header of the next role (title / employer before the date line).
      pendingHeader.push(line);
      if (pendingHeader.length > 2) {
        const overflow = pendingHeader.shift()!;
        if (current) pushLine(current, overflow);
      }
      continue;
    }

    if (current) pushLine(current, line);
  }

  if (current && pendingHeader.length > 0) for (const l of pendingHeader) pushLine(current, l);
  if (entries.length === 0 && lines.some((l) => l.trim())) {
    warnings.push("We could not identify individual roles in your experience section. Please add them in the editor.");
  }
  for (const e of entries) {
    if (!e.employer || !e.title) {
      warnings.push(`Check the employer and job title for the role starting ${e.start_date || "(unknown date)"}.`);
    }
  }
  return entries;
}

function parseEducation(lines: string[]) {
  const entries: ResumeDraft["education"] = [];
  let current: ResumeDraft["education"][number] | null = null;
  for (const raw of lines) {
    const line = stripBullet(raw);
    if (!line) continue;
    const range = line.match(DATE_RANGE);
    const year = line.match(SINGLE_YEAR);
    const hasInstitution = INSTITUTION_WORDS.test(line);
    const hasDegree = DEGREE_WORDS.test(line);
    if (hasInstitution || hasDegree || !current) {
      const startsNew = !current || (hasInstitution && current.institution) || (hasDegree && current.qualification);
      if (startsNew) {
        current = { institution: "", qualification: "", field_of_study: "", start_date: "", end_date: "", notes: "" };
        entries.push(current);
      }
    }
    if (!current) continue;
    const textPart = line.replace(range?.[0] ?? "", "").replace(/[\s|,—–-]+$/, "").trim();
    for (const part of textPart.split(/\s*[|—–]\s*|,\s+(?=[A-Z])/).map((p) => p.trim().replace(/[,;]$/, "")).filter(Boolean)) {
      if (!current.institution && INSTITUTION_WORDS.test(part)) current.institution = part.replace(SINGLE_YEAR, "").replace(/[\s,;–—-]+$/, "");
      else if (!current.qualification && DEGREE_WORDS.test(part)) {
        const [qual, field] = part.split(/\s+in\s+/i);
        current.qualification = (qual ?? part).replace(SINGLE_YEAR, "").trim();
        if (field) current.field_of_study = field.replace(SINGLE_YEAR, "").trim();
      } else if (!SINGLE_YEAR.test(part) || part.length > 12) {
        current.notes = [current.notes, part].filter(Boolean).join("; ");
      }
    }
    if (range) {
      current.start_date = normaliseDate(range[1]).date;
      current.end_date = normaliseDate(range[2]).date;
    } else if (year && !current.end_date) {
      current.end_date = year[0];
    }
  }
  return entries.filter((e) => e.institution || e.qualification);
}

function parseCertifications(lines: string[]) {
  return lines
    .map(stripBullet)
    .filter(Boolean)
    .map((line) => {
      const year = line.match(SINGLE_YEAR)?.[0] ?? "";
      const withoutYear = line.replace(/\(?\b(19|20)\d{2}\b\)?/, "").replace(/[\s,–—-]+$/, "").trim();
      const [name, issuer] = withoutYear.split(/,\s+|\s+\|\s+/);
      return { name: (name ?? withoutYear).slice(0, 300), issuer: issuer ?? "", issued_on: year, expires_on: "" };
    })
    .filter((c) => c.name.length > 0);
}

function parseSkills(lines: string[]) {
  const skills: ResumeDraft["skills"] = [];
  for (const raw of lines) {
    const line = stripBullet(raw);
    if (!line) continue;
    const categorised = line.match(/^([^:]{2,40}):\s*(.+)$/);
    const category = categorised ? categorised[1]!.trim() : "";
    for (const name of splitList(categorised ? categorised[2]! : line)) skills.push({ name, category });
  }
  const seen = new Set<string>();
  return skills.filter((s) => (seen.has(s.name.toLowerCase()) ? false : (seen.add(s.name.toLowerCase()), true)));
}

function parseProjects(lines: string[]) {
  const projects: ResumeDraft["projects"] = [];
  let current: ResumeDraft["projects"][number] | null = null;
  for (const raw of lines) {
    const line = raw.trim();
    if (!line) continue;
    if (!BULLET.test(raw) && line.length <= 100 && !/[.!?]$/.test(line)) {
      current = { name: line, description: "", skills: [], url: line.match(/https?:\/\/\S+/)?.[0] ?? "" };
      projects.push(current);
    } else if (current) {
      current.description = [current.description, stripBullet(line)].filter(Boolean).join("\n");
    }
  }
  return projects;
}

export function parseResumeText(input: string, title = "My resume"): ParseResult {
  const draft = emptyDraft(title);
  const warnings: string[] = [];
  const text = input.replace(/\r\n?/g, "\n").replace(/ /g, " ").replace(/\t/g, "  ");
  const letters = (text.match(/\p{L}/gu) ?? []).length;

  if (text.trim().length < 150 || letters / Math.max(text.length, 1) < 0.4) {
    return {
      status: "unreadable",
      draft,
      warnings: [
        "We could not read enough text from this resume. Scanned or image-only files are not supported yet. Paste your resume text instead, or fill in the fields manually.",
      ],
    };
  }

  const buckets: Record<Section, string[]> = {
    header: [], summary: [], experience: [], education: [], skills: [],
    certifications: [], projects: [], languages: [], achievements: [], other: [],
  };
  let section: Section = "header";
  let headingsFound = 0;
  for (const line of text.split("\n")) {
    const heading = detectHeading(line);
    if (heading) {
      section = heading;
      headingsFound++;
      continue;
    }
    buckets[section].push(line);
  }

  extractContact(buckets.header.length ? buckets.header : text.split("\n").slice(0, 8), draft);

  if (headingsFound === 0) {
    warnings.push("No section headings were recognised. Review every field carefully; you may prefer to enter details manually.");
    draft.summary = "";
    return { status: "partial", draft, warnings };
  }

  // Header lines after the name/contact line that are prose are treated as the summary
  // only if there is no explicit summary section.
  const summaryLines = buckets.summary.length
    ? buckets.summary
    : buckets.header.filter((l) => l.trim().length > 80 && !/@/.test(l));
  draft.summary = summaryLines.map((l) => stripBullet(l)).filter(Boolean).join(" ").slice(0, 5000);
  draft.employment = parseExperience(buckets.experience, warnings);
  draft.education = parseEducation(buckets.education);
  draft.certifications = parseCertifications(buckets.certifications);
  draft.skills = parseSkills(buckets.skills);
  draft.projects = parseProjects(buckets.projects);
  draft.languages = dedupe(buckets.languages.flatMap((l) => splitList(l)));

  if (buckets.achievements.some((l) => l.trim())) {
    warnings.push("Your resume has a separate achievements section. Add those achievements to the right role, or save them as evidence items.");
  }
  if (draft.employment.length === 0) warnings.push("No employment history was found. Add your roles in the editor.");
  if (draft.skills.length === 0) warnings.push("No skills section was found.");

  const status = draft.employment.length > 0 && draft.skills.length > 0 ? "parsed" : "partial";
  return { status, draft, warnings };
}
