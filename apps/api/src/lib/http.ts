import type { FastifyRequest } from 'fastify';
import { z } from 'zod';

export const uuid = z.string().uuid();
export const idParams = z.object({ id: uuid });

export function params<T extends z.ZodTypeAny>(req: FastifyRequest, schema: T): z.infer<T> {
  return schema.parse(req.params);
}
export function query<T extends z.ZodTypeAny>(req: FastifyRequest, schema: T): z.infer<T> {
  return schema.parse(req.query);
}
export function body<T extends z.ZodTypeAny>(req: FastifyRequest, schema: T): z.infer<T> {
  return schema.parse(req.body ?? {});
}

/** Parses a time range; defaults to the last hour. Accepts presets or ISO timestamps. */
export const rangeSchema = z.object({
  range: z.enum(['1h', '6h', '24h', '7d', '30d']).optional(),
  from: z.string().datetime().optional(),
  to: z.string().datetime().optional(),
});

const presets: Record<string, number> = { '1h': 3600e3, '6h': 6 * 3600e3, '24h': 86400e3, '7d': 7 * 86400e3, '30d': 30 * 86400e3 };

export function resolveRange(q: z.infer<typeof rangeSchema>): { from: Date; to: Date } {
  const to = q.to ? new Date(q.to) : new Date();
  const from = q.from ? new Date(q.from) : new Date(to.getTime() - (presets[q.range ?? '1h'] ?? 3600e3));
  if (from >= to) throw Object.assign(new Error('from must be before to'), { statusCode: 400 });
  if (to.getTime() - from.getTime() > 400 * 86400e3) throw Object.assign(new Error('range too large'), { statusCode: 400 });
  return { from, to };
}
