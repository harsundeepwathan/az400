'use client';
import { useState } from 'react';
import { Button, Input, Tabs } from './ui';

export type Range = { range?: '1h' | '6h' | '24h' | '7d' | '30d'; from?: string; to?: string };

export function TimeRangePicker({ value, onChange }: { value: Range; onChange: (r: Range) => void }) {
  const [custom, setCustom] = useState(false);
  const [from, setFrom] = useState('');
  const [to, setTo] = useState('');
  const preset = value.range ?? (value.from ? 'custom' : '1h');
  return (
    <div className="flex flex-wrap items-center gap-2">
      <Tabs value={custom ? 'custom' : preset} onChange={(v) => { if (v === 'custom') { setCustom(true); return; } setCustom(false); onChange({ range: v as Range['range'] }); }}
        items={[{ value: '1h', label: '1h' }, { value: '6h', label: '6h' }, { value: '24h', label: '24h' }, { value: '7d', label: '7d' }, { value: '30d', label: '30d' }, { value: 'custom', label: 'Custom' }]} />
      {custom && (
        <form className="flex items-center gap-1.5" onSubmit={(e) => { e.preventDefault(); if (from && to) onChange({ from: new Date(from).toISOString(), to: new Date(to).toISOString() }); }}>
          <Input type="datetime-local" aria-label="From" value={from} onChange={(e) => setFrom(e.target.value)} className="w-48" />
          <span className="text-ink-3">–</span>
          <Input type="datetime-local" aria-label="To" value={to} onChange={(e) => setTo(e.target.value)} className="w-48" />
          <Button size="sm" type="submit">Apply</Button>
        </form>
      )}
    </div>
  );
}
