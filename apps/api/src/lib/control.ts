// Client for the Go control API (go/internal/control), which runs provider operations.
import type { Config } from '../config.js';
import { HttpError } from './errors.js';

export interface ControlClient {
  validate(orgId: string, accountId: string): Promise<any>;
  discover(orgId: string, accountId: string): Promise<any>;
  testChannel(orgId: string, channelId: string): Promise<any>;
  providers(): Promise<any>;
}

export function controlClient(cfg: Pick<Config, 'controlUrl' | 'controlToken'>): ControlClient {
  async function call(method: string, path: string) {
    if (!cfg.controlToken) throw new HttpError(503, 'Monitoring backend control channel is not configured', 'control_unavailable');
    let res: Response;
    try {
      res = await fetch(cfg.controlUrl + path, {
        method,
        headers: { Authorization: `Bearer ${cfg.controlToken}` },
        signal: AbortSignal.timeout(180_000),
      });
    } catch {
      throw new HttpError(503, 'Monitoring backend is unreachable', 'control_unavailable');
    }
    if (!res.ok) throw new HttpError(502, `Monitoring backend error (${res.status})`, 'control_error');
    return res.json();
  }
  return {
    validate: (o, a) => call('POST', `/internal/accounts/${o}/${a}/validate`),
    discover: (o, a) => call('POST', `/internal/accounts/${o}/${a}/discover`),
    testChannel: (o, c) => call('POST', `/internal/channels/${o}/${c}/test`),
    providers: () => call('GET', '/internal/providers'),
  };
}
