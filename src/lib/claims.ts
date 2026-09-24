import { keywords } from "./fit/keywords";

export type UnsupportedClaim = { claim: string; reason: string };

const NUMBER = /(?:[$£€]\s?)?\d+(?:[.,]\d+)?\s*(?:%|percent|x\b|k\b|m\b|million|billion|\+)?/gi;

function normaliseNumber(n: string): string {
  return n.toLowerCase().replace(/\s+/g, "").replace(/percent/, "%").replace(/,/g, "");
}

/**
 * Flags statements in generated text that the user's profile does not support:
 *  - numbers/metrics that never appear in the profile, and
 *  - skills or technologies that appear in the job description but not in the profile.
 * This is a safety net, not proof of truth; flagged items are shown to the user.
 */
export function detectUnsupportedClaims(
  generated: string,
  profileText: string,
  jobText: string,
  allowedExtra: string[] = [],
): UnsupportedClaim[] {
  const claims: UnsupportedClaim[] = [];
  const profileNumbers = new Set((profileText.match(NUMBER) ?? []).map(normaliseNumber));
  const allowedNumbers = new Set(allowedExtra.flatMap((a) => a.match(NUMBER) ?? []).map(normaliseNumber));

  for (const raw of new Set(generated.match(NUMBER) ?? [])) {
    const n = normaliseNumber(raw);
    if (!/\d/.test(n)) continue;
    // Ignore years (e.g. dates in a cover letter) and single digits used as ordinary words.
    if (/^(19|20)\d{2}$/.test(n) || /^\d$/.test(n)) continue;
    if (!profileNumbers.has(n) && !allowedNumbers.has(n)) {
      claims.push({ claim: raw.trim(), reason: "This figure does not appear anywhere in your resume or evidence vault." });
    }
  }

  const profileTokens = keywords(profileText);
  const jobTokens = keywords(jobText);
  const allowedTokens = keywords(allowedExtra.join(" "));
  for (const token of keywords(generated)) {
    if (jobTokens.has(token) && !profileTokens.has(token) && !allowedTokens.has(token)) {
      claims.push({ claim: token, reason: "This skill or term comes from the job description but is not in your profile." });
    }
  }
  return claims;
}
