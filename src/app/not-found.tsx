import { ButtonLink } from "@/components/ui/button";

export default function NotFound() {
  return (
    <main className="flex min-h-[60vh] flex-col items-center justify-center px-4 text-center">
      <p className="text-sm font-medium text-accent">404</p>
      <h1 className="mt-1 text-2xl font-semibold">Page not found</h1>
      <p className="mt-2 max-w-sm text-sm text-muted">It may have been deleted, or it belongs to a different account.</p>
      <ButtonLink href="/today" className="mt-5">Go to Today</ButtonLink>
    </main>
  );
}
