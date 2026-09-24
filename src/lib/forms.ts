import type { ZodError } from "zod";

export type ActionState = {
  ok?: boolean;
  message?: string;
  error?: string;
  fieldErrors?: Record<string, string>;
} | undefined;

export function fieldErrors(error: ZodError): Record<string, string> {
  const out: Record<string, string> = {};
  for (const issue of error.issues) {
    const key = issue.path.join(".");
    if (!out[key]) out[key] = issue.message;
  }
  return out;
}

export function str(fd: FormData, key: string): string {
  const v = fd.get(key);
  return typeof v === "string" ? v.trim() : "";
}

/** Splits a textarea or comma-separated input into trimmed, non-empty values. */
export function list(fd: FormData, key: string, separator: RegExp = /\n|,/): string[] {
  return str(fd, key)
    .split(separator)
    .map((s) => s.trim())
    .filter(Boolean);
}

export function lines(fd: FormData, key: string): string[] {
  return list(fd, key, /\n/);
}

export function bool(fd: FormData, key: string): boolean {
  const v = fd.get(key);
  return v === "on" || v === "true" || v === "1";
}

export function intOrNull(fd: FormData, key: string): number | null {
  const v = str(fd, key).replace(/[,\s]/g, "");
  if (!v) return null;
  const n = Number(v);
  return Number.isFinite(n) ? Math.round(n) : NaN;
}

export function dateOrNull(fd: FormData, key: string): string | null {
  const v = str(fd, key);
  return v || null;
}
