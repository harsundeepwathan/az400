import "server-only";
import { cookies } from "next/headers";
import { isoDateInZone, isValidTimeZone, type ISODate } from "./dates";

export const TZ_COOKIE = "jp_tz";

/** The user's time zone, reported by the browser via a cookie (defaults to UTC). */
export async function userTimeZone(): Promise<string> {
  const tz = (await cookies()).get(TZ_COOKIE)?.value;
  return tz && isValidTimeZone(tz) ? tz : "UTC";
}

export async function todayForUser(): Promise<ISODate> {
  return isoDateInZone(new Date(), await userTimeZone());
}
