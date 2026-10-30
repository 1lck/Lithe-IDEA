import { useMemo } from "react";
import { useTranslation } from "@/i18n/locale-provider";
import { Button } from "@/ui/button";
import { ArrowClockwiseIcon, TerminalIcon, XIcon } from "@/ui/icons";
import { Spinner } from "@/ui/spinner";
import { paneHeaderClassName, paneTitleClassName } from "@/features/panes/components/pane-chrome";
import { useUIState } from "@/features/window/stores/ui-state.store";
import { applyRightToolWindowIntent } from "@/features/layout/actions/right-tool-window-actions";
import { useBuildWorkspace } from "../hooks/use-build-workspace";
import type { BuildWorkspaceController } from "../services/build-workspace-controller";
import { BuildTaskList } from "./build-task-list";

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
      {model ? <BuildTaskList key={selected.id} controller={controller} instance={selected} model={model}
        manifest={snapshot.manifests[selected.pluginID]} openOutput={openBuildOutput} /> : null}
    </> : snapshot.status === "ready" ? <div className="p-2 text-subtle-foreground ui-text-sm">{t("build.window.empty")}</div> : null}
  </section>;
}
