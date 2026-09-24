"use client";

import { useTransition } from "react";
import { Check } from "lucide-react";
import { Button } from "@/components/ui/button";
import { completeTaskAction, deleteTaskAction, snoozeTaskAction } from "./actions";

export function CompleteTaskButton({ id, completed = false }: { id: string; completed?: boolean }) {
  const [pending, start] = useTransition();
  return (
    <Button
      size="sm"
      variant="secondary"
      disabled={pending}
      onClick={() => start(() => completeTaskAction(id, !completed))}
    >
      <Check className="h-3.5 w-3.5" aria-hidden />
      {completed ? "Reopen" : "Done"}
    </Button>
  );
}

export function TaskMenu({ id }: { id: string }) {
  const [pending, start] = useTransition();
  return (
    <div className="flex flex-wrap gap-1">
      <Button size="sm" variant="ghost" disabled={pending} onClick={() => start(() => snoozeTaskAction(id, 1))}>+1 day</Button>
      <Button size="sm" variant="ghost" disabled={pending} onClick={() => start(() => snoozeTaskAction(id, 7))}>+1 week</Button>
      <Button size="sm" variant="ghost" disabled={pending} onClick={() => start(() => deleteTaskAction(id))} className="text-danger">Delete</Button>
    </div>
  );
}
