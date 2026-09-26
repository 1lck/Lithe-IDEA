import { quotaTone, quotaWindowLabel, formatResetCountdown } from "../services/quota-format";
import type { QuotaWindow } from "../types/quota.types";
import { useTranslation } from "@/i18n/locale-provider";
import { cn } from "@/utils/cn";

const TONE_TEXT_CLASS = {
  ok: "text-success",
  warning: "text-warning",
  danger: "text-destructive",
} as const;

const TONE_BAR_CLASS = {
  ok: "bg-success",
  warning: "bg-warning",
  danger: "bg-destructive",
} as const;

interface QuotaWindowRowProps {
  window: QuotaWindow;
  now: number;
}

export function QuotaWindowRow({ window, now }: QuotaWindowRowProps) {
  const { t } = useTranslation();
  const resetIn = formatResetCountdown(window.resetsAt, now);
  const tone = window.usedPercent === null ? null : quotaTone(window.usedPercent);

  return (
    <div className="space-y-1.5">
      <div className="flex items-center gap-2">
        <span className="shrink-0 rounded bg-selected px-1.5 ui-text-caption text-foreground">
          {window.key}
        </span>
        <span className="ui-text-sm text-foreground">{quotaWindowLabel(t, window)}</span>
        <span
          className={cn(
            "ml-auto ui-text-sm font-medium tabular-nums",
            tone ? TONE_TEXT_CLASS[tone] : "text-subtle-foreground",
          )}
        >
          {window.usedPercent === null ? "—" : `${Math.round(window.usedPercent)}%`}
        </span>
      </div>

      {window.usedPercent === null || tone === null ? (
        // No percentage from the source means no bar: an empty bar reads as 0%
        <div className="ui-text-caption text-subtle-foreground">{t("usage.window.noPercent")}</div>
      ) : (
        <div className="h-1 w-full overflow-hidden rounded-full bg-accent">
          <div
            className={cn("h-full rounded-full transition-[width]", TONE_BAR_CLASS[tone])}
            style={{ width: `${Math.min(100, Math.max(0, window.usedPercent))}%` }}
          />
        </div>
      )}

      {resetIn ? (
        <div className="ui-text-caption text-subtle-foreground">
          {t("usage.window.resetsIn", { time: resetIn })}
        </div>
      ) : null}
    </div>
  );
}
