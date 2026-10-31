import { memo, useMemo, useRef, useSyncExternalStore } from "react";
import { useVirtualizer } from "@tanstack/react-virtual";
import { useTranslation } from "@/i18n/locale-provider";
import { Button } from "@/ui/button";
import { ScrollArea } from "@/ui/scroll-area";
import { joinPath } from "@/utils/path-helpers";
import type { WindowsBuildProviderWorkspace } from "../services/build-provider-workspace";

export type BuildSourceNavigation = (path: string, line: number, column?: number) => void;

/** A completed report changes independently from streamed terminal output. */
export const BuildResultsContent = memo(function BuildResultsContent({ domain, operationID, onNavigate }: {
  domain: WindowsBuildProviderWorkspace; operationID?: string; onNavigate?: BuildSourceNavigation;
}) {
  const { t } = useTranslation(), scrollRef = useRef<HTMLDivElement>(null);
  const revision = useSyncExternalStore(domain.subscribeFacts, domain.snapshotFactRevision, domain.snapshotFactRevision);
  const detail = useMemo(() => operationID ? domain.result(operationID) : undefined, [domain, operationID, revision]);
  const diagnostics = detail?.diagnostics ?? [], tests = detail?.tests?.tests ?? [];
  const count = diagnostics.length + tests.length;
  const virtual = useVirtualizer({ count, getScrollElement: () => scrollRef.current, estimateSize: () => 48, overscan: 5 });
  const navigate: BuildSourceNavigation = (path, line, column) => {
    if (onNavigate) onNavigate(path, line, column);
    else void import("@/features/file-system/stores/file-system.store").then(({ useFileSystemStore }) =>
      useFileSystemStore.getState().handleFileSelect(joinPath(domain.workspacePath, path), false, line, column));
  };
  const row = (index: number) => {
    const diagnostic = diagnostics[index], test = tests[index - diagnostics.length];
    const path = diagnostic?.path ?? test?.path;
    const line = diagnostic?.line ?? test?.line ?? 1;
    const title = diagnostic ? diagnostic.message : `${test!.suite}.${test!.case}`;
    const status = diagnostic ? t(`build.diagnostic.${diagnostic.severity}`) : t(`build.testStatus.${test!.status}`);
    return <div className="flex min-h-[48px] flex-col px-2 py-1 ui-text-sm" data-status={diagnostic?.severity ?? test?.status}>
      <div className="flex min-w-0 items-center gap-2">
        <span className="shrink-0 text-subtle-foreground">{status}</span>
        {path ? <Button variant="ghost" className="h-auto min-w-0 justify-start p-0" tooltip={`${path}:${line}`} onClick={() => navigate(path, line, diagnostic?.column)}>
          <span className="truncate">{title}</span>
        </Button> : <span className="truncate select-text" title={title}>{title}</span>}
        {test?.project ? <span className="truncate text-subtle-foreground">{test.project}</span> : null}
      </div>
      {test?.message ? <div className="whitespace-pre-wrap break-words select-text text-subtle-foreground">{test.message}</div> : null}
    </div>;
  };
  if (!detail) return null;
  return <section className="flex max-h-[50%] min-h-0 flex-col border-t border-border" aria-label={t("build.results.title")}>
    {detail.tests ? <div className="shrink-0 px-2 py-1 ui-text-sm" role="status">{t("build.results.summary", detail.tests.summary)}</div> : null}
    <ScrollArea className="min-h-0" viewportProps={{ ref: scrollRef }}>
      {count <= 200 ? Array.from({ length: count }, (_, index) => <div key={index}>{row(index)}</div>)
        : <div className="relative" style={{ height: virtual.getTotalSize() }}>{virtual.getVirtualItems().map(item =>
          <div key={item.key} ref={virtual.measureElement} data-index={item.index} className="absolute top-0 w-full" style={{ transform: `translateY(${item.start}px)` }}>{row(item.index)}</div>)}</div>}
    </ScrollArea>
  </section>;
});
