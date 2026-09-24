import "server-only";
import { validateResumeFile, type ResumeFileKind } from "./file";

export type Extraction =
  | { ok: true; kind: ResumeFileKind; text: string }
  | { ok: false; error: string };

const EXTRACT_TIMEOUT_MS = 15_000;

function withTimeout<T>(promise: Promise<T>): Promise<T> {
  return Promise.race([
    promise,
    new Promise<T>((_, reject) => setTimeout(() => reject(new Error("timeout")), EXTRACT_TIMEOUT_MS)),
  ]);
}

/** Validates the file and extracts plain text. Never throws; never logs content. */
export async function extractResumeText(name: string, bytes: Uint8Array): Promise<Extraction> {
  const check = validateResumeFile(name, bytes.byteLength, bytes.subarray(0, 8));
  if (!check.ok) return check;
  try {
    if (check.kind === "pdf") {
      const { extractText, getDocumentProxy } = await import("unpdf");
      const pdf = await withTimeout(getDocumentProxy(new Uint8Array(bytes)));
      const { text } = await withTimeout(extractText(pdf, { mergePages: true }));
      return { ok: true, kind: "pdf", text };
    }
    const mammoth = await import("mammoth");
    const { value } = await withTimeout(mammoth.extractRawText({ buffer: Buffer.from(bytes) }));
    return { ok: true, kind: "docx", text: value };
  } catch {
    return {
      ok: false,
      error: "We could not read this file. It may be damaged, password-protected or scanned. Try pasting the text instead.",
    };
  }
}
