"use client";

import { useEffect } from "react";

/** Reports the browser's time zone so "today" and due dates match the user's calendar. */
export function TimeZoneCookie() {
  useEffect(() => {
    const tz = Intl.DateTimeFormat().resolvedOptions().timeZone;
    if (tz && !document.cookie.includes(`jp_tz=${encodeURIComponent(tz)}`)) {
      document.cookie = `jp_tz=${encodeURIComponent(tz)}; path=/; max-age=31536000; samesite=lax`;
    }
  }, []);
  return null;
}
