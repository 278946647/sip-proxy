import dayjs, { type Dayjs } from "dayjs";
import utc from "dayjs/plugin/utc";
import timezone from "dayjs/plugin/timezone";
import relativeTime from "dayjs/plugin/relativeTime";
import "dayjs/locale/zh-cn";

/** Beijing / Hong Kong — both UTC+8 */
export const DISPLAY_TZ = "Asia/Shanghai";

dayjs.extend(utc);
dayjs.extend(timezone);
dayjs.extend(relativeTime);
dayjs.locale("zh-cn");
dayjs.tz.setDefault(DISPLAY_TZ);

const HAS_TZ_SUFFIX = /[zZ]$|[+-]\d{2}:\d{2}$/;

/**
 * Parse control-plane timestamps. Values are stored in UTC; SQLite may return naive ISO strings.
 */
export function parseApiTime(value: string | null | undefined): Dayjs | null {
  if (value == null) return null;
  const s = String(value).trim();
  if (!s) return null;
  if (HAS_TZ_SUFFIX.test(s)) {
    return dayjs(s).tz(DISPLAY_TZ);
  }
  return dayjs.utc(s).tz(DISPLAY_TZ);
}

export function nowDisplay(): Dayjs {
  return dayjs().tz(DISPLAY_TZ);
}

export function formatApiTime(
  value: string | null | undefined,
  format = "YYYY-MM-DD HH:mm:ss",
  fallback = "-",
): string {
  const d = parseApiTime(value);
  return d ? d.format(format) : fallback;
}

export function formatApiTimeFromNow(value: string | null | undefined, fallback = "-"): string {
  const d = parseApiTime(value);
  return d ? d.fromNow() : fallback;
}

/** Serialize a DatePicker value (Asia/Shanghai) to UTC ISO for the API. */
export function toApiIso(value: Dayjs | null | undefined): string | null {
  if (!value) return null;
  return value.tz(DISPLAY_TZ).utc().toISOString();
}
