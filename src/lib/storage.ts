import "server-only";
import { randomUUID } from "node:crypto";
import { mkdir, rm, writeFile } from "node:fs/promises";
import path from "node:path";
import { env } from "./env";
import { supabaseServerClient } from "./auth/supabase";
import type { ResumeFileKind } from "./resume/file";
import { RESUME_TYPES } from "./resume/file";

const LOCAL_ROOT = path.join(process.cwd(), ".data", "uploads");
const BUCKET = "resumes";

/**
 * Stores original resume files privately under "<userId>/<random>.<ext>".
 * The original filename is never used in the path.
 */
export async function storeResumeFile(userId: string, kind: ResumeFileKind, bytes: Uint8Array): Promise<string> {
  const key = `${userId}/${randomUUID()}.${kind}`;
  if (env().storageMode === "supabase") {
    const supabase = await supabaseServerClient();
    const { error } = await supabase.storage.from(BUCKET).upload(key, bytes, { contentType: RESUME_TYPES[kind], upsert: false });
    if (error) throw new Error("Could not store the file");
    return key;
  }
  const file = path.join(LOCAL_ROOT, key);
  await mkdir(path.dirname(file), { recursive: true, mode: 0o700 });
  await writeFile(file, bytes, { mode: 0o600 });
  return key;
}

function assertOwnKey(userId: string, key: string) {
  if (!key.startsWith(`${userId}/`) || key.includes("..")) throw new Error("Invalid storage key");
}

export async function deleteResumeFiles(userId: string, keys: string[]) {
  if (keys.length === 0) return;
  keys.forEach((k) => assertOwnKey(userId, k));
  if (env().storageMode === "supabase") {
    const supabase = await supabaseServerClient();
    await supabase.storage.from(BUCKET).remove(keys);
    return;
  }
  await Promise.all(keys.map((k) => rm(path.join(LOCAL_ROOT, k), { force: true })));
}

export async function deleteAllUserFiles(userId: string, keys: string[]) {
  await deleteResumeFiles(userId, keys);
  if (env().storageMode === "local") await rm(path.join(LOCAL_ROOT, userId), { recursive: true, force: true });
}
