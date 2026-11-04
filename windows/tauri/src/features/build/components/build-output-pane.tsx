import { useSyncExternalStore } from "react";
import { useTranslation } from "@/i18n/locale-provider";
import { Button } from "@/ui/button";
import { StopIcon } from "@/ui/icons";
import { ScrollArea } from "@/ui/scroll-area";
import { RunOutputText } from "@/features/run/components/run-output-text";
import { paneHeaderClassName, paneTitleClassName } from "@/features/panes/components/pane-chrome";
import { useBuildWorkspace } from "../hooks/use-build-workspace";
import type { WindowsBuildProviderWorkspace } from "../services/build-provider-workspace";
import { BuildResultsContent, type BuildSourceNavigation } from "./build-results-content";

export default function BuildOutputPane() {
  const { controller, snapshot } = useBuildWorkspace();
  return controller ? <BuildOutputContent domain={controller.domain} operationID={snapshot.operationID} /> : null;
}

/** The output leaf is the only subscriber to high-volume operation progress. */
export function BuildOutputContent({ domain, operationID, onNavigate }: { domain: WindowsBuildProviderWorkspace; operationID?: string; onNavigate?: BuildSourceNavigation }) {
  const { t } = useTranslation();
  useSyncExternalStore(domain.subscribe, domain.snapshotRevision, domain.snapshotRevision);
  const operation = operationID ? domain.operation(operationID) : undefined;
  const running = operation?.phase === "preparing" || operation?.phase === "running";
  return <section className="flex h-full min-h-0 flex-col" aria-label={t("build.window.output")}>
    <header className={paneHeaderClassName()}>
      <span className={paneTitleClassName("mr-auto")}>{t("build.window.output")}</span>
      <Button variant="ghost" size="icon-xs" disabled={!running} aria-label={t("build.window.stop")} tooltip={t("build.window.stop")}
        onClick={() => { if (operationID) domain.cancel(operationID); }}><StopIcon /></Button>
    </header>
    {operation?.error ? <div role="alert" className="p-2 text-danger ui-text-sm">{operation.error}</div> : null}
    <ScrollArea className="min-h-0 flex-1 p-2" orientation="both">
      <RunOutputText source={operation?.output ?? ""} title={operation?.phase ? t(`build.phase.${operation.phase}`) : t("build.window.output")}
        emptyLabel={t("build.window.noOutput")} />
    </ScrollArea>
    <BuildResultsContent domain={domain} operationID={operationID} onNavigate={onNavigate} />
  </section>;
}
