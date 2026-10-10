'use client';
// ECharts wrapper. Imports only the modules used (tree-shaken). Colors come from CSS
// tokens so light/dark themes are both first-class; single-axis charts only.
import { BarChart, LineChart } from 'echarts/charts';
import { GridComponent, LegendComponent, MarkLineComponent, TooltipComponent } from 'echarts/components';
import * as echarts from 'echarts/core';
import { SVGRenderer } from 'echarts/renderers';
import { useEffect, useRef } from 'react';

echarts.use([LineChart, BarChart, GridComponent, TooltipComponent, LegendComponent, MarkLineComponent, SVGRenderer]);

export function cssVar(name: string): string {
  if (typeof window === 'undefined') return '#888';
  return getComputedStyle(document.documentElement).getPropertyValue(name).trim() || '#888';
}


export interface Series {
  name: string;
  data: [number | string, number | null][];
  color?: string;
  area?: boolean;
  type?: 'line' | 'bar';
  stack?: string;
}

export function TimeChart({ series, height = 180, unit = '', yMax, thresholds = [], valueFormatter, ariaLabel, showLegend }: {
  series: Series[];
  height?: number;
  unit?: string;
  yMax?: number;
  thresholds?: { value: number; label: string; severity: 'warning' | 'critical' }[];
  valueFormatter?: (v: number) => string;
  ariaLabel: string;
  showLegend?: boolean;
}) {
  const el = useRef<HTMLDivElement>(null);
  const chart = useRef<echarts.ECharts | null>(null);

  useEffect(() => {
    if (!el.current) return;
    const c = echarts.init(el.current, undefined, { renderer: 'svg' });
    chart.current = c;
    const ro = new ResizeObserver(() => c.resize());
    ro.observe(el.current);
    const mo = new MutationObserver(() => c.setOption(build(), { notMerge: true }));
    mo.observe(document.documentElement, { attributes: true, attributeFilter: ['data-theme'] });
    return () => { ro.disconnect(); mo.disconnect(); c.dispose(); };
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, []);

  const fmt = valueFormatter ?? ((v: number) => `${Number.isInteger(v) ? v : v.toFixed(1)}${unit}`);

  function build(): echarts.EChartsCoreOption {
    const ink2 = cssVar('--ink-2'), ink3 = cssVar('--ink-3'), grid = cssVar('--grid'), axis = cssVar('--axis'), surface = cssVar('--surface');
    const legend = showLegend ?? series.length > 1;
    return {
      animation: false,
      textStyle: { fontFamily: 'system-ui, -apple-system, "Segoe UI", sans-serif', color: ink2 },
      grid: { left: 8, right: 12, top: legend ? 28 : 10, bottom: 4, containLabel: true },
      legend: legend ? { top: 0, left: 0, icon: 'roundRect', itemWidth: 10, itemHeight: 3, textStyle: { color: ink2, fontSize: 11 } } : undefined,
      tooltip: {
        trigger: 'axis', backgroundColor: surface, borderColor: axis, textStyle: { color: cssVar('--ink'), fontSize: 12 },
        axisPointer: { type: 'line', lineStyle: { color: axis } },
        valueFormatter: (v: unknown) => (v == null ? 'no data' : fmt(Number(v))),
      },
      xAxis: { type: 'time', axisLine: { lineStyle: { color: axis } }, axisTick: { show: false }, splitLine: { show: false },
        axisLabel: { color: ink3, fontSize: 10, hideOverlap: true } },
      yAxis: { type: 'value', max: yMax, min: 0, splitNumber: 3, interval: yMax === 100 ? 25 : undefined, axisLabel: { color: ink3, fontSize: 10, formatter: (v: number) => fmt(v) },
        splitLine: { lineStyle: { color: grid, width: 1 } } },
      series: series.map((s, i) => ({
        name: s.name, type: s.type ?? 'line', data: s.data, showSymbol: false, connectNulls: false, stack: s.stack,
        lineStyle: { width: 2 }, itemStyle: { color: s.color ?? cssVar(`--series-${(i % 8) + 1}`), borderRadius: s.type === 'bar' ? [2, 2, 0, 0] : 0 },
        barMaxWidth: 10, sampling: 'lttb',
        areaStyle: s.area ? { opacity: 0.08 } : undefined,
        markLine: i === 0 && thresholds.length ? {
          silent: true, symbol: 'none', label: { show: true, position: 'insideEndTop', fontSize: 10, color: ink3, formatter: (p: { name: string }) => p.name },
          data: thresholds.map((t) => ({ yAxis: t.value, name: t.label, lineStyle: { color: t.severity === 'critical' ? cssVar('--critical') : cssVar('--warning'), width: 1, type: 'solid', opacity: 0.6 } })),
        } : undefined,
      })),
    };
  }

  useEffect(() => {
    chart.current?.setOption(build(), { notMerge: true });
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [series, yMax, unit, thresholds]);

  return <div ref={el} role="img" aria-label={ariaLabel} style={{ height }} className="w-full" />;
}
