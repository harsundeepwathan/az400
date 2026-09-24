"use client";

import { useState, useTransition, type ReactNode } from "react";
import { Button } from "@/components/ui/button";
import type { ActionState } from "@/lib/forms";

/** A button that runs a server action, optionally after confirmation, and shows its result. */
export function ActionButton({
  action,
  children,
  confirm,
  variant = "secondary",
  size = "sm",
  pendingText,
}: {
  action: () => Promise<ActionState | void>;
  children: ReactNode;
  confirm?: string;
  variant?: "primary" | "secondary" | "ghost" | "danger";
  size?: "sm" | "md";
  pendingText?: string;
}) {
  const [pending, start] = useTransition();
  const [result, setResult] = useState<ActionState | void>();
  return (
    <span className="inline-flex flex-wrap items-center gap-2">
      <Button
        variant={variant}
        size={size}
        disabled={pending}
        onClick={() => {
          if (confirm && !window.confirm(confirm)) return;
          start(async () => setResult(await action()));
        }}
      >
        {pending ? (pendingText ?? "Working…") : children}
      </Button>
      {result?.message && <span role="status" className="text-sm text-muted">{result.message}</span>}
      {result?.error && <span role="alert" className="text-sm text-danger">{result.error}</span>}
    </span>
  );
}
