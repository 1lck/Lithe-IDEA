import { useState } from "react";
import { useUsage } from "../hooks/use-usage";
import { UsageLogView } from "./usage-log-view";
import { UsageQuotaView } from "./usage-quota-view";
import { UsageTokensView } from "./usage-tokens-view";
import { useTranslation } from "@/i18n/locale-provider";
import { Button } from "@/ui/button";
import { RefreshIcon, XIcon } from "@/ui/icons";
import { Tabs, TabsList, TabsTrigger } from "@/ui/tabs";
import { cn } from "@/utils/cn";

type UsageTabId = "quota" | "tokens" | "log";

const TAB_IDS: readonly UsageTabId[] = ["quota", "tokens", "log"];

interface UsageToolWindowProps {
  onClose: () => void;
}

/**
 * The right hand tool window: subscription quota, token statistics and the
 * request log, one tab each rather than one long page.
 */
export function UsageToolWindow({ onClose }: UsageToolWindowProps) {
  const { t } = useTranslation();
  const { snapshot, isScanning, isFirstScan, scan } = useUsage();
  const [tab, setTab] = useState<UsageTabId>("tokens");

  const missingRoots = snapshot.roots.filter((root) => !root.exists).map((root) => root.directory);
  // The first scan of a session re-reads nothing when the ledger was restored,
  // so the "reading the logs" note is only for a panel that has nothing to show.
  const isReadingLogs = isFirstScan && snapshot.records.length === 0;

  return (
    <section
      aria-label={t("usageStats.title")}
      className="flex h-full min-h-0 flex-col bg-background"
    >
      <div className="flex h-8 shrink-0 items-center border-border/70 border-b px-3">
        <h2 className="font-sans ui-text-sm min-w-0 flex-1 truncate font-semibold text-foreground">
          {t("usageStats.title")}
        </h2>
        <Button
          type="button"
          variant="ghost"
          size="icon-xs"
          onClick={scan}
          tooltip={t("usageStats.refresh")}
          aria-label={t("usageStats.refresh")}
          tooltipSide="bottom"
        >
          <RefreshIcon className={cn("size-3.5", isScanning && "animate-spin")} />
        </Button>
        <Button
          type="button"
          variant="ghost"
          size="icon-xs"
          onClick={onClose}
          tooltip={t("commandPalette.close")}
          aria-label={t("commandPalette.close")}
          tooltipSide="bottom"
        >
          <XIcon className="size-3.5" />
        </Button>
      </div>

      <Tabs
        value={tab}
        onValueChange={(value) => setTab(value as UsageTabId)}
        className="flex min-h-0 flex-1 flex-col gap-0"
      >
        <div className="shrink-0 px-3 pt-2 pb-1">
          <TabsList className="w-full" variant="segmented">
            {TAB_IDS.map((id) => (
              <TabsTrigger key={id} value={id} size="xs">
                {t(`usageStats.tab.${id}`)}
              </TabsTrigger>
            ))}
          </TabsList>
        </div>
        <div className="min-h-0 flex-1 overflow-y-auto">
          {tab === "quota" ? (
            <UsageQuotaView />
          ) : tab === "tokens" ? (
            <UsageTokensView records={snapshot.records} isFirstScan={isReadingLogs} />
          ) : (
            <UsageLogView records={snapshot.records} isFirstScan={isReadingLogs} />
          )}
        </div>
      </Tabs>

      <div className="shrink-0 border-border/70 border-t px-3 py-1.5 ui-text-caption text-subtle-foreground">
        <div className="truncate" title={snapshot.roots.map((root) => root.directory).join("\n")}>
          {missingRoots.length === snapshot.roots.length && snapshot.roots.length > 0
            ? t("usageStats.empty")
            : t("usageStats.source", { count: snapshot.trackedFiles })}
        </div>
        {snapshot.lastScanAt ? (
          <div className="truncate">
            {t("usageStats.scannedAt", {
              time: new Date(snapshot.lastScanAt).toLocaleTimeString(),
            })}
          </div>
        ) : null}
      </div>
    </section>
  );
}
