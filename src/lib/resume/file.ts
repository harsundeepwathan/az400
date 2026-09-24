export const MAX_RESUME_BYTES = 5 * 1024 * 1024;

export const RESUME_TYPES = {
  pdf: "application/pdf",
  docx: "application/vnd.openxmlformats-officedocument.wordprocessingml.document",
} as const;
export type ResumeFileKind = keyof typeof RESUME_TYPES;

export type FileCheck = { ok: true; kind: ResumeFileKind } | { ok: false; error: string };

/**
 * Validates an uploaded resume by size, extension and magic bytes. The
 * browser-supplied MIME type is advisory only and is never trusted alone.
 */
export function validateResumeFile(name: string, size: number, head: Uint8Array): FileCheck {
  if (size === 0) return { ok: false, error: "The file is empty." };
  if (size > MAX_RESUME_BYTES) return { ok: false, error: "The file is larger than 5 MB." };
  const ext = name.toLowerCase().split(".").pop();
  const isPdfMagic = head[0] === 0x25 && head[1] === 0x50 && head[2] === 0x44 && head[3] === 0x46; // %PDF
  const isZipMagic = head[0] === 0x50 && head[1] === 0x4b && head[2] === 0x03 && head[3] === 0x04; // PK..
  if (ext === "pdf" && isPdfMagic) return { ok: true, kind: "pdf" };
  if (ext === "docx" && isZipMagic) return { ok: true, kind: "docx" };
  if (ext === "doc") return { ok: false, error: "Legacy .doc files are not supported. Save as .docx or PDF." };
  if (ext !== "pdf" && ext !== "docx") return { ok: false, error: "Only PDF and DOCX files are supported." };
  return { ok: false, error: "The file contents do not match its extension." };
}
