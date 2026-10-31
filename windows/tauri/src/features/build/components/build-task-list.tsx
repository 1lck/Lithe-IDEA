import { useMemo, useRef, useState } from "react";
import { useVirtualizer } from "@tanstack/react-virtual";
import { useTranslation } from "@/i18n/locale-provider";
import { Button } from "@/ui/button";
import { PlayIcon } from "@/ui/icons";
import { ScrollArea } from "@/ui/scroll-area";
import type { BuildInstance, BuildModel } from "../services/build-provider-workspace";
import type { BuildWorkspaceController } from "../services/build-workspace-controller";
import { buildTaskChoices, buildTaskRows, type BuildTaskChoice } from "../services/build-task-presentation";
import { BuildDependenciesTree } from "./build-dependencies-tree";
import { BuildTestsList } from "./build-tests-list";
import { BuildArgumentsDialog } from "./build-arguments-dialog";
import { BuildTargetsList } from "./build-targets-list";


export function BuildTaskList({ controller, instance, model, manifest, openOutput }: {
  controller: BuildWorkspaceController; instance: BuildInstance; model: BuildModel; manifest?: Record<string, unknown>; openOutput: () => void;
}) {
  const { t } = useTranslation(), scrollRef = useRef<HTMLDivElement>(null);
  const [projectID, setProjectID] = useState(model.projects[0]?.id ?? "");
  const [prompt, setPrompt] = useState<BuildTaskChoice>();
  const choices = useMemo(() => buildTaskChoices(manifest, instance, model, projectID || undefined), [manifest, instance, model, projectID]);
  const system = (manifest?.buildSystems as Array<{ id: string; dependencies?: { source?: string }; test?: { source?: string; discovery?: boolean; scopes: string[] } }> | undefined)?.find(system => system.id === instance.buildSystemID);
  const dependencies = controller.domain.dependencyResult(instance, projectID || undefined);
  const rows = useMemo(() => buildTaskRows(choices, group => t(`build.group.${group}`)), [choices, t]);
  const virtual = useVirtualizer({ count: rows.length, getScrollElement: () => scrollRef.current, estimateSize: () => 30,
    getItemKey: index => rows[index]!.id, overscan: 6 });
  const run = (choice: BuildTaskChoice, args: string[] = []) => {
    setPrompt(undefined); openOutput();
    void controller.perform(instance, () => choice.modelTaskID
      ? controller.domain.executeModelTask(instance, choice.modelTaskID, args)
      : controller.domain.executeTask(instance, choice.task, choice.projectID, args));
  };
  const row = (index: number) => {
    const item = rows[index]!;
    if ("heading" in item) return <div key={item.id} className="h-[30px] truncate px-2 py-1 text-subtle-foreground ui-text-sm">{item.heading}</div>;
    return <Button key={item.id} variant="ghost" className="h-[30px] w-full justify-start rounded-none px-2" disabled={model.truncated}
      tooltip={item.choice.description} onClick={() => item.choice.requiresArguments ? setPrompt(item.choice) : run(item.choice)}>
      <PlayIcon className="size-3 shrink-0" /><span className="truncate">{item.choice.title}</span>
    </Button>;
  };
  return <>
    <select aria-label={t("build.window.module")} className="m-2 min-w-0 rounded border border-border bg-background px-1 ui-text-sm"
      value={projectID} onChange={event => { setProjectID(event.target.value); setPrompt(undefined); }}>
      <option value="">{t("build.window.workspace")}</option>
      {model.projects.map(project => <option key={project.id} value={project.id}>{project.displayName ?? project.name} · {project.path}</option>)}
    </select>
    {system?.dependencies?.source === "provider" ? <Button variant="ghost" className="mx-2 justify-start" disabled={model.truncated}
      onClick={() => { void controller.perform(instance, () => controller.domain.dependencies(instance, projectID || undefined)); }}>{t("build.window.loadDependencies")}</Button> : null}
    <ScrollArea className="min-h-0 flex-1" viewportProps={{ ref: scrollRef }}>
      {rows.length <= 200 ? rows.map((_, index) => row(index)) : <div className="relative" style={{ height: virtual.getTotalSize() }}>
        {virtual.getVirtualItems().map(item => <div key={item.key} className="absolute top-0 w-full" style={{ transform: `translateY(${item.start}px)` }}>{row(item.index)}</div>)}
      </div>}
    </ScrollArea>
    {controller.canRunTargets ? <BuildTargetsList controller={controller} instance={instance} model={model} manifest={manifest} projectID={projectID} /> : null}
    {dependencies ? <BuildDependenciesTree key={dependencies.revision} result={dependencies} /> : null}
    {system?.test?.source === "provider" && system.test.scopes.includes(projectID ? "project" : "workspace")
      ? <BuildTestsList controller={controller} instance={instance} projectID={projectID || undefined} discovery={system.test.discovery === true}
        disabled={model.truncated} openOutput={openOutput} /> : null}
    {prompt ? <BuildArgumentsDialog key={prompt.id} title={prompt.title} onCancel={() => setPrompt(undefined)} onRun={args => run(prompt, args)} /> : null}
  </>;
}
