import { useMemo, useRef, useSyncExternalStore } from "react";
import { useVirtualizer } from "@tanstack/react-virtual";
import { useTranslation } from "@/i18n/locale-provider";
import { Button } from "@/ui/button";
import { ScrollArea } from "@/ui/scroll-area";
import { PlayIcon } from "@/ui/icons";
import type { BuildInstance } from "../services/build-provider-workspace";
import type { BuildWorkspaceController } from "../services/build-workspace-controller";

export function BuildTestsList({ controller, instance, projectID, discovery, disabled, openOutput }: {
  controller: BuildWorkspaceController; instance: BuildInstance; projectID?: string; discovery: boolean; disabled?: boolean; openOutput: () => void;
}) {
  const { t } = useTranslation(), scrollRef = useRef<HTMLDivElement>(null), domain = controller.domain;
  const revision = useSyncExternalStore(domain.subscribeFacts, domain.snapshotFactRevision, domain.snapshotFactRevision);
  const snapshot = useMemo(() => domain.testDiscovery(instance), [domain, instance, revision]);
  const tests = useMemo(() => snapshot?.tests.filter(test => !projectID || test.project?.id === projectID) ?? [], [snapshot, projectID]);
  const virtual = useVirtualizer({ count: tests.length, getScrollElement: () => scrollRef.current, estimateSize: () => 30, overscan: 5,
    getItemKey: index => tests[index]!.id });
  const row = (index: number) => {
    const test = tests[index]!;
    return <Button variant="ghost" className="h-[30px] w-full justify-start rounded-none px-2" disabled={disabled} tooltip={`${test.suite}.${test.case}`}
      onClick={() => { openOutput(); void controller.perform(instance, () => domain.executeDiscoveredTest(instance, test.id)); }}>
      <PlayIcon className="size-3 shrink-0" /><span className="truncate">{test.suite}.{test.case}</span>
      {test.project ? <span className="truncate text-subtle-foreground">{test.project.name}</span> : null}
    </Button>;
  };
  return <section className="flex max-h-[40%] min-h-0 flex-col border-t border-border" aria-label={t("build.tests.title")}>
    <div className="flex shrink-0 gap-1 px-2">
      <Button variant="ghost" disabled={disabled} onClick={() => { openOutput(); void controller.perform(instance, () => domain.executeTests(instance, { projectID })); }}>{t("build.tests.run")}</Button>
      {discovery ? <Button variant="ghost" disabled={disabled} onClick={() => { void controller.perform(instance, () => domain.discoverTests(instance)); }}>{t("build.tests.discover")}</Button> : null}
    </div>
    <ScrollArea className="min-h-0" viewportProps={{ ref: scrollRef }}>
      {tests.length <= 200 ? tests.map((test, index) => <div key={test.id}>{row(index)}</div>)
        : <div className="relative" style={{ height: virtual.getTotalSize() }}>{virtual.getVirtualItems().map(item =>
          <div key={item.key} className="absolute top-0 w-full" style={{ transform: `translateY(${item.start}px)` }}>{row(item.index)}</div>)}</div>}
    </ScrollArea>
  </section>;
}
