export function relTime(input: string | Date | null | undefined, now = Date.now()): string {
  if (!input) return '—';
  const t = typeof input === 'string' ? new Date(input).getTime() : input.getTime();
  const s = Math.round((now - t) / 1000);
  const abs = Math.abs(s);
  const suffix = s >= 0 ? 'ago' : 'from now';
  if (abs < 45) return s >= 0 ? 'just now' : 'in seconds';
  if (abs < 3600) return `${Math.round(abs / 60)}m ${suffix}`;
  if (abs < 86400) return `${Math.floor(abs / 3600)}h ${Math.round((abs % 3600) / 60)}m ${suffix}`;
  return `${Math.round(abs / 86400)}d ${suffix}`;
}

export function duration(fromIso: string, toIso?: string | null): string {
  const s = Math.max(0, Math.round(((toIso ? new Date(toIso).getTime() : Date.now()) - new Date(fromIso).getTime()) / 1000));
  if (s < 60) return `${s}s`;
  if (s < 3600) return `${Math.floor(s / 60)}m`;
  if (s < 86400) return `${Math.floor(s / 3600)}h ${Math.floor((s % 3600) / 60)}m`;
  return `${Math.floor(s / 86400)}d ${Math.floor((s % 86400) / 3600)}h`;
}

export function dateTime(iso: string | null | undefined): string {
  if (!iso) return '—';
  return new Date(iso).toLocaleString(undefined, { month: 'short', day: 'numeric', hour: '2-digit', minute: '2-digit', second: '2-digit' });
}

export function bytes(n: number | null | undefined): string {
  if (n == null) return '—';
  const u = ['B', 'KiB', 'MiB', 'GiB', 'TiB'];
  let i = 0;
  let v = n;
  while (v >= 1024 && i < u.length - 1) { v /= 1024; i++; }
  return `${v.toFixed(v >= 100 || i === 0 ? 0 : 1)} ${u[i]}`;
}

export function rate(n: number | null | undefined): string {
  if (n == null) return '—';
  return bytes(n) + '/s';
}

export function pct(n: number | null | undefined, digits = 0): string {
  return n == null ? '—' : `${Number(n).toFixed(digits)}%`;
}

export function metricLabel(m: string): string {
  return ({
    'cpu.utilization': 'CPU', 'memory.utilization': 'Memory', 'disk.utilization': 'Disk',
    'net.in_bytes_per_sec': 'Network in', 'net.out_bytes_per_sec': 'Network out',
    'disk.read_bytes_per_sec': 'Disk read', 'disk.write_bytes_per_sec': 'Disk write',
    'disk.read_ops_per_sec': 'Read IOPS', 'disk.write_ops_per_sec': 'Write IOPS', 'cpu.load1': 'Load (1m)',
    'cpu.load5': 'Load (5m)', 'cpu.load15': 'Load (15m)', 'memory.swap_utilization': 'Swap', 'cpu.iowait': 'I/O wait', 'cpu.steal': 'Steal',
    'net.tcp_established': 'TCP established', 'net.errors_per_sec': 'Interface errors', 'net.drops_per_sec': 'Interface drops',
  } as Record<string, string>)[m] ?? m;
}
