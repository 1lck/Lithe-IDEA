import { useEffect, useState } from "react";
import { QUOTA_CONNECTION_LABEL_KEYS, QUOTA_PLATFORM_LABEL_KEYS } from "../services/quota-api";
import type { PlatformQuota, QuotaPlatformId } from "../types/quota.types";
import { QuotaWindowRow } from "./quota-window-row";
import { useTranslation } from "@/i18n/locale-provider";
import { Button } from "@/ui/button";
import { PulseIcon, RefreshIcon, WarningCircleIcon } from "@/ui/icons";
import { cn } from "@/utils/cn";

interface QuotaPanelProps {
  snapshot: PlatformQuota[];
  active: PlatformQuota | null;
  isRefreshing: boolean;
  onRefresh: () => void;
  onSelectPlatform: (platform: QuotaPlatformId) => void;
  /** The tool window carries the data source in its own footer, so it drops this one. */
  showDataSource?: boolean;
}

export function QuotaPanel({
  snapshot,
  active,
  isRefreshing,
  onRefresh,
  onSelectPlatform,
  showDataSource = true,
}: QuotaPanelProps) {
  const { t } = useTranslation();
  const [now, setNow] = useState(() => Date.now());

  // The countdown only ticks while the panel is open, so the whole status bar
  // does not re-render every minute
  useEffect(() => {
    setNow(Date.now());
    const intervalId = window.setInterval(() => setNow(Date.now()), 30_000);
    return () => window.clearInterval(intervalId);
  }, [active]);

  if (!active) {
    return (
      <div className="px-3 py-2.5 font-sans ui-text-sm text-subtle-foreground">
        {t("usage.loading")}
      </div>
    );
  }

  const updatedAt = active.fetchedAt
    ? t("usage.updatedAt", { time: new Date(active.fetchedAt).toLocaleTimeString() })
    : null;

  return (
    <div className="font-sans">
      <div className="flex items-center gap-2 px-3 py-2">
        <PulseIcon className="size-4 shrink-0 text-subtle-foreground" />
        <span className="ui-text-sm font-medium text-foreground">
          {t(QUOTA_PLATFORM_LABEL_KEYS[active.platform])}
        </span>
        <span className="shrink-0 rounded border border-border px-1.5 ui-text-caption text-subtle-foreground">
          {t(QUOTA_CONNECTION_LABEL_KEYS[active.connection])}
        </span>
        {active.plan ? (
          <span className="shrink-0 ui-text-caption text-subtle-foreground">{active.plan}</span>
        ) : null}
        <Button
          type="button"
          variant="ghost"
          size="icon-sm"
          tooltip={t("usage.refresh")}
          aria-label={t("usage.refresh")}
          className="ml-auto"
          onClick={onRefresh}
        >
          <RefreshIcon className={cn("size-3.5", isRefreshing && "animate-spin")} />
        </Button>
      </div>

      {snapshot.length > 1 ? (
        <div className="flex gap-1 border-border/70 border-t px-3 py-1.5">
          {snapshot.map((entry) => (
            <button
              key={entry.platform}
              type="button"
              onClick={() => onSelectPlatform(entry.platform)}
              className={cn(
                "rounded px-2 py-0.5 ui-text-caption transition-colors",
                entry.platform === active.platform
                  ? "bg-selected text-foreground"
                  : "text-subtle-foreground hover:bg-accent hover:text-foreground",
              )}
            >
              {t(QUOTA_PLATFORM_LABEL_KEYS[entry.platform])}
            </button>
          ))}
        </div>
      ) : null}

      <div className="border-border/70 border-t px-3 py-2.5">
        {active.failure ? (
          <div className="space-y-2">
            <div className="flex items-start gap-2">
              <WarningCircleIcon className="mt-0.5 size-4 shrink-0 text-warning" />
              <span className="ui-text-sm text-foreground">
                {t(`usage.failure.${active.failure}`)}
              </span>
            </div>
            <p className="ui-text-caption leading-relaxed text-subtle-foreground">
              {t(`usage.failureHint.${active.failure}`)}
            </p>
            {active.detail ? (
              <p className="font-mono ui-text-caption break-all text-subtle-foreground/70">
                {active.detail}
              </p>
            ) : null}
            {active.scannedPaths.length > 0 ? (
              <div className="space-y-0.5">
                <div className="ui-text-caption text-subtle-foreground/70">
                  {t("usage.scannedLocations")}
                </div>
                {active.scannedPaths.map((path) => (
                  <div
                    key={path}
                    className="font-mono ui-text-caption break-all text-subtle-foreground/70"
                  >
                    {path}
                  </div>
                ))}
              </div>
            ) : null}
          </div>
        ) : (
          <div className="space-y-3">
            {active.windows.map((window) => (
              <QuotaWindowRow key={window.key} window={window} now={now} />
            ))}
          </div>
        )}
      </div>

      {showDataSource ? (
        <div className="flex items-center gap-2 border-border/70 border-t px-3 py-2 ui-text-caption text-subtle-foreground">
          <span>{t("usage.dataSource")}</span>
          {updatedAt ? <span className="ml-auto shrink-0">{updatedAt}</span> : null}
        </div>
      ) : null}
    </div>
  );
}
