import type { Tx } from '../db.js';

/** Appends an audit record inside the caller's tenant-scoped transaction. */
export async function audit(
  tx: Tx,
  a: { orgId: string; userId: string; action: string; targetType?: string; targetId?: string; details?: object; ip?: string },
) {
  await tx.query(
    `INSERT INTO audit_logs(org_id, actor_type, actor_id, actor_label, action, target_type, target_id, details, ip)
     VALUES ($1,'user',$2::uuid::text,(SELECT email FROM users WHERE id=$2::uuid),$3,$4,$5,$6,$7)`,
    [a.orgId, a.userId, a.action, a.targetType ?? null, a.targetId ?? null, JSON.stringify(a.details ?? {}), a.ip ?? null],
  );
}
