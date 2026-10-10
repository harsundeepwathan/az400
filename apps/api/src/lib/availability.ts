// Availability calculation. Mirrors go/internal/health/availability.go; the policy is
// documented in docs/STATE_MODEL.md#availability:
//   available   = healthy, warning, critical
//   unavailable = down
//   excluded    = maintenance, stopped, unknown, no_data, and unobserved time
// percent = available / (available + unavailable); null when nothing was observed.
export interface StateInterval {
  state: string;
  start: Date;
  end: Date | null;
}

export interface AvailabilityPolicy {
  criticalIsDown?: boolean;
  stoppedIsDown?: boolean;
}

export interface Availability {
  period_seconds: number;
  available_seconds: number;
  unavailable_seconds: number;
  excluded_seconds: number;
  percent: number | null;
  coverage: number;
}

function classify(state: string, p: AvailabilityPolicy): 1 | -1 | 0 {
  switch (state) {
    case 'healthy':
    case 'warning':
      return 1;
    case 'critical':
      return p.criticalIsDown ? -1 : 1;
    case 'down':
      return -1;
    case 'stopped':
      return p.stoppedIsDown ? -1 : 0;
    default:
      return 0;
  }
}

export function computeAvailability(intervals: StateInterval[], from: Date, to: Date, p: AvailabilityPolicy = {}): Availability {
  const period = (to.getTime() - from.getTime()) / 1000;
  let available = 0, unavailable = 0, excluded = 0, covered = 0;
  for (const iv of intervals) {
    const start = Math.max(iv.start.getTime(), from.getTime());
    const end = Math.min((iv.end ?? to).getTime(), to.getTime());
    if (end <= start) continue;
    const d = (end - start) / 1000;
    covered += d;
    const c = classify(iv.state, p);
    if (c === 1) available += d;
    else if (c === -1) unavailable += d;
    else excluded += d;
  }
  excluded += Math.max(0, period - covered);
  const observed = available + unavailable;
  return {
    period_seconds: period,
    available_seconds: available,
    unavailable_seconds: unavailable,
    excluded_seconds: excluded,
    percent: observed > 0 ? (available / observed) * 100 : null,
    coverage: period > 0 ? observed / period : 0,
  };
}

export const METHODOLOGY =
  'Availability = time in Healthy, Warning or Critical ÷ (that time + time in Down), over the selected period. ' +
  'Maintenance, Stopped (intentionally powered off), Unknown, No Data and unobserved time are excluded from both ' +
  'numerator and denominator and reported separately as coverage. Down is only recorded when independent signals ' +
  'confirm an outage or the provider reports the resource unavailable.';
