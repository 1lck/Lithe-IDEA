import { useVirtualizer } from "@tanstack/react-virtual";
import { useCallback, useEffect, useMemo, useRef, useState } from "react";
import { useFileSystemStore } from "@/features/file-system/stores/file-system.store";
import { PaneChip, paneHeaderClassName, paneTitleClassName } from "@/features/panes/components/pane-chrome";
import { useActiveWorkspaceId } from "@/features/workspace/stores/create-workspace-scoped-store";
import { useSpringStore } from "../stores/spring.store";
import type { SpringEndpoint } from "../types/spring.types";
import { filterSpringEndpoints } from "../utils/spring-endpoint-filter";
import {
  isSpringEndpointsRefreshing,
  isSpringEndpointsStale,
  resolveSpringEndpointsViewState,
} from "../utils/spring-endpoints-view-state";
import { springIndexErrorTranslationKey } from "../utils/spring-index-error";
import { resolveSpringEndpointLocation } from "../utils/spring-navigation";
import { Empty, EmptyDescription } from "@/ui/empty";
import { MagnifyingGlassIcon } from "@/ui/icons";
import Input from "@/ui/input";
import { ScrollArea } from "@/ui/scroll-area";
import { Spinner } from "@/ui/spinner";
import { useTranslation } from "@/i18n/locale-provider";
import { cn } from "@/utils/cn";

const VIRTUALIZATION_THRESHOLD = 200;
const ENDPOINT_ROW_HEIGHT = 32;

function methodLabel(endpoint: SpringEndpoint): string {
  return endpoint.httpMethods.length > 0 ? endpoint.httpMethods.join(",") : "ANY";
}

export function SpringEndpointsPane() {
  const { t } = useTranslation();
  const workspaceId = useActiveWorkspaceId();
  const rootFolderPath = useFileSystemStore((state) => state.rootFolderPath);
  const handleFileSelect = useFileSystemStore((state) => state.handleFileSelect);
  const phase = useSpringStore.use.phase();
  const loadedRoot = useSpringStore.use.loadedRoot();
  const index = useSpringStore.use.index();
  const error = useSpringStore.use.error();
  const [query, setQuery] = useState("");
  const [selectedEndpointId, setSelectedEndpointId] = useState<string | null>(null);
  const scrollRef = useRef<HTMLDivElement>(null);

  const filteredEndpoints = useMemo(
    () => filterSpringEndpoints(index.endpoints, query),
    [index.endpoints, query],
  );
  const useVirtualizerList = filteredEndpoints.length > VIRTUALIZATION_THRESHOLD;
  const rowVirtualizer = useVirtualizer({
    count: filteredEndpoints.length,
    getScrollElement: () => scrollRef.current,
    estimateSize: () => ENDPOINT_ROW_HEIGHT,
    getItemKey: (index) => filteredEndpoints[index]?.id ?? index,
    overscan: 8,
  });

  const viewState = resolveSpringEndpointsViewState({
    phase,
    loadedRoot,
    endpointCount: index.endpoints.length,
    filteredCount: filteredEndpoints.length,
  });
  const isInitialLoading = viewState === "loading";
  const isRefreshing = isSpringEndpointsRefreshing(phase, loadedRoot);
  const isStale = isSpringEndpointsStale(phase, loadedRoot);
  const hasFailedWithoutData = viewState === "failed";

  useEffect(() => {
    setQuery("");
    setSelectedEndpointId(null);
    scrollRef.current?.scrollTo({ top: 0 });
  }, [rootFolderPath, workspaceId]);

  useEffect(() => {
    setSelectedEndpointId(null);
    scrollRef.current?.scrollTo({ top: 0 });
  }, [query]);

  const handleEndpointClick = useCallback(
    (endpoint: SpringEndpoint) => {
      if (!rootFolderPath) return;
      const location = resolveSpringEndpointLocation(endpoint, rootFolderPath);
      if (!location) return;
      setSelectedEndpointId(endpoint.id);
      void handleFileSelect(
        location.filePath,
        false,
        location.line + 1,
        location.column + 1,
      ).catch((navigationError) => {
        console.warn("Failed to open Spring endpoint source:", navigationError);
      });
    },
    [handleFileSelect, rootFolderPath],
  );

  const renderEndpointRow = useCallback(
    (endpoint: SpringEndpoint) => (
      <button
        type="button"
        key={endpoint.id}
        aria-label={`${methodLabel(endpoint)} ${endpoint.route}`}
        aria-current={selectedEndpointId === endpoint.id ? "true" : undefined}
        onClick={() => handleEndpointClick(endpoint)}
        title={`${methodLabel(endpoint)} ${endpoint.route} · ${endpoint.controller}.${endpoint.method} · ${endpoint.path}`}
        className={cn(
          "flex h-full min-w-0 w-full items-center gap-3 px-2 text-left transition-colors hover:bg-accent/60",
          selectedEndpointId === endpoint.id && "bg-accent/70",
        )}
      >
        <span className="w-14 shrink-0 font-mono text-[11px] font-semibold text-primary">
          {methodLabel(endpoint)}
        </span>
        <span className="min-w-[12rem] flex-[1.4] truncate font-mono ui-text-sm text-foreground">
          {endpoint.route}
        </span>
        <span className="w-48 shrink-0 truncate font-sans ui-text-sm text-subtle-foreground">
          {endpoint.controller}.{endpoint.method}
        </span>
        <span className="w-72 shrink-0 truncate font-mono text-[11px] text-subtle-foreground">
          {endpoint.path}
        </span>
      </button>
    ),
    [handleEndpointClick, selectedEndpointId],
  );

  const countLabel =
    filteredEndpoints.length === 1
      ? t("springEndpoints.routeCountOne", { count: filteredEndpoints.length })
      : t("springEndpoints.routeCount", { count: filteredEndpoints.length });

  const errorMessageKey = springIndexErrorTranslationKey(error) ?? "springEndpoints.error.indexFailed";

  return (
    <div className="flex h-full min-h-0 flex-col bg-background">
      <div className={paneHeaderClassName("justify-between border-border/70 border-b")}>
        <div className="flex min-w-0 items-center gap-1.5">
          <span className={paneTitleClassName()}>{t("workbench.springEndpoints")}</span>
          <PaneChip>{countLabel}</PaneChip>
        </div>
      </div>
      <div className="border-border/70 border-b p-1.5">
        <Input
          size="sm"
          value={query}
          onChange={(event) => setQuery(event.target.value)}
          placeholder={t("springEndpoints.filterPlaceholder")}
          leftIcon={MagnifyingGlassIcon}
          aria-label={t("springEndpoints.filterPlaceholder")}
        />
      </div>
      {isRefreshing ? (
        <div className="border-border/70 border-b px-3 py-1.5">
          <Spinner label={t("springEndpoints.refreshing")} showLabel compact />
        </div>
      ) : null}
      {isStale ? (
        <div className="border-border/70 border-b px-3 py-1.5 font-sans ui-text-sm text-warning">
          {t("springEndpoints.stale")}
        </div>
      ) : null}
      {isInitialLoading ? (
        <Empty className="min-h-0 flex-1">
          <Spinner label={t("springEndpoints.loading")} showLabel />
        </Empty>
      ) : null}
      {hasFailedWithoutData ? (
        <Empty tone="error" className="min-h-0 flex-1">
          <EmptyDescription>{t(errorMessageKey)}</EmptyDescription>
        </Empty>
      ) : null}
      {viewState === "empty" ? (
        <Empty className="min-h-0 flex-1">
          <EmptyDescription>{t("springEndpoints.empty")}</EmptyDescription>
        </Empty>
      ) : null}
      {viewState === "no-match" ? (
        <Empty className="min-h-0 flex-1">
          <EmptyDescription>{t("springEndpoints.noMatch")}</EmptyDescription>
        </Empty>
      ) : null}
      {viewState === "list" ? (
        <ScrollArea
          className="min-h-0 flex-1"
          viewportProps={{ ref: scrollRef }}
          contentClassName="p-1"
        >
          {useVirtualizerList ? (
            <div className="relative" style={{ height: rowVirtualizer.getTotalSize() }}>
              {rowVirtualizer.getVirtualItems().map((virtualRow) => {
                const endpoint = filteredEndpoints[virtualRow.index];
                if (!endpoint) return null;
                return (
                  <div
                    key={virtualRow.key}
                    className="absolute inset-x-0"
                    style={{
                      height: virtualRow.size,
                      transform: `translateY(${virtualRow.start}px)`,
                    }}
                  >
                    {renderEndpointRow(endpoint)}
                  </div>
                );
              })}
            </div>
          ) : (
            <div>{filteredEndpoints.map(renderEndpointRow)}</div>
          )}
        </ScrollArea>
      ) : null}
    </div>
  );
}

export default SpringEndpointsPane;
