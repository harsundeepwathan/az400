/**
 * Deterministic requirement extraction from a pasted job description.
 * Results are editable by the user; nothing here is sent anywhere.
 */

export type ExtractedRequirement = { text: string; kind: "must" | "nice" };

type Mode = "must" | "nice" | "ignore" | "none";

const NICE_HEADING = /\b(nice[- ]to[- ]haves?|preferred|bonus( points)?|desirable|ideally|would be (great|a plus)|pluses|extra credit)\b/i;
const MUST_HEADING = /\b(requirements|qualifications|what you('ll| will)? (need|bring)|must[- ]haves?|about you|who you are|you (have|bring|are)|skills( (and|&) experience)?|essential|minimum|experience( required)?|what we('re| are) looking for)\b/i;
const IGNORE_HEADING = /\b(responsibilities|what you('ll| will) do|day[- ]to[- ]day|about (us|the (company|role|team|job))|benefits|perks|we offer|what we offer|compensation|salary|how to apply|the role|role overview|our (values|mission)|equal opportunit(y|ies)|diversity)\b/i;
const NICE_MARKER = /\b(preferred|a plus|is a plus|nice to have|bonus|ideally|desirable|advantageous|beneficial)\b/i;
const REQUIREMENT_SIGNAL = /\b(experience|knowledge|proficien|familiar|degree|years?|skills?|ability|understanding|expertise|background|certif|fluent|track record|comfortable)\b/i;
const BULLET = /^\s*(?:[-*•●▪◦‣∙·]|\d+[.)])\s+/;

function headingMode(line: string): Mode | null {
  const t = line.trim().replace(/[:：]\s*$/, "");
  const looksLikeHeading = t.length > 0 && t.length <= 60 && !BULLET.test(line) && (/[:：]\s*$/.test(line.trim()) || !/[.!?]$/.test(t)) && t.split(/\s+/).length <= 8;
  if (!looksLikeHeading) return null;
  if (NICE_HEADING.test(t)) return "nice";
  if (IGNORE_HEADING.test(t)) return "ignore";
  if (MUST_HEADING.test(t)) return "must";
  return null;
}

function clean(line: string): string {
  return line.replace(BULLET, "").replace(/\s+/g, " ").replace(/[;,.]\s*$/, "").trim();
}

export function extractRequirements(description: string, limit = 25): ExtractedRequirement[] {
  const lines = description.replace(/\r\n?/g, "\n").split("\n");
  const found: ExtractedRequirement[] = [];
  let mode: Mode = "none";
  let sawSection = false;

  for (const raw of lines) {
    if (!raw.trim()) continue;
    const heading = headingMode(raw);
    if (heading) {
      mode = heading;
      sawSection = true;
      continue;
    }
    if (mode === "must" || mode === "nice") {
      const text = clean(raw);
      if (text.length < 4 || text.length > 400) continue;
      found.push({ text, kind: mode === "nice" || NICE_MARKER.test(text) ? "nice" : "must" });
    }
  }

  if (!sawSection || found.length === 0) {
    // No recognisable sections: fall back to bullet or sentence lines that read like requirements.
    for (const raw of lines) {
      const text = clean(raw);
      if (text.length < 8 || text.length > 300) continue;
      if (!BULLET.test(raw) && !REQUIREMENT_SIGNAL.test(text)) continue;
      if (!REQUIREMENT_SIGNAL.test(text) && !NICE_MARKER.test(text)) continue;
      found.push({ text, kind: NICE_MARKER.test(text) ? "nice" : "must" });
    }
  }

  const seen = new Set<string>();
  return found
    .filter((r) => {
      const key = r.text.toLowerCase();
      if (seen.has(key)) return false;
      seen.add(key);
      return true;
    })
    .slice(0, limit);
}

/** Phrases in a job description that look like attempts to instruct an AI system. */
const INJECTION_PATTERNS = [
  /ignore (all |any )?(previous|prior|above|earlier) (instructions|prompts|messages)/i,
  /disregard (the |all )?(previous|prior|above|system)/i,
  /you are (now )?(chatgpt|an ai|a language model|the assistant)/i,
  /\bsystem prompt\b/i,
  /(rate|score|mark) (this|the) (candidate|applicant|resume) (as )?(100|highly|a perfect)/i,
  /<\/?(system|assistant|instructions?)>/i,
  /\bnew instructions\b/i,
];

export function detectInjectionSignals(text: string): boolean {
  return INJECTION_PATTERNS.some((re) => re.test(text));
}
