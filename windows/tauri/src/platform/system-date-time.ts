import { isTauri, invoke } from "./tauri-core";

export interface DateTimePresentation {
  date: string;
  time: string;
}

/** Browser previews use locale defaults; packaged Windows uses the user's OS overrides. */
export function formatLocaleDateTime(date: Date, locale?: string): DateTimePresentation {
  return {
    date: new Intl.DateTimeFormat(locale, {
      year: "numeric",
      month: "numeric",
      day: "numeric",
    }).format(date),
    time: new Intl.DateTimeFormat(locale, { hour: "numeric", minute: "2-digit" }).format(date),
  };
}

export async function loadSystemDateTime(timestamp: number): Promise<DateTimePresentation> {
  if (!isTauri()) return formatLocaleDateTime(new Date(timestamp));
  return invoke<DateTimePresentation>("format_system_date_time", { timestamp });
}
