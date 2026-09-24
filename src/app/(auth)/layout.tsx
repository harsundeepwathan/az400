import Link from "next/link";

export default function AuthLayout({ children }: { children: React.ReactNode }) {
  return (
    <div className="flex min-h-screen flex-col items-center justify-center px-4 py-10">
      <Link href="/" className="mb-6 text-lg font-semibold">JobPilot</Link>
      <main className="w-full max-w-sm rounded-lg border border-line bg-surface p-6">{children}</main>
      <p className="mt-6 max-w-sm text-center text-xs text-muted">Your data is private to your account. JobPilot never sells or shares it.</p>
    </div>
  );
}
