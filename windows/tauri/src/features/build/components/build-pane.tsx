import { useMemo, useRef } from "react";
import { useVirtualizer } from "@tanstack/react-virtual";
import { useTranslation } from "@/i18n/locale-provider";
import { Button } from "@/ui/button";
import { ArrowClockwiseIcon, PlayIcon, TerminalIcon, XIcon } from "@/ui/icons";
import { ScrollArea } from "@/ui/scroll-area";
import { Spinner } from "@/ui/spinner";
import { paneHeaderClassName, paneTitleClassName } from "@/features/panes/components/pane-chrome";
import { useUIState } from "@/features/window/stores/ui-state.store";
import { applyRightToolWindowIntent } from "@/features/layout/actions/right-tool-window-actions";
import { useBuildWorkspace } from "../hooks/use-build-workspace";
import type { BuildInstance, BuildModel } from "../services/build-provider-workspace";
import type { BuildWorkspaceController } from "../services/build-workspace-controller";

export function openBuildOutput(): void {
  const state = useUIState.getState();
  state.setBottomPaneActiveTab("build"); state.setIsBottomPaneVisible(true);
}

export default function BuildPane() {
  const { controller, snapshot } = useBuildWorkspace();
  if (!controller) return null;
  return <BuildPaneContent controller={controller} snapshot={snapshot} />;
}

/** Kept injectable for product interaction tests without native IPC. */
export function BuildPaneContent({ controller, snapshot }: ReturnType<typeof useBuildWorkspace> & { controller: BuildWorkspaceController }) {
  const { t } = useTranslation();
  const selected = snapshot.entries.find(entry => entry.id === snapshot.selectedID);
  const model = useMemo(() => selected && controller.domain.model(selected), [controller, selected, snapshot.modelRevision]);
  const phase = snapshot.operationID && controller.domain.operationSummary(snapshot.operationID)?.phase;
  const busy = phase === "preparing" || phase === "running";
  const load = () => { if (selected) void controller.perform(selected, () => controller.domain.loadModel(selected)); };
  return <section className="flex h-full min-h-0 flex-col" aria-label={t("build.window.title")}>
    <header className={paneHeaderClassName()}>
      <span className={paneTitleClassName("mr-auto")}>{t("build.window.title")}</span>
      <Button variant="ghost" size="icon-xs" aria-label={t("build.window.detect")} tooltip={t("build.window.detect")}
        disabled={snapshot.status === "loading"} onClick={() => { void controller.refresh(); }}><ArrowClockwiseIcon /></Button>
      <Button variant="ghost" size="icon-xs" aria-label={t("build.window.output")} tooltip={t("build.window.output")}
        onClick={openBuildOutput}><TerminalIcon /></Button>
      <Button variant="ghost" size="icon-xs" aria-label={t("build.window.close")} tooltip={t("build.window.close")}
        onClick={() => applyRightToolWindowIntent("build", "close")}><XIcon /></Button>
    </header>
    {snapshot.status === "loading" ? <Spinner showLabel className="p-2" /> : null}
    {snapshot.error ? <div role="alert" className="p-2 text-danger ui-text-sm">{snapshot.error}</div> : null}
    {selected ? <>
      <select aria-label={t("build.window.project")} className="m-2 min-w-0 rounded border border-border bg-background px-1 ui-text-sm"
        value={selected.id} onChange={event => controller.select(event.target.value)}>
        {snapshot.entries.map(entry => <option key={entry.id} value={entry.id}>{entry.displayName} · {entry.root}</option>)}
      </select>
      <Button variant="ghost" className="mx-2 justify-start" disabled={busy} onClick={load}>
        {busy ? <Spinner compact /> : null}{t("build.window.load")}
      </Button>
      {model?.truncated ? <div role="alert" className="p-2 ui-text-sm">{t("build.errors.incompleteModel")}</div> : null}
      {model ? <BuildModelTasks controller={controller} instance={selected} model={model} /> : null}
    </> : snapshot.status === "ready" ? <div className="p-2 text-subtle-foreground ui-text-sm">{t("build.window.empty")}</div> : null}
  </section>;
}

function BuildModelTasks({ controller, instance, model }: { controller: BuildWorkspaceController; instance: BuildInstance; model: BuildModel }) {
  const { t } = useTranslation(), scrollRef = useRef<HTMLDivElement>(null);
  const tasks = useMemo(() => model.tasks.filter(task => task.execution === "task"), [model]);
  const virtual = useVirtualizer({ count: tasks.length, getScrollElement: () => scrollRef.current, estimateSize: () => 30,
    getItemKey: index => tasks[index]!.id, overscan: 6 });
  const row = (index: number) => {
    const task = tasks[index]!;
    return <Button key={task.id} variant="ghost" className="h-[30px] w-full justify-start rounded-none px-2" disabled={model.truncated}
      title={task.path} onClick={() => { openBuildOutput(); void controller.perform(instance, () => controller.domain.executeModelTask(instance, task.id)); }}>
      <PlayIcon className="size-3 shrink-0" /><span className="truncate">{task.name}</span>
    </Button>;
  };
  return <>
    <span className="px-2 py-1 text-subtle-foreground ui-text-sm">{t("build.window.tasks")}</span>
    <ScrollArea className="min-h-0 flex-1" viewportProps={{ ref: scrollRef }}>
      {tasks.length <= 200 ? tasks.map((_, index) => row(index)) : <div className="relative" style={{ height: virtual.getTotalSize() }}>
        {virtual.getVirtualItems().map(item => <div key={item.key} className="absolute top-0 w-full" style={{ transform: `translateY(${item.start}px)` }}>{row(item.index)}</div>)}
      </div>}
    </ScrollArea>
  </>;
}
