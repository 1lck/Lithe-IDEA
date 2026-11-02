import { useMemo, useRef, useState } from "react";
import { useVirtualizer } from "@tanstack/react-virtual";
import { Button } from "@/ui/button";
import { PlayIcon, BugIcon } from "@/ui/icons";
import { ScrollArea } from "@/ui/scroll-area";
import { useTranslation } from "@/i18n/locale-provider";
import type { BuildInstance, BuildModel } from "../services/build-provider-workspace";
import type { BuildWorkspaceController } from "../services/build-workspace-controller";
import { buildTargetChoices, type BuildTargetChoice } from "../services/build-target-presentation";
import { BuildArgumentsDialog } from "./build-arguments-dialog";

export function BuildTargetsList({ controller, instance, model, manifest, projectID }: {
  controller: BuildWorkspaceController; instance: BuildInstance; model: BuildModel; manifest?: Record<string, unknown>; projectID: string;
}) {
  const { t } = useTranslation(), viewport = useRef<HTMLDivElement>(null);
  const [prompt, setPrompt] = useState<{ choice: BuildTargetChoice; debug: boolean }>();
  const [active, setActive] = useState<ReturnType<BuildWorkspaceController["runTarget"]>>();
  const choices = useMemo(() => buildTargetChoices(manifest, instance, model, projectID), [manifest, instance, model, projectID]);
  const virtual = useVirtualizer({ count: choices.length, getScrollElement: () => viewport.current, estimateSize: () => 30,
    getItemKey: index => choices[index]!.id, overscan: 6 });
  const row = (index: number) => {
    const choice = choices[index]!;
    return <div key={choice.id} className="flex items-center"><Button variant="ghost" disabled={Boolean(active)} className="h-[30px] min-w-0 flex-1 justify-start rounded-none px-2" onClick={() => setPrompt({ choice, debug: false })}>
      <PlayIcon className="size-3 shrink-0" /><span className="truncate">{choice.title}</span>
    </Button>{choice.debugConfigurationType ? <Button variant="ghost" size="icon-xs" disabled={Boolean(active)}
      aria-label={t("build.targets.saveAndDebug")} tooltip={t("build.targets.saveAndDebug")}
      onClick={() => setPrompt({ choice, debug: true })}><BugIcon /></Button> : null}</div>;
  };
  if (!choices.length) return null;
  return <section aria-label={t("build.targets.title")} className="min-h-0 shrink-0">
    <div className="px-2 py-1 text-subtle-foreground ui-text-sm">{t("build.targets.title")}</div>
    <ScrollArea style={{ height: Math.min(240, choices.length * 30) }} viewportProps={{ ref: viewport }}>
      {choices.length <= 200 ? choices.map((_, index) => row(index)) : <div className="relative" style={{ height: virtual.getTotalSize() }}>
        {virtual.getVirtualItems().map(item => <div key={item.key} className="absolute top-0 w-full" style={{ transform: `translateY(${item.start}px)` }}>{row(item.index)}</div>)}
      </div>}
    </ScrollArea>
    {prompt && choices.some(choice => choice.id === prompt.choice.id) ? <BuildArgumentsDialog key={prompt.choice.id + String(prompt.debug)} title={prompt.choice.title} initialArguments={[]} submitLabel={t(prompt.debug ? "build.targets.saveAndDebug" : "build.targets.saveAndRun")}
      busy={Boolean(active)} onCancel={() => { if (active) active.cancel(); else setPrompt(undefined); }} onRun={args => {
        const operation = controller.runTarget(instance, prompt.choice, args, prompt.debug); setActive(operation);
        void operation.completion.then(() => { setActive(undefined); setPrompt(undefined); });
      }} /> : null}
  </section>;
}
