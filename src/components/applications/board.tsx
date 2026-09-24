"use client";

import Link from "next/link";
import { useOptimistic, useState, useTransition } from "react";
import {
  DndContext, KeyboardSensor, PointerSensor, TouchSensor, useDraggable, useDroppable, useSensor, useSensors, type DragEndEvent,
} from "@dnd-kit/core";
import { GripVertical } from "lucide-react";
import { changeStageAction } from "@/app/(app)/applications/actions";
import { FitScore } from "@/components/badges";
import { cn } from "@/lib/cn";
import type { ApplicationCard } from "@/lib/data/applications";
import { STAGES, STAGE_LABELS, type Stage } from "@/lib/domain";

function StageSelect({ app, onMove, disabled }: { app: ApplicationCard; onMove: (s: Stage) => void; disabled: boolean }) {
  return (
    <>
      <label htmlFor={`move-${app.id}`} className="sr-only">Move {app.job_title} at {app.company} to stage</label>
      <select
        id={`move-${app.id}`}
        value={app.stage}
        disabled={disabled}
        onChange={(e) => onMove(e.target.value as Stage)}
        className="h-7 w-full rounded border border-line bg-surface px-1.5 text-xs text-muted"
      >
        {STAGES.map((s) => <option key={s} value={s}>{STAGE_LABELS[s]}</option>)}
      </select>
    </>
  );
}

function Card({ app, onMove, pending }: { app: ApplicationCard; onMove: (id: string, s: Stage) => void; pending: boolean }) {
  const { attributes, listeners, setNodeRef, transform, isDragging } = useDraggable({ id: app.id, data: { stage: app.stage } });
  const style = transform ? { transform: `translate3d(${transform.x}px, ${transform.y}px, 0)` } : undefined;
  return (
    <li
      ref={setNodeRef}
      style={style}
      data-testid={`app-card-${app.id}`}
      className={cn("rounded-md border border-line bg-surface p-3 shadow-sm", isDragging && "z-10 opacity-80 ring-2 ring-accent")}
    >
      <div className="flex items-start gap-1.5">
        <button
          type="button"
          className="-ml-1 mt-0.5 cursor-grab rounded p-0.5 text-muted hover:bg-subtle active:cursor-grabbing"
          aria-label={`Drag ${app.job_title} at ${app.company}. Press space to pick up, arrow keys to move, space to drop.`}
          {...listeners}
          {...attributes}
        >
          <GripVertical className="h-4 w-4" aria-hidden />
        </button>
        <div className="min-w-0 flex-1">
          <Link href={`/applications/${app.id}`} className="block text-sm font-medium leading-snug hover:underline">{app.job_title}</Link>
          <p className="truncate text-xs text-muted">{app.company}</p>
        </div>
        <FitScore score={app.fit_score} />
      </div>
      {(app.next_action || app.follow_up_on) && (
        <p className="mt-2 truncate text-xs text-muted">{app.next_action || `Follow up ${app.follow_up_on}`}</p>
      )}
      <div className="mt-2">
        <StageSelect app={app} disabled={pending} onMove={(s) => onMove(app.id, s)} />
      </div>
    </li>
  );
}

function Column({ stage, apps, onMove, pending }: { stage: Stage; apps: ApplicationCard[]; onMove: (id: string, s: Stage) => void; pending: boolean }) {
  const { setNodeRef, isOver } = useDroppable({ id: stage });
  return (
    <section
      ref={setNodeRef}
      aria-labelledby={`col-${stage}`}
      data-testid={`column-${stage}`}
      className={cn("flex w-64 shrink-0 flex-col rounded-lg border border-line bg-subtle/60 p-2", isOver && "border-accent bg-accent-soft")}
    >
      <h2 id={`col-${stage}`} className="flex items-center justify-between px-1 pb-2 text-sm font-semibold">
        {STAGE_LABELS[stage]}
        <span className="rounded bg-surface px-1.5 text-xs font-medium tabular-nums text-muted">{apps.length}</span>
      </h2>
      <ul className="flex min-h-16 flex-1 flex-col gap-2">
        {apps.map((a) => <Card key={a.id} app={a} onMove={onMove} pending={pending} />)}
      </ul>
    </section>
  );
}

export function ApplicationBoard({ applications }: { applications: ApplicationCard[] }) {
  const [optimistic, setOptimistic] = useOptimistic(applications, (state, move: { id: string; stage: Stage }) =>
    state.map((a) => (a.id === move.id ? { ...a, stage: move.stage } : a)),
  );
  const [pending, start] = useTransition();
  const [error, setError] = useState<string | null>(null);
  const [announcement, setAnnouncement] = useState("");
  const sensors = useSensors(
    useSensor(PointerSensor, { activationConstraint: { distance: 6 } }),
    useSensor(TouchSensor, { activationConstraint: { delay: 200, tolerance: 6 } }),
    useSensor(KeyboardSensor),
  );

  function move(id: string, stage: Stage) {
    const app = optimistic.find((a) => a.id === id);
    if (!app || app.stage === stage) return;
    setError(null);
    start(async () => {
      setOptimistic({ id, stage });
      const res = await changeStageAction(id, stage);
      if (res?.error) setError(res.error);
      else setAnnouncement(`${app.job_title} moved to ${STAGE_LABELS[stage]}.`);
    });
  }

  function onDragEnd(event: DragEndEvent) {
    if (event.over) move(String(event.active.id), event.over.id as Stage);
  }

  return (
    <>
      <p aria-live="polite" className="sr-only">{announcement}</p>
      {error && <p role="alert" className="mb-3 text-sm text-danger">{error}</p>}
      <DndContext sensors={sensors} onDragEnd={onDragEnd}>
        <div className="-mx-4 relative overflow-x-auto px-4 pb-4 sm:mx-0 sm:px-0" tabIndex={0} role="region" aria-label="Application board, scrolls horizontally">
          <div className="flex gap-3">
            {STAGES.map((stage) => (
              <Column key={stage} stage={stage} apps={optimistic.filter((a) => a.stage === stage)} onMove={move} pending={pending} />
            ))}
          </div>
        </div>
      </DndContext>
    </>
  );
}
