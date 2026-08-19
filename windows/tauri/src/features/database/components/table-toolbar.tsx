import {
  ArrowClockwiseIcon as ArrowClockwise,
  ClipboardTextIcon as ClipboardText,
  CodeIcon as Code,
  ColumnsIcon as Columns,
  DatabaseIcon as Database,
  DownloadIcon as Download,
  MinusCircleIcon as MinusCircle,
  PlusCircleIcon as PlusCircle,
  RadioButtonIcon as RadioButton,
  TrashIcon as Trash,
} from "@/ui/icons";
import { Button } from "@/ui/button";
import { useTranslation } from "@/i18n/locale-provider";
import { cn } from "@/utils/cn";
import { databaseChipClassName } from "./database-surface";
import { formatQueryResultSummary } from "../lib/query-result-summary";
import type {
  DatabaseInfo,
  DatabaseObjectKind,
  PostgresSubscriptionInfo,
  ViewMode,
} from "../types/common.types";

interface TableToolbarProps {
  fileName: string;
  dbInfo: DatabaseInfo | null;
  selectedObjectKind?: DatabaseObjectKind;
  subscriptionInfo?: PostgresSubscriptionInfo | null;
  viewMode: ViewMode;
  setViewMode: (mode: ViewMode) => void;
  isCustomQuery: boolean;
  showColumnTypes: boolean;
  setShowColumnTypes: (show: boolean) => void;
  setIsCustomQuery: (is: boolean) => void;
  hasData: boolean;
  resultRowCount?: number;
  currentPage?: number;
  totalPages?: number;
  exportAsCSV: () => void;
  copyAsJSON: () => void;
  onCreateSubscription?: () => void;
  onToggleSubscription?: () => void;
  onRefreshSubscription?: () => void;
  onDropSubscription?: () => void;
}

export default function TableToolbar({
  fileName,
  dbInfo,
  selectedObjectKind = "table",
  subscriptionInfo,
  viewMode,
  setViewMode,
  isCustomQuery,
  showColumnTypes,
  setShowColumnTypes,
  setIsCustomQuery,
  hasData,
  resultRowCount = 0,
  currentPage,
  totalPages,
  exportAsCSV,
  copyAsJSON,
  onCreateSubscription,
  onToggleSubscription,
  onRefreshSubscription,
  onDropSubscription,
}: TableToolbarProps) {
  const { t } = useTranslation();
  const viewTabs: { mode: ViewMode; label: string }[] = [
    { mode: "data", label: t("database.data") },
    { mode: "schema", label: t("database.schema") },
    { mode: "info", label: t("database.info") },
  ];
  const isSubscription = selectedObjectKind === "subscription";
  const resultSummary =
    hasData && viewMode === "data"
      ? formatQueryResultSummary({
          isCustomQuery,
          rowCount: resultRowCount,
          currentPage,
          totalPages,
          formatVisibleRows: (count) => t("database.visibleRows", { count }),
          formatQueryRows: (count) => t("database.queryRows", { count }),
          formatVisibleQueryRowsOnPage: (count, page, pages) =>
            t("database.visibleQueryRowsOnPage", { count, page, pages }),
        })
      : null;
  const exportTooltip = isCustomQuery
    ? t("database.exportVisibleQueryPageCsv")
    : t("database.exportVisiblePageCsv");
  const jsonTooltip = isCustomQuery
    ? t("database.copyVisibleQueryPageJson")
    : t("database.copyVisiblePageJson");
  const exportLabel = isCustomQuery ? t("database.exportVisibleQueryPageCsv") : t("database.exportAsCsv");
  const jsonLabel = isCustomQuery ? t("database.copyVisibleQueryPageJson") : t("database.copyAsJson");

  return (
    <div className="px-3 py-2">
      <div className="flex items-center justify-between">
        <div className="flex items-center gap-3">
          <div className="flex min-w-0 items-center gap-1.5">
            <Database className="text-subtle-foreground" />
            <span className="font-sans ui-text-sm min-w-0 truncate text-foreground">
              {fileName}
            </span>
            {dbInfo && (
              <span className="font-sans ui-text-sm shrink-0 text-subtle-foreground">
                {dbInfo.tables}t {dbInfo.indexes}i
              </span>
            )}
          </div>
          <div className="flex items-center gap-1 rounded-lg border border-border/60 bg-surface/60 p-0.5">
            {viewTabs.map(({ mode, label }) => (
              <Button
                key={mode}
                onClick={() => setViewMode(mode)}
                variant={viewMode === mode ? "default" : "ghost"}
                size="xs"
                className={cn(
                  "px-2.5 ui-text-sm text-subtle-foreground",
                  viewMode === mode ? "text-foreground" : "text-subtle-foreground",
                )}
                aria-label={t("database.switchToView", { view: label })}
                tooltip={t("database.switchToView", { view: label })}
              >
                {label}
              </Button>
            ))}
          </div>
        </div>
        <div className="flex items-center gap-1">
          {viewMode === "data" && !isCustomQuery && !isSubscription && (
            <Button
              onClick={() => setShowColumnTypes(!showColumnTypes)}
              variant="ghost"
              size="icon-xs"
              className="text-subtle-foreground"
              aria-label={t("database.toggleColumnTypes")}
              tooltip={showColumnTypes ? t("database.hideColumnTypes") : t("database.showColumnTypes")}
            >
              <Columns />
            </Button>
          )}
          {resultSummary && (
            <span
              className={databaseChipClassName("px-2 font-sans ui-text-sm text-subtle-foreground")}
            >
              {resultSummary}
            </span>
          )}
          {viewMode === "data" && (
            <Button
              onClick={() => setIsCustomQuery(true)}
              variant="ghost"
              size="icon-xs"
              className="text-subtle-foreground"
              disabled={isCustomQuery}
              aria-label={t("database.openSqlEditor")}
              tooltip={t("database.openSqlEditor")}
            >
              <Code />
            </Button>
          )}
          {onCreateSubscription && (
            <Button
              onClick={onCreateSubscription}
              variant="ghost"
              className="text-subtle-foreground"
              aria-label={t("database.createSubscription")}
              tooltip={t("database.createSubscription")}
              size="icon-xs"
            >
              <RadioButton />
            </Button>
          )}
          {isSubscription && subscriptionInfo && onToggleSubscription && (
            <Button
              onClick={onToggleSubscription}
              variant="ghost"
              className="text-subtle-foreground"
              aria-label={
                subscriptionInfo.enabled
                  ? t("database.disableSubscription")
                  : t("database.enableSubscription")
              }
              tooltip={
                subscriptionInfo.enabled
                  ? t("database.disableSubscription")
                  : t("database.enableSubscription")
              }
              size="icon-xs"
            >
              {subscriptionInfo.enabled ? <MinusCircle /> : <PlusCircle />}
            </Button>
          )}
          {isSubscription && onRefreshSubscription && (
            <Button
              onClick={onRefreshSubscription}
              variant="ghost"
              className="text-subtle-foreground"
              aria-label={t("database.refreshSubscription")}
              tooltip={t("database.refreshSubscription")}
              size="icon-xs"
            >
              <ArrowClockwise />
            </Button>
          )}
          {isSubscription && onDropSubscription && (
            <Button
              onClick={onDropSubscription}
              variant="ghost"
              className="text-subtle-foreground"
              aria-label={t("database.dropSubscription")}
              tooltip={t("database.dropSubscription")}
              size="icon-xs"
            >
              <Trash />
            </Button>
          )}
          {hasData && (
            <>
              <Button
                onClick={exportAsCSV}
                variant="ghost"
                className="text-subtle-foreground"
                aria-label={exportLabel}
                tooltip={exportTooltip}
                size="icon-xs"
              >
                <Download weight="fill" />
              </Button>
              <Button
                onClick={copyAsJSON}
                variant="ghost"
                className="text-subtle-foreground"
                aria-label={jsonLabel}
                tooltip={jsonTooltip}
                size="icon-xs"
              >
                <ClipboardText />
              </Button>
            </>
          )}
        </div>
      </div>
    </div>
  );
}
