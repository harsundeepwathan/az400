import { TimeZoneCookie } from "@/components/timezone-cookie";

export default function SetupLayout({ children }: { children: React.ReactNode }) {
  return (
    <div className="min-h-screen px-4 py-8 sm:py-12">
      <TimeZoneCookie />
      <main className="mx-auto max-w-3xl">{children}</main>
    </div>
  );
}
