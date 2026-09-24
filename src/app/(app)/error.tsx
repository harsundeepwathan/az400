"use client";

import { Button } from "@/components/ui/button";

export default function AppError({ reset }: { error: Error & { digest?: string }; reset: () => void }) {
  return (
    <div role="alert" className="rounded-lg border border-danger/30 bg-surface p-6">
      <h1 className="text-lg font-semibold">Something went wrong</h1>
      <p className="mt-1 text-sm text-muted">Your data is safe. Try again, and if the problem continues, reload the page.</p>
      <Button className="mt-4" onClick={reset}>Try again</Button>
    </div>
  );
}
