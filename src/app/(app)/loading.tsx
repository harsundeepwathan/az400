export default function Loading() {
  return (
    <div aria-busy="true" aria-live="polite" className="space-y-4">
      <span className="sr-only">Loading…</span>
      <div className="h-8 w-48 animate-pulse rounded bg-subtle" />
      <div className="h-32 animate-pulse rounded-lg bg-subtle" />
      <div className="h-32 animate-pulse rounded-lg bg-subtle" />
    </div>
  );
}
