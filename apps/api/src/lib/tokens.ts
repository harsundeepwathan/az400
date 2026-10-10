import { createHash, randomBytes } from 'node:crypto';

export const sha256 = (s: string) => createHash('sha256').update(s).digest();
export const randomToken = (bytes = 32) => randomBytes(bytes).toString('base64url');
/** Enrollment tokens: shared hash format with go/internal/ingest.HashToken. */
export const newEnrollmentToken = () => 'swe_' + randomToken(24);
